// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Managed} from "./access/Managed.sol";
import {IKeeperRewards} from "./interfaces/IKeeperRewards.sol";
import {V2Constants} from "./interfaces/V2Constants.sol";
import {V2Errors} from "./interfaces/V2Errors.sol";

/// @title KeeperRewards
/// @notice Small USDG bounties for the permissionless lifecycle calls that advance state (ADR-06, architecture §3.7):
///         SettlementOracle.snapshot / finalize, Clearinghouse.settle / redeem, AutoRoller.roll.
/// @dev Paid from a treasury-funded USDG budget, under a per-action bounty (<= V2Constants.MAX_BOUNTY) and a daily cap.
///      Bounties are sized near gas cost (~$0.05 per call on 4663), so a keeper who self-deals to farm them loses money.
///
///      ELIGIBILITY IS THE CALLER'S JOB. This contract does not know what a series, an expiry or a holder is. The
///      rules that make a call worth paying are enforced by the registered CALLING contracts before they call
///      {reward}: SNAPSHOT and FINALIZE only with open interest on the expiry, SETTLE only when the series has long
///      supply, REDEEM only when the holder's payout is at least minRedeemPayout, ROLL only when the roll places at
///      least minRollUnits. A registered caller can therefore spend the budget on any keeper and any action; only
///      register protocol contracts that apply those gates. The bounty table, the daily cap and the balance bound the
///      damage if one does not.
///
///      NEVER BLOCKS A LIFECYCLE CALL. {reward} reverts only for an unregistered caller (NotAuthorized). An unset
///      bounty, an empty budget, a reached cap, a USDG transfer that reverts or returns false (paused token, frozen
///      keeper) and a USDG balance read that fails all pay 0 and return normally. The reentrancy guard can only fire
///      from inside the USDG transfer, where it fails that transfer and so also pays 0. Callers still wrap the call in
///      try/catch, so even the NotAuthorized revert (or running out of gas) cannot take a settlement down.
///
///      THE BUDGET IS THE BALANCE. There is no internal budget counter: {reward} pays out of whatever USDG this
///      contract holds, so USDG sent here directly also funds bounties, and USDG the issuer burns or wipes here
///      simply is not paid. {fund} measures the balance delta so {Funded} reports what actually arrived.
contract KeeperRewards is IKeeperRewards, Managed, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                              SPEND WINDOW
    //////////////////////////////////////////////////////////////*/

    // Exact semantics of the "rolling 24 h" cap.
    //
    // Time is cut into EPOCHs of 6 h aligned to the unix epoch (they start at 00:00, 06:00, 12:00 and 18:00 UTC). A
    // payment is booked to the epoch it is made in and COUNTS against the cap in that epoch and the four after it.
    // {spentToday} is therefore the spend of the current epoch plus the four previous ones, and {reward} pays at most
    // `dailyCap - spentToday`.
    //
    // Guarantee: the USDG paid in ANY interval [s, s + 24 h] is <= dailyCap (the cap in force at the last payment of
    // that interval). Because 4 * EPOCH is exactly 24 h, floor((s + 24 h) / EPOCH) == floor(s / EPOCH) + 4, so every
    // payment of the interval lies in the five epochs the last one was checked against.
    //
    // Price of the guarantee: capacity comes back late. A payment stops counting at the start of the fifth epoch
    // after its own, which is more than 24 h and at most 30 h after it was made (24 h + 1 s when paid in the last
    // second of an epoch, 30 h when paid in its first second). A true per-second sliding window would need unbounded
    // history; a window that simply resets 24 h after it opens is cheaper but lets up to 2 x dailyCap through in a
    // 24 h interval that straddles the reset. Five buckets fit in one storage slot, so this costs the same one SLOAD
    // and one SSTORE per reward as the resetting window.

    /// @dev Length of one spend epoch, seconds. 4 * EPOCH must equal 24 h exactly (see the window comment above).
    uint256 private constant EPOCH = 6 hours;
    /// @dev Epochs a payment counts for: its own and the four after it.
    uint256 private constant EPOCHS = 5;
    /// @dev Width of one epoch's spend bucket. 2^43 - 1 base units is ~8.8M USDG per 6 h; at MAX_BOUNTY per call that
    ///      is 8.8M paid calls in one epoch, far beyond the chain's gas. {reward} still clamps to it, so a bucket can
    ///      never carry into its neighbour whatever dailyCap the admin sets.
    uint256 private constant BUCKET_BITS = 43;
    uint256 private constant BUCKET_MAX = 2 ** BUCKET_BITS - 1;
    /// @dev The five buckets occupy the low 215 bits; the epoch index of bucket 0 sits above them.
    uint256 private constant BUCKETS_BITS = EPOCHS * BUCKET_BITS;
    uint256 private constant BUCKETS_MASK = 2 ** BUCKETS_BITS - 1;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The bounty token, USDG (6 dp).
    IERC20 public immutable usdg;

    /// @inheritdoc IKeeperRewards
    mapping(bytes32 action => uint256) public bounty;

    /// @inheritdoc IKeeperRewards
    /// @dev 0 (the deploy default) pays nothing, so the admin can stop every bounty with one call.
    uint256 public dailyCap;

    /// @notice Whether `caller` is a registered protocol contract allowed to call {reward}.
    mapping(address caller => bool) public isCaller;

    /// @inheritdoc IKeeperRewards
    /// @dev INTERFACE_VERSION 8: the Treasury Safe, set once by the constructor. Protocol-owned money (bounties) can
    ///      only leave to it; {defund} has no free `to` argument any more.
    address public treasury;

    /// @dev The spend window packed into one word: `epoch << BUCKETS_BITS | b4 << 172 | ... | b1 << 43 | b0`, where
    ///      `epoch = timestamp / EPOCH` of the last booked payment, b0 is that epoch's spend and b_i the spend i epochs
    ///      before it, USDG base units. Advancing k epochs is a left shift by k buckets: the oldest fall off the top.
    uint256 private _window;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice The CONFIG_ADMIN lane registered (`registered = true`) or unregistered `caller` for {reward}.
    event CallerSet(address indexed caller, bool registered);
    /// @notice The FEE_MANAGER lane set the cap to `amount` USDG base units per rolling 24 h.
    event DailyCapSet(uint256 amount);
    /// @notice `from` added `amount` USDG base units to the budget (the measured balance delta).
    event Funded(address indexed from, uint256 amount);
    /// @notice The TREASURY_ADMIN lane withdrew `amount` USDG base units of the budget to `to`.
    event Defunded(address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param usdg_ The bounty token (USDG). Must be a contract: the payout path treats empty return data as success,
    ///        which a code-less address would always give.
    /// @param authority The `AccessManager` that maps this contract's selectors to roles (V8Roles).
    /// @param treasury_ The Treasury Safe {defund} pays. Zero is refused, so the pointer can never be unset.
    constructor(IERC20 usdg_, address authority, address treasury_) Managed(authority) {
        if (address(usdg_).code.length == 0) revert V2Errors.UnsupportedAsset();
        if (treasury_ == address(0)) revert V2Errors.NotAuthorized();
        usdg = usdg_;
        treasury = treasury_;
    }

    /*//////////////////////////////////////////////////////////////
                                 REWARD
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IKeeperRewards
    /// @dev Pays min(bounty(action), dailyCap - spentToday, USDG balance). Emits {Rewarded} only when paid > 0.
    ///      Eligibility (open interest, supply, minRedeemPayout, minRollUnits) is enforced by the calling contract, not
    ///      here. The spend is booked before the transfer (checks-effects-interactions) and restored exactly if the
    ///      transfer fails, so a failed payment leaves no trace.
    function reward(address keeper, bytes32 action) external nonReentrant returns (uint256 paid) {
        if (!isCaller[msg.sender]) revert V2Errors.NotAuthorized();

        uint256 amount = bounty[action];
        if (amount == 0) return 0;

        uint256 stored = _window;
        uint256 w = _advance(stored, block.timestamp);
        uint256 spent = _sum(w);
        uint256 cap = dailyCap;
        if (spent >= cap) return 0;
        if (amount > cap - spent) amount = cap - spent;
        // Headroom of the current bucket; see BUCKET_BITS for why this never binds in practice.
        uint256 headroom = BUCKET_MAX - (w & BUCKET_MAX);
        if (amount > headroom) amount = headroom;

        // Read last: the external call is skipped entirely when the bounty or the cap already pays nothing.
        uint256 balance = _usdgBalance();
        if (amount > balance) amount = balance;
        if (amount == 0) return 0;

        _window = w + amount;
        if (!_tryTransfer(keeper, amount)) {
            _window = stored;
            return 0;
        }
        emit Rewarded(keeper, action, amount);
        return amount;
    }

    /*//////////////////////////////////////////////////////////////
                                FUNDING
    //////////////////////////////////////////////////////////////*/

    /// @notice Add `amount` USDG base units to the budget from the caller (approve this contract first). Anyone may
    ///         fund: a donation can only pay bounties.
    /// @dev Reverts if the transfer fails (SafeERC20). Measures the balance delta, so a token that delivers less than
    ///      `amount` is reported as what arrived.
    /// @param amount USDG base units to pull.
    /// @return received USDG base units that arrived.
    function fund(uint256 amount) external nonReentrant returns (uint256 received) {
        uint256 before = usdg.balanceOf(address(this));
        usdg.safeTransferFrom(msg.sender, address(this), amount);
        received = usdg.balanceOf(address(this)) - before;
        emit Funded(msg.sender, received);
    }

    /// @inheritdoc IKeeperRewards
    /// @dev INTERFACE_VERSION 8: TREASURY_ADMIN (24 h). Pays {treasury} only; the v7 free-`to` form is deleted.
    ///      The `Defunded(to, amount)` topic is unchanged and now always reports {treasury}.
    function defund(uint256 amount) external nonReentrant restricted {
        address to = treasury;
        emit Defunded(to, amount);
        usdg.safeTransfer(to, amount);
    }

    /// @notice Sets the only address {defund} can pay. TREASURY_ADMIN (24 h).
    /// @param treasury_ The Treasury Safe; zero is refused (`NotAuthorized`), so the pointer can never be unset.
    function setTreasury(address treasury_) external nonReentrant restricted {
        if (treasury_ == address(0)) revert V2Errors.NotAuthorized();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    /*//////////////////////////////////////////////////////////////
                  SETTERS (CONFIG_ADMIN, FEE_MANAGER)
    //////////////////////////////////////////////////////////////*/

    /// @notice Register (`registered = true`) or unregister `caller` as a protocol contract allowed to call {reward}.
    ///         CONFIG_ADMIN (24 h).
    /// @param caller The protocol contract (SettlementOracle, Clearinghouse, AutoRoller).
    /// @param registered Whether it may call {reward}.
    /// @dev SEC-39 IS CLOSED HERE, NOT FIXED, and this is the note that says so. {reward} trusts a registered
    ///      caller completely -- it never checks that the call it is paying for happened. That is DELIBERATE and is
    ///      stated at the top of this contract (ELIGIBILITY IS THE CALLER'S JOB): this contract does not know what a
    ///      series or an expiry is, so it cannot re-derive eligibility, and the trust is bounded three ways instead
    ///      -- MAX_BOUNTY per call ({setBounty} reverts above 1 USDG), the rolling daily cap, and the balance.
    ///      The one tightening available here would be to refuse a code-less `caller`, mirroring
    ///      Clearinghouse.setKeeperRewards. It is NOT applied: this suite's own fixture registers EOAs as callers
    ///      deliberately (test/v2/unit/KeeperRewards.t.sol:112-113 and :140), so the change is a rewrite of the
    ///      tests rather than a change in behaviour on chain, and it belongs in a row that owns that decision.
    function setCaller(address caller, bool registered) external nonReentrant restricted {
        isCaller[caller] = registered;
        emit CallerSet(caller, registered);
    }

    /// @notice Set the bounty of `action` to `amount` USDG base units. FEE_MANAGER (48 h).
    /// @dev Reverts CeilingExceeded above MAX_BOUNTY (1_000_000 = 1 USDG). Any action id is accepted, not only the five
    ///      V2Constants.ACTION_* ids, so a later protocol contract can be paid without a new KeeperRewards; an id
    ///      nobody reports is simply never paid. 0 disables the action.
    /// @param action Bounty action id, e.g. V2Constants.ACTION_SETTLE.
    /// @param amount USDG base units per call, <= MAX_BOUNTY.
    function setBounty(bytes32 action, uint256 amount) external nonReentrant restricted {
        if (amount > V2Constants.MAX_BOUNTY) revert V2Errors.CeilingExceeded();
        bounty[action] = amount;
        emit BountySet(action, amount);
    }

    /// @notice Set the maximum spend per rolling 24 h to `amount` USDG base units. FEE_MANAGER (48 h).
    /// @dev Takes effect on the next {reward}; spend already counted stays counted, so lowering the cap below
    ///      {spentToday} pays nothing until enough epochs roll out. No compiled ceiling: the balance bounds it.
    /// @param amount USDG base units.
    function setDailyCap(uint256 amount) external nonReentrant restricted {
        dailyCap = amount;
        emit DailyCapSet(amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IKeeperRewards
    /// @dev Spend of the current 6 h epoch and the four before it, i.e. every payment made since the start of the epoch
    ///      24 h before the current one (between 24 h and 30 h of history). See the window comment at the top.
    function spentToday() external view returns (uint256) {
        return _sum(_advance(_window, block.timestamp));
    }

    /// @notice The spend window as of now, for dashboards and the cranker.
    /// @return epochStart Unix seconds at which the current 6 h epoch started.
    /// @return spent USDG base units booked per epoch: `spent[0]` the current epoch, `spent[i]` i epochs ago. `spent[4]`
    ///         stops counting at `epochStart + 6 h`, `spent[3]` 6 h later, and so on.
    function spendByEpoch() external view returns (uint256 epochStart, uint256[EPOCHS] memory spent) {
        uint256 w = _advance(_window, block.timestamp);
        epochStart = block.timestamp - block.timestamp % EPOCH;
        for (uint256 i; i < EPOCHS; ++i) {
            spent[i] = (w >> (i * BUCKET_BITS)) & BUCKET_MAX;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev `w` moved forward to the epoch of `timestamp`: shifted one bucket per elapsed epoch, all zero after five
    ///      or more. A timestamp in an earlier epoch than the one stored (impossible on chain, possible under a test
    ///      warp) leaves the window as stored rather than resurrecting spend that has already rolled out.
    function _advance(uint256 w, uint256 timestamp) private pure returns (uint256) {
        uint256 current = timestamp / EPOCH;
        uint256 last = w >> BUCKETS_BITS;
        if (current <= last) return w;
        uint256 elapsed = current - last;
        uint256 buckets = elapsed >= EPOCHS ? 0 : ((w & BUCKETS_MASK) << (elapsed * BUCKET_BITS)) & BUCKETS_MASK;
        return (current << BUCKETS_BITS) | buckets;
    }

    /// @dev Total of the five buckets of `w`, USDG base units.
    function _sum(uint256 w) private pure returns (uint256 total) {
        for (uint256 i; i < EPOCHS; ++i) {
            total += (w >> (i * BUCKET_BITS)) & BUCKET_MAX;
        }
    }

    /// @dev This contract's USDG balance, or 0 if the read fails. A raw staticcall so a broken or replaced token
    ///      implementation cannot make {reward} revert.
    function _usdgBalance() private view returns (uint256) {
        (bool ok, bytes memory ret) = address(usdg).staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }

    /// @dev Best-effort USDG transfer that never reverts the caller, the raw call of Vault._tryTransfer: a paused token
    ///      or a frozen keeper must not take a lifecycle call down. Empty return data counts as success (the
    ///      non-compliant-ERC20 convention SafeERC20 follows; the constructor rules out a code-less token). The return
    ///      word is compared with 1 instead of `abi.decode(ret, (bool))`, which would itself revert on a dirty bool.
    function _tryTransfer(address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = address(usdg).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (uint256)) == 1));
    }
}
