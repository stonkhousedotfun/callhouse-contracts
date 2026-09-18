// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OrderBookBaseTest} from "./OrderBookBase.t.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {IOrderBook} from "../../../src/v2/interfaces/IOrderBook.sol";

/// @notice The log order the indexer relies on (02-interfaces §1.8, INTERFACE_VERSION 6), asserted log by log with
///         vm.recordLogs: AskResale escrow TransferSingle before OrderPlaced / OrderCancelled; in take, per filled
///         order its delivery logs then its OrderFilled (skipped orders emit nothing), the USDG transfers after the
///         loop, Taken last; never a TransferBatch; OrderFilled.recipient is the take's recipient, not the taker.
contract OrderBookLogsTest is OrderBookBaseTest {
    bytes32 internal immutable TRANSFER_SINGLE = IERC1155.TransferSingle.selector;
    bytes32 internal immutable TRANSFER_BATCH = IERC1155.TransferBatch.selector;
    bytes32 internal immutable ERC20_TRANSFER = IERC20.Transfer.selector;
    bytes32 internal immutable MINTED = IClearinghouse.Minted.selector;
    bytes32 internal immutable ORDER_PLACED = IOrderBook.OrderPlaced.selector;
    bytes32 internal immutable ORDER_CANCELLED = IOrderBook.OrderCancelled.selector;
    bytes32 internal immutable ORDER_FILLED = IOrderBook.OrderFilled.selector;
    bytes32 internal immutable TAKEN = IOrderBook.Taken.selector;

    /*//////////////////////////////////////////////////////////////
                         RESALE ESCROW IN AND OUT
    //////////////////////////////////////////////////////////////*/

    function test_logs_askResale_placeCancelPruneReplace_escrowTransferFirst() public {
        _mintLongs(bob, callId, 20);
        vm.recordLogs();
        uint256 id = _place(bob, callId, RESALE, P2_00, 20);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "place: escrow + OrderPlaced");
        _assertTransferSingle(logs[0], bob, address(book), callId, 20);
        _assertBook(logs[1], ORDER_PLACED, id);

        vm.recordLogs();
        vm.prank(bob);
        uint256 replaced = book.replace(id, P3_00, 15);
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 4, "replace = cancel then place");
        _assertTransferSingle(logs[0], address(book), bob, callId, 20);
        _assertBook(logs[1], ORDER_CANCELLED, id);
        _assertTransferSingle(logs[2], bob, address(book), callId, 15);
        _assertBook(logs[3], ORDER_PLACED, replaced);

        vm.recordLogs();
        vm.prank(bob);
        book.cancel(_ids(replaced));
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "cancel: refund + OrderCancelled");
        _assertTransferSingle(logs[0], address(book), bob, callId, 15);
        _assertBook(logs[1], ORDER_CANCELLED, replaced);
        (, bool pruned) = abi.decode(logs[1].data, (uint64, bool));
        assertFalse(pruned, "cancel is not a prune");

        _mintLongs(bob, dailyId, 5);
        uint256 daily = _place(bob, dailyId, RESALE, P2_00, 5);
        vm.warp(THU_2026_09_10);
        vm.recordLogs();
        vm.prank(keeper);
        book.prune(_ids(daily));
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "prune: refund + OrderCancelled");
        _assertTransferSingle(logs[0], address(book), bob, dailyId, 5);
        _assertBook(logs[1], ORDER_CANCELLED, daily);
        (, pruned) = abi.decode(logs[1].data, (uint64, bool));
        assertTrue(pruned, "pruned flag");
    }

    /*//////////////////////////////////////////////////////////////
                                  TAKE
    //////////////////////////////////////////////////////////////*/

    function test_logs_takeBuying_deliveryThenFilledPerOrder_transfersAfter_takenLast() public {
        _mintLongs(bob, callId, 20);
        uint256 resale = _place(bob, callId, RESALE, P2_00, 20); // 0.40 USDG
        uint256 write = _place(carol, callId, WRITE, P2_50, 20); // 0.50 USDG

        vm.recordLogs();
        // alice takes, keeper receives the longs; 999 is skipped and must leave no trace.
        (, uint256 premium, uint256 takerFee) = _take(alice, _buy(callId, _ids(resale, 999, write), 40, keeper));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(premium, 900_000, "premium");
        assertEq(takerFee, 90_000, "10 % cap");
        _assertNoBatch(logs);
        assertEq(logs.length, 11, "log count");

        // order 1: AskResale delivery from escrow, then its fill
        _assertTransferSingle(logs[0], address(book), keeper, callId, 20);
        _assertFilled(logs[1], resale, bob, 20, false, true);
        _assertRecipient(logs[1], keeper);
        // order 2: the Clearinghouse mint's three logs, then its fill
        _assertTransferSingle(logs[2], address(0), keeper, callId, 20);
        _assertTransferSingle(logs[3], address(0), carol, callId | 1, 20);
        assertEq(logs[4].emitter, address(ch), "Minted emitter");
        assertEq(logs[4].topics[0], MINTED, "Minted");
        assertEq(address(uint160(uint256(logs[4].topics[2]))), carol, "writer");
        assertEq(address(uint160(uint256(logs[4].topics[3]))), keeper, "longTo is the recipient");
        _assertFilled(logs[5], write, carol, 20, true, true);
        _assertRecipient(logs[5], keeper);
        // after the loop: the single pull, maker payments in fill order, the fee
        _assertUsdgTransfer(logs[6], alice, address(book), 990_000);
        // shares 40_000 / 50_000, rebates 20_000 / 25_000; carol pays 25_000 primary fee
        _assertUsdgTransfer(logs[7], address(book), bob, 420_000);
        _assertUsdgTransfer(logs[8], address(book), carol, 500_000);
        _assertUsdgTransfer(logs[9], address(book), treasury, 70_000);
        _assertBook(logs[10], TAKEN, 0);
        assertEq(address(uint160(uint256(logs[10].topics[1]))), alice, "Taken.taker");
        (bool buying, uint64 units, uint256 p, uint256 f) = abi.decode(logs[10].data, (bool, uint64, uint256, uint256));
        assertTrue(buying, "buying");
        assertEq(units, 40, "units");
        assertEq(p, premium, "premium");
        assertEq(f, takerFee, "fee");
    }

    function test_logs_takeSelling_fromInventory_recipientIsNotTheTaker() public {
        uint256 bobBid = _place(bob, callId, BID, P2_50, 20); // 0.50 USDG
        uint256 carolBid = _place(carol, callId, BID, P2_00, 20); // 0.40 USDG
        _mintLongs(alice, callId, 40);

        vm.recordLogs();
        _take(alice, _sell(callId, _ids(bobBid, carolBid), 40, false, mm));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertNoBatch(logs);
        assertEq(logs.length, 9, "log count");

        _assertTransferSingle(logs[0], alice, bob, callId, 20);
        _assertFilled(logs[1], bobBid, bob, 20, false, false);
        _assertRecipient(logs[1], mm);
        _assertTransferSingle(logs[2], alice, carol, callId, 20);
        _assertFilled(logs[3], carolBid, carol, 20, false, false);
        _assertRecipient(logs[3], mm);
        // premium 0.90, fee 0.09 (cap), shares 50_000 / 40_000, rebates 25_000 / 20_000
        _assertUsdgTransfer(logs[4], address(book), mm, 810_000);
        _assertUsdgTransfer(logs[5], address(book), bob, 25_000);
        _assertUsdgTransfer(logs[6], address(book), carol, 20_000);
        _assertUsdgTransfer(logs[7], address(book), treasury, 45_000);
        _assertBook(logs[8], TAKEN, 0);
    }

    function test_logs_takeSelling_writeToSell_mintLogsThenFilled() public {
        uint256 bid = _place(bob, callId, BID, P2_50, 20);
        vm.recordLogs();
        _take(alice, _sell(callId, _ids(bid), 20, true, mm));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertNoBatch(logs);
        assertEq(logs.length, 8, "log count");

        _assertTransferSingle(logs[0], address(0), bob, callId, 20);
        _assertTransferSingle(logs[1], address(0), alice, callId | 1, 20);
        assertEq(logs[2].topics[0], MINTED, "Minted");
        assertEq(address(uint160(uint256(logs[2].topics[2]))), alice, "writer is the taker");
        assertEq(address(uint160(uint256(logs[2].topics[3]))), bob, "longTo is the bid maker");
        _assertFilled(logs[3], bid, bob, 20, true, false);
        _assertRecipient(logs[3], mm);
        // premium 0.50, fee 0.05, primary fee 0.025, rebate 0.025
        _assertUsdgTransfer(logs[4], address(book), mm, 425_000);
        _assertUsdgTransfer(logs[5], address(book), bob, 25_000);
        _assertUsdgTransfer(logs[6], address(book), treasury, 50_000);
        _assertBook(logs[7], TAKEN, 0);
    }

    function test_logs_skippedAskWrite_emitsNothingForIt() public {
        vm.prank(carol);
        ch.setOperator(address(book), false); // carol's write-on-fill ask cannot be minted
        uint256 dead = _place(carol, callId, WRITE, P2_50, 10);
        uint256 live = _place(mm, callId, WRITE, P2_50, 10);
        vm.recordLogs();
        _take(alice, _buy(callId, _ids(dead, live), 20, alice));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log[] memory fills = _filledLogs(logs);
        assertEq(fills.length, 1, "one fill");
        assertEq(uint256(fills[0].topics[1]), live, "the live order");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == TRANSFER_SINGLE) {
                address to = address(uint160(uint256(logs[i].topics[3])));
                assertTrue(to != carol, "nothing delivered to the skipped maker");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _assertTransferSingle(Vm.Log memory log, address from, address to, uint256 id, uint256 value)
        internal
        view
    {
        assertEq(log.emitter, address(ch), "TransferSingle emitter");
        assertEq(log.topics[0], TRANSFER_SINGLE, "TransferSingle");
        assertEq(address(uint160(uint256(log.topics[1]))), address(book), "operator is the book");
        assertEq(address(uint160(uint256(log.topics[2]))), from, "from");
        assertEq(address(uint160(uint256(log.topics[3]))), to, "to");
        (uint256 gotId, uint256 gotValue) = abi.decode(log.data, (uint256, uint256));
        assertEq(gotId, id, "id");
        assertEq(gotValue, value, "value");
    }

    function _assertUsdgTransfer(Vm.Log memory log, address from, address to, uint256 value) internal view {
        assertEq(log.emitter, address(usdg), "Transfer emitter");
        assertEq(log.topics[0], ERC20_TRANSFER, "Transfer");
        assertEq(address(uint160(uint256(log.topics[1]))), from, "from");
        assertEq(address(uint160(uint256(log.topics[2]))), to, "to");
        assertEq(abi.decode(log.data, (uint256)), value, "amount");
    }

    /// @dev A book log with `sig`; `orderId` checked against topic 1 when non-zero.
    function _assertBook(Vm.Log memory log, bytes32 sig, uint256 orderId) internal view {
        assertEq(log.emitter, address(book), "book emitter");
        assertEq(log.topics[0], sig, "book event");
        if (orderId != 0) assertEq(uint256(log.topics[1]), orderId, "order id");
    }

    function _assertFilled(
        Vm.Log memory log,
        uint256 orderId,
        address maker,
        uint64 units,
        bool primary,
        bool takerIsBuyer
    ) internal view {
        _assertBook(log, ORDER_FILLED, orderId);
        assertEq(uint256(log.topics[2]), callId, "longId");
        assertEq(address(uint160(uint256(log.topics[3]))), alice, "taker");
        Filled memory f = _decodeFilled(log);
        assertEq(f.maker, maker, "maker");
        assertEq(f.units, units, "units");
        assertEq(f.primary, primary, "primary");
        assertEq(f.takerIsBuyer, takerIsBuyer, "takerIsBuyer");
    }

    function _assertRecipient(Vm.Log memory log, address recipient) internal pure {
        assertEq(_decodeFilled(log).recipient, recipient, "OrderFilled.recipient is TakeParams.recipient");
    }

    function _assertNoBatch(Vm.Log[] memory logs) internal view {
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != TRANSFER_BATCH, "no TransferBatch");
        }
    }
}
