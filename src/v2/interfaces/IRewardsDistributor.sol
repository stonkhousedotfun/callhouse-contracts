// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IRewardsDistributor
/// @notice Weekly Merkle claims of rewards in one ERC-20 per instance (roadmap 1.4, architecture §3.10, plan
///         02-interfaces §1.9). Introduced in INTERFACE_VERSION 3 for maker rewards; the current surface is
///         INTERFACE_VERSION 8, which replaced `defund(address, uint256)` with {defund} and {treasury}. The admin
///         posts each epoch's root; the tree is built off-chain by whoever scores that instance's epoch.
/// @dev ONE INTERFACE, TWO DEPLOYED TOKENS. Every amount below is in base units of THIS INSTANCE's reward token, and
///      the ABI's `uint256 amount` does not say which token or how many decimals:
///        - the maker instance (`rewardsDistributor` in the deploy manifest) pays USDG, 6 dp;
///        - the lender instance (`lenderRewardsDistributor`, output by script/v2/DeployLenderRewards.s.sol) pays the
///          STONKHOUSE token, 18 dp.
///      A tree built for one instance with the other's decimals is a valid tree off by a factor of 10^12, and nothing
///      on-chain rejects it. Tooling must take the token and its decimals from the instance it targets (the
///      concrete contract's `usdg()` getter returns the reward token whatever its name), never from this file.
/// @dev Leaf format is the OpenZeppelin StandardMerkleTree convention, verified with OZ MerkleProof (sorted pairs):
///          leaf = keccak256(bytes.concat(keccak256(abi.encode(uint256 epoch, uint256 index, address account,
///                 uint256 amount))))
///      `epoch` = whole weeks since Monday 1970-01-05 00:00 UTC, floor((t - 345600) / 604800); `index` = the 0-based
///      position of the entry in the epoch's published values; `amount` = reward-token base units. One entry per
///      account per epoch. Claimed bitmap: word `index >> 8`, bit `index & 0xff`. The reference vector is the
///      indexer's `src/v2/fixtures/maker-epoch-2958.oz.json` (built with the OpenZeppelin merkle-tree JS library).
interface IRewardsDistributor {
    /// @notice Posts the Merkle root of `epoch` and the reward-token total it pays.
    /// @dev TREASURY_ADMIN only (V2Errors.NotAuthorized). Once per epoch: a second call reverts
    ///      V2Errors.AlreadyFinal, so neither the root nor the total can be replaced. `total` is a hard ceiling, not
    ///      a monitoring figure: the epoch's claims together never pay more than it, and a claim that would reverts
    ///      V2Errors.CeilingExceeded. Post exactly the sum of the tree's amounts: a smaller total locks out the last
    ///      claims of the epoch for good, and their amounts can only be published again under another epoch id.
    ///      Claims are also bounded by the contract's reward-token balance, which is not checked here.
    ///      A posted root is permanent: it cannot be revoked, and its proofs stay claimable against any later
    ///      funding even after {defund}. Revocation is not implemented.
    /// @param epoch Weeks since Monday 1970-01-05 00:00 UTC.
    /// @param root StandardMerkleTree root of the epoch's (epoch, index, account, amount) values.
    /// @param total Sum of the epoch's amounts, reward-token base units; the most the epoch's claims will ever pay.
    function setRoot(uint256 epoch, bytes32 root, uint256 total) external;

    /// @notice Pays `amount` of the reward token to `account` for its entry in `epoch`.
    /// @dev Anyone may call; the payment always goes to `account`. Reverts when the epoch has no root, the entry is
    ///      already claimed, `proof` does not prove the leaf against the epoch's root, or the epoch's claims would
    ///      pay more than its posted total (V2Errors.CeilingExceeded).
    /// @param epoch Weeks since Monday 1970-01-05 00:00 UTC.
    /// @param index 0-based position of the entry in the epoch's values.
    /// @param account Account receiving the reward (a maker or a lender, by instance).
    /// @param amount Reward-token base units.
    /// @param proof StandardMerkleTree proof of the leaf.
    function claim(uint256 epoch, uint256 index, address account, uint256 amount, bytes32[] calldata proof) external;

    /// @notice Whether entry `index` of `epoch` has been claimed.
    /// @param epoch Weeks since Monday 1970-01-05 00:00 UTC.
    /// @param index 0-based position of the entry in the epoch's values.
    /// @return True once claimed.
    function isClaimed(uint256 epoch, uint256 index) external view returns (bool);

    /// @notice The posted root of `epoch`.
    /// @param epoch Weeks since Monday 1970-01-05 00:00 UTC.
    /// @return The root; zero when none was posted.
    function root(uint256 epoch) external view returns (bytes32);

    /// @notice The only address {defund} can pay: the Treasury Safe (INTERFACE_VERSION 8).
    /// @return Treasury address.
    function treasury() external view returns (address);

    /// @notice Withdraws `amount` reward-token base units of the reward balance to {treasury}. TREASURY_ADMIN (24 h).
    /// @dev INTERFACE_VERSION 8 REMOVED the free `to` argument of v7's `defund(address, uint256)`. Unclaimed rewards
    ///      are included: old valid proofs stay claimable, and a claim that then finds too little reverts rather
    ///      than being consumed. Defunding is not revocation: those proofs pay again once the balance is refilled.
    /// @param amount Reward-token base units.
    function defund(uint256 amount) external;

    /// @notice TREASURY_ADMIN posted `epoch`'s root and total (reward-token base units).
    event RootSet(uint256 indexed epoch, bytes32 root, uint256 total);

    /// @notice `account` was paid `amount` reward-token base units for entry `index` of `epoch`.
    event Claimed(uint256 indexed epoch, uint256 indexed index, address indexed account, uint256 amount);

    /// @notice TREASURY_ADMIN set the only address {defund} can pay (INTERFACE_VERSION 8).
    event TreasurySet(address indexed treasury);
}
