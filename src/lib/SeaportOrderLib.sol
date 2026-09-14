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

/// @title SeaportOrderLib
/// @notice Validation and encoding for the vault's Seaport listings.
/// @dev DEPLOYMENT NOTE: these functions are `public`, so this compiles to a standalone
///      library that {Vault} reaches by DELEGATECALL and that must be deployed and linked
///      before the vault. Seaport's order structs nest dynamic arrays, and the three encoders
///      the vault needs (`getOrderHash`, `validate`, `cancel`) cost several kilobytes inlined.
///      Chain 4663 enforces a 98,304 B code limit rather than EIP-170's 24,576 B, so the split
///      is no longer forced; it is kept because the library has its own Verify check and a
///      smaller vault is a smaller audit surface. Foundry links this automatically in tests;
///      `script/Deploy.s.sol` deploys it explicitly.
///
///      DELEGATECALL SEMANTICS MATTER HERE. Because a `public` library function runs in the
///      caller's context, `address(this)` inside these functions is the VAULT, and the calls
///      made out to Seaport carry the vault as `msg.sender`. That is exactly what `validate`
///      and `cancel` require: Seaport only accepts them from the offerer.
///
///      THE ORDER SHAPE UNDER WRITE-ON-FILL. A listing is a PARTIAL_RESTRICTED order whose zone
///      is the vault itself, offering option tokens the vault does NOT yet hold. Seaport 1.6
///      calls the zone's `authorizeOrder` before it moves anything, and that hook writes exactly
///      the filled amount into Valorem (see {Vault.authorizeOrder}). The order therefore commits,
///      through its hash, to the one zone that can perform the write, to a partial-fill type
///      (so a buyer can take a fraction and the rest stays offered), and to a single USDG
///      consideration item paid to the vault. Nothing else is listable.
library SeaportOrderLib {
    /// @dev Everything the shape check needs from the vault's own state, in one struct so
    ///      the checks stay inside the EVM stack limit.
    struct Checks {
        bytes32 conduitKey;
        address usdgToken;
        address clearAddress;
        uint256 expectedOptionId;
        /// @dev Contracts the vault could still write this cycle: `Policy.maxContracts(NAV)`
        ///      less `contractsWritten`. An order may not offer more than that, or a full fill
        ///      would be refused by the size gate at the hook and the listing would be dead weight.
        uint256 capacityContracts;
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
    error OfferExceedsCapacity(uint256 requested, uint256 capacity);
    error BadConsiderationLength(uint256 got);
    error BadConsiderationItemType(ItemType got);
    error BadConsiderationToken(address expected, address got);
    error BadConsiderationIdentifier(uint256 got);
    error BadVaultRecipient(address expected, address got);
    error PremiumNotDivisibleByOrderSize(uint256 grossUsdg, uint256 amount);
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
    ///
    ///      WHY `validate()` AND NOT A SIGNATURE. Seaport skips signature verification for an
    ///      order the offerer has validated on chain, and for every later fill of a validated
    ///      order (`OrderValidator.sol:270`). The vault has no signing key and no EIP-1271 hook,
    ///      so pre-validation is the ONLY thing that makes an empty-signature fill succeed, and
    ///      killing a listing is therefore `cancel` or `incrementCounter`, never a state flag.
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

    /// @dev Who the order is from, who may authorise its fills, and what it is selling.
    function _checkOffer(OrderComponents calldata c, Checks memory k) private view returns (uint256 amount) {
        if (c.offerer != address(this)) revert BadOfferer(c.offerer);
        // THE ZONE IS THE VAULT, AND NOTHING ELSE. Seaport 1.6 calls the zone's `authorizeOrder`
        // before any transfer of a restricted order, and that hook is where the vault writes the
        // filled contracts into Valorem. An order naming any other zone would be a promise to
        // deliver option tokens the vault never mints; Seaport would then fail the transfer, but
        // refusing it here keeps the keeper from publishing a dead listing at all. The hash
        // commits to the zone, so a foreign order cannot borrow this vault's authorisation.
        if (c.zone != address(this)) revert BadZone(address(this), c.zone);
        if (c.conduitKey != k.conduitKey) revert BadConduitKey(k.conduitKey, c.conduitKey);
        // The vault passes no data to itself through the zone hash.
        if (c.zoneHash != bytes32(0)) revert BadZoneHash(c.zoneHash);

        // PARTIAL_RESTRICTED and only that. Restricted, because the fill must run the vault's
        // hooks (an open order would let Seaport move tokens the vault does not have, and a fill
        // that skipped `authorizeOrder` would skip the write). Partial, because a buyer takes what
        // they want and the remainder stays offered; a FULL_RESTRICTED order could only ever be
        // filled in one shot. CONTRACT orders are a different mechanism entirely.
        if (c.orderType != OrderType.PARTIAL_RESTRICTED) revert BadOrderType(c.orderType);

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
        if (amount > k.capacityContracts) revert OfferExceedsCapacity(amount, k.capacityContracts);
    }

    /// @dev Who gets paid, how much, and in what: ONE consideration item, USDG, to the vault.
    ///      There is no third-party fee item any more. The vault is not listed on any venue that
    ///      takes a cut, and paying one for flow it did not provide would be a pure depositor cost.
    function _checkConsideration(OrderComponents calldata c, Checks memory k, uint256 amount)
        private
        view
        returns (uint256 grossUsdg)
    {
        if (c.consideration.length != 1) revert BadConsiderationLength(c.consideration.length);

        ConsiderationItem calldata toVault = c.consideration[0];
        if (toVault.itemType != ItemType.ERC20) revert BadConsiderationItemType(toVault.itemType);
        if (toVault.token != k.usdgToken) revert BadConsiderationToken(k.usdgToken, toVault.token);
        if (toVault.identifierOrCriteria != 0) revert BadConsiderationIdentifier(toVault.identifierOrCriteria);
        if (toVault.startAmount != toVault.endAmount) revert DutchAuctionNotAllowed();

        // Getting the recipient wrong is how a compromised keeper would route the premium to
        // itself. No address but the vault is accepted.
        if (toVault.recipient != address(this)) revert BadVaultRecipient(address(this), toVault.recipient);

        grossUsdg = toVault.startAmount;

        // A partial fill pays `gross * k / amount`, and Seaport rejects a fraction it cannot
        // express exactly with `InexactFraction`. The gross must therefore be a whole multiple of
        // the contract count, which also makes the per-contract price the hooks re-check at fill
        // time an exact figure rather than a rounded one.
        if (grossUsdg % amount != 0) revert PremiumNotDivisibleByOrderSize(grossUsdg, amount);
        uint256 unitPriceUsdg = grossUsdg / amount;

        // A premium above the strike is never a real quote; it is a fat finger or a corrupted
        // price feed.
        if (k.strikeUsdg != 0 && unitPriceUsdg > k.strikeUsdg) {
            revert UnitPriceExceedsStrike(unitPriceUsdg, k.strikeUsdg);
        }
    }

    /// @dev When the order is live, and that it cannot be replayed.
    function _checkTiming(ISeaport seaport, OrderComponents calldata c, uint40 exerciseTimestamp) private view {
        if (c.startTime > block.timestamp) revert ListingStartsInFuture(c.startTime);
        if (c.endTime <= block.timestamp) revert ListingAlreadyEnded(c.endTime);
        // A listing that outlives the exercise window could be filled after the buyer's right
        // to exercise has already begun, which is not a call anyone should be selling. Seaport
        // treats `endTime` as exclusive, so `endTime == exerciseTimestamp` fills up to the second
        // before the window and not on the tick; the fill hook enforces the same edge itself.
        if (c.endTime > exerciseTimestamp) revert ListingOutlivesExercise(c.endTime, exerciseTimestamp);

        uint256 counter = seaport.getCounter(address(this));
        if (c.counter != counter) revert BadCounter(counter, c.counter);
    }
}
