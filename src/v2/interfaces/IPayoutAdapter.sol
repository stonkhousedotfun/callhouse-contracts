// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IPayoutAdapter
/// @notice Converts an ITM call long's Stock Token payout to USDG through Uniswap v3 (ADR-11, architecture §3.9).
/// @dev The Clearinghouse does not trust the adapter: it verifies usdgOut >= value at the settlement price (or at a
///      fresh oracle spot above it) * (1 - min(maxPayoutSlippageBps + route fee, MAX_PAYOUT_SLIPPAGE_CEIL_BPS)) itself
///      and pays in kind on any failure. The route fee is this adapter's own {routeFeeBps} answer, read with a gas-capped staticcall and
///      clamped to MAX_ROUTE_FEE_BPS (a failed or short read counts as 0), so a bad adapter can cost a holder at most
///      min(maxPayoutSlippageBps + MAX_ROUTE_FEE_BPS, MAX_PAYOUT_SLIPPAGE_CEIL_BPS) of one payout (INTERFACE_VERSION
///      6). Per-asset routes are DEFAULT_ADMIN_ROLE implementation surface.
interface IPayoutAdapter {
    /// @notice Pulls `amountIn` of `asset` from the caller, swaps it to USDG and sends the USDG to `to`.
    /// @dev Anyone (the Clearinghouse is the intended caller; ERC-20 approval to the adapter). Uses the configured
    ///      route with amountOutMinimum = minOut and reverts otherwise. Holds nothing between calls.
    /// @param asset 18-dp Stock Token to sell.
    /// @param amountIn Asset base units.
    /// @param minOut Minimum USDG base units.
    /// @param to USDG recipient.
    /// @return out USDG base units sent to `to`.
    function swapToUsdg(address asset, uint256 amountIn, uint256 minOut, address to) external returns (uint256 out);

    /// @notice The pool fee of `asset`'s route, bps rounded up (INTERFACE_VERSION 6).
    /// @dev The Clearinghouse measures its slippage bound above this fee, so the bound caps what a redeemer can
    ///      capture beyond the swap's own cost. A Uniswap v3 route reports its fee tier / 100 rounded up (500 -> 5,
    ///      3000 -> 30, 10000 -> 100).
    /// @param asset 18-dp Stock Token.
    /// @return feeBps Pool fee in bps rounded up; 0 when the asset has no route.
    function routeFeeBps(address asset) external view returns (uint16 feeBps);
}
