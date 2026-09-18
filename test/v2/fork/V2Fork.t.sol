// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {ExpiryCalendar} from "../../../src/v2/ExpiryCalendar.sol";
import {KeeperRewards} from "../../../src/v2/KeeperRewards.sol";
import {OrderBook} from "../../../src/v2/OrderBook.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Ids} from "../../../src/v2/interfaces/V2Ids.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {OptionMath} from "../../../src/v2/lib/OptionMath.sol";
import {ChainlinkFeedSource} from "../../../src/v2/oracle/ChainlinkFeedSource.sol";
import {IUniswapV3PoolOracle} from "../../../src/v2/oracle/OracleDeps.sol";
import {SettlementOracle} from "../../../src/v2/oracle/SettlementOracle.sol";
import {UniV3TwapSource} from "../../../src/v2/oracle/UniV3TwapSource.sol";

/// @notice The v2 core deployed on a fork of chain 4663 over the REAL NVDA Stock Token, USDG, Chainlink NVDA feed and
///         NVDA/USDG Uniswap v3 pool. The first test writes a call series through the order book, has it bought and
///         partly re-listed, settles it on the feed's real round history corroborated by the pool's real price over
///         the same window, prunes the book's leftovers, redeems every holder in real NVDA, sweeps the fees, and checks
///         value is conserved in both tokens to the base unit. The second settles the most recent weekly close on the
///         feed alone, through the uncorroborated candidate and its 6 h veto window.
/// @dev Run with:  FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC --match-path "test/v2/fork/V2Fork.t.sol" -vv
///      Without a fork (chain id != 4663) every test logs and returns, as test/fork/ForkLive.t.sol does.
///
///      WHICH EXPIRY. The public RPC forks at its latest block and keeps no historical state, and warping backwards
///      past the pool's newest observation breaks v3's observation arithmetic (test/v2/fork/SourcesFork.t.sol), so the
///      series settles on a close that has ALREADY happened: the most recent WEEKLY close whose settlement window the
///      pool's observation ring still covers, else the most recent session close it covers (the ring holds about 2-3
///      days, so a Friday weekly is reachable from Friday evening to early in the next week; other days settle the
///      last daily close, which the Clearinghouse and the oracle treat identically). If the ring covers no window, the
///      test is skipped with the reason, never passed silently.
///
///      HOW A PAST EXPIRY IS TRADED. Series creation, deposits, orders and takes read no price source, so the test
///      warps back to two hours before that close to create the series and trade it (the band check sees no fresh
///      spot then and is skipped), and warps forward to the fork's own block before anything touches the feed or pool.
///
///      THE POOL SNAPSHOT. UniV3TwapSource.record only works inside [expiry, expiry + SNAPSHOT_GRACE]. When the fork is
///      that fresh the keeper's real SettlementOracle.snapshot records it. Otherwise the test writes into the real
///      source's `snapshots` slot exactly what `record` would have stored, read from the live pool by the same source
///      code path (`observeWindow` over [expiry - 1800, expiry] is `record` without the storage write, C2-03), and
///      checks it through the public getter. Everything after that, capture, corroboration, settlement and payouts,
///      runs unmodified on the production wiring: sources [ChainlinkFeedSource, UniV3TwapSource].
contract V2ForkTest is Test {
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address internal constant NVDA_POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;

    /// @dev Registry values (callhouse ops/markets/tier1.json): NVDA strike grid 2.50 USDG, 25 bps exercise fee.
    uint64 internal constant NVDA_STRIKE_TICK = 2_500_000;
    uint16 internal constant EXERCISE_FEE_BPS = 25;
    uint128 internal constant NVDA_MIN_LIQUIDITY = 1e18;
    /// @dev UniV3TwapSource storage slot of `snapshots` (forge inspect UniV3TwapSource storageLayout).
    uint256 internal constant SNAPSHOTS_SLOT = 2;

    /// @dev The ask the writer quotes, USDG base units per share.
    uint128 internal constant ASK = 8_000_000;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal keeper = makeAddr("keeper");
    address internal treasury = makeAddr("treasury");
    address internal chFees = makeAddr("chFees");
    address internal writer = makeAddr("writer");
    address internal buyer1 = makeAddr("buyer1");
    address internal buyer2 = makeAddr("buyer2");

    IERC20 internal usdg = IERC20(USDG);
    IERC20 internal nvda = IERC20(NVDA);

    ExpiryCalendar internal calendar;
    ChainlinkFeedSource internal clSource;
    UniV3TwapSource internal poolSource;
    SettlementOracle internal oracle;
    KeeperRewards internal rewards;
    Clearinghouse internal ch;
    OrderBook internal book;

    /// @dev The fork's own block time, kept in storage: never read block.timestamp back after a warp (via_ir).
    uint256 internal forkNow;

    modifier onlyFork() {
        if (block.chainid != 4663) {
            console2.log("skipping: not forked onto 4663 (chainid %s)", block.chainid);
            return;
        }
        _;
    }

    function setUp() public {
        if (block.chainid != 4663) return;
        forkNow = block.timestamp;

        calendar = new ExpiryCalendar(admin, _nyseClosures());
        clSource = new ChainlinkFeedSource(admin);
        poolSource = new UniV3TwapSource(admin, USDG);
        oracle = new SettlementOracle(admin, guardian);
        rewards = new KeeperRewards(usdg, admin);
        ch = new Clearinghouse(admin, USDG, address(calendar), chFees, "https://app.stonkhouse.fun/api/token/");
        book = new OrderBook(
            IClearinghouse(address(ch)),
            admin,
            guardian,
            treasury,
            V2Types.FeeParams({
                premiumFeeBps: 500, resaleFeeBps: 0, takerFeeFlat: 100_000, takerFeeCapBps: 1000, makerRebateBps: 5000
            })
        );

        address[] memory sources = new address[](2);
        (sources[0], sources[1]) = (address(clSource), address(poolSource));
        vm.startPrank(admin);
        clSource.setFeed(NVDA, NVDA_FEED, clSource.DEFAULT_MAX_STALE(), clSource.DEFAULT_MAX_ROUND_JUMP_BPS());
        poolSource.setPool(NVDA, NVDA_POOL, NVDA_MIN_LIQUIDITY, poolSource.DEFAULT_WINDOW());
        clSource.setOracle(address(oracle), true);
        poolSource.setOracle(address(oracle), true);
        oracle.setMarket(NVDA, sources, 0, 0, 0);
        oracle.setClearinghouse(address(ch));
        oracle.setKeeperRewards(address(rewards));
        ch.grantRole(V2Constants.GUARDIAN_ROLE, guardian);
        ch.setKeeperRewards(address(rewards));
        ch.registerMarket(
            NVDA,
            V2Types.MarketConfig({
                enabled: true,
                mintPaused: false,
                strikeTick: NVDA_STRIKE_TICK,
                exerciseFeeBps: EXERCISE_FEE_BPS,
                oracle: address(oracle),
                mintFeePpm: 0
            })
        );
        rewards.setCaller(address(oracle), true);
        rewards.setCaller(address(ch), true);
        rewards.setBounty(V2Constants.ACTION_SNAPSHOT, 50_000);
        rewards.setBounty(V2Constants.ACTION_FINALIZE, 100_000);
        rewards.setBounty(V2Constants.ACTION_SETTLE, 50_000);
        rewards.setBounty(V2Constants.ACTION_REDEEM, 20_000);
        rewards.setDailyCap(10e6);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                THE SERIES
    //////////////////////////////////////////////////////////////*/

    function test_fork_callSeries_settlesOnRealHistory_twoSourcesCorroborate_payoutsConserve() public onlyFork {
        (uint40 expiry, bool weekly) = _chooseExpiry();
        if (expiry == 0) {
            console2.log("skipping: the pool's observation ring covers no recent session window");
            vm.skip(true);
            return;
        }
        console2.log(weekly ? "expiry: weekly close" : "expiry: daily close (no weekly window in the ring)", expiry);
        console2.log("seconds since the close:", forkNow - expiry);
        assertTrue(calendar.isValidExpiry(expiry), "a calendar expiry");

        (bool feedOk, uint256 feedPrice) = clSource.windowPrice(NVDA, expiry - V2Constants.SETTLEMENT_WINDOW, expiry);
        if (!feedOk) {
            console2.log("skipping: the feed walk cannot price the window from this block (more than 96 rounds since)");
            vm.skip(true);
            return;
        }
        if (!_fund()) return;
        // An in-the-money call: strike 3 % under the window price, on the 2.50 grid.
        uint128 strike = uint128(OptionMath.roundDownToTick(feedPrice * 97 / 100, NVDA_STRIKE_TICK));
        console2.log("feed window price, strike (USDG 6dp):", feedPrice, strike);

        (uint256 longId, uint256 resaleAsk) = _tradeBeforeTheClose(strike, expiry);
        _snapshotPool(expiry);

        // Finalize on the real round history: two sources, corroborated.
        vm.prank(keeper);
        (bool finalized, uint256 price) = oracle.finalize(NVDA, expiry);
        console2.log("gas: finalize (capture over the live feed walk + corroborate):", vm.lastCallGas().gasTotalUsed);
        assertTrue(finalized, "finalized");
        assertEq(price, feedPrice, "the Chainlink window price, priority 0");
        (V2Types.SettlementStatus status,, uint8 sourceIndex, bool corroborated,,) = oracle.settlementInfo(NVDA, expiry);
        assertEq(uint8(status), uint8(V2Types.SettlementStatus.Finalized), "status");
        assertTrue(corroborated, "the feed and the pool corroborate");
        assertEq(sourceIndex, 0, "Chainlink");
        (, bool[] memory ok, uint256[] memory prices, uint16 dev) = oracle.recordedSources(NVDA, expiry);
        assertTrue(ok[0] && ok[1], "both sources recorded ok");
        uint256 gap = prices[0] > prices[1] ? prices[0] - prices[1] : prices[1] - prices[0];
        console2.log("recorded feed, pool (USDG 6dp):", prices[0], prices[1]);
        console2.log("deviation, bps x 100:", gap * 1_000_000 / prices[0]);
        assertLe(gap * 10_000, (prices[0] < prices[1] ? prices[0] : prices[1]) * dev, "within maxDeviationBps");

        _settleRedeemAndConserve(longId, resaleAsk, price);
    }

    /// The most recent WEEKLY close, whatever the pool ring still covers: nobody snapshotted the pool in its grace, so
    /// the oracle announces the feed's real window price as an uncorroborated candidate, finalizes it after the 6 h
    /// veto window, and the series pays out and conserves value. With the test above this covers both settlement paths
    /// on live data, and a weekly expiry on every run.
    function test_fork_lastWeeklyCall_settlesOnFeedHistoryAfterTheDelay() public onlyFork {
        uint40 expiry;
        for (uint256 i; i < 10 && expiry == 0; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint32 day = uint32(forkNow / 1 days - i);
            uint256 close = calendar.closeOf(day);
            // forge-lint: disable-next-line(unsafe-typecast)
            if (close + V2Constants.FINALIZE_DELAY <= forkNow && calendar.isWeekly(uint40(close))) {
                // casting to 'uint40' is safe because close is a 16:00 New York close in 2026
                // forge-lint: disable-next-line(unsafe-typecast)
                expiry = uint40(close);
            }
        }
        assertGt(expiry, 0, "a weekly close in the last 10 days");
        console2.log("weekly close:", expiry, "seconds ago:", forkNow - expiry);
        (bool feedOk, uint256 feedPrice) = clSource.windowPrice(NVDA, expiry - V2Constants.SETTLEMENT_WINDOW, expiry);
        if (!feedOk) {
            console2.log("skipping: the feed walk cannot price that window from this block (more than 96 rounds since)");
            vm.skip(true);
            return;
        }
        if (!_deal(NVDA, writer, 10e18)) return;
        if (!_deal(USDG, address(rewards), 100e6)) return;
        uint128 strike = uint128(OptionMath.roundUpToTick(feedPrice * 102 / 100, NVDA_STRIKE_TICK)); // out of the money

        vm.warp(expiry - 2 hours);
        vm.prank(keeper);
        uint256 longId = ch.createSeries(NVDA, false, strike, expiry);
        vm.startPrank(writer);
        nvda.approve(address(ch), type(uint256).max);
        ch.deposit(NVDA, 10e18, writer);
        ch.mint(longId, 250, writer, buyer1);
        vm.stopPrank();
        vm.warp(forkNow);

        vm.prank(keeper);
        (bool finalized,) = oracle.finalize(NVDA, expiry);
        assertFalse(finalized, "one source: a candidate, not a price");
        (uint256 candidatePrice, uint8 index, bool disagreed, uint40 finalizableAt) = oracle.candidate(NVDA, expiry);
        assertEq(candidatePrice, feedPrice, "the feed's real window price");
        assertEq(index, 0, "Chainlink");
        assertFalse(disagreed, "the pool did not answer, it did not disagree");
        assertEq(finalizableAt, forkNow + 6 hours, "the 6 h veto window");
        vm.prank(keeper);
        assertFalse(ch.settle(longId), "settle waits for the window");

        vm.warp(finalizableAt);
        vm.prank(keeper);
        assertTrue(ch.settle(longId), "settle finalizes the candidate and settles");
        (V2Types.SettlementStatus status, uint256 price,, bool corroborated,,) = oracle.settlementInfo(NVDA, expiry);
        assertEq(uint8(status), uint8(V2Types.SettlementStatus.Finalized), "final");
        assertEq(price, feedPrice, "at the feed's window price");
        assertFalse(corroborated, "uncorroborated");

        V2Types.Series memory s = ch.series(longId);
        assertEq(s.longPayoutPerUnit + s.feePerUnit, 0, "out of the money: the long gets nothing");
        assertEq(s.shortPayoutPerUnit, V2Constants.UNIT, "the writer gets the whole unit back");
        uint256 writerBefore = nvda.balanceOf(writer);
        vm.startPrank(keeper);
        (uint256 paidLong,) = ch.redeem(longId, buyer1);
        (uint256 paidShort,) = ch.redeem(V2Ids.shortIdOf(longId), writer);
        vm.stopPrank();
        assertEq(paidLong, 0, "zero-value burn");
        assertEq(paidShort, 250 * V2Constants.UNIT, "collateral back");
        assertEq(nvda.balanceOf(writer) - writerBefore, 250 * V2Constants.UNIT, "in real NVDA");
        assertEq(ch.locked(longId), 0, "nothing locked");
        assertEq(nvda.balanceOf(address(ch)), ch.free(writer, NVDA), "the Clearinghouse holds exactly its ledger");
    }

    /*//////////////////////////////////////////////////////////////
                                  STEPS
    //////////////////////////////////////////////////////////////*/

    /// @dev Two hours before the close: create the series, the writer quotes 300 units write-on-fill, buyer1 takes 100
    ///      and buyer2 50, buyer1 re-lists 20. Then back to the fork's block.
    function _tradeBeforeTheClose(uint128 strike, uint40 expiry) internal returns (uint256 longId, uint256 resaleAsk) {
        vm.warp(expiry - 2 hours);
        vm.prank(keeper);
        longId = ch.createSeries(NVDA, false, strike, expiry);
        (address pinnedFeed,,, bool feedPinned) = clSource.pinnedFeeds(NVDA, expiry);
        (address pinnedPool,,,, bool poolPinned,) = poolSource.pinnedPools(NVDA, expiry);
        assertTrue(feedPinned && pinnedFeed == NVDA_FEED, "the live NVDA feed pinned for the expiry");
        assertTrue(poolPinned && pinnedPool == NVDA_POOL, "the live NVDA pool pinned for the expiry");

        vm.startPrank(writer);
        nvda.approve(address(ch), type(uint256).max);
        ch.deposit(NVDA, 10e18, writer);
        ch.setOperator(address(book), true);
        uint256 ask = book.place(longId, V2Types.OrderKind.AskWrite, ASK, 300, 0);
        vm.stopPrank();

        uint256 writerUsdg = usdg.balanceOf(writer);
        uint256 treasuryUsdg = usdg.balanceOf(treasury);
        uint256 buyersUsdg = usdg.balanceOf(buyer1) + usdg.balanceOf(buyer2);
        _buy(buyer1, longId, ask, 100);
        _buy(buyer2, longId, ask, 50);
        // premium 8.00 and 4.00 USDG, each take one 0.10 fee; seller fee 5 %; rebate half the fee.
        assertEq(buyersUsdg - usdg.balanceOf(buyer1) - usdg.balanceOf(buyer2), 12_200_000, "buyers paid premium + fees");
        assertEq(usdg.balanceOf(writer) - writerUsdg, 11_500_000, "writer: premium - 5 % + rebates, real USDG");
        assertEq(usdg.balanceOf(treasury) - treasuryUsdg, 700_000, "treasury: seller fees + fees - rebates");
        assertEq(usdg.balanceOf(address(book)), 0, "the book keeps nothing");
        assertEq(ch.free(writer, NVDA), 10e18 - 150 * V2Constants.UNIT, "collateral locked by the fills");

        vm.startPrank(buyer1);
        ch.setApprovalForAll(address(book), true);
        resaleAsk = book.place(longId, V2Types.OrderKind.AskResale, ASK + 1_000_000, 20, 0);
        vm.stopPrank();

        vm.warp(forkNow);
    }

    function _buy(address buyer, uint256 longId, uint256 ask, uint64 units) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = ask;
        vm.startPrank(buyer);
        usdg.approve(address(book), type(uint256).max);
        book.take(
            V2Types.TakeParams({
                longId: longId,
                buying: true,
                orderIds: ids,
                units: units,
                minUnits: units,
                limitPrice: ASK,
                writeToSell: false,
                recipient: buyer,
                deadline: type(uint40).max
            })
        );
        vm.stopPrank();
    }

    /// @dev The keeper's real snapshot when the fork is inside the grace; otherwise what `record` would have stored,
    ///      read from the live pool through the source's own window code (see the contract NatSpec).
    function _snapshotPool(uint40 expiry) internal {
        (bool ok, uint256 price, int24 meanTick, uint256 liquidity) =
            poolSource.observeWindow(NVDA, expiry - V2Constants.SETTLEMENT_WINDOW, expiry);
        console2.log("pool window price (USDG 6dp), harmonic liquidity:", price, liquidity);
        assertTrue(ok, "the live pool prices the window above the liquidity floor");
        if (forkNow <= uint256(expiry) + V2Constants.SNAPSHOT_GRACE) {
            vm.prank(keeper);
            assertEq(oracle.snapshot(NVDA, expiry), 1, "the keeper's snapshot records the pool");
        } else {
            bytes32 slot = keccak256(abi.encode(uint256(expiry), keccak256(abi.encode(NVDA, SNAPSHOTS_SLOT))));
            // casting to 'uint24' keeps the tick's two's complement in its 24 bits, as Solidity packs an int24
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 packed = uint256(expiry + 60) << 152 | uint256(uint24(meanTick)) << 128 | price;
            vm.store(address(poolSource), slot, bytes32(packed));
        }
        (uint128 stored, int24 storedTick,) = poolSource.snapshots(NVDA, expiry);
        assertEq(stored, price, "snapshot price");
        assertEq(storedTick, meanTick, "snapshot tick");
    }

    /// @dev Settle, prune, redeem every holder in real NVDA, sweep; conservation in NVDA and USDG.
    function _settleRedeemAndConserve(uint256 longId, uint256 resaleAsk, uint256 price) internal {
        uint256 shortId = V2Ids.shortIdOf(longId);
        vm.prank(keeper);
        assertTrue(ch.settle(longId), "settled");
        console2.log("gas: settle:", vm.lastCallGas().gasTotalUsed);
        V2Types.Series memory s = ch.series(longId);
        (uint256 longPer, uint256 feePer, uint256 shortPer) =
            OptionMath.settlementPerUnit(false, s.strike, price, EXERCISE_FEE_BPS);
        assertEq(s.longPayoutPerUnit, longPer, "long per unit");
        assertEq(s.feePerUnit, feePer, "fee per unit");
        assertEq(s.shortPayoutPerUnit, shortPer, "short per unit");
        assertGt(longPer, 0, "in the money");
        assertEq(longPer + feePer + shortPer, V2Constants.UNIT, "per-unit conservation");
        uint256 lockedAtSettle = ch.locked(longId);
        assertEq(lockedAtSettle, 150 * V2Constants.UNIT, "locked at settlement");

        vm.prank(keeper);
        vm.expectRevert(V2Errors.ThirdPartyRedeemDisabled.selector);
        ch.redeem(longId, address(book));
        uint256[] memory ids = new uint256[](1);
        ids[0] = resaleAsk;
        vm.prank(keeper);
        assertEq(book.prune(ids), 1, "resale ask pruned");
        assertEq(ch.balanceOf(buyer1, longId), 100, "escrow back with buyer1");

        uint256[3] memory before = [nvda.balanceOf(buyer1), nvda.balanceOf(buyer2), nvda.balanceOf(writer)];
        address[] memory longs = new address[](2);
        (longs[0], longs[1]) = (buyer1, buyer2);
        address[] memory shorts = new address[](1);
        shorts[0] = writer;
        vm.startPrank(keeper);
        assertEq(ch.redeemBatch(longId, longs), 2, "longs redeemed");
        assertEq(ch.redeemBatch(shortId, shorts), 1, "short redeemed");
        vm.stopPrank();

        uint256 paid1 = nvda.balanceOf(buyer1) - before[0];
        uint256 paid2 = nvda.balanceOf(buyer2) - before[1];
        uint256 paidShort = nvda.balanceOf(writer) - before[2];
        assertEq(paid1, 100 * longPer, "buyer1 paid in real NVDA");
        assertEq(paid2, 50 * longPer, "buyer2 paid in real NVDA");
        assertEq(paidShort, 150 * shortPer, "writer's collateral remainder");
        assertEq(ch.accruedFees(NVDA), 150 * feePer, "exercise fees");
        assertEq(paid1 + paid2 + paidShort + ch.accruedFees(NVDA), lockedAtSettle, "payouts + fees == locked");
        assertEq(ch.totalSupply(longId) + ch.totalSupply(shortId), 0, "every token redeemed");
        assertEq(ch.locked(longId), 0, "nothing left locked");

        vm.prank(keeper);
        ch.sweepFees(NVDA);
        assertEq(nvda.balanceOf(chFees), 150 * feePer, "fees swept");
        assertEq(nvda.balanceOf(address(ch)), ch.free(writer, NVDA), "the Clearinghouse holds exactly its ledger");
        assertEq(usdg.balanceOf(address(ch)), 0, "and no USDG");
        assertEq(usdg.balanceOf(address(book)), 0, "the book holds nothing");
        assertGt(usdg.balanceOf(keeper), 0, "the keeper was paid bounties in real USDG");
        console2.log("keeper bounties (USDG 6dp):", usdg.balanceOf(keeper));
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev The most recent weekly close at least FINALIZE_DELAY old whose window the pool ring covers, else the most
    ///      recent such session close; 0 when the ring covers none.
    function _chooseExpiry() internal view returns (uint40 expiry, bool weekly) {
        uint256 today = forkNow / 1 days;
        for (uint256 i; i < 10; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint32 day = uint32(today - i);
            if (!calendar.isSessionDay(day)) continue;
            uint256 close = calendar.closeOf(day);
            if (close + V2Constants.FINALIZE_DELAY > forkNow) continue;
            if (!_poolCovers(close - V2Constants.SETTLEMENT_WINDOW)) break;
            // forge-lint: disable-next-line(unsafe-typecast)
            uint40 c = uint40(close);
            if (calendar.isWeekly(c)) return (c, true);
            if (expiry == 0) expiry = c;
        }
    }

    function _poolCovers(uint256 start) internal view returns (bool) {
        uint32[] memory ago = new uint32[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        ago[0] = uint32(forkNow - start);
        try IUniswapV3PoolOracle(NVDA_POOL).observe(ago) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev Real tokens by storage-slot discovery (forge `deal`); skips the test with the reason if a slot is not found.
    function _fund() internal returns (bool) {
        if (!_deal(NVDA, writer, 10e18)) return false;
        if (!_deal(USDG, buyer1, 1_000e6)) return false;
        if (!_deal(USDG, buyer2, 1_000e6)) return false;
        if (!_deal(USDG, address(rewards), 100e6)) return false;
        return true;
    }

    function _deal(address token, address to, uint256 amount) internal returns (bool) {
        try this.dealToken(token, to, amount) {
            return true;
        } catch {
            console2.log("skipping: deal() could not locate the balance slot of", token);
            vm.skip(true);
            return false;
        }
    }

    function dealToken(address token, address to, uint256 amount) external {
        deal(token, to, amount, true);
    }

    /// @dev NYSE full closures 2026-2028 as day indexes (callhouse ops/markets/v2-sources.json, R13), the calendar's
    ///      launch seed. Same table as test/v2/fork/SourcesFork.t.sol.
    function _nyseClosures() internal pure returns (uint32[] memory days_) {
        uint32[29] memory closures = [
            uint32(20454),
            20472,
            20500,
            20546,
            20598,
            20623,
            20637,
            20703,
            20783,
            20812,
            20819,
            20836,
            20864,
            20903,
            20969,
            20987,
            21004,
            21067,
            21147,
            21176,
            21200,
            21235,
            21288,
            21333,
            21354,
            21369,
            21431,
            21511,
            21543
        ];
        days_ = new uint32[](closures.length);
        for (uint256 i; i < closures.length; ++i) {
            days_[i] = closures[i];
        }
    }
}
