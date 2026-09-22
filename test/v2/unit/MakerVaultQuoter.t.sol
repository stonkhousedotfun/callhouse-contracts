// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC1155Errors, IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MakerTestBase} from "./MakerBase.t.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";
import {IOrderBook} from "../../../src/v2/interfaces/IOrderBook.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MakerVault} from "../../../src/v2/mm/MakerVault.sol";

/// @notice MakerVault (C2-11): deployment wiring, admin treasury functions, every quoter path against the real
///         Clearinghouse and OrderBook, the proof that no quoter path names a recipient but the vault, and what a
///         compromised quoter key can still move out by trading.
contract MakerVaultQuoterTest is MakerTestBase {
    /*//////////////////////////////////////////////////////////////
                              DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    function test_constructor_wiresTheBookAndRoles() public view {
        assertEq(address(vault.clearinghouse()), address(ch), "clearinghouse from the book");
        assertEq(address(vault.orderBook()), address(book), "book");
        assertEq(address(vault.usdg()), address(usdg), "usdg from the clearinghouse");
        assertTrue(ch.isOperator(address(vault), address(book)), "book is the vault's operator (write-on-fill)");
        assertTrue(ch.isApprovedForAll(address(vault), address(book)), "book approved for ERC-1155 (escrow)");
        assertEq(usdg.allowance(address(vault), address(book)), type(uint256).max, "USDG allowance to the book");
        assertEq(usdg.allowance(address(vault), address(ch)), 0, "no standing allowance to the clearinghouse");
        assertTrue(ch.thirdPartyRedeemAllowed(address(vault)), "anyone may push the vault's redemptions");
        assertEq(vault.treasury(), treasury, "the constructor pinned the only exit");
        assertEq(vault.authority(), address(manager), "the AccessManager is the authority");
        assertTrue(vault.supportsInterface(type(IERC1155Receiver).interfaceId), "ERC-1155 receiver");
        assertTrue(vault.supportsInterface(type(IERC165).interfaceId), "ERC-165");
        // INTERFACE_VERSION 8: roles are not on the target any more, so AccessControl is no longer advertised.
        assertFalse(vault.supportsInterface(type(IAccessControl).interfaceId), "no AccessControl in v8");

        // The two lanes are disjoint on the manager: TREASURY_ADMIN cannot quote, QUOTER cannot reach the money.
        (bool adminIsTreasury,) = manager.hasRole(V8Roles.TREASURY_ADMIN, admin);
        (bool quoterIsTreasury,) = manager.hasRole(V8Roles.TREASURY_ADMIN, quoter);
        (bool quoterIsQuoter,) = manager.hasRole(V8Roles.QUOTER, quoter);
        assertTrue(adminIsTreasury, "admin holds TREASURY_ADMIN");
        assertTrue(quoterIsQuoter, "quoter holds QUOTER");
        assertFalse(quoterIsTreasury, "the mm-bot key is never in the treasury lane");
        assertEq(
            manager.getTargetFunctionRole(address(vault), MakerVault.withdraw.selector),
            V8Roles.TREASURY_ADMIN,
            "withdraw is TREASURY_ADMIN"
        );
        assertEq(
            manager.getTargetFunctionRole(address(vault), MakerVault.place.selector), V8Roles.QUOTER, "place is QUOTER"
        );

        MakerVault.Limits memory l = vault.limits();
        assertEq(l.maxSeriesUnits, MAX_SERIES_UNITS);
        assertEq(l.maxTotalNotional, MAX_TOTAL_NOTIONAL);
        assertEq(l.askToleranceBps, ASK_TOLERANCE_BPS);
        assertEq(l.maxBidBpsOfSpot, MAX_BID_BPS);
        assertEq(l.maxOrderLifetime, 0);
        assertEq(l.maxDailyOutflow, MAX_DAILY_OUTFLOW, "the launch outflow cap");
        assertEq(vault.OUTFLOW_WINDOW(), 1 days, "the refill window");
        (uint256 used, uint256 available) = vault.outflow();
        assertEq(used, 0, "a fresh vault has spent nothing");
        assertEq(available, MAX_DAILY_OUTFLOW, "the whole cap is available");
        assertEq(usdg.balanceOf(address(vault)), VAULT_USDG, "funded");
    }

    /// @dev INTERFACE_VERSION 8: a code-less authority is `NoSource` (a vault whose manager has no code could never
    ///      be gated and could never be repointed), a zero treasury is `NotAuthorized` (money must have an exit), and
    ///      the bps ceilings are unchanged.
    function test_constructor_rejectsBadAuthorityTreasuryAndLimits() public {
        vm.expectRevert(V2Errors.NoSource.selector);
        new MakerVault(IOrderBook(address(book)), address(0), treasury, _defaultLimits());
        vm.expectRevert(V2Errors.NoSource.selector);
        new MakerVault(IOrderBook(address(book)), makeAddr("eoaAuthority"), treasury, _defaultLimits());

        vm.expectRevert(V2Errors.NotAuthorized.selector);
        new MakerVault(IOrderBook(address(book)), address(manager), address(0), _defaultLimits());

        MakerVault.Limits memory l = _defaultLimits();
        l.askToleranceBps = 10_001;
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        new MakerVault(IOrderBook(address(book)), address(manager), treasury, l);
    }

    /*//////////////////////////////////////////////////////////////
                           TREASURY (ADMIN)
    //////////////////////////////////////////////////////////////*/

    /// @dev INTERFACE_VERSION 8: {MakerVault.deposit} is permissionless and {MakerVault.withdraw} pays {treasury}
    ///      and has no `to` argument at all, so the caller of an exit cannot choose where the money lands.
    function test_depositIsPermissionlessAndWithdrawOnlyEverPaysTheTreasury() public {
        _fund(stranger, 5_000e6, 0, 0);
        vm.startPrank(stranger);
        usdg.approve(address(vault), type(uint256).max);
        vm.expectEmit(address(vault));
        emit MakerVault.Deposited(address(usdg), stranger, 5_000e6);
        assertEq(vault.deposit(address(usdg), 5_000e6), 5_000e6, "a stranger may fund the vault");
        vm.stopPrank();
        assertEq(usdg.balanceOf(address(vault)), VAULT_USDG + 5_000e6);

        vm.expectEmit(address(vault));
        emit MakerVault.Withdrawn(address(usdg), treasury, 1_000e6);
        vm.prank(admin);
        vault.withdraw(address(usdg), 1_000e6);
        assertEq(usdg.balanceOf(treasury), 1_000e6, "treasury received");

        vm.prank(admin);
        vault.withdraw(address(nvda), 1e18);
        assertEq(nvda.balanceOf(treasury), 1e18, "any asset");

        // The v7 form with a free recipient is gone: nothing answers that selector any more.
        (bool ok,) = address(vault)
            .call(abi.encodeWithSignature("withdraw(address,uint256,address)", address(usdg), uint256(1), stranger));
        assertFalse(ok, "withdraw(address,uint256,address) is deleted in v8");
    }

    /// @dev Only TREASURY_ADMIN may move the exit, and it is never zero.
    function test_setTreasury_isTreasuryAdminOnlyAndNeverZero() public {
        address next = makeAddr("nextTreasury");
        vm.prank(quoter);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        vault.setTreasury(next);

        vm.prank(admin);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        vault.setTreasury(address(0));

        vm.expectEmit(address(vault));
        emit MakerVault.TreasurySet(next);
        vm.prank(admin);
        vault.setTreasury(next);
        assertEq(vault.treasury(), next, "moved");

        vm.prank(admin);
        vault.withdraw(address(usdg), 1);
        assertEq(usdg.balanceOf(next), 1, "and the exit follows it");
    }

    function test_admin_withdrawPositionRefreshesExposure() public {
        uint256 ask = _place(alice, callId, WRITE, P2_00, 100);
        _vaultTake(_buy(callId, _ids(ask), 100, P2_00, address(vault)));
        assertEq(vault.seriesNotional(callId), 100 * uint256(CALL_STRIKE) / 100, "100 longs stored");

        vm.expectEmit(address(vault));
        emit MakerVault.PositionWithdrawn(callId, treasury, 40);
        vm.prank(admin);
        vault.withdrawPosition(callId, 40);
        assertEq(ch.balanceOf(treasury, callId), 40, "treasury holds the longs");
        assertEq(vault.seriesNotional(callId), 60 * uint256(CALL_STRIKE) / 100, "refreshed to 60");
    }

    /// @dev The Admin Safe is a QUOTER member in `roles.v8.json`, so it can still cancel and close in an emergency.
    ///      What it no longer gets is an exemption from the outflow cap ({MakerVaultOutflowTest}).
    function test_admin_canDoWhatTheQuoterDoes() public {
        vm.prank(admin);
        uint256 id = vault.place(callId, BID, P2_00, 100, 0);
        vm.prank(admin);
        vault.cancel(_ids(id));
        assertTrue(_order(id).cancelled, "admin cancelled");
    }

    /// @dev Rotating a compromised quoter key is a manager call and never touches the vault (INTERFACE_VERSION 8).
    function test_revokedQuoterIsLockedOut() public {
        manager.revokeRole(V8Roles.QUOTER, quoter);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        vault.place(callId, BID, P2_00, 100, 0);
    }

    /*//////////////////////////////////////////////////////////////
                         CLEARINGHOUSE LEDGER
    //////////////////////////////////////////////////////////////*/

    function test_quoter_movesFundsIntoTheLedgerAndBackToTheVaultOnly() public {
        _vaultLedger(address(nvda), 10e18);
        assertEq(ch.free(address(vault), address(nvda)), 10e18, "ledger credited");
        assertEq(nvda.balanceOf(address(vault)), VAULT_SHARES - 10e18, "left the wallet");
        assertEq(nvda.allowance(address(vault), address(ch)), 0, "exact approval consumed");

        _vaultLedger(address(usdg), 1_000e6);
        vm.startPrank(quoter);
        vault.withdrawFromClearinghouse(address(nvda), 4e18);
        vault.withdrawFromClearinghouse(address(usdg), 1_000e6);
        vm.stopPrank();
        assertEq(ch.free(address(vault), address(nvda)), 6e18, "ledger debited");
        assertEq(nvda.balanceOf(address(vault)), VAULT_SHARES - 6e18, "back in the vault");
        assertEq(usdg.balanceOf(address(vault)), VAULT_USDG, "usdg back in the vault");
        assertEq(nvda.balanceOf(quoter) + usdg.balanceOf(quoter), 0, "nothing reached the quoter");

        vm.prank(quoter);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InsufficientCollateral.selector, 6e18, 7e18));
        vault.withdrawFromClearinghouse(address(nvda), 7e18);
    }

    /*//////////////////////////////////////////////////////////////
                                QUOTING
    //////////////////////////////////////////////////////////////*/

    function test_quoter_writeAskFilledPaysTheVault() public {
        _vaultLedger(address(nvda), 10e18);
        uint256 id = _vaultPlace(callId, WRITE, P2_00, 500);
        assertEq(_order(id).maker, address(vault), "vault is the maker");
        assertEq(vault.orderIdsOf(callId).length, 1, "remembered");
        assertEq(vault.seriesNotional(callId), 500 * uint256(CALL_STRIKE) / 100, "500 write units stored");

        _take(alice, _buy(callId, _ids(id), 200, P2_00, alice));

        // premium 4.00, seller fee 5 % = 0.20, taker fee min(0.10, 0.40) = 0.10, rebate 50 % of it = 0.05
        assertEq(usdg.balanceOf(address(vault)), VAULT_USDG + 3_850_000, "premium - fee + rebate");
        assertEq(ch.balanceOf(address(vault), _short(callId)), 200, "vault wrote 200");
        assertEq(ch.balanceOf(alice, callId), 200, "alice holds the longs");
        assertEq(ch.free(address(vault), address(nvda)), 8e18, "collateral locked from the vault ledger");
        (uint256 units, uint256 notional, MakerVault.Exposure memory e) = vault.exposure(callId);
        assertEq(e.shorts, 200);
        assertEq(e.writes, 300);
        assertEq(units, 500, "worst case unchanged by the fill");
        assertEq(notional, vault.seriesNotional(callId), "stored value is exact");
        assertEq(vault.trackedSeries().length, 1);
    }

    function test_quoter_bidThenResellInventoryThenCancel() public {
        uint256 bidId = _vaultPlace(callId, BID, P3_00, 300);
        assertEq(usdg.balanceOf(address(vault)), VAULT_USDG - 9e6, "bid escrow from the vault wallet");

        uint256 bobBefore = usdg.balanceOf(bob);
        _take(bob, _sell(callId, _ids(bidId), 300, P3_00, true, bob));
        assertEq(ch.balanceOf(address(vault), callId), 300, "vault received the longs (ERC-1155 receiver)");
        assertEq(usdg.balanceOf(bob) - bobBefore, 9e6 - 450_000 - 100_000, "bob's proceeds");
        assertEq(usdg.balanceOf(address(vault)), VAULT_USDG - 9e6 + 50_000, "bid maker gets the rebate");

        uint256 resaleId = _vaultPlace(callId, RESALE, P3_00, 300);
        assertEq(ch.balanceOf(address(book), callId), 300, "escrowed");
        assertEq(_units(callId), 300, "escrowed longs still count");

        _take(carol, _buy(callId, _ids(resaleId), 100, P3_00, carol));
        assertEq(usdg.balanceOf(address(vault)), VAULT_USDG - 9e6 + 50_000 + 3_050_000, "resale: no seller fee");

        vm.prank(quoter);
        vault.cancel(_ids(resaleId));
        assertEq(ch.balanceOf(address(vault), callId), 200, "escrow refunded to the vault");
        assertEq(vault.seriesNotional(callId), 200 * uint256(CALL_STRIKE) / 100, "cancel refreshed");
        assertEq(vault.orderIdsOf(callId).length, 0, "dead orders dropped");
    }

    function test_quoter_takesBuyingSellingAndWriteToSell() public {
        uint256 aliceAsk = _place(alice, callId, WRITE, P2_00, 100);
        assertEq(_vaultTake(_buy(callId, _ids(aliceAsk), 100, P2_00, address(vault))), 100, "bought");
        assertEq(ch.balanceOf(address(vault), callId), 100, "longs to the vault");
        assertEq(usdg.balanceOf(address(vault)), VAULT_USDG - 2_100_000, "premium + taker fee");

        uint256 bobBid = _place(bob, callId, BID, P2_50, 100);
        assertEq(_vaultTake(_sell(callId, _ids(bobBid), 100, P2_50, false, address(vault))), 100, "sold");
        assertEq(ch.balanceOf(bob, callId), 100, "longs to the bid maker");
        assertEq(usdg.balanceOf(address(vault)), VAULT_USDG - 2_100_000 + 2_400_000, "proceeds to the vault");

        _vaultLedger(address(nvda), 1e18);
        uint256 carolBid = _place(carol, callId, BID, P2_50, 50);
        assertEq(_vaultTake(_sell(callId, _ids(carolBid), 50, P2_50, true, address(vault))), 50, "wrote to sell");
        assertEq(ch.balanceOf(address(vault), _short(callId)), 50, "short to the vault");
        assertEq(ch.balanceOf(carol, callId), 50, "long to carol");
        assertEq(ch.free(address(vault), address(nvda)), 0.5e18, "minted from the vault ledger");
        assertEq(
            usdg.balanceOf(address(vault)), VAULT_USDG - 2_100_000 + 2_400_000 + 1_087_500, "primary fee on the write"
        );
        assertEq(vault.seriesNotional(callId), 50 * uint256(CALL_STRIKE) / 100, "net short 50");
    }

    function test_quoter_closesPairsAndPullsCollateralBack() public {
        _vaultLedger(address(nvda), 2e18);
        uint256 carolBid = _place(carol, callId, BID, P2_00, 100);
        _vaultTake(_sell(callId, _ids(carolBid), 100, P2_00, true, address(vault)));
        uint256 aliceAsk = _place(alice, callId, WRITE, P2_00, 100);
        _vaultTake(_buy(callId, _ids(aliceAsk), 100, P2_00, address(vault)));
        assertEq(vault.seriesNotional(callId), 0, "a pair nets to zero");
        assertEq(vault.trackedSeries().length, 0, "untracked");

        vm.prank(quoter);
        vault.close(callId, 100);
        assertEq(ch.balanceOf(address(vault), callId) + ch.balanceOf(address(vault), _short(callId)), 0, "burned");
        assertEq(ch.free(address(vault), address(nvda)), 2e18, "collateral freed to the vault ledger");

        vm.prank(quoter);
        vault.withdrawFromClearinghouse(address(nvda), 2e18);
        assertEq(nvda.balanceOf(address(vault)), VAULT_SHARES, "all shares back in the vault");
    }

    function test_quoter_replaceKeepsTheSeriesAndDropsTheOldId() public {
        _vaultLedger(address(nvda), 5e18);
        uint256 id = _vaultPlace(callId, WRITE, P2_00, 100);
        vm.prank(quoter);
        uint256 newId = vault.replace(id, P2_50, 300);
        assertTrue(_order(id).cancelled, "old cancelled");
        V2Types.Order memory o = _order(newId);
        assertEq(o.maker, address(vault));
        assertEq(o.price, P2_50);
        assertEq(o.units, 300);
        uint256[] memory ids = vault.orderIdsOf(callId);
        assertEq(ids.length, 1, "only the live replacement is remembered");
        assertEq(ids[0], newId);
        assertEq(vault.seriesNotional(callId), 300 * uint256(CALL_STRIKE) / 100, "replacement size stored");
    }

    function test_quoter_replaceRejectsForeignAndUnknownOrders() public {
        uint256 aliceAsk = _place(alice, callId, WRITE, P2_00, 100);
        vm.startPrank(quoter);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        vault.replace(aliceAsk, P2_50, 100);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.OrderNotLive.selector, 999));
        vault.replace(999, P2_50, 100);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        vault.cancel(_ids(aliceAsk));
        vm.stopPrank();
    }

    function test_quoter_claimOwedPaysTheVault() public {
        _vaultLedger(address(nvda), 1e18);
        uint256 id = _vaultPlace(callId, WRITE, P2_00, 100);
        usdg.freeze(address(vault));
        _take(alice, _buy(callId, _ids(id), 100, P2_00, alice));
        assertEq(book.owed(address(vault)), 1_950_000, "frozen vault: proceeds owed");
        usdg.unfreeze(address(vault));

        vm.prank(quoter);
        vault.claimOwed();
        assertEq(book.owed(address(vault)), 0);
        assertEq(usdg.balanceOf(address(vault)), VAULT_USDG + 1_950_000, "claimed into the vault");
    }

    function test_settledPositionsAndPrunedEscrowPayTheVault() public {
        uint256 aliceAsk = _place(alice, callId, WRITE, P2_00, 100);
        _vaultTake(_buy(callId, _ids(aliceAsk), 100, P2_00, address(vault)));
        uint256 resaleId = _vaultPlace(callId, RESALE, P3_00, 50);

        vm.warp(FRI_2026_09_18 + V2Constants.FINALIZE_DELAY);
        oracle.setSettlement(address(nvda), FRI_2026_09_18, V2Types.SettlementStatus.Finalized, 250_000_000);
        vm.startPrank(keeper);
        assertTrue(ch.settle(callId), "settled");
        assertEq(book.prune(_ids(resaleId)), 1, "escrow pruned");
        uint256 before = nvda.balanceOf(address(vault));
        ch.redeem(callId, address(vault));
        vm.stopPrank();

        assertEq(ch.balanceOf(address(vault), callId), 0, "redeemed");
        uint256 perUnit = ch.series(callId).longPayoutPerUnit;
        assertGt(perUnit, 0, "ITM");
        assertEq(nvda.balanceOf(address(vault)) - before, 100 * perUnit, "a keeper pushed the payout to the vault");

        vm.prank(quoter);
        vault.sync(_ids(callId));
        assertEq(vault.totalNotional(), 0, "sync clears a redeemed series");
        assertEq(vault.orderIdsOf(callId).length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                 NO RECIPIENT BUT THE VAULT, AND TURNOVER
    //////////////////////////////////////////////////////////////*/

    function testFuzz_takeMustNameTheVault(address recipient, bool buying) public {
        vm.assume(recipient != address(vault));
        uint256 id = buying ? _place(alice, callId, WRITE, P2_00, 100) : _place(alice, callId, BID, P2_00, 100);
        _vaultLedger(address(nvda), 1e18);
        V2Types.TakeParams memory p = buying
            ? _buy(callId, _ids(id), 100, P2_00, recipient)
            : _sell(callId, _ids(id), 100, P2_00, true, recipient);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        vault.take(p);
    }

    /// @dev The quoter lane cannot reach the money lane, and the vault has no role table left to attack: v7's
    ///      `grantRole` / `revokeRole` / `setAuthority` are either gone or the manager's own.
    function test_quoterCannotReachTreasuryOrRoles() public {
        MakerVault.Limits memory loose = _defaultLimits();
        loose.maxBidBpsOfSpot = 10_000;
        vm.startPrank(quoter);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        vault.withdraw(address(usdg), 1);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        vault.withdrawPosition(callId, 1);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        vault.setLimits(loose);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        vault.setTreasury(quoter);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        vault.setAuthority(quoter);
        vm.stopPrank();

        bytes[2] memory goneWithAccessControl = [
            abi.encodeWithSignature("grantRole(bytes32,address)", V2Constants.QUOTER_ROLE, stranger),
            abi.encodeWithSignature("revokeRole(bytes32,address)", V2Constants.DEFAULT_ADMIN_ROLE, admin)
        ];
        for (uint256 i; i < goneWithAccessControl.length; ++i) {
            vm.prank(quoter);
            (bool ok,) = address(vault).call(goneWithAccessControl[i]);
            assertFalse(ok, "v7 AccessControl entry point must not exist on a v8 target");
        }
    }

    function test_strangerCannotQuote() public {
        uint256[] memory none = new uint256[](0);
        V2Types.TakeParams memory p = _buy(callId, none, 1, P2_00, address(vault));
        vm.startPrank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        vault.depositToClearinghouse(address(usdg), 1);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        vault.withdraw(address(usdg), 1);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        vault.withdrawFromClearinghouse(address(usdg), 1);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        vault.place(callId, BID, P2_00, 1, 0);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        vault.replace(1, P2_00, 1);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        vault.cancel(none);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        vault.take(p);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        vault.close(callId, 1);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        vault.claimOwed();
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        vault.sync(none);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        vault.refreshApprovals();
        vm.stopPrank();
    }

    /// @dev The vault has no fallback and none of the entry points that would hand value or rights to someone else.
    function test_noEntryPointMovesValueElsewhere() public {
        bytes[10] memory calls = [
            abi.encodeWithSignature("setDelegate(address,bool)", quoter, true),
            abi.encodeWithSignature("setOperator(address,bool)", quoter, true),
            abi.encodeWithSignature("setApprovalForAll(address,bool)", quoter, true),
            abi.encodeWithSignature("mint(uint256,uint64,address,address)", callId, 1, address(vault), quoter),
            abi.encodeWithSignature("transfer(address,uint256)", quoter, 1),
            abi.encodeWithSignature("approve(address,uint256)", quoter, 1),
            abi.encodeWithSignature(
                "safeTransferFrom(address,address,uint256,uint256,bytes)", address(vault), quoter, callId, 1, ""
            ),
            abi.encodeWithSignature(
                "placeFor(address,uint256,uint8,uint128,uint64,uint40)", quoter, callId, 0, P2_00, 1, 0
            ),
            abi.encodeWithSignature("execute(address,bytes)", address(usdg), ""),
            abi.encodeWithSignature("multicall(bytes[])", new bytes[](0))
        ];
        vm.startPrank(quoter);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(vault).call(calls[i]);
            assertFalse(ok, string.concat("call ", vm.toString(i), " must not exist"));
        }
        vm.stopPrank();
    }

    /// @dev What the price and size guards do not bound, and what the outflow cap does. A compromised quoter buys a
    ///      partner's ask at the bid cap and sells the longs back into the partner's one-tick bid: every trade passes
    ///      the price guard, exposure is back to 0 after each round trip and every token and payment is the vault's,
    ///      yet the premium difference is the partner's (sweep contracts-c14). Before INTERFACE_VERSION 7 the loop ran
    ///      until QUOTER_ROLE was revoked; this test is the v7 replacement of
    ///      `test_compromisedQuoter_roundTripsMoveVaultUsdgToAPartner`, and it now stops on the second round trip with
    ///      OutflowCapExceeded, because the first spent 2,200.10 of the 2,500 USDG cap (v7 design §4.6, §6.1).
    function test_compromisedQuoter_partnerIsHeldToTheOutflowCap() public {
        address partner = carol;
        uint128 cap = uint128(vault.bidCap(callId));
        assertEq(cap, 22_000_000, "bid cap: 10 % of 220");
        uint256 vaultBefore = usdg.balanceOf(address(vault));
        uint256 partnerBefore = usdg.balanceOf(partner) + ch.free(partner, address(usdg));

        uint256 ask = _place(partner, callId, WRITE, cap, 10_000);
        assertEq(_vaultTake(_buy(callId, _ids(ask), 10_000, cap, address(vault))), 10_000, "bought at the cap");
        assertEq(_used(), 2_200_100_000, "22.00 a share plus the 0.10 taker fee");
        uint256 bid = _place(partner, callId, BID, 100, 10_000);
        assertEq(_vaultTake(_sell(callId, _ids(bid), 10_000, 100, false, address(vault))), 10_000, "sold at 0.01");
        assertEq(_units(callId), 0, "no exposure left");
        assertEq(_used(), 2_200_091_000, "the 0.009 the sale brought back in is credited");
        vm.prank(partner);
        ch.close(callId, 10_000);

        // Round two is refused on the leg that pays the partner, before any USDG moves.
        uint256 ask2 = _place(partner, callId, WRITE, cap, 10_000);
        vm.prank(quoter);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.OutflowCapExceeded.selector, 299_909_000, 2_200_100_000));
        vault.take(_buy(callId, _ids(ask2), 10_000, cap, address(vault)));

        uint256 lost = vaultBefore - usdg.balanceOf(address(vault));
        uint256 gained = usdg.balanceOf(partner) + ch.free(partner, address(usdg)) - partnerBefore;
        assertGt(lost, 2_190e6, "one round trip still moved 22.00 minus 0.01 a share");
        assertLe(lost, MAX_DAILY_OUTFLOW, "and never more than the cap before a refill");
        assertGt(gained, 2_000e6, "the partner kept it, less the book's fees");
        assertEq(ch.balanceOf(address(vault), callId) + ch.balanceOf(address(vault), _short(callId)), 0, "no tokens");
        assertEq(vault.totalNotional(), 0, "no stored exposure");
    }

    /// @dev The same turnover needs no partner and no capital: with 1 USDG the key holder bids one tick, the vault
    ///      writes the OTM call into that bid from its own collateral (the ask floor is 0), the key holder rests the
    ///      longs at the bid cap, the vault buys them back and closes the pair (sweep contracts-c21). This is the v7
    ///      replacement of `test_compromisedQuoter_aloneNeedsNoCapital`: the collateral is still free again after
    ///      every round trip, but the buy-back leg of the second one reverts OutflowCapExceeded, and only a full day's
    ///      refill buys the key holder another one — the 2x-the-cap-per-24-h bound of v7 design §4.6.4.
    function test_compromisedQuoter_aloneIsHeldToTheOutflowCap() public {
        uint128 cap = uint128(vault.bidCap(callId));
        assertEq(vault.askFloor(callId), 0, "OTM call: no ask floor");
        _vaultLedger(address(nvda), 100e18);
        usdg.mint(quoter, 1e6);
        vm.startPrank(quoter);
        usdg.approve(address(book), type(uint256).max);
        ch.setApprovalForAll(address(book), true);
        vm.stopPrank();
        uint256 vaultBefore = usdg.balanceOf(address(vault));

        _loop(cap);
        assertEq(_used(), 2_200_100_000, "one round trip spends 2,200.10 of the cap");
        assertEq(_available(), 299_900_000, "and leaves 299.90");

        // The second round trip: the vault may still write (that brings USDG in), but not buy the longs back.
        uint256 bid2 = _place(quoter, callId, BID, 100, 10_000);
        assertEq(_vaultTake(_sell(callId, _ids(bid2), 10_000, 100, true, address(vault))), 10_000, "wrote at 0.01");
        assertEq(_available(), 299_908_500, "the sale credited its 0.0085 back");
        uint256 ask2 = _place(quoter, callId, RESALE, cap, 10_000);
        vm.prank(quoter);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.OutflowCapExceeded.selector, 299_908_500, 2_200_100_000));
        vault.take(_buy(callId, _ids(ask2), 10_000, cap, address(vault)));
        assertLe(vaultBefore - usdg.balanceOf(address(vault)), MAX_DAILY_OUTFLOW, "at most the cap before a refill");

        // A full window refills the bucket and the held-up leg goes through: at most 2x the cap in 24 h.
        vm.warp(block.timestamp + OUTFLOW_WINDOW);
        assertEq(_used(), 0, "the bucket refilled");
        assertEq(_vaultTake(_buy(callId, _ids(ask2), 10_000, cap, address(vault))), 10_000, "bought at the cap");
        vm.prank(quoter);
        vault.close(callId, 10_000);
        assertLe(vaultBefore - usdg.balanceOf(address(vault)), 2 * uint256(MAX_DAILY_OUTFLOW), "<= 2x cap in 24 h");
        assertEq(_units(callId), 0, "no exposure left");
        assertEq(ch.free(address(vault), address(nvda)), 100e18, "the collateral is free again");
        assertEq(ch.balanceOf(quoter, callId) + ch.balanceOf(quoter, _short(callId)), 0, "no tokens kept");
    }

    /// @dev One capital-free round trip of {test_compromisedQuoter_aloneIsHeldToTheOutflowCap}: the vault writes into
    ///      the key holder's one-tick bid, buys the longs back at the bid cap and closes the pair.
    function _loop(uint128 cap) private {
        uint256 bid = _place(quoter, callId, BID, 100, 10_000);
        assertEq(_vaultTake(_sell(callId, _ids(bid), 10_000, 100, true, address(vault))), 10_000, "wrote at 0.01");
        uint256 ask = _place(quoter, callId, RESALE, cap, 10_000);
        assertEq(_vaultTake(_buy(callId, _ids(ask), 10_000, cap, address(vault))), 10_000, "bought at the cap");
        vm.prank(quoter);
        vault.close(callId, 10_000);
        assertEq(_units(callId), 0, "no exposure left");
    }

    /// @dev The approvals the vault grants are usable only by the book, and the book only acts for the vault inside the
    ///      vault's own calls: the quoter cannot use them directly.
    function test_vaultApprovalsAreUselessToTheQuoter() public {
        uint256 aliceAsk = _place(alice, callId, WRITE, P2_00, 100);
        _vaultTake(_buy(callId, _ids(aliceAsk), 100, P2_00, address(vault)));
        _vaultLedger(address(nvda), 1e18);

        vm.startPrank(quoter);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.placeFor(address(vault), callId, WRITE, P2_00, 100, 0);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.placeFor(address(vault), callId, BID, P2_00, 100, 0);
        vm.expectRevert(V2Errors.NotMinter.selector);
        ch.mint(callId, 1, address(vault), quoter);
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155MissingApprovalForAll.selector, quoter, address(vault))
        );
        ch.safeTransferFrom(address(vault), quoter, callId, 1, "");
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, quoter, 0, uint256(1)));
        // the call reverts, so there is no return value to check
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdg.transferFrom(address(vault), quoter, 1);
        vm.stopPrank();
        assertFalse(book.isDelegate(address(vault), quoter), "the vault never names a delegate");
    }

    function test_rejectsErc1155FromAnyoneButTheClearinghouse() public {
        vm.startPrank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        vault.onERC1155Received(stranger, stranger, 1, 1, "");
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        vault.onERC1155BatchReceived(stranger, stranger, new uint256[](0), new uint256[](0), "");
        vm.stopPrank();
    }

    function test_refreshApprovalsIsIdempotent() public {
        vm.prank(quoter);
        vault.refreshApprovals();
        assertTrue(ch.isOperator(address(vault), address(book)));
        assertTrue(ch.isApprovedForAll(address(vault), address(book)));
        assertEq(usdg.allowance(address(vault), address(book)), type(uint256).max);
    }
}
