// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    ISeaport,
    OrderComponents,
    OrderParameters,
    Order,
    OfferItem,
    ConsiderationItem,
    ItemType,
    OrderType
} from "../interfaces/ISeaport.sol";
import {Policy} from "../Policy.sol";

/// @title SeaportOrderLib
/// @notice Validation and encoding for the vault's Seaport listings.
/// @dev DEPLOYMENT NOTE: these functions are `public`, so this compiles to a standalone
///      library that {Vault} reaches by DELEGATECALL and that must be deployed and linked
///      before the vault. That is not a style preference. Seaport's order structs nest
///      dynamic arrays, and the three encoders the vault needs (`getOrderHash`, `validate`,
///      `cancel`) cost several kilobytes inlined, which pushed the vault past the EIP-170
///      24 KB runtime limit. Foundry links this automatically in tests; `script/Deploy.s.sol`
///      deploys it explicitly.
///
///      DELEGATECALL SEMANTICS MATTER HERE. Because a `public` library function runs in the
///      caller's context, `address(this)` inside these functions is the VAULT, and the calls
///      made out to Seaport carry the vault as `msg.sender`. That is exactly what `validate`
///      and `cancel` require: Seaport only accepts them from the offerer.
library SeaportOrderLib {
    /// @dev Everything the shape check needs from the vault's own state, in one struct so
    ///      the checks stay inside the EVM stack limit.
    struct Checks {
        address zone;
        bytes32 conduitKey;
        address overcallFeeRecipient;
        address usdgToken;
        address clearAddress;
        uint256 expectedOptionId;
        uint256 availableContracts;
        uint40 exerciseTimestamp;
        uint256 strikeUsdg;
    }

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error BadOfferer(address got);
    error BadZone(address expected, address got);
    error BadConduitKey(bytes32 expected, bytes32 got);
    error BadZoneHash(bytes32 got);
    error BadOrderType(OrderType got);
    error BadOfferLength(uint256 got);
    error BadOfferItemType(ItemType got);
    error BadOfferToken(address expected, address got);
    error BadOfferIdentifier(uint256 expected, uint256 got);
    error DutchAuctionNotAllowed();
    error OfferAmountZero();
    error OfferExceedsInventory(uint256 requested, uint256 available);
    error BadConsiderationLength(uint256 got);
    error BadConsiderationItemType(ItemType got);
    error BadConsiderationToken(address expected, address got);
    error BadConsiderationIdentifier(uint256 got);
    error BadVaultRecipient(address expected, address got);
    error BadOvercallRecipient(address expected, address got);
    error BadFeeSplit(uint256 expectedToVault, uint256 gotToVault, uint256 expectedToOvercall, uint256 gotToOvercall);
    error PremiumNotDivisibleByOrderSize(uint256 grossUsdg, uint256 amount);
    error OvercallFeeRoundsToZero(uint256 unitPriceUsdg, uint256 minimum);
    error UnitPriceExceedsStrike(uint256 unitPriceUsdg, uint256 strikeUsdg);
    error BadCounter(uint256 expected, uint256 got);
    error ListingOutlivesExercise(uint256 endTime, uint256 exerciseTimestamp);
    error ListingStartsInFuture(uint256 startTime);
    error ListingAlreadyEnded(uint256 endTime);
    error SeaportValidateFailed();
    error SeaportCancelFailed();
    error OrderHashMismatch(bytes32 expected, bytes32 got);

    /*//////////////////////////////////////////////////////////////
                          VALIDATE + AUTHORISE
    //////////////////////////////////////////////////////////////*/

    /// @notice Check a proposed order against the vault's state, then mark it valid on Seaport.
    /// @dev Runs by DELEGATECALL, so `address(this)` is the vault throughout.
    function approve(ISeaport seaport, OrderComponents calldata c, Checks memory k)
        public
        returns (bytes32 orderHash, uint256 grossUsdg, uint256 amount)
    {
        amount = _checkOffer(c, k);
        grossUsdg = _checkConsideration(c, k, amount);
        _checkTiming(seaport, c, k.exerciseTimestamp);

        orderHash = seaport.getOrderHash(c);

        Order[] memory orders = new Order[](1);
        orders[0] = Order({parameters: toParameters(c), signature: ""});
        if (!seaport.validate(orders)) revert SeaportValidateFailed();
    }

    /// @notice Cancel an order on Seaport after confirming it is the one the vault authorised.
    function cancel(ISeaport seaport, OrderComponents calldata c, bytes32 expectedHash) public returns (bytes32) {
        bytes32 got = seaport.getOrderHash(c);
        if (got != expectedHash) revert OrderHashMismatch(expectedHash, got);

        OrderComponents[] memory arr = new OrderComponents[](1);
        arr[0] = c;
        if (!seaport.cancel(arr)) revert SeaportCancelFailed();
        return got;
    }

    /// @dev OrderComponents -> OrderParameters. They differ only in the last field:
    ///      components carry the offerer's counter, parameters carry the consideration count.
    function toParameters(OrderComponents calldata c) public pure returns (OrderParameters memory p) {
        p.offerer = c.offerer;
        p.zone = c.zone;
        p.offer = c.offer;
        p.consideration = c.consideration;
        p.orderType = c.orderType;
        p.startTime = c.startTime;
        p.endTime = c.endTime;
        p.zoneHash = c.zoneHash;
        p.salt = c.salt;
        p.conduitKey = c.conduitKey;
        p.totalOriginalConsiderationItems = c.consideration.length;
    }

    /*//////////////////////////////////////////////////////////////
                             SHAPE CHECKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Who the order is from, and what it is selling.
    function _checkOffer(OrderComponents calldata c, Checks memory k) private view returns (uint256 amount) {
        if (c.offerer != address(this)) revert BadOfferer(c.offerer);
        if (c.zone != k.zone) revert BadZone(k.zone, c.zone);
        if (c.conduitKey != k.conduitKey) revert BadConduitKey(k.conduitKey, c.conduitKey);
        // Overcall's schema refuses any non-zero zone hash, and a listing has no zone to pass
        // data to anyway.
        if (c.zoneHash != bytes32(0)) revert BadZoneHash(c.zoneHash);

        // Restricted orders hand a third party a veto over every fill. Contract orders are a
        // different mechanism entirely. Neither belongs on a vault listing.
        if (c.orderType != OrderType.FULL_OPEN && c.orderType != OrderType.PARTIAL_OPEN) {
            revert BadOrderType(c.orderType);
        }

        if (c.offer.length != 1) revert BadOfferLength(c.offer.length);
        OfferItem calldata o = c.offer[0];
        if (o.itemType != ItemType.ERC1155) revert BadOfferItemType(o.itemType);
        if (o.token != k.clearAddress) revert BadOfferToken(k.clearAddress, o.token);
        if (o.identifierOrCriteria != k.expectedOptionId) {
            revert BadOfferIdentifier(k.expectedOptionId, o.identifierOrCriteria);
        }
        // A start != end amount is a Dutch auction. The premium floor would only bind at one
        // end of the ramp, so it is refused outright.
        if (o.startAmount != o.endAmount) revert DutchAuctionNotAllowed();
        amount = o.startAmount;
        if (amount == 0) revert OfferAmountZero();
        if (amount > k.availableContracts) revert OfferExceedsInventory(amount, k.availableContracts);
    }

    /// @dev Who gets paid, how much, and in what.
    function _checkConsideration(OrderComponents calldata c, Checks memory k, uint256 amount)
        private
        view
        returns (uint256 grossUsdg)
    {
        if (c.consideration.length != 2) revert BadConsiderationLength(c.consideration.length);

        ConsiderationItem calldata toVault = c.consideration[0];
        ConsiderationItem calldata toOvercall = c.consideration[1];

        if (toVault.itemType != ItemType.ERC20) revert BadConsiderationItemType(toVault.itemType);
        if (toOvercall.itemType != ItemType.ERC20) revert BadConsiderationItemType(toOvercall.itemType);
        if (toVault.token != k.usdgToken) revert BadConsiderationToken(k.usdgToken, toVault.token);
        if (toOvercall.token != k.usdgToken) revert BadConsiderationToken(k.usdgToken, toOvercall.token);
        if (toVault.identifierOrCriteria != 0) revert BadConsiderationIdentifier(toVault.identifierOrCriteria);
        if (toOvercall.identifierOrCriteria != 0) revert BadConsiderationIdentifier(toOvercall.identifierOrCriteria);
        if (toVault.startAmount != toVault.endAmount) revert DutchAuctionNotAllowed();
        if (toOvercall.startAmount != toOvercall.endAmount) revert DutchAuctionNotAllowed();

        // The vault must be paid, and Overcall must be paid their fee. Getting recipient[0]
        // wrong is how a compromised keeper would route the premium to itself.
        if (toVault.recipient != address(this)) revert BadVaultRecipient(address(this), toVault.recipient);
        if (toOvercall.recipient != k.overcallFeeRecipient) {
            revert BadOvercallRecipient(k.overcallFeeRecipient, toOvercall.recipient);
        }

        grossUsdg = toVault.startAmount + toOvercall.startAmount;

        // Every Overcall listing is PARTIAL_OPEN, so both consideration amounts must divide
        // evenly by the order size or Seaport rejects a fraction with InexactFraction. That
        // starts with the gross being an exact multiple of the contract count.
        if (grossUsdg % amount != 0) revert PremiumNotDivisibleByOrderSize(grossUsdg, amount);
        uint256 unitPriceUsdg = grossUsdg / amount;

        // Below this the 5% fee floors to zero, and Overcall's schema rejects a zero-amount
        // consideration item, so the listing would never reach a buyer.
        uint256 minUnit = Policy.minListableUnitPrice();
        if (unitPriceUsdg < minUnit) revert OvercallFeeRoundsToZero(unitPriceUsdg, minUnit);

        // A premium above the strike is never a real quote; it is a fat finger or a corrupted
        // price feed. Overcall rejects it server-side too.
        if (k.strikeUsdg != 0 && unitPriceUsdg > k.strikeUsdg) {
            revert UnitPriceExceedsStrike(unitPriceUsdg, k.strikeUsdg);
        }

        (uint256 expVault, uint256 expOvercall,) = Policy.splitPremium(unitPriceUsdg, amount);
        if (toVault.startAmount != expVault || toOvercall.startAmount != expOvercall) {
            revert BadFeeSplit(expVault, toVault.startAmount, expOvercall, toOvercall.startAmount);
        }
    }

    /// @dev When the order is live, and that it cannot be replayed.
    function _checkTiming(ISeaport seaport, OrderComponents calldata c, uint40 exerciseTimestamp) private view {
        if (c.startTime > block.timestamp) revert ListingStartsInFuture(c.startTime);
        if (c.endTime <= block.timestamp) revert ListingAlreadyEnded(c.endTime);
        // A listing that outlives the exercise window could be filled after the buyer's right
        // to exercise has already begun, which is not a call anyone should be selling.
        if (c.endTime > exerciseTimestamp) revert ListingOutlivesExercise(c.endTime, exerciseTimestamp);

        uint256 counter = seaport.getCounter(address(this));
        if (c.counter != counter) revert BadCounter(counter, c.counter);
    }
}
