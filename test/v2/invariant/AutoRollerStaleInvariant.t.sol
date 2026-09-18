// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AutoRollerTestBase} from "../unit/AutoRollerBase.t.sol";
import {AutoRollerStaleHandler} from "./AutoRollerStaleHandler.sol";

/// @notice Stateful invariants of {AutoRoller.cancelStale} and the open grace (INTERFACE_VERSION 7, v7 design §6.3),
///         asserted after every call of {AutoRollerStaleHandler} on the real AutoRoller, OrderBook, Clearinghouse and
///         SettlementOracle.
/// @dev THE INVARIANTS:
///        S1. {AutoRoller.cancelStale} moves no collateral, no option tokens and no USDG but the caller's bounty —
///            whoever calls it, whatever the market, the pauses and the writer's approvals are doing.
///        S2. It returns false rather than reverting for every "nothing to do": the only revert is the writer's own
///            revoked delegate, where the book refuses the cancel and the roller deliberately does not swallow it.
///        S3. After a cranker sweep no tracked live ask is still overtaken at an ok spot, unless its writer revoked
///            the delegate (nothing can withdraw it then, and the writer can cancel it itself).
///        S4. At most one {AutoRoller.StaleAskCancelled} per (writer, longId): a withdrawn position is never re-rolled
///            inside its period, so there is never a second ask to withdraw.
///        S5. Every roll placed an ask strictly out of the money at the reading it used, and a roll made inside
///            {AutoRoller.ROLL_OPEN_GRACE} used a reading observed in a regular session on the same date.
///        S6. The roller holds nothing: no USDG, no Stock Tokens.
///
///      CONFIG. runs = 256, depth = 64, inline like {V2InvariantTest}; fail-on-revert is on and the handler never
///      reverts. Three writers share one market, two buyers take, one pricer reprices; the market's spotMaxAge is the
///      launch registry's 25 h so overnight and weekend readings stay actionable.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract AutoRollerStaleInvariantTest is AutoRollerTestBase {
    AutoRollerStaleHandler internal handler;

    /// @dev Thursday 2026-09-10 09:30 New York: a session open, so the first actions land inside the grace.
    uint256 internal constant WORLD_START = 1_789_070_400 - 6 hours - 30 minutes;

    address internal dave = makeAddr("dave");
    address internal erin = makeAddr("erin");

    function setUp() public override {
        super.setUp();
        _setSpotMaxAge(SPOT_MAX_AGE_25H);

        _fund(dave, ACTOR_USDG, ACTOR_SHARES, 0);
        _fund(erin, ACTOR_USDG, ACTOR_SHARES, 0);
        _onboardWriter(dave, WRITER_SHARES);
        _onboardWriter(erin, WRITER_SHARES);
        address[3] memory writers = [alice, dave, erin];
        for (uint256 i; i < writers.length; ++i) {
            _setStrategy(writers[i], _smart(50, 150, 1000));
        }

        vm.warp(WORLD_START);
        feed.push(220_00000000, WORLD_START);

        handler = new AutoRollerStaleHandler(
            AutoRollerStaleHandler.Deps({
                roller: roller,
                book: book,
                ch: ch,
                oracle: oracle,
                calendar: calendar,
                feed: feed,
                second: second,
                usdg: usdg,
                nvda: nvda,
                admin: admin,
                guardian: guardian,
                pricer: pricer,
                writers: writers,
                buyers: [bob, carol],
                start: WORLD_START
            })
        );
        vm.label(address(handler), "AutoRollerStaleHandler");
        targetContract(address(handler));
    }

    /// S1.
    function invariant_cancelStale_movesNothingButTheBounty() public view {
        assertEq(handler.movedValue(), 0, handler.lastSurprise());
    }

    /// S2.
    function invariant_cancelStale_revertsOnlyForARevokedDelegate() public view {
        assertEq(handler.revertedWithDelegate(), 0, handler.lastSurprise());
    }

    /// S3.
    function invariant_crankLeavesNoOvertakenAskLive() public view {
        assertEq(handler.crankLeftOvertaken(), 0, handler.lastSurprise());
    }

    /// S4.
    function invariant_atMostOneStaleCancelPerPosition() public view {
        assertLe(handler.maxStaleCancels(), 1, "one withdrawal per position");
    }

    /// S5.
    function invariant_rollNeverPlacesAnOvertakenOrPreOpenAsk() public view {
        assertEq(handler.badRoll(), 0, handler.lastSurprise());
    }

    /// S6.
    function invariant_rollerHoldsNothing() public view {
        assertEq(usdg.balanceOf(address(roller)), 0, "the roller holds no USDG");
        assertEq(nvda.balanceOf(address(roller)), 0, "the roller holds no NVDA");
    }

    /// @dev Not an invariant: a hand-driven sequence through the same handler, so S1-S6 are known to be reachable
    ///      rather than vacuous. A roll at the open on the opening print, two 8 % prints that carry the spot past the
    ///      5 % strike, and a cranker sweep that withdraws all three asks.
    function test_handler_reachesARollAndAWithdrawal() public {
        for (uint256 i; i < 3; ++i) {
            handler.roll(i, 0);
        }
        assertEq(handler.rolls(), 3, "three writers rolled");
        handler.print(800, true, 1 hours);
        handler.print(800, true, 1 hours);
        handler.crankStale(0);
        assertEq(handler.cancels(), 3, "all three asks withdrawn");
        assertEq(handler.crankLeftOvertaken(), 0, "nothing left overtaken");
        assertEq(handler.movedValue(), 0, "no value moved");
        assertEq(handler.badRoll(), 0, "no bad placement");
        assertLe(handler.maxStaleCancels(), 1, "one withdrawal per position");
    }
}
