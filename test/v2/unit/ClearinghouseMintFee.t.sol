// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {ClearinghouseTestBase} from "./ClearinghouseBase.t.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {OptionMath} from "../../../src/v2/lib/OptionMath.sol";
import {MockStockToken} from "../../../src/mocks/MockStockToken.sol";

/// @notice c05, the collateral rent of INTERFACE_VERSION 7: what {Clearinghouse.mint} charges, what {close} refunds,
///         what {settle} accrues, and that the {mintFee} / {closeRefund} views answer the same numbers to the base
///         unit (v7 design §4.3, §6.2).
/// @dev THE RATE IS PINNED AT CREATION, like `oracle` and `exerciseFeeBps`: `MarketConfig.mintFeePpm` reaches series
///      created AFTERWARDS only, so a raise cannot re-price a resting order or an open position.
///      THE FIXTURE registers its own market instead of using the base's, because the v7 fixture rule (design §3.8)
///      keeps `mintFeePpm` at 0 everywhere else -- otherwise every OrderBook and AutoRoller number in the suite would
///      move under three work packages at once. TSLA here carries the rate; NVDA stays at 0 as the control.
contract ClearinghouseMintFeeTest is ClearinghouseTestBase {
    /// @dev The design's §5.1 launch rate for NVDA: 80 millionths of the locked collateral per MINT_FEE_PERIOD.
    uint32 internal constant PPM = 80;
    uint40 internal constant E = FRI_2026_09_18;

    /// @dev TSLA carries the rate, NVDA is the ppm-0 control.
    uint256 internal rentCall;
    uint256 internal rentPut;
    uint256 internal freeCall;

    function setUp() public override {
        super.setUp();
        V2Types.MarketConfig memory cfg = _cfg(address(oracle));
        cfg.mintFeePpm = PPM;
        vm.prank(admin);
        _reconfigure(ch, address(tsla), cfg);
        rentCall = ch.createSeries(address(tsla), false, K_240, E);
        rentPut = ch.createSeries(address(tsla), true, K_200, E);
        freeCall = _call(K_240, E);
    }

    /*//////////////////////////////////////////////////////////////
                              THE CHARGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The charge is the ceiled product, for calls and puts, at every distance from expiry the cutoff allows.
    /// @dev One far series, read at 45 d, 7 d, 1 d and one second inside the mint cutoff, rather than four series: the
    ///      rate is a property of the series and the distance is a property of the block.
    function test_mintFee_chargeTableAcrossTheLife() public {
        uint40 far = calendar.nextExpiry(uint40(block.timestamp + 37 days), true);
        uint256 c = ch.createSeries(address(tsla), false, K_240, far);
        uint256 p = ch.createSeries(address(tsla), true, K_200, far);
        uint256 callColl = 100 * V2Constants.UNIT;
        uint256 putColl = 100 * (uint256(K_200) / V2Constants.UNITS_PER_SHARE);
        // One position so the series holds rent: {closeRefund} clamps to `mintFeesHeld`, which would otherwise make
        // every refund below 0 rather than the floored product this table is checking.
        _deposit(alice, address(tsla), callColl + ch.mintFee(c, 100));
        vm.prank(alice);
        ch.setOperator(address(this), true);
        ch.mint(c, 100, alice, alice);

        uint256[4] memory remaining = [uint256(45 days), 7 days, 1 days, uint256(V2Constants.SETTLEMENT_WINDOW) + 1];
        for (uint256 i; i < remaining.length; ++i) {
            if (remaining[i] > far - block.timestamp) continue;
            vm.warp(uint256(far) - remaining[i]);
            assertEq(ch.mintFee(c, 100), OptionMath.mintFee(callColl, PPM, remaining[i]), "call charge");
            assertEq(ch.mintFee(p, 100), OptionMath.mintFee(putColl, PPM, remaining[i]), "put charge");
            // Rounded UP, in the protocol's favour, by under one base unit above the floored twin.
            assertLe(
                ch.mintFee(c, 100) - OptionMath.mintFeeRefund(callColl, PPM, remaining[i]),
                1,
                "ceil is at most one base unit above floor"
            );
            assertEq(ch.closeRefund(c, 100), OptionMath.mintFeeRefund(callColl, PPM, remaining[i]), "refund floors");
        }

        // At expiry itself both are 0, and mint is long past its cutoff.
        vm.warp(far);
        assertEq(ch.mintFee(c, 100), 0, "no life left, no rent");
        assertEq(ch.closeRefund(c, 100), 0, "and nothing to give back");
    }

    /// @notice The design's §5.1 worked numbers, exactly (80 ppm, a weekly 368,100 s out).
    /// @dev 1 unit of a call locks UNIT = 1e16 underlying base units; 368,100 s of the MINT_FEE_PERIOD at 80 ppm is
    ///      ceil(1e16 * 80 * 368100 / (1e6 * 604800)) = 486_904_761_905, about 107 USDG base units at 219.00. A 1-unit
    ///      put at strike 230 locks 2_300_000 USDG base units and pays ceil(111.99...) = 112. 100 units pay ONE ceil,
    ///      not a hundred, which is why 48_690_476_190_477 is below 100 x 486_904_761_905.
    function test_mintFee_docsWorkedNumbers() public {
        uint40 far = calendar.nextExpiry(uint40(block.timestamp + 30 days), true);
        uint256 c = ch.createSeries(address(tsla), false, K_240, far);
        uint256 p = ch.createSeries(address(tsla), true, 230_000_000, far);
        vm.warp(uint256(far) - 368_100);

        assertEq(ch.mintFee(c, 1), 486_904_761_905, "one call unit, 80 ppm, 368_100 s");
        assertEq(ch.mintFee(c, 100), 48_690_476_190_477, "100 units pay one ceil, not a hundred");
        assertLt(ch.mintFee(c, 100), 100 * ch.mintFee(c, 1), "and so pay less than a hundred single units");
        assertEq(ch.mintFee(p, 1), 112, "one put unit at strike 230: ceil(111.99)");

        // Closed on the Wednesday, 172_800 s later, 100 units get back the floored remainder.
        _deposit(alice, address(tsla), 1e18 + ch.mintFee(c, 100));
        vm.prank(alice);
        ch.setOperator(address(this), true);
        ch.mint(c, 100, alice, alice);
        vm.warp(block.timestamp + 2 days);
        assertEq(ch.closeRefund(c, 100), 25_833_333_333_333, "the design's Wednesday refund");
        vm.prank(alice);
        ch.close(c, 100);
        assertEq(ch.series(c).mintFeesHeld, 22_857_142_857_144, "and the rent the protocol kept");
    }

    /// @notice A market at rate 0 charges nothing and writes no rent field; free falls by the collateral alone.
    function test_mintFee_rateZeroChargesNothing() public {
        _deposit(alice, address(nvda), 1e18);
        assertEq(ch.mintFee(freeCall, 100), 0, "no rate, no rent");
        // T-603: `mint` is gated twice -- `isMinter[msg.sender]` (Clearinghouse.sol:641) and, separately,
        // `msg.sender == writer || isOperator[writer][msg.sender]` (:642). The base allowlists the test contract,
        // not `alice`, so the writer authorises it here rather than the base allowlisting an arbitrary EOA.
        vm.prank(alice);
        ch.setOperator(address(this), true);
        ch.mint(freeCall, 100, alice, alice);
        assertEq(ch.free(alice, address(nvda)), 0, "collateral only");
        assertEq(ch.series(freeCall).mintFeesHeld, 0, "nothing held");
        assertEq(ch.closeRefund(freeCall, 100), 0, "nothing to refund");
    }

    /// @notice Free collateral falls by collateral PLUS rent, and `locked` never sees the rent.
    function test_mint_chargesCollateralPlusRentOutOfFree() public {
        uint256 fee = ch.mintFee(rentCall, 100);
        assertGt(fee, 0, "the rate charges");
        _deposit(alice, address(tsla), 1e18 + fee + 7);
        vm.prank(alice);
        ch.setOperator(address(this), true);
        ch.mint(rentCall, 100, alice, bob);
        assertEq(ch.free(alice, address(tsla)), 7, "collateral and rent left the ledger");
        assertEq(ch.locked(rentCall), 1e18, "locked is the collateral, never the rent");
        assertEq(ch.series(rentCall).mintFeesHeld, fee, "the series holds it");
        _assertBacked(rentCall);
    }

    /// @notice Headroom minus one base unit reverts with the FULL requirement; exact headroom mints.
    function test_mint_insufficientCollateralNamesCollateralPlusRent() public {
        uint256 fee = ch.mintFee(rentCall, 100);
        uint256 needed = 1e18 + fee;
        _deposit(alice, address(tsla), needed - 1);
        // T-603: the authorisation goes BEFORE the expectRevert. `vm.expectRevert` binds to the NEXT call, so
        // leaving it above `setOperator` points the expectation at a call that succeeds, and the test fails with
        // "next call did not revert as expected" -- green gate, wrong subject.
        vm.prank(alice);
        ch.setOperator(address(this), true);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InsufficientCollateral.selector, needed - 1, needed));
        ch.mint(rentCall, 100, alice, alice);

        _deposit(alice, address(tsla), 1);
        vm.prank(alice);
        ch.setOperator(address(this), true);
        ch.mint(rentCall, 100, alice, alice);
        assertEq(ch.free(alice, address(tsla)), 0, "exact headroom is enough and nothing is left");
    }

    /// @notice Minted carries the rent as its last field, after the two TransferSingles (§1.8 log order unchanged).
    function test_mint_emitsTheRentAndKeepsTheLogOrder() public {
        uint256 fee = ch.mintFee(rentCall, 100);
        _deposit(alice, address(tsla), 1e18 + fee);
        // T-603: the writer authorises the allowlisted minter BEFORE recordLogs, or {OperatorSet} lands in the
        // recording and this test's whole subject -- that Minted is the THIRD log -- is measured against four.
        vm.prank(alice);
        ch.setOperator(address(this), true);
        vm.recordLogs();
        ch.mint(rentCall, 100, alice, bob);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3, "TransferSingle(long), TransferSingle(short), Minted");
        assertEq(logs[2].topics[0], IClearinghouse.Minted.selector, "Minted is last");
        (uint64 units, uint256 collateral, uint256 loggedFee) = abi.decode(logs[2].data, (uint64, uint256, uint256));
        assertEq(units, 100);
        assertEq(collateral, 1e18, "collateral is unchanged by v7");
        assertEq(loggedFee, fee, "and the rent is the new field");
    }

    /// @notice The rate is pinned at creation: raising the market afterwards leaves existing series alone.
    function test_mintFee_ratePinnedAtCreationNotAtMint() public {
        uint256 before = ch.mintFee(rentCall, 100);
        V2Types.MarketConfig memory cfg = _cfg(address(oracle));
        cfg.mintFeePpm = V2Constants.MINT_FEE_CEIL_PPM;
        vm.prank(admin);
        _reconfigure(ch, address(tsla), cfg);
        assertEq(ch.series(rentCall).mintFeePpm, PPM, "the old series keeps its rate");
        assertEq(ch.mintFee(rentCall, 100), before, "and its charge");

        uint256 later = ch.createSeries(address(tsla), false, K_220, E);
        assertEq(ch.series(later).mintFeePpm, V2Constants.MINT_FEE_CEIL_PPM, "a new series takes the new rate");
        assertGt(ch.mintFee(later, 100), before, "and charges it");
    }

    /// @notice The ceiling binds on registration and on a config change.
    function test_mintFee_ceilingExceededAboveMintFeeCeilPpm() public {
        V2Types.MarketConfig memory cfg = _cfg(address(oracle));
        cfg.mintFeePpm = V2Constants.MINT_FEE_CEIL_PPM + 1;
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        vm.prank(admin);
        _reconfigure(ch, address(tsla), cfg);

        // Registration composes from the defaults; the per-market setter checks the same bound on a market
        // that is not registered yet (a fresh 18-dp token registered first, then the over-ceiling rate).
        MockStockToken fresh = new MockStockToken("FRESH Stock Token", "FRESHx");
        vm.prank(admin);
        ch.registerMarket(address(fresh), STRIKE_TICK, true);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        vm.prank(admin);
        ch.setMarketFees(address(fresh), cfg.exerciseFeeBps, cfg.mintFeePpm);

        cfg.mintFeePpm = V2Constants.MINT_FEE_CEIL_PPM;
        vm.prank(admin);
        _reconfigure(ch, address(tsla), cfg);
        assertEq(ch.market(address(tsla)).mintFeePpm, V2Constants.MINT_FEE_CEIL_PPM, "the ceiling itself is allowed");
    }

    /*//////////////////////////////////////////////////////////////
                              THE REFUND
    //////////////////////////////////////////////////////////////*/

    /// @notice {close} pays the floored refund to the ledger of whoever closes, on top of the collateral.
    function test_close_refundsTheUnusedRentToTheCloser() public {
        uint256 fee = ch.mintFee(rentCall, 100);
        _deposit(alice, address(tsla), 1e18 + fee);
        vm.prank(alice);
        ch.setOperator(address(this), true);
        ch.mint(rentCall, 100, alice, alice);

        vm.warp(block.timestamp + 3 days);
        uint256 refund = ch.closeRefund(rentCall, 100);
        assertEq(refund, OptionMath.mintFeeRefund(1e18, PPM, E - block.timestamp), "the floored product");
        assertGt(refund, 0);
        assertLt(refund, fee, "three days of the life were used");

        vm.expectEmit(true, true, true, true, address(ch));
        emit IClearinghouse.Closed(rentCall, alice, 100, 1e18, refund);
        vm.prank(alice);
        ch.close(rentCall, 100);
        assertEq(ch.free(alice, address(tsla)), 1e18 + refund, "collateral and the refund");
        assertEq(ch.series(rentCall).mintFeesHeld, fee - refund, "the series kept the used part");
    }

    /// @notice The refund follows the PAIR, not the writer: a third party holding both legs is paid it.
    function test_close_refundGoesToWhoeverHoldsThePair() public {
        uint256 fee = ch.mintFee(rentCall, 100);
        _deposit(alice, address(tsla), 1e18 + fee);
        vm.prank(alice);
        ch.setOperator(address(this), true);
        ch.mint(rentCall, 100, alice, alice);
        vm.startPrank(alice);
        ch.safeTransferFrom(alice, carol, rentCall, 100, "");
        ch.safeTransferFrom(alice, carol, _short(rentCall), 100, "");
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        uint256 refund = ch.closeRefund(rentCall, 100);
        vm.prank(carol);
        ch.close(rentCall, 100);
        assertEq(ch.free(carol, address(tsla)), 1e18 + refund, "carol closed, carol was paid");
        assertEq(ch.free(alice, address(tsla)), 0, "the writer got nothing back");
    }

    /// @notice At and after expiry the refund is 0, and {close} still works right up to {settle}.
    function test_close_atAndAfterExpiryRefundsNothing() public {
        uint256 fee = ch.mintFee(rentCall, 100);
        _deposit(alice, address(tsla), 1e18 + fee);
        vm.prank(alice);
        ch.setOperator(address(this), true);
        ch.mint(rentCall, 100, alice, alice);

        vm.warp(E);
        assertEq(ch.closeRefund(rentCall, 100), 0, "at expiry nothing is unused");
        vm.warp(E + 3 days);
        assertEq(ch.closeRefund(rentCall, 100), 0, "and after it");
        vm.prank(alice);
        ch.close(rentCall, 100);
        assertEq(ch.free(alice, address(tsla)), 1e18, "collateral only");
        assertEq(ch.series(rentCall).mintFeesHeld, fee, "the whole rent stayed with the series");
    }

    /// @notice Closing is never pausable, and the rent refund does not change that.
    function test_close_stillWorksUnderEveryPause() public {
        uint256 fee = ch.mintFee(rentCall, 100);
        _deposit(alice, address(tsla), 1e18 + fee);
        vm.prank(alice);
        ch.setOperator(address(this), true);
        ch.mint(rentCall, 100, alice, alice);

        vm.startPrank(guardian);
        ch.setMintPaused(address(tsla), true);
        ch.setCreatePaused(true);
        vm.stopPrank();
        V2Types.MarketConfig memory cfg = _cfg(address(oracle));
        cfg.enabled = false;
        cfg.mintFeePpm = PPM;
        vm.prank(admin);
        _reconfigure(ch, address(tsla), cfg);

        uint256 refund = ch.closeRefund(rentCall, 100);
        assertGt(refund, 0, "there is rent to give back");
        vm.prank(alice);
        ch.close(rentCall, 100);
        assertEq(ch.free(alice, address(tsla)), 1e18 + refund, "a disabled, mint-paused market still refunds");
    }

    /// @notice The clamp in {close} is dead code: forced to bind with vm.store, it caps the refund and never reverts.
    /// @dev The refund can never exceed `mintFeesHeld` on any reachable path (V2-ACCOUNTING §3.3), so the only way to
    ///      see the clamp is to write a smaller `mintFeesHeld` into the series by hand. What it must do then is pay
    ///      what is there and leave {close} working -- never revert and strand the collateral.
    function test_close_clampIsUnreachableButKeepsCloseUnblockable() public {
        uint256 fee = ch.mintFee(rentCall, 100);
        _deposit(alice, address(tsla), 1e18 + fee);
        vm.prank(alice);
        ch.setOperator(address(this), true);
        ch.mint(rentCall, 100, alice, alice);
        assertLe(
            ch.closeRefund(rentCall, 100),
            ch.series(rentCall).mintFeesHeld,
            "the floored refund never exceeds the ceiled fee"
        );

        // Slot 5 of the series struct: uint32 mintFeePpm then uint128 mintFeesHeld.
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(rentCall, SERIES_SLOT))) + 5);
        vm.store(address(ch), slot, bytes32(uint256(PPM) | (uint256(1) << 32)));
        assertEq(ch.series(rentCall).mintFeesHeld, 1, "one base unit is left in the series");
        assertEq(ch.closeRefund(rentCall, 100), 1, "the view clamps too");

        vm.prank(alice);
        ch.close(rentCall, 100);
        assertEq(ch.free(alice, address(tsla)), 1e18 + 1, "paid what was there");
        assertEq(ch.series(rentCall).mintFeesHeld, 0, "and left nothing behind");
    }

    /*//////////////////////////////////////////////////////////////
                             THE ACCRUAL
    //////////////////////////////////////////////////////////////*/

    /// @notice {settle} moves the held rent into accruedFees once, emits MintFeesAccrued after SeriesSettled, and a
    ///         second settle of the same series does nothing.
    function test_settle_accruesHeldRentOnceAfterSeriesSettled() public {
        uint256 fee = ch.mintFee(rentCall, 100);
        _deposit(alice, address(tsla), 1e18 + fee);
        vm.prank(alice);
        ch.setOperator(address(this), true);
        ch.mint(rentCall, 100, alice, alice);

        oracle.setSettlement(address(tsla), E, V2Types.SettlementStatus.Finalized, TSLA_SPOT);
        vm.warp(uint256(E) + V2Constants.FINALIZE_DELAY);
        vm.recordLogs();
        vm.prank(keeper);
        assertTrue(ch.settle(rentCall));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 settledAt = _indexOf(logs, IClearinghouse.SeriesSettled.selector);
        uint256 accruedAt = _indexOf(logs, IClearinghouse.MintFeesAccrued.selector);
        assertLt(settledAt, accruedAt, "SeriesSettled, then MintFeesAccrued");
        assertEq(address(uint160(uint256(logs[accruedAt].topics[2]))), address(tsla), "a call accrues the underlying");
        assertEq(abi.decode(logs[accruedAt].data, (uint256)), fee, "the whole held amount");

        assertEq(ch.series(rentCall).mintFeesHeld, 0, "the series holds nothing now");
        assertEq(ch.accruedFees(address(tsla)), fee, "the protocol does");
        assertEq(ch.closeRefund(rentCall, 100), 0, "a settled series refunds nothing");
        vm.prank(keeper);
        assertFalse(ch.settle(rentCall), "a second settle is a no-op");
        assertEq(ch.accruedFees(address(tsla)), fee, "and accrues nothing again");
    }

    /// @notice A series that never minted emits no MintFeesAccrued at all.
    function test_settle_emitsNothingWhenNoRentIsHeld() public {
        oracle.setSettlement(address(tsla), E, V2Types.SettlementStatus.Finalized, TSLA_SPOT);
        vm.warp(uint256(E) + V2Constants.FINALIZE_DELAY);
        vm.recordLogs();
        vm.prank(keeper);
        ch.settle(rentCall);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IClearinghouse.MintFeesAccrued.selector, "no empty accrual log");
        }
    }

    /// @notice Rent and exercise fees are one pot per asset: one {sweepFees} sends both.
    function test_sweepFees_sendsRentAndExerciseFeesTogether() public {
        uint256 fee = ch.mintFee(rentPut, 100);
        uint256 collateral = 100 * (uint256(K_200) / V2Constants.UNITS_PER_SHARE);
        _deposit(alice, address(usdg), collateral + fee);
        vm.prank(alice);
        ch.setOperator(address(this), true);
        ch.mint(rentPut, 100, alice, alice);

        // Settle deep in the money so the put pays an exercise fee in USDG as well.
        oracle.setSettlement(address(tsla), E, V2Types.SettlementStatus.Finalized, 100_000_000);
        vm.warp(uint256(E) + V2Constants.FINALIZE_DELAY);
        vm.prank(keeper);
        ch.settle(rentPut);
        assertEq(ch.accruedFees(address(usdg)), fee, "rent first");
        _redeem(rentPut, alice);
        uint256 total = ch.accruedFees(address(usdg));
        assertGt(total, fee, "the exercise fee joined it");

        uint256 before = usdg.balanceOf(treasury);
        vm.prank(admin);
        ch.sweepFees(address(usdg));
        assertEq(usdg.balanceOf(treasury) - before, total, "one sweep, both fees");
        assertEq(ch.accruedFees(address(usdg)), 0);
    }

    /// @notice Settlement amounts and redemption payouts do not depend on the rent rate.
    function test_settlement_identicalAtRateZeroAndAtTheCeiling() public {
        V2Types.MarketConfig memory cfg = _cfg(address(oracle));
        cfg.mintFeePpm = V2Constants.MINT_FEE_CEIL_PPM;
        vm.prank(admin);
        _reconfigure(ch, address(tsla), cfg);
        uint256 dear = ch.createSeries(address(tsla), false, K_240, E);

        (uint256 l0, uint256 f0, uint256 s0) = ch.previewSettlement(freeCall, TSLA_SPOT);
        (uint256 l1, uint256 f1, uint256 s1) = ch.previewSettlement(dear, TSLA_SPOT);
        assertEq(l0, l1, "long payout per unit");
        assertEq(f0, f1, "exercise fee per unit");
        assertEq(s0, s1, "short payout per unit");
        assertEq(l1 + f1 + s1, ch.collateralPerUnit(dear), "the identity still holds exactly");
    }

    /*//////////////////////////////////////////////////////////////
                               THE VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice {mintFee} and {closeRefund} answer, base unit for base unit, what mint charges and close refunds in the
    ///         same block, for any size, rate and distance from expiry.
    function testFuzz_views_matchTheRealChargeAndRefund(uint64 units, uint32 ppm, uint32 elapsed) public {
        units = uint64(bound(units, 1, 10_000));
        ppm = uint32(bound(ppm, 0, V2Constants.MINT_FEE_CEIL_PPM));
        // Stay strictly before the mint cutoff.
        elapsed = uint32(bound(elapsed, 0, (E - block.timestamp) - V2Constants.SETTLEMENT_WINDOW - 1));

        V2Types.MarketConfig memory cfg = _cfg(address(oracle));
        cfg.mintFeePpm = ppm;
        vm.prank(admin);
        _reconfigure(ch, address(tsla), cfg);
        uint256 id = ch.createSeries(address(tsla), false, K_220, E);

        vm.warp(block.timestamp + elapsed);
        uint256 quoted = ch.mintFee(id, units);
        _deposit(alice, address(tsla), uint256(units) * V2Constants.UNIT + quoted);
        uint256 freeBefore = ch.free(alice, address(tsla));
        vm.prank(alice);
        ch.setOperator(address(this), true);
        ch.mint(id, units, alice, alice);
        assertEq(
            freeBefore - ch.free(alice, address(tsla)),
            uint256(units) * V2Constants.UNIT + quoted,
            "mint charged exactly what mintFee quoted"
        );
        assertEq(ch.series(id).mintFeesHeld, quoted, "and the series holds exactly that");

        uint256 refundQuote = ch.closeRefund(id, units);
        assertLe(refundQuote, quoted, "the refund never exceeds what the same units paid");
        vm.prank(alice);
        ch.close(id, units);
        assertEq(ch.free(alice, address(tsla)), uint256(units) * V2Constants.UNIT + refundQuote, "close paid it");
    }

    /// @notice Both views reject an id that is not a series.
    function test_views_unknownSeriesReverts() public {
        vm.expectRevert(V2Errors.UnknownSeries.selector);
        ch.mintFee(uint256(keccak256("nope")) & ~uint256(1), 1);
        vm.expectRevert(V2Errors.UnknownSeries.selector);
        ch.closeRefund(uint256(keccak256("nope")) & ~uint256(1), 1);
    }

    /*//////////////////////////////////////////////////////////////
                         THE MATCHING PROOF
    //////////////////////////////////////////////////////////////*/

    /// @notice Over any sequence of mints, closes, transfers and warps, refunds never exceed the fees paid, the
    ///         series' `mintFeesHeld` is exactly their difference, and the clamp in {close} never binds.
    /// @dev This is the fuzz half of the refund-safety proof (V2-ACCOUNTING §3.3, invariants I2' and I7): rent falls
    ///      with time and the rate is fixed per series, so a unit closed at t was charged at some s <= t a CEILED value
    ///      that is at least the FLOORED value paid back now. Supply never goes negative, so closes can always be
    ///      matched to distinct earlier mints; summing gives `SUM refunds <= SUM fees`.
    ///      PAIRS MOVE between the four accounts, so the closer is usually not the writer that paid: the proof is about
    ///      the SERIES' pot, not about any one account, and a pair that changes hands carries its refund with it.
    function testFuzz_mintFee_refundsNeverExceedHeld(uint256 seed) public {
        address[4] memory who = [alice, bob, carol, mm];
        uint256 id = rentCall;
        uint256 paid;
        uint256 refunded;
        for (uint256 i; i < 24; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address actor = who[seed % 4];
            uint256 action = (seed >> 8) % 4;
            uint64 units = uint64(((seed >> 16) % 200) + 1);

            if (action == 3) {
                // Move a whole pair to another account, so that whoever closes it next is not who minted it.
                address to = who[(seed >> 48) % 4];
                uint256 longs = ch.balanceOf(actor, id);
                uint256 shorts = ch.balanceOf(actor, _short(id));
                uint256 n = longs < shorts ? longs : shorts;
                if (to == actor || n == 0 || n < units) continue;
                uint256[] memory ids = new uint256[](2);
                uint256[] memory amounts = new uint256[](2);
                (ids[0], ids[1]) = (id, _short(id));
                (amounts[0], amounts[1]) = (units, units);
                vm.prank(actor);
                ch.safeBatchTransferFrom(actor, to, ids, amounts, "");
            } else if (action == 0) {
                if (block.timestamp >= uint256(E) - V2Constants.SETTLEMENT_WINDOW) continue;
                uint256 fee = ch.mintFee(id, units);
                _deposit(actor, address(tsla), uint256(units) * V2Constants.UNIT + fee);
                vm.prank(actor);
                ch.setOperator(address(this), true);
                ch.mint(id, units, actor, actor);
                paid += fee;
            } else if (action == 1) {
                uint256 held = ch.balanceOf(actor, id);
                uint256 shorts = ch.balanceOf(actor, _short(id));
                uint64 n = uint64(held < shorts ? held : shorts);
                if (n == 0 || n < units) continue;
                uint256 refund = ch.closeRefund(id, units);
                // The clamp never binds: the quote is the unclamped floored product.
                assertEq(
                    refund,
                    OptionMath.mintFeeRefund(uint256(units) * V2Constants.UNIT, PPM, E - block.timestamp),
                    "the clamp did not bind"
                );
                vm.prank(actor);
                ch.close(id, units);
                refunded += refund;
            } else {
                uint256 step = ((seed >> 32) % 2 days) + 1;
                if (block.timestamp + step >= E) continue;
                vm.warp(block.timestamp + step);
            }

            assertLe(refunded, paid, "refunds never exceed the fees paid");
            assertEq(ch.series(id).mintFeesHeld, paid - refunded, "held is exactly the difference");
            uint256 supply = ch.totalSupply(id);
            if (supply != 0 && supply <= type(uint64).max && block.timestamp < E) {
                assertGe(
                    ch.series(id).mintFeesHeld,
                    ch.closeRefund(id, uint64(supply)),
                    "I7: held covers closing the whole supply now"
                );
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _indexOf(Vm.Log[] memory logs, bytes32 topic0) internal pure returns (uint256) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic0) return i;
        }
        revert("log not found");
    }
}
