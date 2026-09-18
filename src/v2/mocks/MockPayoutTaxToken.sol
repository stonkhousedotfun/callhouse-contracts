// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice An 18-dp ERC-20 that burns `taxBps` of every transfer between two non-zero addresses, so the recipient
///         receives less than the amount sent. The UniV3PayoutAdapter suites use it to prove the adapter measures what
///         it pulled instead of trusting `amountIn`.
contract MockPayoutTaxToken is ERC20 {
    uint256 public immutable taxBps;

    constructor(uint256 taxBps_) ERC20("Taxed Stock Token", "TAXx") {
        taxBps = taxBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 tax = value * taxBps / 10_000;
            super._update(from, address(0), tax);
            value -= tax;
        }
        super._update(from, to, value);
    }
}
