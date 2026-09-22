// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseV2Test} from "../BaseV2.t.sol";
import {SettlementOracle} from "../../../src/v2/oracle/SettlementOracle.sol";
import {ChainlinkFeedSource} from "../../../src/v2/oracle/ChainlinkFeedSource.sol";
import {UniV3TwapSource} from "../../../src/v2/oracle/UniV3TwapSource.sol";
import {ISettlementOracle} from "../../../src/v2/interfaces/ISettlementOracle.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MockRoundFeed} from "../../../src/v2/mocks/MockRoundFeed.sol";
import {MockUniV3Pool} from "../../../src/v2/mocks/MockUniV3Pool.sol";

/// @notice SettlementOracle over the real C2-03 sources (ChainlinkFeedSource over a MockRoundFeed, UniV3TwapSource over
///         a MockUniV3Pool): the keeper flow snapshot -> finalize, a capture before the pool snapshot that the pool
///         corroborates later even after the Chainlink replay is gone, a missed snapshot settling on Chainlink after the
///         delay, a manipulated pool, the issuer's oracle pause, and spot from the feed.
/// @dev NVDA market, sources [Chainlink, UniV3]. Feed (8 dp): 219.50 from START - 2 h, 220.00 from START - 1 h, 220.40 from
///      E - 900, so the window [E - 1800, E] averages to 220.20 = 220_200_000 exactly. Pool (USDG token0): tick 222385
///      from START - 2 h, 1e18 / 1.0001^222385 = 220_001_192.5 USDG base units per share (node), 9 bps under the feed.
contract SettlementOracleSourcesTest is BaseV2Test {
    uint40 internal constant E = THU_2026_09_10;
    int24 internal constant TICK_220 = 222385;
    uint256 internal constant POOL_PRICE = 220_001_192;
    uint256 internal constant FEED_TWAP = 220_200_000;
    uint128 internal constant LIQ = 1e19;

    MockRoundFeed internal feed;
    MockUniV3Pool internal pool;
    ChainlinkFeedSource internal cl;
    UniV3TwapSource internal uni;
    SettlementOracle internal oracle;

    function _deployFeeds() internal override {
        feed = new MockRoundFeed(8, "RHNVDA / USD");
        feed.push(219_50000000, START - 2 hours);
        feed.push(NVDA_FEED_ANSWER, START - 1 hours);
        feed.push(220_40000000, E - 900);
        pool = new MockUniV3Pool(address(usdg), address(nvda), 500);
        // forge-lint: disable-next-line(unsafe-typecast)
        pool.pushState(uint40(START - 2 hours), TICK_220, LIQ);
    }

    function _deployCore() internal override {
        _deployManager();
        cl = new ChainlinkFeedSource(address(manager));
        _wire(address(cl), "ChainlinkFeedSource", admin, 0);
        uni = new UniV3TwapSource(address(manager), address(usdg));
        _wire(address(uni), "UniV3TwapSource", admin, 0);
        oracle = new SettlementOracle(address(manager));
        _wire(address(oracle), "SettlementOracle", admin, 0);
        address[] memory sources = new address[](2);
        (sources[0], sources[1]) = (address(cl), address(uni));
        vm.startPrank(admin);
        cl.setFeed(address(nvda), address(feed), cl.DEFAULT_MAX_STALE(), cl.DEFAULT_MAX_ROUND_JUMP_BPS());
        uni.setPool(address(nvda), address(pool), 1e18, uni.DEFAULT_WINDOW());
        oracle.setMarket(address(nvda), sources, 0, 0, 0);
        vm.stopPrank();
    }

    function _status() internal view returns (V2Types.SettlementStatus status) {
        (status,) = oracle.settlementPrice(address(nvda), E);
    }

    /// The normal keeper flow: snapshot inside the grace, then finalize: corroborated on the Chainlink TWAP.
    function test_snapshotThenFinalize_corroborates() public {
        vm.warp(E + 300);
        vm.prank(keeper);
        assertEq(oracle.snapshot(address(nvda), E), 1, "pool recorded, Chainlink stores nothing");
        (uint128 snap,,) = uni.snapshots(address(nvda), E);
        assertApproxEqAbs(snap, POOL_PRICE, 1, "pool window price");

        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SourceRecorded(address(nvda), E, 0, true, FEED_TWAP);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SourceRecorded(address(nvda), E, 1, true, snap);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementFinalized(address(nvda), E, FEED_TWAP, 0, true);
        vm.prank(keeper);
        uint256 gasBefore = gasleft();
        (bool finalized, uint256 price) = oracle.finalize(address(nvda), E);
        uint256 gasUsed = gasBefore - gasleft();
        assertTrue(finalized, "final");
        assertEq(price, FEED_TWAP, "Chainlink TWAP, priority 0");
        assertLt(gasUsed, 400_000, "capture + corroboration over both real sources");
    }

    /// finalize at expiry + 120 captures Chainlink before the pool is snapshotted; the feed then prints 100 rounds so
    /// its replay of the window is gone; the pool snapshot still corroborates the captured price.
    function test_captureBeforeSnapshot_poolCorroboratesAfterReplayDies() public {
        vm.warp(E + V2Constants.FINALIZE_DELAY);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SourceRecorded(address(nvda), E, 1, false, 0);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementCandidate(
            address(nvda), E, FEED_TWAP, 0, false, E + V2Constants.FINALIZE_DELAY + 6 hours
        );
        (bool finalized,) = oracle.finalize(address(nvda), E);
        assertFalse(finalized, "Chainlink alone: candidate");

        vm.warp(E + 300);
        assertEq(oracle.snapshot(address(nvda), E), 1, "pool snapshot inside the grace");
        for (uint256 i; i < 100; ++i) {
            feed.push(220_40000000, E + 301 + i);
        }
        vm.warp(E + 1000);
        (bool replayOk,) = cl.windowPrice(address(nvda), E - 1800, E);
        assertFalse(replayOk, "the window is past the 96-read walk now");

        uint256 price;
        (finalized, price) = oracle.finalize(address(nvda), E);
        assertTrue(finalized, "pool corroborates the captured Chainlink price");
        assertEq(price, FEED_TWAP, "captured price");
        (,, uint8 idx, bool corroborated,,) = oracle.settlementInfo(address(nvda), E);
        assertEq(idx, 0, "Chainlink");
        assertTrue(corroborated, "corroborated");
    }

    /// No snapshot inside the grace: the pool never answers, Chainlink settles alone after the delay.
    function test_snapshotMissed_chainlinkAloneAfterDelay() public {
        vm.warp(E + V2Constants.SNAPSHOT_GRACE + 1);
        assertEq(oracle.snapshot(address(nvda), E), 0, "grace passed");
        (bool finalized,) = oracle.finalize(address(nvda), E);
        assertFalse(finalized, "candidate");
        (,,, uint40 at) = oracle.candidate(address(nvda), E);
        vm.warp(at);
        uint256 price;
        (finalized, price) = oracle.finalize(address(nvda), E);
        assertTrue(finalized, "uncorroborated after 6 h");
        assertEq(price, FEED_TWAP, "Chainlink");
    }

    /// The pool held 2 % high over the window: sources disagree, Chainlink is the candidate with disagreed = true.
    function test_manipulatedPool_disagreedCandidate() public {
        pool.pushState(E - 1800, TICK_220 - 198, LIQ); // ~2 % above 220
        pool.pushState(E, TICK_220, LIQ);
        vm.warp(E + 300);
        oracle.snapshot(address(nvda), E);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementCandidate(address(nvda), E, FEED_TWAP, 0, true, E + 300 + 6 hours);
        (bool finalized,) = oracle.finalize(address(nvda), E);
        assertFalse(finalized, "a manipulated pool buys a delay, never a price");
        assertEq(uint8(_status()), uint8(V2Types.SettlementStatus.Pending), "Pending");
    }

    /// The issuer's oracle pause: Chainlink's window is not ok and spot has no source; lifting it resumes.
    function test_oraclePaused_blocksChainlinkAndSpot() public {
        vm.warp(E - 600);
        (uint256 spotPrice, uint256 updatedAt) = oracle.spot(address(nvda));
        assertEq(spotPrice, 220_400_000, "latest round");
        assertEq(updatedAt, E - 900, "its timestamp");

        nvda.setOraclePaused(true);
        vm.expectRevert(V2Errors.NoSource.selector);
        oracle.spot(address(nvda));
        vm.warp(E + V2Constants.FINALIZE_DELAY);
        (bool finalized,) = oracle.finalize(address(nvda), E);
        assertFalse(finalized, "no ok source while paused");
        (,,,,, bool captured) = oracle.settlementInfo(address(nvda), E);
        assertFalse(captured, "nothing captured");

        nvda.setOraclePaused(false);
        (finalized,) = oracle.finalize(address(nvda), E);
        assertEq(uint8(_status()), uint8(V2Types.SettlementStatus.Pending), "resumes");
    }

    /// @dev T-495's launch-phase action, and the one fact its whole "not reachable today" reading rests on.
    ///      T-495 argued that an early-close day leaves the settlement window with no print inside it, and that the
    ///      Chainlink source nonetheless stays ok BECAUSE `maxStale` is 26 h -- so `_band` never takes its
    ///      `okCount == 0` exit and `adminResolve` stays bounded. That is an argument about a configured number, and
    ///      T-495 recorded that nothing proves it. This is the proof, in both directions.
    ///
    ///      THE GAP IS DERIVED, NEVER TYPED. On a half day the last print is 13:00 and the expiry is still anchored
    ///      at the 16:00 close, so the window `[expiry - SETTLEMENT_WINDOW, expiry]` opens
    ///      `3 hours - SETTLEMENT_WINDOW` after that print. T-502's author published this figure as 1.5 h, corrected
    ///      it to 2.5 h mid-row, and said plainly that the number was load-bearing and wrong in two messages. So it
    ///      is computed here from `V2Constants.SETTLEMENT_WINDOW` and can never drift from it.
    ///
    ///      BOTH DIRECTIONS ARE ASSERTED ON PURPOSE. Ok-at-26 h alone would also pass against a source that ignores
    ///      staleness entirely, which is the shape of every false green this build has produced. The not-ok-at-1 h
    ///      leg is what proves the rule at `ChainlinkFeedSource.sol:235` is doing the work, and it is also the
    ///      standing record that `MIN_MAX_STALE` sits BELOW the gap: the configuration T-502 documents as reachable
    ///      by a direct CONFIG_ADMIN `setFeed` is the one that puts the half-day window back in the unbounded case.
    function test_T495_halfDayWindowIsOkAt26hAndNotOkAtTheOneHourFloor() public {
        uint40 gap = uint40(3 hours) - V2Constants.SETTLEMENT_WINDOW;
        assertEq(gap, 9000, "the half-day gap is 2.5 h: (16:00 close - 13:00 early close) - SETTLEMENT_WINDOW");
        assertGt(gap, cl.MIN_MAX_STALE(), "the floor must sit BELOW the gap or this test proves nothing");

        // The window opens exactly `gap` after the day's last print, and nothing prints inside it.
        uint40 start = E + 4 hours;
        uint40 end = start + V2Constants.SETTLEMENT_WINDOW;
        feed.push(NVDA_FEED_ANSWER, start - gap);
        vm.warp(end);

        (bool okAtDefault, uint256 priceAtDefault) = cl.windowPrice(address(nvda), start, end);
        assertTrue(okAtDefault, "at DEFAULT_MAX_STALE 26 h the half-day window still has an ok price");
        assertEq(priceAtDefault, uint256(uint256(int256(NVDA_FEED_ANSWER)) / 100), "and it is the price in force");

        // BOTH ARGUMENTS ARE READ BEFORE THE PRANK IS ARMED, and that is not style. `vm.prank` applies to the very
        // next call, so an external read written inside the argument list EATS IT: the first version of this test
        // put `cl.MIN_MAX_STALE()` in the call and the manager saw `canCall(SettlementOracleSourcesTest, ...)` and
        // reverted NotAuthorized. That is the T-263 cheatcode-eaten-by-an-argument class, and the reason it is worth
        // a comment is that it failed LOUDLY here only because setFeed is restricted -- on an unguarded call the
        // prank would have been eaten in silence and the test would have passed as the wrong caller.
        uint32 floorMaxStale = cl.MIN_MAX_STALE();
        uint16 jumpBps = cl.DEFAULT_MAX_ROUND_JUMP_BPS();
        vm.prank(admin);
        cl.setFeed(address(nvda), address(feed), floorMaxStale, jumpBps);
        (bool okAtFloor,) = cl.windowPrice(address(nvda), start, end);
        assertFalse(okAtFloor, "at MIN_MAX_STALE 1 h the same window has no ok price at all");
    }

    /// Spot from the feed's latest round goes stale after spotMaxAge WHEN NOTHING CORROBORATES IT; UniV3TwapSource.record
    /// is never called early.
    /// @dev T-OP-087 (SettlementOracle._spot, step 2) made a print older than SPOT_CORROBORATION_AGE spot as long as the
    ///      market's source 1 is ok and agrees within maxDeviationBps, up to MAX_SPOT_MAX_AGE; the spotMaxAge clock this
    ///      test is named for is step 3, reached only when source 1 is NOT ok. Until T-OP-128 this test asserted the
    ///      pre-087 rule against a fixture whose pool sits 9 bps from the print, so the print was corroborated and
    ///      `spot()` no longer reverted (T-OP-097 (b)(3)). The uncorroborated arm is now driven both ways the landed
    ///      rule defines it -- the pool DOWN (step 3, the 1 h clock) and the pool DISAGREEING (step 2, the witness
    ///      says the market moved) -- with the corroborated case first as the control that separates the new rule
    ///      from the old one.
    function test_spotStale_andSnapshotTooEarly() public {
        vm.warp(E - 900 + 1 hours + 1);
        // Control for the landed rule: the hour-old 220.40 print is SPOT while the pool (220.00, 18 bps away, inside
        // the 150 bps default band) agrees with it. Under the pre-087 rule this line reverted StaleSpot.
        (uint256 price, uint256 updatedAt) = oracle.spot(address(nvda));
        assertEq(price, 220_400_000, "an hour-old print the pool agrees with is spot (T-OP-087 step 2)");
        assertEq(updatedAt, E - 900, "the answer is still source 0's timestamp");

        // The arm the test is named for: the pool is DOWN, so there is no witness and the uncorroborated spotMaxAge
        // clock (DEFAULT_SPOT_MAX_AGE, 1 h) governs -- the same print, one second past the hour, is stale.
        pool.setObserveReverts(true);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.StaleSpot.selector, uint256(E - 900)));
        oracle.spot(address(nvda));
        pool.setObserveReverts(false);

        // The other uncorroborated arm: the pool is up but says the market MOVED. A state pushed one second before
        // the pool's DEFAULT_WINDOW (300 s) began makes the whole window read 229.99 (tick 221941), 4.4 % from the
        // print and outside the 150 bps band, so the witness refuses the print rather than corroborating it.
        // forge-lint: disable-next-line(unsafe-typecast)
        pool.pushState(uint40(block.timestamp - uni.DEFAULT_WINDOW() - 1), 221941, LIQ);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.StaleSpot.selector, uint256(E - 900)));
        oracle.spot(address(nvda));

        vm.warp(E - 1);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.TooEarly.selector, E));
        oracle.snapshot(address(nvda), E);
    }
}
