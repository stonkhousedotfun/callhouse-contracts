// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UniV3TwapSource} from "../../../src/v2/oracle/UniV3TwapSource.sol";

import {ForkFloor} from "./ForkFloor.sol";

/*//////////////////////////////////////////////////////////////
        MINIMAL UNISWAP v4 / v3 / PONS TYPES (ABI-identical)
//////////////////////////////////////////////////////////////*/

/// @dev v4-core PoolKey. Currency and IHooks are user-defined address types, so the ABI is five static words.
struct FwPoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @dev v4-core SwapParams.
struct FwSwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

/// @dev v4-periphery IV4Router.ExactInputSingleParams, the stock layout the UniversalRouter's V4_SWAP decodes.
struct FwExactInputSingleParams {
    FwPoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

/// @dev v4-periphery IV4Quoter.QuoteExactSingleParams.
struct FwQuoteExactSingleParams {
    FwPoolKey poolKey;
    bool zeroForOne;
    uint128 exactAmount;
    bytes hookData;
}

/// @dev v3-periphery IQuoterV2.QuoteExactInputSingleParams.
struct FwV3QuoteParams {
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint24 fee;
    uint160 sqrtPriceLimitX96;
}

interface IFwPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(FwPoolKey memory key, FwSwapParams memory params, bytes calldata hookData)
        external
        returns (int256 delta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
    function protocolFeeController() external view returns (address);
    function setProtocolFee(FwPoolKey memory key, uint24 newProtocolFee) external;
}

interface IFwStateView {
    function poolManager() external view returns (address);
    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
    function getLiquidity(bytes32 poolId) external view returns (uint128);
}

interface IFwV4Quoter {
    function poolManager() external view returns (address);
    function quoteExactInputSingle(FwQuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

interface IFwUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IFwPositionManager {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
}

interface IFwLocker {
    function lockedPositions(address token) external view returns (uint256);
    function isLocked(address token) external view returns (bool);
}

/// @dev PonsV2MemeHook (Sourcify exact match on 4663): the parts this spike reads or drives.
interface IFwMemeHook {
    function poolManager() external view returns (address);
    function owner() external view returns (address);
    function factory() external view returns (address);
    function feeSweepOperator() external view returns (address);
    function hookFeeBps() external view returns (uint256);
    function setHookFeeBps(uint256 bps) external;
    function launches(bytes32 poolId)
        external
        view
        returns (
            bool registered,
            bool memecoinIsCurrency0,
            address memecoin,
            address quoteToken,
            address creator,
            address buybackCreatorRecipient,
            address protocolFeeRecipient,
            uint16 creatorTaxBps,
            uint16 protocolFeeShareBps,
            uint16 buybackBurnBps,
            uint16 hookFeeBps,
            uint16 maxInternalPriceImpactBps,
            bool buybackEnabled
        );
    function pendingFees(bytes32 poolId, address currency) external view returns (uint256);
    function pendingCreatorTax(bytes32 poolId, address currency) external view returns (uint256);
}

interface IFwV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function observations(uint256 index)
        external
        view
        returns (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityX128, bool initialized);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata)
        external
        returns (int256 amount0, int256 amount1);
}

interface IFwV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IFwQuoterV2 {
    function quoteExactInputSingle(FwV3QuoteParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

interface IFwWeth {
    function withdraw(uint256 wad) external;
}

interface IFwBurnable {
    function burn(uint256 amount) external;
}

/*//////////////////////////////////////////////////////////////
                    THE SPIKE'S DIRECT CALLER
//////////////////////////////////////////////////////////////*/

/// @notice Test-only direct caller with the shape the proposed V4BuybackExecutor would take (C3-604): USDG it holds
///         -> WETH on the v3 0.01 % pool (pool.swap + callback) -> unwrap -> ETH -> token on ONE PoolKey through
///         PoolManager.unlock (settle / take), or through the UniversalRouter with the same explicit key -> burn, with
///         a supply-delta check. It also serves as the scenario actors (front-runner, seller). Not production code.
contract FlywheelRouteBuyer {
    struct Order {
        uint256 usdgIn;
        uint256 minWethOut;
        uint256 minTokensOut;
        bool viaRouter;
        bytes hookData;
    }

    struct Fill {
        uint256 wethOut;
        uint256 ethIn;
        uint256 tokensOut;
        uint256 supplyDrop;
        uint256 gasV3;
        uint256 gasUnwrap;
        uint256 gasV4;
        uint256 gasBurn;
    }

    error NotPool();
    error NotPoolManager();
    error TransferFailed();
    error TooLittleWeth(uint256 out, uint256 minimum);
    error TooLittleReceived(uint256 out, uint256 minimum);
    error SupplyDelta(uint256 dropped, uint256 burned);

    address internal constant ETH = address(0);
    uint160 internal constant MIN_SQRT_PRICE = 4_295_128_739;
    uint160 internal constant MAX_SQRT_PRICE = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;
    /// @dev UniversalRouter command and v4-periphery Actions opcodes; ActionConstants.MSG_SENDER / OPEN_DELTA.
    uint8 internal constant CMD_V4_SWAP = 0x10;
    uint8 internal constant ACT_SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant ACT_SETTLE = 0x0b;
    uint8 internal constant ACT_TAKE = 0x0e;
    address internal constant MSG_SENDER = address(1);
    uint256 internal constant OPEN_DELTA = 0;

    IERC20 public immutable usdg;
    address public immutable weth;
    address public immutable token;
    address public immutable v3Pool;
    IFwPoolManager public immutable poolManager;
    IFwUniversalRouter public immutable router;
    address public immutable hooks;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;

    constructor(
        address usdg_,
        address weth_,
        address v3Pool_,
        address poolManager_,
        address router_,
        FwPoolKey memory key_
    ) {
        usdg = IERC20(usdg_);
        weth = weth_;
        v3Pool = v3Pool_;
        poolManager = IFwPoolManager(poolManager_);
        router = IFwUniversalRouter(router_);
        token = key_.currency1;
        hooks = key_.hooks;
        fee = key_.fee;
        tickSpacing = key_.tickSpacing;
    }

    receive() external payable {}

    /// @notice The one PoolKey this caller can trade: ETH / token, immutable.
    function key() public view returns (FwPoolKey memory) {
        return FwPoolKey({currency0: ETH, currency1: token, fee: fee, tickSpacing: tickSpacing, hooks: hooks});
    }

    /// @notice The full route for `o.usdgIn` USDG this contract already holds, then burn everything bought.
    function buyAndBurn(Order calldata o) external returns (Fill memory f) {
        uint256 g = gasleft();
        f.wethOut = _v3UsdgToWeth(o.usdgIn);
        f.gasV3 = g - gasleft();
        if (f.wethOut < o.minWethOut) revert TooLittleWeth(f.wethOut, o.minWethOut);

        g = gasleft();
        IFwWeth(weth).withdraw(f.wethOut);
        f.gasUnwrap = g - gasleft();
        f.ethIn = f.wethOut;

        g = gasleft();
        if (o.viaRouter) f.tokensOut = _v4BuyViaRouter(f.ethIn, o.minTokensOut);
        else (, f.tokensOut) = _v4SwapExactIn(true, f.ethIn, o.hookData);
        f.gasV4 = g - gasleft();
        if (f.tokensOut < o.minTokensOut) revert TooLittleReceived(f.tokensOut, o.minTokensOut);

        uint256 supplyBefore = IERC20(token).totalSupply();
        g = gasleft();
        IFwBurnable(token).burn(f.tokensOut);
        f.gasBurn = g - gasleft();
        f.supplyDrop = supplyBefore - IERC20(token).totalSupply();
        if (f.supplyDrop != f.tokensOut) revert SupplyDelta(f.supplyDrop, f.tokensOut);
    }

    /// @notice Scenario actor: USDG -> WETH on the v3 pool, WETH kept.
    function v3UsdgToWeth(uint256 usdgIn) external returns (uint256 wethOut) {
        return _v3UsdgToWeth(usdgIn);
    }

    /// @notice Scenario actor: exact-input swap on the pinned key from this contract's own ETH or tokens.
    function swapExactIn(bool zeroForOne, uint256 amountIn) external returns (uint256 paid, uint256 out) {
        return _v4SwapExactIn(zeroForOne, amountIn, "");
    }

    /// @notice UniversalRouter V4_SWAP for an ETH -> token buy on the pinned key, output to the caller.
    function routerCall(uint256 ethIn, uint256 minOut)
        public
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            FwExactInputSingleParams({
                poolKey: key(),
                zeroForOne: true,
                amountIn: uint128(ethIn),
                amountOutMinimum: uint128(minOut),
                hookData: ""
            })
        );
        // SETTLE(currency, amount, payerIsUser = false): the router pays the ETH it received as msg.value.
        params[1] = abi.encode(ETH, ethIn, false);
        // TAKE(currency, recipient, OPEN_DELTA): the whole output to msg.sender.
        params[2] = abi.encode(token, MSG_SENDER, OPEN_DELTA);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(ACT_SWAP_EXACT_IN_SINGLE, ACT_SETTLE, ACT_TAKE), params);
        commands = abi.encodePacked(CMD_V4_SWAP);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != v3Pool) revert NotPool();
        if (amount1Delta > 0 && !usdg.transfer(msg.sender, uint256(amount1Delta))) revert TransferFailed();
        if (amount0Delta > 0 && !IERC20(weth).transfer(msg.sender, uint256(amount0Delta))) revert TransferFailed();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (bool zeroForOne, uint256 amountIn, bytes memory hookData) = abi.decode(data, (bool, uint256, bytes));
        int256 delta = poolManager.swap(
            key(),
            FwSwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1
            }),
            hookData
        );
        // BalanceDelta: amount0 in the upper 128 bits, amount1 in the lower, both signed from the caller's view.
        int128 amount0 = int128(delta >> 128);
        int128 amount1 = int128(delta);
        (int128 inDelta, int128 outDelta) = zeroForOne ? (amount0, amount1) : (amount1, amount0);
        uint256 paid = uint256(uint128(-inDelta));
        uint256 out = uint256(uint128(outDelta));
        address currencyIn = zeroForOne ? ETH : token;
        poolManager.sync(currencyIn);
        if (currencyIn == ETH) {
            poolManager.settle{value: paid}();
        } else {
            if (!IERC20(token).transfer(address(poolManager), paid)) revert TransferFailed();
            poolManager.settle();
        }
        poolManager.take(zeroForOne ? token : ETH, address(this), out);
        return abi.encode(paid, out);
    }

    function _v3UsdgToWeth(uint256 usdgIn) internal returns (uint256) {
        // WETH is token0 and USDG token1 of the pool: USDG in is oneForZero, exact input is a positive amount.
        (int256 amount0,) = IFwV3Pool(v3Pool).swap(address(this), false, int256(usdgIn), MAX_SQRT_PRICE - 1, "");
        return uint256(-amount0);
    }

    function _v4SwapExactIn(bool zeroForOne, uint256 amountIn, bytes memory hookData)
        internal
        returns (uint256 paid, uint256 out)
    {
        (paid, out) = abi.decode(poolManager.unlock(abi.encode(zeroForOne, amountIn, hookData)), (uint256, uint256));
    }

    function _v4BuyViaRouter(uint256 ethIn, uint256 minOut) internal returns (uint256 out) {
        (bytes memory commands, bytes[] memory inputs) = routerCall(ethIn, minOut);
        uint256 before = IERC20(token).balanceOf(address(this));
        router.execute{value: ethIn}(commands, inputs, block.timestamp);
        out = IERC20(token).balanceOf(address(this)) - before;
    }
}

