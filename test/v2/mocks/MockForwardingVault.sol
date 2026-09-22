// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Where {MockForwardingVault} sends what it allocates. Holds the assets and lets its vault pull them back.
/// @dev Stands in for the live venue's allocator (0x44ABc1d6 on 4663, which supplies to Morpho Blue). It approves
///      its deployer for everything at construction, so the vault can recall allocated assets on a withdraw.
contract ForwardingSink {
    constructor(IERC20 asset_) {
        asset_.approve(msg.sender, type(uint256).max);
    }
}

/// @title MockForwardingVault
/// @notice T-OP-008: an ERC-4626 that mints correct shares for a deposit and then FORWARDS some or all of the
///         received assets onward, in the same call, to an allocator it does not count in its own token balance.
/// @dev THE VENUE {Mock4626Vault} CANNOT BE. `Mock4626Vault` HOLDS what it receives, so for it "the venue's asset
///      balance went up by X" and "X left the depositor" are the same number and no test written against it can
///      tell the two measures apart. The live Steakhouse USDG vault on 4663 does not hold: it passes the deposit
///      straight to its allocator, so its own USDG balance ends where it started while shares are minted. That
///      is the shape this mock reproduces.
///
///      {forwardBps} selects the shape: 10_000 forwards everything (the live venue), 0 holds everything (the
///      same behaviour as `Mock4626Vault` with no fees), anything between is the MIXED case -- the venue keeps
///      part and allocates part -- which is the one a naive fix gets wrong.
///
///      Share pricing stays honest: {totalAssets} counts the assets held here plus those allocated to {sink}, so
///      a forwarding venue is not mistaken for an empty one. A withdraw recalls any shortfall from {sink}.
contract MockForwardingVault is ERC4626 {
    using SafeERC20 for IERC20;

    /// @notice Share of each deposit sent on to {sink}, in basis points.
    uint16 public forwardBps;

    /// @notice The allocator every forwarded asset goes to. Deployed by this vault; it never holds shares.
    address public immutable sink;

    /// @notice Assets currently allocated to {sink}. Counted in {totalAssets}, absent from this contract's balance.
    uint256 public allocated;

    constructor(IERC20 asset_, uint16 forwardBps_) ERC20("MockForwarding4626", "mf4626") ERC4626(asset_) {
        require(forwardBps_ <= 10_000, "forwardBps");
        forwardBps = forwardBps_;
        sink = address(new ForwardingSink(asset_));
    }

    function setForwardBps(uint16 bps) external {
        require(bps <= 10_000, "forwardBps");
        forwardBps = bps;
    }

    /// @dev Held here plus allocated onward. Without the second term every forwarded deposit would read as a loss.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + allocated;
    }

    /// @dev Pull the full deposit, then allocate `forwardBps` of it onward inside the same call, which is what
    ///      leaves this vault's own asset balance short of what the depositor actually paid.
    function _transferIn(address from, uint256 assets) internal override {
        IERC20 token = IERC20(asset());
        token.safeTransferFrom(from, address(this), assets);
        uint256 onward = (assets * forwardBps) / 10_000;
        if (onward != 0) {
            allocated += onward;
            token.safeTransfer(sink, onward);
        }
    }

    /// @dev Recall from the allocator whatever the held balance cannot cover, then pay.
    function _transferOut(address to, uint256 assets) internal override {
        IERC20 token = IERC20(asset());
        uint256 held = token.balanceOf(address(this));
        if (held < assets) {
            uint256 recall = assets - held;
            allocated -= recall;
            token.safeTransferFrom(sink, address(this), recall);
        }
        token.safeTransfer(to, assets);
    }
}
