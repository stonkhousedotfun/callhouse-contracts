// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm, console2} from "forge-std/Test.sol";
import {ClearinghouseTestBase} from "./ClearinghouseBase.t.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {OptionMath} from "../../../src/v2/lib/OptionMath.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";

/// @notice Clearinghouse.redeem without USDG conversion: ITM / OTM / ATM calls and puts, long and short, exact
///         conservation against `locked`, fee accrual and sweep, ledger fallbacks (blocklisted holder, paused or
///         frozen USDG, paused Stock Token, payout-to-ledger preference), the REDEEM bounty gate and the gas target.
///         Conversion paths are in ClearinghousePayout.t.sol, third-party rules and batches in
///         ClearinghouseRedeemAccess.t.sol.
contract ClearinghouseRedeemTest is ClearinghouseTestBase {
    uint256 internal callId;
    uint256 internal putId;

    function setUp() public override {
        super.setUp();
        callId = _call(K_240, FRI_2026_09_18);
        putId = _put(K_200, FRI_2026_09_18);
    }

    /*//////////////////////////////////////////////////////////////
                                  CALLS
    //////////////////////////////////////////////////////////////*/

    /// @dev K = 240, P = 250, 100 units written by alice, held by bob (in kind). Per unit: long 3.75e14, fee 2.5e13,
    ///      short 9.6e15 underlying base units.
    function test_redeem_itmCall_longAndShortInKind() public {
        _write(alice, callId, 100, bob);
        _inKind(bob);
        _settle(callId, 250e6);
        uint256 lockedAtSettle = ch.locked(callId);
        assertEq(lockedAtSettle, 1e18);
        uint256 keeperBefore = usdg.balanceOf(keeper);

        vm.expectEmit(true, true, false, true, address(ch));
        emit IClearinghouse.Redeemed(callId, bob, bob, 100, address(nvda), 3.75e16, 3.75e16, false);
        (uint256 paid, bool inUsdg) = _redeem(callId, bob);
        assertEq(paid, 3.75e16);
        assertFalse(inUsdg);
        assertEq(nvda.balanceOf(bob), ACTOR_SHARES + 3.75e16, "long paid in kind");
        assertEq(ch.balanceOf(bob, callId), 0, "whole balance burned");
        assertEq(ch.totalSupply(callId), 0);
        assertEq(ch.accruedFees(address(nvda)), 2.5e15, "fee accrues");
        assertEq(ch.openInterest(address(nvda), FRI_2026_09_18), 0, "long redemption lowers open interest");
        assertEq(ch.locked(callId), 9.6e17, "what the shorts are still owed");
        assertEq(usdg.balanceOf(keeper) - keeperBefore, REDEEM_BOUNTY, "9.375 USDG of value earns the bounty");

        vm.expectEmit(true, true, false, true, address(ch));
        emit IClearinghouse.Redeemed(_short(callId), alice, alice, 100, address(nvda), 9.6e17, 9.6e17, false);
        (paid, inUsdg) = _redeem(_short(callId), alice);
        assertEq(paid, 9.6e17);
        assertFalse(inUsdg);
        assertEq(nvda.balanceOf(alice), ACTOR_SHARES - 1e18 + 9.6e17, "short gets its remainder in kind");
        assertEq(ch.locked(callId), 0);
        assertEq(nvda.balanceOf(address(ch)), ch.accruedFees(address(nvda)), "only fees remain");
        assertEq(3.75e16 + 9.6e17 + 2.5e15, lockedAtSettle, "exact conservation");
    }

    /// @dev OTM (P < K) and ATM (P == K): the long is burned for nothing, the short gets the whole unit back.
    function test_redeem_otmAndAtmCall() public {
        uint256 atm = _call(K_220, FRI_2026_09_18);
        _write(alice, callId, 10, bob);
        _write(alice, atm, 10, bob);
        _settle(callId, 220e6);
        vm.prank(keeper);
        ch.settle(atm);
        assertEq(ch.series(atm).longPayoutPerUnit, 0, "ATM pays nothing");

        uint256[2] memory ids = [callId, atm];
        for (uint256 i; i < ids.length; ++i) {
            uint256 keeperBefore = usdg.balanceOf(keeper);
            vm.expectEmit(true, true, false, true, address(ch));
            emit IClearinghouse.Redeemed(ids[i], bob, bob, 10, address(nvda), 0, 0, false);
            (uint256 paid, bool inUsdg) = _redeem(ids[i], bob);
            assertEq(paid, 0);
            assertFalse(inUsdg);
            assertEq(ch.balanceOf(bob, ids[i]), 0, "zero-value balance is just burned");
            assertEq(usdg.balanceOf(keeper), keeperBefore, "no bounty for a zero payout");

            (paid,) = _redeem(_short(ids[i]), alice);
            assertEq(paid, 10 * V2Constants.UNIT, "short gets all collateral");
        }
        assertEq(nvda.balanceOf(bob), ACTOR_SHARES);
        assertEq(nvda.balanceOf(alice), ACTOR_SHARES, "writer made whole");
        assertEq(ch.accruedFees(address(nvda)), 0, "no fee when OTM");
        assertEq(nvda.balanceOf(address(ch)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                   PUTS
    //////////////////////////////////////////////////////////////*/

    /// @dev K = 200, P = 190, 10 units: long 0.095 USDG / unit (fee 0.005), short 1.90 USDG / unit.
    function test_redeem_itmPut_longAndShortInUsdg() public {
        _write(alice, putId, 10, bob);
        _settle(putId, 190e6);
        assertEq(ch.locked(putId), 20e6);

        vm.expectEmit(true, true, false, true, address(ch));
        emit IClearinghouse.Redeemed(putId, bob, bob, 10, address(usdg), 950_000, 950_000, false);
        (uint256 paid, bool inUsdg) = _redeem(putId, bob);
        assertEq(paid, 950_000);
        assertTrue(inUsdg, "puts pay USDG");
        assertEq(usdg.balanceOf(bob), ACTOR_USDG + 950_000);
        assertEq(ch.accruedFees(address(usdg)), 50_000);

        (paid, inUsdg) = _redeem(_short(putId), alice);
        assertEq(paid, 19_000_000);
        assertTrue(inUsdg, "a put short is paid in USDG too");
        assertEq(usdg.balanceOf(alice), ACTOR_USDG - 20e6 + 19e6);
        assertEq(ch.locked(putId), 0);
        assertEq(usdg.balanceOf(address(ch)), 50_000, "only the fee remains");
        assertEq(adapter.calls(), 0, "puts never touch the adapter");
    }

    function test_redeem_otmAndAtmPut() public {
        uint256 atm = _put(K_220, FRI_2026_09_18);
        _write(alice, putId, 7, bob);
        _write(alice, atm, 7, bob);
        _settle(putId, 220e6); // put K = 200 is OTM, put K = 220 is ATM
        vm.prank(keeper);
        ch.settle(atm);

        (uint256 paid, bool inUsdg) = _redeem(putId, bob);
        assertEq(paid, 0);
        assertTrue(inUsdg);
        (paid,) = _redeem(atm, bob);
        assertEq(paid, 0);
        (paid,) = _redeem(_short(putId), alice);
        assertEq(paid, 7 * 2e6);
        (paid,) = _redeem(_short(atm), alice);
        assertEq(paid, 7 * 2.2e6);
        assertEq(usdg.balanceOf(alice), ACTOR_USDG);
        assertEq(usdg.balanceOf(address(ch)), 0);
    }

    /// @dev A put settling at 1 base unit: the long gets everything but the fee and one base unit per unit.
    function test_redeem_deepItmPut() public {
        _write(alice, putId, 3, bob);
        _settle(putId, 1);
        V2Types.Series memory s = ch.series(putId);
        assertEq(s.longPayoutPerUnit, 1_994_999);
        assertEq(s.feePerUnit, 5_000);
        assertEq(s.shortPayoutPerUnit, 1);
        (uint256 paid,) = _redeem(putId, bob);
        assertEq(paid, 3 * 1_994_999);
        (paid,) = _redeem(_short(putId), alice);
        assertEq(paid, 3);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSERVATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Several writers and holders, transfers after minting, closes, then every balance redeemed in an arbitrary
    ///      order: payouts + fees == locked at settlement to the base unit, and the Clearinghouse ends holding exactly
    ///      the fees plus the ledger balances.
    function testFuzz_redeem_conservesLocked(bool isPut, uint256 k, uint256 price, uint64 u1, uint64 u2, uint64 moved)
        public
    {
        k = bound(k, 110, 440);
        price = bound(price, 0, 2_000e6);
        u1 = uint64(bound(u1, 1, 5_000));
        u2 = uint64(bound(u2, 1, 5_000));
        moved = uint64(bound(moved, 0, u1));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 strike = uint128(k * 1e6);
        uint256 longId = ch.createSeries(address(nvda), isPut, strike, FRI_2026_09_18);
        address asset = ch.collateralAsset(longId);
        _inKind(bob);
        _inKind(carol);
        _inKind(mm);

        _write(alice, longId, u1, bob);
        _write(carol, longId, u2, carol);
        vm.prank(bob);
        ch.safeTransferFrom(bob, mm, longId, moved, "");
        vm.prank(alice);
        ch.safeTransferFrom(alice, mm, _short(longId), u1 / 2, "");
        if (u2 > 1) {
            vm.prank(carol);
            ch.close(longId, u2 / 2);
        }
        _assertBacked(longId);

        _settle(longId, price);
        uint256 lockedAtSettle = ch.locked(longId);
        uint256 chBefore = _balance(asset, address(ch));

        address[4] memory holders = [mm, carol, bob, alice];
        uint256 paidTotal;
        for (uint256 i; i < holders.length; ++i) {
            (uint256 p,) = _redeem(_short(longId), holders[i]);
            paidTotal += p;
            (p,) = _redeem(longId, holders[i]);
            paidTotal += p;
        }
        uint256 fees = ch.accruedFees(asset);
        assertEq(paidTotal + fees, lockedAtSettle, "payouts + fees == locked at settlement");
        assertEq(ch.locked(longId), 0);
        assertEq(ch.totalSupply(longId), 0);
        assertEq(ch.totalSupply(_short(longId)), 0);
        assertEq(chBefore - _balance(asset, address(ch)), paidTotal, "every payout left the contract");

        V2Types.Series memory s = ch.series(longId);
        assertEq(
            uint256(s.longPayoutPerUnit) + s.feePerUnit + s.shortPayoutPerUnit,
            ch.collateralPerUnit(longId),
            "invariant 3: long + fee + short == collateralPerUnit"
        );
        address[] memory accounts = new address[](4);
        for (uint256 i; i < 4; ++i) {
            accounts[i] = holders[i];
        }
        uint256[] memory ids = new uint256[](1);
        ids[0] = longId;
        _assertSolvent(asset, accounts, ids);
    }

    /// @dev Extreme sizes: a put with a 1e30 strike, two type(uint64).max mints to one holder. Per-unit amounts near
    ///      1e28 times uint64-max units exceed uint128, so the redemption maths must run in uint256; a balance above
    ///      uint64 is redeemed in two calls.
    function test_redeem_extremeSizes() public {
        oracle.setSpot(address(nvda), false, 0, 0);
        uint128 strike = 1e30;
        uint256 bigPut = _put(strike, FRI_2026_09_18);
        uint64 maxUnits = type(uint64).max;
        uint256 perUnit = uint256(strike) / 100;
        usdg.mint(alice, 2 * uint256(maxUnits) * perUnit);
        _deposit(alice, address(usdg), 2 * uint256(maxUnits) * perUnit);
        vm.startPrank(alice);
        ch.mint(bigPut, maxUnits, alice, bob);
        ch.mint(bigPut, maxUnits, alice, bob);
        vm.stopPrank();
        assertEq(ch.balanceOf(bob, bigPut), 2 * uint256(maxUnits));
        assertEq(ch.openInterest(address(nvda), FRI_2026_09_18), 2 * uint256(maxUnits));

        _settle(bigPut, 0);
        V2Types.Series memory s = ch.series(bigPut);
        uint256 owedFirst = uint256(maxUnits) * s.longPayoutPerUnit;
        assertGt(owedFirst, type(uint128).max, "beyond uint128");

        vm.expectEmit(true, true, false, true, address(ch));
        emit IClearinghouse.Redeemed(bigPut, bob, bob, maxUnits, address(usdg), owedFirst, owedFirst, false);
        (uint256 paid,) = _redeem(bigPut, bob);
        assertEq(paid, owedFirst);
        assertEq(ch.balanceOf(bob, bigPut), maxUnits, "capped at uint64 max per call");
        (paid,) = _redeem(bigPut, bob);
        assertEq(paid, owedFirst);
        assertEq(ch.balanceOf(bob, bigPut), 0);
        assertEq(ch.accruedFees(address(usdg)), 2 * uint256(maxUnits) * s.feePerUnit);
        (paid,) = _redeem(_short(bigPut), alice);
        (paid,) = _redeem(_short(bigPut), alice);
        assertEq(ch.locked(bigPut), 0);
        assertEq(usdg.balanceOf(address(ch)), ch.accruedFees(address(usdg)));
    }

    /*//////////////////////////////////////////////////////////////
                                   FEES
    //////////////////////////////////////////////////////////////*/

    function test_sweepFees() public {
        _write(alice, callId, 100, bob);
        _write(alice, putId, 10, bob);
        _inKind(bob);
        _settle(callId, 250e6);
        vm.prank(keeper);
        ch.settle(putId);
        _redeem(callId, bob);
        _redeem(putId, bob); // put K = 200 at 250 is OTM: no USDG fee
        assertEq(ch.accruedFees(address(nvda)), 2.5e15);
        assertEq(ch.accruedFees(address(usdg)), 0);

        vm.expectEmit(true, true, false, true, address(ch));
        emit IClearinghouse.FeesSwept(address(nvda), treasury, 2.5e15);
        vm.prank(carol);
        ch.sweepFees(address(nvda));
        assertEq(nvda.balanceOf(treasury), 2.5e15, "anyone sweeps, the fee recipient receives");
        assertEq(ch.accruedFees(address(nvda)), 0);

        vm.recordLogs();
        ch.sweepFees(address(nvda));
        ch.sweepFees(address(usdg));
        assertEq(vm.getRecordedLogs().length, 0, "nothing accrued: no-op");
    }

    function test_sweepFees_failedTransferKeepsFeesAccrued() public {
        _write(alice, putId, 10, bob);
        _settle(putId, 190e6);
        _redeem(putId, bob);
        usdg.freeze(treasury);
        vm.expectRevert(MockERC20.AddressFrozen.selector);
        ch.sweepFees(address(usdg));
        assertEq(ch.accruedFees(address(usdg)), 50_000);

        usdg.unfreeze(treasury);
        vm.prank(admin);
        ch.setFeeRecipient(carol);
        ch.sweepFees(address(usdg));
        assertEq(usdg.balanceOf(carol), ACTOR_USDG + 50_000, "goes to the current recipient");
    }

    /*//////////////////////////////////////////////////////////////
                             LEDGER FALLBACKS
    //////////////////////////////////////////////////////////////*/

    /// @dev A Stock Token blocklist on the holder turns the in-kind transfer into a ledger credit; the holder withdraws
    ///      once unblocked.
    function test_redeem_blocklistedHolderCreditedToLedger() public {
        _write(alice, callId, 100, bob);
        _inKind(bob);
        _settle(callId, 250e6);
        nvda.blockAccount(bob);

        vm.expectEmit(true, true, false, true, address(ch));
        emit IClearinghouse.Redeemed(callId, bob, address(ch), 100, address(nvda), 3.75e16, 3.75e16, true);
        (uint256 paid, bool inUsdg) = _redeem(callId, bob);
        assertEq(paid, 3.75e16);
        assertFalse(inUsdg);
        assertEq(ch.free(bob, address(nvda)), 3.75e16, "credited, not lost");
        assertEq(nvda.balanceOf(bob), ACTOR_SHARES);

        _assertSolventNvda();
        nvda.unblockAccount(bob);
        vm.prank(bob);
        ch.withdraw(address(nvda), 3.75e16, bob);
        assertEq(nvda.balanceOf(bob), ACTOR_SHARES + 3.75e16);
    }

    /// @dev An issuer pause of the whole Stock Token: shorts are credited too.
    function test_redeem_pausedStockTokenCreditedToLedger() public {
        _write(alice, callId, 10, bob);
        _settle(callId, 230e6);
        nvda.pause();
        (uint256 paid,) = _redeem(_short(callId), alice);
        assertEq(paid, 10e16);
        assertEq(ch.free(alice, address(nvda)), 10e16);
    }

    function test_redeem_pausedUsdgCreditedToLedger() public {
        _write(alice, putId, 10, bob);
        _settle(putId, 190e6);
        usdg.pause();
        vm.expectEmit(true, true, false, true, address(ch));
        emit IClearinghouse.Redeemed(putId, bob, address(ch), 10, address(usdg), 950_000, 950_000, true);
        (uint256 paid, bool inUsdg) = _redeem(putId, bob);
        assertEq(paid, 950_000);
        assertTrue(inUsdg);
        assertEq(ch.free(bob, address(usdg)), 950_000);
        (paid,) = _redeem(_short(putId), alice);
        assertEq(ch.free(alice, address(usdg)), 19e6, "short credited as well");
        usdg.unpause();

        address[] memory accounts = new address[](2);
        accounts[0] = alice;
        accounts[1] = bob;
        uint256[] memory ids = new uint256[](1);
        ids[0] = putId;
        _assertSolvent(address(usdg), accounts, ids);
    }

    function test_redeem_frozenUsdgHolderCreditedToLedger() public {
        _write(alice, putId, 10, bob);
        _settle(putId, 190e6);
        usdg.freeze(bob);
        _redeem(putId, bob);
        assertEq(ch.free(bob, address(usdg)), 950_000);
        assertEq(usdg.balanceOf(bob), ACTOR_USDG);
    }

    /// @dev setPayoutToLedger: credited without a transfer attempt, in the collateral asset.
    function test_redeem_payoutToLedgerPreference() public {
        _write(alice, callId, 10, bob);
        _write(alice, putId, 10, bob);
        vm.prank(alice);
        ch.setPayoutToLedger(true);
        _settle(callId, 250e6);
        vm.prank(keeper);
        ch.settle(putId);

        uint256 chNvda = nvda.balanceOf(address(ch));
        vm.expectEmit(true, true, false, true, address(ch));
        emit IClearinghouse.Redeemed(_short(callId), alice, address(ch), 10, address(nvda), 9.6e16, 9.6e16, true);
        _redeem(_short(callId), alice);
        _redeem(_short(putId), alice);
        assertEq(nvda.balanceOf(address(ch)), chNvda, "no transfer");
        assertEq(ch.free(alice, address(nvda)), 9.6e16);
        assertEq(ch.free(alice, address(usdg)), 20e6);
    }

    /*//////////////////////////////////////////////////////////////
                                  GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_redeem_notSettledOrUnknown() public {
        _write(alice, callId, 10, bob);
        vm.expectRevert(V2Errors.NotSettled.selector);
        _redeem(callId, bob);
        vm.expectRevert(V2Errors.NotSettled.selector);
        _redeem(_short(callId), alice);
        vm.warp(FRI_2026_09_18 + 1 days);
        vm.expectRevert(V2Errors.NotSettled.selector);
        _redeem(callId, bob);

        uint256 unknown = ch.longIdOf(address(tsla), false, K_240, FRI_2026_09_18);
        vm.expectRevert(V2Errors.UnknownSeries.selector);
        _redeem(unknown, bob);
        vm.expectRevert(V2Errors.UnknownSeries.selector);
        _redeem(_short(unknown), bob);
    }

    function test_redeem_noBalanceIsANoOp() public {
        _write(alice, callId, 10, bob);
        _settle(callId, 250e6);
        vm.recordLogs();
        (uint256 paid, bool inUsdg) = _redeem(callId, carol);
        assertEq(paid, 0);
        assertFalse(inUsdg);
        _redeem(_short(callId), bob);
        assertEq(vm.getRecordedLogs().length, 0);

        _redeem(callId, bob);
        vm.recordLogs();
        _redeem(callId, bob);
        assertEq(vm.getRecordedLogs().length, 0, "redeeming twice is a no-op");
    }

    /// @dev §1.8: a redemption emits TransferSingle(holder -> 0) and Redeemed, never TransferBatch.
    function test_redeem_logs() public {
        _write(alice, callId, 10, bob);
        _inKind(bob);
        _settle(callId, 250e6);
        vm.prank(admin);
        ch.setKeeperRewards(address(0));
        vm.recordLogs();
        _redeem(callId, bob);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3, "burn, token transfer, Redeemed");
        assertEq(logs[0].topics[0], keccak256("TransferSingle(address,address,address,uint256,uint256)"));
        assertEq(address(uint160(uint256(logs[0].topics[1]))), keeper, "operator is the caller");
        assertEq(address(uint160(uint256(logs[0].topics[3]))), address(0), "burn");
        assertEq(logs[1].emitter, address(nvda));
        assertEq(logs[2].topics[0], IClearinghouse.Redeemed.selector);
    }

    /*//////////////////////////////////////////////////////////////
                                  BOUNTY
    //////////////////////////////////////////////////////////////*/

    function test_redeem_bountyThreshold() public {
        uint256 otm = _put(110_000_000, FRI_2026_09_18);
        _write(alice, putId, 10, bob);
        _write(alice, putId, 20, carol);
        _write(alice, otm, 5, bob);
        _settle(putId, 190e6);
        _settle(otm, 190e6);
        uint256 k0 = usdg.balanceOf(keeper);

        _redeem(putId, bob); // 0.95 USDG < 1.00
        assertEq(usdg.balanceOf(keeper), k0, "below minRedeemPayout: no bounty");
        _redeem(putId, carol); // 1.90 USDG
        assertEq(usdg.balanceOf(keeper), k0 + REDEEM_BOUNTY, "at or above: bounty to the caller");

        vm.prank(admin);
        ch.setMinRedeemPayout(0);
        uint256 k1 = usdg.balanceOf(keeper);
        _redeem(otm, bob);
        assertEq(usdg.balanceOf(keeper), k1, "a zero payout never pays, whatever the threshold");
        _redeem(_short(otm), alice);
        assertEq(usdg.balanceOf(keeper), k1 + REDEEM_BOUNTY);
    }

    /// @dev The call short's value is measured at the settlement price: 10 units * 9.6e15 at 250 = 24 USDG.
    function test_redeem_bountyValuesCallsAtSettlementPrice() public {
        _write(alice, callId, 1, bob);
        _inKind(bob);
        _settle(callId, 250e6);
        vm.prank(admin);
        ch.setMinRedeemPayout(2_400_000);
        uint256 k0 = usdg.balanceOf(keeper);
        _redeem(_short(callId), alice); // 9.6e15 at 250 = 2.40 USDG
        assertEq(usdg.balanceOf(keeper), k0 + REDEEM_BOUNTY);
        _redeem(callId, bob); // 3.75e14 at 250 = 0.09375 USDG
        assertEq(usdg.balanceOf(keeper), k0 + REDEEM_BOUNTY);
    }

    /*//////////////////////////////////////////////////////////////
                                   GAS
    //////////////////////////////////////////////////////////////*/

    /// @dev Gas target: redeem without conversion <= 120k, measured per payout path with and without a bounty paid.
    ///      Every call is its own transaction (foundry `isolate`), so the numbers include the 21k intrinsic gas and
    ///      cold storage, as on chain.
    function test_gas_redeemWithoutConversion() public {
        uint256 callB = _call(K_220, FRI_2026_09_18);
        uint256 putB = _put(260_000_000, FRI_2026_09_18);
        uint256 callC = _call(230_000_000, FRI_2026_09_18);
        _write(alice, callId, 100, bob);
        _write(alice, callB, 100, bob);
        _write(alice, callC, 100, bob);
        _write(alice, putId, 100, bob);
        _write(alice, putB, 100, bob);
        _inKind(bob);
        _settle(callId, 250e6);
        vm.startPrank(keeper);
        ch.settle(callB);
        ch.settle(callC);
        ch.settle(putId);
        ch.settle(putB);
        vm.stopPrank();
        _redeem(callC, bob); // the NVDA fee accrual and the keeper's bounty balance are no longer fresh slots

        // The Clearinghouse's own work: no bounty payer.
        vm.prank(admin);
        ch.setKeeperRewards(address(0));
        uint256 g = _gasRedeem(callB, bob);
        console2.log("gas: redeem call long in kind (fee accrues)", g);
        assertLe(g, 120_000, "redeem without conversion <= 120k");
        g = _gasRedeem(_short(callB), alice);
        console2.log("gas: redeem call short in kind", g);
        assertLe(g, 120_000, "redeem without conversion <= 120k");
        g = _gasRedeem(_short(putId), alice);
        console2.log("gas: redeem put short in USDG", g);
        assertLe(g, 120_000, "redeem without conversion <= 120k");

        // The same paths when KeeperRewards also pays the REDEEM bounty: its reward() with its own guard, spend window
        // and USDG transfer adds ~42k (~22k more when this redemption is the asset's first fee accrual since a sweep).
        // That is C2-07's cost, not the redemption's; the bound below only catches a regression.
        vm.prank(admin);
        ch.setKeeperRewards(address(rewards));
        uint256 withBounty = _gasRedeem(callId, bob);
        console2.log("gas: redeem call long in kind + REDEEM bounty", withBounty);
        g = _gasRedeem(_short(callId), alice);
        console2.log("gas: redeem call short in kind + REDEEM bounty", g);
        if (g > withBounty) withBounty = g;
        g = _gasRedeem(putB, bob);
        console2.log("gas: redeem put long in USDG (fee accrues) + REDEEM bounty", g);
        if (g > withBounty) withBounty = g;
        assertLe(withBounty, 150_000, "bounty adds one KeeperRewards.reward call on top");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _inKind(address who) internal {
        vm.prank(who);
        ch.setPayoutInKind(true);
    }

    function _balance(address asset, address who) internal view returns (uint256) {
        return MockERC20(asset).balanceOf(who);
    }

    function _gasRedeem(uint256 tokenId, address holder) internal returns (uint256 used) {
        vm.prank(keeper);
        uint256 g = gasleft();
        ch.redeem(tokenId, holder);
        used = g - gasleft();
    }

    function _assertSolventNvda() internal view {
        address[] memory accounts = new address[](3);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = carol;
        uint256[] memory ids = new uint256[](1);
        ids[0] = callId;
        _assertSolvent(address(nvda), accounts, ids);
    }
}
