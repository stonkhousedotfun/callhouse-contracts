// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {OrderBookBaseTest} from "./OrderBookBase.t.sol";
import {MockFeeDiscount} from "../../../src/v2/mocks/MockFeeDiscount.sol";
import {OrderBook} from "../../../src/v2/OrderBook.sol";
import {IFeeDiscount} from "../../../src/v2/interfaces/IFeeDiscount.sol";
import {IOrderBook} from "../../../src/v2/interfaces/IOrderBook.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";

/// @notice The OrderBook's INTERFACE_VERSION 8 revenue surface (03-INTERFACES §2.2): the taker-side hard cap
///         `TakeParams.maxTotalFee` (tenth and last member: `type(uint128).max` is no limit, 0 is zero fees only),
///         `quoteTake`'s fourth return `sellerFees`, the first-sale-only premium fee (a true resale is charged 0),
///         the discount seam (read once per take under DISCOUNT_READ_GAS, clamped to MAX_DISCOUNT_BPS, a hostile
///         module can neither break nor stall a take), and the 48 h fee window working together with the cap so a
///         scheduled change cannot surprise an in-flight taker.
/// @dev Expected amounts are worked by hand in the comments. Fees are the fixture defaults (500 / 0 / 100_000 /
///      1000 / 5000) unless a test schedules new ones: at 2.00 and 50 units the premium is 1.00 USDG, the flat taker
///      fee 0.10, the primary seller fee 0.05 and a resale seller fee 0.
contract OrderBookFeeCapTest is OrderBookBaseTest {
    MockFeeDiscount internal discount;

    function setUp() public override {
        super.setUp();
        discount = new MockFeeDiscount(0);
        discount.setBook(OrderBook(address(book)));
    }

    /// @dev Schedules `f` as the admin (FEE_MANAGER at delay 0 in the fixture) and warps past the 48 h window.
    function _scheduleInEffect(V2Types.FeeParams memory f) internal {
        vm.prank(admin);
        book.setFeeParams(f);
        vm.warp(block.timestamp + V2Constants.FEE_CHANGE_DELAY);
    }

    function _pricierFees() internal pure returns (V2Types.FeeParams memory) {
        // taker fee min(200_000, 2.00 USDG x 1000 bps = 200_000) = 200_000: double the fixture default.
        return V2Types.FeeParams({
            premiumFeeBps: 500, resaleFeeBps: 0, takerFeeFlat: 200_000, takerFeeCapBps: 1000, makerRebateBps: 5000
        });
    }

    function _zeroFees() internal pure returns (V2Types.FeeParams memory) {
        return
            V2Types.FeeParams({
                premiumFeeBps: 0, resaleFeeBps: 0, takerFeeFlat: 0, takerFeeCapBps: 0, makerRebateBps: 0
            });
    }

    /*//////////////////////////////////////////////////////////////
                       THE HARD CAP (TakeParams.maxTotalFee)
    //////////////////////////////////////////////////////////////*/

    /// Buying pays the taker fee only: exactly the cap passes, one base unit below it reverts FeeAboveMax, and the
    /// revert lands before anything moves (the order is still resting, untouched).
    function test_take_buying_feeAtCapPasses_oneBelowReverts() public {
        uint256 ask = _place(carol, callId, WRITE, P2_00, 50); // 1.00 USDG premium, taker fee 100_000

        V2Types.TakeParams memory p = _buy(callId, _ids(ask), 50, alice);
        p.maxTotalFee = 100_000;
        (uint64 filled,, uint256 takerFee) = _take(alice, p);
        assertEq(filled, 50, "filled at exactly the cap");
        assertEq(takerFee, 100_000, "the flat fee");

        uint256 ask2 = _place(carol, callId, WRITE, P2_00, 50);
        p = _buy(callId, _ids(ask2), 50, alice);
        p.maxTotalFee = 99_999;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.FeeAboveMax.selector, 100_000, 99_999));
        book.take(p);
        assertEq(_order(ask2).filled, 0, "nothing filled behind the revert");
        assertEq(usdg.balanceOf(address(book)), 0, "no USDG moved");
    }

    /// Selling with writeToSell is a PRIMARY sale: the cap sees the taker fee plus the 5 % seller fee.
    function test_take_sellingWriteToSell_capIncludesTheSellerFees() public {
        uint256 bid = _place(bob, callId, BID, P2_00, 50);
        uint256 before = usdg.balanceOf(carol);

        // Premium 1.00; taker fee 100_000; primary seller fee 50_000; total 150_000.
        V2Types.TakeParams memory p = _sell(callId, _ids(bid), 50, true, carol);
        p.maxTotalFee = 150_000;
        (uint64 filled, uint256 premium, uint256 takerFee) = _take(carol, p);
        assertEq(filled, 50, "filled at exactly the combined cap");
        assertEq(premium, 1_000_000, "premium");
        assertEq(takerFee, 100_000, "taker fee");
        // T-498. TWO assertions, and they pin DIFFERENT things. Do not delete one for tidiness.
        // PRIMARY, the movement: the fill pays the 1.00 premium less the 0.05 seller fee and the 0.10 taker fee. A
        // delta says nothing about where the wallet started, so it survives the next change to onboarding.
        assertEq(usdg.balanceOf(carol) - before, 850_000, "carol: 1.00 - 0.05 - 0.10");
        // COMPLETENESS, the endpoint: only an absolute assertion says NOTHING OTHER THAN THE FILL moved carol's
        // wallet - a delta of +850_000 still passes if some unrelated debit and credit cancel out. The wallet does not
        // start at ACTOR_USDG: _onboard deposits LEDGER_USDG into the Clearinghouse ledger before any suite here runs,
        // which is what made this case stale while its delta-asserting sibling below stayed immune. Same form as
        // OrderBookTake.t.sol. THIS is the line that goes red when onboarding changes again - UPDATE it, do not
        // delete it; deleting it is what silently drops the endpoint check.
        assertEq(
            usdg.balanceOf(carol), ACTOR_USDG - LEDGER_USDG + 850_000, "carol: nothing but the fill moved the wallet"
        );

        uint256 bid2 = _place(bob, callId, BID, P2_00, 50);
        p = _sell(callId, _ids(bid2), 50, true, carol);
        p.maxTotalFee = 149_999;
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.FeeAboveMax.selector, 150_000, 149_999));
        book.take(p);
        assertEq(_order(bid2).filled, 0, "nothing filled behind the revert");
    }

    /// THE ECONOMIC INVARIANT: a true resale is charged 0. Selling 50 units from inventory pays only the taker fee,
    /// while the same sale minted on the fill (writeToSell, a primary sale) pays the 5 % premium fee.
    function test_take_resaleIsNotCharged_primaryIs() public {
        _mintLongs(carol, callId, 50);
        uint256 bid = _place(bob, callId, BID, P2_00, 50);
        uint256 before = usdg.balanceOf(carol);

        vm.recordLogs();
        (uint64 filled, uint256 premium, uint256 takerFee) = _take(carol, _sell(callId, _ids(bid), 50, false, carol));
        Filled memory f = _decodeFilled(_filledLogs(vm.getRecordedLogs())[0]);
        assertEq(filled, 50, "filled");
        assertEq(premium, 1_000_000, "premium");
        assertEq(takerFee, 100_000, "taker fee");
        assertEq(f.sellerFee, 0, "A TRUE RESALE IS NOT CHARGED");
        assertFalse(f.primary, "not a primary fill");
        assertEq(usdg.balanceOf(carol) - before, 900_000, "carol: 1.00 - 0.10, no seller fee");

        // The positive control: the same units sold write-to-fill pay the 5 % premium fee.
        uint256 bid2 = _place(bob, callId, BID, P2_00, 50);
        vm.recordLogs();
        _take(carol, _sell(callId, _ids(bid2), 50, true, carol));
        Filled memory f2 = _decodeFilled(_filledLogs(vm.getRecordedLogs())[0]);
        assertEq(f2.sellerFee, 50_000, "the primary sale pays 5 %");
        assertTrue(f2.primary, "a primary fill");
    }

    /// type(uint128).max is no limit at all: a fee twice the fixture default goes through it.
    function test_take_maxUint128Cap_meansNoLimit() public {
        uint256 ask = _place(carol, callId, WRITE, P2_00, 100); // 2.00 USDG premium
        _scheduleInEffect(_pricierFees());
        V2Types.TakeParams memory p = _buy(callId, _ids(ask), 100, alice); // the helpers default to uint128.max
        (uint64 filled,, uint256 takerFee) = _take(alice, p);
        assertEq(filled, 100, "filled");
        assertEq(takerFee, 200_000, "the doubled fee passes the unlimited cap");
    }

    /// 0 means zero fees only: the default 0.10 USDG fee reverts behind it, and a genuinely zero-fee take passes.
    function test_take_zeroCap_requiresZeroFees() public {
        uint256 ask = _place(carol, callId, WRITE, P2_00, 50);
        V2Types.TakeParams memory p = _buy(callId, _ids(ask), 50, alice);
        p.maxTotalFee = 0;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.FeeAboveMax.selector, 100_000, 0));
        book.take(p);

        _scheduleInEffect(_zeroFees());
        (uint64 filled,, uint256 takerFee) = _take(alice, p);
        assertEq(filled, 50, "a zero-fee take fits the zero cap");
        assertEq(takerFee, 0, "no fee");
        assertEq(usdg.balanceOf(treasury), 0, "the recipient got nothing");
    }

    /*//////////////////////////////////////////////////////////////
                                 quoteTake
    //////////////////////////////////////////////////////////////*/

    /// quoteTake equals take on all four fields, and a destructure that skips the fourth reads the same first three.
    function test_quoteTake_matchesTake_onAllFourFields() public {
        _mintLongs(bob, callId, 50);
        uint256 ask = _place(carol, callId, WRITE, P2_00, 50);
        uint256 resale = _place(bob, callId, RESALE, P2_00, 50);

        V2Types.TakeParams memory p = _buy(callId, _ids(ask, resale), 100, alice);
        vm.prank(alice);
        (uint64 qUnits, uint256 qPremium, uint256 qFee, uint256 qSellerFees) = book.quoteTake(p);
        (uint64 units, uint256 premium, uint256 takerFee) = _take(alice, p);
        assertEq(qUnits, units, "units");
        assertEq(qPremium, premium, "premium");
        assertEq(qFee, takerFee, "taker fee");
        assertEq(qSellerFees, 0, "a BUYING quote has no taker seller fees");

        // Selling writeToSell: the quote's fourth field is the 5 % the taker pays as a seller.
        uint256 bid = _place(bob, callId, BID, P2_00, 50);
        p = _sell(callId, _ids(bid), 50, true, carol);
        vm.prank(carol);
        (qUnits, qPremium, qFee, qSellerFees) = book.quoteTake(p);
        uint256 before = usdg.balanceOf(carol);
        (units, premium, takerFee) = _take(carol, p);
        assertEq(qUnits, units, "sell: units");
        assertEq(qPremium, premium, "sell: premium");
        assertEq(qFee, takerFee, "sell: taker fee");
        assertEq(qSellerFees, 50_000, "sell: seller fees quoted");
        assertEq(usdg.balanceOf(carol) - before, 1_000_000 - qSellerFees - qFee, "the quote adds up to the proceeds");

        // A destructure that skips the appended field reads the same first three (the consumer-compat pin).
        vm.prank(bob);
        (uint64 u2, uint256 p2, uint256 f2,) = book.quoteTake(_buy(callId, _ids(ask), 50, bob));
        assertEq(u2, 0, "the write ask is filled");
        assertEq(p2, 0, "nothing left to quote");
        assertEq(f2, 0, "nothing left to charge");
    }

    /*//////////////////////////////////////////////////////////////
                          THE DISCOUNT SEAM (v8)
    //////////////////////////////////////////////////////////////*/

    /// An honest 10 % module: the taker fee drops by exactly the rate, quoteTake agrees, the seller fees are
    /// untouched, and the maker rebate comes out of the DISCOUNTED fee (never more than it).
    function test_discount_honestModule_reducesOnlyTheTakerFee() public {
        uint256 ask = _place(carol, callId, WRITE, P2_00, 100); // 2.00 USDG premium, base fee 100_000
        discount.setBps(1_000);
        vm.prank(admin);
        book.setDiscountModule(IFeeDiscount(address(discount)));

        vm.prank(alice);
        (,, uint256 qFee,) = book.quoteTake(_buy(callId, _ids(ask), 100, alice));
        uint256 treasuryBefore = usdg.balanceOf(treasury);
        vm.recordLogs();
        (uint64 filled, uint256 premium, uint256 takerFee) = _take(alice, _buy(callId, _ids(ask), 100, alice));
        Filled memory f = _decodeFilled(_filledLogs(vm.getRecordedLogs())[0]);
        assertEq(filled, 100, "filled");
        assertEq(premium, 2_000_000, "premium");
        assertEq(takerFee, 90_000, "100_000 less 10 %");
        assertEq(qFee, takerFee, "quote matches take under the module");
        assertEq(f.sellerFee, 100_000, "the 5 % seller fee is NOT discounted");
        assertEq(f.makerRebate, 45_000, "half the DISCOUNTED fee (rebate bps 5000)");
        assertTrue(f.makerRebate <= takerFee, "rebate never exceeds the discounted fee");
        assertEq(usdg.balanceOf(treasury) - treasuryBefore, 100_000 + 90_000 - 45_000, "seller fee + fee - rebate");
    }

    /// A reverting module, one that returns short data, and one that burns its gas all read as 0: the take proceeds
    /// at the undiscounted fee. That is what "a hostile module cannot break or stall a take" means.
    function test_discount_revertingShortAndGasBurningModules_readAsZero() public {
        vm.prank(admin);
        book.setDiscountModule(IFeeDiscount(address(discount)));
        MockFeeDiscount.Mode[3] memory modes =
            [MockFeeDiscount.Mode.Revert, MockFeeDiscount.Mode.Short, MockFeeDiscount.Mode.GasDrain];
        for (uint256 i; i < modes.length; ++i) {
            uint256 ask = _place(carol, callId, WRITE, P2_00, 50);
            discount.setMode(modes[i]);
            discount.setBps(9_000); // would halve the fee if it were ever read
            (uint64 filled,, uint256 takerFee) = _take(alice, _buy(callId, _ids(ask), 50, alice));
            assertEq(filled, 50, "the take proceeds");
            assertEq(takerFee, 100_000, "a failed read is 0, not a revert and not a stall");
        }
    }

    /// An answer above MAX_DISCOUNT_BPS is clamped to it: 9,000 bps asked, 5,000 applied.
    function test_discount_answerAboveMax_isClamped() public {
        uint256 ask = _place(carol, callId, WRITE, P2_00, 50);
        discount.setBps(9_000);
        vm.prank(admin);
        book.setDiscountModule(IFeeDiscount(address(discount)));
        (,, uint256 takerFee) = _take(alice, _buy(callId, _ids(ask), 50, alice));
        assertEq(takerFee, 50_000, "clamped to MAX_DISCOUNT_BPS (half), not the 9,000 asked");
    }

    /// A module that tries to change the book's state from inside the read cannot: a staticcall makes the attempt
    /// revert, the module still answers, and the take proceeds at its (clamped) discount.
    function test_discount_reenteringModule_cannotBreakOrStallTheTake() public {
        uint256 ask = _place(carol, callId, WRITE, P2_00, 50);
        discount.setMode(MockFeeDiscount.Mode.Reenter);
        discount.setBps(1_000);
        vm.prank(admin);
        book.setDiscountModule(IFeeDiscount(address(discount)));
        (uint64 filled,, uint256 takerFee) = _take(alice, _buy(callId, _ids(ask), 50, alice));
        assertEq(filled, 50, "the take proceeds");
        assertEq(takerFee, 90_000, "the module's own answer applies");
        assertFalse(book.tradingPaused(), "the reentry attempt changed nothing");
    }

    /// No module set: identical results to a module answering 0 — the whole path is one zero-address check.
    function test_discount_noModule_identicalToTheBasePath() public {
        uint256 ask = _place(carol, callId, WRITE, P2_00, 50);
        vm.recordLogs();
        (,, uint256 feeNoModule) = _take(alice, _buy(callId, _ids(ask), 50, alice));
        Filled memory f1 = _decodeFilled(_filledLogs(vm.getRecordedLogs())[0]);

        discount.setBps(0);
        vm.prank(admin);
        book.setDiscountModule(IFeeDiscount(address(discount)));
        uint256 ask2 = _place(carol, callId, WRITE, P2_00, 50);
        vm.recordLogs();
        (,, uint256 feeZeroModule) = _take(alice, _buy(callId, _ids(ask2), 50, alice));
        Filled memory f2 = _decodeFilled(_filledLogs(vm.getRecordedLogs())[0]);

        assertEq(feeZeroModule, feeNoModule, "same fee");
        assertEq(f2.sellerFee, f1.sellerFee, "same seller fee");
        assertEq(f2.makerRebate, f1.makerRebate, "same rebate");

        vm.prank(admin);
        book.setDiscountModule(IFeeDiscount(address(0))); // clearing works too
        assertEq(address(book.discountModule()), address(0), "cleared");
    }

    /*//////////////////////////////////////////////////////////////
              THE 48 h WINDOW AND THE CAP, WORKING TOGETHER
    //////////////////////////////////////////////////////////////*/

    /// A scheduled change cannot surprise an in-flight taker: quoted at the old fee with the cap set to it, the take
    /// executes at the old fee before effectiveAt; once the pricier schedule is live the SAME take reverts
    /// FeeAboveMax instead of charging more, and passes again when the taker raises the cap to the new fee.
    function test_feeWindowAndCap_protectTheInFlightTaker() public {
        uint256 w1 = _place(carol, callId, WRITE, P2_00, 100);
        uint256 w2 = _place(carol, callId, WRITE, P2_00, 100);

        V2Types.TakeParams memory p = _buy(callId, _ids(w1), 100, alice);
        vm.prank(alice);
        (,, uint256 quoted,) = book.quoteTake(p);
        assertEq(quoted, 100_000, "quoted at the default flat fee");
        p.maxTotalFee = uint128(quoted); // 100_000, far inside uint128

        vm.prank(admin);
        book.setFeeParams(_pricierFees()); // live in 48 h: taker fee 200_000

        (uint64 filled,, uint256 takerFee) = _take(alice, p);
        assertEq(filled, 100, "before effectiveAt the old fees hold");
        assertEq(takerFee, 100_000, "exactly the quote");

        vm.warp(block.timestamp + V2Constants.FEE_CHANGE_DELAY); // the pricier schedule is live
        p.orderIds = _ids(w2);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.FeeAboveMax.selector, 200_000, 100_000));
        book.take(p);
        assertEq(_order(w2).filled, 0, "the in-flight taker was not charged the surprise fee");

        p.maxTotalFee = 200_000;
        (filled,, takerFee) = _take(alice, p);
        assertEq(filled, 100, "and fills once the taker re-quotes");
        assertEq(takerFee, 200_000, "at the new fee");
    }

    /*//////////////////////////////////////////////////////////////
                  mintOpen REQUIRES THE BOOK TO BE A MINTER
    //////////////////////////////////////////////////////////////*/

    /// With the book off the Clearinghouse's minter allow-list every write-on-fill ask is skipped at plan time (the
    /// same condition {Clearinghouse.mint} enforces at delivery), while resale asks still fill; restoring the entry
    /// restores the write fills.
    function test_mintOpen_requiresTheBookToBeAMinter() public {
        uint256 write = _place(carol, callId, WRITE, P2_00, 50);
        _mintLongs(bob, callId, 50);
        uint256 resale = _place(bob, callId, RESALE, P2_00, 50);

        vm.prank(admin);
        ch.setMinter(address(book), false);
        (uint64 filled,,) = _take(alice, _buy(callId, _ids(write, resale), 100, alice));
        assertEq(filled, 50, "only the resale ask filled");
        assertEq(_order(write).filled, 0, "the write ask was skipped, not reverted");
        assertEq(_order(resale).filled, 50, "the resale ask filled");

        vm.prank(admin);
        ch.setMinter(address(book), true);
        (filled,,) = _take(alice, _buy(callId, _ids(write), 50, alice));
        assertEq(filled, 50, "restored with the allow-list entry");
        assertEq(_order(write).filled, 50, "the write ask fills again");
    }
}
