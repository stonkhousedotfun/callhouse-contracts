// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {V2IntegrationBase} from "./V2IntegrationBase.t.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Ids} from "../../../src/v2/interfaces/V2Ids.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";

/// @notice Gas of every user and keeper entry point on the full real stack, the source of docs/V2-GAS.md.
/// @dev Run: forge test --match-path test/v2/integration/V2Gas.t.sol -vv
///      Every figure is `vm.lastCallGas().gasTotalUsed` of one top-level call. foundry.toml sets `isolate = true`, so
///      that call runs as its own transaction and the figure is the gas the transaction is charged: the 21,000
///      intrinsic gas and calldata included, net of the EIP-3529 refund (capped at 1/5 of the gas spent). A full close
///      shows the refund: {test_gas_close} costs less for the whole position than for a part of it. Storage is warm or
///      cold exactly as a first-time or repeat user would find it; each line says which. The ceilings are loose and
///      only catch regressions.
///
///      Fixture: NVDA registered; traders alice, bob, carol, mm and five extra makers onboarded with 50 shares and
///      50,000 USDG on the ledger; call 220 and put 220 on Friday 2026-09-18 (E); the settlement window priced by the
///      feed (221.00 then 222.40) and followed by the pool, as in LifecycleTest.
contract V2GasTest is V2IntegrationBase {
    uint40 internal constant E = FRI_2026_09_18;
    uint128 internal constant K220 = 220_000_000;
    uint128 internal constant PRICE = 2_500_000;

    uint256 internal callId;
    uint256 internal putId;
    address[5] internal makers;

    function setUp() public override {
        super.setUp();
        _registerNvda();
        callId = ch.createSeries(address(nvda), false, K220, E);
        putId = ch.createSeries(address(nvda), true, K220, E);
        makers = [makeAddr("maker1"), makeAddr("maker2"), makeAddr("maker3"), makeAddr("maker4"), makeAddr("maker5")];
        address[4] memory traders = [alice, bob, carol, mm];
        for (uint256 i; i < 9; ++i) {
            address who = i < 4 ? traders[i] : makers[i - 4];
            if (i >= 4) _fund(who, ACTOR_USDG, ACTOR_SHARES, 0);
            _onboard(who);
            _deposit(who, address(nvda), 50e18);
            _deposit(who, address(usdg), 50_000e6);
        }
    }

    function _gas() internal view returns (uint256) {
        return vm.lastCallGas().gasTotalUsed;
    }

    function _log(string memory what, uint256 gasUsed, uint256 ceiling) internal pure {
        console2.log(string.concat("gas | ", what, " |"), gasUsed);
        assertLe(gasUsed, ceiling, what);
    }

    /*//////////////////////////////////////////////////////////////
                              CALIBRATION
    //////////////////////////////////////////////////////////////*/

    /// The smallest state change there is: setOperator on a fresh slot, one zero-to-non-zero SSTORE (22,100) and a log.
    /// Its 46.9k is 21,000 intrinsic + ~0.6k calldata + ~25k execution: the figures include the intrinsic gas.
    function test_gas_calibration() public {
        vm.prank(alice);
        ch.setOperator(bob, true);
        uint256 total = _gas();
        console2.log("gas | calibration: setOperator on a fresh slot |", total);
        assertGt(total, 21_000 + 22_100, "intrinsic gas + the SSTORE");
        assertLt(total, 50_000, "and little else");
    }

    /*//////////////////////////////////////////////////////////////
                              CLEARINGHOUSE
    //////////////////////////////////////////////////////////////*/

    function test_gas_mint() public {
        vm.prank(alice);
        ch.mint(callId, 100, alice, bob);
        _log("mint call, first supply of the series and first balances", _gas(), 240_000);
        vm.prank(alice);
        ch.mint(callId, 100, alice, bob);
        _log("mint call, repeat", _gas(), 110_000);
        vm.prank(alice);
        ch.mint(putId, 100, alice, bob);
        _log("mint put, first supply of the series", _gas(), 240_000);
    }

    function test_gas_close() public {
        vm.prank(alice);
        ch.mint(callId, 100, alice, alice);
        vm.prank(alice);
        ch.close(callId, 40);
        _log("close, partial", _gas(), 90_000);
        vm.prank(alice);
        ch.close(callId, 60);
        _log("close, whole position (balances and supply to zero)", _gas(), 90_000);
    }

    function test_gas_depositWithdraw() public {
        vm.prank(bob);
        ch.deposit(address(usdg), 1_000e6, bob);
        _log("deposit USDG, repeat depositor", _gas(), 90_000);
        vm.prank(bob);
        ch.withdraw(address(usdg), 1_000e6, bob);
        _log("withdraw USDG", _gas(), 90_000);
    }

    /*//////////////////////////////////////////////////////////////
                                 ORDERS
    //////////////////////////////////////////////////////////////*/

    function test_gas_place() public {
        vm.prank(alice);
        book.place(callId, WRITE, PRICE, 100, 0);
        _log("place AskWrite, maker's first order", _gas(), 230_000);
        vm.prank(alice);
        book.place(callId, WRITE, PRICE, 100, 0);
        _log("place AskWrite, repeat", _gas(), 200_000);
        vm.prank(bob);
        book.place(putId, BID, PRICE, 100, 0);
        _log("place Bid (USDG escrow)", _gas(), 260_000);
        vm.prank(carol);
        ch.mint(callId, 100, carol, carol);
        vm.prank(carol);
        book.place(callId, RESALE, PRICE, 100, 0);
        _log("place AskResale (ERC-1155 escrow)", _gas(), 280_000);
    }

    function test_gas_cancel() public {
        vm.prank(carol);
        ch.mint(callId, 100, carol, carol);
        uint256 w = _place(alice, callId, WRITE, PRICE, 100);
        uint256 b = _place(bob, putId, BID, PRICE, 100);
        uint256 r = _place(carol, callId, RESALE, PRICE, 100);
        vm.prank(alice);
        book.cancel(_ids(w));
        _log("cancel AskWrite", _gas(), 60_000);
        vm.prank(bob);
        book.cancel(_ids(b));
        _log("cancel Bid (USDG refund)", _gas(), 90_000);
        vm.prank(carol);
        book.cancel(_ids(r));
        _log("cancel AskResale (ERC-1155 refund)", _gas(), 90_000);
    }

    function test_gas_replace() public {
        uint256 w = _place(alice, callId, WRITE, PRICE, 100);
        vm.prank(alice);
        book.replace(w, PRICE + 100_000, 100);
        _log("replace AskWrite (reprice)", _gas(), 220_000);
    }

    /*//////////////////////////////////////////////////////////////
                                  TAKE
    //////////////////////////////////////////////////////////////*/

    /// A buy of 1 and of 5 orders of each ask kind from distinct makers, and a sale into 1 and 5 bids from inventory
    /// and by writing. Every take fills fresh orders; buyers and sellers have traded before (warm balances).
    function test_gas_take_oneAndFiveOrders() public {
        uint256[5] memory w;
        uint256[5] memory r;
        uint256[5] memory b;
        for (uint256 i; i < 5; ++i) {
            w[i] = _place(makers[i], callId, WRITE, PRICE, 10);
            vm.prank(makers[i]);
            ch.mint(callId, 20, makers[i], makers[i]);
            r[i] = _place(makers[i], callId, RESALE, PRICE, 10);
            b[i] = _place(makers[i], putId, BID, PRICE, 20);
        }
        uint256 w1 = _place(carol, callId, WRITE, PRICE, 10);
        vm.prank(carol);
        ch.mint(callId, 10, carol, carol);
        uint256 r1 = _place(carol, callId, RESALE, PRICE, 10);
        uint256 b1 = _place(carol, putId, BID, PRICE, 20);
        vm.prank(bob);
        ch.mint(putId, 60, bob, bob);
        // warm the takers' balances of both ids
        vm.prank(alice);
        ch.mint(callId, 1, alice, alice);

        vm.prank(alice);
        book.take(_buyParams(callId, _ids(w1), 10, 0, alice));
        _log("take buy AskWrite x1", _gas(), 300_000);
        vm.prank(alice);
        book.take(_buyParams(callId, _ids(w[0], w[1], w[2], w[3], w[4]), 50, 0, alice));
        _log("take buy AskWrite x5", _gas(), 650_000);
        vm.prank(alice);
        book.take(_buyParams(callId, _ids(r1), 10, 0, alice));
        _log("take buy AskResale x1", _gas(), 170_000);
        vm.prank(alice);
        book.take(_buyParams(callId, _ids(r[0], r[1], r[2], r[3], r[4]), 50, 0, alice));
        _log("take buy AskResale x5", _gas(), 400_000);
        vm.prank(bob);
        book.take(_sellParams(putId, _ids(b1), 10, false, bob));
        _log("take sell into Bid from inventory x1", _gas(), 200_000);
        vm.prank(bob);
        book.take(_sellParams(putId, _ids(b[0], b[1], b[2], b[3], b[4]), 50, false, bob));
        _log("take sell into Bid from inventory x5", _gas(), 520_000);
        vm.prank(mm);
        book.take(_sellParams(putId, _ids(b1), 10, true, mm));
        _log("take sell into Bid writeToSell x1", _gas(), 300_000);
        vm.prank(mm);
        book.take(_sellParams(putId, _ids(b[0], b[1], b[2], b[3], b[4]), 50, true, mm));
        _log("take sell into Bid writeToSell x5", _gas(), 650_000);
    }

    /*//////////////////////////////////////////////////////////////
                          SETTLEMENT (KEEPER)
    //////////////////////////////////////////////////////////////*/

    /// @dev Positions on both series, a resale ask and a bid left open, the window printed, time at E.
    function _positionsThroughExpiry() internal returns (uint256 resaleAsk, uint256 bid, uint256 writeAsk) {
        vm.prank(alice);
        ch.mint(callId, 100, alice, bob);
        vm.prank(carol);
        ch.mint(callId, 50, carol, mm);
        vm.prank(alice);
        ch.mint(putId, 100, alice, bob);
        vm.prank(carol);
        ch.mint(putId, 50, carol, mm);
        resaleAsk = _place(bob, callId, RESALE, PRICE, 20);
        bid = _place(mm, putId, BID, PRICE, 20);
        writeAsk = _place(alice, callId, WRITE, PRICE, 20);
        for (uint256 i; i < 5; ++i) {
            vm.prank(alice);
            ch.mint(callId, 10, alice, makers[i]);
        }

        vm.warp(E - 2 hours);
        _print(221_000_000, 222340, E - 2 hours);
        vm.warp(E - 900);
        _print(222_400_000, 222277, E - 900);
    }

    function test_gas_snapshotFinalizeSettle() public {
        _positionsThroughExpiry();
        vm.warp(E + 60);
        vm.prank(keeper);
        oracle.snapshot(address(nvda), E);
        _log("snapshot, pool records (+ SNAPSHOT bounty)", _gas(), 190_000);
        vm.prank(keeper);
        oracle.snapshot(address(nvda), E);
        _log("snapshot, repeat (nothing new)", _gas(), 60_000);

        vm.warp(E + V2Constants.FINALIZE_DELAY);
        vm.prank(keeper);
        oracle.finalize(address(nvda), E);
        _log("finalize, capture 2 sources + corroborated (+ FINALIZE bounty)", _gas(), 420_000);
        vm.prank(keeper);
        oracle.finalize(address(nvda), E);
        _log("finalize, already final", _gas(), 40_000);

        vm.prank(keeper);
        ch.settle(callId);
        _log("settle, oracle already final (+ SETTLE bounty)", _gas(), 170_000);
        vm.prank(keeper);
        ch.settle(callId);
        _log("settle, already settled", _gas(), 40_000);
    }

    /// No snapshot: finalize announces a Chainlink-only candidate, and settle itself finalizes it after the delay.
    function test_gas_finalizeCandidate_settleFinalizesInside() public {
        _positionsThroughExpiry();
        vm.warp(E + V2Constants.FINALIZE_DELAY);
        vm.prank(keeper);
        oracle.finalize(address(nvda), E);
        _log("finalize, capture + uncorroborated candidate (+ bounty)", _gas(), 420_000);
        vm.prank(keeper);
        oracle.finalize(address(nvda), E);
        _log("finalize, candidate inside its delay", _gas(), 60_000);

        vm.warp(E + V2Constants.FINALIZE_DELAY + 6 hours);
        vm.prank(keeper);
        ch.settle(putId);
        _log("settle, finalizing the candidate inside settle (+ SETTLE bounty)", _gas(), 260_000);
    }

    function test_gas_pruneRedeem() public {
        (uint256 resaleAsk, uint256 bid, uint256 writeAsk) = _positionsThroughExpiry();
        vm.warp(E + 60);
        oracle.snapshot(address(nvda), E);
        vm.warp(E + V2Constants.FINALIZE_DELAY);
        oracle.finalize(address(nvda), E);
        ch.settle(callId);
        ch.settle(putId);

        vm.prank(keeper);
        book.prune(_ids(resaleAsk));
        _log("prune 1 AskResale (ERC-1155 refund)", _gas(), 90_000);
        vm.prank(keeper);
        book.prune(_ids(bid, writeAsk));
        _log("prune Bid + AskWrite (USDG refund, no escrow)", _gas(), 110_000);

        vm.prank(keeper);
        ch.redeem(callId, bob);
        _log("redeem ITM call long, in kind to wallet (+ REDEEM bounty, keeper's first)", _gas(), 220_000);
        vm.prank(keeper);
        ch.redeem(V2Ids.shortIdOf(callId), alice);
        _log("redeem call short, in kind to wallet (+ REDEEM bounty)", _gas(), 200_000);
        vm.prank(keeper);
        ch.redeem(putId, bob);
        _log("redeem OTM put long, zero-value burn", _gas(), 90_000);
        vm.prank(keeper);
        ch.redeem(V2Ids.shortIdOf(putId), alice);
        _log("redeem put short, USDG to wallet (+ REDEEM bounty)", _gas(), 200_000);
        vm.prank(mm);
        ch.setPayoutToLedger(true);
        vm.prank(keeper);
        ch.redeem(callId, mm);
        _log("redeem ITM call long, to the ledger (0.765 USDG: under the bounty threshold)", _gas(), 200_000);

        address[] memory five = new address[](5);
        for (uint256 i; i < 5; ++i) {
            five[i] = makers[i];
        }
        address[] memory one = new address[](1);
        one[0] = carol;
        vm.prank(keeper);
        ch.redeemBatch(V2Ids.shortIdOf(callId), one);
        _log("redeemBatch 1 holder (call short + REDEEM bounty)", _gas(), 170_000);
        vm.prank(keeper);
        ch.redeemBatch(callId, five);
        _log("redeemBatch 5 holders (ITM call longs, in kind)", _gas(), 420_000);

        vm.prank(keeper);
        ch.sweepFees(address(nvda));
        _log("sweepFees NVDA", _gas(), 70_000);
    }

    function test_gas_ladderCreate() public {
        vm.prank(keeper);
        ch.createSeries(address(nvda), false, 230_000_000, E);
        _log("createSeries (spot band read through the oracle)", _gas(), 170_000);
        vm.prank(keeper);
        ch.createSeries(address(nvda), false, 230_000_000, E);
        _log("createSeries, existing id", _gas(), 40_000);
    }

    /// The first series of an expiry nobody has created a series for yet, then a second strike of that expiry.
    function test_gas_createSeries_firstAndLaterOfAnExpiry() public {
        vm.prank(keeper);
        ch.createSeries(address(nvda), false, 225_000_000, FRI_2026_09_11);
        _log("createSeries, first series of the expiry", _gas(), 400_000);
        vm.prank(keeper);
        ch.createSeries(address(nvda), true, 215_000_000, FRI_2026_09_11);
        _log("createSeries, later series of the same expiry", _gas(), 200_000);
    }

    function test_gas_takeTicketSizes() public {
        uint256 w = _place(alice, callId, WRITE, PRICE, 200);
        V2Types.TakeParams memory p = _buyParams(callId, _ids(w), 1, 0, bob);
        vm.prank(bob);
        book.take(p);
        _log("take buy AskWrite 1 unit, buyer's first long", _gas(), 400_000);
        p.units = 100;
        vm.prank(bob);
        book.take(p);
        _log("take buy AskWrite 100 units, repeat buyer", _gas(), 260_000);
    }

    /*//////////////////////////////////////////////////////////////
                   INTERFACE_VERSION 7: COLLATERAL RENT
    //////////////////////////////////////////////////////////////*/

    /// @dev What the rent costs, measured against the ppm-0 figures above on the same fixture. The suite's market is
    ///      registered at `mintFeePpm` 0 (v7 design §3.8: nobody moves a shared fixture's default), so these tests
    ///      re-register NVDA at NVDA's launch rate of 80 ppm and create their own series at it -- the rate is pinned
    ///      at creation, so a series made before the change would still be free.
    function _registerNvdaAtRent(uint32 ppm) internal returns (uint256 rentCallId, uint256 rentPutId) {
        V2Types.MarketConfig memory cfg = _nvdaMarket();
        cfg.mintFeePpm = ppm;
        vm.prank(admin);
        ch.setMarketConfig(address(nvda), cfg);
        rentCallId = ch.createSeries(address(nvda), false, 225_000_000, E);
        rentPutId = ch.createSeries(address(nvda), true, 225_000_000, E);
    }

    function test_gas_mint_withRent() public {
        (uint256 rentCallId, uint256 rentPutId) = _registerNvdaAtRent(80);
        vm.prank(alice);
        ch.mint(rentCallId, 100, alice, bob);
        _log("v7 mint call with rent, first supply of the series and first balances", _gas(), 250_000);
        vm.prank(alice);
        ch.mint(rentCallId, 100, alice, bob);
        _log("v7 mint call with rent, repeat", _gas(), 120_000);
        vm.prank(alice);
        ch.mint(rentPutId, 100, alice, bob);
        _log("v7 mint put with rent, first supply of the series", _gas(), 250_000);
        assertGt(ch.series(rentCallId).mintFeesHeld, 0, "rent was actually charged");
    }

    function test_gas_close_withRent() public {
        (uint256 rentCallId,) = _registerNvdaAtRent(80);
        vm.prank(alice);
        ch.mint(rentCallId, 100, alice, alice);
        vm.prank(alice);
        ch.close(rentCallId, 40);
        _log("v7 close with a rent refund, partial", _gas(), 100_000);
        vm.prank(alice);
        ch.close(rentCallId, 60);
        _log("v7 close with a rent refund, whole position", _gas(), 100_000);
    }

    /// @dev `createSeries` pays a 0 -> non-zero SSTORE on the appended slot when the market's rate is non-zero
    ///      (v7 design §3.5, accepted so `Series` appends rather than reorders).
    function test_gas_createSeries_withRent() public {
        V2Types.MarketConfig memory cfg = _nvdaMarket();
        cfg.mintFeePpm = 80;
        vm.prank(admin);
        ch.setMarketConfig(address(nvda), cfg);
        vm.prank(keeper);
        ch.createSeries(address(nvda), false, 225_000_000, FRI_2026_09_11);
        _log("v7 createSeries with rent, first series of the expiry", _gas(), 420_000);
        vm.prank(keeper);
        ch.createSeries(address(nvda), true, 215_000_000, FRI_2026_09_11);
        _log("v7 createSeries with rent, later series of the same expiry", _gas(), 220_000);
    }

    /// @dev A minting fill budgets and charges the rent: the OrderBook's plan carries the series' rate and expiry.
    function test_gas_take_withRent() public {
        (uint256 rentCallId,) = _registerNvdaAtRent(80);
        uint256 w = _place(alice, rentCallId, WRITE, PRICE, 200);
        V2Types.TakeParams memory p = _buyParams(rentCallId, _ids(w), 1, 0, bob);
        vm.prank(bob);
        book.take(p);
        _log("v7 take buy AskWrite 1 unit with rent, buyer's first long", _gas(), 420_000);
        p.units = 100;
        vm.prank(bob);
        book.take(p);
        _log("v7 take buy AskWrite 100 units with rent, repeat buyer", _gas(), 280_000);
    }

    /// @dev `settle` moves the rent it held to `accruedFees` and emits `MintFeesAccrued`; the asset's accrued slot is
    ///      already non-zero here (the exercise fee accrues in the same call), which is the cheaper of the two cases.
    function test_gas_settle_withRentHeld() public {
        (uint256 rentCallId,) = _registerNvdaAtRent(80);
        vm.prank(alice);
        ch.mint(rentCallId, 100, alice, bob);
        assertGt(ch.series(rentCallId).mintFeesHeld, 0, "rent is held before settlement");
        vm.warp(E - 2 hours);
        _print(221_000_000, 222340, E - 2 hours);
        vm.warp(E - 900);
        _print(222_400_000, 222277, E - 900);
        vm.warp(E + 60);
        vm.prank(keeper);
        oracle.snapshot(address(nvda), E);
        vm.warp(E + V2Constants.FINALIZE_DELAY);
        vm.prank(keeper);
        oracle.finalize(address(nvda), E);
        vm.prank(keeper);
        ch.settle(callId); // the ppm-0 series first, so accruedFees[nvda] is already warm
        vm.prank(keeper);
        ch.settle(rentCallId);
        _log("v7 settle with rent held (accrues and emits MintFeesAccrued)", _gas(), 260_000);
        assertEq(ch.series(rentCallId).mintFeesHeld, 0, "held is zero after settlement");
    }
}
