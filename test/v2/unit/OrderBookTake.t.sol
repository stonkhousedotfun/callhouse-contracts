// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm, console2} from "forge-std/Test.sol";
import {OrderBookBaseTest, BookActor} from "./OrderBookBase.t.sol";
import {IMakerRegistry} from "../../../src/v2/interfaces/IMakerRegistry.sol";
import {IOrderBook} from "../../../src/v2/interfaces/IOrderBook.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";

/// @notice A maker registry that is expensive to ask (sweep contracts-c08): it burns all the gas it is given, or answers
///         every call with 64 KiB of zero bytes (about 14,300 gas of its own memory).
contract CostlyRegistry {
    bool public burnGas;

    function setBurnGas(bool on) external {
        burnGas = on;
    }

    fallback() external {
        if (burnGas) {
            while (true) {}
        }
        assembly ("memory-safe") {
            return(0, 0x10000)
        }
    }
}

/// @notice OrderBook.take and quoteTake (C2-06, architecture §3.6, ADR-08): buying across mixed resale and
///         write-on-fill asks with partial fills and every skip rule, selling from inventory and with writeToSell, the
///         taker fee (10 % cap on a micro ticket, flat on a large one, once per call), pro-rata maker rebates with and
///         without registry tiers, primary vs resale seller fees, failed maker payments credited to owed, bid makers
///         that reject ERC-1155 tokens, the absence of matchOrders, escrowed longs across settlement, and gas.
/// @dev Expected amounts are worked by hand in the comments, not recomputed with the book's own formulas.
contract OrderBookTakeTest is OrderBookBaseTest {
    /// @dev Gas limit of a take that names two orders whose makers burn all their hook gas, next to an honest one: two
    ///      delivery stipends plus a fresh honest fill and the re-planning fit well inside it.
    uint256 internal constant STIPEND_GRIEF_GAS = 2_000_000;
    /// @dev Gas an honest receiver's acceptance hook may spend inside the book's capped delivery (per hook).
    uint256 internal constant HONEST_HOOK_GAS = 100_000;

    /*//////////////////////////////////////////////////////////////
                                 BUYING
    //////////////////////////////////////////////////////////////*/

    function test_take_buying_acrossResaleAndWriteAsks_partialFills() public {
        _mintLongs(bob, callId, 50);
        uint256 resale = _place(bob, callId, RESALE, P2_00, 50);
        uint256 write = _place(carol, callId, WRITE, P2_50, 100);
        uint256 untouched = _place(mm, callId, WRITE, P3_00, 100);

        uint256 aliceUsdg = usdg.balanceOf(alice);
        uint256 bobUsdg = usdg.balanceOf(bob);
        uint256 carolUsdg = usdg.balanceOf(carol);
        uint256 mmUsdg = usdg.balanceOf(mm);
        uint256 carolFree = ch.free(carol, address(nvda));

        // 50 units @ 2.00 = 1.00 USDG from bob's escrow, 70 units @ 2.50 = 1.75 USDG minted from carol's collateral.
        (uint64 filled, uint256 premium, uint256 takerFee) =
            _take(alice, _buy(callId, _ids(resale, write, untouched), 120, keeper));

        assertEq(filled, 120, "units");
        assertEq(premium, 2_750_000, "premium");
        assertEq(takerFee, 100_000, "flat fee: 10 % of 2.75 USDG is above 0.10");

        // Shares of the fee by premium: bob 100_000 * 1.00 / 2.75 = 36_363, carol (last) 63_637. Rebates at 50 %:
        // 18_181 and 31_818. Carol pays the 5 % primary fee on 1.75 USDG = 87_500; bob's resale fee is 0.
        assertEq(usdg.balanceOf(alice), aliceUsdg - 2_850_000, "taker paid premium + fee once");
        assertEq(usdg.balanceOf(bob), bobUsdg + 1_018_181, "resale maker: premium + rebate");
        assertEq(usdg.balanceOf(carol), carolUsdg + 1_694_318, "write maker: premium - fee + rebate");
        assertEq(usdg.balanceOf(mm), mmUsdg, "order beyond the wanted size untouched");
        assertEq(usdg.balanceOf(treasury), 137_501, "seller fee + taker fee - rebates");
        assertEq(usdg.balanceOf(address(book)), 0, "book keeps nothing");

        assertEq(ch.balanceOf(keeper, callId), 120, "longs to the recipient");
        assertEq(ch.balanceOf(alice, callId), 0, "not to the taker");
        assertEq(ch.balanceOf(address(book), callId), 0, "resale escrow delivered");
        assertEq(ch.balanceOf(carol, callId | 1), 70, "shorts to the writer");
        assertEq(ch.free(carol, address(nvda)), carolFree - 70e16, "collateral locked for 70 units");
        assertEq(_order(resale).filled, 50, "resale filled");
        assertEq(_order(write).filled, 70, "write partially filled");
        assertEq(_order(untouched).filled, 0, "third order untouched");
    }

    function test_take_buying_skipsDeadForeignWrongSideSelfBeyondLimitAndUnbackedOrders() public {
        uint256 cancelled = _place(carol, callId, WRITE, P2_00, 10);
        vm.prank(carol);
        book.cancel(_ids(cancelled));
        uint256 filledOut = _place(carol, callId, WRITE, P2_00, 5);
        _take(bob, _buy(callId, _ids(filledOut), 5, bob));
        vm.prank(carol);
        uint256 expired = book.place(callId, WRITE, P2_00, 10, START40 + 1 hours);
        uint256 foreign = _place(carol, tslaId, WRITE, P2_00, 10);
        uint256 wrongSide = _place(carol, callId, BID, P2_00, 10);
        uint256 own = _place(alice, callId, WRITE, P2_00, 10);
        uint256 beyondLimit = _place(carol, callId, WRITE, P3_00, 10);
        vm.prank(mm);
        ch.setOperator(address(book), false);
        uint256 noOperator = _place(mm, callId, WRITE, P2_00, 10);
        vm.prank(bob);
        ch.withdraw(address(nvda), LEDGER_SHARES, bob);
        uint256 noCollateral = _place(bob, callId, WRITE, P2_00, 10);
        uint256 good = _place(carol, callId, WRITE, P2_50, 10);
        vm.warp(START + 2 hours);

        uint256[] memory ids = new uint256[](12);
        ids[0] = 999;
        ids[1] = cancelled;
        ids[2] = filledOut;
        ids[3] = expired;
        ids[4] = foreign;
        ids[5] = wrongSide;
        ids[6] = own;
        ids[7] = beyondLimit;
        ids[8] = noOperator;
        ids[9] = noCollateral;
        ids[10] = good;
        ids[11] = good; // named twice, fills once
        V2Types.TakeParams memory p = _buy(callId, ids, 20, alice);
        p.limitPrice = P2_50;

        vm.recordLogs();
        (uint64 filled, uint256 premium,) = _take(alice, p);
        Vm.Log[] memory fills = _filledLogs(vm.getRecordedLogs());

        assertEq(filled, 10, "only the good order");
        assertEq(premium, 250_000, "10 units @ 2.50");
        assertEq(fills.length, 1, "one OrderFilled");
        assertEq(uint256(fills[0].topics[1]), good, "for the good order");
        assertEq(_order(good).filled, 10, "good filled once");
        assertEq(_order(own).filled, 0, "self order skipped");
        assertEq(_order(noOperator).filled, 0, "unapproved writer skipped");
        assertEq(_order(noCollateral).filled, 0, "uncollateralised writer skipped");
        assertEq(_order(beyondLimit).filled, 0, "beyond limit skipped");
    }

    function test_take_limitPriceAndMinUnits() public {
        uint256 cheap = _place(carol, callId, WRITE, P2_00, 10);
        uint256 dear = _place(mm, callId, WRITE, P3_00, 10);
        V2Types.TakeParams memory p = _buy(callId, _ids(cheap, dear), 20, alice);
        p.limitPrice = P2_50;
        p.minUnits = 11;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.BelowMinUnits.selector, 10, 11));
        book.quoteTake(p);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.BelowMinUnits.selector, 10, 11));
        book.take(p);

        p.minUnits = 10;
        (uint64 filled,,) = _take(alice, p);
        assertEq(filled, 10, "only the order inside the limit");
        assertEq(_order(dear).filled, 0, "dear order untouched");
    }

    function test_take_deadlineAndBadParams() public {
        uint256 ask = _place(carol, callId, WRITE, P2_00, 10);
        V2Types.TakeParams memory p = _buy(callId, _ids(ask), 1, alice);

        p.deadline = START40 - 1;
        vm.prank(alice);
        vm.expectRevert(V2Errors.DeadlinePassed.selector);
        book.take(p);
        p.deadline = START40;
        (uint64 filled,,) = _take(alice, p);
        assertEq(filled, 1, "deadline == now is allowed");

        p.units = 0;
        vm.prank(alice);
        vm.expectRevert(V2Errors.BadUnits.selector);
        book.take(p);
        p.units = 1;
        p.recipient = address(0);
        vm.prank(alice);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.take(p);
        p.recipient = address(book);
        vm.prank(alice);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.take(p);
    }

    function test_take_askWrite_wholeOrSkipped_withOneCollateralBudgetPerMaker() public {
        vm.prank(carol);
        ch.withdraw(address(nvda), LEDGER_SHARES - 30e16, carol); // 30 units of collateral left
        uint256 w1 = _place(carol, callId, WRITE, P2_00, 20);
        uint256 w2 = _place(carol, callId, WRITE, P2_50, 20);

        vm.prank(alice);
        (uint64 qUnits, uint256 qPremium, uint256 qFee,) = book.quoteTake(_buy(callId, _ids(w1, w2), 40, alice));
        assertEq(qUnits, 20, "quote: second order would need 20 of the 10 left");
        assertEq(qPremium, 400_000, "quote premium");
        assertEq(qFee, 40_000, "quote fee (10 % cap)");

        (uint64 filled, uint256 premium, uint256 takerFee) = _take(alice, _buy(callId, _ids(w1, w2), 40, alice));
        assertEq(filled, qUnits, "take == quote units");
        assertEq(premium, qPremium, "take == quote premium");
        assertEq(takerFee, qFee, "take == quote fee");
        assertEq(_order(w2).filled, 0, "not cut down to the collateral");
        assertEq(ch.free(carol, address(nvda)), 10e16, "10 units left");

        (filled,,) = _take(alice, _buy(callId, _ids(w2), 10, alice));
        assertEq(filled, 10, "a size the collateral covers fills");
    }

    function test_take_askWrite_skippedWhileTheMarketCannotMint() public {
        uint256 ask = _place(carol, callId, WRITE, P2_00, 10);

        vm.prank(guardian);
        ch.setMintPaused(address(nvda), true);
        (uint64 filled,,) = _take(alice, _buy(callId, _ids(ask), 10, alice));
        assertEq(filled, 0, "mint paused");
        vm.prank(guardian);
        ch.setMintPaused(address(nvda), false);

        V2Types.MarketConfig memory m = _market();
        m.enabled = false;
        vm.prank(admin);
        _reconfigure(ch, address(nvda), m);
        (filled,,) = _take(alice, _buy(callId, _ids(ask), 10, alice));
        assertEq(filled, 0, "market disabled");
        vm.prank(admin);
        _reconfigure(ch, address(nvda), _market());

        (filled,,) = _take(alice, _buy(callId, _ids(ask), 10, alice));
        assertEq(filled, 10, "fills once minting is open");
    }

    function test_take_recipientRejectingTokens_writeSkipped_resaleReverts() public {
        BookActor sink = _newActor();
        sink.setAcceptTokens(false);
        uint256 write = _place(carol, callId, WRITE, P2_00, 10);
        (uint64 filled,,) = _take(alice, _buy(callId, _ids(write), 10, address(sink)));
        assertEq(filled, 0, "the mint reverted inside try/catch: skipped");
        assertEq(ch.balanceOf(carol, callId | 1), 0, "nothing written");

        _mintLongs(bob, callId, 10);
        uint256 resale = _place(bob, callId, RESALE, P2_00, 10);
        vm.prank(alice);
        vm.expectRevert(BookActor.Rejected.selector);
        book.take(_buy(callId, _ids(resale), 10, address(sink)));
    }

    /*//////////////////////////////////////////////////////////////
                                SELLING
    //////////////////////////////////////////////////////////////*/

    function test_take_selling_fromInventory() public {
        uint256 bobBid = _place(bob, callId, BID, P2_50, 50); // 1.25 USDG escrow
        uint256 carolBid = _place(carol, callId, BID, P2_00, 30); // 0.60 USDG escrow
        _mintLongs(alice, callId, 60);
        uint256 aliceUsdg = usdg.balanceOf(alice);
        uint256 bobUsdg = usdg.balanceOf(bob);
        uint256 carolUsdg = usdg.balanceOf(carol);
        uint256 mmUsdg = usdg.balanceOf(mm);

        // bob 50 @ 2.50 = 1.25 USDG, carol 10 @ 2.00 = 0.20 USDG.
        (uint64 filled, uint256 premium, uint256 takerFee) =
            _take(alice, _sell(callId, _ids(bobBid, carolBid), 60, false, mm));

        assertEq(filled, 60, "units");
        assertEq(premium, 1_450_000, "premium");
        assertEq(takerFee, 100_000, "flat");
        // Shares: bob 100_000 * 1.25 / 1.45 = 86_206, carol 13_794; rebates 43_103 and 6_897. Resale fee 0.
        assertEq(usdg.balanceOf(mm), mmUsdg + 1_350_000, "recipient: premium - taker fee - seller fee");
        assertEq(usdg.balanceOf(alice), aliceUsdg, "taker's own wallet untouched");
        assertEq(usdg.balanceOf(bob), bobUsdg + 43_103, "bid maker rebate");
        assertEq(usdg.balanceOf(carol), carolUsdg + 6_897, "bid maker rebate");
        assertEq(usdg.balanceOf(treasury), 50_000, "taker fee - rebates");
        assertEq(usdg.balanceOf(address(book)), 400_000, "carol's remaining 20 units of escrow");
        assertEq(ch.balanceOf(alice, callId), 0, "taker delivered");
        assertEq(ch.balanceOf(bob, callId), 50, "longs straight to bid maker");
        assertEq(ch.balanceOf(carol, callId), 10, "longs straight to bid maker");
        assertEq(_order(bobBid).filled, 50, "bob filled");
        assertEq(_order(carolBid).filled, 10, "carol partially filled");
    }

    function test_take_selling_writeToSell() public {
        uint256 bid = _place(bob, callId, BID, P2_50, 50);
        uint256 aliceFree = ch.free(alice, address(nvda));
        (uint64 filled, uint256 premium, uint256 takerFee) = _take(alice, _sell(callId, _ids(bid), 40, true, carol));

        assertEq(filled, 40, "units");
        assertEq(premium, 1_000_000, "premium");
        assertEq(takerFee, 100_000, "fee");
        assertEq(usdg.balanceOf(carol), ACTOR_USDG - LEDGER_USDG + 850_000, "1.00 - 0.10 taker - 0.05 primary fee");
        assertEq(usdg.balanceOf(treasury), 100_000, "0.05 primary + 0.10 taker - 0.05 rebate");
        assertEq(ch.balanceOf(bob, callId), 40, "minted longs to the bid maker");
        assertEq(ch.balanceOf(alice, callId | 1), 40, "shorts to the taker");
        assertEq(ch.balanceOf(alice, callId), 0, "no longs for the taker");
        assertEq(ch.free(alice, address(nvda)), aliceFree - 40e16, "taker's collateral locked");
        assertEq(usdg.balanceOf(address(book)), 250_000, "10 units of escrow left");
    }

    function test_take_selling_writeToSell_put_budgetsUsdgCollateral() public {
        uint256 bid = _place(bob, putId, BID, P2_50, 30);
        // A 210 put locks 2.10 USDG per unit. Leave alice 25 units of USDG collateral in the ledger.
        vm.prank(alice);
        ch.withdraw(address(usdg), LEDGER_USDG - 25 * 2_100_000, alice);

        (uint64 filled,,) = _take(alice, _sell(putId, _ids(bid), 30, true, alice));
        assertEq(filled, 0, "30 units need 63 USDG, 52.50 free: skipped whole");

        uint256 bookBefore = usdg.balanceOf(address(book));
        (filled,,) = _take(alice, _sell(putId, _ids(bid), 20, true, alice));
        assertEq(filled, 20, "20 units fit");
        assertEq(ch.free(alice, address(usdg)), 5 * 2_100_000, "42 USDG locked");
        assertEq(ch.balanceOf(bob, putId), 20, "put longs to the bid maker");
        assertEq(ch.balanceOf(alice, putId | 1), 20, "put shorts to the taker");
        assertEq(bookBefore - usdg.balanceOf(address(book)), 500_000, "20 @ 2.50 released from escrow");
    }

    function test_take_selling_needsInventoryApprovalOrOperator() public {
        uint256 bid = _place(bob, callId, BID, P2_50, 20);
        _mintLongs(alice, callId, 10);

        (uint64 filled,,) = _take(alice, _sell(callId, _ids(bid), 20, false, alice));
        assertEq(filled, 0, "20 wanted, 10 held: skipped, not cut down");
        V2Types.TakeParams memory p = _sell(callId, _ids(bid), 20, false, alice);
        p.minUnits = 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.BelowMinUnits.selector, 0, 1));
        book.take(p);

        vm.startPrank(alice);
        ch.setApprovalForAll(address(book), false);
        ch.setOperator(address(book), false);
        vm.stopPrank();
        (filled,,) = _take(alice, _sell(callId, _ids(bid), 10, false, alice));
        assertEq(filled, 0, "no ERC-1155 approval");
        (filled,,) = _take(alice, _sell(callId, _ids(bid), 10, true, alice));
        assertEq(filled, 0, "not an operator");
    }

    function test_take_selling_limitPriceIsAFloor() public {
        uint256 low = _place(bob, callId, BID, P2_00, 10);
        uint256 high = _place(carol, callId, BID, P3_00, 10);
        _mintLongs(alice, callId, 20);
        V2Types.TakeParams memory p = _sell(callId, _ids(low, high), 20, false, alice);
        p.limitPrice = P2_50;
        (uint64 filled, uint256 premium,) = _take(alice, p);
        assertEq(filled, 10, "only the bid at or above the floor");
        assertEq(premium, 300_000, "10 @ 3.00");
        assertEq(_order(low).filled, 0, "low bid untouched");
    }

    function test_take_selling_bidMakerRejectingTokens_isSkippedAndCannotRevertOthers() public {
        BookActor picky = _newActor();
        uint256 pickyBid = _place(address(picky), callId, BID, P3_00, 20); // 0.60 USDG escrow, best bid
        picky.setAcceptTokens(false);
        uint256 bobBid = _place(bob, callId, BID, P2_50, 20); // 0.50 USDG escrow
        _mintLongs(alice, callId, 20);

        // The plan reserves all 20 units for the best bid; its delivery reverts, so the book re-plans from bob's bid.
        V2Types.TakeParams memory p = _sell(callId, _ids(pickyBid, bobBid, pickyBid), 20, false, alice);
        p.minUnits = 20;
        vm.recordLogs();
        (uint64 filled, uint256 premium, uint256 takerFee) = _take(alice, p);
        Vm.Log[] memory fills = _filledLogs(vm.getRecordedLogs());
        assertEq(filled, 20, "bob's bid filled in full: minUnits met");
        assertEq(premium, 500_000, "priced at bob's bid");
        assertEq(takerFee, 50_000, "fee on what filled");
        assertEq(fills.length, 1, "no log for the refused bid");
        assertEq(uint256(fills[0].topics[1]), bobBid, "bob's fill");
        assertEq(_decodeFilled(fills[0]).makerRebate, 25_000, "bob's share is the whole fee of the re-planned round");
        assertEq(_order(pickyBid).filled, 0, "picky bid untouched");
        assertEq(ch.balanceOf(address(picky), callId), 0, "picky got nothing");
        assertEq(ch.balanceOf(bob, callId), 20, "bob got the longs");
        assertEq(usdg.balanceOf(address(book)), 600_000, "picky escrow intact");
        assertEq(usdg.balanceOf(treasury), 25_000, "fee - rebate");

        uint256 shortsBefore = ch.balanceOf(alice, callId | 1); // from minting her inventory above
        (filled,,) = _take(alice, _sell(callId, _ids(pickyBid), 10, true, alice));
        assertEq(filled, 0, "writeToSell mint to a rejecting bid maker is skipped too");
        assertEq(ch.balanceOf(alice, callId | 1), shortsBefore, "nothing written");
    }

    function test_take_buying_writerRefusingItsShorts_laterAsksFillAsIfItWereAbsent() public {
        BookActor writer = _newActor();
        uint256 refused = _place(address(writer), callId, WRITE, P2_00, 30); // cheapest ask
        writer.setAcceptTokens(false); // the mint's short leg to the writer will revert
        uint256 carolAsk = _place(carol, callId, WRITE, P2_50, 10);
        uint256 mmAsk = _place(mm, callId, WRITE, P3_00, 10);

        vm.prank(alice);
        (uint64 quoted,,,) = book.quoteTake(_buy(callId, _ids(refused, carolAsk, mmAsk), 20, alice));
        assertEq(quoted, 20, "the quote cannot foresee the refusal");

        vm.recordLogs();
        (uint64 filled, uint256 premium, uint256 takerFee) =
            _take(alice, _buy(callId, _ids(refused, carolAsk, mmAsk), 20, alice));
        Vm.Log[] memory fills = _filledLogs(vm.getRecordedLogs());
        assertEq(filled, 20, "carol and mm fill the 20 units");
        assertEq(premium, 550_000, "10 @ 2.50 + 10 @ 3.00");
        assertEq(takerFee, 55_000, "10 % cap");
        assertEq(fills.length, 2, "two fills");
        assertEq(uint256(fills[0].topics[1]), carolAsk, "caller's order kept");
        assertEq(uint256(fills[1].topics[1]), mmAsk, "caller's order kept");
        // Round two shares 55_000 by premium: carol 25_000, mm 30_000 (last); rebates at 50 %.
        assertEq(_decodeFilled(fills[0]).makerRebate, 12_500, "carol rebate");
        assertEq(_decodeFilled(fills[1]).makerRebate, 15_000, "mm rebate");
        assertEq(_order(refused).filled, 0, "refused ask untouched");
        assertEq(ch.balanceOf(address(writer), callId | 1), 0, "nothing written for the refusing writer");
    }

    /// @dev Sweep contracts-c06. A writer whose hook burns all the gas it is given: uncapped, the first mint handed it
    ///      63/64 of the take's gas and the second the rest, so a take naming two such asks ran out of gas at any
    ///      limit. Each delivery is capped at the book's stipend, so each burning ask costs at most that.
    function test_take_buying_writerBurningAllHookGas_costsAStipendPerAsk_laterAsksFill() public {
        BookActor burner = _newActor();
        uint256 first = _place(address(burner), callId, WRITE, P2_00, 10);
        uint256 second = _place(address(burner), callId, WRITE, P2_00, 10);
        burner.setHookGas(type(uint256).max);
        uint256 carolAsk = _place(carol, callId, WRITE, P2_50, 10);

        vm.prank(alice);
        (uint64 filled, uint256 premium,) =
            book.take{gas: STIPEND_GRIEF_GAS}(_buy(callId, _ids(first, second, carolAsk), 10, alice));
        assertEq(filled, 10, "carol's ask fills");
        assertEq(premium, 250_000, "at carol's price");
        assertEq(_order(first).filled + _order(second).filled, 0, "burning asks untouched");
        assertEq(ch.balanceOf(address(burner), callId | 1), 0, "nothing written for the burner");
        assertEq(ch.balanceOf(alice, callId), 10, "carol's longs to alice");
    }

    /// @dev Sweep contracts-c06, selling: two bids of a maker whose hook burns all its gas, sold into from inventory
    ///      and by writing.
    function test_take_selling_bidMakerBurningAllHookGas_costsAStipendPerBid_laterBidsFill() public {
        BookActor burner = _newActor();
        uint256 first = _place(address(burner), callId, BID, P3_00, 10);
        uint256 second = _place(address(burner), callId, BID, P3_00, 10);
        burner.setHookGas(type(uint256).max);
        uint256 bobBid = _place(bob, callId, BID, P2_50, 20);
        _mintLongs(alice, callId, 10);

        vm.prank(alice);
        (uint64 filled, uint256 premium,) =
            book.take{gas: STIPEND_GRIEF_GAS}(_sell(callId, _ids(first, second, bobBid), 10, false, alice));
        assertEq(filled, 10, "from inventory: bob's bid fills");
        assertEq(premium, 250_000, "at bob's price");

        vm.prank(alice);
        (filled, premium,) =
            book.take{gas: STIPEND_GRIEF_GAS}(_sell(callId, _ids(first, second, bobBid), 10, true, alice));
        assertEq(filled, 10, "writeToSell: bob's bid fills");
        assertEq(premium, 250_000, "at bob's price");

        assertEq(_order(first).filled + _order(second).filled, 0, "burning bids untouched");
        assertEq(ch.balanceOf(address(burner), callId), 0, "burner got nothing");
        assertEq(ch.balanceOf(bob, callId), 20, "bob got both sales");
    }

    /// @dev The stipend is not a limit honest receivers meet: a mint whose long recipient and writer each spend
    ///      HONEST_HOOK_GAS in their hooks still fills, and so does a sale to a bid maker spending it.
    function test_take_receiversSpendingHonestHookGas_stillFill() public {
        BookActor writer = _newActor();
        BookActor sink = _newActor();
        uint256 ask = _place(address(writer), callId, WRITE, P2_00, 10);
        writer.setHookGas(HONEST_HOOK_GAS);
        sink.setHookGas(HONEST_HOOK_GAS);
        (uint64 filled,,) = _take(alice, _buy(callId, _ids(ask), 10, address(sink)));
        assertEq(filled, 10, "write-on-fill ask filled");
        assertEq(ch.balanceOf(address(sink), callId), 10, "longs to the heavy recipient");
        assertEq(ch.balanceOf(address(writer), callId | 1), 10, "shorts to the heavy writer");

        BookActor bidder = _newActor();
        uint256 bid = _place(address(bidder), putId, BID, P2_50, 20);
        bidder.setHookGas(HONEST_HOOK_GAS);
        _mintLongs(alice, putId, 10);
        (filled,,) = _take(alice, _sell(putId, _ids(bid), 10, false, alice));
        assertEq(filled, 10, "sold from inventory to the heavy bid maker");
        (filled,,) = _take(alice, _sell(putId, _ids(bid), 10, true, alice));
        assertEq(filled, 10, "written to the heavy bid maker");
        assertEq(ch.balanceOf(address(bidder), putId), 20, "bid maker got both");
    }

    /*//////////////////////////////////////////////////////////////
                                  FEES
    //////////////////////////////////////////////////////////////*/

    function test_fees_microTicket_takerFeeIsTheTenPercentCap() public {
        uint256 ask = _place(carol, callId, WRITE, P2_50, 1);
        uint256 aliceBefore = usdg.balanceOf(alice);
        uint256 carolBefore = usdg.balanceOf(carol);
        // One unit (0.01 share) at 2.50 USDG/share = 0.025 USDG; the 0.10 flat would be 400 %.
        (uint64 filled, uint256 premium, uint256 takerFee) = _take(alice, _buy(callId, _ids(ask), 1, alice));
        assertEq(filled, 1, "one unit");
        assertEq(premium, 25_000, "0.025 USDG");
        assertEq(takerFee, 2_500, "10 % of premium, not 100_000");
        assertEq(usdg.balanceOf(alice), aliceBefore - 27_500, "taker");
        // 25_000 - 1_250 primary fee + 1_250 rebate (50 % of 2_500)
        assertEq(usdg.balanceOf(carol), carolBefore + 25_000, "maker");
        assertEq(usdg.balanceOf(treasury), 2_500, "1_250 + 2_500 - 1_250");
    }

    function test_fees_largeTicket_takerFeeIsTheFlat() public {
        uint256 ask = _place(carol, callId, WRITE, 5_000_000, 1000);
        uint256 aliceBefore = usdg.balanceOf(alice);
        uint256 carolBefore = usdg.balanceOf(carol);
        // 10 shares at 5.00 = 50 USDG; 10 % would be 5 USDG, the flat 0.10 applies.
        (, uint256 premium, uint256 takerFee) = _take(alice, _buy(callId, _ids(ask), 1000, alice));
        assertEq(premium, 50_000_000, "50 USDG");
        assertEq(takerFee, 100_000, "flat 0.10 USDG");
        assertEq(usdg.balanceOf(alice), aliceBefore - 50_100_000, "taker");
        assertEq(usdg.balanceOf(carol), carolBefore + 47_550_000, "50 - 2.5 primary fee + 0.05 rebate");
        assertEq(usdg.balanceOf(treasury), 2_550_000, "2.5 + 0.10 - 0.05");
    }

    function test_fees_capAndFlatMeetAtOneUsdgOfPremium() public {
        uint64[3] memory sizes = [uint64(39), 40, 41];
        uint256[3] memory fees = [uint256(97_500), 100_000, 100_000];
        for (uint256 i; i < sizes.length; ++i) {
            uint256 ask = _place(carol, callId, WRITE, P2_50, sizes[i]);
            (, uint256 premium, uint256 takerFee) = _take(alice, _buy(callId, _ids(ask), sizes[i], alice));
            assertEq(premium, uint256(sizes[i]) * 25_000, "premium");
            assertEq(takerFee, fees[i], "min(flat, 10 %)");
        }
    }

    function test_fees_takerFeeChargedOncePerCall() public {
        uint256 a = _place(carol, callId, WRITE, 5_000_000, 100);
        uint256 b = _place(mm, callId, WRITE, 5_000_000, 100);
        _mintLongs(bob, callId, 100);
        uint256 c = _place(bob, callId, RESALE, 5_000_000, 100);
        (uint64 filled, uint256 premium, uint256 takerFee) = _take(alice, _buy(callId, _ids(a, b, c), 300, alice));
        assertEq(filled, 300, "three orders");
        assertEq(premium, 15_000_000, "3 x 5 USDG");
        assertEq(takerFee, 100_000, "one flat fee for the call, not three");
    }

    function test_rebates_withoutRegistry_defaultForEveryMaker() public {
        (uint256 c, uint256 m, uint256 b) = _threeMakerAsks();
        uint256[4] memory before = _balances();
        vm.recordLogs();
        _take(alice, _buy(callId, _ids(c, m, b), 150, alice));
        Vm.Log[] memory fills = _filledLogs(vm.getRecordedLogs());

        // Premiums 1.00 USDG each, fee 100_000: shares 33_333, 33_333, 33_334 (last absorbs), rebates at 50 %.
        assertEq(_decodeFilled(fills[0]).makerRebate, 16_666, "carol rebate");
        assertEq(_decodeFilled(fills[1]).makerRebate, 16_666, "mm rebate");
        assertEq(_decodeFilled(fills[2]).makerRebate, 16_667, "bob rebate");
        uint256[4] memory afterTake = _balances();
        assertEq(afterTake[0] - before[0], 966_666, "carol: 1.00 - 0.05 + rebate");
        assertEq(afterTake[1] - before[1], 966_666, "mm: 1.00 - 0.05 + rebate");
        assertEq(afterTake[2] - before[2], 1_016_667, "bob: resale 1.00 + rebate");
        assertEq(afterTake[3] - before[3], 150_001, "treasury: 0.10 seller + 0.10 taker - 49_999");
    }

    function test_rebates_registryTiersChangeWhatIsPaid() public {
        vm.prank(admin);
        book.setMakerRegistry(registry);
        registry.setTier(carol, 10_000);
        registry.setTier(mm, 2_000);
        (uint256 c, uint256 m, uint256 b) = _threeMakerAsks();
        uint256[4] memory before = _balances();
        vm.recordLogs();
        _take(alice, _buy(callId, _ids(c, m, b), 150, alice));
        Vm.Log[] memory fills = _filledLogs(vm.getRecordedLogs());

        assertEq(_decodeFilled(fills[0]).makerRebate, 33_333, "carol: whole share");
        assertEq(_decodeFilled(fills[1]).makerRebate, 6_666, "mm: 20 % of 33_333");
        assertEq(_decodeFilled(fills[2]).makerRebate, 16_667, "bob: no tier, book default 50 % of 33_334");
        uint256[4] memory afterTake = _balances();
        assertEq(afterTake[0] - before[0], 983_333, "carol");
        assertEq(afterTake[1] - before[1], 956_666, "mm");
        assertEq(afterTake[2] - before[2], 1_016_667, "bob");
        assertEq(afterTake[3] - before[3], 143_334, "treasury: 0.20 - 56_666");
    }

    function test_rebates_registryFailureModesFallBackOrClamp() public {
        vm.prank(admin);
        book.setMakerRegistry(registry);

        registry.setTier(carol, 65_535);
        assertEq(_singleMakerRebate(), 100_000, "answer above 10_000 bps clamped to the whole share");
        registry.setTier(carol, 0);
        assertEq(_singleMakerRebate(), 50_000, "tier 0 = book default");
        registry.setTier(carol, 7_500);
        assertEq(_singleMakerRebate(), 75_000, "tier applied");
        registry.setReverts(true);
        assertEq(_singleMakerRebate(), 50_000, "reverting registry = book default, take still succeeds");

        vm.prank(admin);
        book.setMakerRegistry(IMakerRegistry(makeAddr("codeless registry")));
        assertEq(_singleMakerRebate(), 50_000, "no return data = book default");
    }

    /// @dev Sweep contracts-c08. The registry is read once per fill. Uncapped, a registry that burns its gas took 63/64
    ///      of the take's gas at the first fill and ran a take of three fills out of gas, and one answering with 64 KiB
    ///      made every fill copy the answer into the book's memory. Capped at 30,000 gas and one word, each read costs
    ///      a fill at most the cap and a useless answer reads as the book default.
    function test_rebates_registryBurningGasOrAnsweringHugeData_costsACapPerFill() public {
        CostlyRegistry costly = new CostlyRegistry();
        (uint256 c, uint256 m, uint256 b) = _threeMakerAsks();
        _take(alice, _buy(callId, _ids(c, m, b), 150, alice)); // warms every balance and supply the takes below touch
        (c, m, b) = _threeMakerAsks();
        uint256 withoutRegistry = _gasOf(_buy(callId, _ids(c, m, b), 150, alice));

        vm.prank(admin);
        book.setMakerRegistry(IMakerRegistry(address(costly)));
        (c, m, b) = _threeMakerAsks();
        uint256 hugeAnswers = _gasOf(_buy(callId, _ids(c, m, b), 150, alice));
        assertLt(hugeAnswers - withoutRegistry, 3 * 30_000, "three reads, each within its cap, nothing copied");

        costly.setBurnGas(true);
        (c, m, b) = _threeMakerAsks();
        vm.recordLogs();
        vm.prank(alice);
        (uint64 filled,,) = book.take{gas: 1_000_000}(_buy(callId, _ids(c, m, b), 150, alice));
        Vm.Log[] memory fills = _filledLogs(vm.getRecordedLogs());
        assertEq(filled, 150, "burning registry: all three fills");
        assertEq(_decodeFilled(fills[0]).makerRebate, 16_666, "book default rebate");
        assertEq(_decodeFilled(fills[2]).makerRebate, 16_667, "book default rebate, last share");
    }

    function test_rebates_fullRebate_lastMakerAbsorbsRounding_sumIsExactlyTheFee() public {
        V2Types.FeeParams memory f = _defaultFees();
        f.makerRebateBps = 10_000;
        vm.prank(admin);
        book.setFeeParams(f);
        vm.warp(START + V2Constants.FEE_CHANGE_DELAY); // the change is in effect
        (uint256 c, uint256 m, uint256 b) = _threeMakerAsks();
        vm.recordLogs();
        (,, uint256 takerFee) = _take(alice, _buy(callId, _ids(c, m, b), 150, alice));
        Vm.Log[] memory fills = _filledLogs(vm.getRecordedLogs());
        uint256 sum;
        for (uint256 i; i < fills.length; ++i) {
            sum += _decodeFilled(fills[i]).makerRebate;
        }
        assertEq(sum, takerFee, "shares add up to the fee");
        assertEq(_decodeFilled(fills[2]).makerRebate, 33_334, "last maker absorbs the dust");
        assertEq(usdg.balanceOf(treasury), 100_000, "only the primary seller fees stay with the protocol");
    }

    function test_sellerFee_primaryVersusResale_buyingAndSelling() public {
        V2Types.FeeParams memory f = _defaultFees();
        f.resaleFeeBps = 200;
        vm.prank(admin);
        book.setFeeParams(f);
        vm.warp(START + V2Constants.FEE_CHANGE_DELAY); // the change is in effect

        _mintLongs(bob, callId, 40);
        uint256 resale = _place(bob, callId, RESALE, P2_50, 40);
        uint256 write = _place(carol, callId, WRITE, P2_50, 40);
        vm.recordLogs();
        _take(alice, _buy(callId, _ids(resale, write), 80, alice));
        Vm.Log[] memory fills = _filledLogs(vm.getRecordedLogs());
        Filled memory r = _decodeFilled(fills[0]);
        Filled memory w = _decodeFilled(fills[1]);
        assertEq(r.sellerFee, 20_000, "resale: 2 % of 1.00");
        assertFalse(r.primary, "resale is not primary");
        assertEq(w.sellerFee, 50_000, "write: 5 % of 1.00");
        assertTrue(w.primary, "write is primary");
        assertTrue(r.takerIsBuyer && w.takerIsBuyer, "taker bought");

        uint256 bid = _place(mm, callId, BID, P2_50, 80);
        _mintLongs(alice, callId, 40);
        uint256 before = usdg.balanceOf(keeper);
        vm.recordLogs();
        _take(alice, _sell(callId, _ids(bid), 40, false, keeper));
        Filled memory inv = _decodeFilled(_filledLogs(vm.getRecordedLogs())[0]);
        assertEq(inv.sellerFee, 20_000, "sale from inventory is a resale");
        assertFalse(inv.primary, "inventory not primary");
        assertFalse(inv.takerIsBuyer, "taker sold");
        assertEq(usdg.balanceOf(keeper), before + 880_000, "1.00 - 0.02 - 0.10");

        vm.recordLogs();
        _take(alice, _sell(callId, _ids(bid), 40, true, keeper));
        Filled memory minted = _decodeFilled(_filledLogs(vm.getRecordedLogs())[0]);
        assertEq(minted.sellerFee, 50_000, "writeToSell pays the primary fee");
        assertTrue(minted.primary, "writeToSell is primary");
        assertEq(usdg.balanceOf(keeper), before + 880_000 + 850_000, "1.00 - 0.05 - 0.10");
    }

    /// @dev Sweep contracts-c05, kept as documented behaviour (V2-ACCOUNTING §4.1): a fill is primary by how the book
    ///      delivers it, not by where the longs came from. The same 100 freshly written units pay the premium fee
    ///      through a write-on-fill ask and nothing once minted outside the book and listed for resale; and a writer can
    ///      mint through the book for dust by selling, with writeToSell, into a one-tick bid of its own second address.
    ///      INTERFACE_VERSION 7 leaves all of this exactly as it is, and stops mattering: `premiumFeeBps` is 0 at
    ///      launch, and the writer fee is the Clearinghouse's collateral rent, charged at the mint whichever of these
    ///      routes reached it ({ClearinghouseMintFeeTest}, {C05MintFeeTest}). This fixture keeps the v6 fee set
    ///      (premium 500 bps) and `mintFeePpm` 0 (design §3.8), so the numbers below are unchanged.
    function test_sellerFee_followsTheFill_notWhereTheLongsCameFrom() public {
        uint256 carolAsk = _place(carol, callId, WRITE, P2_50, 100);
        _mintLongs(bob, callId, 100);
        uint256 bobAsk = _place(bob, callId, RESALE, P2_50, 100);

        uint256 treasuryBefore = usdg.balanceOf(treasury);
        uint256 carolBefore = usdg.balanceOf(carol);
        _take(alice, _buy(callId, _ids(carolAsk), 100, alice));
        assertEq(usdg.balanceOf(carol) - carolBefore, 2_425_000, "write-on-fill: 2.50 - 0.125 premium fee + 0.05");
        assertEq(usdg.balanceOf(treasury) - treasuryBefore, 175_000, "0.125 + 0.10 - 0.05");

        treasuryBefore = usdg.balanceOf(treasury);
        uint256 bobBefore = usdg.balanceOf(bob);
        _take(alice, _buy(callId, _ids(bobAsk), 100, alice));
        assertEq(usdg.balanceOf(bob) - bobBefore, 2_550_000, "minted outside the book: 2.50 + 0.05, no seller fee");
        assertEq(usdg.balanceOf(treasury) - treasuryBefore, 50_000, "0.10 - 0.05 only");
        assertEq(ch.balanceOf(bob, callId | 1), 100, "bob is short the same 100 units");
        assertEq(ch.balanceOf(carol, callId | 1), 100, "as carol is");

        // mm stands in for a second address of carol's: a one-tick bid for 100 units escrows 100 base units.
        uint256 dustBid = _place(mm, callId, BID, 100, 100);
        vm.recordLogs();
        (, uint256 premium, uint256 takerFee) = _take(carol, _sell(callId, _ids(dustBid), 100, true, carol));
        Filled memory f = _decodeFilled(_filledLogs(vm.getRecordedLogs())[0]);
        assertTrue(f.primary, "a primary fill");
        assertEq(premium, 100, "100 units at one tick");
        assertEq(f.sellerFee + takerFee, 15, "5 + 10 base units of fees for 100 units written through the book");
        assertEq(ch.balanceOf(mm, callId), 100, "the longs, free to resell");
    }

    /*//////////////////////////////////////////////////////////////
                             OWED PAYMENTS
    //////////////////////////////////////////////////////////////*/

    function test_owed_makerWhoseUsdgTransferReverts_isCredited() public {
        _mintLongs(bob, callId, 20);
        uint256 resale = _place(bob, callId, RESALE, P2_50, 20);
        uint256 write = _place(carol, callId, WRITE, P2_50, 20);
        uint256 bobBefore = usdg.balanceOf(bob);
        uint256 carolBefore = usdg.balanceOf(carol);
        usdg.freeze(carol);

        (uint64 filled,,) = _take(alice, _buy(callId, _ids(resale, write), 40, alice));
        assertEq(filled, 40, "take succeeds");
        // premium 1.00, fee 0.10, shares 50_000 each, rebates 25_000 each; carol's 5 % fee on 0.50 = 25_000.
        assertEq(usdg.balanceOf(bob), bobBefore + 525_000, "bob paid");
        assertEq(usdg.balanceOf(carol), carolBefore, "frozen carol not paid");
        assertEq(book.owed(carol), 500_000, "0.50 - 0.025 + 0.025 credited");
        assertEq(usdg.balanceOf(address(book)), 500_000, "book holds what it owes");
        assertEq(usdg.balanceOf(treasury), 75_000, "fees still paid");

        usdg.unfreeze(carol);
        vm.prank(carol);
        book.claimOwed();
        assertEq(usdg.balanceOf(carol), carolBefore + 500_000, "claimed");
        assertEq(usdg.balanceOf(address(book)), 0, "book emptied");
    }

    function test_owed_usdgPaused_sellingTakeCreditsEveryPayee() public {
        uint256 bid = _place(bob, callId, BID, P2_50, 40); // 1.00 USDG escrow
        _mintLongs(alice, callId, 40);
        usdg.pause();

        (uint64 filled,,) = _take(alice, _sell(callId, _ids(bid), 40, false, carol));
        assertEq(filled, 40, "a sale into escrowed bids needs no USDG transfer to succeed");
        assertEq(ch.balanceOf(bob, callId), 40, "longs delivered");
        assertEq(book.owed(carol), 900_000, "recipient owed");
        assertEq(book.owed(bob), 50_000, "rebate owed");
        assertEq(book.owed(treasury), 50_000, "fee owed");
        assertEq(usdg.balanceOf(address(book)), 1_000_000, "all still in the book");

        usdg.unpause();
        address[3] memory payees = [carol, bob, treasury];
        for (uint256 i; i < payees.length; ++i) {
            vm.prank(payees[i]);
            book.claimOwed();
            assertEq(book.owed(payees[i]), 0, "claimed");
        }
        assertEq(usdg.balanceOf(address(book)), 0, "book emptied");
    }

    /*//////////////////////////////////////////////////////////////
                         NO CROSSING FUNCTION
    //////////////////////////////////////////////////////////////*/

    /// @dev ADR-03: every execution goes through take and pays the taker fee.
    function test_noMatchOrders_inTheAbiOrTheBytecode() public {
        string memory json = vm.readFile("out/OrderBook.sol/OrderBook.json");
        string[] memory sigs = vm.parseJsonKeys(json, ".methodIdentifiers");
        bool sawTake;
        for (uint256 i; i < sigs.length; ++i) {
            bytes memory s = bytes(sigs[i]);
            assertFalse(_startsWithMatch(s), sigs[i]);
            if (s.length > 5 && s[0] == "t" && s[1] == "a" && s[2] == "k" && s[3] == "e" && s[4] == "(") {
                sawTake = true;
            }
        }
        assertTrue(sawTake, "the ABI was read");

        (bool ok,) = address(book).call(abi.encodeWithSignature("matchOrders(uint256,uint256)", 1, 2));
        assertFalse(ok, "matchOrders(uint256,uint256)");
        (ok,) = address(book).call(abi.encodeWithSignature("matchOrders(uint256[],uint256[])", _ids(1), _ids(2)));
        assertFalse(ok, "matchOrders(uint256[],uint256[])");
    }

    /*//////////////////////////////////////////////////////////////
                         ESCROW AND SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    function test_escrow_settledSeries_thirdPartyCannotRedeemTheBook_pruneReturnsLongs_makerRedeemed() public {
        if (!ch.isOperator(carol, address(this))) {
            vm.prank(carol);
            ch.setOperator(address(this), true);
        }
        ch.mint(callId, 30, carol, bob); // bob holds longs written by carol
        uint256 ask = _place(bob, callId, RESALE, P2_00, 30);

        vm.warp(FRI_2026_09_18 + 1 hours);
        oracle.setFinal(address(nvda), FRI_2026_09_18, 240_000_000); // ITM: 240 > 230
        vm.prank(keeper);
        assertTrue(ch.settle(callId), "settled");

        (uint64 filled,,) = _take(alice, _buy(callId, _ids(ask), 30, alice));
        assertEq(filled, 0, "trading stopped at expiry");

        vm.prank(carol);
        vm.expectRevert(V2Errors.ThirdPartyRedeemDisabled.selector);
        ch.redeem(callId, address(book));
        address[] memory holders = new address[](1);
        holders[0] = address(book);
        vm.prank(keeper);
        assertEq(ch.redeemBatch(callId, holders), 0, "batch skips the opted-out book");
        assertEq(ch.balanceOf(address(book), callId), 30, "escrow intact");

        vm.prank(keeper);
        assertEq(book.prune(_ids(ask)), 1, "pruned");
        assertEq(ch.balanceOf(bob, callId), 30, "longs back with the maker");

        (uint256 longPerUnit,,) = ch.previewSettlement(callId, 240_000_000);
        assertGt(longPerUnit, 0, "in the money");
        uint256 nvdaBefore = nvda.balanceOf(bob);
        vm.prank(keeper);
        (uint256 paid,) = ch.redeem(callId, bob);
        assertEq(paid, 30 * longPerUnit, "maker redeemed like any holder");
        assertEq(nvda.balanceOf(bob), nvdaBefore + paid, "paid in kind");
    }

    function test_escrow_makerCancelAfterSettlement_returnsLongs() public {
        _mintLongs(bob, callId, 10);
        uint256 ask = _place(bob, callId, RESALE, P2_00, 10);
        vm.warp(FRI_2026_09_18 + 1 hours);
        oracle.setFinal(address(nvda), FRI_2026_09_18, 200_000_000); // OTM
        ch.settle(callId);
        vm.prank(bob);
        book.cancel(_ids(ask));
        assertEq(ch.balanceOf(bob, callId), 10, "longs back");
        vm.prank(keeper);
        (uint256 paid,) = ch.redeem(callId, bob);
        assertEq(paid, 0, "OTM long pays nothing");
        assertEq(ch.balanceOf(bob, callId), 0, "burned");
    }

    /*//////////////////////////////////////////////////////////////
                               QUOTE TAKE
    //////////////////////////////////////////////////////////////*/

    function test_quoteTake_equalsTake_buyingAndSelling() public {
        _mintLongs(bob, callId, 50);
        uint256 resale = _place(bob, callId, RESALE, P2_00, 50);
        uint256 write = _place(carol, callId, WRITE, P2_50, 100);
        V2Types.TakeParams memory buy = _buy(callId, _ids(resale, write), 120, keeper);
        vm.prank(alice);
        (uint64 qu, uint256 qp, uint256 qf,) = book.quoteTake(buy);
        (uint64 tu, uint256 tp, uint256 tf) = _take(alice, buy);
        assertEq(qu, tu, "buy units");
        assertEq(qp, tp, "buy premium");
        assertEq(qf, tf, "buy fee");

        uint256 bid1 = _place(mm, callId, BID, P3_00, 30);
        uint256 bid2 = _place(bob, callId, BID, P2_50, 30);
        V2Types.TakeParams memory sell = _sell(callId, _ids(bid1, bid2), 45, true, keeper);
        vm.prank(alice);
        (qu, qp, qf,) = book.quoteTake(sell);
        (tu, tp, tf) = _take(alice, sell);
        assertEq(qu, tu, "sell units");
        assertEq(qp, tp, "sell premium");
        assertEq(qf, tf, "sell fee");
        assertEq(tu, 45, "sold");
    }

    function test_quoteTake_skipsTheCallersOwnOrders() public {
        uint256 own = _place(alice, callId, WRITE, P2_00, 10);
        vm.prank(alice);
        (uint64 units,,,) = book.quoteTake(_buy(callId, _ids(own), 10, alice));
        assertEq(units, 0, "self order skipped for the caller");
        vm.prank(bob);
        (units,,,) = book.quoteTake(_buy(callId, _ids(own), 10, bob));
        assertEq(units, 10, "fillable for someone else");
    }

    function test_take_nothingFillable_emitsOnlyTaken() public {
        vm.expectEmit(address(book));
        emit IOrderBook.Taken(alice, callId, true, 0, 0, 0);
        vm.recordLogs();
        (uint64 filled, uint256 premium, uint256 takerFee) = _take(alice, _buy(callId, _ids(12_345), 10, alice));
        assertEq(filled + premium + takerFee, 0, "nothing");
        assertEq(vm.getRecordedLogs().length, 1, "no transfers, just Taken");
    }

    /*//////////////////////////////////////////////////////////////
                                  GAS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reference numbers for the PR notes: a buy of 1 and of 5 write-on-fill asks from distinct makers, the same
    ///      for resale asks, and a sale into 1 and 5 bids from inventory. Loose ceilings catch regressions only.
    function test_gas_take_oneAndFiveOrders() public {
        address[5] memory makers = [bob, carol, mm, makeAddr("maker4"), makeAddr("maker5")];
        _onboardExtra(makers[3]);
        _onboardExtra(makers[4]);
        uint256[5] memory w;
        uint256[5] memory r;
        uint256[5] memory b;
        for (uint256 i; i < 5; ++i) {
            w[i] = _place(makers[i], callId, WRITE, P2_50, 10);
            _mintLongs(makers[i], callId, 10);
            r[i] = _place(makers[i], callId, RESALE, P2_50, 10);
            b[i] = _place(makers[i], putId, BID, P2_50, 10);
        }
        // The single-order takes hit a sixth order of each kind, so every take below fills fresh orders.
        uint256 w1 = _place(carol, callId, WRITE, P2_50, 10);
        _mintLongs(carol, callId, 10);
        uint256 r1 = _place(carol, callId, RESALE, P2_50, 10);
        uint256 b1 = _place(carol, putId, BID, P2_50, 10);
        _mintLongs(alice, putId, 60);

        uint256 gw1 = _gasOf(_buy(callId, _ids(w1), 10, alice));
        uint256 gw5 = _gasOf(_buy(callId, _ids(w[0], w[1], w[2], w[3], w[4]), 50, alice));
        uint256 gr1 = _gasOf(_buy(callId, _ids(r1), 10, alice));
        uint256 gr5 = _gasOf(_buy(callId, _ids(r[0], r[1], r[2], r[3], r[4]), 50, alice));
        uint256 gs1 = _gasOf(_sell(putId, _ids(b1), 10, false, alice));
        uint256 gs5 = _gasOf(_sell(putId, _ids(b[0], b[1], b[2], b[3], b[4]), 50, false, alice));
        assertEq(_order(w[4]).filled + _order(r[4]).filled + _order(b[4]).filled, 30, "the fifth orders filled");

        console2.log("take buy AskWrite  x1", gw1);
        console2.log("take buy AskWrite  x5", gw5);
        console2.log("take buy AskResale x1", gr1);
        console2.log("take buy AskResale x5", gr5);
        console2.log("take sell Bid (inventory) x1", gs1);
        console2.log("take sell Bid (inventory) x5", gs5);
        assertLt(gw1, 400_000, "1 write");
        assertLt(gw5, 1_200_000, "5 writes");
        assertLt(gr5, 800_000, "5 resales");
        assertLt(gs5, 800_000, "5 bids");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev carol and mm AskWrite, bob AskResale, 50 units at 2.00 each (1.00 USDG of premium per order).
    function _threeMakerAsks() internal returns (uint256 c, uint256 m, uint256 b) {
        c = _place(carol, callId, WRITE, P2_00, 50);
        m = _place(mm, callId, WRITE, P2_00, 50);
        _mintLongs(bob, callId, 50);
        b = _place(bob, callId, RESALE, P2_00, 50);
    }

    function _balances() internal view returns (uint256[4] memory b) {
        b = [usdg.balanceOf(carol), usdg.balanceOf(mm), usdg.balanceOf(bob), usdg.balanceOf(treasury)];
    }

    /// @dev Rebate carol earns on a fresh 1.00 USDG write-on-fill ask taken alone (share = the whole 0.10 fee).
    function _singleMakerRebate() internal returns (uint256) {
        uint256 ask = _place(carol, callId, WRITE, P2_00, 50);
        vm.recordLogs();
        _take(alice, _buy(callId, _ids(ask), 50, alice));
        return _decodeFilled(_filledLogs(vm.getRecordedLogs())[0]).makerRebate;
    }

    function _startsWithMatch(bytes memory s) internal pure returns (bool) {
        if (s.length < 5) return false;
        bytes5 prefix = bytes5(abi.encodePacked(s[0], s[1], s[2], s[3], s[4]));
        // case-insensitive "match"
        bytes5 lowerCaseBits = 0x2020202020;
        bytes5 word = "match";
        return (prefix | lowerCaseBits) == word;
    }

    function _onboardExtra(address who) internal {
        _fund(who, ACTOR_USDG, ACTOR_SHARES, ACTOR_SHARES);
        _onboard(who);
    }

    function _gasOf(V2Types.TakeParams memory p) internal returns (uint256) {
        _take(alice, p);
        return vm.lastCallGas().gasTotalUsed;
    }
}
