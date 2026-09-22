// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IExpiryCalendar
/// @notice The v2 expiry grid: 16:00 America/New_York on NYSE session days (ADR-07, architecture §3.2).
/// @dev A separate contract behind an admin-settable Clearinghouse pointer that affects NEW series only. The US DST
///      rule is implemented on chain; holidays and special expiries are admin-maintained. The admin setters
///      (`setHolidays`, `setSpecialExpiry`, LISTING, 1 h) are implementation surface and not frozen here; their
///      two events are. Every function below is a read callable by anyone. Early-close days (13:00) are normal days.
interface IExpiryCalendar {
    /// @notice Whether a series may expire at `ts`.
    /// @dev True when `ts` is exactly 16:00:00 New York on a Mon-Fri date whose day index is not a holiday, or when
    ///      `ts` is a whitelisted special expiry.
    /// @param ts Candidate expiry, unix seconds.
    /// @return True for a valid expiry.
    function isValidExpiry(uint40 ts) external view returns (bool);

    /// @notice Whether `ts` is a weekly expiry.
    /// @dev A valid SESSION-DAY expiry with no later session-day expiry in the same ISO week (Friday, or Thursday when
    ///      Friday is a holiday). Special expiries never count, in either direction.
    /// @param ts Candidate expiry, unix seconds.
    /// @return True for a weekly expiry.
    function isWeekly(uint40 ts) external view returns (bool);

    /// @notice The next valid expiry strictly after `afterTs`.
    /// @dev Bounded search of 14 days; reverts when nothing is found inside it. The AutoRoller calls this with
    ///      `now + minLead` so a roll never lands on an expiry that is about to start its averaging window.
    /// @param afterTs Exclusive lower bound, unix seconds.
    /// @param weekly True to return only weekly expiries (see {isWeekly}).
    /// @return Expiry, unix seconds.
    function nextExpiry(uint40 afterTs, bool weekly) external view returns (uint40);

    /// @notice 09:30-16:00 New York on a session day. AutoRoller only rolls inside it.
    /// @dev Chainlink advises against opening positions on overnight or extended-session prints, and a
    ///      permissionless roll must not let a caller pick a thin-session price for someone else's sale.
    /// @param ts Instant to test, unix seconds.
    /// @return True inside the regular session.
    function isRegularSession(uint40 ts) external view returns (bool);

    /// @notice New York's offset from UTC at `ts`.
    /// @dev EDT (UTC-4) from the second Sunday of March 02:00 local to the first Sunday of November 02:00 local,
    ///      else EST (UTC-5). Pure: the rule is compiled, not configured.
    /// @param ts Instant, unix seconds.
    /// @return secondsEastOfUtc -14400 or -18000
    function newYorkOffset(uint40 ts) external pure returns (int32 secondsEastOfUtc); // -14400 or -18000

    /// @notice A holiday was added or removed (LISTING).
    /// @param dayIndex floor(ts / 86400) of the New York date's 16:00 instant.
    /// @param isHoliday True when the date is no longer a session day.
    event HolidaySet(uint32 indexed dayIndex, bool isHoliday);

    /// @notice A special expiry was whitelisted or removed (LISTING).
    /// @param ts Expiry, unix seconds.
    /// @param allowed True when `ts` is now valid regardless of the grid.
    event SpecialExpirySet(uint40 indexed ts, bool allowed);
}
