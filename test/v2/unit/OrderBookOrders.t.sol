// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {OrderBookBaseTest, BookActor} from "./OrderBookBase.t.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {OrderBook} from "../../../src/v2/OrderBook.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {IMakerRegistry} from "../../../src/v2/interfaces/IMakerRegistry.sol";
import {IOrderBook} from "../../../src/v2/interfaces/IOrderBook.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MockClearinghouse} from "../../../src/v2/mocks/MockClearinghouse.sol";

/// @notice OrderBook resting orders (C2-06, architecture §3.6): construction and admin bounds, place / cancel /
///         replace for Bid, AskResale and AskWrite with the exact escrow each moves, validUntil resolution, narrow
///         delegates, prune, the trading pause (new risk only), paging, and the ERC-1155 receiver that accepts only the
///         book's own escrow transfers.
contract OrderBookOrdersTest is OrderBookBaseTest {
    uint40 internal constant CALL_CUTOFF = FRI_2026_09_18 - V2Constants.SETTLEMENT_WINDOW;

    /*//////////////////////////////////////////////////////////////
                          CONSTRUCTION AND ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_constructor_wiresRolesFeesAndOptsOutOfThirdPartyRedeem() public view {
        assertEq(book.clearinghouse(), address(ch), "clearinghouse");
        assertEq(address(book.usdg()), address(usdg), "usdg from the clearinghouse");
        assertEq(book.feeRecipient(), treasury, "fee recipient");
        V2Types.FeeParams memory f = book.feeParams();
        assertEq(f.premiumFeeBps, PREMIUM_FEE_BPS, "premium fee");
        assertEq(f.resaleFeeBps, RESALE_FEE_BPS, "resale fee");
        assertEq(f.takerFeeFlat, TAKER_FEE_FLAT, "taker flat");
        assertEq(f.takerFeeCapBps, TAKER_FEE_CAP_BPS, "taker cap");
        assertEq(f.makerRebateBps, MAKER_REBATE_BPS, "rebate");
        assertEq(book.authority(), address(manager), "the AccessManager is the authority");
        (bool isFeeManager,) = manager.hasRole(V8Roles.FEE_MANAGER, admin);
        assertTrue(isFeeManager, "admin is FEE_MANAGER for the book");
        (bool isTreasuryAdmin,) = manager.hasRole(V8Roles.TREASURY_ADMIN, admin);
        assertTrue(isTreasuryAdmin, "admin is TREASURY_ADMIN for the book");
        (bool isGuardian,) = manager.hasRole(V8Roles.GUARDIAN, guardian);
        assertTrue(isGuardian, "guardian is GUARDIAN for the book");
        (bool strangerAnything,) = manager.hasRole(V8Roles.FEE_MANAGER, stranger);
        assertFalse(strangerAnything, "stranger holds nothing");
        assertFalse(ch.thirdPartyRedeemAllowed(address(book)), "book opted out of third-party redeem");
        assertFalse(book.tradingPaused(), "not paused");
        assertEq(book.lastOrderId(), 0, "no orders");
        assertEq(address(book.makerRegistry()), address(0), "no registry");
        assertTrue(book.supportsInterface(type(IERC1155Receiver).interfaceId), "IERC1155Receiver");
        assertFalse(book.supportsInterface(type(IAccessControl).interfaceId), "v8: roles live on the manager");
        assertTrue(book.supportsInterface(type(IERC165).interfaceId), "IERC165");
        assertFalse(book.supportsInterface(0xffffffff), "not everything");
    }

    function test_constructor_emitsOptOutOnTheClearinghouse() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectEmit(address(ch));
        emit IClearinghouse.ThirdPartyRedeemSet(predicted, false);
        OrderBook fresh = new OrderBook(IClearinghouse(address(ch)), address(manager), treasury, _defaultFees());
        assertEq(address(fresh), predicted, "predicted address");
        assertEq(fresh.authority(), address(manager), "the fresh book points at the same manager");
    }

    function test_constructor_rejectsCodelessAuthorityAndBadRecipient() public {
        vm.expectRevert(V2Errors.NoSource.selector);
        new OrderBook(IClearinghouse(address(ch)), address(0), treasury, _defaultFees());
        vm.expectRevert(V2Errors.NoSource.selector);
        new OrderBook(IClearinghouse(address(ch)), makeAddr("eoa"), treasury, _defaultFees());
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        new OrderBook(IClearinghouse(address(ch)), address(manager), address(0), _defaultFees());
    }

    function test_constructor_rejectsCodelessUsdg() public {
        // T-488: the AUTHORITY must be a contract. `admin` is a code-less EOA (BaseV2Test), and MockClearinghouse
        // forwards its first argument to Managed(authority_), which reverts NoSource() on a code-less authority
        // (src/v2/access/Managed.sol). Passing `admin` here reverted on THIS line, before the expectRevert below was
        // armed, so the UnsupportedAsset guard in OrderBook's constructor was proven by nothing. The code-less address
        // this test actually needs is the usdg argument, and that is what makeAddr("noCode") is.
        MockClearinghouse odd =
            new MockClearinghouse(address(manager), makeAddr("noCode"), address(calendar), chFees, "");
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        new OrderBook(IClearinghouse(address(odd)), address(manager), treasury, _defaultFees());
    }

    function test_constructor_rejectsFeesAboveCeilings() public {
        for (uint256 field; field < 5; ++field) {
            vm.expectRevert(V2Errors.CeilingExceeded.selector);
            new OrderBook(IClearinghouse(address(ch)), address(manager), treasury, _feesAbove(field));
        }
    }

    function test_setFeeParams_onlyAdminAndUnderCeilings() public {
        V2Types.FeeParams memory atCeilings = V2Types.FeeParams({
            premiumFeeBps: V2Constants.PREMIUM_FEE_CEIL_BPS,
            resaleFeeBps: V2Constants.PREMIUM_FEE_CEIL_BPS,
            takerFeeFlat: V2Constants.TAKER_FEE_FLAT_CEIL,
            takerFeeCapBps: V2Constants.TAKER_FEE_CAP_CEIL_BPS,
            makerRebateBps: 10_000
        });
        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.setFeeParams(atCeilings);
        vm.prank(guardian);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.setFeeParams(atCeilings);

        for (uint256 field; field < 5; ++field) {
            vm.prank(admin);
            vm.expectRevert(V2Errors.CeilingExceeded.selector);
            book.setFeeParams(_feesAbove(field));
        }

        vm.expectEmit(address(book));
        emit IOrderBook.FeeParamsScheduled(atCeilings, START40 + V2Constants.FEE_CHANGE_DELAY);
        vm.prank(admin);
        book.setFeeParams(atCeilings);
        assertEq(book.feeParams().premiumFeeBps, PREMIUM_FEE_BPS, "scheduled, not yet in effect");

        vm.warp(START + V2Constants.FEE_CHANGE_DELAY);
        V2Types.FeeParams memory f = book.feeParams();
        assertEq(f.premiumFeeBps, 1000, "premium");
        assertEq(f.resaleFeeBps, 1000, "resale");
        assertEq(f.takerFeeFlat, 1_000_000, "flat");
        assertEq(f.takerFeeCapBps, 1000, "cap");
        assertEq(f.makerRebateBps, 10_000, "rebate");
    }

    function test_setFeeRecipient_onlyAdminNonZeroNotTheBook() public {
        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.setFeeRecipient(carol);
        vm.startPrank(admin);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.setFeeRecipient(address(0));
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.setFeeRecipient(address(book));
        vm.expectEmit(address(book));
        emit OrderBook.FeeRecipientSet(carol);
        book.setFeeRecipient(carol);
        vm.stopPrank();
        assertEq(book.feeRecipient(), carol, "recipient");
    }

    function test_setMakerRegistry_onlyAdminAndClearable() public {
        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.setMakerRegistry(registry);
        vm.startPrank(admin);
        vm.expectEmit(address(book));
        emit OrderBook.MakerRegistrySet(address(registry));
        book.setMakerRegistry(registry);
        assertEq(address(book.makerRegistry()), address(registry), "set");
        book.setMakerRegistry(IMakerRegistry(address(0)));
        vm.stopPrank();
        assertEq(address(book.makerRegistry()), address(0), "cleared");
    }

    function test_setTradingPaused_guardianOnly() public {
        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.setTradingPaused(true);

        // INTERFACE_VERSION 8: the pause is GUARDIAN's alone (v7 also accepted the admin). The fixture's admin holds
        // GUARDIAN as a member, so its call below passes as a guardian call, not an admin one.
        vm.expectEmit(address(book));
        emit IOrderBook.TradingPausedSet(true);
        vm.prank(guardian);
        book.setTradingPaused(true);
        assertTrue(book.tradingPaused(), "guardian paused");

        vm.prank(admin);
        book.setTradingPaused(false);
        assertFalse(book.tradingPaused(), "a guardian member resumed");
    }

    /*//////////////////////////////////////////////////////////////
                                 PLACE
    //////////////////////////////////////////////////////////////*/

    function test_place_bid_escrowsExactPremium() public {
        uint256 aliceBefore = usdg.balanceOf(alice);
        vm.expectEmit(address(book));
        emit IOrderBook.OrderPlaced(1, alice, callId, BID, P2_50, 40, FRI_2026_09_18);
        uint256 id = _place(alice, callId, BID, P2_50, 40);

        assertEq(id, 1, "first id");
        assertEq(book.lastOrderId(), 1, "lastOrderId");
        // 2.50 USDG per share * 40 units / 100 = 1.00 USDG
        assertEq(usdg.balanceOf(alice), aliceBefore - 1_000_000, "maker paid the escrow");
        assertEq(usdg.balanceOf(address(book)), 1_000_000, "book holds the escrow");
        V2Types.Order memory o = _order(id);
        assertEq(o.maker, alice, "maker");
        assertEq(o.longId, callId, "series");
        assertEq(uint8(o.kind), uint8(BID), "kind");
        assertEq(o.price, P2_50, "price");
        assertEq(o.units, 40, "units");
        assertEq(o.filled, 0, "filled");
        assertEq(o.validUntil, FRI_2026_09_18, "Bid defaults to expiry");
        assertFalse(o.cancelled, "live");
    }

    function test_place_put_bid_escrowsUsdgLikeACall() public {
        uint256 id = _place(bob, putId, BID, P3_00, 7);
        assertEq(usdg.balanceOf(address(book)), 210_000, "3.00 * 7 / 100 USDG");
        assertEq(_order(id).longId, putId, "put series");
    }

    function test_place_askResale_escrowsLongs() public {
        _mintLongs(alice, callId, 50);
        vm.expectEmit(address(book));
        emit IOrderBook.OrderPlaced(1, alice, callId, RESALE, P2_00, 30, FRI_2026_09_18);
        uint256 id = _place(alice, callId, RESALE, P2_00, 30);

        assertEq(ch.balanceOf(alice, callId), 20, "maker keeps the rest");
        assertEq(ch.balanceOf(address(book), callId), 30, "book escrows the longs");
        assertEq(usdg.balanceOf(address(book)), 0, "no USDG moves");
        assertEq(_order(id).validUntil, FRI_2026_09_18, "AskResale defaults to expiry");
    }

    function test_place_askWrite_escrowsNothing() public {
        uint256 freeBefore = ch.free(alice, address(nvda));
        uint256 usdgBefore = usdg.balanceOf(alice);
        vm.expectEmit(address(book));
        emit IOrderBook.OrderPlaced(1, alice, callId, WRITE, P2_50, 100, CALL_CUTOFF);
        uint256 id = _place(alice, callId, WRITE, P2_50, 100);

        assertEq(ch.free(alice, address(nvda)), freeBefore, "collateral untouched");
        assertEq(usdg.balanceOf(alice), usdgBefore, "USDG untouched");
        assertEq(ch.balanceOf(address(book), callId), 0, "no tokens");
        assertEq(_order(id).validUntil, CALL_CUTOFF, "AskWrite defaults to the mint cutoff");
    }

    function test_place_validUntil_explicitBoundsPerKind() public {
        vm.startPrank(alice);
        uint256 id = book.place(callId, BID, P2_50, 1, START40 + 1 hours);
        assertEq(_order(id).validUntil, START + 1 hours, "explicit kept");
        id = book.place(callId, BID, P2_50, 1, FRI_2026_09_18);
        assertEq(_order(id).validUntil, FRI_2026_09_18, "exactly expiry is fine");
        id = book.place(callId, WRITE, P2_50, 1, CALL_CUTOFF);
        assertEq(_order(id).validUntil, CALL_CUTOFF, "exactly the cutoff is fine");

        vm.expectRevert(V2Errors.PastCutoff.selector);
        book.place(callId, BID, P2_50, 1, FRI_2026_09_18 + 1);
        vm.expectRevert(V2Errors.PastCutoff.selector);
        book.place(callId, RESALE, P2_50, 1, FRI_2026_09_18 + 1);
        vm.expectRevert(V2Errors.PastCutoff.selector);
        book.place(callId, WRITE, P2_50, 1, CALL_CUTOFF + 1);
        vm.expectRevert(V2Errors.DeadlinePassed.selector);
        book.place(callId, BID, P2_50, 1, START40);
        vm.expectRevert(V2Errors.DeadlinePassed.selector);
        book.place(callId, WRITE, P2_50, 1, START40 - 1);
        vm.stopPrank();
    }

    function test_place_rejectsBadPriceUnitsAndSeries() public {
        vm.startPrank(alice);
        vm.expectRevert(V2Errors.BadPrice.selector);
        book.place(callId, BID, 0, 1, 0);
        vm.expectRevert(V2Errors.BadPrice.selector);
        book.place(callId, WRITE, 150, 1, 0);
        vm.expectRevert(V2Errors.BadPrice.selector);
        book.place(callId, RESALE, 2_500_001, 1, 0);
        vm.expectRevert(V2Errors.BadUnits.selector);
        book.place(callId, BID, P2_50, 0, 0);
        vm.expectRevert(V2Errors.UnknownSeries.selector);
        book.place(uint256(keccak256("no series")) & ~uint256(1), BID, P2_50, 1, 0);
        vm.expectRevert(V2Errors.UnknownSeries.selector);
        book.place(callId | 1, WRITE, P2_50, 1, 0);
        vm.stopPrank();
        assertEq(book.lastOrderId(), 0, "nothing placed");
    }

    function test_place_afterCutoffAskWriteRejected_afterExpiryEveryKind() public {
        _mintLongs(alice, callId, 10);
        vm.warp(CALL_CUTOFF);
        vm.startPrank(alice);
        vm.expectRevert(V2Errors.PastCutoff.selector);
        book.place(callId, WRITE, P2_50, 1, 0);
        uint256 bid = book.place(callId, BID, P2_50, 1, 0);
        uint256 ask = book.place(callId, RESALE, P2_50, 1, 0);
        assertEq(_order(bid).validUntil, FRI_2026_09_18, "bid still trades until expiry");
        assertEq(_order(ask).validUntil, FRI_2026_09_18, "resale still trades until expiry");

        vm.warp(FRI_2026_09_18);
        vm.expectRevert(V2Errors.PastCutoff.selector);
        book.place(callId, BID, P2_50, 1, 0);
        vm.expectRevert(V2Errors.PastCutoff.selector);
        book.place(callId, RESALE, P2_50, 1, 0);
        vm.stopPrank();
    }

    function test_place_needsTheMakersApprovals() public {
        _mintLongs(carol, callId, 10);
        vm.startPrank(carol);
        ch.setApprovalForAll(address(book), false);
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155MissingApprovalForAll.selector, address(book), carol)
        );
        book.place(callId, RESALE, P2_50, 10, 0);
        usdg.approve(address(book), 0);
        vm.expectRevert();
        book.place(callId, BID, P2_50, 10, 0);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                 CANCEL
    //////////////////////////////////////////////////////////////*/

    function test_cancel_bid_afterPartialFill_refundsTheRemainder() public {
        uint256 id = _place(alice, callId, BID, P2_50, 40); // 1.00 USDG escrow
        _mintLongs(bob, callId, 10);
        _take(bob, _sell(callId, _ids(id), 10, false, bob)); // uses 0.25 USDG of the escrow

        uint256 aliceBefore = usdg.balanceOf(alice);
        vm.expectEmit(address(book));
        emit IOrderBook.OrderCancelled(id, 30, false);
        vm.prank(alice);
        book.cancel(_ids(id));

        assertEq(usdg.balanceOf(alice), aliceBefore + 750_000, "30 units * 2.50 / 100 back");
        assertEq(usdg.balanceOf(address(book)), 0, "book emptied");
        assertTrue(_order(id).cancelled, "cancelled");
        assertEq(_order(id).filled, 10, "fill history kept");
    }

    function test_cancel_askResale_returnsTheRemainingLongs() public {
        _mintLongs(alice, callId, 50);
        uint256 id = _place(alice, callId, RESALE, P2_00, 50);
        _take(bob, _buy(callId, _ids(id), 20, bob));

        vm.expectEmit(address(book));
        emit IOrderBook.OrderCancelled(id, 30, false);
        vm.prank(alice);
        book.cancel(_ids(id));
        assertEq(ch.balanceOf(alice, callId), 30, "remaining longs back");
        assertEq(ch.balanceOf(bob, callId), 20, "buyer keeps his");
        assertEq(ch.balanceOf(address(book), callId), 0, "escrow emptied");
    }

    function test_cancel_askWrite_movesNothing() public {
        uint256 id = _place(alice, callId, WRITE, P2_50, 100);
        uint256 freeBefore = ch.free(alice, address(nvda));
        vm.expectEmit(address(book));
        emit IOrderBook.OrderCancelled(id, 100, false);
        vm.prank(alice);
        book.cancel(_ids(id));
        assertEq(ch.free(alice, address(nvda)), freeBefore, "collateral untouched");
        assertTrue(_order(id).cancelled, "cancelled");
    }

    function test_cancel_skipsCancelledAndFilled_revertsUnknown() public {
        uint256 a = _place(alice, callId, BID, P2_50, 10);
        uint256 b = _place(alice, callId, BID, P2_50, 10);
        uint256 filled = _place(alice, callId, WRITE, P2_50, 10);
        _take(bob, _buy(callId, _ids(filled), 10, bob));
        vm.prank(alice);
        book.cancel(_ids(a));

        vm.recordLogs();
        vm.prank(alice);
        book.cancel(_ids(a, filled, b));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 cancelled;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IOrderBook.OrderCancelled.selector) {
                ++cancelled;
                assertEq(uint256(logs[i].topics[1]), b, "only the live order");
            }
        }
        assertEq(cancelled, 1, "one OrderCancelled");
        assertFalse(_order(filled).cancelled, "a filled order stays as it is");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.OrderNotLive.selector, 999));
        book.cancel(_ids(999));
    }

    function test_cancel_onlyMakerOrAskWriteDelegate() public {
        uint256 id = _place(alice, callId, BID, P2_50, 10);
        vm.prank(bob);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.cancel(_ids(id));
    }

    function test_cancel_bid_frozenMaker_creditsOwed_thenClaims() public {
        uint256 id = _place(alice, callId, BID, P2_50, 40);
        usdg.freeze(alice);
        vm.prank(alice);
        book.cancel(_ids(id));
        assertEq(book.owed(alice), 1_000_000, "refund credited");
        assertEq(usdg.balanceOf(address(book)), 1_000_000, "still in the book");

        vm.prank(alice);
        vm.expectRevert(MockERC20.AddressFrozen.selector);
        book.claimOwed();

        usdg.unfreeze(alice);
        uint256 before = usdg.balanceOf(alice);
        vm.expectEmit(address(book));
        emit OrderBook.OwedClaimed(alice, 1_000_000);
        vm.prank(alice);
        book.claimOwed();
        assertEq(usdg.balanceOf(alice), before + 1_000_000, "claimed");
        assertEq(book.owed(alice), 0, "owed cleared");

        vm.recordLogs();
        vm.prank(alice);
        book.claimOwed();
        assertEq(vm.getRecordedLogs().length, 0, "nothing owed is a silent no-op");
    }

    /*//////////////////////////////////////////////////////////////
                                REPLACE
    //////////////////////////////////////////////////////////////*/

    function test_replace_bid_larger_pullsOnlyTheDifference() public {
        uint256 id = _place(alice, callId, BID, P2_50, 40); // 1.00 USDG
        uint256 before = usdg.balanceOf(alice);

        vm.expectEmit(address(book));
        emit IOrderBook.OrderCancelled(id, 40, false);
        vm.expectEmit(address(book));
        emit IOrderBook.OrderPlaced(2, alice, callId, BID, P3_00, 50, FRI_2026_09_18);
        vm.prank(alice);
        uint256 newId = book.replace(id, P3_00, 50); // 1.50 USDG

        assertEq(newId, 2, "new id");
        assertEq(usdg.balanceOf(alice), before - 500_000, "difference pulled");
        assertEq(usdg.balanceOf(address(book)), 1_500_000, "new escrow");
        assertTrue(_order(id).cancelled, "old cancelled");
        V2Types.Order memory o = _order(newId);
        assertEq(o.maker, alice, "maker kept");
        assertEq(o.longId, callId, "series kept");
        assertEq(uint8(o.kind), uint8(BID), "kind kept");
        assertEq(o.price, P3_00, "new price");
        assertEq(o.units, 50, "new units");
        assertEq(o.validUntil, FRI_2026_09_18, "validUntil kept");
    }

    function test_replace_bid_smaller_refundsTheDifference() public {
        uint256 id = _place(alice, callId, BID, P2_50, 40); // 1.00 USDG
        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        book.replace(id, P2_00, 10); // 0.20 USDG
        assertEq(usdg.balanceOf(alice), before + 800_000, "difference refunded");
        assertEq(usdg.balanceOf(address(book)), 200_000, "new escrow");
    }

    function test_replace_bid_afterPartialFill_pricesTheRemainder() public {
        uint256 id = _place(alice, callId, BID, P2_50, 40);
        _mintLongs(bob, callId, 30);
        _take(bob, _sell(callId, _ids(id), 30, false, bob)); // 10 units (0.25 USDG) left in escrow
        uint256 bookBefore = usdg.balanceOf(address(book));
        assertEq(bookBefore, 250_000, "remaining escrow");

        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        book.replace(id, P3_00, 10); // 0.30 USDG
        assertEq(usdg.balanceOf(alice), before - 50_000, "only the difference on the remainder");
        assertEq(usdg.balanceOf(address(book)), 300_000, "new escrow");
    }

    function test_replace_askResale_refundsAndReescrows() public {
        _mintLongs(alice, callId, 60);
        uint256 id = _place(alice, callId, RESALE, P2_00, 30);
        vm.prank(alice);
        uint256 up = book.replace(id, P3_00, 45);
        assertEq(ch.balanceOf(alice, callId), 15, "maker net -45");
        assertEq(ch.balanceOf(address(book), callId), 45, "escrow 45");

        vm.prank(alice);
        uint256 down = book.replace(up, P3_00, 10);
        assertEq(ch.balanceOf(alice, callId), 50, "maker net -10");
        assertEq(ch.balanceOf(address(book), callId), 10, "escrow 10");
        assertTrue(_order(up).cancelled, "intermediate cancelled");
        assertEq(_order(down).units, 10, "final units");
    }

    function test_replace_askWrite_keepsTheResolvedValidUntil() public {
        vm.prank(alice);
        uint256 id = book.place(callId, WRITE, P2_50, 100, START40 + 2 hours);
        vm.prank(alice);
        uint256 newId = book.replace(id, P2_00, 80);
        assertEq(_order(newId).validUntil, START + 2 hours, "validUntil carried over");
        assertEq(uint8(_order(newId).kind), uint8(WRITE), "kind kept");
    }

    function test_replace_rejects() public {
        uint256 id = _place(alice, callId, BID, P2_50, 10);
        uint256 filled = _place(alice, callId, WRITE, P2_50, 10);
        _take(bob, _buy(callId, _ids(filled), 10, bob));
        vm.prank(alice);
        uint256 shortLived = book.place(callId, BID, P2_50, 10, START40 + 1 hours);
        uint256 gone = _place(alice, callId, BID, P2_50, 10);
        vm.prank(alice);
        book.cancel(_ids(gone));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.OrderNotLive.selector, 999));
        book.replace(999, P2_50, 10);
        vm.prank(bob);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.replace(id, P2_50, 10);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.OrderNotLive.selector, filled));
        book.replace(filled, P2_50, 10);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.OrderNotLive.selector, gone));
        book.replace(gone, P2_50, 10);
        vm.expectRevert(V2Errors.BadPrice.selector);
        book.replace(id, 0, 10);
        vm.expectRevert(V2Errors.BadPrice.selector);
        book.replace(id, 2_500_050, 10);
        vm.expectRevert(V2Errors.BadUnits.selector);
        book.replace(id, P2_50, 0);
        vm.stopPrank();

        vm.warp(START + 1 hours);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.OrderNotLive.selector, shortLived));
        book.replace(shortLived, P2_50, 10);

        vm.prank(guardian);
        book.setTradingPaused(true);
        vm.prank(alice);
        vm.expectRevert(V2Errors.TradingPaused.selector);
        book.replace(id, P2_50, 10);
    }

    /*//////////////////////////////////////////////////////////////
                               DELEGATES
    //////////////////////////////////////////////////////////////*/

    function test_delegate_placesReplacesAndCancelsAskWriteForTheMaker() public {
        vm.expectEmit(address(book));
        emit IOrderBook.DelegateSet(alice, keeper, true);
        vm.prank(alice);
        book.setDelegate(keeper, true);
        assertTrue(book.isDelegate(alice, keeper), "delegate set");

        vm.expectEmit(address(book));
        emit IOrderBook.OrderPlaced(1, alice, callId, WRITE, P2_50, 100, CALL_CUTOFF);
        vm.prank(keeper);
        uint256 id = book.placeFor(alice, callId, WRITE, P2_50, 100, 0);
        (uint256[] memory mine,) = book.ordersOfMaker(alice, 0, 10);
        (uint256[] memory keepers,) = book.ordersOfMaker(keeper, 0, 10);
        assertEq(mine.length, 1, "listed under the maker");
        assertEq(keepers.length, 0, "not under the delegate");

        vm.prank(keeper);
        uint256 replaced = book.replace(id, P3_00, 80);
        assertEq(_order(replaced).maker, alice, "replacement belongs to the maker");

        // The maker's collateral backs what the delegate quoted.
        _take(bob, _buy(callId, _ids(replaced), 10, bob));
        assertEq(ch.balanceOf(alice, callId | 1), 10, "maker wrote the shorts");

        vm.prank(keeper);
        book.cancel(_ids(replaced));
        assertTrue(_order(replaced).cancelled, "delegate cancelled");
    }

    function test_delegate_cannotPlaceReplaceOrCancelBidsOrResaleAsks() public {
        vm.prank(alice);
        book.setDelegate(keeper, true);
        _mintLongs(alice, callId, 10);

        vm.startPrank(keeper);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.placeFor(alice, callId, BID, P2_50, 10, 0);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.placeFor(alice, callId, RESALE, P2_50, 10, 0);
        vm.stopPrank();

        uint256 bid = _place(alice, callId, BID, P2_50, 10);
        uint256 ask = _place(alice, callId, RESALE, P2_50, 10);
        vm.startPrank(keeper);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.replace(bid, P3_00, 10);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.replace(ask, P3_00, 10);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.cancel(_ids(bid));
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.cancel(_ids(ask));
        vm.stopPrank();
    }

    function test_delegate_revokedOrForeign_notAuthorized() public {
        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.placeFor(alice, callId, WRITE, P2_50, 10, 0);

        vm.prank(alice);
        book.setDelegate(keeper, true);
        vm.prank(keeper);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.placeFor(bob, callId, WRITE, P2_50, 10, 0);

        vm.prank(alice);
        book.setDelegate(keeper, false);
        assertFalse(book.isDelegate(alice, keeper), "revoked");
        vm.prank(keeper);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.placeFor(alice, callId, WRITE, P2_50, 10, 0);
    }

    function test_placeFor_selfMayPlaceEveryKind() public {
        _mintLongs(alice, callId, 5);
        vm.startPrank(alice);
        book.placeFor(alice, callId, BID, P2_50, 5, 0);
        book.placeFor(alice, callId, RESALE, P2_50, 5, 0);
        book.placeFor(alice, callId, WRITE, P2_50, 5, 0);
        vm.stopPrank();
        assertEq(book.lastOrderId(), 3, "three orders");
        assertEq(ch.balanceOf(address(book), callId), 5, "resale escrowed");
    }

    /*//////////////////////////////////////////////////////////////
                                 PRUNE
    //////////////////////////////////////////////////////////////*/

    function test_prune_refundsExpiredOrdersOfEveryKind_skipsTheRest() public {
        _mintLongs(alice, dailyId, 20);
        uint256 bid = _place(alice, dailyId, BID, P2_00, 20); // 0.40 USDG
        uint256 ask = _place(alice, dailyId, RESALE, P2_00, 20);
        uint256 write = _place(alice, dailyId, WRITE, P2_00, 20);
        uint256 live = _place(alice, callId, BID, P2_00, 10); // 0.20 USDG, next week
        uint256 cancelled = _place(bob, callId, BID, P2_00, 10);
        vm.prank(bob);
        book.cancel(_ids(cancelled));

        uint256 usdgBefore = usdg.balanceOf(alice);
        vm.warp(THU_2026_09_10);
        uint256[] memory ids = new uint256[](6);
        (ids[0], ids[1], ids[2], ids[3], ids[4], ids[5]) = (bid, ask, write, live, 999, cancelled);

        vm.expectEmit(address(book));
        emit IOrderBook.OrderCancelled(bid, 20, true);
        vm.expectEmit(address(book));
        emit IOrderBook.OrderCancelled(ask, 20, true);
        vm.expectEmit(address(book));
        emit IOrderBook.OrderCancelled(write, 20, true);
        vm.prank(keeper);
        uint256 pruned = book.prune(ids);

        assertEq(pruned, 3, "three expired orders");
        assertEq(usdg.balanceOf(alice), usdgBefore + 400_000, "bid escrow back");
        assertEq(ch.balanceOf(alice, dailyId), 20, "resale longs back");
        assertEq(ch.balanceOf(address(book), dailyId), 0, "no escrow left");
        assertEq(usdg.balanceOf(address(book)), 200_000, "live bid escrow stays");
        assertFalse(_order(live).cancelled, "live order untouched");

        vm.prank(keeper);
        assertEq(book.prune(ids), 0, "second prune is a no-op");
    }

    function test_prune_askWritePastCutoff_bidAndResaleStillLive() public {
        _mintLongs(alice, callId, 5);
        uint256 write = _place(alice, callId, WRITE, P2_50, 10);
        uint256 bid = _place(alice, callId, BID, P2_50, 10);
        uint256 ask = _place(alice, callId, RESALE, P2_50, 5);
        vm.warp(CALL_CUTOFF);
        vm.prank(keeper);
        assertEq(book.prune(_ids(write, bid, ask)), 1, "only the write-on-fill ask");
        assertTrue(_order(write).cancelled, "write pruned");
        assertFalse(_order(bid).cancelled, "bid live");
        assertFalse(_order(ask).cancelled, "resale live");
    }

    function test_prune_explicitValidUntilAndPartialFill() public {
        vm.prank(alice);
        uint256 id = book.place(callId, BID, P2_50, 40, START40 + 1 hours);
        _mintLongs(bob, callId, 10);
        _take(bob, _sell(callId, _ids(id), 10, false, bob));

        vm.prank(keeper);
        assertEq(book.prune(_ids(id)), 0, "still live");
        vm.warp(START + 1 hours);
        uint256 before = usdg.balanceOf(alice);
        vm.expectEmit(address(book));
        emit IOrderBook.OrderCancelled(id, 30, true);
        vm.prank(keeper);
        assertEq(book.prune(_ids(id)), 1, "expired at validUntil");
        assertEq(usdg.balanceOf(alice), before + 750_000, "remainder refunded");
    }

    function test_prune_makerRejectingReturnedTokens_isLeftAndOthersContinue() public {
        BookActor actor = _newActor();
        _mintLongs(address(actor), dailyId, 20);
        uint256 actorAsk = _place(address(actor), dailyId, RESALE, P2_00, 20);
        _mintLongs(alice, dailyId, 10);
        uint256 aliceAsk = _place(alice, dailyId, RESALE, P2_00, 10);
        actor.setAcceptTokens(false);

        vm.warp(THU_2026_09_10);
        vm.recordLogs();
        vm.prank(keeper);
        assertEq(book.prune(_ids(actorAsk, aliceAsk)), 1, "only alice's order");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IOrderBook.OrderCancelled.selector) {
                assertEq(uint256(logs[i].topics[1]), aliceAsk, "no log for the skipped order");
            }
        }
        assertFalse(_order(actorAsk).cancelled, "rejected refund leaves the order");
        assertEq(ch.balanceOf(address(book), dailyId), 20, "its escrow stays");
        assertEq(ch.balanceOf(alice, dailyId), 10, "alice refunded");

        // The maker's own cancel surfaces its receiver's revert.
        vm.prank(address(actor));
        vm.expectRevert(BookActor.Rejected.selector);
        book.cancel(_ids(actorAsk));

        actor.setAcceptTokens(true);
        vm.prank(keeper);
        assertEq(book.prune(_ids(actorAsk)), 1, "prunable once it accepts");
        assertEq(ch.balanceOf(address(actor), dailyId), 20, "longs back");
    }

    /// @dev Sweep contracts-c06. Uncapped, a maker whose hook burns all its gas took 63/64 of the batch's gas at its
    ///      first refund and the rest at its second, so the batch ran out of gas at any limit. Each refund is capped at
    ///      the book's delivery stipend, so each burning order costs the keeper at most that.
    function test_prune_makerBurningAllHookGas_costsAStipendPerOrder_othersPruned() public {
        BookActor burner = _newActor();
        _mintLongs(address(burner), dailyId, 20);
        uint256 first = _place(address(burner), dailyId, RESALE, P2_00, 10);
        uint256 second = _place(address(burner), dailyId, RESALE, P2_00, 10);
        _mintLongs(alice, dailyId, 10);
        uint256 aliceAsk = _place(alice, dailyId, RESALE, P2_00, 10);
        burner.setHookGas(type(uint256).max);

        vm.warp(THU_2026_09_10);
        vm.prank(keeper);
        assertEq(book.prune{gas: 1_500_000}(_ids(first, second, aliceAsk)), 1, "only alice's order");
        assertFalse(_order(first).cancelled || _order(second).cancelled, "burning refunds leave their orders");
        assertEq(ch.balanceOf(address(book), dailyId), 20, "their escrow stays");
        assertEq(ch.balanceOf(alice, dailyId), 10, "alice refunded");
    }

    function test_prune_bid_frozenMaker_creditsOwed() public {
        uint256 id = _place(alice, dailyId, BID, P2_50, 40);
        usdg.freeze(alice);
        vm.warp(THU_2026_09_10);
        vm.prank(keeper);
        assertEq(book.prune(_ids(id)), 1, "pruned despite the freeze");
        assertEq(book.owed(alice), 1_000_000, "refund owed");
    }

    /*//////////////////////////////////////////////////////////////
                                 PAUSE
    //////////////////////////////////////////////////////////////*/

    function test_pause_stopsNewRiskButNeverCancelPruneOrClaim() public {
        uint256 bid = _place(alice, callId, BID, P2_50, 10);
        uint256 daily = _place(alice, dailyId, BID, P2_50, 10);
        uint256 ask = _place(alice, callId, WRITE, P2_50, 10);
        vm.prank(alice);
        book.setDelegate(keeper, true);

        vm.prank(guardian);
        book.setTradingPaused(true);

        vm.startPrank(alice);
        vm.expectRevert(V2Errors.TradingPaused.selector);
        book.place(callId, BID, P2_50, 1, 0);
        vm.expectRevert(V2Errors.TradingPaused.selector);
        book.placeFor(alice, callId, WRITE, P2_50, 1, 0);
        vm.expectRevert(V2Errors.TradingPaused.selector);
        book.replace(bid, P3_00, 10);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(V2Errors.TradingPaused.selector);
        book.take(_buy(callId, _ids(ask), 1, bob));
        vm.prank(bob);
        vm.expectRevert(V2Errors.TradingPaused.selector);
        book.quoteTake(_buy(callId, _ids(ask), 1, bob));

        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        book.cancel(_ids(bid));
        assertEq(usdg.balanceOf(alice), before + 250_000, "cancel refunds while paused");
        vm.prank(keeper);
        book.cancel(_ids(ask));
        assertTrue(_order(ask).cancelled, "delegate cancel while paused");

        vm.warp(THU_2026_09_10);
        vm.prank(keeper);
        assertEq(book.prune(_ids(daily)), 1, "prune while paused");
        vm.prank(alice);
        book.claimOwed();

        vm.prank(guardian);
        book.setTradingPaused(false);
        _place(alice, callId, BID, P2_50, 1);
    }

    /*//////////////////////////////////////////////////////////////
                              ENUMERATION
    //////////////////////////////////////////////////////////////*/

    function test_enumeration_pagesSeriesAndMakerListsIncludingDeadOrders() public {
        uint256 a1 = _place(alice, callId, BID, P2_50, 1); // 1
        uint256 b1 = _place(bob, callId, BID, P2_50, 1); // 2
        uint256 a2 = _place(alice, callId, WRITE, P2_50, 1); // 3
        uint256 a3 = _place(alice, putId, BID, P2_50, 1); // 4
        uint256 b2 = _place(bob, callId, WRITE, P2_50, 1); // 5
        uint256 a4 = _place(alice, callId, WRITE, P2_50, 1); // 6
        vm.prank(alice);
        book.cancel(_ids(a4));

        assertEq(book.seriesOrderCount(callId), 5, "call series count");
        assertEq(book.seriesOrderCount(putId), 1, "put series count");
        assertEq(book.makerOrderCount(alice), 4, "alice count");
        assertEq(book.makerOrderCount(bob), 2, "bob count");

        (uint256[] memory page, uint256 next) = book.ordersOfSeries(callId, 0, 2);
        _assertPage(page, _ids(a1, b1), next, 2);
        (page, next) = book.ordersOfSeries(callId, next, 2);
        _assertPage(page, _ids(a2, b2), next, 4);
        (page, next) = book.ordersOfSeries(callId, next, 2);
        _assertPage(page, _ids(a4), next, 0);
        (page, next) = book.ordersOfSeries(callId, 0, 5);
        _assertPage(page, _ids(a1, b1, a2, b2, a4), next, 0);
        (page, next) = book.ordersOfSeries(callId, 0, 100);
        _assertPage(page, _ids(a1, b1, a2, b2, a4), next, 0);
        (page, next) = book.ordersOfSeries(callId, 5, 2);
        assertEq(page.length, 0, "cursor at the end");
        assertEq(next, 0, "done");
        (page, next) = book.ordersOfSeries(callId, 0, 0);
        assertEq(page.length, 0, "limit 0");
        assertEq(next, 0, "limit 0 done");
        (page, next) = book.ordersOfSeries(putId, 0, 10);
        _assertPage(page, _ids(a3), next, 0);
        (page, next) = book.ordersOfSeries(tslaId, 0, 10);
        assertEq(page.length, 0, "empty series");

        (page, next) = book.ordersOfMaker(alice, 0, 3);
        _assertPage(page, _ids(a1, a2, a3), next, 3);
        (page, next) = book.ordersOfMaker(alice, next, 3);
        _assertPage(page, _ids(a4), next, 0);
        (page, next) = book.ordersOfMaker(bob, 0, 10);
        _assertPage(page, _ids(b1, b2), next, 0);
        (page, next) = book.ordersOfMaker(carol, 0, 10);
        assertEq(page.length, 0, "no orders");

        V2Types.Order[] memory orders = book.getOrders(_ids(a4, 999, a1));
        assertEq(orders.length, 3, "one per id");
        assertTrue(orders[0].cancelled, "dead order readable");
        assertEq(orders[1].maker, address(0), "unknown id is a zero struct");
        assertEq(orders[1].units, 0, "unknown id units");
        assertEq(orders[2].maker, alice, "order kept");
    }

    /*//////////////////////////////////////////////////////////////
                           ERC-1155 RECEIVER
    //////////////////////////////////////////////////////////////*/

    function test_receiver_rejectsEveryTransferButItsOwnEscrow() public {
        _mintLongs(alice, callId, 10);
        vm.startPrank(alice);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        ch.safeTransferFrom(alice, address(book), callId, 1, "");
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        ch.safeBatchTransferFrom(alice, address(book), _ids(callId), _ids(1), "");
        vm.expectRevert(V2Errors.NotMinter.selector);
        ch.mint(callId, 1, alice, address(book));
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.onERC1155Received(address(book), alice, callId, 1, "");
        // Even the Clearinghouse naming the book as operator is refused when no escrow is expected.
        vm.prank(address(ch));
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.onERC1155Received(address(book), alice, callId, 1, "");
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.onERC1155BatchReceived(address(book), alice, _ids(callId), _ids(1), "");
        assertEq(ch.balanceOf(address(book), callId), 0, "nothing parked");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _assertPage(uint256[] memory page, uint256[] memory want, uint256 next, uint256 wantNext) internal pure {
        assertEq(page.length, want.length, "page length");
        for (uint256 i; i < want.length; ++i) {
            assertEq(page[i], want[i], "page id");
        }
        assertEq(next, wantNext, "next cursor");
    }
}
