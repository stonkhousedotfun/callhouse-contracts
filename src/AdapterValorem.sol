// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IValoremClear} from "./interfaces/IValoremClear.sol";
import {ValoremLib} from "./lib/ValoremLib.sol";

/// @title AdapterValorem
/// @notice Write / redeem / claim accounting against the Valorem clearinghouse.
/// @dev An abstract base inherited by {Vault}, not a standalone contract. The vault must BE
///      the writer: Valorem mints the claim NFT to `msg.sender`, and `redeem` reverts with
///      `CallerDoesNotOwnClaimId` for anyone else. Delegating to a separate contract would
///      put the collateral somewhere the vault cannot reach.
///
///      PARTIAL ASSIGNMENT IS NORMAL. Every write on an option id before its first exercise
///      lands in one bucket, whoever the writer is, and Valorem assigns exercise PRO RATA BY
///      AMOUNT WRITTEN across that bucket (upstream 6436c82 `_assignExercise`,
///      `_getAssetAmountsForClaimIndex`; integrations/valorem.md §4). So a vault that wrote N
///      contracts can come back with anywhere from 0 to N assigned, in fractions of a contract
///      when it shares the bucket with other writers. Every accounting path below is written to
///      accept the full range, and nothing asserts a 1:1 return of the underlying. What the vault
///      guarantees is the other bound: under write-on-fill it writes only what it sells, so it can
///      never be assigned on more contracts than it was paid a premium for.
abstract contract AdapterValorem {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice ValoremOptionsClearinghouse. Overcall's instance on 4663:
    ///         0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0; the vault is agnostic and can be
    ///         pointed at its own (script/DeployClear.s.sol).
    IValoremClear public immutable clear;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The Valorem option type armed this cycle. Zero when flat.
    uint256 public optionId;

    /// @notice The Valorem claim NFT id representing this cycle's short position. Zero until the
    ///         first fill of a cycle writes it, and zero again once it is redeemed.
    uint256 public claimKey;

    /// @notice Contracts written into Valorem this cycle, as a raw contract count. Under
    ///         write-on-fill this is also the number of contracts SOLD this cycle.
    /// @dev NOT the 1e18-scaled scalar Valorem stores in `Claim.amountWritten`. Keep the two
    ///      straight: `clear.write` takes a count, `clear.claim` returns count * 1e18.
    uint112 public contractsWritten;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @dev One per fill: `contractsCount` is the fill's size and `collateral` what it locked.
    event CallsWritten(uint256 indexed optionId, uint256 indexed claimKey, uint112 contractsCount, uint256 collateral);
    event ClaimRedeemed(uint256 indexed claimKey, uint256 underlyingReturned, uint256 exerciseReceived);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NoOpenClaim();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IValoremClear clear_) {
        clear = clear_;
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Underlying still locked behind this cycle's claim, in asset base units.
    function lockedAssets() public view returns (uint256) {
        return ValoremLib.lockedAssets(clear, claimKey);
    }

    /// @notice Exercise-asset proceeds (USDG) sitting in this cycle's claim, not yet redeemed.
    /// @dev Non-zero only once buyers have been assigned. This is the signal the deposit gate
    ///      uses as a second line of defence: while it is non-zero the vault's NAV has already
    ///      been written down by an assignment whose offsetting USDG has not arrived yet, and
    ///      new money must not be priced against that gap.
    function claimedExerciseProceeds() public view returns (uint256) {
        return ValoremLib.claimedExerciseProceeds(clear, claimKey);
    }

    /// @notice Contracts written this cycle that have been assigned so far, as a raw count.
    function contractsAssigned() public view returns (uint256) {
        return ValoremLib.contractsAssigned(clear, claimKey);
    }

    /*//////////////////////////////////////////////////////////////
                            WRITE / REDEEM
    //////////////////////////////////////////////////////////////*/

    /// @dev Record a write that {ValoremLib.writeOnFill} has already validated and executed. The
    ///      first fill of a cycle and every later one land here alike: `contractsWritten`
    ///      ACCUMULATES, and `claimKey` is unchanged by a top-up because the library refuses any
    ///      other id coming back.
    ///
    ///      THE CLAIM VIEWS ALREADY COVER MANY FILLS. {lockedAssets}, {claimedExerciseProceeds}
    ///      and {contractsAssigned} read Valorem's own `position(claimKey)` / `claim(claimKey)`,
    ///      and upstream sums both over every claim index (one per bucket written into) of the
    ///      claim. Nothing here needs to know how many fills a claim holds.
    function _recordWrite(uint256 optionId_, uint256 key, uint112 n, uint256 collateral) internal {
        claimKey = key;
        contractsWritten += n;

        emit CallsWritten(optionId_, key, n, collateral);
    }

    /// @dev Redeems the cycle's claim after expiry and reports the exact balance deltas.
    function _redeemClaim(IERC20 asset, IERC20 exerciseAsset)
        internal
        returns (uint256 underlyingReturned, uint256 exerciseReceived)
    {
        uint256 key = claimKey;
        if (key == 0) revert NoOpenClaim();

        (underlyingReturned, exerciseReceived) = ValoremLib.redeemClaim(clear, asset, exerciseAsset, key);

        // Clear the cycle's position. Under write-on-fill the vault holds no unsold option
        // tokens at this point; if it ever did, holding them does NOT block the claim
        // redemption. Their collateral already came back through the claim.
        claimKey = 0;
        optionId = 0;
        contractsWritten = 0;

        emit ClaimRedeemed(key, underlyingReturned, exerciseReceived);
    }

    /*//////////////////////////////////////////////////////////////
                           ERC-1155 RECEIVER
    //////////////////////////////////////////////////////////////*/

    /// @dev Valorem mints option tokens and the claim NFT straight to the writer, so the vault
    ///      must accept ERC-1155 pushes. It accepts exactly two: the batch mint that opens a claim
    ///      (`[optionId x n, claimId x 1]`, `from == address(0)`) and the single mint of a top-up.
    ///
    ///      MINTS ONLY, NOT EVERY TRANSFER FROM THE CLEARINGHOUSE. solmate's ERC-1155 calls the
    ///      receiver with `msg.sender == clear` on every `safeTransferFrom` to a contract as well
    ///      as on mints, so a check on the caller alone let any holder push option tokens or a
    ///      claim NFT into the vault (integrations/valorem.md §6.7). Under write-on-fill the vault
    ///      must hold NO option tokens outside a fill: {Vault.validateOrder} asserts the balance is
    ///      back at its pre-fill baseline, so a donation landing mid-fill would revert the buyer's
    ///      fill, and one landing between fills would put inventory in the vault that the write
    ///      accounting knows nothing about. Refusing `from != address(0)` closes both; a refused
    ///      hook makes the donor's own transfer revert, so nothing arrives.
    function onERC1155Received(address, address from, uint256, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(clear) || from != address(0)) return 0x00000000;
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address from, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != address(clear) || from != address(0)) return 0x00000000;
        return this.onERC1155BatchReceived.selector;
    }
}
