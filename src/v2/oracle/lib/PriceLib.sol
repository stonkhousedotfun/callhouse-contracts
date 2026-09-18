// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V2Constants} from "../../interfaces/V2Constants.sol";

/// @title PriceLib
/// @notice Pure price helpers shared by the v2 price sources: feed-answer normalisation and the round jump rule.
/// @dev UNITS. Every price out of this library is USDG base units (6 dp) per whole share, $215.00 = 215_000_000, the
///      convention of ADR-04 and of v1's `Policy.normalizeSpot`.
///
///      WHY NOT IMPORT `Policy`. {normalizeAnswer} is `Policy.normalizeSpot`'s arithmetic, copied: v2 does not link v1
///      code (v1 is frozen and its library reverts `SpotZero`), and a price source must never revert from `latest` or
///      `windowPrice` (IPriceSource), so this version reports `ok = false` where normalizeSpot reverted.
library PriceLib {
    /// @dev The largest price a source reports. V2Types.Series.settlementPrice is uint128, and keeping every price
    ///      under 2^128 also keeps a TWAP accumulator (price x seconds, seconds < 2^40) far inside uint256.
    uint256 internal constant MAX_PRICE = type(uint128).max;

    /// @notice Converts a Chainlink answer with `feedDecimals` decimals to USDG base units (6 dp) per whole share.
    /// @dev Truncates toward zero when the feed has more than 6 decimals, exactly as `Policy.normalizeSpot`. Never
    ///      reverts: an answer <= 0, a result of 0 (a sub-micro-dollar print) or a result above {MAX_PRICE} is not ok.
    /// @param answer Raw feed answer, `feedDecimals` decimals of USD per whole share.
    /// @param feedDecimals The feed's `decimals()`.
    /// @return ok False when the answer cannot be a price.
    /// @return price USDG base units (6 dp) per whole share; 0 when not ok.
    function normalizeAnswer(int256 answer, uint8 feedDecimals) internal pure returns (bool ok, uint256 price) {
        if (answer <= 0) return (false, 0);
        // casting to 'uint256' is safe because the line above returns on answer <= 0
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 a = uint256(answer);
        if (feedDecimals >= 6) {
            // 10 ** 77 is the last power of ten below 2^256; any positive int256 divided by it is already 0, so a
            // larger exponent is answered without computing (and overflowing) the power.
            uint256 exp = uint256(feedDecimals) - 6;
            if (exp > 76) return (false, 0);
            price = a / (10 ** exp);
        } else {
            // At most x 1e6: bounding `a` first keeps the product inside uint256 and the check below catches the rest.
            if (a > MAX_PRICE) return (false, 0);
            price = a * (10 ** (6 - uint256(feedDecimals)));
        }
        if (price == 0 || price > MAX_PRICE) return (false, 0);
        return (true, price);
    }

    /// @notice Whether `newer` moved more than `maxJumpBps` away from its predecessor `older`.
    /// @dev Measured against the OLDER price: |newer - older| x BPS > older x maxJumpBps. A 1e8 mis-scaled print is a
    ///      10,000+ bps move up; a mis-scale down is a move of almost 10,000 bps, which is why the sources cap the
    ///      configurable bound well below that. Exactly `maxJumpBps` is allowed. Both inputs are <= {MAX_PRICE}, so the
    ///      products cannot overflow.
    /// @param newer The later round's price, USDG 6 dp per share.
    /// @param older The earlier round's price, USDG 6 dp per share (non-zero).
    /// @param maxJumpBps Allowed move, basis points of `older`.
    /// @return True when the move is larger than allowed.
    function exceedsJump(uint256 newer, uint256 older, uint256 maxJumpBps) internal pure returns (bool) {
        uint256 diff = newer > older ? newer - older : older - newer;
        return diff * V2Constants.BPS > older * maxJumpBps;
    }
}
