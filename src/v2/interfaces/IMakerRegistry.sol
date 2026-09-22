// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IMakerRegistry
/// @notice Per-maker rebate tiers read by the OrderBook on every fill (roadmap 1.4, architecture §3.10).
/// @dev `setTier(maker, bps)` is FEE_MANAGER (48 h) implementation surface; TierSet is frozen here.
interface IMakerRegistry {
    /// @notice Share of the taker fee paid to `maker` as rebate.
    /// @param maker Maker address.
    /// @return Bps of the taker fee (<= BPS); 0 = use the book's FeeParams.makerRebateBps.
    function rebateBps(address maker) external view returns (uint16); // 0 = use book default

    /// @notice FEE_MANAGER set `maker`'s tier; 0 returns it to the book default.
    event TierSet(address indexed maker, uint16 rebateBps);
}
