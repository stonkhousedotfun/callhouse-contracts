// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IExpiryCalendar} from "./interfaces/IExpiryCalendar.sol";
import {V2Constants} from "./interfaces/V2Constants.sol";
import {V2Errors} from "./interfaces/V2Errors.sol";

/// @title ExpiryCalendar
/// @notice The v2 expiry grid: 16:00:00 America/New_York on NYSE session days, plus admin-whitelisted special expiries
///         (ADR-07, architecture §3.2). Daily = every session day; weekly = the last session day of its ISO week.
/// @dev All times are unix seconds (UTC). A "day index" is floor(ts / 86400), a UTC calendar day counted from
///      1970-01-01. The 16:00 New York close is 20:00 UTC in EDT and 21:00 UTC in EST, so the close of a New York date
///      always falls on the UTC day with the same calendar date: the day index of a close IS its New York date, and
///      holidays are keyed by it (the F2-02 recon's `dayIndex`, callhouse ops/markets/v2-sources.json).
///
///      TIME ZONE. The US DST rule since 2007 is compiled in: EDT (UTC-4) from the second Sunday of March 02:00 local
///      to the first Sunday of November 02:00 local, EST (UTC-5) otherwise. A future change to that rule needs a new
///      calendar, which the Clearinghouse can point NEW series at (existing series keep their expiry). Anything that
///      only looks at the 09:30-16:00 session or the 16:00 close compares dates, never instants, because the 02:00
///      switch cannot move either; only {newYorkOffset} resolves the switch to the second.
///
///      HOLIDAYS are admin data: the constructor seeds the NYSE full-day closures (2026-2028 at deploy) and the admin
///      must extend the set before each new year. An unseeded holiday is an ordinary session day. Early closes (13:00)
///      are ordinary session days: the settlement window simply averages the last prints.
///
///      SPECIAL EXPIRIES are exact instants whitelisted by the admin. They only widen {isValidExpiry}: {isWeekly},
///      {isRegularSession} and {nextExpiry} read the session-day grid alone, so a whitelisted instant never becomes a
///      weekly, never stops a later grid close from being the weekly, and is never returned to the AutoRoller.
contract ExpiryCalendar is IExpiryCalendar, AccessControl, ReentrancyGuardTransient {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice {nextExpiry} looks at closes in (afterTs, afterTs + NEXT_EXPIRY_SEARCH] and reverts beyond, seconds.
    /// @dev Two consecutive weeklies are at most 9 days apart while every week has a session (a Wednesday weekly when
    ///      Thursday and Friday are closed, then the next Friday), so the search fails only once a whole week is closed.
    uint40 public constant NEXT_EXPIRY_SEARCH = 14 days;

    uint256 private constant DAY = 1 days;
    /// @dev UTC time of day of the 16:00 New York close in daylight time (UTC-4) and standard time (UTC-5), seconds.
    uint256 private constant CLOSE_UTC_EDT = 20 hours;
    uint256 private constant CLOSE_UTC_EST = 21 hours;
    /// @dev Regular session [09:30:00, 16:00:00) New York local time of day, seconds.
    uint256 private constant SESSION_OPEN_LOCAL = 9 hours + 30 minutes;
    uint256 private constant SESSION_CLOSE_LOCAL = 16 hours;
    /// @dev The DST switch instants as UTC time of day on the switch Sunday: 02:00 EST = 07:00 UTC (spring forward),
    ///      02:00 EDT = 06:00 UTC (fall back).
    uint256 private constant DST_START_UTC = 7 hours;
    uint256 private constant DST_END_UTC = 6 hours;
    int32 private constant OFFSET_EDT = -4 hours;
    int32 private constant OFFSET_EST = -5 hours;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Whether the New York date with this day index is a full-day NYSE closure.
    mapping(uint32 dayIndex => bool) public holiday;

    /// @notice Whether this exact instant (unix seconds) is whitelisted as an expiry regardless of the grid.
    mapping(uint40 ts => bool) public specialExpiry;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param admin Receives DEFAULT_ADMIN_ROLE: maintains holidays and special expiries.
    /// @param holidays Initial full-day closures as day indexes (floor(16:00 New York instant / 86400)). The launch set
    ///        is the NYSE 2026-2028 list in callhouse ops/markets/v2-sources.json `nyseHolidays.*.fullDays`.
    constructor(address admin, uint32[] memory holidays) {
        // An admin of address(0) would leave the holiday set frozen at the seed with nobody able to extend it.
        if (admin == address(0)) revert V2Errors.NotAuthorized();
        _grantRole(V2Constants.DEFAULT_ADMIN_ROLE, admin);
        for (uint256 i; i < holidays.length; ++i) {
            _setHoliday(holidays[i], true);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Adds (`isHoliday` true) or removes full-day closures. Emits {HolidaySet} for every entry.
    /// @dev Affects every later read, including {isValidExpiry} for series creation; series already created keep their
    ///      expiry (the Clearinghouse checks the calendar only at creation).
    /// @param dayIndexes Day indexes, floor(16:00 New York instant / 86400).
    /// @param isHoliday True to close the dates, false to reopen them.
    function setHolidays(uint32[] calldata dayIndexes, bool isHoliday)
        external
        nonReentrant
        onlyRole(V2Constants.DEFAULT_ADMIN_ROLE)
    {
        for (uint256 i; i < dayIndexes.length; ++i) {
            _setHoliday(dayIndexes[i], isHoliday);
        }
    }

    /// @notice Whitelists (`allowed` true) or removes a special expiry instant. Emits {SpecialExpirySet}.
    /// @param ts Expiry, unix seconds. Taken as given: the admin owns the choice of instant.
    /// @param allowed True to accept `ts` in {isValidExpiry} regardless of the grid.
    function setSpecialExpiry(uint40 ts, bool allowed) external nonReentrant onlyRole(V2Constants.DEFAULT_ADMIN_ROLE) {
        specialExpiry[ts] = allowed;
        emit SpecialExpirySet(ts, allowed);
    }

    /*//////////////////////////////////////////////////////////////
                                 READS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IExpiryCalendar
    function isValidExpiry(uint40 ts) external view returns (bool) {
        return specialExpiry[ts] || _isSessionClose(ts);
    }

    /// @inheritdoc IExpiryCalendar
    function isWeekly(uint40 ts) external view returns (bool) {
        uint256 day = ts / DAY;
        return ts == _closeOf(day) && _isWeeklyDay(day);
    }

    /// @inheritdoc IExpiryCalendar
    /// @dev Grid only: special expiries are not enumerable and are never returned (see the contract NatSpec). Reverts
    ///      {V2Errors.BadExpiry} when no matching close lies in (afterTs, afterTs + NEXT_EXPIRY_SEARCH] or the close
    ///      would not fit uint40.
    function nextExpiry(uint40 afterTs, bool weekly) external view returns (uint40) {
        uint256 limit = uint256(afterTs) + NEXT_EXPIRY_SEARCH;
        // Closes strictly increase with the day index (consecutive closes are 23, 24 or 25 hours apart), so the first
        // close past `limit` ends the search; the loop runs at most 15 times.
        for (uint256 day = afterTs / DAY;; ++day) {
            uint256 close = _closeOf(day);
            if (close > limit) break;
            if (close > afterTs && (weekly ? _isWeeklyDay(day) : _isSessionDay(day))) {
                if (close > type(uint40).max) break;
                // casting to 'uint40' is safe because the line above bounds `close`
                // forge-lint: disable-next-line(unsafe-typecast)
                return uint40(close);
            }
        }
        revert V2Errors.BadExpiry();
    }

    /// @inheritdoc IExpiryCalendar
    /// @dev [09:30:00, 16:00:00) New York local time on a session day: 16:00:00 itself (the close) is outside.
    function isRegularSession(uint40 ts) external view returns (bool) {
        uint256 day = ts / DAY;
        // Inside the session the New York date equals the UTC date (09:30 local is 13:30 or 14:30 UTC, 16:00 is 20:00
        // or 21:00 UTC), so the session is the UTC interval [day + open + shift, day + close + shift) of that UTC day.
        uint256 shift = _isDstDate(day) ? 4 hours : 5 hours;
        uint256 secondOfDay = ts % DAY;
        return
            secondOfDay >= SESSION_OPEN_LOCAL + shift && secondOfDay < SESSION_CLOSE_LOCAL + shift && _isSessionDay(day);
    }

    /// @inheritdoc IExpiryCalendar
    /// @dev Exact to the second at both switches: the spring switch is 07:00 UTC and the fall switch 06:00 UTC on the
    ///      switch Sunday. The UTC year of `ts` is the New York year whenever it matters, because both switches are
    ///      months away from New Year.
    function newYorkOffset(uint40 ts) external pure returns (int32 secondsEastOfUtc) {
        (uint256 startDay, uint256 endDay) = _dstDays(_yearOf(ts / DAY));
        bool dst = ts >= startDay * DAY + DST_START_UTC && ts < endDay * DAY + DST_END_UTC;
        return dst ? OFFSET_EDT : OFFSET_EST;
    }

    /// @notice Whether the New York date with this day index is a session day: Monday-Friday and not a holiday.
    /// @param dayIndex floor(16:00 New York instant / 86400).
    /// @return True on a session day.
    function isSessionDay(uint32 dayIndex) external view returns (bool) {
        return _isSessionDay(dayIndex);
    }

    /// @notice The 16:00:00 New York instant of the date with this day index, whether or not it is a session day.
    /// @param dayIndex floor(16:00 New York instant / 86400).
    /// @return Unix seconds.
    function closeOf(uint32 dayIndex) external pure returns (uint256) {
        return _closeOf(dayIndex);
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Every role check reverts with the shared v2 error instead of OpenZeppelin's, so the one error ABI every
    ///      consumer merges (V2Errors) decodes it. This also covers grantRole / revokeRole.
    function _checkRole(bytes32 role, address account) internal view override {
        if (!hasRole(role, account)) revert V2Errors.NotAuthorized();
    }

    function _setHoliday(uint32 dayIndex, bool isHoliday) private {
        holiday[dayIndex] = isHoliday;
        emit HolidaySet(dayIndex, isHoliday);
    }

    /// @dev `ts` is exactly 16:00:00 New York on a session day.
    function _isSessionClose(uint256 ts) private view returns (bool) {
        uint256 day = ts / DAY;
        return ts == _closeOf(day) && _isSessionDay(day);
    }

    /// @dev 1970-01-01 (day 0) was a Thursday, so (day + 3) % 7 counts from Monday = 0 to Sunday = 6, the ISO week
    ///      order {_isWeeklyDay} needs. The uint32 cast holds for every uint40 timestamp: 2^40 / 86400 < 2^24.
    function _isSessionDay(uint256 day) private view returns (bool) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return (day + 3) % 7 < 5 && !holiday[uint32(day)];
    }

    /// @dev A session day with no later session day in the same ISO week (Monday-Sunday). Only the remaining weekdays
    ///      can take the weekly away, so the scan stops at Saturday: at most four holiday reads.
    function _isWeeklyDay(uint256 day) private view returns (bool) {
        if (!_isSessionDay(day)) return false;
        for (uint256 later = day + 1; (later + 3) % 7 < 5; ++later) {
            // forge-lint: disable-next-line(unsafe-typecast)
            if (!holiday[uint32(later)]) return false;
        }
        return true;
    }

    /// @dev The 16:00:00 New York instant of the date `day`. Whole dates are compared against the switch Sundays: the
    ///      switch happens at 02:00 local, so a switch Sunday's 16:00 already has the new offset.
    function _closeOf(uint256 day) private pure returns (uint256) {
        return day * DAY + (_isDstDate(day) ? CLOSE_UTC_EDT : CLOSE_UTC_EST);
    }

    /// @dev Whether New York is on daylight time for most of the date `day` (from its 02:00 onward on a switch Sunday).
    function _isDstDate(uint256 day) private pure returns (bool) {
        (uint256 startDay, uint256 endDay) = _dstDays(_yearOf(day));
        return day >= startDay && day < endDay;
    }

    /// @dev Day indexes of the second Sunday of March (EDT starts) and the first Sunday of November (EST resumes) of
    ///      `year`. November 1 is always March 1 + 245 days (March through October, no February in between).
    function _dstDays(uint256 year) private pure returns (uint256 startDay, uint256 endDay) {
        uint256 march1 = _daysFromCivil(year, 3, 1);
        // Sunday = 0 weekday numbering here: day 0 was a Thursday (4). Days to the next Sunday, 0 when already Sunday.
        startDay = march1 + (7 - (march1 + 4) % 7) % 7 + 7;
        uint256 november1 = march1 + 245;
        endDay = november1 + (7 - (november1 + 4) % 7) % 7;
    }

    /// @dev The calendar year of day index `day`, from Howard Hinnant's civil_from_days
    ///      (https://howardhinnant.github.io/date_algorithms.html#civil_from_days) restricted to day >= 0, so every
    ///      intermediate is non-negative and unsigned arithmetic is exact. The algorithm counts years from March 1, in
    ///      400-year eras of 146097 days, so the leap day is the last day of its computational year.
    function _yearOf(uint256 day) private pure returns (uint256 year) {
        uint256 z = day + 719_468; // days from 0000-03-01 to 1970-01-01
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097; // [0, 146096]
        uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365], day of the March-based year
        uint256 mp = (5 * doy + 2) / 153; // [0, 11], March = 0
        year = yoe + era * 400;
        // January and February (mp 10, 11) belong to the next calendar year.
        if (mp >= 10) ++year;
    }

    /// @dev Hinnant's days_from_civil for year >= 1970, the inverse of {_yearOf}'s full form. month 1-12, dom 1-31.
    function _daysFromCivil(uint256 year, uint256 month, uint256 dom) private pure returns (uint256) {
        if (month <= 2) --year;
        uint256 era = year / 400;
        uint256 yoe = year - era * 400; // [0, 399]
        uint256 doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + dom - 1; // [0, 365]
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
        return era * 146_097 + doe - 719_468;
    }
}
