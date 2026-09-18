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
        cl = new ChainlinkFeedSource(admin);
        uni = new UniV3TwapSource(admin, address(usdg));
        oracle = new SettlementOracle(admin, guardian);
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

    /// Spot from the feed's latest round goes stale after spotMaxAge; UniV3TwapSource.record is never called early.
    function test_spotStale_andSnapshotTooEarly() public {
        vm.warp(E - 900 + 1 hours + 1);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.StaleSpot.selector, uint256(E - 900)));
        oracle.spot(address(nvda));

        vm.warp(E - 1);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.TooEarly.selector, E));
        oracle.snapshot(address(nvda), E);
    }
}
