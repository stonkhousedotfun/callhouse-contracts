// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IEarnVenueAdapter} from "../interfaces/IEarnVenueAdapter.sol";

/// @title MockReentrantVenue
/// @notice {IEarnVenueAdapter} double that, on {withdraw}, attempts a call back into the OrderBook before paying.
/// @dev T-105: proves the book's reentrancy guard, held for the whole {take}, stops `place` / `cancel` / `take`
///      from inside {IFundingSource.fund} (IFundingSource.sol:19-21). The inner call's success is recorded so a
///      test can assert it failed without the outer `fund` having to revert (EarnVault.fund swallows adapter
///      reverts and returns a zero delivery).
contract MockReentrantVenue is IEarnVenueAdapter {
    using SafeERC20 for IERC20;

    IERC20 private immutable _token;
    uint256 public held;
    address public book;
    bytes public reenterCalldata;
    /// @notice Result of the most recent reentry attempt from {withdraw}.
    bool public lastReenterOk;
    /// @dev SEC-30 (T-451): the vault this venue claims to belong to, or zero to answer whoever asks.
    ///      {EarnVault.setAdapter} probes `vault()` and refuses an adapter that cannot name THIS vault, so without
    ///      this getter the probe refused this double and {EarnVaultFundingTest} could not reach the book guard it
    ///      exists to prove -- it reverted at `setAdapter` instead. Same shape as {MockEarnVenue}, deliberately:
    ///      answering the CALLER by default keeps every existing wiring working, and {setVault} pins it so the
    ///      refusal itself stays testable. A real adapter's `vault` is immutable and can do neither.
    address private _vaultOverride;

    constructor(IERC20 token_) {
        _token = token_;
    }

    /// @notice Pin the vault this venue claims to belong to. Zero restores "answer whoever asks".
    function setVault(address vault_) external {
        _vaultOverride = vault_;
    }

    /// @notice SEC-30: what {EarnVault.setAdapter} probes. Defaults to the caller.
    function vault() external view returns (address) {
        return _vaultOverride == address(0) ? msg.sender : _vaultOverride;
    }

    function setBook(address book_) external {
        book = book_;
    }

    function setReenterCalldata(bytes calldata data) external {
        reenterCalldata = data;
    }

    function asset() external view returns (address) {
        return address(_token);
    }

    function deposit(uint256 assets) external returns (uint256 deposited) {
        if (assets == 0) return 0;
        uint256 before = _token.balanceOf(address(this));
        _token.safeTransferFrom(msg.sender, address(this), assets);
        deposited = _token.balanceOf(address(this)) - before;
        held += deposited;
    }

    function withdraw(uint256 assets, address to) external returns (uint256 withdrawn) {
        (lastReenterOk,) = book.call(reenterCalldata);
        uint256 bal = _token.balanceOf(address(this));
        withdrawn = assets > bal ? bal : assets;
        if (withdrawn == 0) return 0;
        if (withdrawn > held) withdrawn = held;
        held -= withdrawn;
        _token.safeTransfer(to, withdrawn);
    }

    function withdrawable() external view returns (uint256) {
        uint256 bal = _token.balanceOf(address(this));
        return held > bal ? bal : held;
    }

    function totalAssets() external view returns (uint256) {
        return held;
    }
}
