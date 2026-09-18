// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {OrderBookBaseTest, BookActor} from "./OrderBookBase.t.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";

/// @notice Fuzzed value conservation of OrderBook.take (C2-06, architecture §3.6 invariants): over random fee
///         parameters under the ceilings, order sizes, prices, kinds and wanted size,
///         - buying: USDG the taker pays == premium + taker fee == what makers and the fee recipient receive, and the
///           book keeps nothing;
///         - selling: USDG leaving bid escrow == premium == what the recipient, the bid makers and the fee recipient
///           receive, and what stays in the book is exactly the open bid escrow;
///         - units delivered == units filled == Σ OrderFilled units == Σ order fills; Σ rebates <= taker fee.
///      The selling case includes a bid maker that may reject ERC-1155 tokens, so fills skipped at execution (after
///      the plan priced the fee) are covered too.
contract OrderBookFuzzTest is OrderBookBaseTest {
    struct FeeInput {
        uint16 premium;
        uint16 resale;
        uint32 flat;
        uint16 cap;
        uint16 rebate;
    }

    struct LogSums {
        uint256 units;
        uint256 premium;
        uint256 sellerFees;
        uint256 rebates;
    }

    function testFuzz_take_buying_conservesValueAndUnits(
        FeeInput memory fin,
        uint16[3] memory sizes,
        uint32[3] memory ticks,
        uint8 kinds,
        uint16 wantSeed
    ) public {
        V2Types.FeeParams memory fees = _setFees(fin);
        address[3] memory makers = [bob, carol, mm];
        uint256[] memory ids = new uint256[](3);
        uint64[3] memory units;
        uint128[3] memory prices;
        for (uint256 i; i < 3; ++i) {
            units[i] = uint64(sizes[i] % 1000) + 1;
            prices[i] = (uint128(ticks[i]) % 100_000 + 1) * 100; // up to 100 USDG per share, on the tick grid
            bool write = (kinds >> i) & 1 == 1;
            if (!write) _mintLongs(makers[i], callId, units[i]);
            ids[i] = _place(makers[i], callId, write ? WRITE : RESALE, prices[i], units[i]);
        }
        uint64 want = uint64(wantSeed % 3500) + 1;

        uint256[5] memory before = _usdgOf(alice, bob, carol, mm, treasury);
        uint256 bookUsdg = usdg.balanceOf(address(book));
        vm.recordLogs();
        (uint64 filled, uint256 premium, uint256 takerFee) = _take(alice, _buy(callId, ids, want, keeper));
        LogSums memory sums = _sumFills(vm.getRecordedLogs());
        uint256[5] memory afterTake = _usdgOf(alice, bob, carol, mm, treasury);

        (uint64 expUnits, uint256 expPremium) = _expectedFills(units, prices, want, false);
        assertEq(filled, expUnits, "units filled in the caller's order");
        assertEq(premium, expPremium, "premium");
        assertEq(takerFee, _feeOf(premium, fees), "taker fee = min(flat, cap)");

        uint256 paidIn = before[0] - afterTake[0];
        uint256 paidOut = (afterTake[1] - before[1]) + (afterTake[2] - before[2]) + (afterTake[3] - before[3])
            + (afterTake[4] - before[4]);
        assertEq(paidIn, premium + takerFee, "taker pays premium + fee once");
        assertEq(paidOut, paidIn, "USDG in == USDG out + fees");
        assertEq(usdg.balanceOf(address(book)), bookUsdg, "book keeps nothing");

        assertEq(ch.balanceOf(keeper, callId), filled, "units delivered == units filled");
        assertEq(sums.units, filled, "sum of OrderFilled units");
        assertEq(sums.premium, premium, "sum of OrderFilled premium");
        assertLe(sums.rebates, takerFee, "rebates <= taker fee");
        assertEq(afterTake[4] - before[4], sums.sellerFees + takerFee - sums.rebates, "fee recipient share");

        uint256 fillSum;
        uint256 resaleLeft;
        for (uint256 i; i < 3; ++i) {
            V2Types.Order memory o = _order(ids[i]);
            fillSum += o.filled;
            if (o.kind == RESALE) resaleLeft += o.units - o.filled;
        }
        assertEq(fillSum, filled, "sum of order fills");
        assertEq(ch.balanceOf(address(book), callId), resaleLeft, "long escrow == open resale units");
    }

    function testFuzz_take_selling_conservesValueAndUnits(
        FeeInput memory fin,
        uint16[3] memory sizes,
        uint32[3] memory ticks,
        bool writeToSell,
        bool pickyRejects,
        uint16 wantSeed
    ) public {
        V2Types.FeeParams memory fees = _setFees(fin);
        BookActor picky = _newActor();
        address[3] memory makers = [bob, address(picky), carol];
        uint256[] memory ids = new uint256[](3);
        uint64[3] memory units;
        uint128[3] memory prices;
        for (uint256 i; i < 3; ++i) {
            units[i] = uint64(sizes[i] % 1000) + 1;
            prices[i] = (uint128(ticks[i]) % 100_000 + 1) * 100;
            ids[i] = _place(makers[i], callId, BID, prices[i], units[i]);
        }
        picky.setAcceptTokens(!pickyRejects);
        uint64 want = uint64(wantSeed % 3500) + 1;
        if (!writeToSell) _mintLongs(alice, callId, want);

        uint256[5] memory before = _usdgOf(keeper, bob, address(picky), carol, treasury);
        uint256 bookBefore = usdg.balanceOf(address(book));
        uint256 makerLongsBefore =
            ch.balanceOf(bob, callId) + ch.balanceOf(address(picky), callId) + ch.balanceOf(carol, callId);
        uint256 aliceLongs = ch.balanceOf(alice, callId);
        uint256 aliceShorts = ch.balanceOf(alice, callId | 1);

        vm.recordLogs();
        (uint64 filled, uint256 premium, uint256 takerFee) = _take(alice, _sell(callId, ids, want, writeToSell, keeper));
        LogSums memory sums = _sumFills(vm.getRecordedLogs());
        uint256[5] memory afterTake = _usdgOf(keeper, bob, address(picky), carol, treasury);

        // The picky bid is the second order; when it refuses the longs, the rest fills as if it had not been named.
        (uint64 expUnits, uint256 expPremium) = _expectedFills(units, prices, want, pickyRejects);
        assertEq(filled, expUnits, "units");
        assertEq(premium, expPremium, "premium");
        assertEq(takerFee, _feeOf(premium, fees), "taker fee on what filled");

        uint256 paidOut = (afterTake[0] - before[0]) + (afterTake[1] - before[1]) + (afterTake[2] - before[2])
            + (afterTake[3] - before[3]) + (afterTake[4] - before[4]);
        assertEq(bookBefore - usdg.balanceOf(address(book)), premium, "escrow released == premium");
        assertEq(paidOut, premium, "USDG in == USDG out + fees");
        assertEq(afterTake[0] - before[0], premium - takerFee - sums.sellerFees, "recipient proceeds");
        assertLe(sums.rebates, takerFee, "rebates <= taker fee");

        uint256 makerLongsAfter =
            ch.balanceOf(bob, callId) + ch.balanceOf(address(picky), callId) + ch.balanceOf(carol, callId);
        assertEq(makerLongsAfter - makerLongsBefore, filled, "units delivered == units filled");
        assertEq(sums.units, filled, "sum of OrderFilled units");
        if (writeToSell) {
            assertEq(ch.balanceOf(alice, callId | 1) - aliceShorts, filled, "taker wrote the shorts");
        } else {
            assertEq(aliceLongs - ch.balanceOf(alice, callId), filled, "taker delivered inventory");
        }

        uint256 openEscrow;
        for (uint256 i; i < 3; ++i) {
            V2Types.Order memory o = _order(ids[i]);
            openEscrow += uint256(o.price) * (o.units - o.filled) / 100;
        }
        assertEq(usdg.balanceOf(address(book)), openEscrow, "book USDG == open bid escrow");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _setFees(FeeInput memory fin) internal returns (V2Types.FeeParams memory f) {
        f = V2Types.FeeParams({
            premiumFeeBps: fin.premium % 1001,
            resaleFeeBps: fin.resale % 1001,
            takerFeeFlat: fin.flat % 1_000_001,
            takerFeeCapBps: fin.cap % 1001,
            makerRebateBps: fin.rebate % 10_001
        });
        vm.prank(admin);
        book.setFeeParams(f);
        // A fee change waits FEE_CHANGE_DELAY: the takes below run once it is in effect.
        vm.warp(START + V2Constants.FEE_CHANGE_DELAY);
        V2Types.FeeParams memory live = book.feeParams();
        assertEq(abi.encode(live), abi.encode(f), "fuzzed fees in effect");
    }

    function _feeOf(uint256 premium, V2Types.FeeParams memory f) internal pure returns (uint256) {
        uint256 byCap = premium * f.takerFeeCapBps / 10_000;
        return byCap < f.takerFeeFlat ? byCap : f.takerFeeFlat;
    }

    /// @dev Sequential fills in list order. With `skipSecond` the second order is refused at execution; the plan could
    ///      not foresee it, so the book re-plans from the next id and the result equals a take that never named it.
    function _expectedFills(uint64[3] memory units, uint128[3] memory prices, uint64 want, bool skipSecond)
        internal
        pure
        returns (uint64 filled, uint256 premium)
    {
        for (uint256 i; i < 3; ++i) {
            // Refused at execution: the book re-plans from the next id, so the take fills as if it were not named.
            if (i == 1 && skipSecond) continue;
            uint64 left = want - filled;
            uint64 fill = units[i] < left ? units[i] : left;
            filled += fill;
            premium += uint256(prices[i]) * fill / 100;
        }
    }

    function _sumFills(Vm.Log[] memory logs) internal view returns (LogSums memory s) {
        Vm.Log[] memory fills = _filledLogs(logs);
        for (uint256 i; i < fills.length; ++i) {
            Filled memory f = _decodeFilled(fills[i]);
            s.units += f.units;
            s.premium += f.premium;
            s.sellerFees += f.sellerFee;
            s.rebates += f.makerRebate;
        }
    }

    function _usdgOf(address a, address b, address c, address d, address e)
        internal
        view
        returns (uint256[5] memory out)
    {
        out = [usdg.balanceOf(a), usdg.balanceOf(b), usdg.balanceOf(c), usdg.balanceOf(d), usdg.balanceOf(e)];
    }
}
