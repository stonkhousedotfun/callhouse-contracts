// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V2IntegrationBase} from "./V2IntegrationBase.t.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Ids} from "../../../src/v2/interfaces/V2Ids.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {OptionMath} from "../../../src/v2/lib/OptionMath.sol";

/// @notice c05 on the real contracts: the writer fee is rent on the collateral a mint locks, charged by
///         {Clearinghouse.mint} however the mint was reached, refunded pro rata by {Clearinghouse.close} and accrued
///         to the FeeSplitter at {Clearinghouse.settle} (INTERFACE_VERSION 8: {feeRecipient} is the splitter, not an EOA).
/// @dev WHY THIS SUITE EXISTS. Until v7 the writer fee was `premiumFeeBps` of the premium of a PRIMARY book fill, so a
///      writer avoided it by never letting the book mint: mint directly and rest an AskResale (resale fee 0), or
///      `writeToSell` into a one-tick bid from a second address of its own and resell the longs at the real price.
///      The first two tests of this file are the sweep's proofs of exactly that, and after v7 they no longer pass as
///      written: rent is charged on `units x collateralPerUnit x (time to expiry)`, which contains nothing the writer
///      chooses except size and tenor and no fill price at all. Both are kept, renamed, as the positive statements
///      {test_c05_everyRoutePaysTheSameWriterFee} and {test_c05_selfTradeIntoAOneTickBidPaysFullRent}.
///
///      FIXTURE. The v7 fixture rule (design §3.8) keeps `mintFeePpm` at 0 in every other suite, so this one
///      registers NVDA itself at the launch rate of the design's §5.1 table (NVDA 80 ppm) and keeps the base's book
///      fees (premium 500 bps) so the "pays nothing" arithmetic of the PoCs is the pre-v7 arithmetic. The launch fee
///      set (premium 0) is the deploy scripts' business, not this suite's.
contract C05MintFeeTest is V2IntegrationBase {
    /// @dev The design's §5.1 launch rate for NVDA: 80 millionths of the locked collateral per MINT_FEE_PERIOD.
    uint32 internal constant NVDA_PPM = 80;

    uint40 internal constant E = FRI_2026_09_18;
    uint128 internal constant K230 = 230_000_000;
    uint128 internal constant K210 = 210_000_000;

    /// @dev 1e18 / 1.0001^221515 = 240.00 USDG per share (the pool quotes the inverse of the tick).
    int24 internal constant TICK_240 = 221515;

    /// @dev 100 units = 1 share of collateral for a call.
    uint64 internal constant HUNDRED = 100;
    uint256 internal constant ONE_SHARE = 100 * V2Constants.UNIT;

    uint256 internal c230;
    uint256 internal p210;

    function setUp() public override {
        super.setUp();
        vm.startPrank(admin);
        ch.registerMarket(address(nvda), STRIKE_TICK, true);
        ch.setMarketOracle(address(nvda), address(oracle));
        ch.setMarketFees(address(nvda), EXERCISE_FEE_BPS, NVDA_PPM);
        vm.stopPrank();
        address[4] memory traders = [alice, bob, carol, mm];
        for (uint256 i; i < traders.length; ++i) {
            _onboard(traders[i]);
        }
        c230 = ch.createSeries(address(nvda), false, K230, E);
        p210 = ch.createSeries(address(nvda), true, K210, E);
    }

    /*//////////////////////////////////////////////////////////////
                        THE SWEEP'S c05 AVOIDANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice v7: a writer who mints its own longs and rests an AskResale pays the SAME rent as any other route.
    /// @dev This is the sweep's `test_poc_c05_directMintThenResale_writerPaysNothing`, kept as its positive twin. The
    ///      PoC deposited exactly `units x collateralPerUnit` and showed the whole round trip -- mint, resale ask, a
    ///      buyer taking it -- charging the writer nothing at all, because `premiumFeeBps` only ever reached a PRIMARY
    ///      (AskWrite / writeToSell) fill and `resaleFeeBps` is 0.
    ///      After v7 that deposit no longer even mints: {mint} wants collateral PLUS rent. The four routes below --
    ///      a direct mint to self, a direct mint straight to a third party, an AskWrite the book fills, and a
    ///      `writeToSell` into someone else's bid -- are the whole set of ways a long can come into existence, and each
    ///      charges the identical `mintFee` for the identical size in the identical block.
    function test_c05_everyRoutePaysTheSameWriterFee() public {
        uint256 fee = ch.mintFee(c230, HUNDRED);
        assertGt(fee, 0, "the launch rate charges something");
        assertEq(fee, OptionMath.mintFee(ONE_SHARE, NVDA_PPM, E - block.timestamp), "the view is the formula");

        // The PoC's deposit: collateral and not one base unit more. It used to mint.
        _deposit(alice, address(nvda), ONE_SHARE);
        // T-603: authorise BEFORE the expectRevert -- `vm.expectRevert` binds to the NEXT call, so leaving it
        // above `setOperator` points the expectation at a call that succeeds.
        vm.prank(alice);
        ch.setOperator(address(this), true);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InsufficientCollateral.selector, ONE_SHARE, ONE_SHARE + fee));
        ch.mint(c230, HUNDRED, alice, alice);

        // Route 1: direct mint to self, then an AskResale a buyer lifts. The rent is held by the series.
        _deposit(alice, address(nvda), fee);
        vm.prank(alice);
        ch.setOperator(address(this), true);
        ch.mint(c230, HUNDRED, alice, alice);
        assertEq(ch.series(c230).mintFeesHeld, fee, "route 1 rent is held");
        assertEq(ch.free(alice, address(nvda)), 0, "route 1 spent collateral and rent");
        uint256 resale = _place(alice, c230, RESALE, 2_50000, HUNDRED);
        vm.prank(bob);
        book.take(_buyParams(c230, _ids(resale), HUNDRED, 0, bob));
        assertEq(ch.series(c230).mintFeesHeld, fee, "a resale neither charges nor refunds rent");

        // Route 2: a direct mint whose longs go straight to someone else.
        _deposit(carol, address(nvda), ONE_SHARE + fee);
        vm.prank(carol);
        ch.setOperator(address(this), true);
        ch.mint(c230, HUNDRED, carol, bob);
        assertEq(ch.series(c230).mintFeesHeld, 2 * fee, "route 2 paid the same");

        // Route 3: an AskWrite the book mints on fill. The book budgets collateral + rent.
        _deposit(mm, address(nvda), ONE_SHARE + fee);
        uint256 askWrite = _place(mm, c230, WRITE, 2_50000, HUNDRED);
        vm.prank(bob);
        book.take(_buyParams(c230, _ids(askWrite), HUNDRED, HUNDRED, bob));
        assertEq(ch.series(c230).mintFeesHeld, 3 * fee, "route 3 paid the same");
        assertEq(ch.free(mm, address(nvda)), 0, "route 3 spent collateral and rent");

        // Route 4: writeToSell into a bid someone else placed.
        uint256 bid = _place(bob, c230, BID, 2_50000, HUNDRED);
        _deposit(carol, address(nvda), ONE_SHARE + fee);
        vm.prank(carol);
        book.take(_sellParams(c230, _ids(bid), HUNDRED, true, carol));
        assertEq(ch.series(c230).mintFeesHeld, 4 * fee, "route 4 paid the same");
    }

    /// @notice v7: `writeToSell` into a one-tick bid from a second address of the writer's own pays full rent.
    /// @dev This is the sweep's `test_poc_c05_writeToSellIntoOwn1TickBid_thenResell_dustFees`. Before v7 the writer
    ///      sold 100 units to itself at PRICE_TICK (1 base unit of premium), paying `premiumFeeBps` of that -- rounded
    ///      to nothing -- and then resold the longs at the real price for `resaleFeeBps` = 0, so the protocol saw a
    ///      handful of base units on a 250 USDG sale. v7 charges the mint, not the fill: the self-trade is now the
    ///      most expensive route, not the cheapest, because it pays rent AND two taker fees.
    function test_c05_selfTradeIntoAOneTickBidPaysFullRent() public {
        uint256 fee = ch.mintFee(c230, HUNDRED);
        // `alice` and `carol` are the same person's two addresses.
        _deposit(alice, address(nvda), ONE_SHARE + fee);
        uint256 dustBid = _place(carol, c230, BID, uint128(V2Constants.PRICE_TICK), HUNDRED);
        vm.prank(alice);
        (uint64 filled, uint256 premium, uint256 takerFee) =
            book.take(_sellParams(c230, _ids(dustBid), HUNDRED, true, alice));
        assertEq(filled, HUNDRED, "the self-trade filled");
        assertEq(premium, 100, "1 base unit per share x 100 units / 100");
        assertEq(takerFee, 10, "the taker fee cap, 10 % of a 100 base unit premium");

        // The seller fee on that premium is still dust...
        uint256 sellerFee = uint256(premium) * PREMIUM_FEE_BPS / V2Constants.BPS;
        assertEq(sellerFee, 5, "5 % of 100 base units");
        // ...but the writer already paid the rent at mint, whatever it charged itself for the longs.
        assertEq(ch.series(c230).mintFeesHeld, fee, "the dust fill did not make the rent dust");
        assertGt(fee, 100 * sellerFee, "rent dwarfs what the self-trade avoided");

        // Reselling at the real price still costs resaleFeeBps (0), and still refunds no rent.
        uint256 resale = _place(carol, c230, RESALE, 2_50000, HUNDRED);
        vm.prank(bob);
        book.take(_buyParams(c230, _ids(resale), HUNDRED, HUNDRED, bob));
        assertEq(ch.series(c230).mintFeesHeld, fee, "a resale is still fee-free, and still refunds nothing");
    }

    /*//////////////////////////////////////////////////////////////
                        CHARGE, REFUND, ACCRUE
    //////////////////////////////////////////////////////////////*/

    /// @notice The rent a pair pays is the time it was open: close it and the unused part comes back.
    function test_c05_closeRefundsTheUnusedRent() public {
        uint256 fee = ch.mintFee(c230, HUNDRED);
        _deposit(alice, address(nvda), ONE_SHARE + fee);
        vm.prank(alice);
        ch.setOperator(address(this), true);
        ch.mint(c230, HUNDRED, alice, alice);

        vm.warp(block.timestamp + 2 days);
        uint256 refund = ch.closeRefund(c230, HUNDRED);
        assertGt(refund, 0, "two days before expiry there is rent left");
        assertLt(refund, fee, "two days of the life were used");

        vm.prank(alice);
        ch.close(c230, HUNDRED);
        assertEq(ch.free(alice, address(nvda)), ONE_SHARE + refund, "collateral and the unused rent came back");
        assertEq(ch.series(c230).mintFeesHeld, fee - refund, "the series kept the rent that was used");
    }

    /// @notice Rent held at expiry becomes protocol revenue at {settle}, sweepable with the exercise fees.
    function test_c05_settleAccruesTheHeldRentAndSweepTakesItWithTheExerciseFees() public {
        uint256 fee = ch.mintFee(c230, HUNDRED);
        _deposit(alice, address(nvda), ONE_SHARE + fee);
        vm.prank(alice);
        ch.setOperator(address(this), true);
        ch.mint(c230, HUNDRED, alice, alice);

        _settleAt(E, 240_000_000, TICK_240);
        assertEq(ch.series(c230).mintFeesHeld, 0, "settle moved it out of the series");
        uint256 accrued = ch.accruedFees(address(nvda));
        assertGe(accrued, fee, "the rent is in accruedFees");

        vm.prank(keeper);
        ch.redeem(c230, alice);
        vm.prank(keeper);
        ch.redeem(V2Ids.shortIdOf(c230), alice);
        uint256 total = ch.accruedFees(address(nvda));
        assertGt(total, fee, "the exercise fee joined it");
        uint256 before = nvda.balanceOf(address(splitter));
        vm.prank(admin);
        ch.sweepFees(address(nvda));
        assertEq(nvda.balanceOf(address(splitter)) - before, total, "one sweep sends rent and exercise fees together");
    }

    /// @notice A put's rent is USDG, charged against the writer's USDG ledger and never against the strike it locks.
    function test_c05_putRentIsChargedInUsdgAndLeavesTheLockedStrikeAlone() public {
        uint64 units = 100;
        uint256 collateral = units * ch.collateralPerUnit(p210);
        uint256 fee = ch.mintFee(p210, units);
        assertGt(fee, 0, "a put pays rent too");

        _deposit(alice, address(usdg), collateral + fee);
        vm.prank(alice);
        ch.setOperator(address(this), true);
        ch.mint(p210, units, alice, alice);
        assertEq(ch.locked(p210), collateral, "locked is the strike, never the rent");
        assertEq(ch.free(alice, address(usdg)), 0, "rent came out of free USDG");
        assertEq(ch.series(p210).mintFeesHeld, fee, "the series holds it");

        _settleAt(E, 240_000_000, TICK_240);
        assertEq(ch.accruedFees(address(usdg)), fee, "a put's rent accrues in USDG");
    }

    /*//////////////////////////////////////////////////////////////
                        THE WHOLE STORY, WITH RENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Three writers, mints and closes across a week, a settlement and a sweep: every base unit is accounted
    ///         for at every step, and the protocol's rent revenue is exactly what was charged less what came back.
    /// @dev The model here is per writer, and it is the model the design asks the lifecycle suite for -- carried in
    ///      this suite instead, because the lifecycle story's premiums and payouts are hand-computed at `mintFeePpm`
    ///      0 (design §3.8) and turning rent on there would move numbers three work packages depend on.
    ///      I2' at every step: `balance == SUM free + SUM locked + SUM mintFeesHeld (unsettled) + accruedFees`.
    function test_c05_lifecycleConservesEveryBaseUnitOfRent() public {
        address[3] memory writers = [alice, bob, carol];
        uint256 charged;
        uint256 refunded;

        // Three writers mint at three different moments, so each pays for a different slice of the week.
        for (uint256 i; i < writers.length; ++i) {
            uint64 units = uint64(100 * (i + 1));
            uint256 fee = ch.mintFee(c230, units);
            _deposit(writers[i], address(nvda), uint256(units) * V2Constants.UNIT + fee);
            vm.prank(writers[i]);
            ch.setOperator(address(this), true);
            ch.mint(c230, units, writers[i], mm);
            charged += fee;
            assertEq(ch.series(c230).mintFeesHeld, charged, "every mint adds its rent to the series");
            _assertConserved("after a mint");
            vm.warp(block.timestamp + 1 days);
        }

        // Two of them buy their longs back and close; the third rides to expiry.
        for (uint256 i; i < 2; ++i) {
            uint64 units = uint64(100 * (i + 1));
            vm.prank(mm);
            ch.safeTransferFrom(mm, writers[i], c230, units, "");
            uint256 refund = ch.closeRefund(c230, units);
            vm.prank(writers[i]);
            ch.close(c230, units);
            refunded += refund;
            assertEq(ch.series(c230).mintFeesHeld, charged - refunded, "held is charged less refunded");
            _assertConserved("after a close");
            vm.warp(block.timestamp + 1 days);
        }
        assertLt(refunded, charged, "the time the pairs were open was not free");

        _settleAt(E, 240_000_000, TICK_240);
        assertEq(ch.series(c230).mintFeesHeld, 0, "settle emptied the series");
        uint256 rentRevenue = charged - refunded;
        assertGe(ch.accruedFees(address(nvda)), rentRevenue, "and the protocol has the rent it earned");
        _assertConserved("after settlement");

        // Redeem everyone and sweep: nothing of the rent is stranded.
        ch.redeem(c230, mm);
        for (uint256 i; i < writers.length; ++i) {
            ch.redeem(V2Ids.shortIdOf(c230), writers[i]);
        }
        _assertConserved("after redemptions");
        vm.prank(admin);
        ch.sweepFees(address(nvda));
        assertEq(ch.accruedFees(address(nvda)), 0, "swept");
        _assertConserved("after the sweep");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Invariant 2' for NVDA: the Clearinghouse holds exactly the ledger balances, the locked collateral, the
    ///      rent every unsettled series still holds and the fees it has accrued -- no more, and nothing stranded.
    function _assertConserved(string memory step) internal view {
        uint256 claims = ch.accruedFees(address(nvda));
        address[6] memory accounts = [alice, bob, carol, mm, treasury, chFees];
        for (uint256 i; i < accounts.length; ++i) {
            claims += ch.free(accounts[i], address(nvda));
        }
        uint256[2] memory ladder = [c230, p210];
        for (uint256 i; i < ladder.length; ++i) {
            if (ch.collateralAsset(ladder[i]) != address(nvda)) continue;
            claims += ch.locked(ladder[i]);
            V2Types.Series memory s = ch.series(ladder[i]);
            if (!s.settled) claims += s.mintFeesHeld;
        }
        assertEq(claims, nvda.balanceOf(address(ch)), string.concat(step, ": I2' holds exactly"));
    }

    function _rentMarket(uint32 ppm) internal view returns (V2Types.MarketConfig memory cfg) {
        cfg = _nvdaMarket();
        cfg.mintFeePpm = ppm;
    }

    /// @dev Prints two corroborating rounds into the TWAP window of `expiry`, snapshots inside the grace, finalizes at
    ///      expiry + FINALIZE_DELAY and settles both series of this fixture.
    function _settleAt(uint40 expiry, uint256 price, int24 tick) internal {
        _print(price, tick, expiry - 2 hours);
        _print(price, tick, expiry - 900);
        vm.warp(uint256(expiry) + 60);
        vm.prank(keeper);
        oracle.snapshot(address(nvda), expiry);
        vm.warp(uint256(expiry) + V2Constants.FINALIZE_DELAY);
        vm.prank(keeper);
        (bool finalized,) = oracle.finalize(address(nvda), expiry);
        assertTrue(finalized, "the two sources corroborated");
        vm.prank(keeper);
        assertTrue(ch.settle(c230), "the call settled");
        vm.prank(keeper);
        assertTrue(ch.settle(p210), "the put settled");
    }
}
