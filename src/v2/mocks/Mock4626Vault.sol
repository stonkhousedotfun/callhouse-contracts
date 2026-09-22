// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Mock4626Vault
/// @notice Test double for T-104: an ERC-4626 whose WITHDRAWABLE amount and whose honesty are independently settable.
/// @dev {maxRedeem} is capped by {withdrawCap} so {maxWithdraw} (which is derived from it) can be throttled while
///      {convertToAssets}(balance) stays large — that is the {IEarnVenueAdapter.withdrawable} vs {totalAssets} split.
///      {depositFeeBps} / {withdrawFeeBps} skim underlying to {feeSink} inside {_transferIn}/{_transferOut}, so an
///      adapter that trusted the 4626 return value would disagree with the measured asset-balance delta.
contract Mock4626Vault is ERC4626 {
    using SafeERC20 for IERC20;

    uint256 public withdrawCap;
    uint16 public depositFeeBps;
    uint16 public withdrawFeeBps;
    address public feeSink;

    constructor(IERC20 asset_) ERC20("Mock4626", "m4626") ERC4626(asset_) {
        withdrawCap = type(uint256).max;
        feeSink = address(0xdead);
    }

    function setWithdrawCap(uint256 cap) external {
        withdrawCap = cap;
    }

    function setFees(uint16 depositBps, uint16 withdrawBps) external {
        depositFeeBps = depositBps;
        withdrawFeeBps = withdrawBps;
    }

    /// @dev Cap shares so {maxWithdraw} follows. See OZ ERC4626: override {maxRedeem}, not only {maxWithdraw}.
    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 shares = super.maxRedeem(owner);
        uint256 assets = convertToAssets(shares);
        if (assets <= withdrawCap) return shares;
        return previewWithdraw(withdrawCap);
    }

    function _transferIn(address from, uint256 assets) internal override {
        IERC20 token = IERC20(asset());
        token.safeTransferFrom(from, address(this), assets);
        uint256 fee = (assets * depositFeeBps) / 10_000;
        if (fee != 0) token.safeTransfer(feeSink, fee);
    }

    function _transferOut(address to, uint256 assets) internal override {
        IERC20 token = IERC20(asset());
        uint256 fee = (assets * withdrawFeeBps) / 10_000;
        uint256 net = assets - fee;
        if (fee != 0) token.safeTransfer(feeSink, fee);
        token.safeTransfer(to, net);
    }
}
