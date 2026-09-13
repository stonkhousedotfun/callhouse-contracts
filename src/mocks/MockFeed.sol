// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Chainlink-shaped price feed with a staleness toggle.
contract MockFeed {
    uint8 public decimals;
    string public description;

    int256 private _answer;
    uint256 private _updatedAt;
    uint80 private _roundId = 1;

    constructor(uint8 d, int256 initialAnswer, string memory desc) {
        decimals = d;
        _answer = initialAnswer;
        _updatedAt = block.timestamp;
        description = desc;
    }

    function setAnswer(int256 a) external {
        _answer = a;
        _updatedAt = block.timestamp;
        _roundId++;
    }

    /// @notice Freeze `updatedAt` in the past so staleness checks trip.
    function setUpdatedAt(uint256 t) external {
        _updatedAt = t;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }
}
