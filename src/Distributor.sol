// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Distributor
/// @notice USDG accrual for vault shareholders.
/// @dev Inherited by {Vault}. It is an abstract base rather than a standalone contract on
///      purpose: the accrual must be settled on every share balance change, and only the
///      share token itself can hook that.
///
///      DESIGN NOTE — USDG is deliberately NOT part of the share price.
///      TECHSPEC 4.2 forbids marking the short call to market, and folding USDG into
///      `totalAssets` would make the share price jump the instant a premium lands, which is
///      the same dishonesty in a different coat. Instead premium accrues to an index and is
///      claimed separately. Share price moves only when the asset balance moves.
///
///      ACCRUAL MODEL
///      `accUsdgPerShare` is a monotonically increasing index, PRECISION-scaled USDG per
///      share. Each account snapshots the index at its last balance change; the difference
///      times its balance is what it earned since. This is the standard MasterChef pattern
///      with the settle moved into `_update`, which makes it correct across transfers,
///      mints and burns without any caller discipline.
abstract contract Distributor is ERC20 {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Index scaling. 1e27 rather than 1e18 because USDG has only 6 decimals: at 1e18 a
    ///      small weekly premium against a large share supply would round to zero per share.
    uint256 internal constant ACC_PRECISION = 1e27;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The payout token. Yield is USDG or it is nothing.
    IERC20 public immutable usdg;

    /// @notice PRECISION-scaled USDG accrued per share since deployment.
    uint256 public accUsdgPerShare;

    /// @dev Per-account snapshot of `accUsdgPerShare` at that account's last balance change.
    mapping(address => uint256) private _accSnapshot;

    /// @dev Per-account settled-but-unclaimed USDG, in USDG base units.
    mapping(address => uint256) private _accrued;

    /// @notice Remainder from the last distribution that was too small to index. Carried
    ///         into the next one so nothing is silently lost.
    uint256 public usdgDust;

    /// @notice USDG received while `totalSupply() == 0` and therefore not attributable to
    ///         anyone yet. Rolled into the next distribution.
    uint256 public usdgUnallocated;

    /// @notice The portion of this contract's USDG balance that has already been attributed.
    /// @dev THE ACCOUNTING ANCHOR. New premium is detected as `balance - usdgAccounted`, and
    ///      every outflow decrements this in lockstep with the real transfer.
    ///
    ///      It replaces an earlier `balance - (owed + reserved + dust + ...)` derivation that
    ///      looked equivalent and was not. `accUsdgPerShare` floors once per distribution, while
    ///      a holder's pending accrual floors once over the COMBINED delta since they last
    ///      settled, and floor(b*(d1+d2)) >= floor(b*d1) + floor(b*d2). So the sum of what
    ///      holders could claim drifts a base unit above the sum of what was recorded as
    ///      distributed. The derived figure then underflowed, which permanently bricked every
    ///      deposit, mint and roll close. A checkpointed balance cannot drift: it is measured,
    ///      not inferred.
    uint256 public usdgAccounted;

    /// @notice Lifetime USDG pushed into the index, net of protocol fees. Informational.
    uint256 public totalUsdgDistributed;

    /// @notice Lifetime USDG actually paid out to holders.
    uint256 public totalUsdgClaimed;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event UsdgDistributed(uint256 amount, uint256 accUsdgPerShare, uint256 totalSupply);
    event UsdgUnallocated(uint256 amount, uint256 totalUnallocated);
    event ClaimUsdg(address indexed account, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NothingToClaim();
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IERC20 usdg_) {
        if (address(usdg_) == address(0)) revert ZeroAddress();
        usdg = usdg_;
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice USDG claimable by `account` right now, settled plus unsettled.
    function claimableUsdg(address account) public view returns (uint256) {
        return _accrued[account] + _pending(account);
    }

    /// @dev Unsettled accrual for `account` at the current index.
    function _pending(address account) internal view returns (uint256) {
        uint256 bal = balanceOf(account);
        if (bal == 0) return 0;
        uint256 delta = accUsdgPerShare - _accSnapshot[account];
        if (delta == 0) return 0;
        return (bal * delta) / ACC_PRECISION;
    }

    /*//////////////////////////////////////////////////////////////
                              DISTRIBUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Push `amount` USDG into the per-share index.
    /// @dev Caller must have already taken the protocol fee and must already hold the USDG.
    ///      Any remainder too small to index, and anything received while there are no
    ///      shares, is carried forward rather than dropped.
    function _distributeUsdg(uint256 amount) internal {
        uint256 pot = amount + usdgDust + usdgUnallocated;
        usdgDust = 0;
        usdgUnallocated = 0;

        uint256 supply = totalSupply();
        if (supply == 0 || pot == 0) {
            usdgUnallocated = pot;
            if (pot != 0) emit UsdgUnallocated(amount, pot);
            return;
        }

        uint256 indexDelta = (pot * ACC_PRECISION) / supply;
        // What the index can actually represent, floored to the share unit.
        uint256 credited = (indexDelta * supply) / ACC_PRECISION;

        accUsdgPerShare += indexDelta;
        usdgDust = pot - credited;
        totalUsdgDistributed += credited;

        emit UsdgDistributed(credited, accUsdgPerShare, supply);
    }

    /*//////////////////////////////////////////////////////////////
                                CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim all USDG accrued to the caller.
    /// @dev Never blocked by the pause or halt. TECHSPEC 4.9: halting must never block
    ///      `claimUsdg`, `queueRedeem` or `rollClose`.
    function claimUsdg() external returns (uint256 amount) {
        return _claimUsdg(msg.sender, msg.sender);
    }

    /// @notice Claim all USDG accrued to the caller, sending it to `to`.
    function claimUsdgTo(address to) external returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        return _claimUsdg(msg.sender, to);
    }

    function _claimUsdg(address account, address to) internal returns (uint256 amount) {
        _settle(account);
        amount = _accrued[account];
        if (amount == 0) revert NothingToClaim();

        // Clamp to what the contract can actually back. `accUsdgPerShare` floors once per
        // distribution while an account's pending accrual floors once over the combined delta
        // since it last settled, and floor(b*(d1+d2)) >= floor(b*d1) + floor(b*d2). So the sum
        // of everyone's accrual can sit a base unit above the sum of what was distributed.
        // Clamping turns that into at most one base unit of unpaid dust for the last claimant
        // rather than a revert, or worse, a payout out of money that belongs to the redeem
        // queue.
        uint256 payable_ = _usdgAvailableForHolders();
        if (amount > payable_) amount = payable_;
        if (amount == 0) revert NothingToClaim();

        _accrued[account] -= amount;
        totalUsdgClaimed += amount;
        _debitUsdgOut(amount);
        usdg.safeTransfer(to, amount);
        emit ClaimUsdg(account, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                               SETTLING
    //////////////////////////////////////////////////////////////*/

    /// @dev Move `account`'s unsettled accrual into its settled balance and re-snapshot.
    function _settle(address account) internal {
        uint256 p = _pending(account);
        if (p != 0) _accrued[account] += p;
        _accSnapshot[account] = accUsdgPerShare;
    }

    /// @dev Settle both sides of every balance change before it happens. This is what makes
    ///      the accrual correct under transfers: whoever held the shares when the premium
    ///      landed keeps it, and the new holder starts from the current index.
    function _update(address from, address to, uint256 value) internal virtual override {
        if (from != address(0)) _settle(from);
        if (to != address(0) && to != from) _settle(to);
        super._update(from, to, value);
    }

    /// @dev Exposed for the vault's queue settlement, which must not strand accrual on
    ///      shares it is about to burn.
    function _settleAccount(address account) internal {
        _settle(account);
    }

    /// @dev USDG this contract may pay to share holders: everything it holds that is not
    ///      already promised to the redeem queue or owed as protocol fee.
    function _usdgAvailableForHolders() internal view virtual returns (uint256) {
        return usdg.balanceOf(address(this));
    }

    /// @dev Settle `account` and move its entire settled balance out, returning the amount.
    ///      Used once, on the escrow address, when the redeem queue is settled: the shares
    ///      sitting in escrow earned a real share of that week's premium, and it belongs to
    ///      the people who queued, not to the holders who stayed.
    function _takeAccrued(address account) internal returns (uint256 amount) {
        _settle(account);
        amount = _accrued[account];
        if (amount == 0) return 0;

        // Same clamp as {_claimUsdg}: never promise the queue money the vault does not hold.
        uint256 payable_ = _usdgAvailableForHolders();
        if (amount > payable_) amount = payable_;

        _accrued[account] -= amount;
        totalUsdgClaimed += amount;
    }

    /// @notice Indexed USDG not yet claimed. Informational only.
    /// @dev Saturating, because the index and the per-account accrual floor at different
    ///      points and the difference can go a base unit the wrong way. Nothing in the money
    ///      path reads this; {usdgAccounted} is the figure the harvest uses.
    function usdgOwed() public view returns (uint256) {
        uint256 d = totalUsdgDistributed;
        uint256 c = totalUsdgClaimed;
        return d > c ? d - c : 0;
    }

    /// @dev Record that `amount` USDG has left the contract, keeping {usdgAccounted} in step
    ///      with the real balance. Saturating so a rounding artefact can never revert a payout.
    function _debitUsdgOut(uint256 amount) internal {
        uint256 a = usdgAccounted;
        usdgAccounted = a > amount ? a - amount : 0;
    }

    /// @dev Mark the entire current balance as attributed. Called at the end of every accrual.
    function _markUsdgAccounted(uint256 balance) internal {
        usdgAccounted = balance;
    }
}
