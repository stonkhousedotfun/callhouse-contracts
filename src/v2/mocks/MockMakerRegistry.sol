// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IMakerRegistry} from "../interfaces/IMakerRegistry.sol";

/// @title MockMakerRegistry
/// @notice Test double of IMakerRegistry for the OrderBook suites (C2-06): settable per-maker rebate tiers, plus the
///         failure modes the book must survive (a reverting read, and an answer above 10_000 bps).
/// @dev No roles. The real MakerRegistry is C2-11.
contract MockMakerRegistry is IMakerRegistry {
    mapping(address maker => uint16) private _tier;
    bool public reverts;

    error RegistryDown();

    /// @notice Sets `maker`'s tier in bps of the taker fee; 0 returns it to the book default. Any value is accepted
    ///         so a test can hand the book an out-of-range answer.
    function setTier(address maker, uint16 bps) external {
        _tier[maker] = bps;
        emit TierSet(maker, bps);
    }

    /// @notice Makes {rebateBps} revert.
    function setReverts(bool on) external {
        reverts = on;
    }

    /// @inheritdoc IMakerRegistry
    function rebateBps(address maker) external view returns (uint16) {
        if (reverts) revert RegistryDown();
        return _tier[maker];
    }
}
