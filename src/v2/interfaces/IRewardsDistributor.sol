// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IRewardsDistributor
/// @notice Weekly Merkle claims of USDG maker rewards (roadmap 1.4, architecture §3.10, plan 02-interfaces §1.9,
///         INTERFACE_VERSION 3). The indexer's maker scoring builds each epoch's tree; the admin posts its root.
/// @dev Leaf format is the OpenZeppelin StandardMerkleTree convention, verified with OZ MerkleProof (sorted pairs):
///          leaf = keccak256(bytes.concat(keccak256(abi.encode(uint256 epoch, uint256 index, address account,
///                 uint256 amount))))
///      `epoch` = whole weeks since Monday 1970-01-05 00:00 UTC, floor((t - 345600) / 604800); `index` = the 0-based
///      position of the entry in the epoch's published values; `amount` = USDG base units (6 dp). One entry per
///      account per epoch. Claimed bitmap: word `index >> 8`, bit `index & 0xff`. The reference vector is the
///      indexer's `src/v2/fixtures/maker-epoch-2958.oz.json` (built with the OpenZeppelin merkle-tree JS library).
interface IRewardsDistributor {
    /// @notice Posts the Merkle root of `epoch` and the USDG total it pays.
    /// @dev DEFAULT_ADMIN_ROLE only (V2Errors.NotAuthorized). Once per epoch: a second call reverts
    ///      V2Errors.AlreadyFinal, so neither the root nor the total can be replaced. `total` is a hard ceiling, not
    ///      a monitoring figure: the epoch's claims together never pay more than it, and a claim that would reverts
    ///      V2Errors.CeilingExceeded. Post exactly the sum of the tree's amounts: a smaller total locks out the last
    ///      claims of the epoch for good, and their amounts can only be published again under another epoch id.
    ///      Claims are also bounded by the contract's USDG balance, which is not checked here.
    /// @param epoch Weeks since Monday 1970-01-05 00:00 UTC.
    /// @param root StandardMerkleTree root of the epoch's (epoch, index, account, amount) values.
    /// @param total Sum of the epoch's amounts, USDG base units; the most the epoch's claims will ever pay.
    function setRoot(uint256 epoch, bytes32 root, uint256 total) external;

    /// @notice Pays `amount` USDG to `account` for its entry in `epoch`.
    /// @dev Anyone may call; the USDG always goes to `account`. Reverts when the epoch has no root, the entry is
    ///      already claimed, `proof` does not prove the leaf against the epoch's root, or the epoch's claims would
    ///      pay more than its posted total (V2Errors.CeilingExceeded).
    /// @param epoch Weeks since Monday 1970-01-05 00:00 UTC.
    /// @param index 0-based position of the entry in the epoch's values.
    /// @param account Maker receiving the reward.
    /// @param amount USDG base units.
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

    /// @notice DEFAULT_ADMIN_ROLE posted `epoch`'s root and total (USDG base units).
    event RootSet(uint256 indexed epoch, bytes32 root, uint256 total);

    /// @notice `account` was paid `amount` USDG base units for entry `index` of `epoch`.
    event Claimed(uint256 indexed epoch, uint256 indexed index, address indexed account, uint256 amount);
}
