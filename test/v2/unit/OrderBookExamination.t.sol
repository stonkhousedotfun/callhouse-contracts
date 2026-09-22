// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OrderBookBaseTest, BookActor} from "./OrderBookBase.t.sol";
import {MockFeeDiscount} from "../../../src/v2/mocks/MockFeeDiscount.sol";
import {OrderBook} from "../../../src/v2/OrderBook.sol";
import {IFeeDiscount} from "../../../src/v2/interfaces/IFeeDiscount.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";

/// @dev A discount module that answers a FULL dirty word: every bit set, far above uint16 and above
///      MAX_DISCOUNT_BPS. `MockFeeDiscount` caps its own answer at uint16.max before returning, so it cannot probe what
///      the book does with a word the ABI decoder would refuse as a uint16 -- the book's raw staticcall copies the
///      first word as a uint256 and must clamp it, never overflow on it.
contract FullWordDiscount {
    function discountBps(address) external pure returns (uint256) {
        return type(uint256).max;
    }
}

/// @notice T-OP-145: the proofs the C8-03 acceptance asked for that the nine OrderBook suites do not carry at
///         `6b7467e0`. Each test names the criterion it closes and the exact line of `OrderBook.sol` it holds, and
///         each was proven by breaking: a one-line mutation of the working-tree `OrderBook.sol` turns it red by name,
///         restored, green again (the mutations and outputs are in docs/examinations/T-63-ORDERBOOK.md §4 and §7).
/// @dev Fixture defaults: 500 / 0 / 100_000 / 1000 / 5000 (OrderBookBase.t.sol:187-191). At 2.00 and 50 units the
///      premium is 1.00 USDG, the flat taker fee 0.10, the primary seller fee 0.05 and a resale seller fee 0.
contract OrderBookExaminationTest is OrderBookBaseTest {
    MockFeeDiscount internal discount;

    function setUp() public override {
        super.setUp();
        discount = new MockFeeDiscount(1_000); // an honest 10 % module
        discount.setBook(OrderBook(address(book)));
        vm.prank(admin);
        book.setDiscountModule(IFeeDiscount(address(discount)));
    }

    function _feesWithPremium(uint16 premiumFeeBps) internal pure returns (V2Types.FeeParams memory f) {
        f = V2Types.FeeParams({
            premiumFeeBps: premiumFeeBps,
            resaleFeeBps: RESALE_FEE_BPS,
            takerFeeFlat: TAKER_FEE_FLAT,
            takerFeeCapBps: TAKER_FEE_CAP_BPS,
            makerRebateBps: MAKER_REBATE_BPS
        });
    }

    /*//////////////////////////////////////////////////////////////
          CRITERION 8 -- THE SEAM IS READ ONCE PER TAKE (OrderBook.sol:438, :496)
    //////////////////////////////////////////////////////////////*/

    /// The module is read EXACTLY once per take, even when the take runs two rounds: the best bid's maker rejects the
    /// tokens, its delivery fails, the book re-plans from the next bid, and the second round reuses the figure the
    /// first read carried on `Exec.discountBps` (OrderBook.sol:437-438). `vm.expectCall(..., 1)` is exact: a second
    /// read anywhere in the take -- in `_plan`, `_execute` or the re-plan loop -- fails this test by count.
    function test_exam_discountModuleIsReadExactlyOncePerTake_evenAcrossTwoRounds() public {
        BookActor picky = _newActor();
        uint256 pickyBid = _place(address(picky), callId, BID, P3_00, 20); // best bid, 0.60 USDG escrowed
        picky.setAcceptTokens(false);
        uint256 bobBid = _place(bob, callId, BID, P2_50, 20); // 0.50 USDG escrowed
        _mintLongs(alice, callId, 20);

        V2Types.TakeParams memory p = _sell(callId, _ids(pickyBid, bobBid), 20, false, alice);
        p.minUnits = 20; // so the re-planned round is the only way this take can succeed
        vm.expectCall(address(discount), abi.encodeCall(IFeeDiscount.discountBps, (alice)), 1);
        (uint64 filled, uint256 premium, uint256 takerFee) = _take(alice, p);
        assertEq(filled, 20, "the re-planned round filled bob's bid: two rounds ran");
        assertEq(premium, 500_000, "priced at bob's bid");
        // min(100_000, 500_000 * 1000 bps) = 50_000, less the 10 % the one read carried into both rounds.
        assertEq(takerFee, 45_000, "one discounted fee, carried across the re-plan");
        assertEq(_order(pickyBid).filled, 0, "the refused bid is untouched");
    }

    /// quoteTake makes the same single read a take would (OrderBook.sol:496), so the quoted fee IS the fee a take
    /// at the same block pays under the module. Two entry points, one read each: the exact count over the whole test
    /// is 2, and a second read inside either of them fails it by count.
    function test_exam_quoteTakeReadsTheModuleExactlyOnce_andMatchesTheTake() public {
        uint256 ask = _place(carol, callId, WRITE, P2_00, 50);
        V2Types.TakeParams memory p = _buy(callId, _ids(ask), 50, alice);

        vm.expectCall(address(discount), abi.encodeCall(IFeeDiscount.discountBps, (alice)), 2);
        vm.prank(alice);
        (uint64 qUnits,, uint256 qFee,) = book.quoteTake(p);
        assertEq(qUnits, 50, "quoted");
        assertEq(qFee, 90_000, "100_000 less 10 %");

        (,, uint256 takerFee) = _take(alice, p);
        assertEq(takerFee, qFee, "the take pays exactly the quote");
    }

    /*//////////////////////////////////////////////////////////////
       CRITERION 8 -- A MODULE CAN NEVER TAKE MORE THAN MAX_DISCOUNT_BPS (OrderBook.sol:861)
    //////////////////////////////////////////////////////////////*/

    /// A module answering a full dirty word (every bit set) is clamped to MAX_DISCOUNT_BPS: the book copies the raw
    /// first word as a uint256 (OrderBook.sol:857-859) and clamps before any arithmetic touches it, so an answer no
    /// ABI decoder would accept as a uint16 neither reverts the take nor takes more than half the fee.
    function test_exam_moduleAnsweringAFullWord_isClampedToHalf_notReverted() public {
        FullWordDiscount hostile = new FullWordDiscount();
        vm.prank(admin);
        book.setDiscountModule(IFeeDiscount(address(hostile)));
        uint256 ask = _place(carol, callId, WRITE, P2_00, 50);

        vm.prank(alice);
        (,, uint256 qFee,) = book.quoteTake(_buy(callId, _ids(ask), 50, alice));
        (uint64 filled,, uint256 takerFee) = _take(alice, _buy(callId, _ids(ask), 50, alice));
        assertEq(filled, 50, "the take proceeds");
        assertEq(takerFee, 50_000, "clamped to MAX_DISCOUNT_BPS: half of 100_000, not overflowed and not zero");
        assertEq(qFee, takerFee, "the quote clamps the same way");
        assertEq(uint256(V2Constants.MAX_DISCOUNT_BPS), 5_000, "the clamp the test relies on");
    }

    /*//////////////////////////////////////////////////////////////
       CRITERION 5 -- WHAT THE CAP COUNTS (OrderBook.sol:458): TAKER-SIDE FEES ONLY
    //////////////////////////////////////////////////////////////*/

    /// Buying an AskWrite: the fill carries a 5 % seller fee, but it is the MAKER's (taken out of the maker's
    /// proceeds, OrderBook.sol:1037), so the buyer's cap sees the taker fee alone. Exactly the taker fee passes even
    /// though 0.05 of seller fee changed hands on the same fill; the accounting below is the worked example of
    /// docs/examinations/T-63-ORDERBOOK.md §2. No module here: the base path is the one the spec words.
    function test_exam_buyersCapExcludesTheMakersSellerFee_workedExample() public {
        vm.prank(admin);
        book.setDiscountModule(IFeeDiscount(address(0)));
        uint256 ask = _place(carol, callId, WRITE, P2_00, 50); // premium 1.00; seller fee 0.05 (carol's)
        uint256 aliceBefore = usdg.balanceOf(alice);
        uint256 carolBefore = usdg.balanceOf(carol);
        uint256 treasuryBefore = usdg.balanceOf(treasury);

        V2Types.TakeParams memory p = _buy(callId, _ids(ask), 50, alice);
        p.maxTotalFee = 100_000; // the taker fee and nothing else
        (uint64 filled, uint256 premium, uint256 takerFee) = _take(alice, p);
        assertEq(filled, 50, "fills at a cap equal to the taker fee alone");
        assertEq(premium, 1_000_000, "premium");
        assertEq(takerFee, 100_000, "taker fee");
        // alice: premium + taker fee. carol: premium - her 5 % seller fee + her rebate (half the taker fee).
        // treasury: seller fee + taker fee - rebate. Sum of the three deltas is zero.
        assertEq(aliceBefore - usdg.balanceOf(alice), 1_100_000, "buyer pays premium + taker fee, never the seller fee");
        assertEq(usdg.balanceOf(carol) - carolBefore, 1_000_000 - 50_000 + 50_000, "maker: 1.00 - 0.05 + 0.05 rebate");
        assertEq(usdg.balanceOf(treasury) - treasuryBefore, 50_000 + 100_000 - 50_000, "fees less the rebate");

        // Positive control inside the same test: one unit below the taker fee reverts with the TAKER fee as the total.
        uint256 ask2 = _place(carol, callId, WRITE, P2_00, 50);
        p = _buy(callId, _ids(ask2), 50, alice);
        p.maxTotalFee = 99_999;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.FeeAboveMax.selector, 100_000, 99_999));
        book.take(p);
    }

    /*//////////////////////////////////////////////////////////////
       CRITERION 10 -- THE 48 h WINDOW AND THE CAP PROTECT A SELLING TAKER TOO
    //////////////////////////////////////////////////////////////*/

    /// The in-flight-taker case the existing suite proves for a BUYER (OrderBookFeeCap.t.sol:305) proven for a
    /// SELLER, where the scheduled change is to the PREMIUM fee -- the fee a selling writeToSell taker pays as a
    /// seller and the one the cap includes (OrderBook.sol:458). Quoted at 0.05 + 0.10 with the cap set to the quote,
    /// the take executes at the old fees before effectiveAt; once the doubled premium fee is live the SAME take reverts
    /// FeeAboveMax(200_000, 150_000) instead of paying 0.10 more, and fills once the taker re-quotes and raises the cap.
    /// A cap that counted only the taker fee would let the scheduled change take the extra 0.05 silently.
    function test_exam_feeWindowAndCap_protectTheInFlightSELLINGTaker_fromAPremiumFeeRise() public {
        vm.prank(admin);
        book.setDiscountModule(IFeeDiscount(address(0)));
        uint256 bid1 = _place(bob, callId, BID, P2_00, 50);
        uint256 bid2 = _place(bob, callId, BID, P2_00, 50);

        V2Types.TakeParams memory p = _sell(callId, _ids(bid1), 50, true, carol);
        vm.prank(carol);
        (, uint256 qPremium, uint256 qFee, uint256 qSellerFees) = book.quoteTake(p);
        assertEq(qPremium, 1_000_000, "premium");
        assertEq(qFee, 100_000, "taker fee");
        assertEq(qSellerFees, 50_000, "5 % primary seller fee, the taker's own when writing to sell");
        p.maxTotalFee = uint128(qFee + qSellerFees); // 150_000: exactly the quote

        vm.prank(admin);
        book.setFeeParams(_feesWithPremium(1_000)); // live in 48 h: the premium fee doubles to 10 %, the ceiling

        uint256 before = usdg.balanceOf(carol);
        (uint64 filled,, uint256 takerFee) = _take(carol, p);
        assertEq(filled, 50, "before effectiveAt the old fees hold");
        assertEq(takerFee, 100_000, "taker fee unchanged");
        assertEq(usdg.balanceOf(carol) - before, 850_000, "1.00 - 0.05 - 0.10: exactly the quote");

        vm.warp(block.timestamp + V2Constants.FEE_CHANGE_DELAY); // the 10 % premium fee is live
        p.orderIds = _ids(bid2);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.FeeAboveMax.selector, 200_000, 150_000));
        book.take(p);
        assertEq(_order(bid2).filled, 0, "the in-flight seller was not charged the surprise premium fee");

        p.maxTotalFee = 200_000;
        before = usdg.balanceOf(carol);
        (filled,, takerFee) = _take(carol, p);
        assertEq(filled, 50, "fills once the seller re-quotes");
        assertEq(takerFee, 100_000, "the taker fee did not move");
        assertEq(usdg.balanceOf(carol) - before, 800_000, "1.00 - 0.10 seller fee - 0.10 taker fee at the new rate");
    }

    /// The other half of criterion 4, at the raised rate: a true RESALE by a selling taker is still charged 0 after
    /// the premium fee doubles -- the change is to the first-sale fee only (OrderBook.sol:975, `primary ? premium :
    /// resale`), so an inventory sale's cap is the taker fee alone before and after.
    function test_exam_resaleStaysFree_afterThePremiumFeeRises() public {
        vm.prank(admin);
        book.setDiscountModule(IFeeDiscount(address(0)));
        vm.prank(admin);
        book.setFeeParams(_feesWithPremium(1_000));
        vm.warp(block.timestamp + V2Constants.FEE_CHANGE_DELAY);
        _mintLongs(carol, callId, 50);
        uint256 bid = _place(bob, callId, BID, P2_00, 50);

        V2Types.TakeParams memory p = _sell(callId, _ids(bid), 50, false, carol);
        vm.prank(carol);
        (,,, uint256 qSellerFees) = book.quoteTake(p);
        assertEq(qSellerFees, 0, "a resale quotes no seller fee at the raised premium rate");
        p.maxTotalFee = 100_000; // the taker fee alone
        uint256 before = usdg.balanceOf(carol);
        (uint64 filled,, uint256 takerFee) = _take(carol, p);
        assertEq(filled, 50, "fills at a cap of the taker fee alone");
        assertEq(takerFee, 100_000, "taker fee");
        assertEq(usdg.balanceOf(carol) - before, 900_000, "1.00 - 0.10 and NO seller fee on a resale");
    }
}
