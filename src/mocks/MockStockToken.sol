// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Stands in for a Robinhood Stock Token: 18 decimals, ERC-8056 `uiMultiplier()`, an
///         `oraclePaused()` gate, and the issuer powers that can hurt the vault.
/// @dev Mirrors the verified `Stock.sol` gates (integrations/robinhood-chain.md §3):
///      - `pause()`: `transfer`, `transferFrom`, `mint` and `burn` are `onlyNotPaused`. Approvals are
///        not transfers and keep working.
///      - blocklist: `transfer` checks `to` and `msg.sender`, `transferFrom` also `from`; `approve`
///        checks the spender and the caller. `isBlocked(address)` is the public view.
///      - `adminBurn(from, amount)` is a BARE `_burn` with no pause and no blocklist modifier: the
///        issuer can destroy tokens held by any address, including the vault, at any time. That is
///        the power AF-05 is about, so the mock must let a test exercise it against a paused or
///        blocked vault as well as a healthy one.
///      - The display multiplier can go DOWN as well as up (WEEK 2.0 -> 1.0 happened on chain);
///        `setUiMultiplier` accepts any value.
contract MockStockToken is ERC20 {
    uint256 private _uiMultiplier = 1e18;
    bool private _oraclePaused;
    bool public paused;
    mapping(address => bool) private _blocked;

    /// @dev Set for the duration of {adminBurn} so {_update} skips the pause and blocklist gates.
    bool private _adminBurning;

    error TokenPaused();
    error AccountBlocked(address account);

    event Paused();
    event Unpaused();
    event Blocked(address indexed account);
    event Unblocked(address indexed account);
    event AdminBurn(address indexed from, uint256 amount);
    event UIMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier);

    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                           DISPLAY MULTIPLIER
    //////////////////////////////////////////////////////////////*/

    /// @notice ERC-8056 display multiplier, 1e18-scaled. Never touches balances.
    function uiMultiplier() external view returns (uint256) {
        return _uiMultiplier;
    }

    /// @notice Move the multiplier as a dividend or split would. Balances stay raw. Decreases are
    ///         allowed, as on the live token (which only requires `> 0`; the mock accepts any value so
    ///         the share-maths tests can fuzz the whole range).
    function setUiMultiplier(uint256 m) external {
        emit UIMultiplierUpdated(_uiMultiplier, m);
        _uiMultiplier = m;
    }

    function oraclePaused() external view returns (bool) {
        return _oraclePaused;
    }

    function setOraclePaused(bool p) external {
        _oraclePaused = p;
    }

    /*//////////////////////////////////////////////////////////////
                          PAUSE / BLOCKLIST / BURN
    //////////////////////////////////////////////////////////////*/

    /// @notice Simulate the issuer halting all transfers, mints and burns.
    function pause() external {
        paused = true;
        emit Paused();
    }

    function unpause() external {
        paused = false;
        emit Unpaused();
    }

    function blockAccount(address who) external {
        _blocked[who] = true;
        emit Blocked(who);
    }

    function unblockAccount(address who) external {
        _blocked[who] = false;
        emit Unblocked(who);
    }

    function isBlocked(address who) external view returns (bool) {
        return _blocked[who];
    }

    /// @notice The issuer's seizure lever: a bare burn that ignores the pause and the blocklist.
    function adminBurn(address from, uint256 amount) external {
        _adminBurning = true;
        _burn(from, amount);
        _adminBurning = false;
        emit AdminBurn(from, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                ERC-20 GATES
    //////////////////////////////////////////////////////////////*/

    /// @dev Approvals survive a pause; a blocked caller or spender cannot approve.
    function approve(address spender, uint256 value) public override returns (bool) {
        if (_blocked[msg.sender]) revert AccountBlocked(msg.sender);
        if (_blocked[spender]) revert AccountBlocked(spender);
        return super.approve(spender, value);
    }

    /// @dev The caller is checked here; `from` and `to` are checked in {_update}.
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (_blocked[msg.sender]) revert AccountBlocked(msg.sender);
        return super.transferFrom(from, to, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (!_adminBurning) {
            if (paused) revert TokenPaused();
            if (from != address(0) && _blocked[from]) revert AccountBlocked(from);
            if (to != address(0) && _blocked[to]) revert AccountBlocked(to);
        }
        super._update(from, to, value);
    }
}
