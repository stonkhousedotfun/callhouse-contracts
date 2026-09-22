// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {FullMath} from "../../../src/v2/oracle/lib/FullMath.sol";
import {TickMath} from "../../../src/v2/oracle/lib/TickMath.sol";
import {V4PoolKey} from "../../../src/v2/periphery/BuybackDeps.sol";
import {V4BuybackConfig, V4BuybackExecutor} from "../../../src/v2/periphery/V4BuybackExecutor.sol";
import {MockBuybackV3Pool} from "../mocks/MockBuybackV3Pool.sol";
import {MockPonsLaunchHook} from "../mocks/MockPonsLaunchHook.sol";
import {MockV4PoolManager} from "../mocks/MockV4PoolManager.sol";
import {MockV4StateView} from "../mocks/MockV4StateView.sol";
import {V4ProtocolFeeMirror} from "../lib/V4ProtocolFeeMirror.sol";
import {MockWeth9} from "../mocks/MockWeth9.sol";

/// @notice The mocked venue every V4BuybackExecutor unit suite runs against, shaped like the live one C3-602
///         measured: a Uniswap v3 USDG/WETH 0.01 % pool with WETH as token0 at tick -197,537 (2,639.57 USDG per
///         WETH), and one Uniswap v4 ETH/token pool whose launch hook takes 100 bps for itself and 100 bps of
///         creator tax out of the OUTPUT, with the PoolManager protocol fee and the pool's LP fee at 0.
/// @dev The v3 mock prices its swap from the same tick the TWAP floor reads, so an undisturbed fill always clears
///      the floor and `payBps` is the only thing that pushes it under. The v4 mock reads the hook's own record for
///      the cut it charges, so declared and charged agree until a test sets {MockV4PoolManager.setExtraCutBps}.
abstract contract V4BuybackExecutorFixture is Test {
    /// @dev The live v3 USDG/WETH pool's tick and in-range liquidity at the C3-602 fork block.
    int24 internal constant V3_TICK = -197_537;
    uint128 internal constant V3_LIQUIDITY = 4_893_766_857_630_448_658;
    uint24 internal constant V3_FEE = 100;
    /// @dev Token base units per 1e18 wei, near the live v4 mid of 8,655,722.42 STONKHOUSE per ETH.
    uint256 internal constant TOKENS_PER_ETH = 8_655_722e18;

    uint32 internal constant WINDOW = 300;
    /// @dev 1 bp of v3 pool fee plus a 50 bp tolerance, the shape C3-602 used for its floor.
    uint16 internal constant SLIPPAGE_BPS = 51;
    /// @dev Above the 211 bps worst case of the pinned venue (1 v3 + 100 hook + 100 creator + 10 protocol ceiling).
    uint16 internal constant FEE_CAP_BPS = 250;
    uint128 internal constant MIN_LIQUIDITY = 1e18;

    uint40 internal constant T0 = 1_789_000_000;
    uint256 internal constant USDG_IN = 50e6;

    MockERC20 internal usdg;
    MockERC20 internal tok;
    MockWeth9 internal weth;
    MockBuybackV3Pool internal v3;
    MockV4PoolManager internal manager;
    MockPonsLaunchHook internal hook;
    MockV4StateView internal lens;
    V4BuybackExecutor internal exec;

    V4PoolKey internal key;
    bytes32 internal poolId;
    /// @dev WETH wei per whole (1e6) USDG at the configured tick; the v3 mock's price and the floor's quote.
    uint256 internal wethPerUsdg;

    address internal splitter = makeAddr("splitter");
    address internal stranger = makeAddr("stranger");

    function setUp() public virtual {
        vm.warp(uint256(T0) + 1 days);

        usdg = new MockERC20("Global Dollar", "USDG", 6);
        tok = new MockERC20("STONKHOUSE", "STONK", 18);
        weth = new MockWeth9();
        manager = new MockV4PoolManager();
        hook = new MockPonsLaunchHook(address(manager));
        lens = new MockV4StateView(address(manager));
        // The live pool's order: WETH is token0 and USDG token1.
        v3 = new MockBuybackV3Pool(address(weth), address(usdg), V3_FEE);
        v3.pushState(T0, V3_TICK, V3_LIQUIDITY);

        key =
            V4PoolKey({currency0: address(0), currency1: address(tok), fee: 0, tickSpacing: 200, hooks: address(hook)});
        poolId = keccak256(abi.encode(key));
        _setLaunch(100, 100);
        manager.setPool(key, uint160(1 << 96), 0, 0, 0);
        manager.setLiquidity(poolId, 29_277_002_188_455_995_497_142);
        manager.setPrice(TOKENS_PER_ETH);

        wethPerUsdg = _quoteWeth(1e6);
        v3.setSwap(MockBuybackV3Pool.Mode.Good, wethPerUsdg, 10_000, 10_000);

        // The v3 pool pays WETH out of its own balance.
        vm.deal(address(this), 1000 ether);
        weth.deposit{value: 1000 ether}();
        weth.transfer(address(v3), 1000 ether);

        exec = new V4BuybackExecutor(_cfg());
        vm.label(address(exec), "V4BuybackExecutor");

        usdg.mint(splitter, 1_000_000e6);
        vm.prank(splitter);
        usdg.approve(address(exec), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev The default configuration; constructor tests copy it and change one field.
    function _cfg() internal view returns (V4BuybackConfig memory) {
        return V4BuybackConfig({
            splitter: splitter,
            usdg: address(usdg),
            weth: address(weth),
            v3Pool: address(v3),
            poolManager: address(manager),
            stateView: address(lens),
            key: key,
            maxTotalFeeBps: FEE_CAP_BPS,
            maxSlippageBps: SLIPPAGE_BPS,
            twapWindow: WINDOW,
            minLiquidity: MIN_LIQUIDITY
        });
    }

    function _setLaunch(uint16 hookFeeBps, uint16 creatorTaxBps) internal {
        hook.setLaunch(
            poolId,
            MockPonsLaunchHook.Launch({
                registered: true,
                memecoinIsCurrency0: false,
                memecoin: address(tok),
                quoteToken: address(0),
                creatorTaxBps: creatorTaxBps,
                hookFeeBps: hookFeeBps
            })
        );
    }

    /// @dev The executor's own floor arithmetic: WETH base units for `usdgIn` at the configured tick, before the
    ///      slippage tolerance.
    function _quoteWeth(uint256 usdgIn) internal pure returns (uint256) {
        uint160 sqrtRatio = TickMath.getSqrtRatioAtTick(V3_TICK);
        uint256 ratioX192 = uint256(sqrtRatio) * sqrtRatio;
        // USDG is token1 here, so the quote is 2^192 / ratio.
        return FullMath.mulDiv(1 << 192, usdgIn, ratioX192);
    }

    /// @dev What the mocked venue pays for `usdgIn`: the v3 fill, then the v4 fill net of every fee the mocks charge.
    function _expected(uint256 usdgIn)
        internal
        view
        returns (uint256 wethOut, uint256 gross, uint256 cut, uint256 tokenOut)
    {
        wethOut = usdgIn * v3.wethPerUsdg() / 1e6 * v3.payBps() / 10_000;
        (,, uint24 protocolFee, uint24 lpFee) = lens.getSlot0(poolId);
        // T-185 finding 1, closed here rather than only recorded: this line used to write `protocolFee & 0xFFF`,
        // THE SAME EXPRESSION as `V4BuybackExecutor._feeBps`, so a flipped mask moved the code and the expectation
        // together and every suite built on this fixture stayed green. The nibble now comes from
        // `V4ProtocolFeeMirror`, a line-for-line copy of v4-core's ProtocolFeeLibrary, so the expectation is
        // anchored to the dependency instead of to the contract it is meant to check.
        uint256 afterFees = wethOut - (wethOut * uint256(V4ProtocolFeeMirror.getZeroForOneFee(protocolFee)) / 1_000_000);
        afterFees -= afterFees * uint256(lpFee) / 1_000_000;
        gross = afterFees * TOKENS_PER_ETH / 1e18;
        (,,,,,,, uint16 creatorTaxBps,,, uint16 hookFeeBps,,) = hook.launches(poolId);
        cut = gross * (uint256(hookFeeBps) + creatorTaxBps + manager.extraCutBps()) / 10_000;
        tokenOut = gross - cut;
    }

    function _buy(uint256 usdgIn, uint256 minTokenOut, uint256 minWethOut)
        internal
        returns (uint256 usdgSpent, uint256 tokenOut)
    {
        vm.prank(splitter);
        return exec.buy(usdgIn, minTokenOut, minWethOut);
    }

    /// @dev Nothing of the route's four assets stayed behind, measured against `held`.
    function _assertHoldsNothing(uint256 heldUsdg, uint256 heldWeth, uint256 heldToken, uint256 heldEth) internal view {
        assertEq(usdg.balanceOf(address(exec)), heldUsdg, "executor kept USDG");
        assertEq(weth.balanceOf(address(exec)), heldWeth, "executor kept WETH");
        assertEq(tok.balanceOf(address(exec)), heldToken, "executor kept tokens");
        assertEq(address(exec).balance, heldEth, "executor kept ETH");
    }
}
