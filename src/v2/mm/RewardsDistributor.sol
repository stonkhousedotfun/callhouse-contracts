// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Managed} from "../access/Managed.sol";
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
///      accepted. `index` = the entry's 0-based position in the published values, `amount` = base units of THIS
///      INSTANCE's reward token -- see the note below; it is not always USDG and not always 6 dp.
///      Claimed bitmap: word `index >> 8`, bit `index & 0xff`, per epoch, so one SSTORE covers 256 makers.
///
/// @dev TWO INSTANCES, TWO TOKENS, AND EVERY "USDG" BELOW MEANS "THIS INSTANCE'S REWARD TOKEN". T-182 corrects
///      docstrings that named a token and a decimal count this contract does not fix:
///        - the MAKER instance (`rewardsDistributor` in the manifest) holds USDG, 6 dp;
///        - the LENDER instance (`RewardsDistributorLender`, deployed by `script/v2/DeployLenderRewards.s.sol`)
///          holds the STONKHOUSE token, 18 dp, and that script REFUSES anything that is not an 18-decimal token
///          called STONKHOUSE.
///      The contract itself reads `decimals()` from nothing and cares about neither: it moves whatever `usdg`
///      was constructed with. The immutable keeps the name `usdg` for ABI stability -- renaming it is a code
///      change, not a docstring one -- so read it as "the reward token" everywhere.
///
///      THE TOTAL IS A CEILING. {setRoot} records the epoch's total and {claim} never lets the epoch pay more than it.
///      Every epoch is paid from the same USDG balance, so a malformed tree whose amounts add up to more than the
///      posted total cannot spend another epoch's rewards; with a correct tree (the sum of amounts == total, as X2-03
///      builds it) the ceiling never binds.
///
///      FUNDING. Claims pay out of this contract's USDG balance; a claim that finds too little reverts and stays
///      claimable. {fund} is open to anyone (it can only pay rewards); {defund} takes unclaimed rewards back to
///      {treasury} and nowhere else (INTERFACE_VERSION 8). Rewards are treasury money, not user collateral (ADR-09),
///      so TREASURY_ADMIN may reclaim them at any time -- but only to the Treasury Safe. Reclaiming the balance does
///      not cancel a single proof: every posted root stays claimable against whatever is funded later ({setRoot}).
///
///      A CLAIM THAT CANNOT BE PAID REVERTS. A frozen account's claim reverts whole (the bitmap is untouched) and can be
///      pushed again once the account can receive USDG. There is no ledger: nothing here is worth parking.
///
///      ERRORS (all V2Errors). setRoot: NotAuthorized (the manager refused the caller), NoSource (zero root:
///      `root(epoch) == 0` means "none posted"), AlreadyFinal (the epoch already has a root). claim: NoSource (no root
///      for the epoch), AlreadyFinal (entry already claimed), NotAuthorized (proof does not prove the leaf),
///      CeilingExceeded (would pay the epoch past its total).
///
///      ACCESS (INTERFACE_VERSION 8). {Managed}: one `AccessManager` maps (this contract, selector) to a role id per
///      `script/v2/roles.v8.json`. {setRoot}, {defund} and {setTreasury} are TREASURY_ADMIN (24 h); {fund} and
///      {claim} carry no role at all, because funding can only add rewards and a claim always pays the proven account.
contract RewardsDistributor is IRewardsDistributor, Managed, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice The reward token: USDG (6 dp) on the maker instance, the STONKHOUSE token (18 dp) on the lender
    ///         instance. The name is historical; nothing here assumes either token or either decimal count.
    IERC20 public immutable usdg;

    mapping(uint256 epoch => bytes32) private _roots;
    mapping(uint256 epoch => uint256) private _totals;

    /// @notice USDG base units already paid for `epoch`; never above {totalOf}.
    mapping(uint256 epoch => uint256) public claimedAmount;

    /// @notice Claimed bitmap of `epoch`: bit `index & 0xff` of word `index >> 8` is set once entry `index` is claimed.
    mapping(uint256 epoch => mapping(uint256 word => uint256)) public claimedWord;

    /// @inheritdoc IRewardsDistributor
    /// @dev INTERFACE_VERSION 8: a constructor argument, changed only by TREASURY_ADMIN through {setTreasury}. It is
    ///      never zero, so {defund} always has somewhere to pay and can never be pointed at an attacker's address by
    ///      a caller who is not TREASURY_ADMIN.
    address public treasury;

    /// @notice `from` added `amount` USDG base units to the reward balance (the measured balance delta).
    event Funded(address indexed from, uint256 amount);
    /// @notice TREASURY_ADMIN withdrew `amount` USDG base units of the reward balance to `to`, which is always
    ///         {treasury} from INTERFACE_VERSION 8.
    event Defunded(address indexed to, uint256 amount);

    /// @param usdg_ The reward token (USDG): must be a contract (UnsupportedAsset).
    /// @param authority_ The `AccessManager` that gates {setRoot}, {defund} and {setTreasury} (NoSource when it has
    ///        no code).
    /// @param treasury_ The Treasury Safe: the only address {defund} can ever pay (NotAuthorized when zero).
    constructor(IERC20 usdg_, address authority_, address treasury_) Managed(authority_) {
        if (address(usdg_).code.length == 0) revert V2Errors.UnsupportedAsset();
        usdg = usdg_;
        _setTreasury(treasury_);
    }

    /*//////////////////////////////////////////////////////////////
                                 ROOTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Posts the Merkle root of `epoch` and the reward-token total it pays. TREASURY_ADMIN (24 h), once per
    ///         epoch.
    /// @dev NotAuthorized for any other caller; NoSource for a zero root; AlreadyFinal when the epoch already has one.
    ///      The balance is not checked: the admin may fund before or after.
    ///
    ///      A POSTED ROOT IS PERMANENT AND CANNOT BE REVOKED. It cannot be replaced, it never expires, and {claim}
    ///      accepts its proofs for as long as the epoch's total and this contract's balance allow. {defund} only moves
    ///      balance: a claim against a defunded contract reverts and stays claimable, and succeeds again once anyone
    ///      funds the contract, for any epoch. So correcting a wrong tree is NOT "defund and repost": publishing the
    ///      corrected values under a new epoch id adds a second liability beside the first, and every unclaimed entry
    ///      of the wrong tree (up to its posted total, less what it already paid) stays payable from all future
    ///      funding. Account for that whole outstanding amount before funding again. Revoking a root is not
    ///      implemented; it would be a contract change, not an operating procedure.
    /// @param epoch Weeks since Monday 1970-01-05 00:00 UTC.
    /// @param epochRoot StandardMerkleTree root of the epoch's (epoch, index, account, amount) values.
    /// @param epochTotal Sum of the epoch's amounts, in base units of this instance's reward token; the most the
    ///        epoch's claims will ever pay.
    function setRoot(uint256 epoch, bytes32 epochRoot, uint256 epochTotal) external nonReentrant restricted {
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

    /// @inheritdoc IRewardsDistributor
    /// @dev INTERFACE_VERSION 8: TREASURY_ADMIN (24 h) through the manager, and the money can only land on
    ///      {treasury}. v7's `defund(address,uint256)` is DELETED, so `defund` is no longer an overloaded name and
    ///      `.selector` is unambiguous again. The `Defunded` topic is unchanged and now always reports {treasury}.
    ///      Unclaimed rewards are included: claims that then find too little revert and stay claimable.
    function defund(uint256 amount) external nonReentrant restricted {
        address to = treasury;
        emit Defunded(to, amount);
        usdg.safeTransfer(to, amount);
    }

    /// @notice Sets the only address {defund} can pay. TREASURY_ADMIN (24 h).
    /// @param treasury_ The Treasury Safe; zero is refused (`NotAuthorized`).
    function setTreasury(address treasury_) external nonReentrant restricted {
        _setTreasury(treasury_);
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

    /// @dev Stores the Treasury Safe. Zero is refused so {defund} never burns the reward balance and never has to
    ///      carry a "treasury unset" branch that could be reached with money in the contract.
    function _setTreasury(address treasury_) private {
        if (treasury_ == address(0)) revert V2Errors.NotAuthorized();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }
}
