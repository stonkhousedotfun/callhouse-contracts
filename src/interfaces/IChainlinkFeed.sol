// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Chainlink AggregatorV3 surface.
/// @dev Used ONLY as a display value and as the OTM-band write-gate. It is never in the
///      settlement path: nothing about redeem, harvest or the redeem queue reads a price.
///      That is deliberate — it keeps an oracle out of the money path.
interface IChainlinkFeed {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
