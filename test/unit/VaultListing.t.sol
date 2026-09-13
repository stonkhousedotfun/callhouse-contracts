// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {Vault} from "../../src/Vault.sol";
import {Policy} from "../../src/Policy.sol";
import {AdapterSeaport} from "../../src/AdapterSeaport.sol";
import {SeaportOrderLib} from "../../src/lib/SeaportOrderLib.sol";
import {OrderComponents, OfferItem, ConsiderationItem, ItemType, OrderType} from "../../src/interfaces/ISeaport.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Seaport order authorisation: what the vault will sign for, and everything it won't.
/// @dev This is the surface that stops a compromised keeper. The keeper never holds the option
///      ERC-1155 and never holds a signing key for the vault; the only way inventory leaves is
///      an order the vault itself authorised. So every field of that order is checked on chain,
///      and the bulk of this file is the rejection matrix for those checks.
///
///      TESTING NOTE, and it bit this repo once already: `vm.expectRevert` arms the NEXT
///      external call. Every helper here that touches the vault, the registry or Seaport is
///      hoisted into a local BEFORE the cheatcode, including the expected-error bytes.
contract VaultListingTest is BaseTest {
    /*//////////////////////////////////////////////////////////////
                              LOCAL FIXTURE
    //////////////////////////////////////////////////////////////*/

    /// @dev Contracts written in the standard setup. 10 lots against a 30e18 deposit sits well
    ///      inside the 95% utilization limit (28) and the 50-lot cap.
    uint112 internal constant N = 10;

    bytes4 internal constant EIP1271_MAGIC = 0x1626ba7e;
    bytes4 internal constant EIP1271_INVALID = 0xffffffff;

    event ListingApproved(
        bytes32 indexed orderHash, uint256 indexed optionId, uint256 amount, uint256 grossUsdg, uint8 seq
    );
    event ListingCancelled(bytes32 indexed orderHash);
    event AllListingsInvalidated(uint256 newCounter);

    /// @dev Deposit, write N contracts, and hand back a well-formed order for them.
    ///      Nothing is approved yet: each rejection test mutates exactly one field first.
    function _openAndBuild() internal returns (uint256 optionId, OrderComponents memory c) {
        _deposit(alice, 30e18);
        optionId = _rollOpen(N);
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

    function _sig(bytes32 h) internal view returns (bytes32) {
        return bytes32(vault.isValidSignature(h, ""));
    }

    /*//////////////////////////////////////////////////////////////
                        THE HAPPY PATH (T-07, F-03)
    //////////////////////////////////////////////////////////////*/

    function test_approveListing_recordsTheAuthorisedOrder() public {
        (uint256 optionId, OrderComponents memory c) = _openAndBuild();
        bytes32 expectedHash = seaport.getOrderHash(c);

        vm.expectEmit(true, true, true, true, address(vault));
        emit ListingApproved(expectedHash, optionId, N, 20_000_000, 1);

        vm.prank(keeper);
        vault.approveListing(c);

        assertEq(vault.listingHash(), expectedHash, "listingHash is the authorised order");
        assertEq(vault.listingGrossUsdg(), 20_000_000, "$2.00 x 10 contracts, gross of Overcall's cut");
        assertEq(vault.listingAmount(), N, "10 contracts offered");
        assertEq(vault.listingsThisCycle(), 1, "first of the three listings this cycle");
        assertTrue(seaport.validated(expectedHash), "order marked valid on Seaport so it fills unsigned");

        (bool isValidated, bool isCancelled, uint256 totalFilled, uint256 totalSize) =
            seaport.getOrderStatus(expectedHash);
        assertTrue(isValidated, "validated");
        assertFalse(isCancelled, "not cancelled");
        assertEq(totalFilled, 0, "nothing filled yet");
        assertEq(totalSize, N, "order size is the offer amount");
    }

    /// @dev FULL_OPEN is the other order type Overcall may publish. It must be accepted too,
    ///      or a legitimate non-partial listing would be unlistable.
    function test_approveListing_acceptsFullOpenAsWellAsPartialOpen() public {
        (, OrderComponents memory c) = _openAndBuild();
        c.orderType = OrderType.FULL_OPEN;

        vm.prank(keeper);
        vault.approveListing(c);

        assertEq(vault.listingHash(), seaport.getOrderHash(c), "FULL_OPEN is a legal shape");
    }

    /// @dev F-03: the fill is where the 95/5 split becomes real money.
    function test_fill_paysVault95AndOvercall5AndMovesTheOptionsOut() public {
        (uint256 optionId, OrderComponents memory c) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(c);

        // THE ARITHMETIC, BY HAND, so a reader can check the fixture instead of trusting it.
        //   unit price        = 2_000_000            ($2.00, USDG is 6 dp)
        //   feePerContract    = 2_000_000 * 500 / 10_000 = 100_000        ($0.10)
        //   writerPerContract = 2_000_000 - 100_000      = 1_900_000      ($1.90)
        //   consideration[1]  =   100_000 * 10 =   1_000_000   ($1.00 to Overcall)
        //   consideration[0]  = 1_900_000 * 10 =  19_000_000   ($19.00 to the vault)
        //   gross             = 2_000_000 * 10 =  20_000_000   ($20.00 out of the buyer)
        // 1_000_000 / 20_000_000 = 5.00% exactly, and 19_000_000 + 1_000_000 = 20_000_000.
        (uint256 toVault, uint256 toOvercall, uint256 gross) = _splitPremium(_okUnitPrice(), N);
        assertEq(gross, 20_000_000, "gross premium");
        assertEq(toVault, 19_000_000, "95%");
        assertEq(toOvercall, 1_000_000, "5%");

        uint256 buyerBefore = usdg.balanceOf(buyer);
        _fill(c, N);

        assertEq(usdg.balanceOf(address(vault)), toVault, "vault received exactly 95% of gross");
        assertEq(usdg.balanceOf(overcallFee), toOvercall, "Overcall received exactly 5% of gross");
        assertEq(usdg.balanceOf(buyer), buyerBefore - gross, "buyer paid gross, no more");
        assertEq(clear.balanceOf(address(vault), optionId), 0, "every option token left the vault");
        assertEq(clear.balanceOf(buyer, optionId), N, "buyer holds the calls");
    }

    /// @dev A partial fill must pay exactly its fraction of BOTH consideration items. This is
    ///      the reason the fee is rounded per contract rather than on the total: Seaport
    ///      rejects any fraction it cannot express exactly.
    function test_partialFill_paysExactlyTheFilledFraction() public {
        (uint256 optionId, OrderComponents memory c) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(c);

        uint256 buyerBefore = usdg.balanceOf(buyer);
        _fill(c, 4);

        // THE ARITHMETIC, BY HAND. Seaport pays each consideration item startAmount*k/total:
        //   vault    = 19_000_000 * 4 / 10 = 7_600_000   ($7.60), remainder 0
        //   Overcall =  1_000_000 * 4 / 10 =   400_000   ($0.40), remainder 0
        //   buyer out = 7_600_000 + 400_000 = 8_000_000  ($8.00 = $2.00 x 4)
        // Both divisions are exact, which is the whole point of rounding the fee per contract:
        // round on the TOTAL and one of these leaves a remainder and Seaport reverts.
        assertEq(usdg.balanceOf(address(vault)), 7_600_000, "40% of 19.00 USDG");
        assertEq(usdg.balanceOf(overcallFee), 400_000, "40% of 1.00 USDG");
        assertEq(buyerBefore - usdg.balanceOf(buyer), 8_000_000, "buyer paid $2.00 x 4, exactly");
        assertEq(clear.balanceOf(address(vault), optionId), 6, "six contracts still in inventory");
        assertEq(clear.balanceOf(buyer, optionId), 4, "buyer holds four");

        // The recorded listing is the ORDER's size and gross, not the outstanding remainder.
        // A UI reading listingAmount as "contracts still for sale" would be wrong here; the
        // vault's own inventory check reads the ERC-1155 balance instead, which is why the
        // relist test below refuses the original size against the shrunken inventory.
        assertEq(vault.listingAmount(), N, "listingAmount is the order size, not the remainder");
        assertEq(vault.listingGrossUsdg(), 20_000_000, "listingGrossUsdg likewise");

        // The remaining 6 completes the order and lands on the full-fill numbers exactly.
        _fill(c, 6);
        assertEq(usdg.balanceOf(address(vault)), 19_000_000, "95% of gross once fully filled");
        assertEq(usdg.balanceOf(overcallFee), 1_000_000, "5% of gross once fully filled");
        assertEq(buyerBefore - usdg.balanceOf(buyer), 20_000_000, "buyer paid gross in total, no more");
        assertEq(clear.balanceOf(address(vault), optionId), 0, "inventory emptied");
    }

    /// @dev Per-contract rounding has to survive every legal (price, size, fill) triple, not
    ///      just the round ones. If the split were rounded on the total, some of these fills
    ///      would revert InexactFraction on Seaport and the week would go unfilled.
    function testFuzz_perContractRoundingKeepsEveryPartialFillExact(uint256 unitPrice, uint8 sizeRaw, uint8 fillRaw)
        public
    {
        uint112 n = uint112(bound(uint256(sizeRaw), 1, 20));
        uint256 k = bound(uint256(fillRaw), 1, n);
        // Lower bound is the policy floor EXACTLY (0.40% of $220 = $0.88/contract), not a
        // comfortable margin above it, so the boundary price is inside the fuzzer's domain.
        // Upper bound is $50, well under the $231 strike and inside the buyer's $5,000 purse
        // at the largest size this bounds to (20 x $50 = $1,000). The wide range matters: it
        // is what generates the odd prices where 5% does NOT divide evenly.
        unitPrice = bound(unitPrice, 880_000, 50_000_000);

        _deposit(alice, 30e18);
        uint256 optionId = _rollOpen(n);
        OrderComponents memory c = _approveListing(optionId, n, unitPrice);

        _fill(c, k);

        uint256 feePerContract = (unitPrice * 500) / 10_000;
        assertEq(usdg.balanceOf(overcallFee), feePerContract * k, "Overcall gets the per-contract fee x fill");
        assertEq(usdg.balanceOf(address(vault)), (unitPrice - feePerContract) * k, "vault gets the remainder x fill");
        assertEq(clear.balanceOf(buyer, optionId), k, "buyer received exactly the filled contracts");
    }

    /*//////////////////////////////////////////////////////////////
                        REJECTIONS: WHO AND WHAT
    //////////////////////////////////////////////////////////////*/

    function test_reject_badOfferer() public {
        (, OrderComponents memory c) = _openAndBuild();
        c.offerer = alice;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadOfferer.selector, alice));
    }

    function test_reject_nonZeroZone() public {
        (, OrderComponents memory c) = _openAndBuild();
        c.zone = bob;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadZone.selector, address(0), bob));
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

    /// @dev A restricted order hands a zone a veto over every fill; a CONTRACT order is a
    ///      different mechanism entirely. Neither belongs on the vault's inventory.
    function test_reject_restrictedAndContractOrderTypes() public {
        (, OrderComponents memory c) = _openAndBuild();

        c.orderType = OrderType.FULL_RESTRICTED;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadOrderType.selector, OrderType.FULL_RESTRICTED));

        c.orderType = OrderType.PARTIAL_RESTRICTED;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadOrderType.selector, OrderType.PARTIAL_RESTRICTED));

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

    function test_reject_dutchAuctionInEitherConsiderationItem() public {
        (, OrderComponents memory c) = _openAndBuild();

        c.consideration[0].endAmount = c.consideration[0].startAmount - 1;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.DutchAuctionNotAllowed.selector));

        c.consideration[0].endAmount = c.consideration[0].startAmount;
        c.consideration[1].endAmount = c.consideration[1].startAmount + 1;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.DutchAuctionNotAllowed.selector));
    }

    function test_reject_zeroOfferAmount() public {
        (, OrderComponents memory c) = _openAndBuild();
        c.offer[0].startAmount = 0;
        c.offer[0].endAmount = 0;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.OfferAmountZero.selector));
    }

    /// @dev Offering more than the vault holds would be a naked call the moment it filled.
    function test_reject_offerExceedsInventory() public {
        _deposit(alice, 30e18);
        uint256 optionId = _rollOpen(N);
        OrderComponents memory c = _buildOrder(optionId, uint256(N) + 1, _okUnitPrice());
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.OfferExceedsInventory.selector, uint256(N) + 1, N));
    }

    /// @dev Inventory shrinks as the order fills, and the next listing must respect that.
    ///      Re-listing the original size after a partial fill is the naked-call hazard again.
    function test_reject_relistingMoreThanTheUnsoldInventory() public {
        (uint256 optionId, OrderComponents memory c) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(c);
        _fill(c, 4);

        vm.prank(keeper);
        vault.cancelListing(c);

        OrderComponents memory tooBig = _buildOrder(optionId, N, _okUnitPrice() + 100_000);
        _rejects(tooBig, abi.encodeWithSelector(SeaportOrderLib.OfferExceedsInventory.selector, N, 6));

        // Exactly the remaining six is fine.
        OrderComponents memory ok = _buildOrder(optionId, 6, _okUnitPrice() + 100_000);
        vm.prank(keeper);
        vault.approveListing(ok);
        assertEq(vault.listingAmount(), 6, "relisted the unsold remainder");
    }

    /*//////////////////////////////////////////////////////////////
                     REJECTIONS: WHO GETS PAID, AND HOW MUCH
    //////////////////////////////////////////////////////////////*/

    function test_reject_oneConsiderationItem() public {
        (, OrderComponents memory c) = _openAndBuild();
        ConsiderationItem[] memory one = new ConsiderationItem[](1);
        one[0] = c.consideration[0];
        c.consideration = one;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadConsiderationLength.selector, 1));
    }

    function test_reject_threeConsiderationItems() public {
        (, OrderComponents memory c) = _openAndBuild();
        ConsiderationItem[] memory three = new ConsiderationItem[](3);
        three[0] = c.consideration[0];
        three[1] = c.consideration[1];
        three[2] = c.consideration[1];
        c.consideration = three;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadConsiderationLength.selector, 3));
    }

    /// @dev Both legs are checked, so both are tested. An ERC-1155 consideration would be the
    ///      vault "selling" its calls for more calls; a NATIVE one would be payment in a token
    ///      the vault has no distribution path for at all.
    function test_reject_nonErc20ConsiderationItem() public {
        (, OrderComponents memory c) = _openAndBuild();

        c.consideration[0].itemType = ItemType.ERC1155;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadConsiderationItemType.selector, ItemType.ERC1155));

        c.consideration[0].itemType = ItemType.ERC20;
        c.consideration[1].itemType = ItemType.NATIVE;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadConsiderationItemType.selector, ItemType.NATIVE));
    }

    /// @dev Getting paid in something other than USDG is getting paid in something the vault
    ///      cannot distribute. Both items are checked.
    function test_reject_nonUsdgConsideration() public {
        (, OrderComponents memory c) = _openAndBuild();

        c.consideration[0].token = address(nvda);
        _rejects(
            c, abi.encodeWithSelector(SeaportOrderLib.BadConsiderationToken.selector, address(usdg), address(nvda))
        );

        c.consideration[0].token = address(usdg);
        c.consideration[1].token = address(nvda);
        _rejects(
            c, abi.encodeWithSelector(SeaportOrderLib.BadConsiderationToken.selector, address(usdg), address(nvda))
        );
    }

    function test_reject_nonZeroConsiderationIdentifier() public {
        (, OrderComponents memory c) = _openAndBuild();

        c.consideration[0].identifierOrCriteria = 7;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadConsiderationIdentifier.selector, 7));

        // The Overcall leg is checked with the same rule; testing only item 0 would leave the
        // second branch of the identifier check unexecuted.
        c.consideration[0].identifierOrCriteria = 0;
        c.consideration[1].identifierOrCriteria = 9;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadConsiderationIdentifier.selector, 9));
    }

    /// @dev THE attack. A compromised keeper proposes a perfectly-priced order that pays the
    ///      premium to the keeper instead of the vault. No address but the vault is accepted.
    function testFuzz_reject_premiumPaidToAnyoneButTheVault(address rogue) public {
        vm.assume(rogue != address(vault));
        (, OrderComponents memory c) = _openAndBuild();
        c.consideration[0].recipient = payable(rogue);
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadVaultRecipient.selector, address(vault), rogue));
    }

    /// @dev The second item is Overcall's 5%. Point it anywhere else and Overcall will not
    ///      surface the listing, so the order is dead weight on chain.
    function testFuzz_reject_overcallFeePaidToTheWrongAddress(address rogue) public {
        vm.assume(rogue != overcallFee);
        (, OrderComponents memory c) = _openAndBuild();
        c.consideration[1].recipient = payable(rogue);
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadOvercallRecipient.selector, overcallFee, rogue));
    }

    /// @dev Rounding the 5% on the TOTAL instead of per contract still produces a signable
    ///      order whose gross divides by the order size, so nothing else catches it. It is
    ///      caught here because Seaport would then reject partial fills with InexactFraction
    ///      and the listing would quietly become all-or-nothing.
    ///      At $0.900001 x 20 the two roundings differ by exactly one base unit.
    function test_reject_feeSplitRoundedOnTheTotal() public {
        _deposit(alice, 30e18);
        uint256 optionId = _rollOpen(20);

        uint256 unitPrice = 900_001;
        OrderComponents memory c = _buildOrder(optionId, 20, unitPrice);
        // Sanity: the fixture builds the correct, per-contract split.
        assertEq(c.consideration[0].startAmount, 17_100_020, "per-contract split, vault leg");
        assertEq(c.consideration[1].startAmount, 900_000, "per-contract split, Overcall leg");

        // Now round on the total instead: 18_000_020 * 5% = 900_001.
        c.consideration[0].startAmount = 17_100_019;
        c.consideration[0].endAmount = 17_100_019;
        c.consideration[1].startAmount = 900_001;
        c.consideration[1].endAmount = 900_001;

        _rejects(
            c, abi.encodeWithSelector(SeaportOrderLib.BadFeeSplit.selector, 17_100_020, 17_100_019, 900_000, 900_001)
        );
    }

    /// @dev The other shape of the same attack: keep the gross correct so the divisibility and
    ///      floor checks all pass, but move Overcall's 5% into the vault's own leg. The order
    ///      would still validate on Seaport and still pay the vault MORE than a correct one,
    ///      which is precisely why nothing downstream would complain - the split is pinned to
    ///      Overcall's published schema, not to the vault's advantage.
    ///        gross unchanged at 20_000_000, so unit price is still 2_000_000
    ///        expected (19_000_000, 1_000_000)  vs  proposed (20_000_000, 0)
    function test_reject_feeSplitThatSkimsOvercallsLeg() public {
        (, OrderComponents memory c) = _openAndBuild();
        c.consideration[0].startAmount = 20_000_000;
        c.consideration[0].endAmount = 20_000_000;
        c.consideration[1].startAmount = 0;
        c.consideration[1].endAmount = 0;

        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.BadFeeSplit.selector, 19_000_000, 20_000_000, 1_000_000, 0));
    }

    /// @dev A gross that is not a whole multiple of the contract count cannot be filled in
    ///      fractions at all.
    function test_reject_grossNotDivisibleByOrderSize() public {
        (, OrderComponents memory c) = _openAndBuild();
        c.consideration[0].startAmount += 1;
        c.consideration[0].endAmount += 1;
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.PremiumNotDivisibleByOrderSize.selector, 20_000_001, N));
    }

    /// @dev Below 20 base units the 5% fee floors to zero, and Overcall's schema rejects a
    ///      zero-amount consideration item, so the listing would never reach a buyer.
    function test_reject_unitPriceWhoseFeeRoundsToZero() public {
        _deposit(alice, 30e18);
        uint256 optionId = _rollOpen(N);
        OrderComponents memory c = _buildOrder(optionId, N, 19);
        assertEq(c.consideration[1].startAmount, 0, "5% of 19 base units floors to nothing");
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.OvercallFeeRoundsToZero.selector, 19, 20));

        // One base unit higher the fee survives (20 * 500 / 10_000 = 1), so the SHAPE gate is
        // satisfied and a different gate has to be the one that stops it. It is the economic
        // floor: 20 x 10 = 200 base units of gross against a $8.80 floor. Proving this keeps
        // the two gates from being confused for one another - the shape gate is not, and must
        // not be mistaken for, a price floor.
        OrderComponents memory atTwenty = _buildOrder(optionId, N, 20);
        assertEq(atTwenty.consideration[1].startAmount, 10, "5% of 20 base units is 1, x 10 contracts");
        assertEq(atTwenty.consideration[0].startAmount, 190, "the vault leg keeps the other 19");
        _rejects(atTwenty, abi.encodeWithSelector(Policy.PremiumBelowMinimum.selector, 200, 8_800_000));
    }

    /// @dev A premium above the strike is never a real quote, it is a fat finger or a broken
    ///      feed. 20 base units is the floor, the strike is the ceiling.
    function test_reject_unitPriceAboveTheStrike() public {
        _deposit(alice, 30e18);
        uint256 optionId = _rollOpen(N);
        uint256 strike = registry.strikePerContract(optionId);
        assertEq(strike, 231_000_000, "the in-band rung");
        OrderComponents memory c = _buildOrder(optionId, N, strike + 1);
        _rejects(c, abi.encodeWithSelector(SeaportOrderLib.UnitPriceExceedsStrike.selector, strike + 1, strike));

        // The check is strictly-greater, so the strike itself is still listable. Asserting the
        // rejection alone would pass just as well against an off-by-one `>=`, which would ban a
        // legitimate (if absurdly rich) quote.
        //   unit = 231_000_000, fee = 231_000_000 * 500 / 10_000 = 11_550_000
        //   vault leg    = (231_000_000 - 11_550_000) * 10 = 2_194_500_000
        //   Overcall leg =                11_550_000  * 10 =   115_500_000
        //   gross        =                231_000_000 * 10 = 2_310_000_000
        OrderComponents memory atStrike = _buildOrder(optionId, N, strike);
        assertEq(atStrike.consideration[0].startAmount, 2_194_500_000, "vault leg at the strike");
        assertEq(atStrike.consideration[1].startAmount, 115_500_000, "Overcall leg at the strike");
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

        // ...and one second earlier, i.e. an order that ends exactly when the book closes, is
        // legal. The check is `endTime > exerciseTimestamp`; without this half an off-by-one
        // would shave a second off every listing and nothing here would notice.
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
                         REJECTIONS: THE POLICY FLOOR
    //////////////////////////////////////////////////////////////*/

    /// @dev The economic floor is 0.40% of spot notional per week. At $220 spot that is
    ///      $0.88 a contract, so $0.80 must fail and $0.90 must pass. The order shape is
    ///      impeccable in both cases: this gate is purely about price.
    function test_reject_premiumBelowThePolicyFloor() public {
        _deposit(alice, 30e18);
        uint256 optionId = _rollOpen(N);

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
    ///      $0.80 vs $0.90 leaves a $0.10 gap either side of the real edge and would pass just
    ///      as happily against an off-by-one. THE ARITHMETIC, BY HAND:
    ///        floor(gross) = spot x contracts x minPremiumBps / 10_000
    ///                     = 220_000_000 x 10 x 40 / 10_000 = 8_800_000   ($8.80 for ten lots)
    ///        880_000 x 10 = 8_800_000  -> exactly the floor, must be ACCEPTED
    ///        879_999 x 10 = 8_799_990  -> ten base units under, must be REJECTED
    ///      (879_999 is the largest unit price whose gross still lands under the floor while
    ///      staying an exact multiple of the order size, so this is as tight as the edge gets.)
    function test_policyFloorIsInclusiveAtTheExactBoundary() public {
        _deposit(alice, 30e18);
        uint256 optionId = _rollOpen(N);

        OrderComponents memory under = _buildOrder(optionId, N, 879_999);
        _rejects(under, abi.encodeWithSelector(Policy.PremiumBelowMinimum.selector, 8_799_990, 8_800_000));

        OrderComponents memory exactlyOnTheFloor = _buildOrder(optionId, N, 880_000);
        vm.prank(keeper);
        vault.approveListing(exactlyOnTheFloor);
        assertEq(vault.listingGrossUsdg(), 8_800_000, "a premium exactly on the floor is listable");
        assertEq(vault.listingsThisCycle(), 1, "and the rejected one burned no slot");
    }

    /*//////////////////////////////////////////////////////////////
                      ONE LIVE LISTING, THREE PER CYCLE
    //////////////////////////////////////////////////////////////*/

    /// @dev F-11. Two live orders for the same inventory could both fill, so a second listing
    ///      is refused until the first is explicitly cancelled.
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
        assertTrue(seaport.cancelled(live), "cancelled on Seaport too");

        vm.prank(keeper);
        vault.approveListing(second);
        assertEq(vault.listingHash(), seaport.getOrderHash(second), "the replacement is live");
        // The replacement is priced ABOVE the first, so it is a reprice up and spends no slot.
        assertEq(vault.listingsThisCycle(), 1, "only the first listing spent a price level");
    }

    /// @dev T-07. The cap exists so a compromised or panicking keeper cannot ratchet the price
    ///      down all week: three descending price levels per cycle, cancelled or not. CHANGED
    ///      BEHAVIOUR: slots used to count every authorisation; they now count price cuts (the
    ///      first listing, then each strictly lower unit price), so this walks the price DOWN.
    function test_threePriceCutsPerCycleThenNoMore() public {
        (uint256 optionId,) = _openAndBuild();
        uint256 p = _okUnitPrice();
        OrderComponents memory a = _buildOrder(optionId, N, p + 300_000);
        OrderComponents memory b = _buildOrder(optionId, N, p + 200_000);
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
        assertEq(vault.lowestListedUnitUsdg(), p + 100_000, "the third cut is the lowest price authorised");
        assertEq(vault.listingHash(), bytes32(0), "nothing live, so this is the cap and not the live-listing guard");

        _rejects(d, abi.encodeWithSelector(AdapterSeaport.TooManyListings.selector, uint8(3), uint8(3)));
    }

    /// @dev F5(a). With the budget spent, a relist AT the lowest price or above it is still free,
    ///      any number of times, including a bigger tranche after `writeMore`. Only a fourth cut
    ///      is refused.
    function test_relistAtOrAboveTheLowestPriceIsFreeEvenWithTheBudgetSpent() public {
        (uint256 optionId,) = _openAndBuild();
        uint256 p = _okUnitPrice();
        for (uint256 i; i < 3; i++) {
            OrderComponents memory cut = _approveListing(optionId, N, p - i * 100_000);
            vm.prank(keeper);
            vault.cancelListing(cut);
        }
        assertEq(vault.listingsThisCycle(), 3, "three cuts spent the budget");

        // Same price as the lowest: free.
        OrderComponents memory same = _approveListing(optionId, N, p - 200_000);
        vm.prank(keeper);
        vault.cancelListing(same);
        // Up: free, and again, and a different size.
        OrderComponents memory up = _approveListing(optionId, N, p + 500_000);
        vm.prank(keeper);
        vault.cancelListing(up);
        _writeMore(5);
        _approveListing(optionId, N + 5, p + 500_000);
        assertEq(vault.listingsThisCycle(), 3, "no relist at or above the lowest spent a slot");
        assertEq(vault.lowestListedUnitUsdg(), p - 200_000, "and none of them moved the lowest");

        vm.prank(keeper);
        vault.invalidateAllListings();

        OrderComponents memory fourthCut = _buildOrder(optionId, N, p - 300_000);
        _rejects(fourthCut, abi.encodeWithSelector(AdapterSeaport.TooManyListings.selector, uint8(3), uint8(3)));
    }

    /// @dev Review round 2 PoC, pinned for the off-chain keeper. Three authorisations at ONE price,
    ///      each cancelled, spend one slot; a fourth at that price succeeds and the counter still
    ///      reads 1. The keeper used to take `seq` from `listingsThisCycle + 1` and to expect
    ///      TooManyListings(3,3) here (callhouse keeper/src/dryrun-extended.ts); it now keeps its
    ///      own sequence and mirrors the price-cut rule (keeper/src/policy.ts listingSlotRefused).
    function test_relistsAtOnePriceSpendOneSlot() public {
        (uint256 optionId,) = _openAndBuild();
        uint256 p = _okUnitPrice();
        for (uint256 i; i < 3; i++) {
            OrderComponents memory c = _approveListing(optionId, N, p);
            vm.prank(guardian);
            vault.cancelListing(c);
        }
        assertEq(vault.listingsThisCycle(), 1, "three authorisations at one price spend ONE slot");
        _approveListing(optionId, N, p);
        assertEq(vault.listingsThisCycle(), 1, "and a fourth at that price is free");
        assertEq(vault.lowestListedUnitUsdg(), p, "the lowest price is the one price listed");
    }

    /// @dev The budget is per cycle. A new write reopens it, or the vault would be unlistable
    ///      forever after three relists in one busy week.
    function test_listingBudgetResetsOnTheNextRollOpen() public {
        _deposit(alice, 30e18);
        uint256 optionId = _rollOpen(N);
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

        exerciseTs = uint40(block.timestamp + 6 days);
        expiryTs = uint40(block.timestamp + 7 days);
        _installCycle();
        feed.setAnswer(SPOT_FEED); // refresh updatedAt; a week has passed

        _rollOpen(N);
        assertEq(vault.listingsThisCycle(), 0, "fresh budget for the new cycle");
        assertEq(vault.lowestListedUnitUsdg(), 0, "and no lowest price carried over from last week");
    }

    /*//////////////////////////////////////////////////////////////
                    F5(b): PERMISSIONLESS STALE-LISTING KILL
    //////////////////////////////////////////////////////////////*/

    /// @dev List the N contracts at `unitPrice` and hand back the stranger who will try to kill it.
    function _listForStaleTest(uint256 unitPrice) internal returns (address stranger) {
        _deposit(alice, 30e18);
        uint256 optionId = _rollOpen(N);
        _approveListing(optionId, N, unitPrice);
        stranger = makeAddr("stranger");
    }

    function _assertKilledBy(address who) internal {
        uint256 counterBefore = seaport.getCounter(address(vault));
        vm.prank(who);
        vault.invalidateStaleListing();
        assertEq(vault.listingHash(), bytes32(0), "the stale listing is dead");
        assertEq(seaport.getCounter(address(vault)), counterBefore + 1, "by a Seaport counter bump");
    }

    /// @dev A rally to $225 lifts the band floor to 231.75, above the 231 strike written at $220.
    function test_invalidateStaleListing_afterARallyPastTheBandFloor() public {
        address stranger = _listForStaleTest(_okUnitPrice());
        feed.setAnswer(225_00000000);
        _assertKilledBy(stranger);
    }

    /// @dev Listed exactly on the $220 floor (8_800_000 for ten). At $221 the floor is 8_840_000
    ///      and the band floor 227.63 still admits the 231 strike, so only the premium is stale.
    function test_invalidateStaleListing_whenTheFloorRisesAboveTheListingGross() public {
        address stranger = _listForStaleTest(880_000);
        feed.setAnswer(221_00000000);
        _assertKilledBy(stranger);
    }

    /// @dev A paused Stock Token oracle means a fresh approval would revert, so the listing counts
    ///      as stale even though its price is still fine.
    function test_invalidateStaleListing_whileTheOracleIsPaused() public {
        address stranger = _listForStaleTest(_okUnitPrice());
        nvda.setOraclePaused(true);
        _assertKilledBy(stranger);
    }

    /// @dev Nobody may kill a listing the policy would still authorise, which is what keeps this
    ///      from being a griefing lever. $224 moves the floor to 8_960_000 and the band floor to
    ///      230.72: a $2.00 listing of a 231 strike is still valid. A dead feed proves nothing.
    function test_invalidateStaleListing_revertsWhileStillValidOrWithoutAPrice() public {
        address stranger = _listForStaleTest(_okUnitPrice());
        feed.setAnswer(224_00000000);

        vm.prank(stranger);
        vm.expectRevert(Vault.ListingStillValid.selector);
        vault.invalidateStaleListing();

        vm.warp(block.timestamp + MAX_PRICE_AGE + 1);
        vm.prank(stranger);
        vm.expectRevert();
        vault.invalidateStaleListing();
        assertTrue(vault.listingHash() != bytes32(0), "the listing survives both");
    }

    /// @dev Regression (review round 1): approveListing used to check only the premium floor, so
    ///      after a rally to $225 (band floor 231.75 > the 231 strike) it still accepted a $2.00
    ///      listing that any stranger could kill in the same block, round after round, keeping the
    ///      written inventory unsold but assignable. The keeper now cannot list it at all.
    function test_approveListing_refusesAStrikeBelowTheLiveBandFloor() public {
        _deposit(alice, 30e18);
        uint256 optionId = _rollOpen(N);
        feed.setAnswer(225_00000000);
        _rejects(
            _buildOrder(optionId, N, _okUnitPrice()),
            abi.encodeWithSelector(Policy.StrikeBelowBand.selector, uint256(231_000_000), uint256(231_750_000))
        );
        assertEq(vault.listingHash(), bytes32(0), "nothing listed for a griefer to kill");
        assertEq(vault.listingsThisCycle(), 0);
    }

    /// @dev The two paths read one set of floors, so at any spot where approveListing accepts a
    ///      listing, invalidateStaleListing refuses to kill it. $224.27 is the last cent at which
    ///      the band floor (230.9981) still admits the 231 strike.
    function test_invalidateStaleListing_cannotKillWhatApproveListingJustAccepted() public {
        _deposit(alice, 30e18);
        uint256 optionId = _rollOpen(N);
        address stranger = makeAddr("stranger");
        int256[3] memory spots = [int256(220_00000000), 223_00000000, 224_27000000];
        for (uint256 i; i < spots.length; i++) {
            feed.setAnswer(spots[i]);
            OrderComponents memory c = _approveListing(optionId, N, _okUnitPrice());
            vm.prank(stranger);
            vm.expectRevert(Vault.ListingStillValid.selector);
            vault.invalidateStaleListing();
            assertTrue(vault.listingHash() != bytes32(0), "the accepted listing survives");
            vm.prank(keeper);
            vault.cancelListing(c); // the keeper's own reprice, to relist at the next spot
        }
        assertEq(vault.listingsThisCycle(), 1, "same-price relists stay free");
    }

    function test_invalidateStaleListing_revertsWithNoLiveListing() public {
        _deposit(alice, 30e18);
        _rollOpen(N);
        feed.setAnswer(225_00000000);
        vm.expectRevert(AdapterSeaport.NoLiveListing.selector);
        vault.invalidateStaleListing();
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
    ///      re-keys every order this vault ever signed, so the old one can never come back.
    function test_invalidateAllListings_bumpsTheCounterAndStrandsTheOldOrder() public {
        (, OrderComponents memory c) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(c);
        bytes32 live = vault.listingHash();
        assertEq(seaport.getCounter(address(vault)), 0, "counter starts at zero");

        vm.expectEmit(true, true, true, true, address(vault));
        emit AllListingsInvalidated(1);
        vm.prank(guardian);
        vault.invalidateAllListings();

        assertEq(seaport.getCounter(address(vault)), 1, "counter bumped");
        assertEq(vault.listingHash(), bytes32(0), "live hash cleared");
        assertEq(vault.listingGrossUsdg(), 0, "gross cleared");
        assertEq(vault.listingAmount(), 0, "amount cleared");
        assertEq(_sig(live), bytes32(EIP1271_INVALID), "the vault no longer vouches for the old hash");

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
                                EIP-1271
    //////////////////////////////////////////////////////////////*/

    /// @dev Seaport may ask the offerer to sign either the raw order hash or its EIP-712
    ///      digest, depending on the fill path. Answering only one of the two would make the
    ///      listing unfillable through Overcall's UI, which is an unfilled week.
    function test_eip1271_answersForTheLiveHashAndItsEip712Digest() public {
        (, OrderComponents memory c) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(c);
        bytes32 live = vault.listingHash();

        (, bytes32 domainSeparator,) = seaport.information();
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domainSeparator, live));

        assertEq(_sig(live), bytes32(EIP1271_MAGIC), "raw order hash is signed");
        assertEq(_sig(digest), bytes32(EIP1271_MAGIC), "EIP-712 digest form is signed");
        assertEq(_sig(keccak256("some other order")), bytes32(EIP1271_INVALID), "unrelated hash is refused");
    }

    function testFuzz_eip1271_refusesEveryUnrelatedHash(bytes32 h) public {
        (, OrderComponents memory c) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(c);
        bytes32 live = vault.listingHash();
        (, bytes32 domainSeparator,) = seaport.information();
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domainSeparator, live));

        vm.assume(h != live && h != digest);
        assertEq(_sig(h), bytes32(EIP1271_INVALID), "authorisation is one hash, not a key");
    }

    /// @dev With nothing live the vault must be a dead signer. Answering for anything here is
    ///      how a stale or forged order gets filled against the inventory.
    ///
    ///      THIS DELIBERATELY DOES NOT STOP AT THE VIRGIN VAULT. On a vault that never listed,
    ///      `listingHash` is zero and the early return makes the assertion trivially true for
    ///      every input; the fuzzer proves nothing. The state that matters is AFTER a real
    ///      listing has been cancelled, because then the stale hash and its EIP-712 digest are
    ///      live values sitting inside the fuzzer's domain, and they are exactly the two hashes
    ///      a stale-order replay would present.
    function testFuzz_eip1271_refusesEverythingWithNoLiveListing(bytes32 h) public {
        assertEq(_sig(h), bytes32(EIP1271_INVALID), "a vault that never listed signs nothing");

        (, OrderComponents memory c) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(c);
        bytes32 live = vault.listingHash();
        (, bytes32 domainSeparator,) = seaport.information();
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domainSeparator, live));
        // Guard against the assertion below holding for an uninteresting reason.
        assertEq(_sig(live), bytes32(EIP1271_MAGIC), "signed while genuinely live");
        assertEq(_sig(digest), bytes32(EIP1271_MAGIC), "digest form signed while genuinely live");

        vm.prank(keeper);
        vault.cancelListing(c);

        assertEq(_sig(h), bytes32(EIP1271_INVALID), "no live listing means no signature, ever");
        assertEq(_sig(live), bytes32(EIP1271_INVALID), "not even for the hash it signed a moment ago");
        assertEq(_sig(digest), bytes32(EIP1271_INVALID), "nor its EIP-712 digest");
    }

    function test_eip1271_goesDeadAfterCancel() public {
        (, OrderComponents memory c) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(c);
        bytes32 live = vault.listingHash();
        (, bytes32 domainSeparator,) = seaport.information();
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domainSeparator, live));
        assertEq(_sig(live), bytes32(EIP1271_MAGIC), "live while listed");

        vm.prank(keeper);
        vault.cancelListing(c);

        assertEq(_sig(live), bytes32(EIP1271_INVALID), "refused after cancel");
        assertEq(_sig(digest), bytes32(EIP1271_INVALID), "digest form refused after cancel");
        assertEq(_sig(bytes32(0)), bytes32(EIP1271_INVALID), "the empty hash is never signed");
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
        // Idle: nothing has been written yet, so there is nothing to list.
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
    ///      unvalidated and unsigned. MockSeaport stores `validated` under the hash the caller
    ///      supplies and so does not model that re-keying, which is why this asserts the
    ///      on-chain facts the vault actually controls: the counter moved, the recorded hash
    ///      is gone, and EIP-1271 refuses the old hash.
    function test_lockBook_killsAStillLiveListing() public {
        (, OrderComponents memory c) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(c);
        bytes32 live = vault.listingHash();

        _warpToExercise();
        vault.lockBook(); // permissionless

        assertEq(_phase(), 2, "Exercisable");
        assertEq(vault.listingHash(), bytes32(0), "no listing survives the book close");
        assertEq(seaport.getCounter(address(vault)), 1, "counter bumped, every outstanding order re-keyed");
        assertEq(_sig(live), bytes32(EIP1271_INVALID), "the vault will not sign the old order again");

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
    ///      a live order on the book. `rollClose` has to kill it on the way past: the option
    ///      tokens are about to be redeemed back into collateral, and an order still fillable
    ///      against inventory the vault no longer has is the naked-call hazard at its worst.
    function test_rollClose_killsAListingLeftLiveThroughExpiry() public {
        (, OrderComponents memory c) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(c);
        bytes32 live = vault.listingHash();

        _warpToExpiry();
        assertEq(_phase(), 1, "still Listed: lockBook was never called");
        _rollClose();

        assertEq(_phase(), 0, "Idle");
        assertEq(vault.listingHash(), bytes32(0), "no listing survives the close");
        assertEq(seaport.getCounter(address(vault)), 1, "counter bumped, every outstanding order re-keyed");
        assertEq(_sig(live), bytes32(EIP1271_INVALID), "the vault will not sign the old order again");
    }

    /*//////////////////////////////////////////////////////////////
                        THE ORACLE GATE ON A LISTING
    //////////////////////////////////////////////////////////////*/

    /// @dev `approveListing` is the second place in the contract that reads spot, because the
    ///      economic floor it enforces is a percentage OF spot. A broken feed therefore has to
    ///      stop a listing and not merely a write: with a stale or absent price the floor is
    ///      computed against a number nobody stands behind, and the keeper could authorise a
    ///      sale of the whole inventory at a premium derived from last week's market.
    ///      The shape of the order is impeccable in both of these; only the price source is bad.
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
    ///      not sell anything either, and - just as important - the guardian must still be able
    ///      to PULL what is already on the book. An oracle halt that also froze the unwind path
    ///      would leave a live order sitting on Seaport with nobody able to retract it.
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

        nvda.setOraclePaused(true);
        vm.prank(guardian);
        vault.invalidateAllListings();
        assertEq(seaport.getCounter(address(vault)), 1, "nor does invalidateAllListings");
    }

    /*//////////////////////////////////////////////////////////////
                          INVENTORY EXHAUSTED
    //////////////////////////////////////////////////////////////*/

    /// @dev Once the whole order has filled the vault holds no option tokens at all, so there
    ///      is nothing left to list. The guard has to hold at zero as well as at a shortfall:
    ///      a listing authorised here would be naked from the moment it was filled.
    function test_reject_anyListingOnceInventoryIsFullySold() public {
        (uint256 optionId, OrderComponents memory c) = _openAndBuild();
        vm.prank(keeper);
        vault.approveListing(c);
        _fill(c, N);
        assertEq(clear.balanceOf(address(vault), optionId), 0, "the vault sold every contract");

        // The order is spent but still recorded, so it has to be cancelled before anything
        // else can be proposed at all.
        vm.prank(keeper);
        vault.cancelListing(c);

        OrderComponents memory oneMore = _buildOrder(optionId, 1, _okUnitPrice() + 100_000);
        _rejects(oneMore, abi.encodeWithSelector(SeaportOrderLib.OfferExceedsInventory.selector, 1, 0));
        assertEq(vault.listingsThisCycle(), 1, "the refused proposal burned no slot");
    }
}
