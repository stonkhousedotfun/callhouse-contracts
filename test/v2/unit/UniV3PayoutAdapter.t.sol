// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {BaseV2Test} from "../BaseV2.t.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {IPayoutAdapter} from "../../../src/v2/interfaces/IPayoutAdapter.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {MockPayoutSwapRouter} from "../../../src/v2/mocks/MockPayoutSwapRouter.sol";
import {MockPayoutTaxToken} from "../../../src/v2/mocks/MockPayoutTaxToken.sol";
import {MockPayoutV3Factory} from "../../../src/v2/mocks/MockPayoutV3Factory.sol";
import {IUniV3SwapRouter02} from "../../../src/v2/periphery/PayoutDeps.sol";
import {UniV3PayoutAdapter} from "../../../src/v2/periphery/UniV3PayoutAdapter.sol";

/// @notice UniV3PayoutAdapter on its own (C2-10): route configuration and roles, and the swap's all-or-nothing
///         contract (exact pull, minimum output, full consumption, nothing left behind) against a mock SwapRouter02.
/// @dev Fixture: factory pools NVDA/USDG at 500 and 3000, TSLA/USDG at 3000; the router quotes NVDA at NVDA_SPOT and
///      TSLA at TSLA_SPOT, holds 10M USDG; the adapter routes NVDA at 500 and has no TSLA route. alice approved the
///      adapter for both Stock Tokens. The standard trade is 2 NVDA shares for 440 USDG.
contract UniV3PayoutAdapterTest is BaseV2Test {
    UniV3PayoutAdapter internal adapter;
    MockPayoutSwapRouter internal router;
    MockPayoutV3Factory internal factory;

    address internal nvdaPool = makeAddr("NVDA/USDG 0.05%");
    address internal nvdaPool30 = makeAddr("NVDA/USDG 0.30%");
    address internal tslaPool = makeAddr("TSLA/USDG 0.30%");

    uint256 internal constant AMOUNT = 2e18;
    uint256 internal constant FAIR = 440e6; // 2 shares at NVDA_SPOT
    uint256 internal constant MIN_OUT = 435_600_000; // FAIR less 100 bps

    event RouteSet(address indexed asset, address indexed pool, uint24 fee);

    function _deployCore() internal override {
        factory = new MockPayoutV3Factory();
        factory.setPool(address(nvda), address(usdg), 500, nvdaPool);
        factory.setPool(address(usdg), address(nvda), 3000, nvdaPool30);
        factory.setPool(address(tsla), address(usdg), 3000, tslaPool);
        router = new MockPayoutSwapRouter(address(factory));
        router.setPrice(address(nvda), NVDA_SPOT);
        router.setPrice(address(tsla), TSLA_SPOT);
        usdg.mint(address(router), 10_000_000e6);
        adapter = new UniV3PayoutAdapter(admin, address(usdg), address(router));
        vm.label(address(adapter), "UniV3PayoutAdapter");
        vm.label(address(router), "MockPayoutSwapRouter");
        vm.label(address(factory), "MockPayoutV3Factory");

        vm.prank(admin);
        adapter.setRoute(address(nvda), 500);

        vm.startPrank(alice);
        nvda.approve(address(adapter), type(uint256).max);
        tsla.approve(address(adapter), type(uint256).max);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_wiring() public view {
        assertEq(adapter.usdg(), address(usdg));
        assertEq(adapter.router(), address(router));
        assertEq(adapter.factory(), address(factory), "factory read from the router");
        assertTrue(adapter.hasRole(V2Constants.DEFAULT_ADMIN_ROLE, admin));
        (address pool, uint24 fee) = adapter.routes(address(nvda));
        assertEq(pool, nvdaPool);
        assertEq(fee, 500);
        (pool, fee) = adapter.routes(address(tsla));
        assertEq(pool, address(0), "no route until set");
        assertEq(fee, 0);
    }

    function test_constructor_rejectsZeroAdmin() public {
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        new UniV3PayoutAdapter(address(0), address(usdg), address(router));
    }

    function test_constructor_rejectsCodelessUsdg() public {
        address noCode = makeAddr("no-code-usdg");
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        new UniV3PayoutAdapter(admin, noCode, address(router));
    }

    function test_constructor_rejectsCodelessRouter() public {
        address noCode = makeAddr("no-code-router");
        vm.expectRevert(V2Errors.NoSource.selector);
        new UniV3PayoutAdapter(admin, address(usdg), noCode);
    }

    function test_constructor_rejectsRouterWithCodelessFactory() public {
        MockPayoutSwapRouter orphan = new MockPayoutSwapRouter(makeAddr("no-code-factory"));
        vm.expectRevert(V2Errors.NoSource.selector);
        new UniV3PayoutAdapter(admin, address(usdg), address(orphan));
    }

    /// @dev The selector the adapter calls is SwapRouter02's (no deadline field), the one the 4663 router dispatches.
    function test_exactInputSingleSelectorIsSwapRouter02() public pure {
        assertEq(IUniV3SwapRouter02.exactInputSingle.selector, bytes4(0x04e45aaf));
        assertEq(IPayoutAdapter.swapToUsdg.selector, UniV3PayoutAdapter.swapToUsdg.selector);
    }

    /*//////////////////////////////////////////////////////////////
                                  ROUTES
    //////////////////////////////////////////////////////////////*/

    function test_setRoute_setsAndEmits() public {
        vm.expectEmit(true, true, false, true, address(adapter));
        emit RouteSet(address(tsla), tslaPool, 3000);
        vm.prank(admin);
        adapter.setRoute(address(tsla), 3000);
        (address pool, uint24 fee) = adapter.routes(address(tsla));
        assertEq(pool, tslaPool);
        assertEq(fee, 3000);
    }

    /// @dev The factory is asked with (asset, USDG); a pool registered in the other token order is still found.
    function test_setRoute_changesFeeTier_andSwapUsesIt() public {
        vm.expectEmit(true, true, false, true, address(adapter));
        emit RouteSet(address(nvda), nvdaPool30, 3000);
        vm.prank(admin);
        adapter.setRoute(address(nvda), 3000);
        _swap(AMOUNT, MIN_OUT, bob);
        assertEq(router.lastParams().fee, 3000, "the new tier is used");
    }

    function test_setRoute_clear() public {
        vm.expectEmit(true, true, false, true, address(adapter));
        emit RouteSet(address(nvda), address(0), 0);
        vm.prank(admin);
        adapter.setRoute(address(nvda), 0);
        (address pool, uint24 fee) = adapter.routes(address(nvda));
        assertEq(pool, address(0));
        assertEq(fee, 0);

        vm.prank(alice);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        adapter.swapToUsdg(address(nvda), AMOUNT, MIN_OUT, bob);

        // Clearing an asset that never had a route is harmless and still logged.
        vm.expectEmit(true, true, false, true, address(adapter));
        emit RouteSet(address(tsla), address(0), 0);
        vm.prank(admin);
        adapter.setRoute(address(tsla), 0);
    }

    /// @dev routeFeeBps is the route's fee tier / 100 rounded up (INTERFACE_VERSION 6): the four 4663 tiers, odd tiers
    ///      rounding up, and the highest tier setRoute accepts reading as MAX_ROUTE_FEE_BPS.
    function test_routeFeeBps_roundsUpPerTier() public {
        assertEq(adapter.routeFeeBps(address(nvda)), 5, "0.05 %");
        uint24[8] memory fees = [uint24(100), 500, 3000, 10_000, 1, 101, 2500, 9901];
        uint16[8] memory bps = [uint16(1), 5, 30, 100, 1, 2, 25, 100];
        for (uint256 i; i < fees.length; ++i) {
            factory.setPool(address(tsla), address(usdg), fees[i], tslaPool);
            vm.prank(admin);
            adapter.setRoute(address(tsla), fees[i]);
            assertEq(adapter.routeFeeBps(address(tsla)), bps[i]);
        }
    }

    /// @dev A route above the 1 % tier is refused even when the factory has the pool: the Clearinghouse counts at most
    ///      MAX_ROUTE_FEE_BPS of a route's fee, so every ordinary conversion through it would silently pay in kind. The
    ///      ceiling is checked before the factory, the previous route stays, and exactly 1 % is accepted.
    function test_setRoute_rejectsFeeTierAboveOnePercent() public {
        uint24[4] memory tiers = [uint24(10_001), 20_000, 50_000, type(uint24).max];
        address unlisted = makeAddr("unlisted");
        address costly = makeAddr("NVDA/USDG costly");
        vm.startPrank(admin);
        for (uint256 i; i < tiers.length; ++i) {
            factory.setPool(address(nvda), address(usdg), tiers[i], costly);
            vm.expectRevert(V2Errors.CeilingExceeded.selector);
            adapter.setRoute(address(nvda), tiers[i]);
            vm.expectRevert(V2Errors.CeilingExceeded.selector);
            adapter.setRoute(unlisted, tiers[i]); // before the factory is asked: no NoSource
        }
        vm.stopPrank();
        (address pool, uint24 fee) = adapter.routes(address(nvda));
        assertEq(pool, nvdaPool, "previous route kept");
        assertEq(fee, 500);
        assertEq(adapter.routeFeeBps(address(nvda)), 5);

        factory.setPool(address(nvda), address(usdg), V2Constants.MAX_ROUTE_FEE_TIER, makeAddr("NVDA/USDG 1%"));
        vm.prank(admin);
        adapter.setRoute(address(nvda), V2Constants.MAX_ROUTE_FEE_TIER);
        assertEq(adapter.routeFeeBps(address(nvda)), V2Constants.MAX_ROUTE_FEE_BPS, "exactly 1 % is a route");
    }

    /// @dev For any tier with a pool: setRoute refuses it above MAX_ROUTE_FEE_TIER, and otherwise routeFeeBps is the
    ///      tier / 100 rounded up and never above MAX_ROUTE_FEE_BPS, the most the Clearinghouse counts.
    function testFuzz_setRoute_feeTierCeiling(uint24 tier) public {
        vm.assume(tier != 0);
        factory.setPool(address(tsla), address(usdg), tier, tslaPool);
        vm.prank(admin);
        if (tier > V2Constants.MAX_ROUTE_FEE_TIER) {
            vm.expectRevert(V2Errors.CeilingExceeded.selector);
            adapter.setRoute(address(tsla), tier);
            assertEq(adapter.routeFeeBps(address(tsla)), 0, "no route");
        } else {
            adapter.setRoute(address(tsla), tier);
            uint16 bps = adapter.routeFeeBps(address(tsla));
            assertEq(uint256(bps), (uint256(tier) + 99) / 100);
            assertLe(bps, V2Constants.MAX_ROUTE_FEE_BPS);
        }
    }

    function test_routeFeeBps_zeroWithoutRoute() public {
        assertEq(adapter.routeFeeBps(address(tsla)), 0, "never routed");
        assertEq(adapter.routeFeeBps(address(0)), 0);
        vm.prank(admin);
        adapter.setRoute(address(nvda), 3000);
        assertEq(adapter.routeFeeBps(address(nvda)), 30, "follows a tier change");
        vm.prank(admin);
        adapter.setRoute(address(nvda), 0);
        assertEq(adapter.routeFeeBps(address(nvda)), 0, "cleared");
    }

    function test_setRoute_onlyAdmin() public {
        address[4] memory outsiders = [alice, guardian, keeper, address(router)];
        for (uint256 i; i < outsiders.length; ++i) {
            vm.prank(outsiders[i]);
            vm.expectRevert(V2Errors.NotAuthorized.selector);
            adapter.setRoute(address(tsla), 3000);
            vm.prank(outsiders[i]);
            vm.expectRevert(V2Errors.NotAuthorized.selector);
            adapter.setRoute(address(nvda), 0);
        }
    }

    function test_setRoute_rejectsZeroAndUsdg() public {
        vm.startPrank(admin);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        adapter.setRoute(address(0), 500);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        adapter.setRoute(address(usdg), 500);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        adapter.setRoute(address(usdg), 0);
        vm.stopPrank();
    }

    /// @dev A fee tier with no pool (or an asset with no pool at all) is refused at set time, and the old route stays.
    function test_setRoute_rejectsMissingPool() public {
        vm.startPrank(admin);
        vm.expectRevert(V2Errors.NoSource.selector);
        adapter.setRoute(address(nvda), 10_000);
        vm.expectRevert(V2Errors.NoSource.selector);
        adapter.setRoute(address(tsla), 500);
        vm.expectRevert(V2Errors.NoSource.selector);
        adapter.setRoute(makeAddr("unlisted"), 3000);
        vm.stopPrank();
        (address pool, uint24 fee) = adapter.routes(address(nvda));
        assertEq(pool, nvdaPool, "previous route kept");
        assertEq(fee, 500);
    }

    /// @dev Role management reverts with the shared error too, and admin rights move only through the admin.
    function test_roles_grantAndRevoke() public {
        vm.prank(alice);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        adapter.grantRole(V2Constants.DEFAULT_ADMIN_ROLE, alice);

        vm.expectEmit(true, true, true, true, address(adapter));
        emit IAccessControl.RoleGranted(V2Constants.DEFAULT_ADMIN_ROLE, carol, admin);
        vm.prank(admin);
        adapter.grantRole(V2Constants.DEFAULT_ADMIN_ROLE, carol);
        vm.prank(carol);
        adapter.setRoute(address(tsla), 3000);

        vm.prank(admin);
        adapter.revokeRole(V2Constants.DEFAULT_ADMIN_ROLE, carol);
        vm.prank(carol);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        adapter.setRoute(address(tsla), 0);
    }

    /// @dev GUARDIAN_ROLE (or any other role) grants no power here: routes are the only privileged surface.
    function test_roles_otherRolesHaveNoPower() public {
        vm.prank(admin);
        adapter.grantRole(V2Constants.GUARDIAN_ROLE, guardian);
        vm.prank(guardian);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        adapter.setRoute(address(nvda), 0);
    }

    /*//////////////////////////////////////////////////////////////
                              SWAP: SUCCESS
    //////////////////////////////////////////////////////////////*/

    function test_swap_exactPull_paysRecipient_leavesNothing() public {
        uint256 aliceNvda = nvda.balanceOf(alice);
        uint256 bobUsdg = usdg.balanceOf(bob);
        uint256 routerNvda = nvda.balanceOf(address(router));

        uint256 out = _swap(AMOUNT, MIN_OUT, bob);

        assertEq(out, FAIR, "returns the measured output");
        assertEq(usdg.balanceOf(bob) - bobUsdg, FAIR, "recipient got the USDG");
        assertEq(aliceNvda - nvda.balanceOf(alice), AMOUNT, "pulled exactly amountIn from the caller");
        assertEq(nvda.balanceOf(address(router)) - routerNvda, AMOUNT, "the router consumed all of it");
        _assertNothingLeft();

        IUniV3SwapRouter02.ExactInputSingleParams memory p = router.lastParams();
        assertEq(router.calls(), 1);
        assertEq(p.tokenIn, address(nvda));
        assertEq(p.tokenOut, address(usdg));
        assertEq(p.fee, 500);
        assertEq(p.recipient, bob, "USDG goes straight to the recipient");
        assertEq(p.amountIn, AMOUNT);
        assertEq(p.amountOutMinimum, MIN_OUT, "the router's minimum is minOut");
        assertEq(p.sqrtPriceLimitX96, 0, "no price limit: the floor is minOut");
    }

    /// @dev Output exactly at the minimum is accepted (>=).
    function test_swap_exactlyMinOut() public {
        assertEq(_swap(AMOUNT, FAIR, carol), FAIR);
    }

    /// @dev No caller restriction: anyone swaps its own tokens, including to itself.
    function test_swap_anyCallerAnyRecipient() public {
        vm.startPrank(mm);
        nvda.approve(address(adapter), AMOUNT);
        uint256 before = usdg.balanceOf(mm);
        assertEq(adapter.swapToUsdg(address(nvda), AMOUNT, MIN_OUT, mm), FAIR);
        vm.stopPrank();
        assertEq(usdg.balanceOf(mm) - before, FAIR);
        _assertNothingLeft();
    }

    /// @dev Tokens sent to the adapter directly neither brick it nor get swept into a caller's swap: every check is a
    ///      delta, so the donation just stays.
    function test_swap_donationNotSweptAndNotBlocking() public {
        nvda.mint(address(adapter), 5e18);
        usdg.mint(address(adapter), 1_000e6);
        uint256 bobUsdg = usdg.balanceOf(bob);
        assertEq(_swap(AMOUNT, MIN_OUT, bob), FAIR);
        assertEq(usdg.balanceOf(bob) - bobUsdg, FAIR, "recipient got the swap, not the donation");
        assertEq(nvda.balanceOf(address(adapter)), 5e18, "stock donation untouched");
        assertEq(usdg.balanceOf(address(adapter)), 1_000e6, "USDG donation untouched");
        assertEq(router.lastParams().amountIn, AMOUNT, "only amountIn was sold");
    }

    /*//////////////////////////////////////////////////////////////
                            SWAP: MIN OUTPUT
    //////////////////////////////////////////////////////////////*/

    /// @dev One base unit under the minimum: the router's own check reverts, with its own string.
    function test_swap_belowMinOut_routerReverts() public {
        router.setRateBps(9_899);
        assertLt(router.quote(address(nvda), AMOUNT), MIN_OUT);
        vm.prank(alice);
        vm.expectRevert(bytes("Too little received"));
        adapter.swapToUsdg(address(nvda), AMOUNT, MIN_OUT, bob);
    }

    /// @dev A router that ignores amountOutMinimum still cannot deliver less: the adapter measures the recipient.
    function test_swap_belowMinOut_adapterCatchesBrokenRouter() public {
        router.setMode(MockPayoutSwapRouter.Mode.IgnoreMinOut);
        router.setRateBps(5_000);
        vm.prank(alice);
        vm.expectRevert(V2Errors.BadPrice.selector);
        adapter.swapToUsdg(address(nvda), AMOUNT, MIN_OUT, bob);
    }

    /// @dev The output landing anywhere but the recipient counts as nothing received.
    function test_swap_outputElsewhere_reverts() public {
        router.setMode(MockPayoutSwapRouter.Mode.PayElsewhere);
        router.setElsewhere(carol);
        vm.prank(alice);
        vm.expectRevert(V2Errors.BadPrice.selector);
        adapter.swapToUsdg(address(nvda), AMOUNT, MIN_OUT, bob);
    }

    function test_swap_zeroMinOut_reverts() public {
        vm.prank(alice);
        vm.expectRevert(V2Errors.BadPrice.selector);
        adapter.swapToUsdg(address(nvda), AMOUNT, 0, bob);
    }

    /*//////////////////////////////////////////////////////////////
                       SWAP: ROUTE, AMOUNTS, RECIPIENT
    //////////////////////////////////////////////////////////////*/

    function test_swap_noRoute_reverts() public {
        vm.startPrank(alice);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        adapter.swapToUsdg(address(tsla), AMOUNT, 1, bob);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        adapter.swapToUsdg(address(usdg), 1e6, 1, bob);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        adapter.swapToUsdg(makeAddr("unlisted"), AMOUNT, 1, bob);
        vm.stopPrank();
        assertEq(router.calls(), 0);
    }

    /// @dev amountIn == 0 is SwapRouter02's CONTRACT_BALANCE sentinel (sell the router's own balance): never forwarded.
    function test_swap_zeroAmount_reverts() public {
        vm.prank(alice);
        vm.expectRevert(V2Errors.BadUnits.selector);
        adapter.swapToUsdg(address(nvda), 0, 1, bob);
    }

    /// @dev address(0), the router's MSG_SENDER / ADDRESS_THIS sentinels, the adapter and the router are refused.
    function test_swap_badRecipients_revert() public {
        address[5] memory bad = [address(0), address(1), address(2), address(adapter), address(router)];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(V2Errors.NotAuthorized.selector);
            adapter.swapToUsdg(address(nvda), AMOUNT, MIN_OUT, bad[i]);
        }
        assertEq(router.calls(), 0);
    }

    /// @dev A pool that runs out of liquidity fills partially and the router does not object; the adapter does, so no
    ///      part of a payout can be stranded here.
    function test_swap_partialFill_reverts() public {
        router.setMode(MockPayoutSwapRouter.Mode.Partial);
        vm.prank(alice);
        vm.expectRevert(V2Errors.BadUnits.selector);
        adapter.swapToUsdg(address(nvda), AMOUNT, 1, bob);
    }

    /// @dev A token that delivers less than amountIn (transfer tax) fails the measured pull.
    function test_swap_shortPull_reverts() public {
        MockPayoutTaxToken taxed = new MockPayoutTaxToken(100);
        factory.setPool(address(taxed), address(usdg), 500, makeAddr("TAX/USDG"));
        router.setPrice(address(taxed), NVDA_SPOT);
        vm.prank(admin);
        adapter.setRoute(address(taxed), 500);
        taxed.mint(alice, AMOUNT);
        vm.startPrank(alice);
        taxed.approve(address(adapter), AMOUNT);
        vm.expectRevert(V2Errors.BadUnits.selector);
        adapter.swapToUsdg(address(taxed), AMOUNT, 1, bob);
        vm.stopPrank();
    }

    function test_swap_callerWithoutAllowanceOrBalance_reverts() public {
        vm.prank(bob); // bob never approved the adapter
        vm.expectRevert();
        adapter.swapToUsdg(address(nvda), AMOUNT, MIN_OUT, bob);

        vm.prank(treasury); // no NVDA at all
        nvda.approve(address(adapter), AMOUNT);
        vm.prank(treasury);
        vm.expectRevert();
        adapter.swapToUsdg(address(nvda), AMOUNT, MIN_OUT, treasury);
    }

    function test_swap_routerReverts_bubbles() public {
        router.setMode(MockPayoutSwapRouter.Mode.Revert);
        vm.prank(alice);
        vm.expectRevert(MockPayoutSwapRouter.MockRouterReverted.selector);
        adapter.swapToUsdg(address(nvda), AMOUNT, MIN_OUT, bob);
    }

    /// @dev USDG refusing the recipient (frozen) fails the swap as a whole: the Clearinghouse then pays in kind.
    function test_swap_recipientFrozenForUsdg_reverts() public {
        usdg.freeze(bob);
        vm.prank(alice);
        vm.expectRevert(MockERC20.AddressFrozen.selector);
        adapter.swapToUsdg(address(nvda), AMOUNT, MIN_OUT, bob);
    }

    /*//////////////////////////////////////////////////////////////
                               REENTRANCY
    //////////////////////////////////////////////////////////////*/

    /// @dev From inside the router call, both entry points are locked; the outer swap still completes.
    function test_swap_reentryBlocked() public {
        bytes[2] memory attacks = [
            abi.encodeCall(adapter.swapToUsdg, (address(nvda), 1e18, 1, address(router))),
            abi.encodeCall(adapter.setRoute, (address(nvda), 0))
        ];
        router.setMode(MockPayoutSwapRouter.Mode.Reenter);
        for (uint256 i; i < attacks.length; ++i) {
            uint256 snap = vm.snapshotState();
            router.setReenter(address(adapter), attacks[i]);
            assertEq(_swap(AMOUNT, MIN_OUT, bob), FAIR, "outer swap completed");
            assertTrue(router.reenterAttempted());
            assertFalse(router.reenterSucceeded(), "re-entry failed");
            assertEq(bytes4(router.reenterRevertData()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
            (, uint24 fee) = adapter.routes(address(nvda));
            assertEq(fee, 500, "route untouched");
            _assertNothingLeft();
            vm.revertToState(snap);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                   FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev Any size and rate: the swap succeeds iff the quote meets minOut, pays exactly the quote, and leaves nothing
    ///      behind; otherwise it reverts and nothing moves.
    function testFuzz_swap_allOrNothing(uint256 amountIn, uint256 rateBps, uint256 slippageBps) public {
        // From 1e12 base units (0.22 USDG of NVDA) up, so minOut is never 0 (which the adapter refuses outright).
        amountIn = bound(amountIn, 1e12, 1_000e18);
        rateBps = bound(rateBps, 5_000, 12_000);
        slippageBps = bound(slippageBps, 0, V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS);
        uint256 fair = router.quote(address(nvda), amountIn);
        uint256 minOut = fair * (V2Constants.BPS - slippageBps) / V2Constants.BPS;
        router.setRateBps(rateBps);
        uint256 quoted = router.quote(address(nvda), amountIn);

        uint256 aliceNvda = nvda.balanceOf(alice);
        uint256 bobUsdg = usdg.balanceOf(bob);
        vm.prank(alice);
        if (quoted < minOut) {
            vm.expectRevert(bytes("Too little received"));
            adapter.swapToUsdg(address(nvda), amountIn, minOut, bob);
            assertEq(nvda.balanceOf(alice), aliceNvda);
            assertEq(usdg.balanceOf(bob), bobUsdg);
        } else {
            uint256 out = adapter.swapToUsdg(address(nvda), amountIn, minOut, bob);
            assertEq(out, quoted);
            assertGe(out, minOut);
            assertEq(usdg.balanceOf(bob) - bobUsdg, quoted);
            assertEq(aliceNvda - nvda.balanceOf(alice), amountIn);
        }
        _assertNothingLeft();
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _swap(uint256 amountIn, uint256 minOut, address to) internal returns (uint256) {
        vm.prank(alice);
        return adapter.swapToUsdg(address(nvda), amountIn, minOut, to);
    }

    function _assertNothingLeft() internal view {
        assertEq(nvda.balanceOf(address(adapter)), 0, "adapter holds no stock");
        assertEq(usdg.balanceOf(address(adapter)), 0, "adapter holds no USDG");
        assertEq(nvda.allowance(address(adapter), address(router)), 0, "no router allowance left");
    }
}
