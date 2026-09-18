// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {V2IntegrationBase} from "./V2IntegrationBase.t.sol";
import {AutoRoller} from "../../../src/v2/AutoRoller.sol";
import {KeeperRewards} from "../../../src/v2/KeeperRewards.sol";
import {IOrderBook} from "../../../src/v2/interfaces/IOrderBook.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Ids} from "../../../src/v2/interfaces/V2Ids.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MakerVault} from "../../../src/v2/mm/MakerVault.sol";
import {MockPayoutAdapter} from "../../../src/v2/mocks/MockPayoutAdapter.sol";
import {MockVerifierProxy} from "../../../src/v2/mocks/MockVerifierProxy.sol";
import {DataStreamsSource} from "../../../src/v2/oracle/DataStreamsSource.sol";

/// @notice The numbers docs/V2-ARCHITECTURE.md and docs/V2-ACCOUNTING.md quote that no other suite asserts on its own:
///         the per-contract constants, the expiry clock across the 2026 DST switch, every intermediate figure of the
///         order-book fee examples (seller fee, taker-fee share and rebate of each fill, read from OrderFilled), and the
///         redemption of a one-share ticket (owed stock, its value at the settlement price, the conversion floor, the
///         exercise fee and the writer's remainder). Everything runs on the real contracts of V2IntegrationBase.
/// @dev A docs example that changes must change here first: `forge test --match-contract V2DocsNumbersTest -vv` prints
///      every figure with its name. The fee and settlement stories repeat LifecycleTest's trades and prices
///      (test/v2/integration/Lifecycle.t.sol), so the two suites agree on every total.
///
///      UNITS as in src/v2: prices USDG base units (6 dp) per whole share, units 0.01 share, NVDA amounts 18-dp base
///      units, fees and rebates USDG base units unless the asset says otherwise. No contract is mocked except the
///      tokens, the feed, the pool and (in the redemption story) the payout adapter.
contract V2DocsNumbersTest is V2IntegrationBase {
    uint40 internal constant E = FRI_2026_09_18;
    /// @dev The Chainlink TWAP over [E - 1800, E] of LifecycleTest's two prints: (221.00 + 222.40) / 2.
    uint256 internal constant SETTLE_PRICE = 221_700_000;
    int24 internal constant TICK_221_00 = 222340;
    int24 internal constant TICK_222_40 = 222277;

    uint128 internal constant K210 = 210_000_000;
    uint128 internal constant K220 = 220_000_000;
    uint128 internal constant K230 = 230_000_000;

    /// @dev One OrderFilled, decoded.
    struct Filled {
        address maker;
        uint64 units;
        uint128 price;
        uint256 premium;
        uint256 sellerFee;
        uint256 makerRebate;
        bool primary;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// V2-ARCHITECTURE.md "Values no role can change" and the per-contract bounds quoted there. V2Constants itself is
    /// pinned by InterfaceIdsTest.
    function test_docs_contractConstants() public {
        // SettlementOracle: parameter defaults and bounds, source count.
        assertEq(uint256(oracle.SETTLEMENT_WINDOW()), 1800, "window");
        assertEq(uint256(oracle.DEFAULT_MAX_DEVIATION_BPS()), 150, "default deviation");
        assertEq(uint256(oracle.MAX_DEVIATION_CEIL_BPS()), 1000, "deviation ceiling");
        assertEq(uint256(oracle.DEFAULT_UNCORROBORATED_DELAY()), 6 hours, "default delay");
        assertEq(uint256(oracle.MIN_UNCORROBORATED_DELAY()), 30 minutes, "min delay");
        assertEq(uint256(oracle.MAX_UNCORROBORATED_DELAY()), 24 hours, "max delay");
        assertEq(uint256(oracle.DEFAULT_SPOT_MAX_AGE()), 1 hours, "default spot age");
        assertEq(uint256(oracle.MAX_SPOT_MAX_AGE()), 4 days, "max spot age");
        assertEq(oracle.MAX_SOURCES(), 8, "sources per market");

        // ChainlinkFeedSource.
        assertEq(clSource.MAX_ROUND_READS(), 96, "round reads");
        assertEq(uint256(clSource.DEFAULT_MAX_STALE()), 26 hours, "default maxStale");
        assertEq(uint256(clSource.MIN_MAX_STALE()), 1 hours, "min maxStale");
        assertEq(uint256(clSource.MAX_MAX_STALE()), 7 days, "max maxStale");
        assertEq(uint256(clSource.DEFAULT_MAX_ROUND_JUMP_BPS()), 2000, "default jump");
        assertEq(uint256(clSource.MAX_ROUND_JUMP_CEIL_BPS()), 5000, "jump ceiling");

        // UniV3TwapSource.
        assertEq(uint256(poolSource.DEFAULT_WINDOW()), 300, "latest window");
        assertEq(uint256(poolSource.MIN_WINDOW()), 60, "min window");
        assertEq(uint256(poolSource.MAX_WINDOW()), 1 hours, "max window");

        // DataStreamsSource (built, disabled).
        DataStreamsSource ds = new DataStreamsSource(admin, address(new MockVerifierProxy()));
        assertEq(ds.RING_SIZE(), 256, "ring");
        assertEq(ds.MIN_OBSERVATIONS(), 10, "observations per window");
        assertEq(uint256(ds.MAX_GAP()), 300, "max gap");
        assertEq(uint256(ds.MIN_OBSERVATION_SPACING()), 30, "spacing");
        assertEq(uint256(ds.MAX_REPORT_AGE()), 60, "report age");
        assertEq(uint256(ds.MAX_MID_AGE()), 300, "mid age");
        assertEq(uint256(ds.MARKET_STATUS_REGULAR()), 2, "regular hours status");

        // Clearinghouse, ExpiryCalendar, KeeperRewards.
        assertEq(uint256(ch.DEFAULT_MIN_REDEEM_PAYOUT()), 1_000_000, "min redeem payout constant");
        assertEq(uint256(ch.minRedeemPayout()), 1_000_000, "min redeem payout at deploy");
        assertEq(uint256(calendar.NEXT_EXPIRY_SEARCH()), 14 days, "nextExpiry search");
        KeeperRewards fresh = new KeeperRewards(IERC20(address(usdg)), admin);
        assertEq(fresh.dailyCap(), 0, "a new KeeperRewards pays nothing");

        // AutoRoller.
        AutoRoller roller = new AutoRoller(IOrderBook(address(book)), admin);
        assertEq(uint256(roller.MIN_OTM_BPS()), 100, "min otm");
        assertEq(uint256(roller.MAX_OTM_BPS()), 2500, "max otm");
        assertEq(uint256(roller.MIN_ASK_BPS()), 5, "min ask");
        assertEq(uint256(roller.MAX_ASK_BPS()), 1000, "max ask");
        assertEq(uint256(roller.DAILY_MIN_LEAD()), 2 hours, "daily lead");
        assertEq(uint256(roller.WEEKLY_MIN_LEAD()), 24 hours, "weekly lead");
        assertEq(uint256(roller.minRollUnits()), 100, "min roll units at deploy");

        // MakerVault.
        MakerVault vault = new MakerVault(
            IOrderBook(address(book)),
            admin,
            address(0),
            MakerVault.Limits({
                maxSeriesUnits: 0,
                maxTotalNotional: 0,
                askToleranceBps: 0,
                maxBidBpsOfSpot: 0,
                maxOrderLifetime: 0,
                maxDailyOutflow: 0
            })
        );
        assertEq(vault.MAX_LIVE_ORDERS_PER_SERIES(), 16, "live orders per series");
        assertEq(vault.OUTFLOW_WINDOW(), 1 days, "outflow refill window (INTERFACE_VERSION 7)");

        // INTERFACE_VERSION 7 shared constants: the collateral rent and the pool ring the c10 sign-off needs.
        assertEq(V2Constants.PPM, 1_000_000, "rent denominator");
        assertEq(uint256(V2Constants.MINT_FEE_PERIOD), 7 days, "rent is quoted per week of remaining life");
        assertEq(uint256(V2Constants.MINT_FEE_CEIL_PPM), 5_000, "rent ceiling, 0.5 %/week of the locked collateral");
        assertEq(uint256(roller.ROLL_OPEN_GRACE()), 30 minutes, "open grace");
        assertEq(
            V2Constants.MIN_POOL_OBSERVATION_CARDINALITY,
            2401,
            "a UniV3 source needs a ring that outlasts a flood through the snapshot grace"
        );

        emit log_named_uint("oracle default deviation bps", oracle.DEFAULT_MAX_DEVIATION_BPS());
        emit log_named_uint("oracle default uncorroborated delay s", oracle.DEFAULT_UNCORROBORATED_DELAY());
        emit log_named_uint("chainlink default maxStale s", clSource.DEFAULT_MAX_STALE());
        emit log_named_uint("chainlink default jump bps", clSource.DEFAULT_MAX_ROUND_JUMP_BPS());
    }

    /*//////////////////////////////////////////////////////////////
                             EXPIRY CLOCK
    //////////////////////////////////////////////////////////////*/

    /// V2-ARCHITECTURE.md "16:00 New York in UTC shifts with DST": the close is 20:00 UTC in EDT and 21:00 UTC in EST,
    /// and the grid crosses the 2026-11-01 switch from Friday 20:00 UTC to Monday 21:00 UTC.
    function test_docs_expiryClockShiftsWithDst() public view {
        uint40 fri0918 = 1_789_761_600; // 2026-09-18 20:00 UTC
        uint40 fri1030 = 1_793_390_400; // 2026-10-30 20:00 UTC
        uint40 mon1102 = 1_793_653_200; // 2026-11-02 21:00 UTC
        uint40 fri1218 = 1_797_627_600; // 2026-12-18 21:00 UTC
        assertEq(fri0918, E, "the fixture's weekly");
        assertEq(calendar.closeOf(20_714), fri0918, "2026-09-18 close");
        assertEq(uint256(fri0918) % 1 days, 20 hours, "EDT: 20:00 UTC");
        assertEq(calendar.closeOf(20_805), fri1218, "2026-12-18 close");
        assertEq(uint256(fri1218) % 1 days, 21 hours, "EST: 21:00 UTC");
        assertEq(calendar.newYorkOffset(fri0918), -4 hours, "EDT offset");
        assertEq(calendar.newYorkOffset(fri1218), -5 hours, "EST offset");
        assertTrue(calendar.isValidExpiry(fri1030) && calendar.isWeekly(fri1030), "Friday weekly before the switch");
        assertEq(calendar.nextExpiry(fri1030, false), mon1102, "next daily is Monday, one hour later in UTC");
        assertFalse(calendar.isValidExpiry(mon1102 - 1 hours), "20:00 UTC is not a close after the switch");
    }

    /*//////////////////////////////////////////////////////////////
                           ORDER BOOK FEES
    //////////////////////////////////////////////////////////////*/

    /// V2-ACCOUNTING.md "A micro ticket" and "A one-share ticket across two makers" (LifecycleTest's first and third
    /// buys, with every fill's seller fee, taker-fee share and rebate read from its OrderFilled).
    function test_docs_orderBookFees_microTicketAndOneShare() public {
        uint256 c210 = _market();
        _deposit(carol, address(nvda), 1e18);
        _deposit(alice, address(nvda), 2e18);
        uint256 askCarol = _place(carol, c210, WRITE, 12_500_000, 100);
        uint256 askAlice = _place(alice, c210, WRITE, 13_000_000, 200);
        uint256 carolFree = ch.free(carol, address(nvda));

        // Micro ticket: 1 unit (0.01 share) from carol at 12.50.
        uint256[4] memory before = _usdgOf(bob, carol, alice, treasury);
        vm.recordLogs();
        vm.prank(bob);
        (uint64 units, uint256 premium, uint256 takerFee) =
            book.take(_buyParams(c210, _ids(askCarol, askAlice), 1, 1, bob));
        Filled[] memory f = _filled(vm.getRecordedLogs());
        assertEq(units, 1, "micro: units");
        assertEq(premium, 125_000, "micro: premium = 12_500_000 x 1 / 100");
        assertEq(takerFee, 12_500, "micro: taker fee = min(100_000, 10 % of 125_000)");
        assertEq(f.length, 1, "micro: one fill");
        _assertFill(f[0], carol, 1, 12_500_000, 125_000, 6_250, 6_250, true);
        uint256[4] memory afterIt = _usdgOf(bob, carol, alice, treasury);
        assertEq(before[0] - afterIt[0], 137_500, "micro: buyer pays premium + taker fee");
        assertEq(afterIt[1] - before[1], 125_000, "micro: maker gets premium - seller fee + rebate");
        assertEq(afterIt[3] - before[3], 12_500, "micro: fee recipient gets seller fee + taker fee - rebate");
        assertEq(carolFree - ch.free(carol, address(nvda)), 1e16, "micro: one unit of NVDA collateral locked");
        _logTake("micro", premium, takerFee, f);

        // One-share ticket: 100 units across carol (99 left at 12.50) and alice (1 at 13.00), one taker fee.
        before = afterIt;
        vm.recordLogs();
        vm.prank(bob);
        (units, premium, takerFee) = book.take(_buyParams(c210, _ids(askCarol, askAlice), 100, 100, bob));
        f = _filled(vm.getRecordedLogs());
        assertEq(units, 100, "share: units");
        assertEq(premium, 12_505_000, "share: premium = 12_375_000 + 130_000");
        assertEq(takerFee, 100_000, "share: taker fee is the flat 0.10");
        assertEq(f.length, 2, "share: two fills");
        _assertFill(f[0], carol, 99, 12_500_000, 12_375_000, 618_750, 49_480, true);
        _assertFill(f[1], alice, 1, 13_000_000, 130_000, 6_500, 520, true);
        afterIt = _usdgOf(bob, carol, alice, treasury);
        assertEq(before[0] - afterIt[0], 12_605_000, "share: buyer");
        assertEq(afterIt[1] - before[1], 11_805_730, "share: carol");
        assertEq(afterIt[2] - before[2], 124_020, "share: alice");
        assertEq(afterIt[3] - before[3], 675_250, "share: fee recipient");
        assertEq(ch.balanceOf(bob, c210), 101, "bob's longs");
        _logTake("one share", premium, takerFee, f);
    }

    /// V2-ACCOUNTING.md "Selling into a bid" (LifecycleTest's resale step on a call): a sale from inventory pays no
    /// seller fee (resale fee 0); a sale that writes the longs (writeToSell) is primary and pays the premium fee.
    function test_docs_orderBookFees_sellIntoBid() public {
        uint256 c210 = _market();
        _deposit(alice, address(nvda), 1e18);
        _deposit(carol, address(nvda), 1e18);
        vm.prank(alice);
        ch.mint(c210, 40, alice, bob); // bob holds 40 longs to sell

        uint256 bid = _place(mm, c210, BID, 9_000_000, 60);
        assertEq(usdg.balanceOf(address(book)), 5_400_000, "bid escrow = 9_000_000 x 60 / 100");

        // bob sells 40 from his wallet.
        uint256[4] memory before = _usdgOf(bob, mm, carol, treasury);
        vm.recordLogs();
        vm.prank(bob);
        (uint64 units, uint256 premium, uint256 takerFee) = book.take(_sellParams(c210, _ids(bid), 40, false, bob));
        Filled[] memory f = _filled(vm.getRecordedLogs());
        assertEq(units, 40, "inventory: units");
        assertEq(premium, 3_600_000, "inventory: premium");
        assertEq(takerFee, 100_000, "inventory: flat taker fee");
        _assertFill(f[0], mm, 40, 9_000_000, 3_600_000, 0, 50_000, false);
        uint256[4] memory afterIt = _usdgOf(bob, mm, carol, treasury);
        assertEq(afterIt[0] - before[0], 3_500_000, "inventory: seller gets premium - taker fee");
        assertEq(afterIt[1] - before[1], 50_000, "inventory: bid maker gets its rebate");
        assertEq(afterIt[3] - before[3], 50_000, "inventory: fee recipient");
        _logTake("sell from inventory", premium, takerFee, f);

        // carol writes 10 into the rest of the bid.
        before = afterIt;
        uint256 carolFree = ch.free(carol, address(nvda));
        vm.recordLogs();
        vm.prank(carol);
        (units, premium, takerFee) = book.take(_sellParams(c210, _ids(bid), 10, true, carol));
        f = _filled(vm.getRecordedLogs());
        assertEq(units, 10, "write: units");
        assertEq(premium, 900_000, "write: premium");
        assertEq(takerFee, 90_000, "write: taker fee at the 10 % cap");
        _assertFill(f[0], mm, 10, 9_000_000, 900_000, 45_000, 45_000, true);
        afterIt = _usdgOf(bob, mm, carol, treasury);
        assertEq(afterIt[2] - before[2], 765_000, "write: seller gets premium - seller fee - taker fee");
        assertEq(afterIt[1] - before[1], 45_000, "write: bid maker rebate");
        assertEq(afterIt[3] - before[3], 90_000, "write: fee recipient");
        assertEq(carolFree - ch.free(carol, address(nvda)), 10e16, "write: carol's collateral locked");
        assertEq(ch.balanceOf(mm, c210), 50, "mm bought 50");
        assertEq(usdg.balanceOf(address(book)), 900_000, "the bid's last 10 units stay escrowed");
        _logTake("sell by writing", premium, takerFee, f);
    }

    /*//////////////////////////////////////////////////////////////
                        SETTLEMENT AND REDEMPTION
    //////////////////////////////////////////////////////////////*/

    /// V2-ACCOUNTING.md "Settlement" and "Redemption" worked examples: 100 units (one share) each of the 210, 220 and
    /// 230 calls and the 230 put, settled at 221.70 on two corroborating sources, then every holder redeemed. The 210
    /// call long converts to USDG through an adapter at the 100 bps slippage bound; the rest is paid in kind.
    function test_docs_settlementAndRedemption() public {
        uint256 c210 = _market();
        vm.startPrank(keeper);
        uint256 c220 = ch.createSeries(address(nvda), false, K220, E);
        uint256 c230 = ch.createSeries(address(nvda), false, K230, E);
        uint256 p230 = ch.createSeries(address(nvda), true, K230, E);
        vm.stopPrank();
        _deposit(alice, address(nvda), 3e18);
        _deposit(alice, address(usdg), 230e6);
        vm.startPrank(alice);
        ch.mint(c210, 100, alice, bob);
        ch.mint(c220, 100, alice, carol);
        ch.mint(c230, 100, alice, bob);
        ch.mint(p230, 100, alice, bob);
        vm.stopPrank();
        assertEq(ch.locked(c210), 1e18, "a one-share call locks 1 NVDA");
        assertEq(ch.locked(p230), 230_000_000, "a one-share put locks the strike in USDG");
        assertEq(ch.openInterest(address(nvda), E), 400, "open interest in units");

        vm.warp(E - 2 hours);
        _print(221_000_000, TICK_221_00, E - 2 hours);
        vm.warp(E - 900);
        _print(222_400_000, TICK_222_40, E - 900);
        vm.warp(E + 60);
        vm.prank(keeper);
        oracle.snapshot(address(nvda), E);
        vm.warp(E + 120);
        vm.prank(keeper);
        (bool finalized, uint256 price) = oracle.finalize(address(nvda), E);
        assertTrue(finalized, "corroborated");
        assertEq(price, SETTLE_PRICE, "(221.00 x 900 + 222.40 x 900) / 1800");
        vm.startPrank(keeper);
        assertTrue(ch.settle(c210) && ch.settle(c220) && ch.settle(c230) && ch.settle(p230), "settled");
        vm.stopPrank();

        // Per unit (0.01 share).
        _assertPerUnit(c210, 502_740_189_445_196, 25_000_000_000_000, 9_472_259_810_554_804);
        _assertPerUnit(c220, 69_012_178_619_757, 7_668_019_846_639, 9_923_319_801_533_604);
        _assertPerUnit(c230, 0, 0, 1e16);
        _assertPerUnit(p230, 77_250, 5_750, 2_217_000);
        uint256 gross210 = 502_740_189_445_196 + 25_000_000_000_000;
        assertEq(gross210, 527_740_189_445_196, "210 call gross per unit");
        assertEq(gross210 * SETTLE_PRICE / 1e18, 116_999, "gross value floors below 11.70 / 100");
        assertEq(uint256(69_012_178_619_757) + 7_668_019_846_639, 76_680_198_466_396, "220 call gross per unit");
        assertEq(uint256(76_680_198_466_396) / 10, 7_668_019_846_639, "220: the fee is 10 % of gross");
        assertEq(uint256(1e16) * 25 / 10_000, 25_000_000_000_000, "210: the fee is the 25 bps rate leg");
        assertEq(ch.collateralPerUnit(p230), 2_300_000, "230 put collateral per unit");
        assertEq(uint256(77_250) + 5_750, 83_000, "230 put gross per unit: (230.00 - 221.70) / 100");
        assertEq(uint256(2_300_000) * 25 / 10_000, 5_750, "230 put: the fee is the 25 bps rate leg");

        // 210 call long, converted: owed stock, its value at P, and the conversion floor at 100 bps.
        MockPayoutAdapter adapter = new MockPayoutAdapter(IERC20(address(usdg)), SETTLE_PRICE);
        usdg.mint(address(adapter), 100e6);
        vm.prank(admin);
        ch.setPayoutAdapter(address(adapter), 100);
        assertEq(adapter.routeFeeBps(address(nvda)), 0, "the example adapter reports no route fee");
        uint256 bobUsdg = usdg.balanceOf(bob);
        uint256 keeperUsdg = usdg.balanceOf(keeper);
        vm.prank(keeper);
        (uint256 paid, bool inUsdg) = ch.redeem(c210, bob);
        assertTrue(inUsdg, "converted");
        assertEq(adapter.lastAmountIn(), 50_274_018_944_519_600, "owed: 100 x long per unit");
        assertEq(uint256(50_274_018_944_519_600) * SETTLE_PRICE / 1e18, 11_145_749, "value at P");
        (bool spotOk, uint256 spot, uint256 spotAt) = oracle.trySpot(address(nvda));
        assertTrue(spotOk, "spot ok");
        assertEq(spot, 222_400_000, "the feed's last print is the spot, above P");
        assertEq(block.timestamp - spotAt, 1_020, "and at most 1 h old, so the floor is valued at it");
        assertEq(uint256(50_274_018_944_519_600) * 222_400_000 / 1e18, 11_180_941, "value at the spot");
        assertEq(
            adapter.lastMinOut(), 11_069_131, "minOut = value at the spot x (10_000 - (100 + route fee 0)) / 10_000"
        );
        assertEq(paid, 11_145_749, "paid at a fair rate");
        assertEq(usdg.balanceOf(bob) - bobUsdg, 11_145_749, "bob's USDG");
        assertEq(usdg.balanceOf(keeper) - keeperUsdg, REDEEM_BOUNTY, "value >= 1 USDG: REDEEM bounty");
        assertEq(ch.accruedFees(address(nvda)), 2_500_000_000_000_000, "exercise fee: 100 x 25e12");
        assertEq(uint256(2_500_000_000_000_000) * SETTLE_PRICE / 1e18, 554_250, "exercise fee value at P");

        // 220 call long, in kind by preference: the 10 % cap set the fee.
        vm.prank(carol);
        ch.setPayoutInKind(true);
        uint256 carolNvda = nvda.balanceOf(carol);
        vm.prank(keeper);
        (paid, inUsdg) = ch.redeem(c220, carol);
        assertFalse(inUsdg, "in kind");
        assertEq(paid, 6_901_217_861_975_700, "220 call long owed");
        assertEq(nvda.balanceOf(carol) - carolNvda, 6_901_217_861_975_700, "carol's NVDA");
        assertEq(uint256(6_901_217_861_975_700) * SETTLE_PRICE / 1e18, 1_530_000, "value at P");

        // Writer's shorts: the call remainders are worth the strike at P; the OTM call returns everything.
        uint256 aliceNvda = nvda.balanceOf(alice);
        vm.startPrank(keeper);
        (uint256 short210,) = ch.redeem(V2Ids.shortIdOf(c210), alice);
        (uint256 short220,) = ch.redeem(V2Ids.shortIdOf(c220), alice);
        (uint256 long230,) = ch.redeem(c230, bob);
        (uint256 short230,) = ch.redeem(V2Ids.shortIdOf(c230), alice);
        vm.stopPrank();
        assertEq(short210, 947_225_981_055_480_400, "210 short");
        assertEq(50_274_018_944_519_600 + 2_500_000_000_000_000 + short210, 1e18, "210: long + fee + short == 1 NVDA");
        assertEq(short210 * SETTLE_PRICE / 1e18, 210_000_000, "210 short worth the strike at P");
        assertEq(short220, 992_331_980_153_360_400, "220 short");
        assertEq(short220 * SETTLE_PRICE / 1e18, 220_000_000, "220 short worth the strike at P");
        assertEq(long230, 0, "OTM long burns for nothing");
        assertEq(short230, 1e18, "OTM short gets its share back");
        assertEq(nvda.balanceOf(alice) - aliceNvda, short210 + short220 + short230, "alice's NVDA");

        // 230 put: USDG both sides.
        vm.startPrank(keeper);
        (uint256 putLong,) = ch.redeem(p230, bob);
        (uint256 putShort,) = ch.redeem(V2Ids.shortIdOf(p230), alice);
        vm.stopPrank();
        assertEq(putLong, 7_725_000, "put long");
        assertEq(putShort, 221_700_000, "put short");
        assertEq(ch.accruedFees(address(usdg)), 575_000, "put exercise fee");
        assertEq(putLong + putShort + 575_000, 230_000_000, "put: payouts + fee == locked");

        // Conservation: every series paid out exactly what it locked.
        uint256 nvdaFees = 2_500_000_000_000_000 + 100 * 7_668_019_846_639;
        assertEq(ch.accruedFees(address(nvda)), nvdaFees, "NVDA fees");
        assertEq(
            50_274_018_944_519_600 + 6_901_217_861_975_700 + short210 + short220 + short230 + nvdaFees, 3e18, "NVDA"
        );
        assertEq(ch.locked(c210) + ch.locked(c220) + ch.locked(c230) + ch.locked(p230), 0, "nothing left locked");
        assertEq(ch.openInterest(address(nvda), E), 0, "no open interest");
        assertEq(nvda.balanceOf(address(ch)), nvdaFees, "the Clearinghouse holds only the fees");
        assertEq(usdg.balanceOf(address(ch)), 575_000, "and in USDG too");

        emit log_named_uint("210 call long per unit (NVDA base units)", 502_740_189_445_196);
        emit log_named_uint("210 call long, 100 units, value at P (USDG base units)", 11_145_749);
        emit log_named_uint("conversion minOut at 100 bps", adapter.lastMinOut());
        emit log_named_uint("210 short, 100 units (NVDA base units)", short210);
        emit log_named_uint("230 put long, 100 units (USDG base units)", putLong);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Registers NVDA, onboards the traders and creates the 210 call of E at START (spot 220.00).
    function _market() internal returns (uint256 c210) {
        _registerNvda();
        address[4] memory traders = [alice, bob, carol, mm];
        for (uint256 i; i < traders.length; ++i) {
            _onboard(traders[i]);
        }
        vm.prank(keeper);
        c210 = ch.createSeries(address(nvda), false, K210, E);
    }

    function _usdgOf(address a, address b, address c, address d) internal view returns (uint256[4] memory bal) {
        bal = [usdg.balanceOf(a), usdg.balanceOf(b), usdg.balanceOf(c), usdg.balanceOf(d)];
    }

    /// @dev Every OrderFilled the book emitted, in log order.
    function _filled(Vm.Log[] memory logs) internal view returns (Filled[] memory out) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(book) && logs[i].topics[0] == IOrderBook.OrderFilled.selector) ++n;
        }
        out = new Filled[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(book) || logs[i].topics[0] != IOrderBook.OrderFilled.selector) continue;
            Filled memory f;
            (f.maker, f.units, f.price, f.premium, f.sellerFee, f.makerRebate, f.primary,,) =
                abi.decode(logs[i].data, (address, uint64, uint128, uint256, uint256, uint256, bool, bool, address));
            out[n++] = f;
        }
    }

    function _assertFill(
        Filled memory f,
        address maker,
        uint64 units,
        uint128 price,
        uint256 premium,
        uint256 sellerFee,
        uint256 rebate,
        bool primary
    ) internal pure {
        assertEq(f.maker, maker, "fill maker");
        assertEq(uint256(f.units), uint256(units), "fill units");
        assertEq(uint256(f.price), uint256(price), "fill price");
        assertEq(f.premium, premium, "fill premium");
        assertEq(f.sellerFee, sellerFee, "fill seller fee");
        assertEq(f.makerRebate, rebate, "fill rebate");
        assertEq(f.primary, primary, "fill primary");
    }

    function _assertPerUnit(uint256 longId, uint256 longPer, uint256 feePer, uint256 shortPer) internal view {
        V2Types.Series memory s = ch.series(longId);
        assertEq(s.settlementPrice, SETTLE_PRICE, "settlement price");
        assertEq(s.longPayoutPerUnit, longPer, "long per unit");
        assertEq(s.feePerUnit, feePer, "fee per unit");
        assertEq(s.shortPayoutPerUnit, shortPer, "short per unit");
        assertEq(longPer + feePer + shortPer, ch.collateralPerUnit(longId), "long + fee + short == collateral");
    }

    function _logTake(string memory label, uint256 premium, uint256 takerFee, Filled[] memory f) internal {
        emit log_named_string("take", label);
        emit log_named_uint("  premium", premium);
        emit log_named_uint("  taker fee", takerFee);
        for (uint256 i; i < f.length; ++i) {
            emit log_named_uint("  fill premium", f[i].premium);
            emit log_named_uint("  fill seller fee", f[i].sellerFee);
            emit log_named_uint("  fill rebate", f[i].makerRebate);
        }
    }
}
