// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {Vault} from "../../src/Vault.sol";
import {Policy} from "../../src/Policy.sol";
import {AdapterSeaport} from "../../src/AdapterSeaport.sol";
import {SeaportOrderLib} from "../../src/lib/SeaportOrderLib.sol";
import {OrderComponents, OfferItem, ConsiderationItem, ItemType, OrderType} from "../../src/interfaces/ISeaport.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Seaport order authorisation: what the vault will list, and everything it won't.
/// @dev This is the surface that stops a compromised keeper. The keeper never holds an option
///      token and never holds a signing key for the vault; the only way a contract is ever written
///      and sold is a fill of an order the vault itself authorised, through the vault's own zone
///      hooks. So every field of that order is checked on chain, and the bulk of this file is the
///      rejection matrix for those checks. What happens INSIDE a fill is test/unit/VaultWriteOnFill.t.sol.
///
///      TESTING NOTE, and it bit this repo once already: `vm.expectRevert` arms the NEXT
///      external call. Every helper here that touches the vault, the clearinghouse or Seaport is
///      hoisted into a local BEFORE the cheatcode, including the expected-error bytes.
contract VaultListingTest is BaseTest {
    /*//////////////////////////////////////////////////////////////
                              LOCAL FIXTURE
    //////////////////////////////////////////////////////////////*/

    /// @dev Contracts listed in the standard setup. 10 lots against a 30e18 deposit sits well
    ///      inside the 95% utilization limit (28) and the 50-lot cap.
    uint112 internal constant N = 10;

    event ListingApproved(
        bytes32 indexed orderHash, uint256 indexed optionId, uint256 amount, uint256 grossUsdg, uint8 seq
    );
    event ListingCancelled(bytes32 indexed orderHash);
    event AllListingsInvalidated(uint256 newCounter);

    /// @dev Deposit, ARM the in-band rung, and hand back a well-formed order for N contracts.
    ///      Nothing is approved yet: each rejection test mutates exactly one field first.
    function _openAndBuild() internal returns (uint256 optionId, OrderComponents memory c) {
        _deposit(alice, 30e18);
        optionId = _rollOpen();
        c = _buildOrder(optionId, N, _okUnitPrice());
    }

    /// @dev Propose `c` as the keeper and require it to revert with exactly `err`.
    ///      `err` must already be computed by the caller: building it here would put an
    ///      external call between the cheatcode and the call it is arming.
    function _rejects(OrderComponents memory c, bytes memory err) internal {
        vm.prank(keeper);
        vm.expectRevert(err);
        vault.approveListing(c);
    }

    /*//////////////////////////////////////////////////////////////
                             THE HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_approveListing_recordsTheAuthorisedOrder() public {
        (uint256 optionId, OrderComponents memory c) = _openAndBuild();
        bytes32 expectedHash = seaport.getOrderHash(c);

        vm.expectEmit(true, true, true, true, address(vault));
        emit ListingApproved(expectedHash, optionId, N, 19_000_000, 1);

        vm.prank(keeper);
        vault.approveListing(c);

        assertEq(vault.listingHash(), expectedHash, "listingHash is the authorised order");
        assertEq(vault.listingGrossUsdg(), 19_000_000, "$1.90 x 10 contracts, every unit of it the vault's");
        assertEq(vault.listingAmount(), N, "10 contracts offered");
        assertEq(vault.listingsThisCycle(), 1, "first of the three listings this cycle");
        assertTrue(mockSeaport.validated(expectedHash), "order marked valid on Seaport so it fills unsigned");
        assertEq(vault.contractsWritten(), 0, "listing writes nothing: the fill does");
        assertEq(clear.balanceOf(address(vault), optionId), 0, "and the vault holds no option tokens");

        (bool isValidated, bool isCancelled, uint256 totalFilled, uint256 totalSize) =
            seaport.getOrderStatus(expectedHash);
        assertTrue(isValidated, "validated");
        assertFalse(isCancelled, "not cancelled");
        assertEq(totalFilled, 0, "nothing filled yet");
        assertEq(totalSize, N, "order size is the offer amount");
    }

    /// @dev CAPACITY, NOT INVENTORY. The keeper may list everything the size gate would still
    ///      admit: `Policy.maxContracts(NAV) - contractsWritten`. 30 NVDA at 95% is 28 lots.
    function test_approveListing_acceptsTheWholeCapacity() public {
        _deposit(alice, 30e18);
        uint256 optionId = _rollOpen();
        OrderComponents memory c = _buildOrder(optionId, 28, _okUnitPrice());
        vm.prank(keeper);
        vault.approveListing(c);
        assertEq(vault.listingAmount(), 28, "the full capacity is listable at once");
    }

    /*//////////////////////////////////////////////////////////////
                        REJECTIONS: WHO AND WHAT
    //////////////////////////////////////////////////////////////*/

    function test_reject_badOfferer() public {
        (, OrderComponents memory c) = _openAndBuild();
        c.offerer = alice;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadOfferer.selector, alice));
    }

    /// @dev THE ZONE IS THE VAULT. Any other zone (including none) would promise option tokens the
    ///      vault never mints, because the write happens inside the vault's own `authorizeOrder`.
    function test_reject_zoneOtherThanTheVault() public {
        (, OrderComponents memory c) = _openAndBuild();
        c.zone = bob;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadZone.selector, address(vault), bob));

        c.zone = address(0);
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadZone.selector, address(vault), address(0)));
    }

    function test_reject_nonZeroZoneHash() public {
        (, OrderComponents memory c) = _openAndBuild();
        c.zoneHash = keccak256("payload");
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadZoneHash.selector, keccak256("payload")));
    }

    function test_reject_nonZeroConduitKey() public {
        (, OrderComponents memory c) = _openAndBuild();
        bytes32 rogueKey = bytes32(uint256(1));
        c.conduitKey = rogueKey;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadConduitKey.selector, bytes32(0), rogueKey));
    }

    /// @dev PARTIAL_RESTRICTED and nothing else. An OPEN order would let Seaport try to move tokens
    ///      the vault does not hold without ever calling the hook that writes them; FULL_RESTRICTED
    ///      could only fill in one shot; CONTRACT orders are a different mechanism.
    function test_reject_everyOrderTypeButPartialRestricted() public {
        (, OrderComponents memory c) = _openAndBuild();

        c.orderType = OrderType.FULL_OPEN;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadOrderType.selector, OrderType.FULL_OPEN));

        c.orderType = OrderType.PARTIAL_OPEN;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadOrderType.selector, OrderType.PARTIAL_OPEN));

        c.orderType = OrderType.FULL_RESTRICTED;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadOrderType.selector, OrderType.FULL_RESTRICTED));

        c.orderType = OrderType.CONTRACT;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadOrderType.selector, OrderType.CONTRACT));
    }

    function test_reject_twoOfferItems() public {
        (, OrderComponents memory c) = _openAndBuild();
        OfferItem[] memory two = new OfferItem[](2);
        two[0] = c.offer[0];
        two[1] = c.offer[0];
        c.offer = two;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadOfferLength.selector, 2));
    }

    function test_reject_zeroOfferItems() public {
        (, OrderComponents memory c) = _openAndBuild();
        c.offer = new OfferItem[](0);
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadOfferLength.selector, 0));
    }

    /// @dev An ERC20 offer item is how a keeper would try to offer the vault's USDG.
    function test_reject_erc20OfferItem() public {
        (, OrderComponents memory c) = _openAndBuild();
        c.offer[0].itemType = ItemType.ERC20;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadOfferItemType.selector, ItemType.ERC20));
    }

    /// @dev And offering the underlying Stock Token itself would be selling the collateral.
    function test_reject_wrongOfferToken() public {
        (, OrderComponents memory c) = _openAndBuild();
        c.offer[0].token = address(nvda);
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadOfferToken.selector, address(clear), address(nvda)));
    }

    function test_reject_wrongOptionId() public {
        (uint256 optionId, OrderComponents memory c) = _openAndBuild();
        uint256 otherRung = optionIds[RUNG_MID];
        c.offer[0].identifierOrCriteria = otherRung;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadOfferIdentifier.selector, optionId, otherRung));
    }

    /// @dev startAmount != endAmount is a Dutch auction. The premium floor would only bind at
    ///      one end of the ramp, so it is refused wherever it appears in the order.
    function test_reject_dutchAuctionInTheOffer() public {
        (, OrderComponents memory c) = _openAndBuild();
        c.offer[0].endAmount = N - 1;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.DutchAuctionNotAllowed.selector));
    }

    function test_reject_dutchAuctionInTheConsideration() public {
        (, OrderComponents memory c) = _openAndBuild();
        c.consideration[0].endAmount = c.consideration[0].startAmount - 1;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.DutchAuctionNotAllowed.selector));
    }

    function test_reject_zeroOfferAmount() public {
        (, OrderComponents memory c) = _openAndBuild();
        c.offer[0].startAmount = 0;
        c.offer[0].endAmount = 0;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.OfferAmountZero.selector));
    }

    /// @dev Offering more than the size gate would admit is a listing no full fill could ever clear:
    ///      the hook would refuse it at the margin, so it is dead weight refused up front.
    function test_reject_offerExceedsCapacity() public {
        _deposit(alice, 30e18);
        uint256 optionId = _rollOpen();
        OrderComponents memory c = _buildOrder(optionId, 29, _okUnitPrice());
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.OfferExceedsCapacity.selector, 29, 28));
    }

    /// @dev Capacity shrinks as fills write, and the next listing must respect that: after 4 of 10
    ///      have sold (and been written), the relist may offer at most 28 - 4 = 24.
    function test_reject_relistingMoreThanTheRemainingCapacity() public {
        (uint256 optionId, OrderComponents memory c) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(c);
        _fill(c, 4);
        assertEq(vault.contractsWritten(), 4, "four written by the fill");

        vm.prank(keeper);
        vault.cancelListing(c);

        OrderComponents memory tooBig = _buildOrder(optionId, 25, _okUnitPrice() + 100_000);
        _rejects(tooBig, abi.encodeWithSelector(SeaportOrderLib.OfferExceedsCapacity.selector, 25, 24));

        // Exactly the remaining capacity is fine.
        OrderComponents memory ok = _buildOrder(optionId, 24, _okUnitPrice() + 100_000);
        vm.prank(keeper);
        vault.approveListing(ok);
        assertEq(vault.listingAmount(), 24, "relisted the remaining capacity");
    }

    /*//////////////////////////////////////////////////////////////
                     REJECTIONS: WHO GETS PAID, AND HOW MUCH
    //////////////////////////////////////////////////////////////*/

    /// @dev ONE consideration item. There is no venue fee item any more: paying a third party for
    ///      flow it did not provide would be a pure depositor cost, and a second recipient is one
    ///      more place a compromised keeper could route premium.
    function test_reject_anyConsiderationLengthButOne() public {
        (, OrderComponents memory c) = _openAndBuild();

        ConsiderationItem[] memory two = new ConsiderationItem[](2);
        two[0] = c.consideration[0];
        two[1] = c.consideration[0];
        c.consideration = two;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadConsiderationLength.selector, 2));

        c.consideration = new ConsiderationItem[](0);
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadConsiderationLength.selector, 0));
    }

    /// @dev An ERC-1155 consideration would be the vault "selling" its calls for more calls; a
    ///      NATIVE one would be payment in a token the vault has no distribution path for at all.
    function test_reject_nonErc20ConsiderationItem() public {
        (, OrderComponents memory c) = _openAndBuild();

        c.consideration[0].itemType = ItemType.ERC1155;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadConsiderationItemType.selector, ItemType.ERC1155));

        c.consideration[0].itemType = ItemType.NATIVE;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadConsiderationItemType.selector, ItemType.NATIVE));
    }

    /// @dev Getting paid in something other than USDG is getting paid in something the vault
    ///      cannot distribute.
    function test_reject_nonUsdgConsideration() public {
        (, OrderComponents memory c) = _openAndBuild();
        c.consideration[0].token = address(nvda);
        _rejects(
            c, abi.encodeWithSelector(SeaportOrderLib.BadConsiderationToken.selector, address(usdg), address(nvda))
        );
    }

    function test_reject_nonZeroConsiderationIdentifier() public {
        (, OrderComponents memory c) = _openAndBuild();
        c.consideration[0].identifierOrCriteria = 7;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadConsiderationIdentifier.selector, 7));
    }

    /// @dev THE attack. A compromised keeper proposes a perfectly-priced order that pays the
    ///      premium to the keeper instead of the vault. No address but the vault is accepted.
    function testFuzz_reject_premiumPaidToAnyoneButTheVault(address rogue) public {
        vm.assume(rogue != address(vault));
        (, OrderComponents memory c) = _openAndBuild();
        c.consideration[0].recipient = payable(rogue);
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadVaultRecipient.selector, address(vault), rogue));
    }

    /// @dev A gross that is not a whole multiple of the contract count cannot be filled in
    ///      fractions at all, and the hook needs an exact unit price to re-check the floor per fill.
    function test_reject_grossNotDivisibleByOrderSize() public {
        (, OrderComponents memory c) = _openAndBuild();
        c.consideration[0].startAmount += 1;
        c.consideration[0].endAmount += 1;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.PremiumNotDivisibleByOrderSize.selector, 19_000_001, N));
    }

    /// @dev A premium above the strike is never a real quote, it is a fat finger or a broken
    ///      feed. The strike itself is still listable: the check is strictly-greater.
    function test_reject_unitPriceAboveTheStrike() public {
        _deposit(alice, 30e18);
        uint256 optionId = _rollOpen();
        uint256 strike = vault.cycleStrikeUsdg();
        assertEq(strike, 231_000_000, "the in-band rung");
        OrderComponents memory c = _buildOrder(optionId, N, strike + 1);
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.UnitPriceExceedsStrike.selector, strike + 1, strike));

        OrderComponents memory atStrike = _buildOrder(optionId, N, strike);
        vm.prank(keeper);
        vault.approveListing(atStrike);
        assertEq(vault.listingGrossUsdg(), 2_310_000_000, "a unit price equal to the strike is accepted");
    }

    /*//////////////////////////////////////////////////////////////
                         REJECTIONS: TIMING AND REPLAY
    //////////////////////////////////////////////////////////////*/

    function test_reject_staleCounter() public {
        (, OrderComponents memory c) = _openAndBuild();
        c.counter = 1;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadCounter.selector, 0, 1));
    }

    /// @dev A listing that outlives the exercise window could be filled after the buyer's
    ///      right to exercise has already begun. That is not a call anyone should be selling.
    function test_reject_endTimePastTheExerciseTimestamp() public {
        (, OrderComponents memory c) = _openAndBuild();
        c.endTime = uint256(exerciseTs) + 1;
        _rejects(
            c,
            abi.encodeWithSelector(
                SeaportOrderLib.ListingOutlivesExercise.selector, uint256(exerciseTs) + 1, exerciseTs
            )
        );

        // ...and an order that ends exactly when the window opens is legal. Seaport's `endTime` is
        // exclusive, so it fills up to the second before and never on the tick; the fill hook
        // enforces the same edge itself (VaultWriteOnFill.t.sol).
        c.endTime = exerciseTs;
        vm.prank(keeper);
        vault.approveListing(c);
        assertEq(vault.listingHash(), seaport.getOrderHash(c), "endTime == exerciseTs is accepted");
    }

    function test_reject_endTimeAlreadyPast() public {
        (, OrderComponents memory c) = _openAndBuild();
        uint256 nowTs = block.timestamp;
        c.endTime = nowTs;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.ListingAlreadyEnded.selector, nowTs));

        // The check is `endTime <= now`, so an order that survives one more second is legal.
        c.endTime = nowTs + 1;
        vm.prank(keeper);
        vault.approveListing(c);
        assertEq(vault.listingHash(), seaport.getOrderHash(c), "endTime one second out is accepted");
    }

    function test_reject_startTimeInTheFuture() public {
        (, OrderComponents memory c) = _openAndBuild();
        uint256 nowTs = block.timestamp;
        c.startTime = nowTs + 1;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.ListingStartsInFuture.selector, nowTs + 1));

        // A listing that starts in THIS block is live now, not in the future, so it is legal.
        c.startTime = nowTs;
        vm.prank(keeper);
        vault.approveListing(c);
        assertEq(vault.listingHash(), seaport.getOrderHash(c), "startTime == now is accepted");
    }

    /*//////////////////////////////////////////////////////////////
                         REJECTIONS: THE POLICY FLOORS
    //////////////////////////////////////////////////////////////*/

    /// @dev The economic floor is 0.40% of spot notional per week. At $220 spot that is
    ///      $0.88 a contract, so $0.80 must fail and $0.90 must pass. The order shape is
    ///      impeccable in both cases: this gate is purely about price. It is an EARLY refusal
    ///      for the keeper; the hook re-derives the floor at the spot of each fill.
    function test_reject_premiumBelowThePolicyFloor() public {
        _deposit(alice, 30e18);
        uint256 optionId = _rollOpen();

        OrderComponents memory tooCheap = _buildOrder(optionId, N, 800_000);
        _rejects(tooCheap, abi.encodeWithSelector(Policy.PremiumBelowMinimum.selector, 8_000_000, 8_800_000));

        assertEq(vault.listingHash(), bytes32(0), "a rejected listing leaves no trace");
        assertEq(vault.listingsThisCycle(), 0, "and does not burn a listing slot");

        OrderComponents memory justEnough = _buildOrder(optionId, N, 900_000);
        vm.prank(keeper);
        vault.approveListing(justEnough);
        assertEq(vault.listingGrossUsdg(), 9_000_000, "$0.90 clears the $0.88 floor");
    }

    /// @dev The floor is `premium < floor` reverts, so the floor itself must be listable.
    ///        floor(gross) = 220_000_000 x 10 x 40 / 10_000 = 8_800_000
    ///        880_000 x 10 = 8_800_000  -> exactly the floor, must be ACCEPTED
    ///        879_999 x 10 = 8_799_990  -> ten base units under, must be REJECTED
    function test_policyFloorIsInclusiveAtTheExactBoundary() public {
        _deposit(alice, 30e18);
        uint256 optionId = _rollOpen();

        OrderComponents memory under = _buildOrder(optionId, N, 879_999);
        _rejects(under, abi.encodeWithSelector(Policy.PremiumBelowMinimum.selector, 8_799_990, 8_800_000));

        OrderComponents memory exactlyOnTheFloor = _buildOrder(optionId, N, 880_000);
        vm.prank(keeper);
        vault.approveListing(exactlyOnTheFloor);
        assertEq(vault.listingGrossUsdg(), 8_800_000, "a premium exactly on the floor is listable");
        assertEq(vault.listingsThisCycle(), 1, "and the rejected one burned no slot");
    }

    /// @dev Regression (review round 1): after a rally to $225 the band floor is 231.75, above the
    ///      231 strike armed at $220. A listing then would only ever be refused at the hook, fill
    ///      after fill, so the keeper cannot publish it at all. FLOOR ONLY (decision D9): after a
    ///      sell-off the strike sits above the band ceiling, which makes the call safer to sell.
    function test_approveListing_refusesAStrikeBelowTheLiveBandFloorButNotAboveTheCeiling() public {
        _deposit(alice, 30e18);
        uint256 optionId = _rollOpen();
        feed.setAnswer(225_00000000);
        _rejects(
            _buildOrder(optionId, N, _okUnitPrice()),
            abi.encodeWithSelector(Policy.StrikeBelowBand.selector, uint256(231_000_000), uint256(231_750_000))
        );
        assertEq(vault.listingHash(), bytes32(0), "nothing listed");
        assertEq(vault.listingsThisCycle(), 0);

        // A sell-off to $200 puts the 231 strike 15.5% out, above the 12% ceiling: still listable.
        feed.setAnswer(200_00000000);
        OrderComponents memory c = _buildOrder(optionId, N, _okUnitPrice());
        vm.prank(keeper);
        vault.approveListing(c);
        assertEq(vault.listingHash(), seaport.getOrderHash(c), "the ceiling is not re-checked after the arm");
    }

    /*//////////////////////////////////////////////////////////////
                      ONE LIVE LISTING, THREE PER CYCLE
    //////////////////////////////////////////////////////////////*/

    /// @dev Two live orders would both fill and both write, so a second listing is refused until
    ///      the first is explicitly cancelled.
    function test_onlyOneListingLiveAtATime() public {
        (uint256 optionId, OrderComponents memory first) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(first);
        bytes32 live = vault.listingHash();

        OrderComponents memory second = _buildOrder(optionId, N, _okUnitPrice() + 100_000);
        _rejects(second, abi.encodeWithSelector(AdapterSeaport.PreviousListingLive.selector, live));

        vm.prank(keeper);
        vault.cancelListing(first);
        assertEq(vault.listingHash(), bytes32(0), "cancel clears the live hash");
        assertEq(vault.listingGrossUsdg(), 0, "and the recorded gross");
        assertEq(vault.listingAmount(), 0, "and the recorded size");
        assertTrue(mockSeaport.cancelled(live), "cancelled on Seaport too");

        vm.prank(keeper);
        vault.approveListing(second);
        assertEq(vault.listingHash(), seaport.getOrderHash(second), "the replacement is live");
        assertEq(vault.listingsThisCycle(), 2, "every authorisation spends a slot");
    }

    /// @dev Under write on fill a listing is a standing offer sized to capacity and Seaport tracks
    ///      the fraction filled, so nothing is ever relisted for size: a relist is a REPRICE, and
    ///      three a week is the ceiling on how far a keeper can walk the quote before the guardian
    ///      must step in. Every authorisation spends a slot, cancelled or not, up or down.
    function test_threeListingsPerCycleThenNoMore() public {
        (uint256 optionId,) = _openAndBuild();
        uint256 p = _okUnitPrice();
        OrderComponents memory a = _buildOrder(optionId, N, p + 300_000);
        OrderComponents memory b = _buildOrder(optionId, N, p + 500_000); // a reprice UP spends one too
        OrderComponents memory c3 = _buildOrder(optionId, N, p + 100_000);
        OrderComponents memory d = _buildOrder(optionId, N, p);

        vm.startPrank(keeper);
        vault.approveListing(a);
        vault.cancelListing(a);
        vault.approveListing(b);
        vault.cancelListing(b);
        vault.approveListing(c3);
        vault.cancelListing(c3);
        vm.stopPrank();

        assertEq(vault.listingsThisCycle(), 3, "budget spent");
        assertEq(vault.listingHash(), bytes32(0), "nothing live, so this is the cap and not the live-listing guard");

        _rejects(d, abi.encodeWithSelector(AdapterSeaport.TooManyListings.selector, uint8(3), uint8(3)));
    }

    /// @dev The budget is per cycle. A new arm reopens it, or the vault would be unlistable
    ///      forever after three reprices in one busy week.
    function test_listingBudgetResetsOnTheNextRollOpen() public {
        _deposit(alice, 30e18);
        uint256 optionId = _rollOpen();
        OrderComponents memory a = _approveListing(optionId, N, _okUnitPrice());
        vm.prank(keeper);
        vault.cancelListing(a);
        _approveListing(optionId, N, _okUnitPrice() - 100_000);
        assertEq(vault.listingsThisCycle(), 2, "two of three used this cycle");

        // Close the week out unfilled, then install next week's cycle.
        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();
        _rollClose();
        _nextWeek();

        _rollOpen();
        assertEq(vault.listingsThisCycle(), 0, "fresh budget for the new cycle");
    }

    /*//////////////////////////////////////////////////////////////
                                 CANCEL
    //////////////////////////////////////////////////////////////*/

    function test_cancelListing_keeperCan() public {
        (, OrderComponents memory c) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(c);
        bytes32 live = vault.listingHash();

        vm.expectEmit(true, true, true, true, address(vault));
        emit ListingCancelled(live);
        vm.prank(keeper);
        vault.cancelListing(c);

        assertEq(vault.listingHash(), bytes32(0), "keeper cancelled");
    }

    /// @dev The guardian is the emergency brake: it must be able to pull a listing without the
    ///      keeper's cooperation, because the usual reason to pull one is a bad keeper.
    function test_cancelListing_guardianCan() public {
        (, OrderComponents memory c) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(c);

        vm.prank(guardian);
        vault.cancelListing(c);

        assertEq(vault.listingHash(), bytes32(0), "guardian cancelled");
    }

    function test_cancelListing_strangerCannot() public {
        (, OrderComponents memory c) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(c);

        bytes32 keeperRole = vault.KEEPER_ROLE();
        bytes memory err =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, keeperRole);

        vm.prank(alice);
        vm.expectRevert(err);
        vault.cancelListing(c);

        assertTrue(vault.listingHash() != bytes32(0), "listing survived the stranger");
    }

    /// @dev Cancelling with the wrong components would leave the real listing live while the
    ///      vault's bookkeeping said otherwise. The hash is checked before anything is cleared.
    function test_cancelListing_rejectsMismatchedComponents() public {
        (uint256 optionId, OrderComponents memory c) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(c);
        bytes32 live = vault.listingHash();

        OrderComponents memory other = _buildOrder(optionId, N, _okUnitPrice() + 100_000);
        bytes32 got = seaport.getOrderHash(other);
        bytes memory err = abi.encodeWithSelector(SeaportOrderLib.OrderHashMismatch.selector, live, got);

        vm.prank(keeper);
        vm.expectRevert(err);
        vault.cancelListing(other);

        assertEq(vault.listingHash(), live, "the real listing is untouched");
    }

    function test_cancelListing_revertsWithNothingLive() public {
        (, OrderComponents memory c) = _openAndBuild();
        bytes memory err = abi.encodeWithSelector(AdapterSeaport.NoLiveListing.selector);
        vm.prank(keeper);
        vm.expectRevert(err);
        vault.cancelListing(c);
    }

    /*//////////////////////////////////////////////////////////////
                          INVALIDATE EVERYTHING
    //////////////////////////////////////////////////////////////*/

    /// @dev The guardian's tool of last resort: it needs no order data, so it still works when
    ///      the keeper is gone and nobody can reconstruct the components. Bumping the counter
    ///      re-keys every order this vault ever validated, so the old one can never come back.
    function test_invalidateAllListings_bumpsTheCounterAndStrandsTheOldOrder() public {
        (, OrderComponents memory c) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(c);
        assertEq(seaport.getCounter(address(vault)), 0, "counter starts at zero");

        vm.expectEmit(true, true, true, true, address(vault));
        emit AllListingsInvalidated(1);
        vm.prank(guardian);
        vault.invalidateAllListings();

        assertEq(seaport.getCounter(address(vault)), 1, "counter bumped");
        assertEq(vault.listingHash(), bytes32(0), "live hash cleared");
        assertEq(vault.listingGrossUsdg(), 0, "gross cleared");
        assertEq(vault.listingAmount(), 0, "amount cleared");

        // The old order is now permanently unapprovable: its counter can never be current again.
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadCounter.selector, 1, 0));
    }

    function test_invalidateAllListings_keeperCanToo() public {
        (, OrderComponents memory c) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(c);

        vm.prank(keeper);
        vault.invalidateAllListings();
        assertEq(vault.listingHash(), bytes32(0), "keeper may also invalidate");
        assertEq(seaport.getCounter(address(vault)), 1, "and the counter really moved");
    }

    function test_invalidateAllListings_strangerCannot() public {
        (, OrderComponents memory c) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(c);

        bytes32 guardianRole = vault.GUARDIAN_ROLE();
        bytes memory err =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, guardianRole);

        vm.prank(bob);
        vm.expectRevert(err);
        vault.invalidateAllListings();

        // A refused call must leave the emergency brake unused, not half-pulled.
        assertTrue(vault.listingHash() != bytes32(0), "the listing survived the stranger");
        assertEq(seaport.getCounter(address(vault)), 0, "and the counter did not move");
    }

    /*//////////////////////////////////////////////////////////////
                             NO SIGNATURES
    //////////////////////////////////////////////////////////////*/

    /// @dev The vault signs nothing. Pre-validation on Seaport is what lets an empty signature fill,
    ///      and it is the only authorisation path; an EIP-1271 hook would be a second one answering
    ///      for digests the vault never checked. It is neither advertised nor present.
    function test_noEip1271_theVaultIsNotASigner() public {
        assertFalse(vault.supportsInterface(0x1626ba7e), "EIP-1271 interface id is not advertised");
        (bool ok,) = address(vault).call(abi.encodeWithSelector(0x1626ba7e, bytes32(0), ""));
        assertFalse(ok, "isValidSignature does not exist on the vault");
    }

    /*//////////////////////////////////////////////////////////////
                        ACCESS CONTROL AND THE HALT
    //////////////////////////////////////////////////////////////*/

    function test_approveListing_isKeeperOnly() public {
        (, OrderComponents memory c) = _openAndBuild();
        bytes32 keeperRole = vault.KEEPER_ROLE();

        bytes memory errAlice =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, keeperRole);
        vm.prank(alice);
        vm.expectRevert(errAlice);
        vault.approveListing(c);

        // The guardian can kill listings but must not be able to create them.
        bytes memory errGuardian =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, keeperRole);
        vm.prank(guardian);
        vm.expectRevert(errGuardian);
        vault.approveListing(c);

        // The admin is not a keeper either.
        bytes memory errAdmin =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, keeperRole);
        vm.prank(admin);
        vm.expectRevert(errAdmin);
        vault.approveListing(c);

        assertEq(vault.listingHash(), bytes32(0), "none of the three authorised anything");
        assertEq(vault.listingsThisCycle(), 0, "and none of them burned a slot");
    }

    function test_approveListing_requiresTheListedPhase() public {
        _deposit(alice, 30e18);
        // Idle: nothing has been armed yet, so there is nothing to list.
        OrderComponents memory c = _buildOrder(optionIds[RUNG_PICK], N, _okUnitPrice());
        bytes memory err = abi.encodeWithSelector(Vault.WrongPhase.selector, Vault.Phase.Listed, Vault.Phase.Idle);
        vm.prank(keeper);
        vm.expectRevert(err);
        vault.approveListing(c);
    }

    function test_approveListing_isBlockedByHaltWrites() public {
        (, OrderComponents memory c) = _openAndBuild();

        vm.prank(guardian);
        vault.haltWrites();

        bytes memory err = abi.encodeWithSelector(Vault.WritesAreHalted.selector);
        vm.prank(keeper);
        vm.expectRevert(err);
        vault.approveListing(c);

        // Unhalting restores it; the halt is a brake, not a bricking.
        vm.prank(admin);
        vault.unhaltWrites();
        vm.prank(keeper);
        vault.approveListing(c);
        assertEq(vault.listingHash(), seaport.getOrderHash(c), "listing works again once unhalted");
    }

    /// @dev The halt must never stop the vault from UNWINDING. Pulling a listing while halted
    ///      is exactly the sequence a guardian runs in an incident.
    function test_haltDoesNotBlockCancelOrInvalidate() public {
        (uint256 optionId, OrderComponents memory c) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(c);

        vm.prank(guardian);
        vault.haltWrites();

        vm.prank(guardian);
        vault.cancelListing(c);
        assertEq(vault.listingHash(), bytes32(0), "cancel works while halted");

        vm.prank(guardian);
        vault.invalidateAllListings();
        assertEq(seaport.getCounter(address(vault)), 1, "invalidate works while halted");

        // Unwinding is open; re-listing is not.
        OrderComponents memory again = _buildOrder(optionId, N, _okUnitPrice() + 100_000);
        _rejects(again, abi.encodeWithSelector(Vault.WritesAreHalted.selector));
    }

    /*//////////////////////////////////////////////////////////////
                               BOOK CLOSE
    //////////////////////////////////////////////////////////////*/

    /// @dev Once the exercise window opens the vault must not still be selling calls. lockBook
    ///      is permissionless and kills any live listing on its way past.
    ///
    ///      NOTE ON WHAT IS ASSERTED: the kill is the Seaport counter bump. Real Seaport
    ///      derives an order's hash from the offerer's CURRENT counter at fulfilment, so a
    ///      bumped counter re-keys every outstanding order and the old one reads as
    ///      unvalidated. MockSeaport stores `validated` under the hash the caller supplies and
    ///      so does not model that re-keying, which is why this asserts the on-chain facts the
    ///      vault actually controls: the counter moved and the recorded hash is gone. The fill
    ///      hook independently refuses a fill outside Listed (VaultWriteOnFill.t.sol).
    function test_lockBook_killsAStillLiveListing() public {
        (, OrderComponents memory c) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(c);

        _warpToExercise();
        vault.lockBook(); // permissionless

        assertEq(_phase(), 2, "Exercisable");
        assertEq(vault.listingHash(), bytes32(0), "no listing survives the book close");
        assertEq(seaport.getCounter(address(vault)), 1, "counter bumped, every outstanding order re-keyed");

        // And no replacement can be authorised once the book is closed.
        bytes memory err =
            abi.encodeWithSelector(Vault.WrongPhase.selector, Vault.Phase.Listed, Vault.Phase.Exercisable);
        vm.prank(keeper);
        vm.expectRevert(err);
        vault.approveListing(c);
    }

    function test_lockBook_isPermissionlessButOnlyAfterTheExerciseTimestamp() public {
        (, OrderComponents memory c) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(c);

        bytes memory err = abi.encodeWithSelector(Vault.NotYetExercisable.selector, exerciseTs);
        vm.prank(carol);
        vm.expectRevert(err);
        vault.lockBook();

        vm.warp(uint256(exerciseTs) - 1);
        vm.prank(carol);
        vm.expectRevert(err);
        vault.lockBook();

        vm.warp(exerciseTs);
        vm.prank(carol); // a stranger, on purpose
        vault.lockBook();
        assertEq(_phase(), 2, "anyone may close the book once the window opens");
    }

    /// @dev Nobody called `lockBook` all week, so the vault reaches expiry still in Listed with
    ///      a live order on the book. `rollClose` has to kill it on the way past.
    function test_rollClose_killsAListingLeftLiveThroughExpiry() public {
        (, OrderComponents memory c) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(c);

        _warpToExpiry();
        assertEq(_phase(), 1, "still Listed: lockBook was never called");
        _rollClose();

        assertEq(_phase(), 0, "Idle");
        assertEq(vault.listingHash(), bytes32(0), "no listing survives the close");
        assertEq(seaport.getCounter(address(vault)), 1, "counter bumped, every outstanding order re-keyed");
    }

    /*//////////////////////////////////////////////////////////////
                        THE ORACLE GATE ON A LISTING
    //////////////////////////////////////////////////////////////*/

    /// @dev `approveListing` reads spot because the economic floor it enforces is a percentage OF
    ///      spot. A broken feed therefore has to stop a listing and not merely an arm.
    function test_approveListing_refusesAStaleSpotPrice() public {
        (, OrderComponents memory c) = _openAndBuild();

        // One second past the 6-hour tolerance is enough; the check is a strict `>`.
        uint256 tooOld = block.timestamp - MAX_PRICE_AGE - 1;
        feed.setUpdatedAt(tooOld);

        bytes memory err = abi.encodeWithSelector(Vault.StalePrice.selector, tooOld, uint256(MAX_PRICE_AGE));
        vm.prank(keeper);
        vm.expectRevert(err);
        vault.approveListing(c);

        assertEq(vault.listingHash(), bytes32(0), "nothing authorised against a stale price");
        assertEq(vault.listingsThisCycle(), 0, "and no slot burned");

        // Exactly ON the tolerance is still fresh, and the listing goes through.
        feed.setUpdatedAt(block.timestamp - MAX_PRICE_AGE);
        vm.prank(keeper);
        vault.approveListing(c);
        assertEq(vault.listingHash(), seaport.getOrderHash(c), "a price exactly at the age limit is usable");
    }

    /// @dev The issuer can halt the Stock Token's own oracle. While it is halted the vault must
    ///      not list anything either, and the guardian must still be able to PULL what is
    ///      already on the book.
    function test_pausedStockOracleBlocksListingButNotTheUnwind() public {
        (, OrderComponents memory c) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(c);
        bytes32 live = vault.listingHash();

        vm.prank(keeper);
        vault.cancelListing(c);

        nvda.setOraclePaused(true);

        bytes memory err = abi.encodeWithSelector(Vault.OraclePaused.selector);
        vm.prank(keeper);
        vm.expectRevert(err);
        vault.approveListing(c);
        assertEq(vault.listingHash(), bytes32(0), "no new listing while the issuer oracle is halted");

        // Re-list once the issuer resumes, then prove the unwind path ignores the oracle.
        nvda.setOraclePaused(false);
        vm.prank(keeper);
        vault.approveListing(c);
        assertEq(vault.listingHash(), live, "same order, same hash, once the oracle is back");

        nvda.setOraclePaused(true);
        vm.prank(guardian);
        vault.cancelListing(c);
        assertEq(vault.listingHash(), bytes32(0), "cancel does not consult the oracle");

        vm.prank(guardian);
        vault.invalidateAllListings();
        assertEq(seaport.getCounter(address(vault)), 1, "nor does invalidateAllListings");
    }

    /*//////////////////////////////////////////////////////////////
                          CAPACITY EXHAUSTED
    //////////////////////////////////////////////////////////////*/

    /// @dev Once the fills have written the whole capacity there is nothing left to list. The
    ///      guard has to hold at zero as well as at a shortfall.
    function test_reject_anyListingOnceCapacityIsWritten() public {
        _deposit(alice, 30e18);
        uint256 optionId = _rollOpen();
        OrderComponents memory c = _approveListing(optionId, 28, _okUnitPrice());
        _fund(buyer, 0, 100_000_000);
        _fill(c, 28);
        assertEq(vault.contractsWritten(), 28, "the vault wrote and sold its whole capacity");

        vm.prank(keeper);
        vault.cancelListing(c);

        OrderComponents memory oneMore = _buildOrder(optionId, 1, _okUnitPrice() + 100_000);
        _rejects(oneMore, abi.encodeWithSelector(SeaportOrderLib.OfferExceedsCapacity.selector, 1, 0));
        assertEq(vault.listingsThisCycle(), 1, "the refused proposal burned no slot");
    }
}
