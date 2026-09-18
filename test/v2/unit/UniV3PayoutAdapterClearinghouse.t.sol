// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ClearinghouseTestBase} from "./ClearinghouseBase.t.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {MockPayoutSwapRouter} from "../../../src/v2/mocks/MockPayoutSwapRouter.sol";
import {MockPayoutV3Factory} from "../../../src/v2/mocks/MockPayoutV3Factory.sol";
import {UniV3PayoutAdapter} from "../../../src/v2/periphery/UniV3PayoutAdapter.sol";

/// @notice The real Clearinghouse (C2-05) converting ITM call payouts through the real UniV3PayoutAdapter over a mock
///         SwapRouter02: a good rate pays USDG end to end, and every way the swap can go wrong (bad rate, a router that
///         ignores the minimum, a partial fill, no route, a cleared route) pays in kind.
/// @dev Same series as ClearinghousePayoutTest: NVDA call K = 240 settled at P = 250, bob holds 100 units, owed 3.75e16
///      NVDA base units worth 9.375 USDG, minOut 9_276_562 under the 100 bps bound above the 0.05 % route's 5 bps fee
///      (INTERFACE_VERSION 6). The router quotes NVDA at 250.00 and TSLA at 380.00; the adapter routes NVDA only. The
///      base fixture's MockPayoutAdapter is replaced on the Clearinghouse by the real adapter.
contract UniV3PayoutAdapterClearinghouseTest is ClearinghouseTestBase {
    UniV3PayoutAdapter internal uniAdapter;
    MockPayoutSwapRouter internal router;
    MockPayoutV3Factory internal factory;

    uint256 internal callId;
    uint256 internal tslaCallId;

    uint256 internal constant P = 250e6;
    uint256 internal constant OWED = 3.75e16;
    uint256 internal constant VALUE = 9_375_000;
    /// @dev VALUE less 105 bps: the 100 bps bound plus the 5 bps fee of the NVDA route.
    uint256 internal constant MIN_OUT = 9_276_562;

    uint256 internal constant TSLA_P = 380e6;

    function _deployCore() internal override {
        super._deployCore();
        factory = new MockPayoutV3Factory();
        factory.setPool(address(nvda), address(usdg), 500, makeAddr("NVDA/USDG 0.05%"));
        factory.setPool(address(tsla), address(usdg), 3000, makeAddr("TSLA/USDG 0.30%"));
        router = new MockPayoutSwapRouter(address(factory));
        router.setPrice(address(nvda), P);
        router.setPrice(address(tsla), TSLA_P);
        usdg.mint(address(router), 1_000_000e6);
        uniAdapter = new UniV3PayoutAdapter(admin, address(usdg), address(router));
        vm.label(address(uniAdapter), "UniV3PayoutAdapter");
        vm.label(address(router), "MockPayoutSwapRouter");

        vm.startPrank(admin);
        uniAdapter.setRoute(address(nvda), 500);
        ch.setPayoutAdapter(address(uniAdapter), SLIPPAGE_BPS);
        vm.stopPrank();
    }

    function setUp() public override {
        super.setUp();
        callId = _call(K_240, FRI_2026_09_18);
        tslaCallId = ch.createSeries(address(tsla), false, 350_000_000, FRI_2026_09_18);
        _write(alice, callId, 100, bob);
        _write(carol, callId, 50, carol);
        _write(alice, tslaCallId, 100, bob);
        _settle(callId, P);
        _settle(tslaCallId, TSLA_P);
    }

    /*//////////////////////////////////////////////////////////////
                                 SUCCESS
    //////////////////////////////////////////////////////////////*/

    function test_redeem_itmCallLong_paysUsdgThroughAdapter() public {
        uint256 chNvda = nvda.balanceOf(address(ch));
        uint256 chUsdg = usdg.balanceOf(address(ch));
        uint256 routerNvda = nvda.balanceOf(address(router));
        vm.expectEmit(true, true, false, true, address(ch));
        emit IClearinghouse.Redeemed(callId, bob, bob, 100, address(usdg), VALUE, OWED, false);
        (uint256 paid, bool inUsdg) = _redeem(callId, bob);

        assertTrue(inUsdg, "converted");
        assertEq(paid, VALUE);
        assertEq(usdg.balanceOf(bob), ACTOR_USDG + VALUE, "holder received USDG");
        assertEq(nvda.balanceOf(bob), ACTOR_SHARES, "and no Stock Tokens");
        assertEq(chNvda - nvda.balanceOf(address(ch)), OWED, "Clearinghouse gave up exactly the payout");
        assertEq(nvda.balanceOf(address(router)) - routerNvda, OWED, "all of it was sold");
        _assertAdapterEmpty();

        assertEq(router.calls(), 1);
        assertEq(router.lastParams().fee, 500);
        assertEq(router.lastParams().recipient, address(ch), "router pays the Clearinghouse (sweep contracts-c30)");
        assertEq(usdg.balanceOf(address(ch)), chUsdg, "which sends all of it on to the holder");
        assertEq(router.lastParams().amountIn, OWED);
        assertEq(router.lastParams().amountOutMinimum, MIN_OUT, "the Clearinghouse's minOut reaches the pool");
        assertEq(ch.accruedFees(address(nvda)), 2.5e15, "exercise fee stays in kind");
    }

    function test_redeemBatch_convertsThroughAdapter() public {
        address[] memory holders = new address[](2);
        holders[0] = bob;
        holders[1] = carol;
        vm.prank(keeper);
        assertEq(ch.redeemBatch(callId, holders), 2);
        assertEq(usdg.balanceOf(bob), ACTOR_USDG + VALUE, "bob converted inside the batch");
        assertEq(usdg.balanceOf(carol), ACTOR_USDG + VALUE / 2, "carol too");
        assertEq(router.calls(), 2);
        _assertAdapterEmpty();
    }

    function test_redeem_toLedger_creditsUsdg() public {
        vm.prank(bob);
        ch.setPayoutToLedger(true);
        uint256 chUsdg = usdg.balanceOf(address(ch));
        (uint256 paid, bool inUsdg) = _redeem(callId, bob);
        assertTrue(inUsdg);
        assertEq(paid, VALUE);
        assertEq(router.lastParams().recipient, address(ch), "USDG comes to the Clearinghouse");
        assertEq(ch.free(bob, address(usdg)), VALUE, "credited as USDG");
        assertEq(usdg.balanceOf(address(ch)) - chUsdg, VALUE);
        _assertAdapterEmpty();
    }

    /// @dev 50 bps under fair is inside the 100 bps bound.
    function test_redeem_withinSlippage_paysUsdg() public {
        router.setRateBps(9_950);
        (uint256 paid, bool inUsdg) = _redeem(callId, bob);
        assertTrue(inUsdg);
        assertEq(paid, 9_328_125);
    }

    /// @dev The floor follows the route's fee tier: 104 bps short converts through NVDA's 0.05 % route (floor 105 bps),
    ///      and TSLA routed through its 0.30 % pool converts 125 bps short (floor 130 bps) while 131 bps short pays in
    ///      kind. The adapter's routeFeeBps is what the Clearinghouse adds (INTERFACE_VERSION 6).
    function test_redeem_floorFollowsTheRouteFee() public {
        assertEq(MIN_OUT, VALUE * (10_000 - SLIPPAGE_BPS - 5) / 10_000);
        assertEq(uniAdapter.routeFeeBps(address(nvda)), 5);
        assertEq(uniAdapter.routeFeeBps(address(tsla)), 0, "no TSLA route yet");
        uint256 snap = vm.snapshotState();
        router.setRateBps(9_896);
        (uint256 paid, bool inUsdg) = _redeem(callId, bob);
        assertTrue(inUsdg, "104 bps short converts through the 0.05 % route");
        assertEq(paid, 9_277_500);
        vm.revertToState(snap);

        vm.prank(admin);
        uniAdapter.setRoute(address(tsla), 3000);
        assertEq(uniAdapter.routeFeeBps(address(tsla)), 30);
        uint256 owed = 100 * uint256(ch.series(tslaCallId).longPayoutPerUnit);
        uint256 value = owed * TSLA_P / 1e18;
        uint256 floor = value * (10_000 - SLIPPAGE_BPS - 30) / 10_000;

        snap = vm.snapshotState();
        router.setRateBps(9_869);
        assertLt(router.quote(address(tsla), owed), floor);
        _assertInKind(tslaCallId, IERC20(address(tsla)), owed);
        vm.revertToState(snap);

        router.setRateBps(9_875);
        (paid, inUsdg) = _redeem(tslaCallId, bob);
        assertTrue(inUsdg, "125 bps short converts through the 0.30 % route");
        assertEq(router.lastParams().fee, 3000);
        assertEq(router.lastParams().amountOutMinimum, floor, "minOut = value less 100 + 30 bps");
        assertEq(paid, router.quote(address(tsla), owed));
        assertLe(value - paid, (value * (SLIPPAGE_BPS + 30) + 9_999) / 10_000, "captured <= bound + route fee");
    }

    /// @dev At the 30 bps launch bound the floor per Uniswap fee tier is 35 bps (0.05 %), 60 bps (0.30 %) and 130 bps
    ///      (1 %) below value: a rate exactly at the floor converts with that amountOutMinimum, one bps lower pays in
    ///      kind.
    function test_redeem_launchBoundFloorPerFeeTier() public {
        uint24[3] memory fees = [uint24(500), 3000, 10_000];
        uint256[3] memory floorBps = [uint256(35), 60, 130];
        for (uint256 i; i < fees.length; ++i) {
            uint256 snap = vm.snapshotState();
            factory.setPool(address(nvda), address(usdg), fees[i], makeAddr("NVDA/USDG tier"));
            vm.startPrank(admin);
            ch.setPayoutAdapter(address(uniAdapter), 30);
            uniAdapter.setRoute(address(nvda), fees[i]);
            vm.stopPrank();
            uint256 floor = VALUE * (10_000 - floorBps[i]) / 10_000;

            uint256 inner = vm.snapshotState();
            router.setRateBps(10_000 - floorBps[i] - 1);
            _assertInKind(callId, IERC20(address(nvda)), OWED);
            vm.revertToState(inner);

            router.setRateBps(10_000 - floorBps[i]);
            (uint256 paid, bool inUsdg) = _redeem(callId, bob);
            assertTrue(inUsdg, "converts at the fee-aware floor");
            assertEq(router.lastParams().fee, fees[i]);
            assertEq(router.lastParams().amountOutMinimum, floor, "minOut = value less 30 bps + the route fee");
            assertEq(paid, floor);
            vm.revertToState(snap);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           FAILURES -> IN KIND
    //////////////////////////////////////////////////////////////*/

    /// @dev The bad-rate case: the pool would pay 106 bps under settlement value, beyond the 100 bps bound above the
    ///      route's 5 bps fee; the router's minimum (minOut from the Clearinghouse) reverts the swap, and the holder
    ///      gets the Stock Token.
    function test_redeem_badRate_fallsBackInKind() public {
        router.setRateBps(9_894);
        assertLt(router.quote(address(nvda), OWED), MIN_OUT);
        _assertInKind(callId, IERC20(address(nvda)), OWED);
    }

    /// @dev A router that ignores its minimum: the adapter's own measurement reverts, and the Clearinghouse would have
    ///      caught it anyway.
    function test_redeem_routerIgnoresMinimum_fallsBackInKind() public {
        router.setMode(MockPayoutSwapRouter.Mode.IgnoreMinOut);
        router.setRateBps(9_000);
        _assertInKind(callId, IERC20(address(nvda)), OWED);
    }

    function test_redeem_partialFill_fallsBackInKind() public {
        router.setMode(MockPayoutSwapRouter.Mode.Partial);
        _assertInKind(callId, IERC20(address(nvda)), OWED);
    }

    function test_redeem_routerReverts_fallsBackInKind() public {
        router.setMode(MockPayoutSwapRouter.Mode.Revert);
        _assertInKind(callId, IERC20(address(nvda)), OWED);
    }

    /// @dev TSLA has a pool but no route on the adapter: its ITM call long is paid in TSLA.
    function test_redeem_noRoute_paysInKind() public {
        (, uint24 fee) = uniAdapter.routes(address(tsla));
        assertEq(fee, 0, "no TSLA route");
        _assertInKind(tslaCallId, IERC20(address(tsla)), 100 * uint256(ch.series(tslaCallId).longPayoutPerUnit));
        assertEq(router.calls(), 0, "never reached the router");
    }

    /// @dev Clearing NVDA's route switches that market to in kind; setting it again restores conversion.
    function test_redeem_routeCleared_paysInKind_thenRestored() public {
        vm.prank(admin);
        uniAdapter.setRoute(address(nvda), 0);
        _assertInKind(callId, IERC20(address(nvda)), OWED);

        vm.prank(admin);
        uniAdapter.setRoute(address(nvda), 500);
        (uint256 paid, bool inUsdg) = _redeem(callId, carol);
        assertTrue(inUsdg, "carol converts again");
        assertEq(paid, VALUE / 2);
    }

    function test_gas_redeemConvertedThroughUniV3Adapter() public {
        vm.prank(admin);
        ch.setKeeperRewards(address(0));
        vm.prank(keeper);
        uint256 g = gasleft();
        ch.redeem(callId, bob);
        g -= gasleft();
        console2.log("gas: redeem call long converted via UniV3PayoutAdapter + mock router, no bounty", g);
        assertEq(usdg.balanceOf(bob), ACTOR_USDG + VALUE);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _assertAdapterEmpty() internal view {
        assertEq(nvda.balanceOf(address(uniAdapter)), 0, "adapter holds no NVDA");
        assertEq(usdg.balanceOf(address(uniAdapter)), 0, "adapter holds no USDG");
        assertEq(nvda.allowance(address(ch), address(uniAdapter)), 0, "Clearinghouse approval zeroed");
        assertEq(nvda.allowance(address(uniAdapter), address(router)), 0, "no router allowance left");
    }

    function _assertInKind(uint256 longId, IERC20 asset, uint256 owed) internal {
        uint256 bobUsdg = usdg.balanceOf(bob);
        uint256 bobAsset = asset.balanceOf(bob);
        vm.recordLogs();
        (uint256 paid, bool inUsdg) = _redeem(longId, bob);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertFalse(inUsdg, "fell back to in kind");
        assertEq(paid, owed);
        assertEq(asset.balanceOf(bob) - bobAsset, owed, "Stock Tokens delivered");
        assertEq(usdg.balanceOf(bob), bobUsdg, "no USDG");
        assertEq(asset.balanceOf(address(uniAdapter)), 0, "adapter kept nothing");
        assertEq(asset.allowance(address(ch), address(uniAdapter)), 0, "no approval left");
        assertEq(asset.allowance(address(uniAdapter), address(router)), 0, "no router approval left");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(ch) && logs[i].topics[0] == IClearinghouse.Redeemed.selector) {
                (address to,, address delivered, uint256 amount, uint256 inKind, bool toLedger) =
                    abi.decode(logs[i].data, (address, uint64, address, uint256, uint256, bool));
                assertEq(to, bob);
                assertEq(delivered, address(asset));
                assertEq(amount, owed);
                assertEq(inKind, owed);
                assertFalse(toLedger);
                found = true;
            }
        }
        assertTrue(found, "Redeemed logged");
    }
}
