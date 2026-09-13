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
///      PARTIAL ASSIGNMENT IS NORMAL. Valorem assigns exercise by bucket, not pro-rata
///      across the whole market, so a vault that wrote N contracts can come back with
///      anywhere from 0 to N assigned. Every accounting path below is written to accept the
///      full range, and nothing asserts a 1:1 return of the underlying.
abstract contract AdapterValorem {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice ValoremOptionsClearinghouse. Mainnet 4663: 0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0.
    IValoremClear public immutable clear;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The Valorem option type written this cycle. Zero when flat.
    uint256 public optionId;

    /// @notice The Valorem claim NFT id representing this cycle's short position. Zero when flat.
    uint256 public claimKey;

    /// @notice Contracts written into Valorem this cycle, as a raw contract count.
    /// @dev NOT the 1e18-scaled scalar Valorem stores in `Claim.amountWritten`. Keep the two
    ///      straight: `clear.write` takes a count, `clear.claim` returns count * 1e18.
    uint112 public contractsWritten;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

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

    /// @notice Contracts written this cycle still held by the vault, unsold.
    /// @dev Read from the clearinghouse rather than tracked in storage. Seaport moves the option
    ///      tokens out on a fill without calling back into the vault, so any counter the vault
    ///      kept itself would silently drift the moment a buyer filled. The ERC-1155 balance is
    ///      the only number that cannot be wrong.
    function contractsRemaining() public view returns (uint256) {
        uint256 id = optionId;
        if (id == 0) return 0;
        return clear.balanceOf(address(this), id);
    }

    /// @notice Contracts that have left the vault via a Seaport fill, as a raw count.
    /// @dev Derived, for the same reason as {contractsRemaining}. Settlement never reads it: the
    ///      claim returns whatever collateral was not assigned regardless of how many option
    ///      tokens the vault still holds.
    function contractsSold() public view returns (uint256) {
        uint256 written = contractsWritten;
        uint256 held = contractsRemaining();
        return held >= written ? 0 : written - held;
    }

    /*//////////////////////////////////////////////////////////////
                            WRITE / REDEEM
    //////////////////////////////////////////////////////////////*/

    /// @dev Record a write that {ValoremLib.write} has already validated and executed. A fresh
    ///      claim and a top-up land here alike: `contractsWritten` ACCUMULATES, and `claimKey` is
    ///      unchanged by a top-up because the library refuses any other id coming back.
    ///
    ///      THE CLAIM VIEWS ALREADY COVER TRANCHES. {lockedAssets}, {claimedExerciseProceeds} and
    ///      {contractsAssigned} read Valorem's own `position(claimKey)` / `claim(claimKey)`, and
    ///      upstream sums both over every claim index (one per bucket written into) of the claim.
    ///      Nothing here needs to know how many tranches a claim holds.
    function _recordWrite(uint256 optionId_, uint256 key, uint112 n, uint256 collateral) internal {
        optionId = optionId_;
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

        // Clear the cycle's position. Unsold option ERC-1155 may still sit in the vault; they are
        // worthless after expiry and, critically, holding them does NOT block the claim
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
    ///      must accept ERC-1155 pushes. It only ever accepts them from the clearinghouse;
    ///      anything else is rejected so the vault cannot be used as a dumping ground.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(clear)) return 0x00000000;
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != address(clear)) return 0x00000000;
        return this.onERC1155BatchReceived.selector;
    }
}
