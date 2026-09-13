// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISeaport, IConduitController, OrderComponents} from "./interfaces/ISeaport.sol";
import {IERC1155Minimal} from "./interfaces/IERC1155Minimal.sol";
import {Policy} from "./Policy.sol";
import {SeaportOrderLib} from "./lib/SeaportOrderLib.sol";

/// @title AdapterSeaport
/// @notice Listing the cycle's option tokens on Seaport 1.6 with the vault as offerer.
/// @dev An abstract base inherited by {Vault}.
///
///      WHY THE VAULT IS THE OFFERER.
///      The obvious shortcut is to let the keeper sign as offerer, but that requires the
///      option ERC-1155 to sit in the keeper's wallet, which hands a hot key custody of the
///      depositors' collateral. Instead the vault offers, holds the tokens, and authorises a
///      specific order hash. The keeper can only propose; it can never move inventory.
///
///      TWO AUTHORISATION PATHS, ON PURPOSE.
///      `validate()` marks the order on-chain so it fills with an empty signature, and
///      EIP-1271 answers for the hash if a filler supplies one anyway. Overcall's API and
///      their UI may take either route, and an unfillable listing is an unfilled week.
///
///      ORDER SHAPE IS CHECKED ON CHAIN.
///      Everything the keeper proposes is verified here against the vault's own state before
///      it is authorised: who receives the money, how much, which token, for how long. A
///      compromised keeper cannot list the inventory to itself or for a dollar.
abstract contract AdapterSeaport {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev EIP-1271 magic value for a valid signature.
    bytes4 internal constant EIP1271_MAGIC = 0x1626ba7e;
    bytes4 internal constant EIP1271_INVALID = 0xffffffff;

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Seaport 1.6. Mainnet 4663: 0x0000000000000068F116a894984e2DB1123eB395.
    ISeaport public immutable seaport;

    /// @notice The Overcall fee recipient that must receive the 5% consideration item.
    /// @dev Copied from a real filled Overcall order at deploy time. If this is wrong the
    ///      listing is still valid Seaport, but Overcall will not surface it.
    address public immutable overcallFeeRecipient;

    /// @notice The conduit key Overcall's orders use. Zero means Seaport pulls directly.
    bytes32 public immutable conduitKey;

    /// @notice The address Seaport will pull the ERC-1155 from: the conduit, or Seaport itself.
    address public immutable transferApprovalTarget;

    /// @notice The zone Overcall's orders use. Zero for fully open orders.
    address public immutable seaportZone;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Hash of the currently authorised listing. Zero when nothing is listed.
    bytes32 public listingHash;

    /// @notice Gross USDG the live listing asks for, before Overcall's 5%.
    uint256 public listingGrossUsdg;

    /// @notice Option contracts the live listing offers.
    uint256 public listingAmount;

    /// @notice PRICE LEVELS spent this cycle: how many listings set a new lowest unit price.
    ///         Capped at {Policy.MAX_LISTINGS_PER_CYCLE} to stop a keeper ratcheting the price
    ///         down all week.
    /// @dev The name is kept for ABI stability; it no longer counts every authorisation.
    ///
    ///      WHY SLOTS COUNT PRICE CUTS. The cap used to count every approval, and a cancel never
    ///      refunded one. After a mid-week rally the keeper's honest move is to reprice UP, or to
    ///      relist a bigger tranche after {Vault.writeMore}; each of those burned a slot, so three
    ///      repricings left the vault unable to list at all while a stale listing sat on the book.
    ///      The threat the cap exists for is a ratchet DOWN. So the first listing of a cycle, and
    ///      any listing whose unit price (gross / amount) is strictly below the lowest authorised
    ///      so far, spends a slot and becomes the new lowest; a listing at or above the lowest is
    ///      free. That still allows at most three descending price levels per cycle.
    uint8 public listingsThisCycle;

    /// @notice The lowest gross unit price (USDG base units per contract) authorised this cycle.
    ///         Zero before the first listing of a cycle.
    uint256 public lowestListedUnitUsdg;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @dev `seq` is {listingsThisCycle} after this approval: the number of price levels spent,
    ///      NOT a running count of authorisations. Two listings can share a `seq`.
    event ListingApproved(
        bytes32 indexed orderHash, uint256 indexed optionId, uint256 amount, uint256 grossUsdg, uint8 seq
    );
    event ListingCancelled(bytes32 indexed orderHash);
    event AllListingsInvalidated(uint256 newCounter);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error PreviousListingLive(bytes32 liveHash);
    error TooManyListings(uint8 authorised, uint8 max);
    error NoLiveListing();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(ISeaport seaport_, address overcallFeeRecipient_, bytes32 conduitKey_, address seaportZone_) {
        seaport = seaport_;
        overcallFeeRecipient = overcallFeeRecipient_;
        conduitKey = conduitKey_;
        seaportZone = seaportZone_;

        // Resolve where the ERC-1155 approval has to point. With a zero conduit key Seaport
        // moves tokens itself; otherwise the conduit does, and approving Seaport would leave
        // every fill reverting.
        if (conduitKey_ == bytes32(0)) {
            transferApprovalTarget = address(seaport_);
        } else {
            (,, address controller) = seaport_.information();
            (address conduit, bool exists) = IConduitController(controller).getConduit(conduitKey_);
            transferApprovalTarget = exists ? conduit : address(seaport_);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                EIP-1271
    //////////////////////////////////////////////////////////////*/

    /// @notice EIP-1271. Answers only for the single order hash the vault has authorised.
    /// @dev The signature bytes are ignored on purpose: authorisation is the on-chain
    ///      `listingHash`, not a key. Anything else returns the invalid magic value, so a
    ///      stale or forged order cannot be filled against the vault.
    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        bytes32 live = listingHash;
        if (live == bytes32(0)) return EIP1271_INVALID;
        if (digest == live) return EIP1271_MAGIC;
        if (digest == _eip712Digest(live)) return EIP1271_MAGIC;
        return EIP1271_INVALID;
    }

    /// @dev Seaport asks the offerer to sign the EIP-712 digest of the order hash. The domain
    ///      separator is read live rather than cached so a chain-id change cannot strand it.
    function _eip712Digest(bytes32 orderHash) internal view returns (bytes32) {
        (, bytes32 domainSeparator,) = seaport.information();
        return keccak256(abi.encodePacked(hex"1901", domainSeparator, orderHash));
    }

    /*//////////////////////////////////////////////////////////////
                          APPROVE A LISTING
    //////////////////////////////////////////////////////////////*/

    /// @dev Validate a keeper-proposed order against vault state, authorise it on Seaport,
    ///      and record it. Reverts unless every field is exactly what this vault expects.
    /// @param components The full order the keeper intends to publish.
    /// @param expectedOptionId The option type the vault wrote this cycle.
    /// @param availableContracts Option tokens the vault still holds and may offer.
    /// @param usdgToken The USDG address both consideration items must use.
    /// @param clearAddress The clearinghouse, i.e. the ERC-1155 the offer item must reference.
    /// @param exerciseTimestamp The cycle's exercise time; the listing must end by then.
    /// @param strikeUsdg The option's exerciseAmount per contract, used as a sanity ceiling.
    /// @return orderHash The authorised hash.
    /// @return grossUsdg Gross premium asked, before Overcall's cut.
    /// @return amount Contracts offered.
    function _approveListing(
        OrderComponents calldata components,
        uint256 expectedOptionId,
        uint256 availableContracts,
        address usdgToken,
        address clearAddress,
        uint40 exerciseTimestamp,
        uint256 strikeUsdg
    ) internal returns (bytes32 orderHash, uint256 grossUsdg, uint256 amount) {
        if (listingHash != bytes32(0)) revert PreviousListingLive(listingHash);

        (orderHash, grossUsdg, amount) = SeaportOrderLib.approve(
            seaport,
            components,
            SeaportOrderLib.Checks({
                zone: seaportZone,
                conduitKey: conduitKey,
                overcallFeeRecipient: overcallFeeRecipient,
                usdgToken: usdgToken,
                clearAddress: clearAddress,
                expectedOptionId: expectedOptionId,
                availableContracts: availableContracts,
                exerciseTimestamp: exerciseTimestamp,
                strikeUsdg: strikeUsdg
            })
        );

        // The library already refused a gross that is not an exact multiple of `amount`.
        uint256 unitPrice = grossUsdg / amount;
        uint256 lowest = lowestListedUnitUsdg;
        uint8 used = listingsThisCycle;
        if (lowest == 0 || unitPrice < lowest) {
            if (used >= Policy.MAX_LISTINGS_PER_CYCLE) revert TooManyListings(used, Policy.MAX_LISTINGS_PER_CYCLE);
            listingsThisCycle = ++used;
            lowestListedUnitUsdg = unitPrice;
        }

        listingHash = orderHash;
        listingGrossUsdg = grossUsdg;
        listingAmount = amount;

        emit ListingApproved(orderHash, expectedOptionId, amount, grossUsdg, used);
    }

    /*//////////////////////////////////////////////////////////////
                                CANCEL
    //////////////////////////////////////////////////////////////*/

    /// @dev Cancel the live listing. The caller supplies the components again; they are
    ///      checked against the recorded hash, so a wrong order cannot be cancelled by
    ///      mistake and the live one cannot be left dangling.
    function _cancelListing(OrderComponents calldata components) internal {
        bytes32 live = listingHash;
        if (live == bytes32(0)) revert NoLiveListing();
        SeaportOrderLib.cancel(seaport, components, live);
        _clearListing();
        emit ListingCancelled(live);
    }

    /// @dev The guardian's blunt instrument: bump the Seaport counter, which invalidates every
    ///      outstanding order from this vault at once and needs no order data to do it. This
    ///      is the path that works when the keeper is dead and nobody can reconstruct the
    ///      components.
    function _invalidateAllListings() internal {
        uint256 newCounter = seaport.incrementCounter();
        bytes32 live = listingHash;
        _clearListing();
        if (live != bytes32(0)) emit ListingCancelled(live);
        emit AllListingsInvalidated(newCounter);
    }

    function _clearListing() internal {
        listingHash = bytes32(0);
        listingGrossUsdg = 0;
        listingAmount = 0;
    }

    /// @dev Reset the per-cycle listing budget. Called on roll open.
    function _resetListingBudget() internal {
        listingsThisCycle = 0;
        lowestListedUnitUsdg = 0;
    }

    /*//////////////////////////////////////////////////////////////
                             APPROVALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Approve the conduit (or Seaport) to move the vault's option tokens. Set once;
    ///      the approval is scoped to the clearinghouse's ERC-1155, which only ever holds
    ///      option and claim tokens this vault wrote.
    function _approveOptionTransfers(address clearAddress) internal {
        IERC1155Minimal(clearAddress).setApprovalForAll(transferApprovalTarget, true);
    }
}
