// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IKeeperRewards
/// @notice USDG bounties for permissionless lifecycle calls that advance state (ADR-06, architecture §3.7).
/// @dev Holds a treasury-funded USDG budget. Bounties are sized near gas cost (~$0.05 per call on 4663) so farming
///      them by self-dealing is pointless. Actions are V2Constants.ACTION_SNAPSHOT / ACTION_FINALIZE / ACTION_SETTLE /
///      ACTION_REDEEM / ACTION_ROLL / ACTION_CANCEL_STALE, plus ACTION_DISTRIBUTE and ACTION_BUYBACK from
///      INTERFACE_VERSION 8; each bounty is <= MAX_BOUNTY. `setBounty` accepts ANY action id and this contract holds
///      no cooldown logic, so the two flywheel actions need no code here. The callers apply the eligibility gates
///      (open interest, supply, minimum payout, minimum roll size) before calling {reward}.
///
///      INTERFACE_VERSION 8 SPLITS THE ADMIN SURFACE BY LANE: `setBounty` and `setDailyCap` are FEE_MANAGER (48 h),
///      `setCaller` is CONFIG_ADMIN (24 h), and `defund` is TREASURY_ADMIN (24 h) and has LOST ITS `to` ARGUMENT --
///      protocol-owned money leaves only to the Treasury Safe. {fund} stays permissionless (a donation can only pay
///      bounties). BountySet and TreasurySet are frozen here.
interface IKeeperRewards {
    /// @notice Pays `keeper` the bounty of `action`, within the remaining budget and rolling daily cap.
    /// @dev Registered protocol contracts only (NotAuthorized). Empty budget or cap reached pays 0 and does not
    ///      revert; callers still wrap the call in try/catch so a reward can never block a lifecycle call.
    /// @param keeper Account paid (the caller of the lifecycle function).
    /// @param action Bounty action id, e.g. keccak256("SETTLE").
    /// @return paid USDG base units paid.
    function reward(address keeper, bytes32 action) external returns (uint256 paid); // protocol contracts only

    /// @notice Bounty of `action`.
    /// @param action Bounty action id.
    /// @return USDG base units, <= MAX_BOUNTY (1_000_000 = 1 USDG).
    function bounty(bytes32 action) external view returns (uint256);

    /// @notice Maximum total spend over a rolling 24 h.
    /// @return USDG base units.
    function dailyCap() external view returns (uint256);

    /// @notice Spend counted against {dailyCap} in the current rolling 24 h.
    /// @return USDG base units.
    function spentToday() external view returns (uint256);

    /// @notice The only address {defund} can pay: the Treasury Safe (INTERFACE_VERSION 8).
    /// @dev A constructor argument, changeable only under TREASURY_ADMIN's 24 h lane. `VerifyV8` asserts that this,
    ///      `MakerVault.treasury`, `RewardsDistributor.treasury` and `FeeSplitter.treasury` are all the Treasury Safe.
    /// @return Treasury address.
    function treasury() external view returns (address);

    /// @notice Withdraws `amount` USDG base units of the budget to {treasury}. TREASURY_ADMIN (24 h).
    /// @dev INTERFACE_VERSION 8 REMOVED the free `to` argument of v7's `defund(address, uint256)`, so no role can
    ///      name a destination. Reverts if the transfer fails, including for more than the balance. The rolling spend
    ///      window is untouched: defunding lowers what CAN be paid, never what HAS been counted.
    /// @param amount USDG base units.
    function defund(uint256 amount) external;

    /// @notice `amount` USDG base units paid to `keeper` for `action`.
    event Rewarded(address indexed keeper, bytes32 indexed action, uint256 amount);
    /// @notice TREASURY_ADMIN set the only address {defund} can pay (INTERFACE_VERSION 8).
    event TreasurySet(address indexed treasury);
    /// @notice FEE_MANAGER set the bounty of `action` to `amount` USDG base units.
    event BountySet(bytes32 indexed action, uint256 amount);
}
