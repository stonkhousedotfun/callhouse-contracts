// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AutoRollerTestBase} from "./AutoRollerBase.t.sol";
import {AutoRoller} from "../../../src/v2/AutoRoller.sol";
import {IAutoRoller} from "../../../src/v2/interfaces/IAutoRoller.sol";
import {IKeeperRewards} from "../../../src/v2/interfaces/IKeeperRewards.sol";
import {IOrderBook} from "../../../src/v2/interfaces/IOrderBook.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";

/// @notice Strategy bounds, stop, one roll per period, the writer's approvals, pauses, reprice, bounties and admin.
contract AutoRollerStrategyTest is AutoRollerTestBase {
    /*//////////////////////////////////////////////////////////////
                                 BOUNDS
    //////////////////////////////////////////////////////////////*/

    function _expectBadStrategy(V2Types.Strategy memory s) internal {
        vm.prank(alice);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        roller.setStrategy(address(nvda), s);
    }

    function test_bounds_otm() public {
        _expectBadStrategy(_weekly(99, 150));
        _expectBadStrategy(_weekly(2501, 150));
        _setStrategy(alice, _weekly(100, 150));
        _setStrategy(alice, _weekly(2500, 150));
        assertEq(roller.strategy(alice, address(nvda)).otmBps, 2500, "stored");
    }

    function test_bounds_ask() public {
        _expectBadStrategy(_weekly(500, 4));
        _expectBadStrategy(_weekly(500, 1001));
        _setStrategy(alice, _weekly(500, 5));
        _setStrategy(alice, _weekly(500, 1000));
        assertEq(roller.strategy(alice, address(nvda)).askBps, 1000, "stored");
    }

    function test_bounds_smartPricingBand() public {
        _expectBadStrategy(_smart(4, 150, 500));
        _expectBadStrategy(_smart(151, 150, 500));
        _expectBadStrategy(_smart(50, 150, 149));
        _expectBadStrategy(_smart(50, 150, 1001));
        _setStrategy(alice, _smart(150, 150, 150));
        _setStrategy(alice, _smart(5, 150, 1000));

        // Without smart pricing the band is never read, so it is not checked.
        V2Types.Strategy memory s = _weekly(500, 150);
        (s.minAskBps, s.maxAskBps) = (9000, 1);
        _setStrategy(alice, s);
    }

    function test_setStrategy_unregisteredMarket_reverts() public {
        vm.prank(alice);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        roller.setStrategy(address(tsla), _weekly(500, 150));
    }

    function test_setStrategy_activatesAndEmits() public {
        V2Types.Strategy memory s = _smart(50, 150, 500);
        s.active = false;
        s.maxUnits = 250;
        V2Types.Strategy memory stored = s;
        stored.active = true;
        vm.expectEmit(address(roller));
        emit IAutoRoller.StrategySet(alice, address(nvda), stored);
        _setStrategy(alice, s);
        V2Types.Strategy memory got = roller.strategy(alice, address(nvda));
        assertTrue(got.active, "setting a strategy activates it");
        assertTrue(got.weekly && got.smartPricing, "flags");
        assertEq(got.minAskBps, 50, "min");
        assertEq(got.maxAskBps, 500, "max");
        assertEq(got.maxUnits, 250, "maxUnits");
        V2Types.Strategy memory none = roller.strategy(bob, address(nvda));
        assertFalse(none.active, "never set: all zero");
        assertEq(none.otmBps, 0, "never set: all zero");
    }

    function test_maxUnits_capsSize() public {
        V2Types.Strategy memory s = _weekly(500, 150);
        s.maxUnits = 250;
        _setStrategy(alice, s);
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        assertEq(_mustRoll(alice).units, 250, "capped");
    }

    function test_noFreeCollateral_noRoll() public {
        _setStrategy(alice, _weekly(500, 150));
        vm.prank(alice);
        ch.withdraw(address(nvda), WRITER_SHARES - 0.009e18, alice);
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        _noRoll(alice, "0.9 of a unit free: nothing to write");
    }

    /// A new strategy keeps the live ask; its terms apply from the next period.
    function test_setStrategy_midPeriod_keepsLiveAsk() public {
        _setStrategy(alice, _weekly(500, 150));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        Rolled memory r = _mustRoll(alice);
        _setStrategy(alice, _weekly(1000, 300));
        V2Types.Order memory o = _order(r.orderId);
        assertFalse(o.cancelled, "ask still live");
        assertEq(o.price, P_3_30, "old price");
        _noRoll(alice, "same period");
    }

    /*//////////////////////////////////////////////////////////////
                           ONE ROLL PER PERIOD
    //////////////////////////////////////////////////////////////*/

    function test_doubleRoll_samePeriod_isNoop() public {
        _setStrategy(alice, _weekly(500, 150));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        _mustRoll(alice);
        _noRoll(alice, "immediately again");
        _spotAt(_ny(FRI_0911, 10, 0, 0), 240_00000000);
        _noRoll(alice, "next morning, still this period, even after a big move");
        assertEq(usdg.balanceOf(keeper), ROLL_BOUNTY, "one bounty");
    }

    /*//////////////////////////////////////////////////////////////
                                  STOP
    //////////////////////////////////////////////////////////////*/

    function test_stop_cancelsLiveAsk() public {
        _setStrategy(alice, _weekly(500, 150));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        Rolled memory r = _mustRoll(alice);

        vm.expectEmit(address(roller));
        emit IAutoRoller.StrategyStopped(alice, address(nvda));
        vm.expectEmit(address(book));
        emit IOrderBook.OrderCancelled(r.orderId, 1000, false);
        vm.prank(alice);
        roller.stop(address(nvda));

        assertTrue(_order(r.orderId).cancelled, "ask cancelled");
        assertFalse(roller.strategy(alice, address(nvda)).active, "inactive");
        (uint256 longId, uint256 orderId, uint40 expiry) = roller.position(alice, address(nvda));
        assertEq(longId, r.longId, "series kept for the close-out");
        assertEq(orderId, 0, "no ask tracked");
        assertEq(expiry, FRI_2026_09_11, "expiry kept");
        assertEq(_buy(bob, r.longId, r.orderId, 100), 0, "nothing to buy");
        _noRoll(alice, "stopped");

        // After expiry the stopped strategy is still closed out, but never rolled again.
        vm.warp(uint256(FRI_2026_09_11) + 1);
        (bool advanced, uint256 count,) = _roll(keeper, alice);
        assertTrue(advanced && count == 0, "closed out, not rolled");
        _spotAt(_ny(MON_0914, 10, 0, 0), 220_00000000);
        _noRoll(alice, "inactive");
    }

    /// Paused and resumed inside a period: the next roll is the next period's.
    function test_stop_thenResume_rollsNextPeriod() public {
        _setStrategy(alice, _weekly(500, 150));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        _mustRoll(alice);
        vm.prank(alice);
        roller.stop(address(nvda));
        _setStrategy(alice, _weekly(500, 150));
        _noRoll(alice, "resumed in the same period");

        vm.warp(uint256(FRI_2026_09_11) + 1);
        _roll(keeper, alice);
        _spotAt(_ny(MON_0914, 10, 0, 0), 220_00000000);
        assertEq(_mustRoll(alice).expiry, FRI_2026_09_18, "next period");
        assertEq(usdg.balanceOf(keeper), 2 * ROLL_BOUNTY, "one bounty per period");
    }

    /// The writer revoked the roller as delegate first: stop still deactivates; the ask stays tracked for the writer.
    function test_stop_withoutDelegate_stillStops() public {
        _setStrategy(alice, _weekly(500, 150));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        Rolled memory r = _mustRoll(alice);
        vm.startPrank(alice);
        book.setDelegate(address(roller), false);
        roller.stop(address(nvda));
        vm.stopPrank();
        assertFalse(roller.strategy(alice, address(nvda)).active, "inactive");
        assertFalse(_order(r.orderId).cancelled, "the roller could not cancel");
        (, uint256 orderId,) = roller.position(alice, address(nvda));
        assertEq(orderId, r.orderId, "still tracked");
    }

    /// A stop sent with too little gas for the cancel reverts; it never succeeds with the ask still live. The lowest gas
    /// at which a stop succeeds is what a minimum-gas estimator picks, so an out-of-gas cancel swallowed by the catch
    /// would have told the writer "stopped" while buyers could still fill the ask (sweep contracts-c20).
    function test_stop_withTooLittleGasForTheCancel_reverts() public {
        _setStrategy(alice, _weekly(500, 150));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        Rolled memory r = _mustRoll(alice);

        uint256 succeeded;
        for (uint256 g = 20_000; g <= 60_000; g += 20) {
            uint256 snap = vm.snapshotState();
            vm.prank(alice);
            (bool ok,) = address(roller).call{gas: g}(abi.encodeCall(AutoRoller.stop, (address(nvda))));
            if (ok) {
                ++succeeded;
                assertTrue(
                    _order(r.orderId).cancelled, string.concat("stopped with the ask live at gas ", vm.toString(g))
                );
                (, uint256 orderId,) = roller.position(alice, address(nvda));
                assertEq(orderId, 0, "no ask tracked");
            }
            vm.revertToState(snap);
        }
        assertGt(succeeded, 0, "the range reaches a full stop");
    }

    function test_stop_neverSet_isHarmless() public {
        vm.expectEmit(address(roller));
        emit IAutoRoller.StrategyStopped(bob, address(nvda));
        vm.prank(bob);
        roller.stop(address(nvda));
        assertFalse(roller.strategy(bob, address(nvda)).active, "inactive");
    }

    /*//////////////////////////////////////////////////////////////
                               APPROVALS
    //////////////////////////////////////////////////////////////*/

    function _assertNothingHappened() internal view {
        (uint256 longId, uint256 orderId, uint40 expiry) = roller.position(alice, address(nvda));
        assertEq(longId + orderId + expiry, 0, "no position");
        assertEq(book.lastOrderId(), 0, "no order");
        assertFalse(ch.seriesExists(ch.longIdOf(address(nvda), false, K_231, FRI_2026_09_11)), "no series");
        assertEq(usdg.balanceOf(keeper), 0, "no bounty");
    }

    function _expectRollReverts(bytes4 selector) internal {
        vm.prank(keeper);
        vm.expectRevert(selector);
        roller.roll(alice, address(nvda));
    }

    function test_revokeRollerOperator_revertsCleanly_thenResumes() public {
        _setStrategy(alice, _weekly(500, 150));
        vm.prank(alice);
        ch.setOperator(address(roller), false);
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        _expectRollReverts(V2Errors.NotAuthorized.selector);
        _assertNothingHappened();

        vm.prank(alice);
        ch.setOperator(address(roller), true);
        assertEq(_mustRoll(alice).units, 1000, "resumes");
    }

    function test_revokeBookOperator_revertsCleanly_thenResumes() public {
        _setStrategy(alice, _weekly(500, 150));
        vm.prank(alice);
        ch.setOperator(address(book), false);
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        _expectRollReverts(V2Errors.NotAuthorized.selector);
        _assertNothingHappened();

        vm.prank(alice);
        ch.setOperator(address(book), true);
        _mustRoll(alice);
    }

    function test_revokeDelegate_revertsCleanly_thenResumes() public {
        _setStrategy(alice, _weekly(500, 150));
        vm.prank(alice);
        book.setDelegate(address(roller), false);
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        _expectRollReverts(V2Errors.NotAuthorized.selector);
        _assertNothingHappened();

        vm.prank(alice);
        book.setDelegate(address(roller), true);
        _mustRoll(alice);
    }

    /// Approvals are checked only when a roll would place: a keeper probing outside the session gets false, not a revert.
    function test_revoked_outsideSession_returnsFalse() public {
        _setStrategy(alice, _weekly(500, 150));
        vm.prank(alice);
        ch.setOperator(address(roller), false);
        _spotAt(_ny(THU_0910, 8, 0, 0), 220_00000000);
        _noRoll(alice, "not due");
    }

    /// A writer who revokes mid-period keeps the ask (the book still mints while it is operator); nothing reverts until
    /// the next period would be placed.
    function test_revokeMidPeriod_closeOutThenReverts() public {
        _setStrategy(alice, _weekly(500, 150));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        _mustRoll(alice);
        vm.prank(alice);
        ch.setOperator(address(roller), false);
        _noRoll(alice, "period already rolled");

        vm.warp(uint256(FRI_2026_09_11) + 1);
        (bool advanced,,) = _roll(keeper, alice);
        assertTrue(advanced, "unfilled close-out needs no approval");
        vm.warp(_ny(MON_0914, 10, 0, 0));
        feed.push(220_00000000, _ny(MON_0914, 10, 0, 0));
        _expectRollReverts(V2Errors.NotAuthorized.selector);
    }

    /*//////////////////////////////////////////////////////////////
                                 PAUSES
    //////////////////////////////////////////////////////////////*/

    function test_mintPaused_reverts() public {
        _setStrategy(alice, _weekly(500, 150));
        vm.prank(guardian);
        ch.setMintPaused(address(nvda), true);
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        _expectRollReverts(V2Errors.MintPaused.selector);
        vm.prank(guardian);
        ch.setMintPaused(address(nvda), false);
        _mustRoll(alice);
    }

    function test_marketDisabled_reverts() public {
        _setStrategy(alice, _weekly(500, 150));
        V2Types.MarketConfig memory m = ch.market(address(nvda));
        m.enabled = false;
        vm.prank(admin);
        ch.setMarketConfig(address(nvda), m);
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        _expectRollReverts(V2Errors.MarketDisabled.selector);
    }

    function test_createPaused_reverts() public {
        _setStrategy(alice, _weekly(500, 150));
        vm.prank(guardian);
        ch.setCreatePaused(true);
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        _expectRollReverts(V2Errors.CreatePaused.selector);
    }

    function test_tradingPaused_reverts() public {
        _setStrategy(alice, _weekly(500, 150));
        vm.prank(guardian);
        book.setTradingPaused(true);
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        _expectRollReverts(V2Errors.TradingPaused.selector);
        _assertNothingHappened();
    }

    /*//////////////////////////////////////////////////////////////
                                REPRICE
    //////////////////////////////////////////////////////////////*/

    /// Smart pricing: band [0.5 %, 5 %] of spot 220 = [1.10, 11.00]; the roll places at 1.5 % = 3.30.
    function _rollSmart() internal returns (Rolled memory r) {
        _setStrategy(alice, _smart(50, 150, 500));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        r = _mustRoll(alice);
        vm.warp(_ny(THU_0910, 10, 30, 0));
    }

    function test_reprice_onlyPricerRole() public {
        _rollSmart();
        address[3] memory notPricers = [alice, admin, keeper];
        for (uint256 i; i < notPricers.length; ++i) {
            vm.prank(notPricers[i]);
            vm.expectRevert(V2Errors.NotAuthorized.selector);
            roller.reprice(alice, address(nvda), 4_000_000);
        }
    }

    function test_reprice_requiresSmartPricing() public {
        _setStrategy(alice, _weekly(500, 150));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        _mustRoll(alice);
        vm.prank(pricer);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        roller.reprice(alice, address(nvda), 4_000_000);
    }

    function test_reprice_requiresActiveStrategy() public {
        _rollSmart();
        vm.prank(alice);
        roller.stop(address(nvda));
        vm.prank(pricer);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        roller.reprice(alice, address(nvda), 4_000_000);
    }

    function test_reprice_noTrackedAsk_reverts() public {
        _setStrategy(alice, _smart(50, 150, 500));
        vm.prank(pricer);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.OrderNotLive.selector, uint256(0)));
        roller.reprice(alice, address(nvda), 4_000_000);
    }

    function test_reprice_bandIsInclusiveAndExact() public {
        _rollSmart();
        vm.startPrank(pricer);
        vm.expectRevert(V2Errors.BadPrice.selector);
        roller.reprice(alice, address(nvda), 1_099_900);
        vm.expectRevert(V2Errors.BadPrice.selector);
        roller.reprice(alice, address(nvda), 11_000_100);
        roller.reprice(alice, address(nvda), 1_100_000);
        roller.reprice(alice, address(nvda), 11_000_000);
        vm.stopPrank();
        (, uint256 orderId,) = roller.position(alice, address(nvda));
        assertEq(_order(orderId).price, 11_000_000, "top of the band");
    }

    function test_reprice_offTick_reverts() public {
        _rollSmart();
        vm.prank(pricer);
        vm.expectRevert(V2Errors.BadPrice.selector);
        roller.reprice(alice, address(nvda), 2_000_050);
    }

    function test_reprice_staleSpot_reverts() public {
        _rollSmart();
        uint256 printedAt = _ny(THU_0910, 10, 0, 0);
        vm.warp(printedAt + 1 hours + 1);
        // The expected value is computed first: a view call between prank and the target would consume the prank.
        vm.prank(pricer);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.StaleSpot.selector, printedAt));
        roller.reprice(alice, address(nvda), 4_000_000);
    }

    function test_reprice_replacesRemainingUnits() public {
        Rolled memory r = _rollSmart();
        _buy(bob, r.longId, r.orderId, 250);

        vm.recordLogs();
        vm.prank(pricer);
        roller.reprice(alice, address(nvda), 4_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory last = logs[logs.length - 1];
        assertEq(last.topics[0], IAutoRoller.Repriced.selector, "Repriced last");
        (uint256 oldId, uint256 newId, uint128 price) = abi.decode(last.data, (uint256, uint256, uint128));
        assertEq(oldId, r.orderId, "old id");
        assertEq(price, 4_000_000, "price");

        (, uint256 orderId,) = roller.position(alice, address(nvda));
        assertEq(orderId, newId, "position follows the new ask");
        assertTrue(_order(r.orderId).cancelled, "old ask cancelled");
        V2Types.Order memory o = _order(newId);
        assertEq(o.maker, alice, "maker");
        assertEq(o.units, 750, "remaining units");
        assertEq(o.price, 4_000_000, "new price");
        assertEq(o.validUntil, _order(r.orderId).validUntil, "same validUntil");
        assertEq(_buy(carol, r.longId, newId, 750), 750, "fillable");
    }

    function test_reprice_pastCutoff_reverts() public {
        Rolled memory r = _rollSmart();
        _spotAt(uint256(FRI_2026_09_11) - 30 minutes, 220_00000000);
        vm.prank(pricer);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.OrderNotLive.selector, r.orderId));
        roller.reprice(alice, address(nvda), 4_000_000);
    }

    function test_reprice_delegateRevoked_reverts() public {
        _rollSmart();
        vm.prank(alice);
        book.setDelegate(address(roller), false);
        vm.prank(pricer);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        roller.reprice(alice, address(nvda), 4_000_000);
    }

    /// Fixed in INTERFACE_VERSION 7 (sweep contracts-c16; this test was `test_ask_afterARally_fillsBelowIntrinsic`,
    /// where the pricer's `reprice(26.00)` — the band's top, 10 % of 260 — went through and bob bought the whole ask
    /// for 26.00 against an intrinsic of 29.00). The ask still keeps its roll-time price until the mint cutoff and
    /// {roll} still does nothing inside the period, but the pricer can no longer move an ask the spot has reached
    /// (InTheMoney) and anyone may withdraw it with {cancelStale} before a taker gets there.
    function test_ask_afterARally_cancelledBeforeItFillsBelowIntrinsic() public {
        _setStrategy(alice, _smart(50, 150, 1000));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        Rolled memory r = _mustRoll(alice);
        assertEq(r.strike, K_231, "strike 231");
        assertEq(r.price, P_3_30, "ask 3.30");

        _spotAt(_ny(THU_0910, 15, 0, 0), 260_00000000); // intrinsic 29.00
        _noRoll(alice, "the period is rolled");
        // InTheMoney sits before the band, so neither the price the band refused nor the one it allowed gets through.
        vm.startPrank(pricer);
        vm.expectRevert(V2Errors.InTheMoney.selector);
        roller.reprice(alice, address(nvda), 29_000_000); // intrinsic, above the band
        vm.expectRevert(V2Errors.InTheMoney.selector);
        roller.reprice(alice, address(nvda), 26_000_000); // the band's top, 10 % of 260, below intrinsic
        vm.stopPrank();

        vm.prank(carol);
        assertTrue(roller.cancelStale(alice, address(nvda)), "anyone withdraws it");
        assertTrue(_order(r.orderId).cancelled, "ask withdrawn");
        assertEq(_buy(bob, r.longId, r.orderId, 1000), 0, "nothing left to take below intrinsic");
        assertEq(_free(alice), WRITER_SHARES, "the writer keeps its shares and its upside");
    }

    /*//////////////////////////////////////////////////////////////
                                BOUNTIES
    //////////////////////////////////////////////////////////////*/

    function _rollRewards(Vm.Log[] memory logs) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(rewards) && logs[i].topics[0] == IKeeperRewards.Rewarded.selector
                    && logs[i].topics[2] == V2Constants.ACTION_ROLL
            ) ++n;
        }
    }

    function test_bounty_oncePerPeriod_toTheCaller() public {
        _setStrategy(alice, _weekly(500, 150));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        vm.recordLogs();
        vm.prank(carol);
        roller.roll(alice, address(nvda));
        assertEq(_rollRewards(vm.getRecordedLogs()), 1, "one ROLL reward");
        assertEq(usdg.balanceOf(carol), ACTOR_USDG + ROLL_BOUNTY, "to the caller");

        for (uint256 i; i < 3; ++i) {
            vm.recordLogs();
            vm.prank(i == 0 ? carol : keeper);
            assertFalse(roller.roll(alice, address(nvda)), "no-op");
            assertEq(_rollRewards(vm.getRecordedLogs()), 0, "no second bounty");
        }

        vm.warp(uint256(FRI_2026_09_11) + 1);
        _roll(keeper, alice);
        _spotAt(_ny(MON_0914, 10, 0, 0), 220_00000000);
        _mustRoll(alice);
        assertEq(usdg.balanceOf(keeper), ROLL_BOUNTY, "next period pays again");
    }

    function test_bounty_belowMinRollUnits_placesWithoutBounty() public {
        V2Types.Strategy memory s = _weekly(500, 150);
        s.maxUnits = 99;
        _setStrategy(alice, s);
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        assertEq(_mustRoll(alice).units, 99, "placed");
        assertEq(usdg.balanceOf(keeper), 0, "below minRollUnits: no bounty");

        _setStrategy(bob, s);
        _onboardWriter(bob, WRITER_SHARES);
        vm.prank(admin);
        roller.setMinRollUnits(99);
        _mustRoll(bob);
        assertEq(usdg.balanceOf(keeper), ROLL_BOUNTY, "at the threshold: bounty");
    }

    function test_bounty_payerFailures_neverBlockARoll() public {
        _setStrategy(alice, _weekly(500, 150));
        _setStrategy(bob, _weekly(500, 150));
        _onboardWriter(bob, WRITER_SHARES);
        vm.prank(admin);
        rewards.setCaller(address(roller), false);
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        _mustRoll(alice);
        assertEq(usdg.balanceOf(keeper), 0, "unregistered caller: reward reverts, roll does not");

        vm.prank(admin);
        roller.setKeeperRewards(address(0));
        _mustRoll(bob);
        assertEq(usdg.balanceOf(keeper), 0, "no payer set");
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_constructor_wiring() public {
        assertEq(address(roller.orderBook()), address(book), "book");
        assertEq(address(roller.clearinghouse()), address(ch), "clearinghouse from the book");
        assertEq(roller.usdg(), address(usdg), "usdg from the clearinghouse");
        assertEq(roller.minRollUnits(), roller.DEFAULT_MIN_ROLL_UNITS(), "default threshold");
        assertTrue(roller.hasRole(V2Constants.DEFAULT_ADMIN_ROLE, admin), "admin");
        assertTrue(roller.supportsInterface(type(IAutoRoller).interfaceId), "IAutoRoller");
        assertTrue(roller.supportsInterface(type(IAccessControl).interfaceId), "IAccessControl");
        assertTrue(roller.supportsInterface(type(IERC165).interfaceId), "IERC165");

        vm.expectRevert(V2Errors.NotAuthorized.selector);
        new AutoRoller(IOrderBook(address(book)), address(0));
    }

    function test_admin_setters_roleAndBounds() public {
        vm.startPrank(alice);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        roller.setKeeperRewards(address(0));
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        roller.setMinRollUnits(1);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        roller.grantRole(V2Constants.PRICER_ROLE, alice);
        vm.stopPrank();

        vm.startPrank(admin);
        vm.expectRevert(V2Errors.NoSource.selector);
        roller.setKeeperRewards(makeAddr("codeless"));
        vm.expectEmit(address(roller));
        emit AutoRoller.KeeperRewardsSet(address(0));
        roller.setKeeperRewards(address(0));
        vm.expectEmit(address(roller));
        emit AutoRoller.MinRollUnitsSet(7);
        roller.setMinRollUnits(7);
        vm.stopPrank();
        assertEq(address(roller.keeperRewards()), address(0), "payer cleared");
        assertEq(roller.minRollUnits(), 7, "threshold");
    }
}
