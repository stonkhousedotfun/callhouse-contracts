// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {V8AccessTest} from "../lib/V8Access.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";
import {PayoutRouter} from "../../../src/v2/periphery/PayoutRouter.sol";
import {IPayoutRouter} from "../../../src/v2/interfaces/IPayoutRouter.sol";
import {IPayoutAdapter} from "../../../src/v2/interfaces/IPayoutAdapter.sol";
import {UniV3PayoutAdapter} from "../../../src/v2/periphery/UniV3PayoutAdapter.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {IUniV3SwapRouter02, IUniV3PoolFactory} from "../../../src/v2/periphery/PayoutDeps.sol";
import {IV4PoolManager, IV4StateView, V4PoolKey, V4SwapParams} from "../../../src/v2/periphery/BuybackDeps.sol";
import {V4Currency} from "../../../src/v2/periphery/v4/V4Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../../src/mocks/MockStockToken.sol";

contract MockV3Factory is IUniV3PoolFactory {
    mapping(bytes32 => address) public pools;

    function setPool(address a, address b, uint24 fee, address pool) external {
        pools[keccak256(abi.encode(a, b, fee))] = pool;
        pools[keccak256(abi.encode(b, a, fee))] = pool;
    }

    function getPool(address a, address b, uint24 fee) external view returns (address) {
        return pools[keccak256(abi.encode(a, b, fee))];
    }
}

contract MockV3Router is IUniV3SwapRouter02 {
    address public immutable factory;
    MockERC20 public immutable dollar;
    uint256 public quote = 1e6;

    constructor(address factory_, MockERC20 dollar_) {
        factory = factory_;
        dollar = dollar_;
    }

    function setQuote(uint256 q) external {
        quote = q;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        // Real SwapRouter02 pulls tokenIn from the caller. Without this the adapter's
        // full-consumption check (stock balance back to `held`) reverts BadUnits.
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        amountOut = quote;
        require(amountOut >= p.amountOutMinimum, "Too little received");
        dollar.transfer(p.recipient, amountOut);
    }
}

contract MockV4 is IV4PoolManager, IV4StateView {
    uint160 public sqrtPrice = 1 << 96;
    uint128 public liquidity = 1e18;
    uint24 public lpFee = 3000;
    uint24 public protocolFee;
    MockERC20 public dollar;
    uint256 public quote = 1e6;
    address public lastTakeTo;

    constructor(MockERC20 dollar_) {
        dollar = dollar_;
    }

    function setState(uint160 sqrtPrice_, uint128 liquidity_, uint24 lpFee_) external {
        sqrtPrice = sqrtPrice_;
        liquidity = liquidity_;
        lpFee = lpFee_;
    }

    function setQuote(uint256 q) external {
        quote = q;
    }

    function poolManager() external view returns (address) {
        return address(this);
    }

    function getSlot0(bytes32) external view returns (uint160, int24, uint24, uint24) {
        return (sqrtPrice, 0, protocolFee, lpFee);
    }

    /// @dev T-185: `protocolFee` had no setter, so every PayoutRouter test ran it at 0 -- and 0 is SYMMETRIC under
    ///      the nibble split, so `PayoutRouter._v4FeeBps`'s `zeroForOne ? & 0xFFF : >> 12` had never been exercised
    ///      in either direction. Takes the PACKED value so a test can make the two nibbles differ.
    function setProtocolFee(uint24 packed) external {
        protocolFee = packed;
    }

    function getLiquidity(bytes32) external view returns (uint128) {
        return liquidity;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return PayoutRouter(msg.sender).unlockCallback(data);
    }

    function swap(V4PoolKey memory, V4SwapParams memory params, bytes calldata)
        external
        view
        returns (int256 swapDelta)
    {
        uint256 paid = uint256(-params.amountSpecified);
        uint256 taken = quote;
        if (params.zeroForOne) {
            swapDelta = (int256(uint256(uint128(taken)))) | (int256(uint256(uint128(paid))) << 128) * -1;
            // amount0 negative paid, amount1 positive taken
            swapDelta = (-int256(paid) << 128) | int256(uint256(uint128(taken)));
        } else {
            swapDelta = (int256(uint256(uint128(taken))) << 128) | int256(-int256(paid));
        }
    }

    function sync(address) external {}

    function settle() external payable returns (uint256) {
        return 0;
    }

    function take(address, address to, uint256 amount) external {
        lastTakeTo = to;
        dollar.transfer(to, amount == 0 ? quote : amount);
    }
}