/*//////////////////////////////////////////////////////////////
                              THE SPIKE
//////////////////////////////////////////////////////////////*/

/// @notice C3-602 route spike: the approved flywheel route on a fork of chain 4663, executed end to end by a contract
///         caller against the LIVE USDG, WETH, Uniswap v3 USDG/WETH 0.01 % pool, Uniswap v4 PoolManager, the
///         STONKHOUSE launch pool (pinned PoolKey, PonsV2MemeHook) and the token's own burn().
///           1. shape: every address, runtime code hash, hook permission bits, frozen per-pool fee terms, pool state,
///              the LP lock, the v3 TWAP, the 11 other pools of the token;
///           2. route by size: USDG -> WETH -> ETH -> STONKHOUSE -> burn at 1 ... 2,500 USDG, each from a fresh
///              snapshot, against QuoterV2 + V4Quoter quotes, with fee components, ticks and gas per leg, and the
///              11 other pools unchanged;
///           3. the UniversalRouter V4_SWAP with the explicit PoolKey, from a contract and from an EOA;
///           4-5. adverse ordering on the v4 leg (front-run and back-run) and on the v3 leg (TWAP floor);
///           6. shallow liquidity after a token sell-off;
///           7. fee changes: the hook owner's global setter, a storage counterfactual of the frozen terms, and the
///              PoolManager protocol fee at its ceiling;
///           8. caller and hookData restrictions.
/// @dev Run with:  FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC --fork-block-number <N> \
///                   --match-path "test/v2/fork/FlywheelRouteFork.t.sol" -vv
///      Without a fork (chain id != 4663) every test logs and returns, as test/fork/ForkLive.t.sol does. The public RPC
///      keeps no historical state, so <N> must be a recent block; docs/V2-FLYWHEEL-ROUTE-SPIKE.md records the block
///      the report was taken at. Output lines starting with an upper-case tag (BLOCK, ADDR, ROUTE_A, ...) are
///      space-separated key=value records for the report.
contract FlywheelRouteForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant TOKEN = 0xc2525b7c68b6d66dE5AABFEDC7B13314F389D5C4; // STONKHOUSE, 18 dp
    address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant V3_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca; // USDG/WETH 0.01 %, WETH token0
    address constant V3_QUOTER = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7; // QuoterV2
    address constant V3_ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2; // SwapRouter02, WETH9() read
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044; // PonsV2MemeHook
    address constant LP_LOCKER = 0x267444D099b10fB5Ed7c3Cc7B7c767AdcA574952; // RobinFunFiV2LaunchLocker
    address constant PONS_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    bytes32 constant POOL_ID = 0x17ce8a5fccf32a6b7c7ab3a1c1d3663d6396614384661e9779cdb68c4541dddc;
    /// @dev The launch pool's only liquidity: one full-range position, minted to the locker at graduation.
    uint256 constant LP_TOKEN_ID = 2_761_804;
    uint24 constant V3_FEE = 100;

    uint256 constant Q96 = 1 << 96;
    uint256 constant Q192 = 1 << 192;
    uint256 constant PPM = 1_000_000;

    FlywheelRouteBuyer buyer;
    address admin = makeAddr("admin");

    /// @dev One fill of the route, with the pre-trade mids, quotes and the hook's cut.
    struct Run {
        uint256 usdgIn;
        uint256 wethMid;
        uint256 wethQuoted;
        uint256 tokensQuoted;
        uint256 tokensMid;
        uint256 tokensMidOfEth;
        uint256 hookFee;
        uint256 creatorTax;
        uint256 gasCall;
        uint256 gasTx;
        int24 v3TickBefore;
        int24 v3TickAfter;
        int24 v4TickBefore;
        int24 v4TickAfter;
        FlywheelRouteBuyer.Fill f;
    }

    struct Terms {
        bool registered;
        bool memecoinIsCurrency0;
        address memecoin;
        address quoteToken;
        address creator;
        uint16 creatorTaxBps;
        uint16 protocolFeeShareBps;
        uint16 buybackBurnBps;
        uint16 hookFeeBps;
        uint16 maxInternalPriceImpactBps;
        bool buybackEnabled;
    }

    modifier onlyFork() {
        if (block.chainid != 4663) {
            console2.log("skipping: not forked onto 4663 (chainid %s)", block.chainid);
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        if (block.chainid != 4663) return;
        buyer = _newBuyer();
        vm.label(address(buyer), "FlywheelRouteBuyer");
        vm.label(USDG, "USDG");
        vm.label(WETH, "WETH");
        vm.label(TOKEN, "STONKHOUSE");
        vm.label(V3_POOL, "USDG/WETH 0.01%");
        vm.label(POOL_MANAGER, "PoolManager");
        vm.label(HOOK, "PonsV2MemeHook");
        vm.label(UNIVERSAL_ROUTER, "UniversalRouter");
        vm.label(V4_QUOTER, "V4Quoter");
    }

    /*//////////////////////////////////////////////////////////////
                    1. ADDRESSES, CODE, FEES AND STATE
    //////////////////////////////////////////////////////////////*/

    function test_fork_routeShape_addressesCodeFeesAndState() public onlyFork {
        console2.log(
            string.concat(
                "BLOCK", _kv("number", block.number), _kv("timestamp", block.timestamp), _kv("chainid", block.chainid)
            )
        );

        // Identities: every address below is either pinned here and re-derived on chain, or read from chain.
        assertEq(keccak256(abi.encode(_key())), POOL_ID, "the pinned PoolKey hashes to the launch poolId");
        assertEq(IFwV3Factory(V3_FACTORY).getPool(USDG, WETH, V3_FEE), V3_POOL, "v3 factory: USDG/WETH 0.01 % pool");
        assertEq(IFwV3Pool(V3_POOL).token0(), WETH, "WETH is token0");
        assertEq(IFwV3Pool(V3_POOL).token1(), USDG, "USDG is token1");
        assertEq(IFwV3Pool(V3_POOL).fee(), V3_FEE);
        (bool ok, bytes memory ret) = V3_ROUTER.staticcall(abi.encodeWithSignature("WETH9()"));
        assertTrue(ok);
        assertEq(abi.decode(ret, (address)), WETH, "SwapRouter02.WETH9() is the WETH used");
        assertEq(IFwMemeHook(HOOK).poolManager(), POOL_MANAGER, "hook.poolManager()");
        assertEq(IFwStateView(STATE_VIEW).poolManager(), POOL_MANAGER, "StateView.poolManager()");
        assertEq(IFwV4Quoter(V4_QUOTER).poolManager(), POOL_MANAGER, "V4Quoter.poolManager()");
        assertEq(IFwMemeHook(HOOK).factory(), PONS_FACTORY, "hook.factory() is the Pons v2 factory");

        _logCode("USDG", USDG);
        _logCode("WETH", WETH);
        _logCode("STONKHOUSE", TOKEN);
        _logCode("V3Factory", V3_FACTORY);
        _logCode("V3Pool_USDG_WETH_100", V3_POOL);
        _logCode("QuoterV2", V3_QUOTER);
        _logCode("PoolManager", POOL_MANAGER);
        _logCode("StateView", STATE_VIEW);
        _logCode("V4Quoter", V4_QUOTER);
        _logCode("UniversalRouter", UNIVERSAL_ROUTER);
        _logCode("PositionManager", POSITION_MANAGER);
        _logCode("PonsV2MemeHook", HOOK);
        _logCode("LpLocker", LP_LOCKER);
        _logCode("PonsV2Factory", PONS_FACTORY);
        _logCode("ProtocolFeeController", IFwPoolManager(POOL_MANAGER).protocolFeeController());

        // Hook permissions are the low 14 address bits (v4-core Hooks). 0x2044: beforeInitialize, afterSwap,
        // afterSwapReturnDelta. No beforeSwap: the hook cannot refuse or reprice a swap before it runs.
        uint160 flags = uint160(HOOK) & 0x3FFF;
        assertEq(flags, 0x2044, "hook permission bits");
        assertEq(flags & (1 << 7), 0, "no beforeSwap");
        assertEq(flags & (1 << 3), 0, "no beforeSwapReturnDelta");
        assertEq(flags & (3 << 8), 0, "no remove-liquidity hooks");
        console2.log(
            string.concat(
                "HOOK_FLAGS",
                _kv("bits", flags),
                " beforeInitialize=1 afterSwap=1 afterSwapReturnsDelta=1 beforeSwap=0 beforeSwapReturnsDelta=0",
                " add/removeLiquidity=0 donate=0 afterInitialize=0"
            )
        );

        // Fee terms are frozen per pool at registerPool; the global hookFeeBps() only seeds new launches.
        Terms memory t = _terms();
        assertTrue(t.registered, "pool registered on the hook");
        assertFalse(t.memecoinIsCurrency0, "token is currency1");
        assertEq(t.memecoin, TOKEN);
        assertEq(t.quoteToken, address(0), "quote is native ETH");
        console2.log(
            string.concat(
                "HOOK_TERMS",
                _kv("pool_hookFeeBps", t.hookFeeBps),
                _kv("pool_creatorTaxBps", t.creatorTaxBps),
                _kv("pool_protocolFeeShareBps", t.protocolFeeShareBps),
                _kv("pool_buybackBurnBps", t.buybackBurnBps),
                _kv("pool_maxInternalPriceImpactBps", t.maxInternalPriceImpactBps),
                _kv("pool_buybackEnabled", t.buybackEnabled ? 1 : 0),
                _kv("global_hookFeeBps", IFwMemeHook(HOOK).hookFeeBps())
            )
        );
        console2.log(
            string.concat(
                "HOOK_ROLES",
                _ka("owner", IFwMemeHook(HOOK).owner()),
                _ka("feeSweepOperator", IFwMemeHook(HOOK).feeSweepOperator()),
                _ka("creator", t.creator),
                _ka("protocolFeeController", IFwPoolManager(POOL_MANAGER).protocolFeeController())
            )
        );

        // The v4 launch pool.
        (uint160 s4, int24 tick4, uint24 protocolFee, uint24 lpFee) = IFwStateView(STATE_VIEW).getSlot0(POOL_ID);
        uint128 l4 = IFwStateView(STATE_VIEW).getLiquidity(POOL_ID);
        assertEq(lpFee, 0, "LP fee 0");
        assertGt(l4, 0, "in-range liquidity");
        console2.log(
            string.concat(
                "V4_POOL",
                _kv("sqrtPriceX96", s4),
                _ki("tick", tick4),
                _kv("protocolFee", protocolFee),
                _kv("lpFee", lpFee),
                _kv("liquidity", l4),
                _kv("eth_reserve_wei", Math.mulDiv(l4, Q96, s4)),
                _kv("token_reserve", Math.mulDiv(l4, s4, Q96)),
                _kv("tokens_per_eth_mid", _tokensAtMid(1e18, s4))
            )
        );

        // The LP: one full-range position held by the Pons locker, which has no withdrawal or arbitrary-call path.
        assertEq(IFwPositionManager(POSITION_MANAGER).ownerOf(LP_TOKEN_ID), LP_LOCKER, "position held by the locker");
        assertEq(IFwLocker(LP_LOCKER).lockedPositions(TOKEN), LP_TOKEN_ID, "locker records the position");
        assertTrue(IFwLocker(LP_LOCKER).isLocked(TOKEN));
        uint128 lpLiquidity = IFwPositionManager(POSITION_MANAGER).getPositionLiquidity(LP_TOKEN_ID);
        assertLe(lpLiquidity, l4, "locked position is part of the in-range liquidity");
        console2.log(
            string.concat("V4_LP", _kv("tokenId", LP_TOKEN_ID), _kv("liquidity", lpLiquidity), _ka("owner", LP_LOCKER))
        );

        // The v3 pool, its observation ring, and its TWAP through the repo's own UniV3TwapSource.
        _logV3Pool();

        // The 11 other pools of the token: ids re-derived from their keys, state logged.
        (FwPoolKey[11] memory keys, bytes32[11] memory ids) = _trapPools();
        for (uint256 i; i < 11; ++i) {
            assertEq(keccak256(abi.encode(keys[i])), ids[i], "trap pool key re-derives its Initialize id");
            (uint160 s, int24 tk, uint24 pf, uint24 lf) = IFwStateView(STATE_VIEW).getSlot0(ids[i]);
            console2.log(
                string.concat(
                    "TRAP_POOL",
                    _kb("id", ids[i]),
                    _ka("currency0", keys[i].currency0),
                    _kv("fee", keys[i].fee),
                    _ki("tickSpacing", keys[i].tickSpacing),
                    _ka("hooks", keys[i].hooks),
                    _kv("lpFee", lf),
                    _kv("protocolFee", pf),
                    _ki("tick", tk),
                    _kv("sqrtPriceX96", s),
                    _kv("liquidity", IFwStateView(STATE_VIEW).getLiquidity(ids[i]))
                )
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                    2. THE ROUTE BY SIZE, DIRECT CALLER
    //////////////////////////////////////////////////////////////*/

    function test_fork_routeBySize_directCaller_quotesFeesTicksGas() public onlyFork {
        uint256[9] memory sizes = [uint256(1), 5, 20, 50, 100, 250, 500, 1000, 2500];
        Terms memory t = _terms();
        for (uint256 i; i < sizes.length; ++i) {
            uint256 snap = vm.snapshotState();
            Run memory r = _route(sizes[i] * 1e6, false, "", 0, 0);
            _logRun("direct", r);

            assertEq(r.f.wethOut, r.wethQuoted, "QuoterV2 quote == v3 leg output");
            assertEq(r.f.tokensOut, r.tokensQuoted, "V4Quoter quote == v4 leg output");
            // The hook's cut is exactly the frozen terms applied to the swap's gross output.
            uint256 gross = r.f.tokensOut + r.hookFee + r.creatorTax;
            assertEq(r.hookFee, gross * t.hookFeeBps / 10_000, "hook fee = gross x pool hookFeeBps");
            assertEq(r.creatorTax, gross * t.creatorTaxBps / 10_000, "creator tax = gross x pool creatorTaxBps");
            assertLt(r.f.tokensOut, r.tokensMid, "output below the two-mid value");
            vm.revertToState(snap);
        }
    }

    /*//////////////////////////////////////////////////////////////
            3. UNIVERSALROUTER WITH THE EXPLICIT POOLKEY
    //////////////////////////////////////////////////////////////*/

    function test_fork_universalRouter_explicitPoolKey_matchesDirect() public onlyFork {
        uint256[3] memory sizes = [uint256(5), 50, 250];
        for (uint256 i; i < sizes.length; ++i) {
            uint256 snap = vm.snapshotState();
            Run memory d = _route(sizes[i] * 1e6, false, "", 0, 0);
            vm.revertToState(snap);

            snap = vm.snapshotState();
            Run memory u = _route(sizes[i] * 1e6, true, "", 0, 0);
            _logRun("router", u);
            assertEq(u.f.ethIn, d.f.ethIn, "same ETH into v4");
            assertEq(u.f.tokensOut, d.f.tokensOut, "router output == direct output on the same key and state");
            vm.revertToState(snap);

            // An EOA through the router, same ETH, output to msg.sender.
            snap = vm.snapshotState();
            address eoa = makeAddr("routerEoa");
            vm.deal(eoa, d.f.ethIn);
            (bytes memory commands, bytes[] memory inputs) = buyer.routerCall(d.f.ethIn, 0);
            uint256 g = gasleft();
            vm.prank(eoa, eoa);
            IFwUniversalRouter(UNIVERSAL_ROUTER).execute{value: d.f.ethIn}(commands, inputs, block.timestamp);
            g -= gasleft();
            uint256 gTx = vm.lastCallGas().gasTotalUsed;
            assertEq(IERC20(TOKEN).balanceOf(eoa), d.f.tokensOut, "EOA via router == direct output");
            assertEq(eoa.balance, 0, "all ETH spent");
            console2.log(
                string.concat(
                    "ROUTER_EOA",
                    _kv("size_usdg", sizes[i]),
                    _kv("eth_in", d.f.ethIn),
                    _kv("tok_out", IERC20(TOKEN).balanceOf(eoa)),
                    _kv("direct_tok_out", d.f.tokensOut),
                    _kv("gas_execute", g),
                    _kv("gas_execute_tx_total", gTx),
                    _kv("direct_gas_v4", d.f.gasV4)
                )
            );
            vm.revertToState(snap);
        }
    }

    /*//////////////////////////////////////////////////////////////
                4. ADVERSE ORDERING ON THE v4 LEG
    //////////////////////////////////////////////////////////////*/

    function test_fork_adverseOrdering_v4FrontRun_andBackRun() public onlyFork {
        uint256[3] memory sizes = [uint256(50), 250, 1000];
        uint256[4] memory fronts = [uint256(0.1 ether), 0.5 ether, 1 ether, 2 ether];
        for (uint256 i; i < sizes.length; ++i) {
            uint256 snap = vm.snapshotState();
            Run memory base = _route(sizes[i] * 1e6, false, "", 0, 0);
            vm.revertToState(snap);

            for (uint256 j; j < fronts.length; ++j) {
                // The attacker's round trip alone: what front-run + back-run costs without our trade in between.
                snap = vm.snapshotState();
                FlywheelRouteBuyer alone = _newBuyer();
                vm.deal(address(alone), fronts[j]);
                (, uint256 tokAlone) = alone.swapExactIn(true, fronts[j]);
                (, uint256 ethBackAlone) = alone.swapExactIn(false, tokAlone);
                vm.revertToState(snap);

                snap = vm.snapshotState();
                FlywheelRouteBuyer attacker = _newBuyer();
                vm.deal(address(attacker), fronts[j]);
                (, uint256 tokFront) = attacker.swapExactIn(true, fronts[j]);
                Run memory hit = _route(sizes[i] * 1e6, false, "", 0, 0);
                (, uint256 ethBack) = attacker.swapExactIn(false, tokFront);
                assertLt(hit.f.tokensOut, base.f.tokensOut, "front-run lowers our output");
                console2.log(
                    string.concat(
                        "ADVERSE_V4",
                        _kv("size_usdg", sizes[i]),
                        _kv("front_eth", fronts[j]),
                        _kv("base_tok_out", base.f.tokensOut),
                        _kv("hit_tok_out", hit.f.tokensOut),
                        _kv("our_loss_ppm", (base.f.tokensOut - hit.f.tokensOut) * PPM / base.f.tokensOut),
                        _ki("attacker_pnl_wei", int256(ethBack) - int256(fronts[j])),
                        _ki("attacker_roundtrip_alone_pnl_wei", int256(ethBackAlone) - int256(fronts[j])),
                        _ki("attacker_gain_from_our_trade_wei", int256(ethBack) - int256(ethBackAlone))
                    )
                );
                vm.revertToState(snap);
            }

            // A pre-trade quote minus 1 % as minTokensOut refuses the 0.5 ETH front-run case.
            snap = vm.snapshotState();
            FlywheelRouteBuyer front = _newBuyer();
            vm.deal(address(front), 0.5 ether);
            front.swapExactIn(true, 0.5 ether);
            uint256 minOut = base.tokensQuoted * 99 / 100;
            deal(USDG, address(buyer), sizes[i] * 1e6);
            try buyer.buyAndBurn(
                FlywheelRouteBuyer.Order({
                    usdgIn: sizes[i] * 1e6, minWethOut: 0, minTokensOut: minOut, viaRouter: false, hookData: ""
                })
            ) {
                fail("minTokensOut from the pre-trade quote should refuse the front-run fill");
            } catch (bytes memory err) {
                assertEq(bytes4(err), FlywheelRouteBuyer.TooLittleReceived.selector, "refused by minTokensOut");
                console2.log(
                    string.concat(
                        "ADVERSE_V4_GUARD",
                        _kv("size_usdg", sizes[i]),
                        _kv("front_eth", 0.5 ether),
                        _kv("min_tok_out", minOut),
                        " result=reverted_TooLittleReceived"
                    )
                );
            }
            vm.revertToState(snap);
        }
    }

    /*//////////////////////////////////////////////////////////////
            5. ADVERSE ORDERING ON THE v3 LEG, TWAP FLOOR
    //////////////////////////////////////////////////////////////*/

    function test_fork_adverseOrdering_v3FrontRun_twapFloor() public onlyFork {
        UniV3TwapSource src = _twapSource(300);
        (bool ok, uint256 twapUsdgPerWeth,) = src.latest(WETH);
        assertTrue(ok, "300 s TWAP available");
        uint256 usdgIn = 50e6;
        uint256 toleranceBps = 50;
        // Floor: WETH at the 300 s TWAP, less the 0.01 % pool fee and a 50 bps tolerance.
        uint256 minWeth = usdgIn * 1e18 / twapUsdgPerWeth * (10_000 - 1 - toleranceBps) / 10_000;

        uint256 snap = vm.snapshotState();
        Run memory base = _route(usdgIn, false, "", minWeth, 0);
        assertGe(base.f.wethOut, minWeth, "undisturbed fill clears the TWAP floor");
        vm.revertToState(snap);

        uint256[3] memory fronts = [uint256(100_000e6), 1_000_000e6, 5_000_000e6];
        for (uint256 j; j < fronts.length; ++j) {
            snap = vm.snapshotState();
            FlywheelRouteBuyer attacker = _newBuyer();
            deal(USDG, address(attacker), fronts[j]);
            attacker.v3UsdgToWeth(fronts[j]);
            // Unguarded fill in the pushed state.
            uint256 inner = vm.snapshotState();
            Run memory hit = _route(usdgIn, false, "", 0, 0);
            vm.revertToState(inner);
            // Guarded fill in the same state.
            deal(USDG, address(buyer), usdgIn);
            bool refused;
            try buyer.buyAndBurn(
                FlywheelRouteBuyer.Order({
                    usdgIn: usdgIn, minWethOut: minWeth, minTokensOut: 0, viaRouter: false, hookData: ""
                })
            ) {}
            catch (bytes memory err) {
                assertEq(bytes4(err), FlywheelRouteBuyer.TooLittleWeth.selector, "refused by the TWAP floor");
                refused = true;
            }
            assertEq(refused, hit.f.wethOut < minWeth, "floor refuses exactly when the fill is below it");
            console2.log(
                string.concat(
                    "ADVERSE_V3",
                    _kv("size_usdg", 50),
                    _kv("front_usdg", fronts[j] / 1e6),
                    _kv("twap300_usdg_per_weth", twapUsdgPerWeth),
                    _kv("min_weth", minWeth),
                    _kv("base_weth_out", base.f.wethOut),
                    _kv("hit_weth_out", hit.f.wethOut),
                    _kv("our_weth_loss_ppm", (base.f.wethOut - hit.f.wethOut) * PPM / base.f.wethOut),
                    _ki("v3_tick_after_front", hit.v3TickBefore),
                    _kv("floor_refused", refused ? 1 : 0)
                )
            );
            vm.revertToState(snap);
        }
    }

    /*//////////////////////////////////////////////////////////////
                6. SHALLOW LIQUIDITY AFTER A SELL-OFF
    //////////////////////////////////////////////////////////////*/

    /// @dev The launch pool's only liquidity is one full-range position the locker can never withdraw, so L cannot
    ///      fall. What can fall is the ETH side: x = L / sqrtP. A token sell-off that multiplies sqrtP by k divides
    ///      the ETH reserve by k, which for an ETH-in buy is the same curve as a pool with L / k at the old price.
    function test_fork_shallowLiquidity_afterTokenSellOff() public onlyFork {
        (uint160 s0,,,) = IFwStateView(STATE_VIEW).getSlot0(POOL_ID);
        uint128 l0 = IFwStateView(STATE_VIEW).getLiquidity(POOL_ID);
        uint256 tokenReserve = Math.mulDiv(l0, s0, Q96);
        uint256[2] memory ks = [uint256(2), 4];
        uint256[3] memory sizes = [uint256(5), 50, 250];
        for (uint256 i; i < ks.length; ++i) {
            uint256 snap = vm.snapshotState();
            FlywheelRouteBuyer seller = _newBuyer();
            uint256 sellAmount = tokenReserve * (ks[i] - 1);
            deal(TOKEN, address(seller), sellAmount);
            (, uint256 ethOut) = seller.swapExactIn(false, sellAmount);
            (uint160 s1, int24 tick1,,) = IFwStateView(STATE_VIEW).getSlot0(POOL_ID);
            assertEq(IFwStateView(STATE_VIEW).getLiquidity(POOL_ID), l0, "full-range L unchanged by price");
            console2.log(
                string.concat(
                    "SHALLOW_STATE",
                    _kv("k", ks[i]),
                    _kv("tokens_sold", sellAmount),
                    _kv("eth_out", ethOut),
                    _ki("tick_after", tick1),
                    _kv("eth_reserve_before", Math.mulDiv(l0, Q96, s0)),
                    _kv("eth_reserve_after", Math.mulDiv(l0, Q96, s1))
                )
            );
            for (uint256 j; j < sizes.length; ++j) {
                uint256 inner = vm.snapshotState();
                Run memory r = _route(sizes[j] * 1e6, false, "", 0, 0);
                _logRun(string.concat("shallow_k", vm.toString(ks[i])), r);
                vm.revertToState(inner);
            }
            vm.revertToState(snap);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        7. FEE CHANGES
    //////////////////////////////////////////////////////////////*/

    function test_fork_feeChanges_hookOwner_frozenTerms_protocolFee() public onlyFork {
        uint256 usdgIn = 50e6;
        uint256 snap = vm.snapshotState();
        Run memory base = _route(usdgIn, false, "", 0, 0);
        vm.revertToState(snap);
        Terms memory t0 = _terms();

        // (c1) The hook owner raises the GLOBAL fee to its ceiling. The launch pool's frozen terms do not move, and
        //      neither does the fill.
        snap = vm.snapshotState();
        address hookOwner = IFwMemeHook(HOOK).owner();
        vm.prank(hookOwner);
        IFwMemeHook(HOOK).setHookFeeBps(1000);
        assertEq(IFwMemeHook(HOOK).hookFeeBps(), 1000, "global fee raised");
        Terms memory t1 = _terms();
        assertEq(t1.hookFeeBps, t0.hookFeeBps, "pool hookFeeBps frozen");
        assertEq(t1.creatorTaxBps, t0.creatorTaxBps, "pool creatorTaxBps frozen");
        Run memory c1 = _route(usdgIn, false, "", 0, 0);
        assertEq(c1.f.tokensOut, base.f.tokensOut, "owner's global fee change does not reach this pool");
        console2.log(
            string.concat(
                "FEE_OWNER_GLOBAL",
                _kv("global_hookFeeBps", 1000),
                _kv("pool_hookFeeBps", t1.hookFeeBps),
                _kv("base_tok_out", base.f.tokensOut),
                _kv("tok_out", c1.f.tokensOut)
            )
        );
        vm.revertToState(snap);

        // (c2) Counterfactual, NOT a path that exists in the verified source: overwrite the pool's frozen terms in
        //      the hook's storage, to measure what a higher per-pool fee would do to the fill and to prove a
        //      launches(poolId) read would see it. 250 bps total, then the 2,000 bps ceiling registerPool allows.
        bytes32 slot = _launchTermsSlot();
        uint16[2] memory hookBps = [uint16(150), 1000];
        uint16[2] memory taxBps = [uint16(100), 1000];
        for (uint256 i; i < 2; ++i) {
            snap = vm.snapshotState();
            _overwriteTerms(slot, hookBps[i], taxBps[i]);
            Terms memory tc = _terms();
            assertEq(tc.hookFeeBps, hookBps[i], "launches() reads the overwritten hookFeeBps");
            assertEq(tc.creatorTaxBps, taxBps[i], "launches() reads the overwritten creatorTaxBps");
            assertEq(tc.memecoin, TOKEN, "rest of the record intact");
            Run memory c2 = _route(usdgIn, false, "", 0, 0);
            uint256 gross = c2.f.tokensOut + c2.hookFee + c2.creatorTax;
            assertEq(c2.hookFee, gross * hookBps[i] / 10_000);
            assertEq(c2.creatorTax, gross * taxBps[i] / 10_000);
            assertEq(c2.f.tokensOut, c2.tokensQuoted, "V4Quoter still matches the fill");
            console2.log(
                string.concat(
                    "FEE_COUNTERFACTUAL",
                    _kv("pool_hookFeeBps", hookBps[i]),
                    _kv("pool_creatorTaxBps", taxBps[i]),
                    _kv("base_tok_out", base.f.tokensOut),
                    _kv("tok_out", c2.f.tokensOut),
                    _kv("drop_ppm", (base.f.tokensOut - c2.f.tokensOut) * PPM / base.f.tokensOut)
                )
            );
            vm.revertToState(snap);
        }

        // (c3) The PoolManager protocol fee: its controller can set up to 1,000 pips (0.1 %) per direction on any
        //      pool, and on this chain already has on several of the token's other pools.
        snap = vm.snapshotState();
        address controller = IFwPoolManager(POOL_MANAGER).protocolFeeController();
        uint24 maxProtocolFee = 1000 | (1000 << 12);
        vm.prank(controller);
        IFwPoolManager(POOL_MANAGER).setProtocolFee(_key(), maxProtocolFee);
        (,, uint24 pf,) = IFwStateView(STATE_VIEW).getSlot0(POOL_ID);
        assertEq(pf, maxProtocolFee, "protocol fee set");
        Run memory c3 = _route(usdgIn, false, "", 0, 0);
        assertEq(c3.f.tokensOut, c3.tokensQuoted, "V4Quoter includes the protocol fee");
        console2.log(
            string.concat(
                "FEE_PROTOCOL",
                _ka("controller", controller),
                _kv("protocolFee", pf),
                _kv("base_tok_out", base.f.tokensOut),
                _kv("tok_out", c3.f.tokensOut),
                _kv("drop_ppm", (base.f.tokensOut - c3.f.tokensOut) * PPM / base.f.tokensOut)
            )
        );
        vm.revertToState(snap);
    }

    /*//////////////////////////////////////////////////////////////
                8. CALLER AND HOOKDATA RESTRICTIONS
    //////////////////////////////////////////////////////////////*/

    function test_fork_callerAndHookData_noRestriction() public onlyFork {
        uint256 usdgIn = 50e6;
        uint256 snap = vm.snapshotState();
        Run memory empty = _route(usdgIn, false, "", 0, 0);
        vm.revertToState(snap);

        snap = vm.snapshotState();
        Run memory junk = _route(usdgIn, false, hex"deadbeefcafe", 0, 0);
        assertEq(junk.f.tokensOut, empty.f.tokensOut, "hookData is ignored");
        vm.revertToState(snap);

        // A second, freshly deployed contract caller, with no history and no relation to the pool.
        snap = vm.snapshotState();
        FlywheelRouteBuyer other = _newBuyer();
        vm.deal(address(other), empty.f.ethIn);
        (, uint256 out) = other.swapExactIn(true, empty.f.ethIn);
        assertEq(out, empty.f.tokensOut, "any contract caller gets the same fill");
        vm.revertToState(snap);

        console2.log(
            string.concat(
                "CALLER",
                _kv("contract_caller_tok_out", empty.f.tokensOut),
                _kv("junk_hookdata_tok_out", junk.f.tokensOut),
                _kv("fresh_contract_tok_out", out),
                " contract_caller=accepted hookData=ignored"
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                9. THE OTHER 11 POOLS OF THE TOKEN
    //////////////////////////////////////////////////////////////*/

    /// @dev What the same spend would buy on each other pool, by V4Quoter, against the pinned pool's fill.
    function test_fork_trapPools_quotedAgainstPinned() public onlyFork {
        uint256 usdgIn = 50e6;
        uint256 snap = vm.snapshotState();
        Run memory pinned = _route(usdgIn, false, "", 0, 0);
        vm.revertToState(snap);
        (FwPoolKey[11] memory keys, bytes32[11] memory ids) = _trapPools();
        for (uint256 i; i < 11; ++i) {
            // ETH-quoted pools take the ETH the v3 leg delivered; USDG-quoted pools take the USDG directly.
            uint256 amountIn = keys[i].currency0 == address(0) ? pinned.f.ethIn : usdgIn;
            string memory result;
            uint256 quoted;
            try IFwV4Quoter(V4_QUOTER)
                .quoteExactInputSingle(
                    FwQuoteExactSingleParams({
                        poolKey: keys[i], zeroForOne: true, exactAmount: uint128(amountIn), hookData: ""
                    })
                ) returns (
                uint256 q, uint256
            ) {
                quoted = q;
                result = "quoted";
                assertLt(q, pinned.f.tokensOut, "every other pool fills worse than the pinned key");
            } catch {
                result = "reverted";
            }
            console2.log(
                string.concat(
                    "TRAP_QUOTE",
                    _kb("id", ids[i]),
                    _kv("fee", keys[i].fee),
                    _ka("currency0", keys[i].currency0),
                    _kv("amount_in", amountIn),
                    _kv("tok_out", quoted),
                    _kv("pinned_tok_out", pinned.f.tokensOut),
                    " result=",
                    result
                )
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _key() internal pure returns (FwPoolKey memory) {
        return FwPoolKey({currency0: address(0), currency1: TOKEN, fee: 0, tickSpacing: 200, hooks: HOOK});
    }

    function _newBuyer() internal returns (FlywheelRouteBuyer) {
        return new FlywheelRouteBuyer(USDG, WETH, V3_POOL, POOL_MANAGER, UNIVERSAL_ROUTER, _key());
    }

    /// @dev Quotes the route at the current state, runs it through `buyer`, and checks everything the burn and the
    ///      pinned key promise: exact supply drop, nothing left in the caller, the 11 other pools untouched.
    function _route(uint256 usdgIn, bool viaRouter, bytes memory hookData, uint256 minWethOut, uint256 minTokensOut)
        internal
        returns (Run memory r)
    {
        r.usdgIn = usdgIn;
        (uint160 s3, int24 t3,,,,,) = IFwV3Pool(V3_POOL).slot0();
        (uint160 s4, int24 t4,,) = IFwStateView(STATE_VIEW).getSlot0(POOL_ID);
        r.v3TickBefore = t3;
        r.v4TickBefore = t4;
        r.wethMid = Math.mulDiv(usdgIn, Q192, uint256(s3) * s3);
        r.tokensMid = _tokensAtMid(r.wethMid, s4);
        (r.wethQuoted,,,) = IFwQuoterV2(V3_QUOTER)
            .quoteExactInputSingle(
                FwV3QuoteParams({tokenIn: USDG, tokenOut: WETH, amountIn: usdgIn, fee: V3_FEE, sqrtPriceLimitX96: 0})
            );
        (r.tokensQuoted,) = IFwV4Quoter(V4_QUOTER)
            .quoteExactInputSingle(
                FwQuoteExactSingleParams({
                    poolKey: _key(), zeroForOne: true, exactAmount: uint128(r.wethQuoted), hookData: hookData
                })
            );

        bytes32 trapsBefore = _trapStateHash();
        uint256 feeBefore = IFwMemeHook(HOOK).pendingFees(POOL_ID, TOKEN);
        uint256 taxBefore = IFwMemeHook(HOOK).pendingCreatorTax(POOL_ID, TOKEN);
        uint256 hookBalBefore = IERC20(TOKEN).balanceOf(HOOK);
        uint256 supplyBefore = IERC20(TOKEN).totalSupply();

        deal(USDG, address(buyer), usdgIn);
        uint256 g = gasleft();
        r.f = buyer.buyAndBurn(
            FlywheelRouteBuyer.Order({
                usdgIn: usdgIn,
                minWethOut: minWethOut,
                minTokensOut: minTokensOut,
                viaRouter: viaRouter,
                hookData: hookData
            })
        );
        r.gasCall = g - gasleft();
        // The whole call as its own transaction (isolate = true): 21,000 intrinsic and calldata included, net of refunds.
        r.gasTx = vm.lastCallGas().gasTotalUsed;

        r.hookFee = IFwMemeHook(HOOK).pendingFees(POOL_ID, TOKEN) - feeBefore;
        r.creatorTax = IFwMemeHook(HOOK).pendingCreatorTax(POOL_ID, TOKEN) - taxBefore;
        r.tokensMidOfEth = _tokensAtMid(r.f.ethIn, s4);
        (, r.v3TickAfter,,,,,) = IFwV3Pool(V3_POOL).slot0();
        (, r.v4TickAfter,,) = IFwStateView(STATE_VIEW).getSlot0(POOL_ID);

        assertEq(supplyBefore - IERC20(TOKEN).totalSupply(), r.f.tokensOut, "totalSupply fell by exactly the burn");
        assertEq(r.f.supplyDrop, r.f.tokensOut);
        assertEq(IERC20(TOKEN).balanceOf(HOOK) - hookBalBefore, r.hookFee + r.creatorTax, "hook holds its cut");
        assertEq(IERC20(TOKEN).balanceOf(address(buyer)), 0, "nothing bought is left unburned");
        assertEq(IERC20(USDG).balanceOf(address(buyer)), 0, "all USDG spent");
        assertEq(IERC20(WETH).balanceOf(address(buyer)), 0, "all WETH unwrapped");
        assertEq(address(buyer).balance, 0, "all ETH spent");
        assertEq(_trapStateHash(), trapsBefore, "the 11 other pools are untouched");
        assertTrue(r.v4TickAfter < r.v4TickBefore || r.f.tokensOut == 0, "the pinned pool moved");
    }

    function _logRun(string memory tag, Run memory r) internal pure {
        uint256 gross = r.f.tokensOut + r.hookFee + r.creatorTax;
        string memory head = string.concat(" tag=", tag, _kv("size_usdg", r.usdgIn / 1e6));
        console2.log(
            string.concat(
                "ROUTE_A",
                head,
                _kv("usdg_in", r.usdgIn),
                _kv("weth_mid", r.wethMid),
                _kv("weth_quoted", r.wethQuoted),
                _kv("weth_out", r.f.wethOut),
                _kv("eth_in", r.f.ethIn),
                _kv("tok_mid", r.tokensMid),
                _kv("tok_mid_of_eth", r.tokensMidOfEth),
                _kv("tok_quoted", r.tokensQuoted),
                _kv("tok_gross", gross),
                _kv("hook_fee", r.hookFee),
                _kv("creator_tax", r.creatorTax),
                _kv("tok_out", r.f.tokensOut),
                _kv("burned", r.f.supplyDrop)
            )
        );
        console2.log(
            string.concat(
                "ROUTE_B",
                head,
                _kv("loss_total_ppm", (r.tokensMid - r.f.tokensOut) * PPM / r.tokensMid),
                _kv("loss_v3_ppm", (r.wethMid - r.f.wethOut) * PPM / r.wethMid),
                _kv("v3_fee_ppm", 100),
                _kv("impact_v4_ppm", (r.tokensMidOfEth - gross) * PPM / r.tokensMidOfEth),
                _kv("hook_fee_ppm_of_gross", r.hookFee * PPM / gross),
                _kv("creator_tax_ppm_of_gross", r.creatorTax * PPM / gross),
                _kv("usdg6_per_mtok", r.usdgIn * 1e24 / r.f.tokensOut),
                _kv("mid_usdg6_per_mtok", r.usdgIn * 1e24 / r.tokensMid)
            )
        );
        console2.log(
            string.concat(
                "ROUTE_C",
                head,
                _ki("v3_tick_before", r.v3TickBefore),
                _ki("v3_tick_after", r.v3TickAfter),
                _ki("v4_tick_before", r.v4TickBefore),
                _ki("v4_tick_after", r.v4TickAfter),
                _kv("gas_v3", r.f.gasV3),
                _kv("gas_unwrap", r.f.gasUnwrap),
                _kv("gas_v4", r.f.gasV4),
                _kv("gas_burn", r.f.gasBurn),
                _kv("gas_call", r.gasCall),
                _kv("gas_tx_total", r.gasTx)
            )
        );
    }

    function _logV3Pool() internal {
        IFwV3Pool pool = IFwV3Pool(V3_POOL);
        (uint160 s3, int24 t3, uint16 idx, uint16 card,,,) = pool.slot0();
        (uint32 oldest,,, bool init) = pool.observations((uint256(idx) + 1) % card);
        if (!init) (oldest,,,) = pool.observations(0);
        console2.log(
            string.concat(
                "V3_POOL",
                _kv("sqrtPriceX96", s3),
                _ki("tick", t3),
                _kv("liquidity", pool.liquidity()),
                _kv("observationIndex", idx),
                _kv("observationCardinality", card),
                _kv("oldest_observation_age_s", block.timestamp - oldest),
                _kv("spot_usdg_per_weth", Math.mulDiv(uint256(s3) * s3, 1e18, Q192)),
                _kv("usdg_balance", IERC20(USDG).balanceOf(V3_POOL)),
                _kv("weth_balance", IERC20(WETH).balanceOf(V3_POOL))
            )
        );
        UniV3TwapSource src = _twapSource(300);
        uint32[2] memory windows = [uint32(300), 1800];
        for (uint256 i; i < 2; ++i) {
            (bool ok, uint256 price, int24 meanTick, uint256 harmonicL) =
                src.observeWindow(WETH, uint40(block.timestamp - windows[i]), uint40(block.timestamp));
            assertTrue(ok, "TWAP window available");
            console2.log(
                string.concat(
                    "V3_TWAP",
                    _kv("window_s", windows[i]),
                    _kv("usdg_per_weth", price),
                    _ki("mean_tick", meanTick),
                    _ki("spot_minus_mean_ticks", int256(t3) - int256(meanTick)),
                    _kv("harmonic_liquidity", harmonicL)
                )
            );
        }
    }

    /// @dev The repo's own UniV3TwapSource pointed at USDG/WETH (WETH plays the 18-dp "underlying").
    function _twapSource(uint32 window) internal returns (UniV3TwapSource src) {
        src = new UniV3TwapSource(admin, USDG);
        vm.prank(admin);
        src.setPool(WETH, V3_POOL, 0, window);
    }

    function _tokensAtMid(uint256 ethIn, uint160 sqrtPriceX96) internal pure returns (uint256) {
        // currency1 per currency0 = (sqrtP / 2^96)^2; sqrtP < 2^128 here, so sqrtP^2 fits.
        return Math.mulDiv(ethIn, uint256(sqrtPriceX96) * sqrtPriceX96, Q192);
    }

    function _terms() internal view returns (Terms memory t) {
        (
            t.registered,
            t.memecoinIsCurrency0,
            t.memecoin,
            t.quoteToken,
            t.creator,,,
            t.creatorTaxBps,
            t.protocolFeeShareBps,
            t.buybackBurnBps,
            t.hookFeeBps,
            t.maxInternalPriceImpactBps,
            t.buybackEnabled
        ) = IFwMemeHook(HOOK).launches(POOL_ID);
    }

    /// @dev Finds `launches[POOL_ID]` in the hook's storage: the mapping's base slot is searched rather than assumed
    ///      (OpenZeppelin's storage layout differs across versions). Word 0 packs registered, memecoinIsCurrency0 and
    ///      memecoin; word 4 packs protocolFeeRecipient and the five uint16 terms and buybackEnabled.
    function _launchTermsSlot() internal view returns (bytes32) {
        for (uint256 base; base < 32; ++base) {
            bytes32 slot = keccak256(abi.encode(POOL_ID, base));
            uint256 w = uint256(vm.load(HOOK, slot));
            if (w & 0xff == 1 && address(uint160(w >> 16)) == TOKEN) return slot;
        }
        revert("launches slot not found");
    }

    function _overwriteTerms(bytes32 slot, uint16 hookBps, uint16 taxBps) internal {
        bytes32 wordSlot = bytes32(uint256(slot) + 4);
        uint256 w = uint256(vm.load(HOOK, wordSlot));
        w &= ~(uint256(0xffff) << 160); // creatorTaxBps
        w &= ~(uint256(0xffff) << 208); // hookFeeBps
        w |= uint256(taxBps) << 160;
        w |= uint256(hookBps) << 208;
        vm.store(HOOK, wordSlot, bytes32(w));
    }

    function _trapStateHash() internal view returns (bytes32 h) {
        (, bytes32[11] memory ids) = _trapPools();
        for (uint256 i; i < 11; ++i) {
            (uint160 s, int24 tk, uint24 pf, uint24 lf) = IFwStateView(STATE_VIEW).getSlot0(ids[i]);
            h = keccak256(abi.encode(h, s, tk, pf, lf, IFwStateView(STATE_VIEW).getLiquidity(ids[i])));
        }
    }

    /// @dev The token's other v4 pools, from the PoolManager's Initialize logs (every pool with the token as a
    ///      currency; none has it as currency0). No hooks; LP fees 7 % to 99.12 %.
    function _trapPools() internal pure returns (FwPoolKey[11] memory keys, bytes32[11] memory ids) {
        address e = address(0);
        keys[0] = FwPoolKey(USDG, TOKEN, 902_000, 18_000, e);
        ids[0] = 0xdc5edfb112b051864e24c2e1e3a16ad5828daa31e4ebce30a5bcaa8e0caec2f0;
        keys[1] = FwPoolKey(USDG, TOKEN, 870_000, 60, e);
        ids[1] = 0xe35be1d884537b18f1356ca63038d8823447ea5385316ca306c39da577dd5099;
        keys[2] = FwPoolKey(USDG, TOKEN, 991_200, 19_824, e);
        ids[2] = 0x8a6342ccfdfcac3a619cbd5bc81664a7968b02df7b2edcc91263c31966884196;
        keys[3] = FwPoolKey(USDG, TOKEN, 800_000, 16_000, e);
        ids[3] = 0xceff9e897feda8fe3781175db9c0394dd57f5c936d9ff336739411b9ac3ed3ff;
        keys[4] = FwPoolKey(e, TOKEN, 250_000, 2500, e);
        ids[4] = 0xd04efbc033c5a13c8a24bcb97c6bffab9c9ca38e3f6a817e43503d2c703230ff;
        keys[5] = FwPoolKey(e, TOKEN, 810_000, 19_988, e);
        ids[5] = 0x879b22a86cf1de099d77695bf759957ab142777d425e7bc73702c84a1f15f1c1;
        keys[6] = FwPoolKey(e, TOKEN, 800_269, 200, e);
        ids[6] = 0x4277fe7b6b898ccd0eb504f98aa785d18fd9f1589fedb0c47ea2a570053f14ff;
        keys[7] = FwPoolKey(USDG, TOKEN, 200_000, 2000, e);
        ids[7] = 0x36404cfadd040b846edd6ec3f483ae0b6a888d3ff82a32201ad473baba441481;
        keys[8] = FwPoolKey(USDG, TOKEN, 70_000, 700, e);
        ids[8] = 0x4ac7373102df992a4f957c9fc1efaeb3d3cdc94c777dec08cf02dbe5b274ee55;
        keys[9] = FwPoolKey(USDG, TOKEN, 500_000, 5000, e);
        ids[9] = 0xf2071fd6d692d362b2ccecc690525f4dee907307a1278aa12e492f4590d92bba;
        keys[10] = FwPoolKey(e, TOKEN, 899_900, 8999, e);
        ids[10] = 0x2762f4aead8bec92602ee453bfaefd9d0f192f24e200405a912563d32f093b68;
    }

    function _logCode(string memory name, address a) internal view {
        console2.log(
            string.concat(
                "ADDR name=", name, _ka("address", a), _kv("code_size", a.code.length), _kb("codehash", a.codehash)
            )
        );
    }

    function _kv(string memory k, uint256 v) internal pure returns (string memory) {
        return string.concat(" ", k, "=", vm.toString(v));
    }

    function _ki(string memory k, int256 v) internal pure returns (string memory) {
        return string.concat(" ", k, "=", vm.toString(v));
    }

    function _ka(string memory k, address v) internal pure returns (string memory) {
        return string.concat(" ", k, "=", vm.toString(v));
    }

    function _kb(string memory k, bytes32 v) internal pure returns (string memory) {
        return string.concat(" ", k, "=", vm.toString(v));
    }

    /// @dev THE FLOOR (T-588). Every other test in this file carries a chain-id guard that SKIPS when no fork is
    ///      attached, so a run that never reached chain 4663 prints `0 failed` and exits 0 -- indistinguishable from
    ///      a run in which every invariant held. This test carries no such guard. Under `FOUNDRY_PROFILE=fork` it
    ///      FAILS when the suite could not have executed, and it is the only test here that can say so.
    ///
    ///      Its witness is `POOL_MANAGER`, an address this suite's own tests read.
    ///      A count of reported tests would not do: a skip IS a report, so such a floor is satisfied by a run in
    ///      which nothing ran. See `ForkFloor` for the rest of the reasoning.
    function test_fork_floor_flywheelRouteForkExecutedAgainstARealFork() public {
        ForkFloor.requireExecutedAgainstRealFork(POOL_MANAGER, "FlywheelRouteFork");
    }
}
