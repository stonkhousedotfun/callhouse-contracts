// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Plain mintable ERC-20 with configurable decimals. Stands in for USDG (6 dp).
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    /// @dev Lets a test model a stablecoin blocklist or a global pause, which is what makes the
    ///      "a blocked fee recipient must not freeze the vault" property testable.
    mapping(address => bool) public blocked;
    bool public paused;

    error Blocked(address who);
    error Paused();

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _decimals = d;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function setBlocked(address who, bool v) external {
        blocked[who] = v;
    }

    function setPaused(bool v) external {
        paused = v;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert Paused();
        if (blocked[from]) revert Blocked(from);
        if (blocked[to]) revert Blocked(to);
        super._update(from, to, value);
    }
}
