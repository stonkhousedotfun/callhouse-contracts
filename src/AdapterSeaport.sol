// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISeaport, IConduitController, OrderComponents} from "./interfaces/ISeaport.sol";
import {IERC1155Minimal} from "./interfaces/IERC1155Minimal.sol";
import {Policy} from "./Policy.sol";
import {SeaportOrderLib} from "./lib/SeaportOrderLib.sol";

/// @title AdapterSeaport
/// @notice Listing the cycle's option tokens on Seaport 1.6 with the vault as offerer AND as zone.
/// @dev An abstract base inherited by {Vault}.
///
///      WHY THE VAULT IS THE OFFERER.
///      The obvious shortcut is to let the keeper sign as offerer, but that requires the
///      option ERC-1155 to sit in the keeper's wallet, which hands a hot key custody of the
///      depositors' collateral. Instead the vault offers, and authorises a specific order hash.
///      The keeper can only propose; it can never move inventory.
///
///      WHY THE VAULT IS ALSO THE ZONE.
///      Under write-on-fill the vault holds NO option tokens between fills. Every listing is a
///      PARTIAL_RESTRICTED order whose zone is the vault, so Seaport 1.6 calls the vault's
///      `authorizeOrder` before it moves anything; that hook writes exactly the filled amount into
///      Valorem, and Seaport then transfers those freshly minted tokens to the buyer
///      ({Vault.authorizeOrder}). The order hash commits to the zone, so no order that names another
///      zone can ever be filled against this vault, and no order that names this vault as zone can
///      be filled unless it IS the vault's live listing.
///
///      ONE AUTHORISATION PATH.
///      `validate()` marks the order on chain, and Seaport skips signature verification for a
///      validated order on every later fill. There is no signing key and no EIP-1271 hook: the
///      vault answers for no digest, which also keeps its USDG out of reach of USDG's own
///      EIP-3009 / permit paths (integrations/usdg.md G7). Killing a listing is therefore
///      `cancel` or `incrementCounter` on Seaport, never a flag in vault storage.
///
///      ORDER SHAPE IS CHECKED ON CHAIN.
///      Everything the keeper proposes is verified here against the vault's own state before
///      it is authorised: who receives the money, how much, which token, for how long. A
///      compromised keeper cannot list the inventory to itself or for a dollar.
abstract contract AdapterSeaport {
    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Seaport 1.6. Mainnet 4663: 0x0000000000000068F116a894984e2DB1123eB395.
    ISeaport public immutable seaport;

    /// @notice The conduit key every listing uses. Zero means Seaport pulls directly.
    bytes32 public immutable conduitKey;

    /// @notice The address Seaport will pull the ERC-1155 from: the conduit, or Seaport itself.
    address public immutable transferApprovalTarget;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Hash of the currently authorised listing. Zero when nothing is listed.
    bytes32 public listingHash;

    /// @notice USDG the live listing asks for in full: `listingAmount` contracts at one unit price.
    uint256 public listingGrossUsdg;

    /// @notice Option contracts the live listing offers. The ORDER's size, not the unfilled
    ///         remainder; Seaport tracks the fraction filled.
    uint256 public listingAmount;

    /// @notice Listings authorised this cycle, capped at {Policy.MAX_LISTINGS_PER_CYCLE}.
    /// @dev Every `approveListing` spends one, cancelled or not. Under write-on-fill a listing is
    ///      sized to capacity and Seaport tracks partial fills, so nothing is ever relisted for
    ///      size; a relist is a reprice, and the cap bounds how far a keeper can walk the quote
    ///      in a week before the guardian must step in.
    uint8 public listingsThisCycle;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @dev `seq` is {listingsThisCycle} after this approval.
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

    constructor(ISeaport seaport_, bytes32 conduitKey_) {
        seaport = seaport_;
        conduitKey = conduitKey_;

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
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The zone every listing must name: this vault. Kept as a view so deploy tooling and
    ///         the keeper read the same answer the shape check enforces.
    function seaportZone() external view returns (address) {
        return address(this);
    }

    /*//////////////////////////////////////////////////////////////
                          APPROVE A LISTING
    //////////////////////////////////////////////////////////////*/

    /// @dev Validate a keeper-proposed order against vault state, authorise it on Seaport,
    ///      and record it. Reverts unless every field is exactly what this vault expects.
    /// @param components The full order the keeper intends to publish.
    /// @param expectedOptionId The option type the vault armed this cycle.
    /// @param capacityContracts Contracts the vault could still write this cycle.
    /// @param usdgToken The USDG address the consideration item must use.
    /// @param clearAddress The clearinghouse, i.e. the ERC-1155 the offer item must reference.
    /// @param exerciseTimestamp The cycle's exercise time; the listing must end by then.
    /// @param strikeUsdg The option's exerciseAmount per contract, used as a sanity ceiling.
    /// @return orderHash The authorised hash.
    /// @return grossUsdg USDG asked for the whole order.
    /// @return amount Contracts offered.
    function _approveListing(
        OrderComponents calldata components,
        uint256 expectedOptionId,
        uint256 capacityContracts,
        address usdgToken,
        address clearAddress,
        uint40 exerciseTimestamp,
        uint256 strikeUsdg
    ) internal returns (bytes32 orderHash, uint256 grossUsdg, uint256 amount) {
        if (listingHash != bytes32(0)) revert PreviousListingLive(listingHash);

        uint8 used = listingsThisCycle;
        if (used >= Policy.MAX_LISTINGS_PER_CYCLE) revert TooManyListings(used, Policy.MAX_LISTINGS_PER_CYCLE);

        (orderHash, grossUsdg, amount) = SeaportOrderLib.approve(
            seaport,
            components,
            SeaportOrderLib.Checks({
                conduitKey: conduitKey,
                usdgToken: usdgToken,
                clearAddress: clearAddress,
                expectedOptionId: expectedOptionId,
                capacityContracts: capacityContracts,
                exerciseTimestamp: exerciseTimestamp,
                strikeUsdg: strikeUsdg
            })
        );

        listingsThisCycle = ++used;
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
    }

    /*//////////////////////////////////////////////////////////////
                             APPROVALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Approve the conduit (or Seaport) to move the vault's option tokens. Set once;
    ///      the approval is scoped to the clearinghouse's ERC-1155, which only ever holds
    ///      option and claim tokens this vault wrote. It also covers the claim NFT, which is
    ///      safe only because {SeaportOrderLib} pins the offer item to the cycle's option id.
    function _approveOptionTransfers(address clearAddress) internal {
        IERC1155Minimal(clearAddress).setApprovalForAll(transferApprovalTarget, true);
    }
}
