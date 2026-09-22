// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {OrderBookBaseTest} from "./OrderBookBase.t.sol";
import {IOrderBook} from "../../../src/v2/interfaces/IOrderBook.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";

/// @notice OrderBook fee changes wait V2Constants.FEE_CHANGE_DELAY (48 h from INTERFACE_VERSION 8): {OrderBook.setFeeParams} schedules a change
///         with effectiveAt = now + 48 h and logs FeeParamsScheduled; feeParams(), quoteTake and every take use the
///         fees in effect, which are the scheduled change once block.timestamp >= effectiveAt; pendingFeeParams()
///         shows a change that is not in effect yet. A second schedule before the first is due replaces it and
///         restarts the delay; one after it is due keeps the first in effect until the second is due; scheduling the
///         fees in effect cancels a pending change. The ceilings and the role are checked when a change is scheduled.
/// @dev Expected take amounts are worked by hand in the comments; the fuzz test recomputes them with the documented
///      formulas. Times are START-based constants (OrderBookBaseTest: never read back from block.timestamp).
contract OrderBookFeeDelayTest is OrderBookBaseTest {
    uint256 internal constant DELAY = V2Constants.FEE_CHANGE_DELAY;
    /// @dev effectiveAt of a change scheduled at START.
    uint40 internal constant DUE40 = START40 + V2Constants.FEE_CHANGE_DELAY;

    /// @dev Fuzzed fee parameters, reduced under the ceilings by {_feesFrom}.
    struct FeeSeed {
        uint16 premium;
        uint16 resale;
        uint32 flat;
        uint16 cap;
        uint16 rebate;
    }

    /*//////////////////////////////////////////////////////////////
                               SCHEDULING
    //////////////////////////////////////////////////////////////*/

    function test_setFeeParams_schedulesFortyEightHoursAhead_inEffectAtExactlyEffectiveAt() public {
        V2Types.FeeParams memory next = _newFees();
        vm.recordLogs();
        _schedule(next);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "one log");
        assertEq(logs[0].emitter, address(book), "from the book");
        assertEq(logs[0].topics[0], IOrderBook.FeeParamsScheduled.selector, "FeeParamsScheduled, not FeeParamsSet");
        (V2Types.FeeParams memory logged, uint40 effectiveAt) = abi.decode(logs[0].data, (V2Types.FeeParams, uint40));
        assertEq(abi.encode(logged), abi.encode(next), "logged params");
        assertEq(uint256(effectiveAt), START + 172_800, "effectiveAt = now + 48 h");

        _assertFees(_defaultFees(), "just scheduled: the old fees stay in effect");
        _assertPending(next, DUE40, "pendingFeeParams shows the change");

        vm.warp(START + DELAY - 1);
        _assertFees(_defaultFees(), "one second before effectiveAt");
        _assertPending(next, DUE40, "still pending");

        vm.warp(START + DELAY);
        _assertFees(next, "at exactly effectiveAt");
        _assertNothingPending("in effect, so no longer pending");

        vm.warp(START + 7 days);
        _assertFees(next, "and it stays in effect");
        _assertNothingPending("nothing pending");
    }

    function test_setFeeParams_onlyTheAdminSchedules() public {
        address[3] memory others = [guardian, stranger, treasury];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(V2Errors.NotAuthorized.selector);
            book.setFeeParams(_newFees());
        }
        _assertNothingPending("a refused caller schedules nothing");
        _schedule(_newFees());
        _assertPending(_newFees(), DUE40, "the admin schedules");
    }

    function test_setFeeParams_ceilingsRevertWhenScheduling() public {
        for (uint256 field; field < 5; ++field) {
            vm.prank(admin);
            vm.expectRevert(V2Errors.CeilingExceeded.selector);
            book.setFeeParams(_feesAbove(field));
        }
        _assertNothingPending("nothing scheduled above a ceiling");

        _schedule(_newFees());
        vm.warp(START + 1 hours);
        for (uint256 field; field < 5; ++field) {
            vm.prank(admin);
            vm.expectRevert(V2Errors.CeilingExceeded.selector);
            book.setFeeParams(_feesAbove(field));
        }
        _assertPending(_newFees(), DUE40, "a refused schedule leaves the pending change and its delay alone");

        V2Types.FeeParams memory atCeilings = V2Types.FeeParams({
            premiumFeeBps: V2Constants.PREMIUM_FEE_CEIL_BPS,
            resaleFeeBps: V2Constants.PREMIUM_FEE_CEIL_BPS,
            takerFeeFlat: V2Constants.TAKER_FEE_FLAT_CEIL,
            takerFeeCapBps: V2Constants.TAKER_FEE_CAP_CEIL_BPS,
            makerRebateBps: 10_000
        });
        _schedule(atCeilings);
        _assertPending(atCeilings, DUE40 + 1 hours, "exactly at the ceilings: scheduled");
    }

    function test_setFeeParams_rescheduleBeforeDue_replacesAndRestartsTheDelay() public {
        _schedule(_newFees()); // due START + 48 h
        vm.warp(START + 12 hours);
        vm.expectEmit(address(book));
        emit IOrderBook.FeeParamsScheduled(_otherFees(), START40 + 12 hours + V2Constants.FEE_CHANGE_DELAY);
        _schedule(_otherFees()); // due START + 60 h
        _assertFees(_defaultFees(), "neither change in effect");
        _assertPending(_otherFees(), START + 60 hours, "replaced; the delay restarted from the second call");

        vm.warp(START + DELAY);
        _assertFees(_defaultFees(), "the replaced change never takes effect");
        vm.warp(START + 60 hours - 1);
        _assertFees(_defaultFees(), "one second before the restarted delay ends");
        vm.warp(START + 60 hours);
        _assertFees(_otherFees(), "the replacement, at its own effectiveAt");
        _assertNothingPending("in effect");
    }

    function test_setFeeParams_afterTheChangeIsDue_keepsItInEffectUntilTheNextIsDue() public {
        uint256 ask = _place(carol, callId, WRITE, P2_00, 50); // resting, 1.00 USDG of premium
        _schedule(_newFees()); // due START + 48 h
        vm.warp(START + 50 hours);
        _assertFees(_newFees(), "first change in effect");
        _schedule(_otherFees()); // due START + 98 h
        _assertFees(_newFees(), "between the two schedules: the first change");
        _assertPending(_otherFees(), START + 98 hours, "second change pending");

        // The take path agrees. _newFees: taker fee min(50_000, 1.00 USDG x 900 bps = 90_000) = 50_000; primary
        // seller fee 1_000_000 x 800 bps = 80_000; rebate 50_000 x 2500 bps = 12_500.
        vm.recordLogs();
        (,, uint256 takerFee) = _take(alice, _buy(callId, _ids(ask), 50, alice));
        Filled memory f = _decodeFilled(_filledLogs(vm.getRecordedLogs())[0]);
        assertEq(takerFee, 50_000, "taker fee at the first change");
        assertEq(f.sellerFee, 80_000, "seller fee at the first change");
        assertEq(f.makerRebate, 12_500, "rebate at the first change");

        vm.warp(START + 98 hours - 1);
        _assertFees(_newFees(), "until one second before the second is due");
        vm.warp(START + 98 hours);
        _assertFees(_otherFees(), "then the second");
        _assertNothingPending("second in effect");
    }

    function test_setFeeParams_schedulingTheFeesInEffect_cancelsAPendingChange() public {
        _schedule(_newFees()); // due START + 48 h
        vm.warp(START + 1 hours);
        _schedule(_defaultFees()); // the fees in effect
        _assertPending(_defaultFees(), START + 49 hours, "the cancel is a scheduled change to the same fees");
        vm.warp(START + DELAY);
        _assertFees(_defaultFees(), "the cancelled change never takes effect");
        vm.warp(START + 49 hours);
        _assertFees(_defaultFees(), "nothing changed");
        _assertNothingPending("nothing pending");

        // The same once a change is in effect: A in effect, B scheduled, A scheduled again.
        _schedule(_newFees()); // A, due START + 97 h
        vm.warp(START + 97 hours);
        _schedule(_otherFees()); // B, due START + 145 h
        vm.warp(START + 98 hours);
        _schedule(_newFees()); // A again, the fees in effect: due START + 146 h
        vm.warp(START + 145 hours);
        _assertFees(_newFees(), "B never takes effect");
        vm.warp(START + 146 hours);
        _assertFees(_newFees(), "still A");
        _assertNothingPending("nothing pending");
    }

    /*//////////////////////////////////////////////////////////////
                             RESTING ORDERS
    //////////////////////////////////////////////////////////////*/

    function test_take_restingOrders_payOldFeesBeforeEffectiveAt_newFeesFromIt() public {
        // Resting before the change: carol's write-on-fill asks and bob's resale asks, 50 units at 2.00 = 1.00 USDG.
        uint256 w1 = _place(carol, callId, WRITE, P2_00, 50);
        uint256 w2 = _place(carol, callId, WRITE, P2_00, 50);
        _mintLongs(bob, callId, 100);
        uint256 r1 = _place(bob, callId, RESALE, P2_00, 50);
        uint256 r2 = _place(bob, callId, RESALE, P2_00, 50);
        _schedule(_newFees());

        // One second before effectiveAt, the registry defaults (500 / 0 / 100_000 / 1000 / 5000). Premium 2.00 USDG;
        // taker fee min(100_000, 200_000) = 100_000; shares 50_000 each, rebates 25_000 each; seller fees 50_000
        // (carol, primary 5 %) and 0 (bob, resale 0).
        vm.warp(START + DELAY - 1);
        uint256[4] memory before = _wallets();
        V2Types.TakeParams memory p = _buy(callId, _ids(w1, r1), 100, alice);
        vm.prank(alice);
        (,, uint256 quoted,) = book.quoteTake(p);
        vm.recordLogs();
        (uint64 filled, uint256 premium, uint256 takerFee) = _take(alice, p);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertNoFeeLogAndTakenLast(logs);
        Vm.Log[] memory fills = _filledLogs(logs);
        uint256[4] memory afterTake = _wallets();
        assertEq(filled, 100, "units");
        assertEq(premium, 2_000_000, "premium");
        assertEq(quoted, 100_000, "quote: old taker fee");
        assertEq(takerFee, 100_000, "old taker fee");
        assertEq(_decodeFilled(fills[0]).sellerFee, 50_000, "old primary seller fee");
        assertEq(_decodeFilled(fills[1]).sellerFee, 0, "old resale seller fee");
        assertEq(_decodeFilled(fills[0]).makerRebate, 25_000, "old rebate, carol");
        assertEq(_decodeFilled(fills[1]).makerRebate, 25_000, "old rebate, bob");
        assertEq(before[0] - afterTake[0], 2_100_000, "alice: 2.00 + 0.10");
        assertEq(afterTake[1] - before[1], 975_000, "carol: 1.00 - 0.05 + 0.025");
        assertEq(afterTake[2] - before[2], 1_025_000, "bob: 1.00 + 0.025");
        assertEq(afterTake[3] - before[3], 100_000, "treasury: 0.05 + 0.10 - 0.05");

        // At exactly effectiveAt, _newFees (800 / 300 / 50_000 / 900 / 2500) on the other two resting orders. Taker
        // fee min(50_000, 180_000) = 50_000; shares 25_000 each, rebates 6_250 each; seller fees 80_000 (carol) and
        // 30_000 (bob).
        vm.warp(START + DELAY);
        before = _wallets();
        p = _buy(callId, _ids(w2, r2), 100, alice);
        vm.prank(alice);
        (,, quoted,) = book.quoteTake(p);
        vm.recordLogs();
        (filled, premium, takerFee) = _take(alice, p);
        logs = vm.getRecordedLogs();
        _assertNoFeeLogAndTakenLast(logs);
        fills = _filledLogs(logs);
        afterTake = _wallets();
        assertEq(filled, 100, "units");
        assertEq(premium, 2_000_000, "premium");
        assertEq(quoted, 50_000, "quote: new taker fee");
        assertEq(takerFee, 50_000, "new taker fee");
        assertEq(_decodeFilled(fills[0]).sellerFee, 80_000, "new primary seller fee");
        assertEq(_decodeFilled(fills[1]).sellerFee, 30_000, "new resale seller fee");
        assertEq(_decodeFilled(fills[0]).makerRebate, 6_250, "new rebate, carol");
        assertEq(_decodeFilled(fills[1]).makerRebate, 6_250, "new rebate, bob");
        assertEq(before[0] - afterTake[0], 2_050_000, "alice: 2.00 + 0.05");
        assertEq(afterTake[1] - before[1], 926_250, "carol: 1.00 - 0.08 + 0.00625");
        assertEq(afterTake[2] - before[2], 976_250, "bob: 1.00 - 0.03 + 0.00625");
        assertEq(afterTake[3] - before[3], 147_500, "treasury: 0.08 + 0.03 + 0.05 - 0.0125");
        _assertNothingPending("in effect");
    }

    /*//////////////////////////////////////////////////////////////
                    THE DAPP'S DEADLINE RULE (ACCEPTED RISK)
    //////////////////////////////////////////////////////////////*/

    /// @dev v7's "no maximum fee" accepted risk is CLOSED in INTERFACE_VERSION 8 by `TakeParams.maxTotalFee` (the
    ///      cap's own suite lives in OrderBookFeeCap.t.sol, including the cap and this window working together). What
    ///      stays true here: the deadline rules still make a take execute at the fees it was quoted or not at all.
    ///      (1) while a change is pending, deadline = effectiveAt - 1; (2) with nothing pending, a deadline under
    ///      FEE_CHANGE_DELAY (48 h) after the block it read, which no change scheduled later can reach.
    function test_take_dappDeadlineRule_paysTheQuotedFeesOrReverts() public {
        uint256 w1 = _place(carol, callId, WRITE, P2_00, 50);
        uint256 w2 = _place(carol, callId, WRITE, P2_00, 50);
        uint256 w3 = _place(carol, callId, WRITE, P2_00, 50);
        uint256 w4 = _place(carol, callId, WRITE, P2_00, 50);
        _schedule(_newFees()); // due START + 48 h

        // Rule 1, built at START + 47 h: the quote is the old taker fee min(100_000, 1.00 USDG x 1000 bps) = 100_000.
        vm.warp(START + 47 hours);
        (, uint40 effectiveAt) = book.pendingFeeParams();
        V2Types.TakeParams memory p = _buy(callId, _ids(w1), 50, alice);
        p.deadline = effectiveAt - 1;
        vm.prank(alice);
        (,, uint256 quoted,) = book.quoteTake(p);
        assertEq(quoted, 100_000, "quoted at the fees in effect");
        vm.warp(effectiveAt - 1); // mined in the last second before the change
        (,, uint256 takerFee) = _take(alice, p);
        assertEq(takerFee, quoted, "executes at the quoted fee");

        V2Types.TakeParams memory late = _buy(callId, _ids(w2), 50, alice);
        late.deadline = effectiveAt - 1;
        vm.warp(effectiveAt); // mined at the change: the new fees would apply, so the deadline refuses it
        vm.prank(alice);
        vm.expectRevert(V2Errors.DeadlinePassed.selector);
        book.take(late);
        assertEq(_order(w2).filled, 0, "nothing filled");

        // Rule 2, built at START + 49 h with nothing pending: _newFees in effect, taker fee min(50_000, 90_000).
        vm.warp(START + 49 hours);
        _assertNothingPending("the first change is in effect");
        p = _buy(callId, _ids(w3), 50, alice);
        p.deadline = START40 + 49 hours + V2Constants.FEE_CHANGE_DELAY - 1;
        vm.prank(alice);
        (,, quoted,) = book.quoteTake(p);
        assertEq(quoted, 50_000, "quoted at the fees in effect");
        _schedule(_otherFees()); // right after the read, in the same second: due START + 97 h
        vm.warp(p.deadline);
        (,, takerFee) = _take(alice, p);
        assertEq(takerFee, quoted, "a change scheduled after the read cannot reach the deadline");

        late = _buy(callId, _ids(w4), 50, alice);
        late.deadline = p.deadline;
        vm.warp(START + 97 hours); // _otherFees due now
        vm.prank(alice);
        vm.expectRevert(V2Errors.DeadlinePassed.selector);
        book.take(late);
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev Four schedules, each 0 to 120 h after the previous one (the first 0 to 120 h after START, so two can share
    ///      a second and, at the 48 h delay, a schedule can both come due and be replaced), of random fees under the
    ///      ceilings; after each schedule one take at a random time up to the next
    ///      schedule (or up to 120 h after the last). Each take fills a resting write-on-fill ask and a resting resale ask
    ///      of 1.00 USDG premium each, placed before any schedule. The fees it pays must be those of the most recent
    ///      schedule with effectiveAt <= the fill time that no later schedule replaced before its effectiveAt, or the
    ///      constructor's fees when there is none.
    function testFuzz_fees_fillPaysTheLatestScheduleInEffectThatWasNotReplaced(
        FeeSeed[4] memory seeds,
        uint32[4] memory gapSeeds,
        uint32[4] memory fillSeeds
    ) public {
        uint256[4] memory writes;
        uint256[4] memory resales;
        // T-488. NOT `callId`. This walk reaches START + 480 h (four gaps of up to 120 h), and callId expires at
        // FRI_2026_09_18, START + 211.56 h. An order placed with a `validUntil` of 0 is NOT open-ended: OrderBook
        // clamps it to the series' limit - `mintCutoff` for AskWrite, `mintCutoff + SETTLEMENT_WINDOW` (the expiry)
        // for AskResale - so past that every resting ask here is dead and the take filled 0 of 100. The series is
        // DERIVED from the calendar rather than typed: the first weekly close after the walk's furthest reach.
        uint40 farExpiry = calendar.nextExpiry(uint40(START + 480 hours), true);
        uint256 farId = ch.createSeries(address(nvda), false, CALL_STRIKE, farExpiry);
        _mintLongs(bob, farId, 200);
        for (uint256 i; i < 4; ++i) {
            writes[i] = _place(carol, farId, WRITE, P2_00, 50);
            resales[i] = _place(bob, farId, RESALE, P2_00, 50);
        }

        V2Types.FeeParams[4] memory scheduled;
        uint256[4] memory at;
        uint256 t = START + uint256(gapSeeds[0]) % (120 hours + 1);
        for (uint256 i; i < 4; ++i) {
            vm.warp(t);
            at[i] = t;
            scheduled[i] = _feesFrom(seeds[i]);
            _schedule(scheduled[i]);
            _assertPending(scheduled[i], t + DELAY, "scheduled with effectiveAt = now + 48 h");

            uint256 next = t + (i < 3 ? uint256(gapSeeds[i + 1]) % (120 hours + 1) : 120 hours);
            uint256 fillAt = t + uint256(fillSeeds[i]) % (next - t + 1);
            vm.warp(fillAt);
            _assertFill(farId, writes[i], resales[i], _expectedFees(scheduled, at, i, fillAt));
            t = next;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Every field differs from the registry defaults (500, 0, 100_000, 1000, 5000).
    function _newFees() internal pure returns (V2Types.FeeParams memory) {
        return V2Types.FeeParams({
            premiumFeeBps: 800, resaleFeeBps: 300, takerFeeFlat: 50_000, takerFeeCapBps: 900, makerRebateBps: 2500
        });
    }

    /// @dev Differs from both the defaults and {_newFees} in every field.
    function _otherFees() internal pure returns (V2Types.FeeParams memory) {
        return V2Types.FeeParams({
            premiumFeeBps: 200, resaleFeeBps: 100, takerFeeFlat: 300_000, takerFeeCapBps: 500, makerRebateBps: 7500
        });
    }

    function _feesFrom(FeeSeed memory s) internal pure returns (V2Types.FeeParams memory) {
        return V2Types.FeeParams({
            premiumFeeBps: s.premium % 1001,
            resaleFeeBps: s.resale % 1001,
            takerFeeFlat: s.flat % 1_000_001,
            takerFeeCapBps: s.cap % 1001,
            makerRebateBps: s.rebate % 10_001
        });
    }

    function _schedule(V2Types.FeeParams memory f) internal {
        vm.prank(admin);
        book.setFeeParams(f);
    }

    function _assertFees(V2Types.FeeParams memory want, string memory what) internal view {
        assertEq(abi.encode(book.feeParams()), abi.encode(want), what);
    }

    function _assertPending(V2Types.FeeParams memory want, uint256 effectiveAt, string memory what) internal view {
        (V2Types.FeeParams memory params, uint40 at) = book.pendingFeeParams();
        assertEq(uint256(at), effectiveAt, string.concat(what, ": effectiveAt"));
        assertEq(abi.encode(params), abi.encode(want), string.concat(what, ": params"));
    }

    function _assertNothingPending(string memory what) internal view {
        V2Types.FeeParams memory zero;
        _assertPending(zero, 0, what);
    }

    /// @dev USDG of alice (taker), carol, bob (makers) and treasury (fee recipient).
    function _wallets() internal view returns (uint256[4] memory w) {
        w = [usdg.balanceOf(alice), usdg.balanceOf(carol), usdg.balanceOf(bob), usdg.balanceOf(treasury)];
    }

    /// @dev A take writes no fee state: no FeeParams log, and the §1.8 order still ends with Taken.
    function _assertNoFeeLogAndTakenLast(Vm.Log[] memory logs) internal view {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(book)) continue;
            assertTrue(logs[i].topics[0] != IOrderBook.FeeParamsScheduled.selector, "no FeeParamsScheduled in a take");
            assertTrue(logs[i].topics[0] != IOrderBook.FeeParamsSet.selector, "no FeeParamsSet in a take");
        }
        assertEq(logs[logs.length - 1].emitter, address(book), "last log from the book");
        assertEq(logs[logs.length - 1].topics[0], IOrderBook.Taken.selector, "Taken last");
    }

    /// @dev The spec, written independently of the book: walking back from the latest schedule, the first one whose
    ///      effectiveAt has passed at `fillAt` and that the next schedule did not replace before its effectiveAt.
    function _expectedFees(V2Types.FeeParams[4] memory s, uint256[4] memory at, uint256 last, uint256 fillAt)
        internal
        pure
        returns (V2Types.FeeParams memory)
    {
        for (uint256 k = last + 1; k > 0; --k) {
            uint256 j = k - 1;
            bool inEffect = at[j] + DELAY <= fillAt;
            bool replacedFirst = j < last && at[j + 1] < at[j] + DELAY;
            if (inEffect && !replacedFirst) return s[j];
        }
        return _defaultFees();
    }

    /// @dev Takes `write` then `resale` (1.00 USDG of premium each) and checks every fee against `want`: taker fee
    ///      min(flat, 2.00 USDG x cap), seller fees by kind, rebates on shares floor(fee / 2) and the rest.
    function _assertFill(uint256 longId, uint256 write, uint256 resale, V2Types.FeeParams memory want) internal {
        _assertFees(want, "feeParams() at the fill");
        uint256 byCap = 2_000_000 * uint256(want.takerFeeCapBps) / 10_000;
        uint256 fee = byCap < want.takerFeeFlat ? byCap : want.takerFeeFlat;
        uint256 treasuryBefore = usdg.balanceOf(treasury);

        vm.recordLogs();
        (uint64 filled, uint256 premium, uint256 takerFee) = _take(alice, _buy(longId, _ids(write, resale), 100, alice));
        Vm.Log[] memory fills = _filledLogs(vm.getRecordedLogs());
        assertEq(filled, 100, "both orders filled");
        assertEq(premium, 2_000_000, "premium");
        assertEq(takerFee, fee, "taker fee at the fees in effect");

        Filled memory w = _decodeFilled(fills[0]);
        Filled memory r = _decodeFilled(fills[1]);
        assertEq(w.sellerFee, uint256(want.premiumFeeBps) * 1_000_000 / 10_000, "primary seller fee");
        assertEq(r.sellerFee, uint256(want.resaleFeeBps) * 1_000_000 / 10_000, "resale seller fee");
        uint256 share = fee / 2;
        assertEq(w.makerRebate, share * want.makerRebateBps / 10_000, "rebate on the first share");
        assertEq(r.makerRebate, (fee - share) * want.makerRebateBps / 10_000, "rebate on the last share");
        assertEq(
            usdg.balanceOf(treasury) - treasuryBefore,
            w.sellerFee + r.sellerFee + fee - w.makerRebate - r.makerRebate,
            "fee recipient"
        );
    }
}
