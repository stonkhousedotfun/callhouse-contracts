// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A WETH9 stand-in for the V4BuybackExecutor suites: wrap, unwrap, and the ways a broken wrapper can pay.
/// @dev Modes for {withdraw}:
///        - `Good`: burns `wad` and sends exactly `wad` wei back, as WETH9 does.
///        - `ShortPay`: burns `wad` but sends only `shortPayBps` of it, so the executor's "ETH rose by exactly the
///          WETH that was burned" check has something to catch.
///        - `NoBurn`: sends the ETH without burning, so the WETH balance does not return to where it was.
///      `withdraw` pays with a plain `call`, like WETH9, so a recipient without a `receive` reverts.
contract MockWeth9 is ERC20 {
    enum Mode {
        Good,
        ShortPay,
        NoBurn
    }

    Mode public mode;
    uint16 public shortPayBps = 10_000;

    error EthTransferFailed();

    constructor() ERC20("Wrapped Ether", "WETH") {}

    function setMode(Mode mode_, uint16 shortPayBps_) external {
        mode = mode_;
        shortPayBps = shortPayBps_;
    }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) external {
        uint256 pay = wad;
        if (mode == Mode.ShortPay) pay = wad * shortPayBps / 10_000;
        if (mode != Mode.NoBurn) _burn(msg.sender, wad);
        (bool ok,) = msg.sender.call{value: pay}("");
        if (!ok) revert EthTransferFailed();
    }

    /// @notice Fund the wrapper so {withdraw} has ETH to pay with when a test minted WETH directly.
    receive() external payable {}

    /// @notice Mint WETH without sending ETH; a test pairs it with a direct ETH transfer to this contract.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
