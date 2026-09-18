// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MakerTestBase} from "./MakerBase.t.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MakerVault} from "../../../src/v2/mm/MakerVault.sol";

/// @notice MakerVault guard rails (C2-11): the intrinsic-value floor on asks, the bid cap, stale spot, the per-series
///         unit cap, the total notional cap and its bookkeeping, the live-order cap and the order lifetime bound.
contract MakerVaultGuardsTest is MakerTestBase {
    /*//////////////////////////////////////////////////////////////
                           ASK FLOOR (INTRINSIC)
    //////////////////////////////////////////////////////////////*/

    function test_askFloor_itmCall() public {
        _setSpot(address(nvda), 240_000_000);
        // intrinsic 240 - 230 = 10.00, tolerance 1 % of 240 = 2.40
        assertEq(vault.askFloor(callId), 7_600_000, "floor");
        vm.startPrank(quoter);
        vm.expectRevert(V2Errors.BadPrice.selector);
        vault.place(callId, WRITE, 7_599_900, 100, 0);
        vm.expectRevert(V2Errors.BadPrice.selector);
        vault.place(callId, RESALE, 7_599_900, 100, 0);
        vault.place(callId, WRITE, 7_600_000, 100, 0);
        vm.stopPrank();
    }

    function test_askFloor_itmPut() public {
        _setSpot(address(nvda), 200_000_000);
        // intrinsic 210 - 200 = 10.00, tolerance 2.00
        assertEq(vault.askFloor(putId), 8_000_000, "floor");
        _vaultLedger(address(usdg), 10_000e6);
        vm.startPrank(quoter);
        vm.expectRevert(V2Errors.BadPrice.selector);
        vault.place(putId, WRITE, 7_999_900, 100, 0);
        vault.place(putId, WRITE, 8_000_000, 100, 0);
        vm.stopPrank();
        assertEq(vault.askFloor(callId), 0, "the call is out of the money");
    }

    function test_askFloor_outOfTheMoneyAndInsideToleranceIsZero() public {
        assertEq(vault.askFloor(callId), 0, "OTM call");
        assertEq(vault.askFloor(putId), 0, "OTM put");
        _vaultPlace(callId, WRITE, 100, 1);
        _setSpot(address(nvda), 231_000_000);
        assertEq(vault.askFloor(callId), 0, "intrinsic 1.00 < tolerance 2.31");
    }

    function test_askFloor_replace() public {
        _setSpot(address(nvda), 240_000_000);
        uint256 id = _vaultPlace(callId, WRITE, 7_600_000, 100);
        _setSpot(address(nvda), 250_000_000);
        // intrinsic 20.00, tolerance 2.50
        vm.startPrank(quoter);
        vm.expectRevert(V2Errors.BadPrice.selector);
        vault.replace(id, 7_600_000, 100);
        vault.replace(id, 17_500_000, 100);
        vm.stopPrank();
    }

    function test_askFloor_sellingTakeLimit() public {
        _setSpot(address(nvda), 240_000_000);
        uint256 bobBid = _place(bob, callId, BID, 8_000_000, 100);
        _vaultLedger(address(nvda), 1e18);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadPrice.selector);
        vault.take(_sell(callId, _ids(bobBid), 100, 7_599_900, true, address(vault)));
        assertEq(_vaultTake(_sell(callId, _ids(bobBid), 100, 7_600_000, true, address(vault))), 100, "fills at 8.00");
    }

    function testFuzz_askFloor(uint256 spot, uint256 ticks, bool isPut) public {
        spot = bound(spot, 1_000_000, 1_000_000_000);
        uint128 price = uint128(bound(ticks, 1, 1_000_000) * 100);
        _setSpot(address(nvda), spot);
        uint256 strike = isPut ? PUT_STRIKE : CALL_STRIKE;
        uint256 intrinsic = isPut ? (strike > spot ? strike - spot : 0) : (spot > strike ? spot - strike : 0);
        uint256 tolerance = spot * ASK_TOLERANCE_BPS / 10_000;
        uint256 floor = intrinsic > tolerance ? intrinsic - tolerance : 0;
        uint256 longId = isPut ? putId : callId;
        assertEq(vault.askFloor(longId), floor, "view");

        vm.prank(quoter);
        if (price < floor) vm.expectRevert(V2Errors.BadPrice.selector);
        vault.place(longId, WRITE, price, 1, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                BID CAP
    //////////////////////////////////////////////////////////////*/

    function test_bidCap_place() public {
        assertEq(vault.bidCap(callId), 22_000_000, "10 % of 220");
        vm.startPrank(quoter);
        vm.expectRevert(V2Errors.BadPrice.selector);
        vault.place(callId, BID, 22_000_100, 10, 0);
        vault.place(callId, BID, 22_000_000, 10, 0);
        vm.stopPrank();
    }

    function test_bidCap_replaceFollowsSpot() public {
        uint256 id = _vaultPlace(callId, BID, 20_000_000, 10);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadPrice.selector);
        vault.replace(id, 22_000_100, 10);
        _setSpot(address(nvda), 250_000_000);
        vm.prank(quoter);
        vault.replace(id, 25_000_000, 10);
    }

    function test_bidCap_buyingTakeLimit() public {
        uint256 aliceAsk = _place(alice, callId, WRITE, 20_000_000, 100);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadPrice.selector);
        vault.take(_buy(callId, _ids(aliceAsk), 100, 22_000_100, address(vault)));
        assertEq(_vaultTake(_buy(callId, _ids(aliceAsk), 100, 22_000_000, address(vault))), 100, "fills at 20.00");
    }

    function test_bidCap_zeroStopsBuying() public {
        MakerVault.Limits memory l = _defaultLimits();
        l.maxBidBpsOfSpot = 0;
        vm.prank(admin);
        vault.setLimits(l);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadPrice.selector);
        vault.place(callId, BID, 100, 1, 0);
    }

    /*//////////////////////////////////////////////////////////////
                               STALE SPOT
    //////////////////////////////////////////////////////////////*/

    function test_staleSpotStopsQuotingButNotUnwinding() public {
        uint256 bidId = _vaultPlace(callId, BID, P2_00, 100);
        uint256 aliceAsk = _place(alice, callId, WRITE, P2_00, 100);
        _vaultLedger(address(usdg), 1_000e6);
        oracle.setSpot(address(nvda), false, 0, 0);

        vm.startPrank(quoter);
        vm.expectRevert(V2Errors.NoSource.selector);
        vault.place(callId, WRITE, P2_00, 1, 0);
        vm.expectRevert(V2Errors.NoSource.selector);
        vault.replace(bidId, P2_00, 50);
        vm.expectRevert(V2Errors.NoSource.selector);
        vault.take(_buy(callId, _ids(aliceAsk), 100, P2_00, address(vault)));
        vm.expectRevert(V2Errors.NoSource.selector);
        vault.askFloor(callId);

        vault.cancel(_ids(bidId));
        vault.withdrawFromClearinghouse(address(usdg), 1_000e6);
        vm.stopPrank();
        assertEq(usdg.balanceOf(address(vault)), VAULT_USDG, "unwound with no oracle");

        oracle.setSpot(address(nvda), true, 0, START);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.NoSource.selector);
        vault.place(callId, WRITE, P2_00, 1, 0);
    }

    /// @dev The same unwinding path with the two on-chain freezes on at once: no spot AND the outflow cap at 0 (the
    ///      admin's spend freeze, v7 design §4.6.4). Neither reads the other, so a cancel and a ledger move still
    ///      work; the price guard is what refuses new quotes, and it does so before the cap is ever consulted.
    function test_staleSpotAndZeroCapStillUnwind() public {
        uint256 bidId = _vaultPlace(callId, BID, P2_00, 100);
        _vaultLedger(address(usdg), 1_000e6);
        _setOutflowCap(0);
        oracle.setSpot(address(nvda), false, 0, 0);

        vm.startPrank(quoter);
        vm.expectRevert(V2Errors.NoSource.selector);
        vault.place(callId, BID, P2_00, 1, 0);
        vault.cancel(_ids(bidId));
        vault.withdrawFromClearinghouse(address(usdg), 1_000e6);
        vault.sync(_ids(callId));
        vault.claimOwed();
        vm.stopPrank();
        assertEq(usdg.balanceOf(address(vault)), VAULT_USDG, "unwound with no oracle and no outflow budget");
        (uint256 used,) = vault.outflow();
        assertEq(used, 0, "the cancel credited the escrow back even at cap 0");
    }

    /*//////////////////////////////////////////////////////////////
                             PER-SERIES CAP
    //////////////////////////////////////////////////////////////*/

    function test_seriesCap_bids() public {
        _vaultPlace(callId, BID, P2_00, 10_000);
        assertEq(_units(callId), 10_000);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        vault.place(callId, BID, P2_00, 1, 0);
    }

    function test_seriesCap_writeAsks() public {
        _vaultPlace(callId, WRITE, P2_00, 6_000);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        vault.place(callId, WRITE, P2_00, 4_001, 0);
        _vaultPlace(callId, WRITE, P2_00, 4_000);
        assertEq(_units(callId), 10_000);
    }

    function test_seriesCap_seriesAreIndependent() public {
        _vaultPlace(callId, BID, P2_00, 10_000);
        _vaultPlace(tslaId, BID, P2_00, 10_000);
        _vaultPlace(putId, WRITE, P2_00, 10_000);
        assertEq(vault.trackedSeries().length, 3);
    }

    function test_seriesCap_netsLongsAgainstShorts() public {
        _vaultLedger(address(nvda), 20e18);
        uint256 carolBid = _place(carol, callId, BID, P2_00, 2_000);
        _vaultTake(_sell(callId, _ids(carolBid), 2_000, P2_00, true, address(vault)));
        assertEq(_units(callId), 2_000, "net short 2,000");

        // up = bids 12,000 - shorts 2,000 = 10,000; down = shorts 2,000
        _vaultPlace(callId, BID, P2_00, 12_000);
        assertEq(_units(callId), 10_000, "a bid first buys the shorts back");
        vm.prank(quoter);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        vault.place(callId, BID, P2_00, 1, 0);
    }

    function test_seriesCap_buyingTake() public {
        uint256 aliceAsk = _place(alice, callId, WRITE, P2_00, 6_000);
        uint256 bobAsk = _place(bob, callId, WRITE, P2_00, 5_000);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        vault.take(_buy(callId, _ids(aliceAsk, bobAsk), 11_000, P2_00, address(vault)));
        assertEq(_vaultTake(_buy(callId, _ids(aliceAsk, bobAsk), 10_000, P2_00, address(vault))), 10_000, "at cap");
        assertEq(ch.balanceOf(address(vault), callId), 10_000);
    }

    function test_seriesCap_reducingActionsPassAboveTheCap() public {
        uint256 aliceAsk = _place(alice, callId, WRITE, P2_00, 8_000);
        _vaultTake(_buy(callId, _ids(aliceAsk), 8_000, P2_00, address(vault)));
        MakerVault.Limits memory l = _defaultLimits();
        l.maxSeriesUnits = 1_000;
        vm.prank(admin);
        vault.setLimits(l);

        vm.prank(quoter);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        vault.place(callId, BID, P2_00, 1, 0);

        uint256 carolBid = _place(carol, callId, BID, P2_00, 3_000);
        assertEq(_vaultTake(_sell(callId, _ids(carolBid), 3_000, P2_00, false, address(vault))), 3_000, "sold down");
        assertEq(_units(callId), 5_000, "still above the cap, but lower");
        _vaultPlace(callId, RESALE, P2_50, 5_000);
        assertEq(_units(callId), 5_000, "listing inventory does not grow the worst case");
        assertEq(vault.seriesNotional(callId), 5_000 * uint256(CALL_STRIKE) / 100);
    }

    /*//////////////////////////////////////////////////////////////
                          TOTAL NOTIONAL CAP
    //////////////////////////////////////////////////////////////*/

    function test_totalNotionalCap() public {
        MakerVault.Limits memory l = _defaultLimits();
        l.maxTotalNotional = 50_000e6;
        vm.prank(admin);
        vault.setLimits(l);

        _vaultPlace(callId, WRITE, P2_00, 10_000); // 10,000 x 230.00 / 100 = 23,000
        assertEq(vault.totalNotional(), 23_000e6);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        vault.place(tslaId, WRITE, P2_00, 7_501, 0); // 27,003.60 -> 50,003.60
        vm.expectEmit(address(vault));
        emit MakerVault.ExposureSet(tslaId, 7_500, 27_000e6, 50_000e6);
        _vaultPlace(tslaId, WRITE, P2_00, 7_500);
        assertEq(vault.totalNotional(), 50_000e6, "exactly at the cap");
        assertEq(vault.seriesNotional(tslaId), 27_000e6);
        assertEq(vault.trackedSeries().length, 2);
    }

    function test_totalNotional_syncReleasesExpiredOrders() public {
        MakerVault.Limits memory l = _defaultLimits();
        l.maxTotalNotional = 30_000e6;
        l.maxOrderLifetime = 1 hours;
        vm.prank(admin);
        vault.setLimits(l);

        _vaultPlace(callId, WRITE, P2_00, 10_000);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        vault.place(tslaId, WRITE, P2_00, 2_000, 0); // 7,200 -> 30,200

        vm.warp(START + 1 hours);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        vault.place(tslaId, WRITE, P2_00, 2_000, 0); // the expired call quote is still booked

        assertEq(_units(callId), 0, "the view sees the order expired");
        vm.prank(quoter);
        vault.sync(_ids(callId));
        assertEq(vault.totalNotional(), 0, "released");
        assertEq(vault.trackedSeries().length, 0);
        assertEq(vault.orderIdsOf(callId).length, 0, "expired id dropped");
        _vaultPlace(tslaId, WRITE, P2_00, 2_000);
    }

    /// An AskResale past its validUntil can no longer fill, but the book still holds its longs for the vault until a
    /// cancel or a prune hands them back, so they keep counting: an expired listing does not free the cap for a bid
    /// that would double the position once the longs come back (sweep contracts-c15).
    function test_seriesCap_expiredResaleEscrowStillCounts() public {
        uint256 aliceAsk = _place(alice, callId, WRITE, P2_00, 10_000);
        _vaultTake(_buy(callId, _ids(aliceAsk), 10_000, P2_00, address(vault)));
        vm.prank(quoter);
        // casting to uint40 is safe: START is a 2026 timestamp
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 resale = vault.place(callId, RESALE, P3_00, 10_000, uint40(START + 1 hours));
        assertEq(_units(callId), 10_000, "escrow counted while live");

        vm.warp(START + 1 hours);
        (uint256 units,, MakerVault.Exposure memory e) = vault.exposure(callId);
        assertEq(units, 10_000, "escrow still counted once expired");
        assertEq(e.resale, 10_000, "as resale escrow");
        assertEq(e.longs, 0, "none in the wallet");
        vm.prank(quoter);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        vault.place(callId, BID, P2_00, 1, 0);
        vm.prank(quoter);
        vault.sync(_ids(callId));
        assertEq(vault.seriesNotional(callId), 23_000e6, "sync keeps it");
        assertEq(vault.orderIdsOf(callId).length, 1, "the id is kept while its escrow is away");

        // Anyone's prune hands the longs back: the same exposure, now in the wallet, and the id is dropped.
        assertEq(book.prune(_ids(resale)), 1, "pruned");
        assertEq(ch.balanceOf(address(vault), callId), 10_000, "longs back");
        vm.prank(quoter);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        vault.place(callId, BID, P2_00, 1, 0);
        vm.prank(quoter);
        vault.sync(_ids(callId));
        assertEq(vault.seriesNotional(callId), 23_000e6, "unchanged");
        assertEq(vault.orderIdsOf(callId).length, 0, "pruned id dropped");
    }

    function test_totalNotional_cancelRefreshesEverySeriesTouched() public {
        uint256 a = _vaultPlace(callId, WRITE, P2_00, 1_000);
        uint256 b = _vaultPlace(tslaId, BID, P2_00, 1_000);
        uint256 c = _vaultPlace(callId, BID, P2_00, 500);
        assertEq(vault.totalNotional(), 2_300e6 + 3_600e6);
        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (a, b, c);
        vm.prank(quoter);
        vault.cancel(ids);
        assertEq(vault.totalNotional(), 0);
        assertEq(vault.trackedSeries().length, 0);
    }

    function test_takerFillsNeverRaiseTheStoredValue() public {
        uint256 bidId = _vaultPlace(callId, BID, P2_00, 1_000);
        uint256 stored = vault.seriesNotional(callId);
        _take(bob, _sell(callId, _ids(bidId), 600, P2_00, true, bob));
        (uint256 units, uint256 notional,) = vault.exposure(callId);
        assertEq(units, 1_000, "600 longs + 400 open bid");
        assertEq(notional, stored, "a fill moves units from the order to the position");

        uint256 carolBid = _place(carol, callId, BID, P2_00, 600);
        _vaultTake(_sell(callId, _ids(carolBid), 600, P2_00, false, address(vault)));
        assertEq(vault.seriesNotional(callId), 400 * uint256(CALL_STRIKE) / 100, "only the open bid is left");
    }

    /*//////////////////////////////////////////////////////////////
                        ORDER COUNT AND LIFETIME
    //////////////////////////////////////////////////////////////*/

    function test_liveOrderCapPerSeries() public {
        uint256 cap = vault.MAX_LIVE_ORDERS_PER_SERIES();
        uint256 first;
        for (uint256 i; i < cap; ++i) {
            // casting to uint128 is safe: i < 16
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 id = _vaultPlace(callId, WRITE, uint128(1_000_000 + i * 100), 1);
            if (i == 0) first = id;
        }
        vm.prank(quoter);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        vault.place(callId, WRITE, P3_00, 1, 0);
        _vaultPlace(tslaId, WRITE, P3_00, 1); // another series has its own budget

        _vaultLedger(address(nvda), 1e18);
        _take(alice, _buy(callId, _ids(first), 1, type(uint128).max, alice));
        _vaultPlace(callId, WRITE, P3_00, 1); // a filled order frees a slot
        assertEq(vault.orderIdsOf(callId).length, cap);
    }

    function test_orderLifetime() public {
        MakerVault.Limits memory l = _defaultLimits();
        l.maxOrderLifetime = 1 hours;
        vm.prank(admin);
        vault.setLimits(l);

        uint256 id = _vaultPlace(callId, WRITE, P2_00, 1);
        assertEq(_order(id).validUntil, START + 1 hours, "zero resolves to now + lifetime");
        vm.startPrank(quoter);
        vm.expectRevert(V2Errors.PastCutoff.selector);
        // casting to uint40 is safe: START is a 2026 timestamp
        // forge-lint: disable-next-line(unsafe-typecast)
        vault.place(callId, BID, P2_00, 1, uint40(START + 1 hours + 1));
        // forge-lint: disable-next-line(unsafe-typecast)
        id = vault.place(callId, BID, P2_00, 1, uint40(START + 30 minutes));
        vm.stopPrank();
        assertEq(_order(id).validUntil, START + 30 minutes, "an earlier bound is kept");

        uint40 cutoff = FRI_2026_09_18 - V2Constants.SETTLEMENT_WINDOW;
        // now + 1 h lands between the mint cutoff and the expiry (cutoff + 30 min)
        vm.warp(cutoff - 40 minutes);
        id = _vaultPlace(callId, WRITE, P2_00, 1);
        assertEq(_order(id).validUntil, cutoff, "never past the series limit (AskWrite: mint cutoff)");
        id = _vaultPlace(callId, BID, P2_00, 1);
        assertEq(_order(id).validUntil, cutoff + 20 minutes, "a bid's limit is the expiry, so now + lifetime applies");
    }

    /*//////////////////////////////////////////////////////////////
                           LIMITS AND VIEWS
    //////////////////////////////////////////////////////////////*/

    function test_setLimits_boundsAndEvent() public {
        MakerVault.Limits memory l = MakerVault.Limits({
            maxSeriesUnits: 1,
            maxTotalNotional: 2,
            askToleranceBps: 10_000,
            maxBidBpsOfSpot: 10_000,
            maxOrderLifetime: 3,
            maxDailyOutflow: 4
        });
        vm.expectEmit(address(vault));
        emit MakerVault.LimitsSet(l);
        vm.prank(admin);
        vault.setLimits(l);
        MakerVault.Limits memory got = vault.limits();
        assertEq(got.maxSeriesUnits, 1);
        assertEq(got.maxTotalNotional, 2);
        assertEq(got.maxOrderLifetime, 3);
        assertEq(got.maxDailyOutflow, 4, "the v7 field round-trips through the appended tuple");
        (uint256 used, uint256 available) = vault.outflow();
        assertEq(used, 0, "nothing spent yet");
        assertEq(available, 4, "and the new cap is what is available: maxDailyOutflow has no ceiling of its own");

        l.askToleranceBps = 10_001;
        vm.prank(admin);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        vault.setLimits(l);
        l.askToleranceBps = 0;
        l.maxBidBpsOfSpot = 10_001;
        vm.prank(admin);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        vault.setLimits(l);
    }

    function test_exposureDetail() public {
        _vaultLedger(address(nvda), 10e18);
        uint256 carolBid = _place(carol, callId, BID, P2_00, 300);
        _vaultTake(_sell(callId, _ids(carolBid), 300, P2_00, true, address(vault))); // 300 shorts
        uint256 aliceAsk = _place(alice, callId, WRITE, P2_00, 700);
        _vaultTake(_buy(callId, _ids(aliceAsk), 700, P2_00, address(vault))); // 700 longs
        _vaultPlace(callId, RESALE, P3_00, 200); // 500 longs in the wallet, 200 escrowed
        _vaultPlace(callId, BID, P2_00, 150);
        _vaultPlace(callId, WRITE, P3_00, 900);

        (uint256 units, uint256 notional, MakerVault.Exposure memory e) = vault.exposure(callId);
        assertEq(e.longs, 500);
        assertEq(e.shorts, 300);
        assertEq(e.resale, 200);
        assertEq(e.bids, 150);
        assertEq(e.writes, 900);
        assertEq(e.live, 3);
        // up = 500 + 200 + 150 - 300 = 550; down = 300 + 900 - 500 = 700
        assertEq(units, 700);
        assertEq(notional, 700 * uint256(CALL_STRIKE) / 100);
        assertEq(vault.seriesNotional(callId), notional);
    }

    function test_unknownSeriesRejected() public {
        vm.startPrank(quoter);
        vm.expectRevert(V2Errors.UnknownSeries.selector);
        vault.place(_short(callId), BID, P2_00, 1, 0);
        vm.expectRevert(V2Errors.UnknownSeries.selector);
        vault.place(12345, WRITE, P2_00, 1, 0);
        V2Types.TakeParams memory p = _buy(12345, new uint256[](0), 1, P2_00, address(vault));
        vm.expectRevert(V2Errors.UnknownSeries.selector);
        vault.take(p);
        vm.stopPrank();
    }
}
