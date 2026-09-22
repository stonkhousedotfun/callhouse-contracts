// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IStockZap
/// @notice Stateless wallet helpers for buying a routed Stock Token into a Clearinghouse ledger and selling a
///         wallet-held Stock Token back to USDG.
interface IStockZap {
    /// @notice Buys `asset` with USDG over the PayoutRouter's pinned route and credits the received Stock Token to
    ///         `to` in the Clearinghouse ledger.
    /// @param asset Registered 18-decimal Stock Token.
    /// @param usdgIn Exact USDG input, in USDG base units.
    /// @param minAssetOut Minimum Stock Token output, in token base units.
    /// @param to Clearinghouse ledger account to credit.
    /// @param deadline Last timestamp at which the call may execute.
    /// @return assetOut Stock Token amount bought and deposited.
    function writeZap(address asset, uint256 usdgIn, uint256 minAssetOut, address to, uint40 deadline)
        external
        returns (uint256 assetOut);

    /// @notice Sells `asset` pulled from the caller's wallet over the PayoutRouter's pinned route and pays USDG to
    ///         `to`. Stock held in the Clearinghouse must be withdrawn by the user first.
    /// @param asset Routed 18-decimal Stock Token.
    /// @param assetIn Exact Stock Token input, in token base units.
    /// @param minUsdgOut Minimum USDG output, in USDG base units.
    /// @param to Wallet receiving USDG.
    /// @param deadline Last timestamp at which the call may execute.
    /// @return usdgOut USDG paid to `to`.
    function exitZap(address asset, uint256 assetIn, uint256 minUsdgOut, address to, uint40 deadline)
        external
        returns (uint256 usdgOut);

    /// @notice USDG was swapped to a Stock Token and credited to `account`'s Clearinghouse ledger.
    event WriteZapped(
        address indexed account, address indexed asset, address caller, uint256 usdgIn, uint256 assetOut, uint8 venue
    );

    /// @notice A Stock Token was pulled from the caller's wallet, swapped to USDG and paid to `account`.
    event ExitZapped(
        address indexed account, address indexed asset, address caller, uint256 assetIn, uint256 usdgOut, uint8 venue
    );
}
