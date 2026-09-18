// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IKeeperRewards
/// @notice USDG bounties for permissionless lifecycle calls that advance state (ADR-06, architecture §3.7).
/// @dev Holds a treasury-funded USDG budget. Bounties are sized near gas cost (~$0.05 per call on 4663) so farming
///      them by self-dealing is pointless. Actions are V2Constants.ACTION_SNAPSHOT / ACTION_FINALIZE / ACTION_SETTLE /
///      ACTION_REDEEM / ACTION_ROLL; each bounty is <= MAX_BOUNTY. The callers apply the eligibility gates (open
///      interest, supply, minimum payout, minimum roll size) before calling {reward}. Admin setters (bounty table,
///      daily cap, registered protocol contracts, funding) are DEFAULT_ADMIN_ROLE implementation surface; BountySet
///      is frozen here.
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

    /// @notice `amount` USDG base units paid to `keeper` for `action`.
    event Rewarded(address indexed keeper, bytes32 indexed action, uint256 amount);
    /// @notice DEFAULT_ADMIN_ROLE set the bounty of `action` to `amount` USDG base units.
    event BountySet(bytes32 indexed action, uint256 amount);
}
