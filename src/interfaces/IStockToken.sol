// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice A Robinhood Chain Stock Token.
/// @dev These are ERC-20 debt securities issued by Robinhood Assets (Jersey) Limited,
///      NOT equity. 18 decimals. They expose an ERC-8056 `uiMultiplier()` that accretes
///      with dividends and splits.
///
///      CRITICAL ACCOUNTING ASSUMPTION: the token is NON-REBASING. `balanceOf` is raw and
///      does not move on its own; `uiMultiplier()` moves instead, and the UI multiplies.
///      Every share calculation in this repo uses raw balances. If a Stock Token ever
///      rebases `balanceOf`, the vault's share math breaks and this integration must be
///      revisited. See ops/recon/R6-stock-token.md.
interface IStockToken is IERC20 {
    function decimals() external view returns (uint8);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);

    /// @notice ERC-8056 display multiplier, 1e18-scaled. Display only. Never used in share math.
    function uiMultiplier() external view returns (uint256);

    /// @notice True when the issuer's price oracle is halted. The vault refuses to write
    ///         a new call while this is true.
    function oraclePaused() external view returns (bool);
}

/// @notice The ERC-8056 surface on its own, for optional/defensive staticcalls.
/// @dev The vault probes these with low-level staticcalls so that a token which does not
///      implement them degrades gracefully instead of bricking the roll.
interface IERC8056 {
    function uiMultiplier() external view returns (uint256);
}