contract PayoutRouterTest is V8AccessTest {
    address internal holder = makeAddr("holder");
    address internal guardian = makeAddr("g");
    MockERC20 internal usdg;
    MockStockToken internal nvda;
    MockV3Factory internal v3Factory;
    MockV3Router internal v3Router;
    MockV4 internal v4;
    PayoutRouter internal router;

    function setUp() public {
        usdg = new MockERC20("USDG", "USDG", 6);
        nvda = new MockStockToken("NVDA", "NVDAx");
        v3Factory = new MockV3Factory();
        v3Router = new MockV3Router(address(v3Factory), usdg);
        v3Factory.setPool(address(nvda), address(usdg), 500, address(0xBEEF));
        v4 = new MockV4(usdg);
        router = new PayoutRouter(address(_manager()), address(usdg), address(v3Router), address(v4), address(v4));
        _wire(address(router), "PayoutRouter", holder, 0);
        _grant(V8Roles.GUARDIAN, guardian, 0);
        usdg.mint(address(v3Router), 1_000_000e6);
        usdg.mint(address(v4), 1_000_000e6);
        nvda.mint(address(this), 100e18);
        nvda.approve(address(router), type(uint256).max);
    }

    function _manager() internal returns (address) {
        _deployManager();
        return address(manager);
    }

    /// @dev F-05-04. A route is VALIDATED and priced through `v4StateView` and EXECUTED through the PoolManager the
    ///      router inherited from `V4UnlockCallback`. Code at each address does not say they are the same manager, so
    ///      the constructor compares them. Mirrors `V4BuybackExecutor`'s check on the same `IV4StateView.poolManager()`.
    function test_constructor_stateViewOverAnotherPoolManagerRevertsNoSource() public {
        MockV4 other = new MockV4(usdg);
        // `MockV4.poolManager()` returns `address(this)`, so two instances are two managers, which is the mismatch.
        assertTrue(other.poolManager() != v4.poolManager(), "the two mocks must name different managers");
        vm.expectRevert(V2Errors.NoSource.selector);
        new PayoutRouter(address(manager), address(usdg), address(v3Router), address(v4), address(other));
    }

    /// @dev The other half of the pair: a StateView over the SAME manager deploys and is stored.
    function test_constructor_stateViewOverTheSamePoolManagerDeploys() public {
        PayoutRouter paired =
            new PayoutRouter(address(manager), address(usdg), address(v3Router), address(v4), address(v4));
        assertEq(paired.v4StateView(), address(v4), "v4StateView");
        assertEq(IV4StateView(paired.v4StateView()).poolManager(), address(v4), "the stored StateView's manager");
    }

    function test_setRouteV3_strangerRevertsNotAuthorized() public {
        vm.prank(makeAddr("nope"));
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        router.setRouteV3(address(nvda), 500);
    }

    function test_setRouteV4_refusesDynamicFeeFlag() public {
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.RouteRejected.selector, keccak256("DYNAMIC_FEE")));
        router.setRouteV4(address(nvda), 0x800000 | 3000, 60);
    }

    function test_setRouteV4_refusesUninitialisedAndNoLiquidity() public {
        v4.setState(0, 1e18, 3000);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.RouteRejected.selector, keccak256("NOT_INIT")));
        router.setRouteV4(address(nvda), 3000, 60);
        v4.setState(1 << 96, 0, 3000);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.RouteRejected.selector, keccak256("NO_LIQUIDITY")));
        router.setRouteV4(address(nvda), 3000, 60);
    }

    /// @dev T-185 PIN: which half of the packed `protocolFee` the cached route fee reads.
    ///      `PayoutRouter.sol:224` picks `zeroForOne ? (protocolFee & 0xFFF) : (protocolFee >> 12)`, and v4 orders a
    ///      pool's currencies BY ADDRESS, so selling NVDA into USDG is `zeroForOne` exactly when NVDA sorts first.
    ///      The expected figure below is written as a LITERAL and the direction from a raw address comparison --
    ///      deliberately NOT from `V4Currency.zeroForOne` and NOT from the same ternary, because deriving the
    ///      expectation from the code under test is what made the existing checks blind (see
    ///      `test/v2/unit/V4FeeNibblePin.t.sol`).
    ///      The two nibbles are ASYMMETRIC on purpose: 111 and 222 pips give 32 and 33 bps after
    ///      `(lpFee + proto + 99) / 100` with the mock's 3000 lpFee, so a flipped ternary changes the answer.
    function test_v4RouteFeeReadsTheNibbleForTheRouteDirection() public {
        v4.setProtocolFee(uint24(111) | (uint24(222) << 12));

        vm.prank(holder);
        router.setRouteV4(address(nvda), 3000, 60);

        bool zeroForOne = address(nvda) < address(usdg);
        uint16 expected = zeroForOne ? 32 : 33;
        uint16 wrongWay = zeroForOne ? 33 : 32;

        assertEq(
            router.routeFeeBps(address(nvda)),
            expected,
            "the cached route fee must charge the nibble for the direction this route actually swaps"
        );
        assertTrue(router.routeFeeBps(address(nvda)) != wrongWay, "the route fee read the opposite nibble");
    }

    function test_setRouteV4_hooklessSucceedsAndCachesFee() public {
        vm.prank(holder);
        router.setRouteV4(address(nvda), 3000, 60);
        IPayoutRouter.Route memory r = router.routes(address(nvda));
        assertEq(uint8(r.venue), uint8(IPayoutRouter.Venue.V4));
        assertEq(r.fee, 3000);
        assertEq(r.tickSpacing, 60);
        assertEq(r.v3Pool, address(0));
        // MockV4.lpFee = 3000 pips; formula from UniV3PayoutAdapter.sol:194 is (fee + 99) / 100.
        assertEq(r.feeBps, 30);
        assertEq(router.routeFeeBps(address(nvda)), 30);
    }

    function test_constructedV4KeyIsHookless() public view {
        V4PoolKey memory k = V4Currency.key(address(nvda), address(usdg), 3000, 60);
        assertEq(k.hooks, address(0), "hooks are never a setRouteV4 parameter");
        // Memory-to-memory struct assignment aliases; build a distinct struct.
        V4PoolKey memory hooked = V4PoolKey({
            currency0: k.currency0,
            currency1: k.currency1,
            fee: k.fee,
            tickSpacing: k.tickSpacing,
            hooks: address(0xB0B)
        });
        assertTrue(V4Currency.id(k) != V4Currency.id(hooked), "hooked pool id differs");
        assertEq(k.hooks, address(0), "the hookless key must not alias the hooked copy");
    }

    function test_clearRoute_zerosCachedFee() public {
        vm.prank(holder);
        router.setRouteV3(address(nvda), 500);
        assertEq(router.routeFeeBps(address(nvda)), 5);
        assertEq(uint8(router.routes(address(nvda)).venue), uint8(IPayoutRouter.Venue.V3));
        vm.prank(guardian);
        router.clearRoute(address(nvda));
        IPayoutRouter.Route memory r = router.routes(address(nvda));
        assertEq(uint8(r.venue), uint8(IPayoutRouter.Venue.None));
        assertEq(r.feeBps, 0, "cached fee must not outlive the route");
        assertEq(router.routeFeeBps(address(nvda)), 0);
    }

    function test_swapToUsdg_v3() public {
        vm.prank(holder);
        router.setRouteV3(address(nvda), 500);
        v3Router.setQuote(10e6);
        uint256 out = router.swapToUsdg(address(nvda), 1e18, 1e6, address(0xABC));
        assertEq(out, 10e6);
        assertEq(usdg.balanceOf(address(0xABC)), 10e6);
        assertEq(nvda.balanceOf(address(this)), 99e18);
    }

    function test_swapToUsdg_v4() public {
        vm.prank(holder);
        router.setRouteV4(address(nvda), 3000, 60);
        v4.setQuote(10e6);
        uint256 out = router.swapToUsdg(address(nvda), 1e18, 1e6, address(0xABC));
        assertEq(out, 10e6);
        assertEq(usdg.balanceOf(address(0xABC)), 10e6);
        assertEq(v4.lastTakeTo(), address(0xABC));
        assertEq(nvda.balanceOf(address(this)), 99e18);
    }

    function test_swapMissesFloor_isASuccessForTheWinnerInKind() public {
        // The router reverts below minOut. The Clearinghouse catches that and pays STOCK TOKENS.
        // That fallback is a FEATURE: the winner is paid, not reverted. This test pins the router
        // half; UniV3PayoutAdapterClearinghouse.t.sol pins the Clearinghouse half (inUsdg == false).
        vm.prank(holder);
        router.setRouteV3(address(nvda), 500);
        v3Router.setQuote(1);
        vm.expectRevert();
        router.swapToUsdg(address(nvda), 1e18, 1e6, address(0xABC));
        assertEq(nvda.balanceOf(address(this)), 100e18, "failed swap consumes nothing");
    }

    /*//////////////////////////////////////////////////////////////
       F-CT5-03 -- refreshRouteFee: permissionless, cached, silent
    //////////////////////////////////////////////////////////////*/

    /// @notice F-CT5-03 (ops/audit/CT5-TESTS.md:343-390). `refreshRouteFee` was named by no test in any layer.
    ///         Its only appearance in test/ was the selector pin at test/v2/InterfaceIds.t.sol:832, and a selector
    ///         pin asserts the function's NAME, never its body. It is permissionless (script/v2/roles.v8.json:243)
    ///         and it writes `feeBps`, the cached fee the payout path sizes against. This executes it.
    /// @dev The middle assertion is the one that makes the last one mean something: the cache does NOT follow the
    ///      pool on its own, so the change after the call is the refresh and not the read.
    function test_refreshRouteFee_v4_picksUpAPoolFeeChangeAndAnyoneCanCallIt() public {
        vm.prank(holder);
        router.setRouteV4(address(nvda), 3000, 60);
        assertEq(router.routeFeeBps(address(nvda)), 30, "cached at route time: (3000 + 99) / 100");

        // The pool's own LP fee moves on chain.
        v4.setState(1 << 96, 1e18, 10_000);
        assertEq(router.routeFeeBps(address(nvda)), 30, "a cache that tracked the pool by itself would need no refresh");

        address anyone = makeAddr("anyone at all");
        vm.prank(anyone);
        router.refreshRouteFee(address(nvda));

        assertEq(router.routeFeeBps(address(nvda)), 100, "(10_000 + 99) / 100 = 100");
        IPayoutRouter.Route memory r = router.routes(address(nvda));
        assertEq(r.fee, 3000, "the route's pinned fee TIER is not what a refresh rewrites");
        assertEq(uint8(r.venue), uint8(IPayoutRouter.Venue.V4), "the venue is untouched");
    }

    /// @notice F-CT5-03's observability half, pinned as a FACT rather than fixed: the write is invisible on chain.
    /// @dev WHAT AN OPERATOR COULD OBSERVE TODAY IF THIS WERE CALLED MALICIOUSLY: nothing, directly. Every sibling
    ///      that writes `feeBps` announces it -- `setRouteV3` and `setRouteV4` both emit {RouteSet} -- and this one
    ///      emits no log at all, so an indexer sees no transition and a monitor has no event to alert on. The only
    ///      signal available is indirect: the value now returned by `routeFeeBps` differs from the one the last
    ///      {RouteSet} announced, and nothing in the system reconciles those two today. This test asserts the
    ///      silence so that ADDING an event becomes a deliberate, visible change rather than a silent one.
    ///      ADDING THAT EVENT IS NOT IN SCOPE HERE: src/v2/periphery/PayoutRouter.sol is outside this row's
    ///      scope_paths, and an event on a money path is not something to slip in sideways. It needs its own row.
    function test_refreshRouteFee_emitsNothingSoTheChangeIsUnobservable() public {
        vm.prank(holder);
        router.setRouteV4(address(nvda), 3000, 60);
        v4.setState(1 << 96, 1e18, 10_000);

        vm.recordLogs();
        vm.prank(makeAddr("anyone at all"));
        router.refreshRouteFee(address(nvda));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0, "refreshRouteFee emits nothing -- if this fails, someone added an event, on purpose");
        assertEq(router.routeFeeBps(address(nvda)), 100, "...and yet the cached fee DID change under that silence");
    }

    /// @dev The V3 branch of the same function. `_v3FeeBps` is computed from the route's own pinned tier rather
    ///      than read from the pool, so a refresh is a no-op here by construction -- which is worth pinning,
    ///      because it says the two venues do NOT behave the same under this call.
    function test_refreshRouteFee_v3_recomputesTheSameValueFromTheRoutesOwnTier() public {
        vm.prank(holder);
        router.setRouteV3(address(nvda), 500);
        assertEq(router.routeFeeBps(address(nvda)), 5, "cached at route time");

        vm.prank(makeAddr("anyone at all"));
        router.refreshRouteFee(address(nvda));
        assertEq(router.routeFeeBps(address(nvda)), 5, "the V3 fee comes from the tier, so a refresh cannot move it");
    }

    /// @dev The one guard the function does have: an asset with no route is refused rather than silently caching 0.
    function test_refreshRouteFee_unroutedAssetReverts() public {
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        router.refreshRouteFee(address(nvda));

        // Positive control: the SAME call succeeds once a route exists, so the revert is the missing route.
        vm.prank(holder);
        router.setRouteV3(address(nvda), 500);
        router.refreshRouteFee(address(nvda));
        assertEq(router.routeFeeBps(address(nvda)), 5, "routed, so the refresh goes through");
    }

    function test_routesSelectorCollisionIsPinned() public pure {
        assertEq(IPayoutRouter.routes.selector, bytes4(0xd7409659));
        // UniV3PayoutAdapter.routes is a public mapping; `.selector` is not a member on the type.
        assertEq(bytes4(keccak256("routes(address)")), bytes4(0xd7409659));
        assertEq(IPayoutRouter.routes.selector, bytes4(keccak256("routes(address)")));
    }

    /// @dev Compile-time pin: the v7 adapter getter still returns (address pool, uint24 fee).
    ///      The body is unreachable; deleting or retupling the mapping fails to compile.
    function test_adapterRoutesGetterStillTuplePoolFee() public view {
        if (block.timestamp == 0) {
            UniV3PayoutAdapter(address(0)).routes(address(0));
        }
    }
}
