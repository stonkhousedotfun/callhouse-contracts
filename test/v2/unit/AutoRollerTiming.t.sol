// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AutoRollerTestBase} from "./AutoRollerBase.t.sol";

/// @notice When a roll happens and what it writes: the regular session, fresh spot, minLead, the expiry search, and
///         the property that neither the caller nor the moment inside a session changes strike, price or size.
contract AutoRollerTimingTest is AutoRollerTestBase {
    uint256 internal constant SESSION = 6 hours + 30 minutes;

    function setUp() public override {
        super.setUp();
        _setStrategy(alice, _weekly(500, 150));
    }

    /*//////////////////////////////////////////////////////////////
                             REGULAR SESSION
    //////////////////////////////////////////////////////////////*/

    function test_session_overnight_noRoll() public {
        _spotAt(_ny(THU_0910, 3, 0, 0), 220_00000000);
        _noRoll(alice, "03:00 overnight");
        _spotAt(_ny(THU_0910, 20, 0, 0), 220_00000000);
        _noRoll(alice, "20:00 after hours");
    }

    /// A print from before the open does not roll at the open: it is inside {AutoRoller.ROLL_OPEN_GRACE} and was not
    /// observed in session (INTERFACE_VERSION 7). The grace ends 30 minutes later and the same print rolls.
    function test_session_openBoundary() public {
        _spotAt(_ny(THU_0910, 9, 29, 59), 220_00000000);
        _noRoll(alice, "09:29:59 is outside the session");
        vm.warp(_ny(THU_0910, 9, 30, 0));
        _noRoll(alice, "09:30:00 on a pre-open print: the open grace");
        vm.warp(_ny(THU_0910, 9, 59, 59));
        _noRoll(alice, "one second before the grace ends");
        vm.warp(_ny(THU_0910, 10, 0, 0));
        Rolled memory r = _mustRoll(alice);
        assertEq(r.expiry, FRI_2026_09_11, "10:00:00 rolls");
        assertEq(r.strike, K_231, "on the same print it refused at 09:30");
    }

    /// The opening print itself rolls at the open: it was observed in session on the same date, so the grace is met.
    function test_session_openBoundary_sessionPrintRollsAt0930() public {
        _spotAt(_ny(THU_0910, 9, 30, 0), 220_00000000);
        Rolled memory r = _mustRoll(alice);
        assertEq(r.expiry, FRI_2026_09_11, "09:30:00 on a 09:30:00 print");
    }

    /*//////////////////////////////////////////////////////////////
                               OPEN GRACE
    //////////////////////////////////////////////////////////////*/

    function test_constants_rollOpenGrace() public view {
        assertEq(roller.ROLL_OPEN_GRACE(), 30 minutes, "1800 seconds");
    }

    /// Fixed in INTERFACE_VERSION 7 (sweep contracts-c16; before the grace this test was
    /// `test_openGap_rollOnYesterdaysClose_fillsBelowIntrinsic` and the roll at 09:30 wrote a 231 strike and a 3.30 ask
    /// on a market that opened at 260, which the first taker bought for 3.30 against an intrinsic of 29.00).
    /// With the launch registry's 25 h spotMaxAge yesterday's closing print is still "fresh" at today's open, so
    /// freshness alone cannot tell a gap from a quiet open. The roll now waits for a print made in session that day.
    function test_openGrace_gapAtTheOpen_rollWaitsForTheOpeningPrint() public {
        _setSpotMaxAge(SPOT_MAX_AGE_25H);
        _spotAt(_ny(THU_0910, 15, 59, 0), 220_00000000); // Thursday's closing print

        vm.warp(_ny(FRI_0911, 9, 30, 0));
        _noRoll(alice, "Friday 09:30 on Thursday's close");
        vm.warp(_ny(FRI_0911, 9, 59, 59));
        _noRoll(alice, "still inside the grace");

        // The opening print ends the wait at once, whatever is left of the grace.
        _spotAt(_ny(FRI_0911, 9, 59, 59), 260_00000000);
        Rolled memory r = _mustRoll(alice);
        assertEq(r.strike, 273_000_000, "273 = 260 x 1.05, the price the market actually opened at");
        assertEq(r.price, 3_900_000, "1.5 % of 260");
        assertGt(uint256(r.strike), 260_000_000, "out of the money where the market is");
    }

    /// The cost of the grace on a quiet open: the roll moves from 09:30 to 10:00 and then writes the same thing.
    function test_openGrace_quietOpen_rollsAtTheEndOfTheGraceOnThePreviousClose() public {
        _setSpotMaxAge(SPOT_MAX_AGE_25H);
        _spotAt(_ny(THU_0910, 15, 59, 0), 220_00000000);
        vm.warp(_ny(FRI_0911, 9, 59, 59));
        _noRoll(alice, "the grace has one second left");
        vm.warp(_ny(FRI_0911, 10, 0, 0));
        Rolled memory r = _mustRoll(alice);
        assertEq(r.strike, K_231, "the grace expired: yesterday's close is accepted");
        assertEq(r.expiry, FRI_2026_09_18, "a daily roll at 10:00 would still have 6 h of lead");
    }

    /// A pre-market heartbeat is on the same date but was not observed in session, so it does not satisfy the grace.
    function test_openGrace_preMarketHeartbeatDoesNotCount() public {
        _spotAt(_ny(THU_0910, 9, 0, 0), 220_00000000);
        vm.warp(_ny(THU_0910, 9, 45, 0));
        _noRoll(alice, "09:00 heartbeat, same UTC date, before the open");
        vm.warp(_ny(THU_0910, 10, 0, 0));
        _mustRoll(alice);
    }

    /// Any second of a session and any print inside the market's spotMaxAge: the roll happens exactly when the grace
    /// has passed or the print was itself in session that day, and never on a strike more than one tick off the print
    /// it used.
    function testFuzz_openGrace(uint256 nowOffset, uint256 printOffset) public {
        _setSpotMaxAge(SPOT_MAX_AGE_25H);
        uint256 open = _ny(FRI_0911, 9, 30, 0);
        uint256 nowTs = open + bound(nowOffset, 0, SESSION - 1);
        // Anywhere from 24 h before the print's own session open to `nowTs` itself.
        uint256 printAt = nowTs - bound(printOffset, 0, 24 hours);
        _spotAt(printAt, 220_00000000);
        vm.warp(nowTs);

        bool graceOver = calendar.isRegularSession(uint40(nowTs - 30 minutes));
        bool sessionPrint = printAt / 1 days == nowTs / 1 days && calendar.isRegularSession(uint40(printAt));
        (bool advanced,, Rolled memory r) = _roll(keeper, alice);
        assertEq(advanced, graceOver || sessionPrint, "rolls exactly when the grace is met");
        if (advanced) assertEq(r.strike, K_231, "on the 220 print");
    }

    function test_session_lastSecond_rolls() public {
        _spotAt(_ny(THU_0910, 15, 59, 59), 220_00000000);
        Rolled memory r = _mustRoll(alice);
        assertEq(r.expiry, FRI_2026_09_11, "15:59:59 Thursday still writes Friday: 24 h + 1 s ahead");
    }

    function test_session_close_noRoll() public {
        _spotAt(_ny(THU_0910, 16, 0, 0), 220_00000000);
        _noRoll(alice, "16:00:00 is the close, outside the session");
    }

    function test_session_weekend_noRoll() public {
        _spotAt(_ny(SAT_0912, 11, 0, 0), 220_00000000);
        _noRoll(alice, "Saturday");
    }

    function test_session_holiday_noRoll_thenNextSessionDay() public {
        uint32[] memory days_ = new uint32[](1);
        days_[0] = MON_0914;
        vm.prank(admin);
        calendar.setHolidays(days_, true);

        _spotAt(_ny(MON_0914, 11, 0, 0), 220_00000000);
        _noRoll(alice, "holiday Monday");
        _spotAt(_ny(TUE_0915, 11, 0, 0), 220_00000000);
        Rolled memory r = _mustRoll(alice);
        assertEq(r.expiry, FRI_2026_09_18, "Tuesday rolls");
    }

    /*//////////////////////////////////////////////////////////////
                                  SPOT
    //////////////////////////////////////////////////////////////*/

    /// The last round is from the evening before (START - 1 h): not fresh at 10:00.
    function test_spot_stale_noRoll_thenFreshRolls() public {
        vm.warp(_ny(THU_0910, 10, 0, 0));
        _noRoll(alice, "stale spot");
        _spotAt(_ny(THU_0910, 10, 0, 5), 220_00000000);
        _mustRoll(alice);
    }

    function test_spot_exactlyMaxAge_isFresh() public {
        uint256 t = _ny(THU_0910, 10, 0, 0);
        _spotAt(t, 220_00000000);
        vm.warp(t + 1 hours);
        _mustRoll(alice);
    }

    function test_spot_maxAgePlusOneSecond_noRoll() public {
        uint256 t = _ny(THU_0910, 10, 0, 0);
        _spotAt(t, 220_00000000);
        vm.warp(t + 1 hours + 1);
        _noRoll(alice, "one second too old");
    }

    function test_spot_oraclePaused_noRoll() public {
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        nvda.setOraclePaused(true);
        _noRoll(alice, "issuer oracle pause");
        nvda.setOraclePaused(false);
        _mustRoll(alice);
    }

    function test_spot_feedReverts_noRoll() public {
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        feed.setReverts(true);
        _noRoll(alice, "feed down");
    }

    /*//////////////////////////////////////////////////////////////
                                MIN LEAD
    //////////////////////////////////////////////////////////////*/

    function test_minLead_daily_before1400_writesToday() public {
        _setStrategy(alice, _daily(500, 150));
        _spotAt(_ny(THU_0910, 13, 59, 59), 220_00000000);
        assertEq(_mustRoll(alice).expiry, THU_2026_09_10, "2 h 00 m 01 s ahead: today");
    }

    function test_minLead_daily_at1400_writesTomorrow() public {
        _setStrategy(alice, _daily(500, 150));
        _spotAt(_ny(THU_0910, 14, 0, 0), 220_00000000);
        assertEq(_mustRoll(alice).expiry, FRI_2026_09_11, "exactly 2 h ahead is not enough: tomorrow");
    }

    function test_minLead_weekly_onTheWeeklyDay_writesNextWeek() public {
        _spotAt(_ny(FRI_0911, 9, 30, 0), 220_00000000);
        assertEq(_mustRoll(alice).expiry, FRI_2026_09_18, "Friday morning: next Friday");
    }

    /// Friday 09-18 is a holiday, so Thursday 09-17 is the weekly: Wednesday afternoon still writes it, Thursday morning
    /// already writes the week after.
    function test_minLead_weekly_thursdayWeekly() public {
        uint32[] memory days_ = new uint32[](1);
        days_[0] = FRI_0918;
        vm.prank(admin);
        calendar.setHolidays(days_, true);
        uint40 thu0917 = _close(THU_0917);

        _spotAt(_ny(WED_0916, 15, 0, 0), 220_00000000);
        assertEq(_mustRoll(alice).expiry, thu0917, "Wednesday 15:00: Thursday's weekly, 25 h ahead");

        _setStrategy(bob, _weekly(500, 150));
        _onboardWriter(bob, WRITER_SHARES);
        _spotAt(_ny(THU_0917, 10, 0, 0), 220_00000000);
        (bool advanced, uint256 count, Rolled memory r) = _roll(keeper, bob);
        assertTrue(advanced && count == 1, "bob rolls");
        assertEq(r.expiry, FRI_2026_09_25, "Thursday morning: its own weekly is 6 h away, so next week's");
    }

    /// No weekly expiry inside the calendar's 14-day search: nextExpiry reverts and the roll is simply not due.
    function test_noExpiryFound_noRoll() public {
        uint32[] memory days_ = new uint32[](9);
        (days_[0], days_[1], days_[2], days_[3]) = (TUE_0915, WED_0916, THU_0917, FRI_0918);
        for (uint32 i; i < 5; ++i) {
            days_[4 + i] = MON_0921 + i;
        }
        vm.prank(admin);
        calendar.setHolidays(days_, true);
        _spotAt(_ny(MON_0914, 11, 0, 0), 220_00000000);
        _noRoll(alice, "BadExpiry is treated as no roll");
    }

    /// Any session second of the week 09-14..09-18: the chosen expiry is at least minLead away, of the strategy's kind,
    /// and the first such expiry after now + minLead.
    function testFuzz_minLead_alwaysHolds(uint256 dayPick, uint256 offset, bool weekly) public {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 day = MON_0914 + uint32(bound(dayPick, 0, 4));
        uint256 t = _ny(day, 9, 30, 0) + bound(offset, 0, SESSION - 1);
        _setStrategy(alice, weekly ? _weekly(500, 150) : _daily(500, 150));
        _spotAt(t, 220_00000000);
        Rolled memory r = _mustRoll(alice);

        uint256 lead = weekly ? 24 hours : 2 hours;
        assertGe(uint256(r.expiry), t + lead, "never inside minLead");
        assertGt(uint256(r.expiry) - 30 minutes, t, "the averaging window has not started");
        if (weekly) assertTrue(calendar.isWeekly(r.expiry), "a weekly");
        assertTrue(calendar.isValidExpiry(r.expiry), "a grid expiry");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(r.expiry, calendar.nextExpiry(uint40(t + lead), weekly), "the first one after now + minLead");
    }

    /*//////////////////////////////////////////////////////////////
                         CALLER CANNOT CHOOSE
    //////////////////////////////////////////////////////////////*/

    /// Weekly strategy, any caller, any second of Tuesday's session, same oracle price: the same roll every time.
    function testFuzz_callerAndTime_doNotChangeTheRoll(address caller, uint256 offset) public {
        vm.assume(caller != address(0) && caller != address(roller) && caller != address(rewards));
        uint256 t = _ny(TUE_0915, 9, 30, 0) + bound(offset, 0, SESSION - 1);
        _spotAt(t, 220_00000000);
        uint256 callerBefore = usdg.balanceOf(caller);

        (bool advanced, uint256 count, Rolled memory r) = _roll(caller, alice);
        assertTrue(advanced, "rolled");
        assertEq(count, 1, "once");
        assertEq(r.strike, K_231, "strike from strategy + spot only");
        assertEq(r.price, P_3_30, "price from strategy + spot only");
        assertEq(r.units, 1000, "size from the writer's ledger only");
        assertEq(r.expiry, FRI_2026_09_18, "Tuesday's weekly");
        assertEq(_order(r.orderId).maker, alice, "always the writer's ask");
        assertEq(_order(r.orderId).units, 1000, "ask size");
        assertEq(usdg.balanceOf(caller) - callerBefore, ROLL_BOUNTY, "bounty to whoever called");
        _assertRollerEmpty(r.longId);
    }

    /// Daily strategy: any caller before 14:00 writes today's close, from 14:00 tomorrow's; strike, price and size
    /// never move.
    function testFuzz_daily_callerAndTime(address caller, uint256 offset) public {
        vm.assume(caller != address(0) && caller != address(roller) && caller != address(rewards));
        _setStrategy(alice, _daily(300, 80));
        uint256 open = _ny(WED_0916, 9, 30, 0);
        uint256 t = open + bound(offset, 0, SESSION - 1);
        _spotAt(t, 220_00000000);
        (bool advanced,, Rolled memory r) = _roll(caller, alice);
        assertTrue(advanced, "rolled");
        uint40 expected = t < _ny(WED_0916, 14, 0, 0) ? _close(WED_0916) : _close(THU_0917);
        assertEq(r.expiry, expected, "today before 14:00, else tomorrow");
        assertEq(r.strike, 227_000_000, "226.60 rounds up to 227");
        assertEq(r.price, 1_760_000, "0.8 % of 220 = 1.76");
        assertEq(r.units, 1000, "size");
    }

    /// Strike and price follow the formulas exactly for any spot and strategy inside the bounds: the exact rational value
    /// rounded up to the grid.
    function testFuzz_strikeAndPrice_formula(uint256 spotAnswer, uint256 otm, uint256 ask) public {
        spotAnswer = bound(spotAnswer, 10_00000000, 5000_00000000);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 otmBps = uint16(bound(otm, 100, 2500));
        // T-OP-063 / SEC-13: the compiled ask floor is MIN_ASK_BPS = 50; a fuzzed ask in [5, 49] would revert
        // CeilingExceeded in setStrategy before the formula under test is reached. The bound mirrors the constant.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 askBps = uint16(bound(ask, 50, 1000));
        _setStrategy(alice, _weekly(otmBps, askBps));
        uint256 t = _ny(TUE_0915, 11, 0, 0);
        vm.warp(t - 1);
        // forge-lint: disable-next-line(unsafe-typecast)
        feed.push(int256(spotAnswer), t - 1);
        // forge-lint: disable-next-line(unsafe-typecast)
        _spotAt(t, int256(spotAnswer));
        uint256 spot = spotAnswer / 100;

        Rolled memory r = _mustRoll(alice);
        assertEq(r.strike, _expectedStrike(spot, otmBps), "strike");
        assertEq(r.price, _expectedPrice(spot, askBps), "price");
        assertGe(uint256(r.strike) * 10_000, spot * (10_000 + otmBps), "strike never closer to spot than asked");
        assertLt(uint256(r.strike) * 10_000, spot * (10_000 + otmBps) + STRIKE_TICK * 10_000, "within one tick");
        assertGe(uint256(r.price) * 10_000, spot * askBps, "ask never below the rate");
        assertEq(r.price % 100, 0, "on the price grid");
        assertGt(r.price, 0, "positive");
    }
}
