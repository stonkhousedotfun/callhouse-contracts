// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V2IntegrationBase} from "./V2IntegrationBase.t.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Ids} from "../../../src/v2/interfaces/V2Ids.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";

/// @notice The whole v2 story on the real contracts, for calls and puts, in and out of the money: register the market,
///         create a strike ladder, writers quote write-on-fill asks, buyers take 1, 10 and 100 units, longs are resold
///         (resale ask, a bid hit from inventory, a bid hit by writing), a writer buys back and closes, the mint cutoff
///         and expiry stop what they must, the keeper snapshots the pool and finalizes on two corroborating sources,
///         settles every series, prunes the book's leftover orders, redeems every holder with redeemBatch and sweeps
///         the exercise fees. Every wallet, ledger and fee balance is checked against an independent model after every
///         step, and value is conserved to the base unit.
/// @dev THE LADDER, NVDA weekly Friday 2026-09-18 (E), created at START with spot 220.00 (band [110, 440]):
///        calls 210 / 220 / 230 and puts 230 / 220 / 210.
///      THE SETTLEMENT PRICE. Feed rounds 221.00 at E - 2 h and 222.40 at E - 900, so the Chainlink TWAP over
///      [E - 1800, E] is (221.00 + 222.40) / 2 = 221.70 = P exactly. The pool follows at ticks 222340 / 222277 (mean tick
///      222308, 221.7017), 1 bp away: the sources corroborate and Chainlink (priority 0) gives the price.
///      At P = 221.70 (hand-computed with OptionMath's formulas, node BigInt, exercise fee 25 bps):
///        call 210 ITM  long 502_740_189_445_196  fee 25_000_000_000_000 (rate leg)  short 9_472_259_810_554_804
///        call 220 ITM  long  69_012_178_619_757  fee  7_668_019_846_639 (10 % cap)   short 9_923_319_801_533_604
///        call 230 OTM  long 0, fee 0, short UNIT
///        put  230 ITM  long 77_250  fee 5_750 (rate leg)  short 2_217_000 (USDG)
///        put  220 OTM  (no supply: settles without a SETTLE bounty)       put 210 OTM  long 0, short 2_100_000.
///      THE MODEL. `exp*` mirrors every wallet (USDG, NVDA) and ledger balance the story touches, updated by the fee
///      formulas of ADR-08 written out here (not read from the contracts): premium = price x units / 100; taker fee =
///      min(0.10, premium x 10 %); seller fee 5 % on primary fills, 0 on resale; each fill's share of the taker fee pro
///      rata by premium with the last fill taking the dust; rebate = share x 50 %.
contract LifecycleTest is V2IntegrationBase {
    uint40 internal constant E = FRI_2026_09_18;
    uint256 internal constant P = 221_700_000;
    int24 internal constant TICK_221_00 = 222340;
    int24 internal constant TICK_222_40 = 222277;

    uint256 internal constant C210_LONG = 502_740_189_445_196;
    uint256 internal constant C210_FEE = 25_000_000_000_000;
    uint256 internal constant C210_SHORT = 9_472_259_810_554_804;
    uint256 internal constant C220_LONG = 69_012_178_619_757;
    uint256 internal constant C220_FEE = 7_668_019_846_639;
    uint256 internal constant C220_SHORT = 9_923_319_801_533_604;
    uint256 internal constant P230_LONG = 77_250;
    uint256 internal constant P230_FEE = 5_750;
    uint256 internal constant P230_SHORT = 2_217_000;

    uint128 internal constant K210 = 210_000_000;
    uint128 internal constant K220 = 220_000_000;
    uint128 internal constant K230 = 230_000_000;

    /// @dev Series.
    uint256 internal c210;
    uint256 internal c220;
    uint256 internal c230;
    uint256 internal p230;
    uint256 internal p220;
    uint256 internal p210;
    uint256[6] internal ladder;

    /// @dev Orders: alice's and carol's write-on-fill asks, bob's resale asks, mm's bid.
    uint256 internal aC210;
    uint256 internal aC220;
    uint256 internal aC230;
    uint256 internal aP230;
    uint256 internal aP220;
    uint256 internal aP210;
    uint256 internal cC210;
    uint256 internal cP230;
    uint256 internal bResale210;
    uint256 internal bResale230;
    uint256 internal mBid230;

    /// @dev The model: wallet and ledger balances every address is expected to hold.
    mapping(address => uint256) internal expUsdg;
    mapping(address => uint256) internal expNvda;
    mapping(address => uint256) internal expFreeUsdg;
    mapping(address => uint256) internal expFreeNvda;
    address[] internal tracked;

    /// @dev What each series held at settlement, and what its redemptions paid (payouts + exercise fees).
    mapping(uint256 longId => uint256) internal lockedAtSettle;
    mapping(address asset => uint256) internal lockedAtSettleByAsset;
    mapping(address asset => uint256) internal paidOutByAsset;
    uint256 internal redeemBounties;

    struct Fill {
        address maker;
        uint128 price;
        uint64 units;
        bool primary;
    }

    function setUp() public override {
        super.setUp();
        address[4] memory traders = [alice, bob, carol, mm];
        for (uint256 i; i < traders.length; ++i) {
            _onboard(traders[i]);
        }
        address[11] memory everyone = [
            alice,
            bob,
            carol,
            mm,
            treasury,
            chFees,
            address(splitter),
            keeper,
            address(rewards),
            address(ch),
            address(book)
        ];
        for (uint256 i; i < everyone.length; ++i) {
            tracked.push(everyone[i]);
        }
        for (uint256 i; i < tracked.length; ++i) {
            address a = tracked[i];
            expUsdg[a] = usdg.balanceOf(a);
            expNvda[a] = nvda.balanceOf(a);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                THE STORY
    //////////////////////////////////////////////////////////////*/

    function test_lifecycle_weeklyLadder_callsAndPuts_itmAndOtm() public {
        _registerAndLadder();
        _writersQuote();
        _buyersTakeFractionalSizes();
        _resale();
        _buyBackAndClose();
        _cutoff();
        _expiry();
        _snapshotAndFinalize();
        _settle();
        _pruneResaleAsks();
        _redeemEveryHolder();
        _sweepAndConserve();
    }

    /// Register -> ladder: the market is admin-registered, the keeper creates the six series permissionlessly at
    /// START, each pins the oracle and the exercise fee, the strike band and grid are enforced, creation is idempotent.
    function _registerAndLadder() internal {
        vm.prank(keeper);
        vm.expectRevert(V2Errors.MarketDisabled.selector);
        ch.createSeries(address(nvda), false, K210, E);

        _registerNvda();
        V2Types.MarketConfig memory m = ch.market(address(nvda));
        assertTrue(m.enabled, "registered");
        assertEq(m.oracle, address(oracle), "oracle");
        assertEq(m.strikeTick, STRIKE_TICK, "tick");

        vm.startPrank(keeper);
        c210 = ch.createSeries(address(nvda), false, K210, E);
        c220 = ch.createSeries(address(nvda), false, K220, E);
        c230 = ch.createSeries(address(nvda), false, K230, E);
        p230 = ch.createSeries(address(nvda), true, K230, E);
        p220 = ch.createSeries(address(nvda), true, K220, E);
        p210 = ch.createSeries(address(nvda), true, K210, E);
        assertEq(ch.createSeries(address(nvda), false, K210, E), c210, "idempotent");
        vm.expectRevert(V2Errors.BadStrike.selector);
        ch.createSeries(address(nvda), false, 441_000_000, E); // above 2 x spot
        vm.expectRevert(V2Errors.BadStrike.selector);
        ch.createSeries(address(nvda), true, 109_000_000, E); // below spot / 2
        vm.expectRevert(V2Errors.BadStrike.selector);
        ch.createSeries(address(nvda), false, 210_500_000, E); // off the 1.00 grid
        vm.stopPrank();
        ladder = [c210, c220, c230, p230, p220, p210];

        V2Types.Series memory s = ch.series(p230);
        assertEq(s.underlying, address(nvda), "underlying");
        assertTrue(s.isPut, "put");
        assertEq(s.strike, K230, "strike");
        assertEq(s.expiry, E, "expiry");
        assertEq(s.oracle, address(oracle), "oracle pinned");
        assertEq(s.exerciseFeeBps, EXERCISE_FEE_BPS, "fee pinned");
        (bool pinned, address[] memory sources, uint16 dev, uint32 delay,) = oracle.settlementConfig(address(nvda), E);
        assertTrue(pinned, "the ladder pinned the expiry's settlement configuration");
        assertEq(sources.length, 2, "both sources");
        assertEq(sources[0], address(clSource), "Chainlink first");
        assertEq(dev + delay, 150 + 6 hours, "default deviation and delay");
        (address pinnedFeed,,, bool feedPinned) = clSource.pinnedFeeds(address(nvda), E);
        assertTrue(feedPinned && pinnedFeed == address(feed), "the feed pinned for E");
        (address pinnedPool,,,, bool poolPinned,) = poolSource.pinnedPools(address(nvda), E);
        assertTrue(poolPinned && pinnedPool == address(pool), "the pool pinned for E");
        assertEq(c210, V2Ids.longIdOf(address(nvda), false, K210, E), "id formula");
        assertEq(ch.mintCutoff(c210), E - V2Constants.SETTLEMENT_WINDOW, "cutoff");
    }

    /// Writers deposit collateral and quote write-on-fill asks on the ladder; no collateral moves until a fill.
    function _writersQuote() internal {
        _mDeposit(alice, address(nvda), 20e18);
        _mDeposit(alice, address(usdg), 20_000e6);
        _mDeposit(carol, address(nvda), 10e18);
        _mDeposit(carol, address(usdg), 10_000e6);
        vm.prank(mm);
        ch.setPayoutToLedger(true); // mm's payouts are credited to its ledger

        aC210 = _place(alice, c210, WRITE, 13_000_000, 200);
        aC220 = _place(alice, c220, WRITE, 5_000_000, 200);
        aC230 = _place(alice, c230, WRITE, 1_500_000, 200);
        aP230 = _place(alice, p230, WRITE, 10_000_000, 200);
        aP220 = _place(alice, p220, WRITE, 3_000_000, 200);
        aP210 = _place(alice, p210, WRITE, 800_000, 200);
        cC210 = _place(carol, c210, WRITE, 12_500_000, 100);
        cP230 = _place(carol, p230, WRITE, 10_500_000, 100);
        _check("quotes placed");
    }

    /// Buyers take 1, 10 and 100 units: a micro ticket (taker fee at the 10 % cap), a small one, and two 100-unit
    /// takes, one across two makers (one flat fee, rebates pro rata by premium).
    function _buyersTakeFractionalSizes() internal {
        uint256 bobBefore = usdg.balanceOf(bob);
        uint256 carolBefore = usdg.balanceOf(carol);
        uint256 splitterBefore = usdg.balanceOf(address(splitter));
        // 1 unit of the 210 call from carol at 12.50: premium 0.125, fee 0.0125 (cap), seller fee 0.00625, rebate
        // 0.00625.
        _buy(bob, c210, _ids(cC210, aC210), 1, _fills(Fill(carol, 12_500_000, 1, true)));
        assertEq(bobBefore - usdg.balanceOf(bob), 137_500, "1 unit: bob paid premium + capped fee");
        assertEq(usdg.balanceOf(carol) - carolBefore, 125_000, "1 unit: carol got premium - 5 % + rebate");
        assertEq(usdg.balanceOf(address(splitter)) - splitterBefore, 12_500, "1 unit: splitter");

        _buy(bob, c230, _ids(aC230), 10, _fills(Fill(alice, 1_500_000, 10, true)));

        bobBefore = usdg.balanceOf(bob);
        carolBefore = usdg.balanceOf(carol);
        uint256 aliceBefore = usdg.balanceOf(alice);
        splitterBefore = usdg.balanceOf(address(splitter));
        // 100 units across carol (99 left at 12.50) and alice (1 at 13.00): premium 12.505, one 0.10 fee, shares
        // 98_960 / 1_040, rebates 49_480 / 520.
        _buy(
            bob,
            c210,
            _ids(cC210, aC210),
            100,
            _fills(Fill(carol, 12_500_000, 99, true), Fill(alice, 13_000_000, 1, true))
        );
        assertEq(bobBefore - usdg.balanceOf(bob), 12_605_000, "100 units: bob");
        assertEq(usdg.balanceOf(carol) - carolBefore, 11_805_730, "100 units: carol");
        assertEq(usdg.balanceOf(alice) - aliceBefore, 124_020, "100 units: alice");
        assertEq(usdg.balanceOf(address(splitter)) - splitterBefore, 675_250, "100 units: splitter");

        _buy(
            bob,
            p230,
            _ids(aP230, cP230),
            100,
            _fills(Fill(alice, 10_000_000, 100, true)) // carol's dearer ask is named but not reached
        );
        _buy(carol, p210, _ids(aP210), 10, _fills(Fill(alice, 800_000, 10, true)));
        _buy(mm, c220, _ids(aC220), 50, _fills(Fill(alice, 5_000_000, 50, true)));

        assertEq(ch.balanceOf(bob, c210), 101, "bob 210 calls");
        assertEq(ch.balanceOf(carol, V2Ids.shortIdOf(c210)), 100, "carol wrote 100");
        assertEq(ch.balanceOf(alice, V2Ids.shortIdOf(c210)), 1, "alice wrote 1");
        assertEq(ch.balanceOf(bob, p230), 100, "bob 230 puts");
        assertEq(ch.balanceOf(alice, V2Ids.shortIdOf(p230)), 100, "alice wrote the puts");
        _check("buyers");
    }

    /// Resale: bob resells 210 calls to mm; mm bids for 230 puts and bob sells into the bid from inventory while
    /// carol sells into it by writing (writeToSell); bob lists 230 calls and alice buys 6 of them back.
    function _resale() internal {
        vm.prank(bob);
        bResale210 = book.place(c210, RESALE, 14_000_000, 40, 0);
        assertEq(ch.balanceOf(address(book), c210), 40, "escrow");
        _buy(mm, c210, _ids(bResale210), 30, _fills(Fill(bob, 14_000_000, 30, false)));

        mBid230 = _place(mm, p230, BID, 9_000_000, 60);
        expUsdg[mm] -= 5_400_000;
        assertEq(usdg.balanceOf(address(book)), 5_400_000, "bid escrow");
        _sell(bob, p230, _ids(mBid230), 40, false, _fills(Fill(mm, 9_000_000, 40, false)));
        _sell(carol, p230, _ids(mBid230), 10, true, _fills(Fill(mm, 9_000_000, 10, true)));
        assertEq(ch.balanceOf(mm, p230), 50, "mm bought 40 resold + 10 written");
        assertEq(ch.balanceOf(carol, V2Ids.shortIdOf(p230)), 10, "carol wrote into the bid");

        vm.prank(bob);
        bResale230 = book.place(c230, RESALE, 2_000_000, 10, 0);
        _buy(alice, c230, _ids(bResale230), 6, _fills(Fill(bob, 2_000_000, 6, false)));
        _check("resale");
    }

    /// Close: alice holds 6 longs and 10 shorts of the 230 call; closing 4 frees 4 units of collateral.
    function _buyBackAndClose() internal {
        vm.prank(alice);
        ch.close(c230, 4);
        expFreeNvda[alice] += 4 * V2Constants.UNIT;
        assertEq(ch.balanceOf(alice, c230), 2, "long left");
        assertEq(ch.balanceOf(alice, V2Ids.shortIdOf(c230)), 6, "short left");
        _check("close");
    }

    /// Cutoff: no more writing (place, mint, write-on-fill fills); resale still trades until expiry. The feed and the
    /// pool print the settlement window's prices.
    function _cutoff() internal {
        vm.warp(E - 2 hours);
        _print(221_000_000, TICK_221_00, E - 2 hours);

        vm.warp(E - V2Constants.SETTLEMENT_WINDOW);
        vm.prank(alice);
        vm.expectRevert(V2Errors.PastCutoff.selector);
        book.place(c210, WRITE, 13_000_000, 10, 0);
        // T-603: the subject here is the PastCutoff REFUSAL, so the call has to reach that check. Pranked as
        // `alice` it never did -- she is not allowlisted, so it died at NotMinter (Clearinghouse.sol:641) and the
        // test reported `NotMinter() != PastCutoff()`. The writer authorises the allowlisted sender first, and the
        // authorisation goes before the expectRevert because that cheatcode binds to the next call.
        vm.prank(alice);
        ch.setOperator(address(this), true);
        vm.expectRevert(V2Errors.PastCutoff.selector);
        ch.mint(c210, 1, alice, alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.BelowMinUnits.selector, uint64(0), uint64(1)));
        book.take(_buyParams(c220, _ids(aC220), 10, 1, bob));

        _buy(mm, c210, _ids(bResale210), 5, _fills(Fill(bob, 14_000_000, 5, false)));

        vm.warp(E - 900);
        _print(222_400_000, TICK_222_40, E - 900);
        _check("cutoff");
    }

    /// Expiry: trading stops for every kind, nothing settles before the oracle may finalize, and close still works.
    function _expiry() internal {
        vm.warp(E);
        vm.prank(mm);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.BelowMinUnits.selector, uint64(0), uint64(1)));
        book.take(_buyParams(c210, _ids(bResale210), 5, 1, mm));

        vm.prank(keeper);
        assertFalse(ch.settle(c210), "oracle not final: settle returns false");
        vm.prank(keeper);
        vm.expectRevert(V2Errors.NotSettled.selector);
        ch.redeem(c210, bob);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.TooEarly.selector, E + V2Constants.FINALIZE_DELAY));
        oracle.finalize(address(nvda), E);

        vm.prank(alice);
        ch.close(c230, 2); // after expiry, before settlement
        expFreeNvda[alice] += 2 * V2Constants.UNIT;
        _check("expiry");
    }

    /// Snapshot inside the grace, finalize at expiry + FINALIZE_DELAY: Chainlink and the pool corroborate.
    function _snapshotAndFinalize() internal {
        vm.warp(E + 60);
        vm.prank(keeper);
        assertEq(oracle.snapshot(address(nvda), E), 1, "the pool recorded; Chainlink stores nothing");
        _mBounty(SNAPSHOT_BOUNTY);
        (uint128 snap,,) = poolSource.snapshots(address(nvda), E);
        (, uint256 observed,,) = poolSource.observeWindow(address(nvda), E - V2Constants.SETTLEMENT_WINDOW, E);
        assertEq(snap, observed, "snapshot is the window, not the moment of the call");

        vm.warp(E + V2Constants.FINALIZE_DELAY);
        vm.prank(keeper);
        (bool finalized, uint256 price) = oracle.finalize(address(nvda), E);
        _mBounty(FINALIZE_BOUNTY);
        assertTrue(finalized, "finalized");
        assertEq(price, P, "Chainlink TWAP over the window");

        (V2Types.SettlementStatus status,, uint8 sourceIndex, bool corroborated, bool resolved, bool captured) =
            oracle.settlementInfo(address(nvda), E);
        assertEq(uint8(status), uint8(V2Types.SettlementStatus.Finalized), "status");
        assertEq(sourceIndex, 0, "priority 0");
        assertTrue(corroborated, "two sources corroborate");
        assertFalse(resolved, "not admin-resolved");
        assertTrue(captured, "captured");
        (, bool[] memory ok, uint256[] memory prices, uint16 dev) = oracle.recordedSources(address(nvda), E);
        assertTrue(ok[0] && ok[1], "both sources ok");
        assertEq(prices[0], P, "Chainlink");
        assertEq(prices[1], snap, "pool");
        uint256 gap = prices[1] > P ? prices[1] - P : P - prices[1];
        assertLe(gap * 10_000, P * dev, "within maxDeviationBps");
        assertLe(gap * 10_000, P * 1, "the pool is within 1 bp here");
        _check("finalized");
    }

    /// Settle every series: stored amounts match the hand-computed ones, conservation per unit, SETTLE bounty only
    /// for series with supply, idempotent.
    function _settle() internal {
        for (uint256 i; i < ladder.length; ++i) {
            uint256 id = ladder[i];
            vm.prank(keeper);
            assertTrue(ch.settle(id), "settled");
            if (ch.totalSupply(id) > 0) _mBounty(SETTLE_BOUNTY);
            V2Types.Series memory s = ch.series(id);
            assertEq(s.settlementPrice, P, "price");
            assertEq(
                uint256(s.longPayoutPerUnit) + s.feePerUnit + s.shortPayoutPerUnit,
                ch.collateralPerUnit(id),
                "long + fee + short == collateral per unit"
            );
            lockedAtSettle[id] = ch.locked(id);
            assertEq(lockedAtSettle[id], ch.totalSupply(id) * ch.collateralPerUnit(id), "locked at settlement");
            lockedAtSettleByAsset[ch.collateralAsset(id)] += lockedAtSettle[id];
            vm.prank(keeper);
            assertFalse(ch.settle(id), "idempotent");
        }
        _assertPerUnit(c210, C210_LONG, C210_FEE, C210_SHORT);
        _assertPerUnit(c220, C220_LONG, C220_FEE, C220_SHORT);
        _assertPerUnit(c230, 0, 0, V2Constants.UNIT);
        _assertPerUnit(p230, P230_LONG, P230_FEE, P230_SHORT);
        _assertPerUnit(p220, 0, 0, 2_200_000);
        _assertPerUnit(p210, 0, 0, 2_100_000);
        assertEq(lockedAtSettleByAsset[address(nvda)], (101 + 50 + 4) * V2Constants.UNIT, "NVDA locked");
        assertEq(lockedAtSettleByAsset[address(usdg)], 110 * 2_300_000 + 10 * 2_100_000, "USDG locked");
        _check("settled");
    }

    /// The book's escrow cannot be redeemed from under its makers; prune hands leftovers back (resale longs, bid USDG)
    /// and closes every dead write-on-fill ask.
    function _pruneResaleAsks() internal {
        vm.prank(keeper);
        vm.expectRevert(V2Errors.ThirdPartyRedeemDisabled.selector);
        ch.redeem(c210, address(book));

        uint256 n = book.lastOrderId();
        uint256[] memory all = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            all[i] = i + 1;
        }
        vm.prank(keeper);
        // Open at expiry: alice's six asks, carol's put ask, bob's two resale asks, mm's bid. carol's call ask filled.
        assertEq(book.prune(all), 10, "pruned");
        expUsdg[mm] += 900_000; // 10 units of the 9.00 bid
        assertEq(ch.balanceOf(address(book), c210), 0, "resale escrow returned");
        assertEq(ch.balanceOf(address(book), c230), 0, "resale escrow returned");
        assertEq(usdg.balanceOf(address(book)), 0, "bid escrow returned");
        vm.prank(keeper);
        assertEq(book.prune(all), 0, "nothing left");

        _assertHolding(c210, bob, 66, 0);
        _assertHolding(c210, mm, 35, 0);
        _assertHolding(c210, carol, 0, 100);
        _assertHolding(c210, alice, 0, 1);
        _assertHolding(c220, mm, 50, 0);
        _assertHolding(c220, alice, 0, 50);
        _assertHolding(c230, bob, 4, 0);
        _assertHolding(c230, alice, 0, 4);
        _assertHolding(p230, bob, 60, 0);
        _assertHolding(p230, mm, 50, 0);
        _assertHolding(p230, alice, 0, 100);
        _assertHolding(p230, carol, 0, 10);
        _assertHolding(p210, carol, 10, 0);
        _assertHolding(p210, alice, 0, 10);
        _check("pruned");
    }

    /// redeemBatch every long and short id over every holder: each payout is balance x per-unit amount, in kind to the
    /// wallet (or the ledger for mm), and the REDEEM bounty is paid for each payout worth >= 1 USDG.
    function _redeemEveryHolder() internal {
        address[] memory holders = _holders();
        for (uint256 i; i < ladder.length; ++i) {
            for (uint256 side; side < 2; ++side) {
                uint256 id = side == 0 ? ladder[i] : V2Ids.shortIdOf(ladder[i]);
                uint256 expected = _modelRedeem(id, holders);
                vm.prank(keeper);
                assertEq(ch.redeemBatch(id, holders), expected, "holders redeemed");
                assertEq(ch.totalSupply(id), 0, "every token redeemed");
            }
            assertEq(ch.locked(ladder[i]), 0, "series paid out");
        }
        assertEq(ch.openInterest(address(nvda), E), 0, "no open interest");
        assertEq(redeemBounties, 11, "REDEEM bounties: payouts worth >= 1 USDG");
        _check("redeemed");
    }

    /// Sweep the exercise fees, then conservation: what was locked at settlement is exactly what was paid out plus the
    /// fees, the Clearinghouse holds exactly its ledger, the book holds nothing, and after every writer withdraws the
    /// Clearinghouse is empty.
    function _sweepAndConserve() internal {
        uint256 nvdaFees = 101 * C210_FEE + 50 * C220_FEE;
        uint256 usdgFees = 110 * P230_FEE;
        assertEq(ch.accruedFees(address(nvda)), nvdaFees, "NVDA fees accrued");
        assertEq(ch.accruedFees(address(usdg)), usdgFees, "USDG fees accrued");
        vm.startPrank(keeper);
        ch.sweepFees(address(nvda));
        ch.sweepFees(address(usdg));
        vm.stopPrank();
        expNvda[address(splitter)] += nvdaFees;
        expUsdg[address(splitter)] += usdgFees;
        paidOutByAsset[address(nvda)] += nvdaFees;
        paidOutByAsset[address(usdg)] += usdgFees;

        assertEq(paidOutByAsset[address(nvda)], lockedAtSettleByAsset[address(nvda)], "NVDA: payouts + fees == locked");
        assertEq(paidOutByAsset[address(usdg)], lockedAtSettleByAsset[address(usdg)], "USDG: payouts + fees == locked");
        assertEq(expUsdg[keeper], SNAPSHOT_BOUNTY + FINALIZE_BOUNTY + 5 * SETTLE_BOUNTY + 11 * REDEEM_BOUNTY, "keeper");
        _check("swept");

        address[4] memory traders = [alice, bob, carol, mm];
        for (uint256 i; i < traders.length; ++i) {
            address t = traders[i];
            uint256 u = ch.free(t, address(usdg));
            uint256 s = ch.free(t, address(nvda));
            vm.startPrank(t);
            if (u != 0) ch.withdraw(address(usdg), u, t);
            if (s != 0) ch.withdraw(address(nvda), s, t);
            vm.stopPrank();
            (expUsdg[t], expFreeUsdg[t]) = (expUsdg[t] + u, 0);
            (expNvda[t], expFreeNvda[t]) = (expNvda[t] + s, 0);
        }
        _check("withdrawn");
        assertEq(usdg.balanceOf(address(ch)), 0, "Clearinghouse USDG empty");
        assertEq(nvda.balanceOf(address(ch)), 0, "Clearinghouse NVDA empty");
    }

    /*//////////////////////////////////////////////////////////////
                                THE MODEL
    //////////////////////////////////////////////////////////////*/

    function _mDeposit(address who, address asset, uint256 amount) internal {
        _deposit(who, asset, amount);
        if (asset == address(usdg)) {
            (expUsdg[who], expFreeUsdg[who]) = (expUsdg[who] - amount, expFreeUsdg[who] + amount);
        } else {
            (expNvda[who], expFreeNvda[who]) = (expNvda[who] - amount, expFreeNvda[who] + amount);
        }
    }

    function _mBounty(uint256 amount) internal {
        expUsdg[keeper] += amount;
        expUsdg[address(rewards)] -= amount;
    }

    /// @dev A buying take by `taker` for itself, checked against the model.
    function _buy(address taker, uint256 longId, uint256[] memory ids, uint64 units, Fill[] memory fills) internal {
        (uint64 wantUnits, uint256 wantPremium, uint256 wantFee) = _modelTake(taker, longId, fills, true, false);
        vm.prank(taker);
        (uint64 filled, uint256 premium, uint256 fee) = book.take(_buyParams(longId, ids, units, 0, taker));
        assertEq(filled, wantUnits, "units filled");
        assertEq(premium, wantPremium, "premium");
        assertEq(fee, wantFee, "taker fee");
        _check("buy");
    }

    /// @dev A selling take by `taker` for itself (from inventory, or writing), checked against the model.
    function _sell(
        address taker,
        uint256 longId,
        uint256[] memory ids,
        uint64 units,
        bool writeToSell,
        Fill[] memory fills
    ) internal {
        (uint64 wantUnits, uint256 wantPremium, uint256 wantFee) = _modelTake(taker, longId, fills, false, writeToSell);
        vm.prank(taker);
        (uint64 filled, uint256 premium, uint256 fee) = book.take(_sellParams(longId, ids, units, writeToSell, taker));
        assertEq(filled, wantUnits, "units filled");
        assertEq(premium, wantPremium, "premium");
        assertEq(fee, wantFee, "taker fee");
        _check("sell");
    }

    /// @dev ADR-08 for one take. Buying: the taker pays premium + fee; each maker gets premium - seller fee + rebate
    ///      (bid escrow is not involved); a primary fill spends the maker's free collateral. Selling: the escrow of the
    ///      bids pays the premium; the taker (recipient) gets premium - seller fees - fee; bid makers get their rebates;
    ///      writeToSell spends the taker's free collateral. INTERFACE_VERSION 8: the FeeSplitter gets seller fees +
    ///      fee - rebates (OrderBook._payOrOwe to {feeRecipient}, which the fixture set to the splitter).
    function _modelTake(address taker, uint256 longId, Fill[] memory fills, bool buying, bool writeToSell)
        internal
        returns (uint64 units, uint256 premium, uint256 fee)
    {
        uint256 n = fills.length;
        uint256[] memory premiums = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            premiums[i] = uint256(fills[i].price) * fills[i].units / 100;
            premium += premiums[i];
            units += fills[i].units;
        }
        uint256 byCap = premium * TAKER_FEE_CAP_BPS / 10_000;
        fee = byCap < TAKER_FEE_FLAT ? byCap : TAKER_FEE_FLAT;

        uint256 cut;
        uint256 rebates;
        uint256 sellerFees;
        for (uint256 i; i < n; ++i) {
            Fill memory f = fills[i];
            uint256 share = i + 1 == n ? fee - cut : fee * premiums[i] / premium;
            cut += share;
            uint256 rebate = share * MAKER_REBATE_BPS / 10_000;
            uint256 sellerFee = premiums[i] * (f.primary ? PREMIUM_FEE_BPS : RESALE_FEE_BPS) / 10_000;
            rebates += rebate;
            sellerFees += sellerFee;
            if (buying) {
                expUsdg[f.maker] += premiums[i] - sellerFee + rebate;
                if (f.primary) _mSpendCollateral(f.maker, longId, f.units);
            } else {
                expUsdg[f.maker] += rebate;
                if (writeToSell) _mSpendCollateral(taker, longId, f.units);
            }
        }
        if (buying) {
            expUsdg[taker] -= premium + fee;
        } else {
            expUsdg[taker] += premium - sellerFees - fee;
        }
        expUsdg[address(splitter)] += sellerFees + fee - rebates;
    }

    function _mSpendCollateral(address writer, uint256 longId, uint64 units) internal {
        V2Types.Series memory s = ch.series(longId);
        if (s.isPut) expFreeUsdg[writer] -= uint256(units) * (s.strike / 100);
        else expFreeNvda[writer] -= uint256(units) * V2Constants.UNIT;
    }

    /// @dev The payouts a redeemBatch of `id` over `holders` must make, applied to the model; returns how many holders
    ///      hold the id. Per-unit amounts were checked against hand-computed values in {_settle}.
    function _modelRedeem(uint256 id, address[] memory holders) internal returns (uint256 count) {
        uint256 longId = id & ~uint256(1);
        V2Types.Series memory s = ch.series(longId);
        bool isLong = id == longId;
        uint256 perUnit = isLong ? s.longPayoutPerUnit : s.shortPayoutPerUnit;
        for (uint256 i; i < holders.length; ++i) {
            address h = holders[i];
            uint256 bal = ch.balanceOf(h, id);
            if (bal == 0) continue;
            ++count;
            uint256 owed = bal * perUnit;
            paidOutByAsset[s.isPut ? address(usdg) : address(nvda)] += owed;
            (, bool toLedger) = ch.payoutPrefs(h);
            if (s.isPut) {
                if (toLedger) expFreeUsdg[h] += owed;
                else expUsdg[h] += owed;
            } else {
                if (toLedger) expFreeNvda[h] += owed;
                else expNvda[h] += owed;
            }
            uint256 value = s.isPut ? owed : owed * s.settlementPrice / 1e18;
            if (value != 0 && value >= ch.minRedeemPayout()) {
                ++redeemBounties;
                _mBounty(REDEEM_BOUNTY);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 CHECKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Every modelled balance, invariant 2 per asset (the Clearinghouse holds exactly its ledger, locked and
    ///      fees), the book's escrow identity, and total supply accounted for by the tracked addresses.
    function _check(string memory step) internal view {
        for (uint256 i; i < tracked.length; ++i) {
            address a = tracked[i];
            // The Clearinghouse and the book hold what their identities below say.
            if (a == address(ch) || a == address(book)) continue;
            string memory who = vm.getLabel(a);
            assertEq(usdg.balanceOf(a), expUsdg[a], string.concat(step, ": USDG wallet of ", who));
            assertEq(nvda.balanceOf(a), expNvda[a], string.concat(step, ": NVDA wallet of ", who));
            assertEq(ch.free(a, address(usdg)), expFreeUsdg[a], string.concat(step, ": USDG ledger of ", who));
            assertEq(ch.free(a, address(nvda)), expFreeNvda[a], string.concat(step, ": NVDA ledger of ", who));
        }
        uint256 usdgClaims = ch.accruedFees(address(usdg));
        uint256 nvdaClaims = ch.accruedFees(address(nvda));
        uint256 usdgSupply;
        uint256 nvdaSupply;
        for (uint256 i; i < tracked.length; ++i) {
            usdgClaims += ch.free(tracked[i], address(usdg));
            nvdaClaims += ch.free(tracked[i], address(nvda));
            usdgSupply += usdg.balanceOf(tracked[i]);
            nvdaSupply += nvda.balanceOf(tracked[i]);
        }
        uint256 bidEscrow;
        for (uint256 i; i < ladder.length; ++i) {
            uint256 id = ladder[i];
            if (id == 0) continue;
            bool isUsdg = ch.collateralAsset(id) == address(usdg);
            if (isUsdg) usdgClaims += ch.locked(id);
            else nvdaClaims += ch.locked(id);
            // I2' (INTERFACE_VERSION 7): collateral rent an unsettled series holds is a claim of its own until close
            // refunds it or settle accrues it. This fixture runs at `mintFeePpm` 0 (design §3.8), so the story's
            // hand-computed premiums and payouts are unchanged and this term is 0 -- which is itself the assertion
            // below: v7 charges a market that set no rate exactly nothing, on every route the story walks.
            V2Types.Series memory s = ch.series(id);
            assertEq(s.mintFeePpm, 0, string.concat(step, ": the fixture's rate is 0"));
            assertEq(s.mintFeesHeld, 0, string.concat(step, ": and no rent was charged anywhere"));
            if (!s.settled) {
                if (isUsdg) usdgClaims += s.mintFeesHeld;
                else nvdaClaims += s.mintFeesHeld;
            }
            (uint256 resale, uint256 bids) = _openEscrow(id);
            bidEscrow += bids;
            assertEq(ch.balanceOf(address(book), id), resale, string.concat(step, ": book longs == resale escrow"));
        }
        assertEq(usdgClaims, usdg.balanceOf(address(ch)), string.concat(step, ": USDG ledger + locked + fees"));
        assertEq(nvdaClaims, nvda.balanceOf(address(ch)), string.concat(step, ": NVDA ledger + locked + fees"));
        assertEq(usdg.balanceOf(address(book)), bidEscrow, string.concat(step, ": book USDG == bid escrow"));
        assertEq(usdgSupply, usdg.totalSupply(), string.concat(step, ": USDG accounted for"));
        assertEq(nvdaSupply, nvda.totalSupply(), string.concat(step, ": NVDA accounted for"));
    }

    function _openEscrow(uint256 longId) internal view returns (uint256 resaleUnits, uint256 bidUsdg) {
        (uint256[] memory ids,) = book.ordersOfSeries(longId, 0, 100);
        V2Types.Order[] memory orders = book.getOrders(ids);
        for (uint256 i; i < orders.length; ++i) {
            V2Types.Order memory o = orders[i];
            if (o.cancelled) continue;
            uint256 left = o.units - o.filled;
            if (o.kind == RESALE) resaleUnits += left;
            else if (o.kind == BID) bidUsdg += uint256(o.price) * left / 100;
        }
    }

    function _assertPerUnit(uint256 id, uint256 longPer, uint256 feePer, uint256 shortPer) internal view {
        V2Types.Series memory s = ch.series(id);
        assertEq(s.longPayoutPerUnit, longPer, "long per unit");
        assertEq(s.feePerUnit, feePer, "fee per unit");
        assertEq(s.shortPayoutPerUnit, shortPer, "short per unit");
    }

    function _assertHolding(uint256 longId, address who, uint256 longs, uint256 shorts) internal view {
        assertEq(ch.balanceOf(who, longId), longs, "long holding");
        assertEq(ch.balanceOf(who, V2Ids.shortIdOf(longId)), shorts, "short holding");
    }

    function _fills(Fill memory a) internal pure returns (Fill[] memory f) {
        f = new Fill[](1);
        f[0] = a;
    }

    function _fills(Fill memory a, Fill memory b) internal pure returns (Fill[] memory f) {
        f = new Fill[](2);
        (f[0], f[1]) = (a, b);
    }
}
