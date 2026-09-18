// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IRewardsDistributor} from "../interfaces/IRewardsDistributor.sol";
import {V2Errors} from "../interfaces/V2Errors.sol";

/// @title RewardsDistributor
/// @notice Weekly Merkle claims of USDG maker rewards (roadmap 1.4, architecture §3.10, 02-interfaces §1.9). The
///         indexer scores makers per epoch and publishes the epoch's values and tree (X2-03); the admin posts the root
///         once; anyone may then push each maker's claim, which always pays the maker.
/// @dev FORMAT (02-interfaces §1.9, the authority is X2-03's OpenZeppelin vector, test/v2/fixtures/
///      maker-epoch-2958.oz.json). The tree is the OpenZeppelin merkle-tree library's StandardMerkleTree over
///      ["uint256", "uint256", "address", "uint256"] = (epoch, index, account, amount):
///        leaf = keccak256(bytes.concat(keccak256(abi.encode(epoch, index, account, amount))))
///      and pairs are hashed sorted, which is what OZ MerkleProof verifies. The double hash is why a 64-byte inner node
///      can never be passed off as a leaf. `epoch` = whole weeks since Monday 1970-01-05 00:00 UTC; any uint256 is
///      accepted. `index` = the entry's 0-based position in the published values, `amount` = USDG base units (6 dp).
///      Claimed bitmap: word `index >> 8`, bit `index & 0xff`, per epoch, so one SSTORE covers 256 makers.
///
///      THE TOTAL IS A CEILING. {setRoot} records the epoch's total and {claim} never lets the epoch pay more than it.
///      Every epoch is paid from the same USDG balance, so a malformed tree whose amounts add up to more than the
///      posted total cannot spend another epoch's rewards; with a correct tree (the sum of amounts == total, as X2-03
///      builds it) the ceiling never binds.
///
///      FUNDING. Claims pay out of this contract's USDG balance; a claim that finds too little reverts and stays
///      claimable. {fund} is open to anyone (it can only pay rewards); {defund} lets the admin take unclaimed rewards
///      back. Rewards are treasury money, not user collateral (ADR-09), so the admin may reclaim them at any time.
///
///      A CLAIM THAT CANNOT BE PAID REVERTS. A frozen account's claim reverts whole (the bitmap is untouched) and can be
///      pushed again once the account can receive USDG. There is no ledger: nothing here is worth parking.
///
///      ERRORS (all V2Errors). setRoot: NotAuthorized (not admin), NoSource (zero root: `root(epoch) == 0` means "none
///      posted"), AlreadyFinal (the epoch already has a root). claim: NoSource (no root for the epoch), AlreadyFinal
///      (entry already claimed), NotAuthorized (proof does not prove the leaf), CeilingExceeded (would pay the epoch
///      past its total).
contract RewardsDistributor is IRewardsDistributor, AccessControl, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice The reward token, USDG (6 dp).
    IERC20 public immutable usdg;

    mapping(uint256 epoch => bytes32) private _roots;
    mapping(uint256 epoch => uint256) private _totals;

    /// @notice USDG base units already paid for `epoch`; never above {totalOf}.
    mapping(uint256 epoch => uint256) public claimedAmount;

    /// @notice Claimed bitmap of `epoch`: bit `index & 0xff` of word `index >> 8` is set once entry `index` is claimed.
    mapping(uint256 epoch => mapping(uint256 word => uint256)) public claimedWord;

    /// @notice `from` added `amount` USDG base units to the reward balance (the measured balance delta).
    event Funded(address indexed from, uint256 amount);
    /// @notice DEFAULT_ADMIN_ROLE withdrew `amount` USDG base units of the reward balance to `to`.
    event Defunded(address indexed to, uint256 amount);

    /// @param usdg_ The reward token (USDG): must be a contract (UnsupportedAsset).
    /// @param admin Receives DEFAULT_ADMIN_ROLE: posts roots, defunds (NotAuthorized when zero).
    constructor(IERC20 usdg_, address admin) {
        if (address(usdg_).code.length == 0) revert V2Errors.UnsupportedAsset();
        if (admin == address(0)) revert V2Errors.NotAuthorized();
        usdg = usdg_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /*//////////////////////////////////////////////////////////////
                                 ROOTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Posts the Merkle root of `epoch` and the USDG total it pays. DEFAULT_ADMIN_ROLE, once per epoch.
    /// @dev NotAuthorized for a non-admin; NoSource for a zero root; AlreadyFinal when the epoch already has one. A root
    ///      cannot be replaced: a wrong tree is abandoned (defund what it would not pay) and the corrected values are
    ///      published under a new epoch id. The balance is not checked: the admin may fund before or after.
    /// @param epoch Weeks since Monday 1970-01-05 00:00 UTC.
    /// @param epochRoot StandardMerkleTree root of the epoch's (epoch, index, account, amount) values.
    /// @param epochTotal Sum of the epoch's amounts, USDG base units; the most the epoch's claims will ever pay.
    function setRoot(uint256 epoch, bytes32 epochRoot, uint256 epochTotal)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (epochRoot == bytes32(0)) revert V2Errors.NoSource();
        if (_roots[epoch] != bytes32(0)) revert V2Errors.AlreadyFinal();
        _roots[epoch] = epochRoot;
        _totals[epoch] = epochTotal;
        emit RootSet(epoch, epochRoot, epochTotal);
    }

    /*//////////////////////////////////////////////////////////////
                                 CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Pays `amount` USDG to `account` for its entry `index` in `epoch`. Anyone may call.
    /// @dev Checks, in order: the epoch has a root (NoSource), the entry is unclaimed (AlreadyFinal), `proof` proves
    ///      {leaf}(epoch, index, account, amount) against the root with OZ MerkleProof (NotAuthorized), and the epoch
    ///      stays within its total (CeilingExceeded). Then the bit and the paid amount are written, Claimed is emitted
    ///      and the USDG is transferred (checks-effects-interactions; a failed transfer reverts all of it). A zero
    ///      amount is marked claimed without a transfer.
    /// @param epoch Weeks since Monday 1970-01-05 00:00 UTC.
    /// @param index 0-based position of the entry in the epoch's values.
    /// @param account Maker receiving the reward.
    /// @param amount USDG base units.
    /// @param proof StandardMerkleTree proof of the leaf.
    function claim(uint256 epoch, uint256 index, address account, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
    {
        bytes32 epochRoot = _roots[epoch];
        if (epochRoot == bytes32(0)) revert V2Errors.NoSource();
        uint256 word = index >> 8;
        // forge-lint: disable-next-line(incorrect-shift)
        uint256 bit = 1 << (index & 0xff);
        uint256 claimedBits = claimedWord[epoch][word];
        if (claimedBits & bit != 0) revert V2Errors.AlreadyFinal();
        if (!MerkleProof.verifyCalldata(proof, epochRoot, leaf(epoch, index, account, amount))) {
            revert V2Errors.NotAuthorized();
        }
        uint256 paid = claimedAmount[epoch] + amount;
        if (paid > _totals[epoch]) revert V2Errors.CeilingExceeded();

        claimedWord[epoch][word] = claimedBits | bit;
        claimedAmount[epoch] = paid;
        emit Claimed(epoch, index, account, amount);
        if (amount != 0) usdg.safeTransfer(account, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                FUNDING
    //////////////////////////////////////////////////////////////*/

    /// @notice Adds `amount` USDG base units to the reward balance from the caller (approve this contract first).
    ///         Anyone may fund.
    /// @dev Measures the balance delta, so {Funded} reports what actually arrived.
    /// @param amount USDG base units to pull.
    /// @return received USDG base units that arrived.
    function fund(uint256 amount) external nonReentrant returns (uint256 received) {
        uint256 before = usdg.balanceOf(address(this));
        usdg.safeTransferFrom(msg.sender, address(this), amount);
        received = usdg.balanceOf(address(this)) - before;
        emit Funded(msg.sender, received);
    }

    /// @notice Withdraws `amount` USDG base units of the reward balance to `to`. DEFAULT_ADMIN_ROLE.
    /// @dev Unclaimed rewards included: claims that then find too little revert and stay claimable.
    /// @param to Recipient.
    /// @param amount USDG base units.
    function defund(address to, uint256 amount) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        emit Defunded(to, amount);
        usdg.safeTransfer(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRewardsDistributor
    function root(uint256 epoch) external view returns (bytes32) {
        return _roots[epoch];
    }

    /// @notice The total posted with `epoch`'s root: the most its claims will ever pay, USDG base units (0 = no root).
    /// @param epoch Weeks since Monday 1970-01-05 00:00 UTC.
    /// @return USDG base units.
    function totalOf(uint256 epoch) external view returns (uint256) {
        return _totals[epoch];
    }

    /// @inheritdoc IRewardsDistributor
    function isClaimed(uint256 epoch, uint256 index) external view returns (bool) {
        // forge-lint: disable-next-line(incorrect-shift)
        return claimedWord[epoch][index >> 8] & (1 << (index & 0xff)) != 0;
    }

    /// @notice The StandardMerkleTree leaf of one entry (02-interfaces §1.9).
    /// @param epoch Weeks since Monday 1970-01-05 00:00 UTC.
    /// @param index 0-based position of the entry in the epoch's values.
    /// @param account Maker.
    /// @param amount USDG base units.
    /// @return keccak256(bytes.concat(keccak256(abi.encode(epoch, index, account, amount)))).
    function leaf(uint256 epoch, uint256 index, address account, uint256 amount) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(epoch, index, account, amount))));
    }

    /// @dev Every role check reverts with the shared v2 error. Covers grantRole / revokeRole as well.
    function _checkRole(bytes32 role, address account) internal view override {
        if (!hasRole(role, account)) revert V2Errors.NotAuthorized();
    }
}
