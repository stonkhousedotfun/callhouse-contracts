// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title V2Ids
/// @notice ERC-1155 id scheme of the Clearinghouse: the one formula IClearinghouse.longIdOf documents.
/// @dev longId = keccak256(abi.encode(underlying, isPut, strike, expiry)) with the low bit cleared; shortId sets it.
///      abi.encode (not encodePacked) so every field is a full 32-byte word and off-chain mirrors are a plain
///      `encodeAbiParameters(address, bool, uint128, uint40)`. Clearing one bit halves the id space: two series share
///      an id with probability 2^-255, and Clearinghouse.createSeries still checks the stored tuple
///      (V2Errors.SeriesIdCollision) so the question never has to be argued. The test vectors in
///      test/v2/fixtures/series-ids.json (script/v2/EmitSeriesIds.s.sol) are what seriesId.ts is tested against.
library V2Ids {
    /// @notice Long id of the series (underlying, isPut, strike, expiry). Low bit always 0.
    /// @param underlying 18-dp Stock Token.
    /// @param isPut True for a put.
    /// @param strike USDG base units (6 dp) per whole share.
    /// @param expiry Unix seconds.
    /// @return The long id.
    function longIdOf(address underlying, bool isPut, uint128 strike, uint40 expiry) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(underlying, isPut, strike, expiry))) & ~uint256(1);
    }

    /// @notice Short id paired with `longId`: `longId | 1`. A short id passed in comes back unchanged.
    /// @param longId Long id.
    /// @return The short id.
    function shortIdOf(uint256 longId) internal pure returns (uint256) {
        return longId | 1;
    }

    /// @notice Whether `id` is a short id (low bit 1).
    /// @param id Any Clearinghouse ERC-1155 id.
    /// @return True for a short id.
    function isShortId(uint256 id) internal pure returns (bool) {
        return id & 1 == 1;
    }
}
