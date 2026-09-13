// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Stands in for a Robinhood Stock Token: 18 decimals, ERC-8056 `uiMultiplier()`,
///         an `oraclePaused()` gate, and an issuer freeze that can brick transfers.
/// @dev The freeze is the point. TECHSPEC calls issuer freeze an existential risk, and the
///      only honest test is one where `transfer` actually reverts mid-cycle.
contract MockStockToken is ERC20 {
    uint256 private _uiMultiplier = 1e18;
    bool private _oraclePaused;
    bool public frozen;

    error IssuerFreeze();

    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice ERC-8056 display multiplier, 1e18-scaled. Never touches balances.
    function uiMultiplier() external view returns (uint256) {
        return _uiMultiplier;
    }

    /// @notice Move the multiplier as a dividend or split would. Balances stay raw.
    function setUiMultiplier(uint256 m) external {
        _uiMultiplier = m;
    }

    function oraclePaused() external view returns (bool) {
        return _oraclePaused;
    }

    function setOraclePaused(bool p) external {
        _oraclePaused = p;
    }

    /// @notice Simulate Robinhood Assets (Jersey) Limited halting transfers.
    function setFrozen(bool f) external {
        frozen = f;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (frozen) revert IssuerFreeze();
        super._update(from, to, value);
    }
}
