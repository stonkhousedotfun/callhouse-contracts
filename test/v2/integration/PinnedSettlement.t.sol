// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {V2IntegrationBase} from "./V2IntegrationBase.t.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {ISettlementOracle} from "../../../src/v2/interfaces/ISettlementOracle.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Ids} from "../../../src/v2/interfaces/V2Ids.sol";
import {IPriceSource} from "../../../src/v2/interfaces/IPriceSource.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MockOraclePriceSource} from "../../../src/v2/mocks/MockOraclePriceSource.sol";
import {MockRoundFeed} from "../../../src/v2/mocks/MockRoundFeed.sol";
import {MockUniV3Pool} from "../../../src/v2/mocks/MockUniV3Pool.sol";
import {MockVerifierProxy} from "../../../src/v2/mocks/MockVerifierProxy.sol";
import {ChainlinkFeedSource} from "../../../src/v2/oracle/ChainlinkFeedSource.sol";
import {DataStreamsSource} from "../../../src/v2/oracle/DataStreamsSource.sol";
import {SettlementOracle} from "../../../src/v2/oracle/SettlementOracle.sol";
import {UniV3TwapSource} from "../../../src/v2/oracle/UniV3TwapSource.sol";

/// @notice The owner decision of 2026-09-17 on the real stack (closes C2-16 finding 1, "the admin key can pick the
///         settlement price of live series"): createSeries pins the expiry's settlement configuration on the oracle
///         and on both sources, and after that the admin can re-point the feed and the pool, loosen their bounds, add
///         an agreeing source, widen the deviation, shorten the delay or empty the market without reaching the live
///         series; expiries without series take the new configuration. Also the failure modes, all closed: a market
///         without sources, an oracle without the Clearinghouse pointer, a listed source that does not list the oracle
///         (the revoke-then-repoint attack), is unconfigured or broken, and a hidden pre-pin through the Clearinghouse
///         pointer or a source allow-list each stop the creation; no gas limit creates a series with a source left
///         unpinned; a migration to a second oracle sharing the sources works while their configurations are unchanged.
/// @dev Fixture: V2IntegrationBase with NVDA registered. Honest window (LifecycleTest's): feed 221.00 at E - 2 h and
///      222.40 at E - 900, TWAP 221.70 = P; the pool follows, 1 bp away. The admin's replacements price NVDA at 400.00:
///      a feed with its own history and a 1-L pool at tick 216407 (399.99). A DataStreamsSource (mock VerifierProxy),
///      configured for NVDA and listing the oracle, joins the market only in the suites that call {_useThreeSources}.
contract PinnedSettlementTest is V2IntegrationBase {
    uint40 internal constant E = FRI_2026_09_18;
    /// @dev The following Friday: no series exists for it unless a test creates one after the admin's change.
    uint40 internal constant E2 = FRI_2026_09_18 + 7 days;
    uint256 internal constant P = 221_700_000;
    int24 internal constant TICK_221_00 = 222340;
    int24 internal constant TICK_222_40 = 222277;
    /// @dev 1e18 / 1.0001^221941 = 229.99 USDG: a pool pushed 3.7 % away from the feed.
    int24 internal constant TICK_230 = 221941;
    uint256 internal constant EVIL = 400_000_000;
    int24 internal constant TICK_EVIL = 216407;
    /// @dev The evil pool's liquidity floor. It was 0 ("no floor") until T-OP-062 made {UniV3TwapSource.setPool} refuse
    ///      a zero floor (`CeilingExceeded`) and three walks here died at that call (T-OP-097 (b)(1)). This is the
    ///      smallest legal floor, the value T-OP-062's own tests chose; the evil pool is pushed with exactly 1 L of
    ///      in-range liquidity (setUp), so its harmonic-mean liquidity is 1, `1 < 1` is false, and the pool prices.
    uint128 internal constant EVIL_POOL_MIN_LIQUIDITY = 1;
    uint128 internal constant K220 = 220_000_000;

    /// @dev R13 Regular Hours feed ids (callhouse ops/markets/v2-sources.json): NVDA's, and AAPL's as "another stream".
    bytes32 internal constant DS_NVDA_FEED_ID = 0x000b6aa036224454037bab103184565f6aa9ea589c3b349f6d8471ee753524b9;
    bytes32 internal constant DS_OTHER_FEED_ID = 0x000bbd87a23775b4c11092ae9a1fc7b3393636ae1dbb9f1ef460f845c0f4cff1;

    MockRoundFeed internal evilFeed;
    MockUniV3Pool internal evilPool;
    DataStreamsSource internal dsSource;

    function setUp() public override {
        super.setUp();
        _registerNvda();
        _onboard(alice);
        evilFeed = new MockRoundFeed(8, "RHNVDA / USD");
        evilFeed.push(_ans(EVIL), START - 2 hours);
        evilFeed.push(_ans(EVIL), START - 1 hours);
        evilPool = new MockUniV3Pool(address(usdg), address(nvda), 3000);
        // casting to 'uint40' is safe because START is a 2026 timestamp
        // forge-lint: disable-next-line(unsafe-typecast)
        evilPool.pushState(uint40(START - 2 hours), TICK_EVIL, 1);
        dsSource = new DataStreamsSource(address(manager), address(new MockVerifierProxy()));
        _wire(address(dsSource), "DataStreamsSource", admin, 0);
        vm.startPrank(admin);
        dsSource.setFeed(address(nvda), DS_NVDA_FEED_ID);
        dsSource.setOracle(address(oracle), true);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _ans(uint256 usdg6) internal pure returns (int256) {
        // casting to 'int256' is safe because test prices are far below 2^255 / 100
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(usdg6 * 100);
    }

    /// @dev The keeper creates a call and alice writes 100 units to bob, so the expiry has open interest.
    function _createAndWrite(uint40 expiry, uint128 strike) internal returns (uint256 longId) {
        vm.prank(keeper);
        longId = ch.createSeries(address(nvda), false, strike, expiry);
        _deposit(alice, address(nvda), 1e18);
        vm.prank(alice);
        ch.setOperator(address(this), true);
        ch.mint(longId, 100, alice, bob);
    }

    function _printHonestWindow(uint40 expiry) internal {
        _print(221_000_000, TICK_221_00, expiry - 2 hours);
        _print(222_400_000, TICK_222_40, expiry - 900);
    }

    function _list(address a, address b) internal pure returns (address[] memory l) {
        l = new address[](2);
        (l[0], l[1]) = (a, b);
    }

    function _feedPinned(uint40 expiry) internal view returns (bool pinned, address pinnedFeed) {
        (pinnedFeed,,, pinned) = clSource.pinnedFeeds(address(nvda), expiry);
    }

    function _poolPinned(uint40 expiry) internal view returns (bool pinned, address pinnedPool) {
        (pinnedPool,,,, pinned,) = poolSource.pinnedPools(address(nvda), expiry);
    }

    /*//////////////////////////////////////////////////////////////
                              WHAT IS PINNED
    //////////////////////////////////////////////////////////////*/

    /// The first series of an expiry logs the oracle's pin, then each source's, then SeriesCreated; a later series of
    /// the same expiry logs SeriesCreated alone.
    function test_pin_firstSeriesPinsTheOracleAndBothSources_inLogOrder() public {
        vm.recordLogs();
        vm.prank(keeper);
        uint256 longId = ch.createSeries(address(nvda), false, K220, E);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 4, "oracle pin, feed pin, pool pin, SeriesCreated");
        assertEq(logs[0].emitter, address(oracle), "the oracle first");
        assertEq(logs[0].topics[0], ISettlementOracle.SettlementConfigPinned.selector, "SettlementConfigPinned");
        assertEq(uint256(logs[0].topics[2]), E, "indexed expiry");
        (address[] memory sources, uint16 dev, uint32 delay) = abi.decode(logs[0].data, (address[], uint16, uint32));
        assertEq(sources.length, 2, "two sources");
        assertEq(sources[0], address(clSource), "Chainlink first");
        assertEq(sources[1], address(poolSource), "pool second");
        assertEq(dev, 150, "deviation");
        assertEq(delay, 6 hours, "delay");
        assertEq(logs[1].emitter, address(clSource), "then source 0");
        assertEq(logs[1].topics[0], ChainlinkFeedSource.FeedPinned.selector, "FeedPinned");
        assertEq(logs[2].emitter, address(poolSource), "then source 1");
        assertEq(logs[2].topics[0], UniV3TwapSource.PoolPinned.selector, "PoolPinned");
        assertEq(logs[3].emitter, address(ch), "SeriesCreated last");
        assertEq(logs[3].topics[0], IClearinghouse.SeriesCreated.selector, "SeriesCreated");
        assertEq(uint256(logs[3].topics[1]), longId, "the new id");

        (bool pinned, address pinnedFeed) = _feedPinned(E);
        assertTrue(pinned && pinnedFeed == address(feed), "feed pinned");
        address pinnedPool;
        (pinned, pinnedPool) = _poolPinned(E);
        assertTrue(pinned && pinnedPool == address(pool), "pool pinned");
        (pinned,,,,) = oracle.settlementConfig(address(nvda), E);
        assertTrue(pinned, "oracle pinned");

        vm.recordLogs();
        vm.prank(keeper);
        ch.createSeries(address(nvda), true, K220, E);
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "a later series of the expiry logs SeriesCreated only");
        assertEq(logs[0].topics[0], IClearinghouse.SeriesCreated.selector);
    }

    /*//////////////////////////////////////////////////////////////
                     WHAT THE ADMIN CAN NO LONGER DO
    //////////////////////////////////////////////////////////////*/

    /// After series exist the admin re-points the feed and the pool at 400-dollar replacements with their loosest
    /// bounds and no liquidity floor, and widens the deviation to 1000 bps with a 30-minute delay. The live series
    /// still snapshot the pinned pool, capture the pinned feed, corroborate at the honest 221.70 with 150 bps and
    /// settle there. A series created after the change pins the admin's configuration and settles at 400.
    function test_pin_adminRepointsFeedAndPoolAfterCreation_liveSeriesSettleOnTheirPin() public {
        uint256 callId = _createAndWrite(E, K220);

        vm.startPrank(admin);
        clSource.setFeed(address(nvda), address(evilFeed), clSource.MAX_MAX_STALE(), clSource.MAX_ROUND_JUMP_CEIL_BPS());
        poolSource.setPool(address(nvda), address(evilPool), EVIL_POOL_MIN_LIQUIDITY, poolSource.MIN_WINDOW());
        oracle.setMarket(address(nvda), _list(address(clSource), address(poolSource)), 1000, 30 minutes, 0);
        vm.stopPrank();
        uint256 laterId = _createAndWrite(E2, 400_000_000); // spot is 400 now, so the strike band is [200, 800]

        _printHonestWindow(E);
        vm.warp(E + 60);
        vm.prank(keeper);
        assertEq(oracle.snapshot(address(nvda), E), 1, "the pinned pool records");
        (uint128 snap,,) = poolSource.snapshots(address(nvda), E);
        assertApproxEqAbs(snap, P, 20_000, "from the honest pool");
        vm.warp(E + V2Constants.FINALIZE_DELAY);
        vm.prank(keeper);
        (bool finalized, uint256 price) = oracle.finalize(address(nvda), E);
        assertTrue(finalized, "corroborated by the pinned feed and pool");
        assertEq(price, P, "the honest TWAP");
        (,,, uint16 dev) = oracle.recordedSources(address(nvda), E);
        assertEq(dev, 150, "the pinned deviation");
        vm.prank(keeper);
        assertTrue(ch.settle(callId), "settled");
        assertEq(ch.series(callId).settlementPrice, P, "at the pinned price");

        evilFeed.push(_ans(EVIL), E2 - 2 hours);
        vm.warp(E2 + 60);
        vm.prank(keeper);
        oracle.snapshot(address(nvda), E2);
        vm.warp(E2 + V2Constants.FINALIZE_DELAY);
        vm.prank(keeper);
        (finalized, price) = oracle.finalize(address(nvda), E2);
        assertTrue(finalized, "the series created after the change: the admin's sources corroborate");
        assertEq(price, EVIL, "the new configuration applies to new expiries");
        vm.prank(keeper);
        ch.settle(laterId);
    }

    /// The pinned sources disagree (the pool is pushed to 230 for the window). The admin puts an agreeing source next
    /// to Chainlink with a 30-minute delay: the live expiry still captures only its pinned pair, announces a disagreeing
    /// candidate with the pinned 6 h delay, and once the guardian vetoes it nothing finalizes it, because only the
    /// pinned sources could corroborate. The same list on an expiry without series corroborates at once.
    function test_pin_adminAddsAnAgreeingSource_cannotFinalizeTheLiveSeries() public {
        _createAndWrite(E, K220);
        feed.push(_ans(221_000_000), E - 2 hours);
        feed.push(_ans(222_400_000), E - 900);
        // casting to 'uint40' is safe because E is a 2026 timestamp
        // forge-lint: disable-next-line(unsafe-typecast)
        pool.pushState(uint40(E - 2 hours), TICK_230, POOL_LIQUIDITY);
        MockOraclePriceSource agreeing = new MockOraclePriceSource();
        agreeing.setWindow(true, P);
        vm.prank(admin);
        oracle.setMarket(address(nvda), _list(address(clSource), address(agreeing)), 150, 30 minutes, 0);

        vm.warp(E + 60);
        vm.prank(keeper);
        oracle.snapshot(address(nvda), E);
        vm.warp(E + V2Constants.FINALIZE_DELAY);
        vm.prank(keeper);
        (bool finalized,) = oracle.finalize(address(nvda), E);
        assertFalse(finalized, "the pinned feed and pool disagree");
        (address[] memory recorded,,,) = oracle.recordedSources(address(nvda), E);
        assertEq(recorded[1], address(poolSource), "captured the pinned pool, not the added source");
        (uint256 cPrice, uint8 idx, bool disagreed, uint40 at) = oracle.candidate(address(nvda), E);
        assertEq(cPrice, P, "Chainlink's price");
        assertEq(idx, 0, "index 0");
        assertTrue(disagreed, "disagreed");
        assertEq(at, E + V2Constants.FINALIZE_DELAY + 6 hours, "the pinned delay, not 30 minutes");

        vm.prank(guardian);
        oracle.veto(address(nvda), E);
        vm.warp(E + V2Constants.FINALIZE_DELAY + 6 hours);
        vm.prank(keeper);
        (finalized,) = oracle.finalize(address(nvda), E);
        assertFalse(finalized, "held: the admin's agreeing source cannot corroborate a pinned expiry");

        _printHonestWindow(E2);
        vm.warp(E2 + V2Constants.FINALIZE_DELAY);
        uint256 price;
        (finalized, price) = oracle.finalize(address(nvda), E2);
        assertTrue(finalized, "no series pinned E2: the admin's list corroborates at once");
        assertEq(price, P, "Chainlink and the added source agree");
    }

    /// The admin empties the market and removes the feed and the pool after the series exist. The expiry still
    /// captures its pinned feed when the admin resolves 48 h later, so the resolve band holds: 400 is refused, the band
    /// edge is accepted. Without sources no new series can be created, and an unpinned expiry resolves at any price.
    function test_pin_adminEmptiesTheMarketAndRemovesTheSources_resolveStaysBanded() public {
        _createAndWrite(E, K220);
        vm.startPrank(admin);
        oracle.setMarket(address(nvda), new address[](0), 0, 0, 0);
        clSource.setFeed(address(nvda), address(0), 0, 0);
        poolSource.setPool(address(nvda), address(0), 0, 0);
        vm.stopPrank();
        _printHonestWindow(E);

        vm.warp(E + V2Constants.RESOLVE_DELAY);
        uint256 lo = P * (10_000 - 150) / 10_000;
        uint256 hi = P * (10_000 + 150) / 10_000;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.ResolveOutOfBand.selector, lo, hi));
        oracle.adminResolve(address(nvda), E, EVIL);
        vm.prank(admin);
        oracle.adminResolve(address(nvda), E, hi);
        (, uint256 price) = oracle.settlementPrice(address(nvda), E);
        assertEq(price, hi, "resolved at the band edge of the pinned feed's price");

        vm.prank(keeper);
        vm.expectRevert(V2Errors.NoSource.selector);
        ch.createSeries(address(nvda), false, K220, E2);

        vm.warp(E2 + V2Constants.RESOLVE_DELAY);
        vm.prank(admin);
        oracle.adminResolve(address(nvda), E2, EVIL);
        (, price) = oracle.settlementPrice(address(nvda), E2);
        assertEq(price, EVIL, "an expiry with no series and no sources: any price (nobody holds it)");
    }

    /*//////////////////////////////////////////////////////////////
                              FAILURE MODES
    //////////////////////////////////////////////////////////////*/

    /// A market without sources, or an oracle that does not name this Clearinghouse, cannot create series.
    function test_pin_createSeriesNeedsSourcesAndTheClearinghousePointer() public {
        vm.prank(admin);
        oracle.setMarket(address(nvda), new address[](0), 0, 0, 0);
        vm.prank(keeper);
        vm.expectRevert(V2Errors.NoSource.selector);
        ch.createSeries(address(nvda), false, K220, E);

        vm.startPrank(admin);
        oracle.setMarket(address(nvda), _list(address(clSource), address(poolSource)), 0, 0, 0);
        oracle.setClearinghouse(address(0));
        vm.stopPrank();
        vm.prank(keeper);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        ch.createSeries(address(nvda), false, K220, E);

        vm.prank(admin);
        oracle.setClearinghouse(address(ch));
        vm.prank(keeper);
        uint256 longId = ch.createSeries(address(nvda), false, K220, E);
        assertTrue(ch.seriesExists(longId), "created once wired");
    }

    /*//////////////////////////////////////////////////////////////
                        PINNING FAILS CLOSED
    //////////////////////////////////////////////////////////////*/

    /// @dev The Data Streams source joins the market as source 2 (configured, listing the oracle), for the suites that
    ///      need all three real sources.
    function _useThreeSources() internal {
        address[] memory l = new address[](3);
        (l[0], l[1], l[2]) = (address(clSource), address(poolSource), address(dsSource));
        vm.prank(admin);
        oracle.setMarket(address(nvda), l, 0, 0, 0);
    }

    function _sources3() internal view returns (address[3] memory) {
        return [address(clSource), address(poolSource), address(dsSource)];
    }

    /// @dev The source at `i` of {_sources3} has pinned (underlying NVDA, expiry).
    function _sourcePinned(uint256 i, uint40 expiry) internal view returns (bool pinned) {
        if (i == 0) (pinned,) = _feedPinned(expiry);
        else if (i == 1) (pinned,) = _poolPinned(expiry);
        else (pinned,) = dsSource.pinnedFeeds(address(nvda), expiry);
    }

    /// @dev createSeries(NVDA call 220, expiry) from the keeper reverts with exactly `err`, and nothing exists after
    ///      it: no series, no ERC-1155 supply, no oracle pin.
    function _refused(uint40 expiry, bytes memory err) internal {
        vm.prank(keeper);
        vm.expectRevert(err);
        ch.createSeries(address(nvda), false, K220, expiry);
        uint256 longId = ch.longIdOf(address(nvda), false, K220, expiry);
        assertFalse(ch.seriesExists(longId), "no series");
        assertEq(ch.totalSupply(longId) + ch.totalSupply(longId | 1), 0, "no ERC-1155 supply");
        (bool pinned,,,,) = oracle.settlementConfig(address(nvda), expiry);
        assertFalse(pinned, "no oracle pin");
    }

    function _sourceNotPinned(address source, bytes4 reason) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(V2Errors.SourceNotPinned.selector, source, reason);
    }

    /// @dev `source.setOracle(oracle, allowed)` from the admin (the three sources share the selector).
    function _allow(address source, address who, bool allowed) internal {
        vm.prank(admin);
        ChainlinkFeedSource(source).setOracle(who, allowed);
    }

    /// C2-16 finding 1, the revoke-then-repoint attack: the admin takes the oracle off one source's allow-list before
    /// the first series of an expiry, so that source would stay unpinned and follow a later setFeed / setPool. Now the
    /// creation reverts (SourceNotPinned naming the source, NotAuthorized as its reason) and nothing is pinned, for each
    /// of the three sources. With the allow-list restored the series is created with the oracle and all three sources
    /// pinned, in log order: SettlementConfigPinned, FeedPinned, PoolPinned, the Data Streams FeedPinned, SeriesCreated.
    function test_failClosed_oracleRevokedOnAnySource_blocksCreationUntilRestored() public {
        _useThreeSources();
        address[3] memory srcs = _sources3();
        for (uint256 i; i < 3; ++i) {
            _allow(srcs[i], address(oracle), false);
            _refused(E, _sourceNotPinned(srcs[i], V2Errors.NotAuthorized.selector));
            for (uint256 j; j < 3; ++j) {
                assertFalse(_sourcePinned(j, E), "no source kept a pin");
            }
            _allow(srcs[i], address(oracle), true);
        }

        vm.recordLogs();
        vm.prank(keeper);
        uint256 longId = ch.createSeries(address(nvda), false, K220, E);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 5, "oracle pin, three source pins, SeriesCreated");
        assertEq(logs[0].emitter, address(oracle), "the oracle first");
        assertEq(logs[0].topics[0], ISettlementOracle.SettlementConfigPinned.selector, "SettlementConfigPinned");
        assertEq(logs[1].emitter, address(clSource), "then source 0");
        assertEq(logs[1].topics[0], ChainlinkFeedSource.FeedPinned.selector, "FeedPinned");
        assertEq(logs[2].emitter, address(poolSource), "then source 1");
        assertEq(logs[2].topics[0], UniV3TwapSource.PoolPinned.selector, "PoolPinned");
        assertEq(logs[3].emitter, address(dsSource), "then source 2");
        assertEq(logs[3].topics[0], DataStreamsSource.FeedPinned.selector, "Data Streams FeedPinned");
        assertEq(logs[4].emitter, address(ch), "SeriesCreated last");
        assertEq(logs[4].topics[0], IClearinghouse.SeriesCreated.selector, "SeriesCreated");
        assertEq(uint256(logs[4].topics[1]), longId, "the new id");
        for (uint256 j; j < 3; ++j) {
            assertTrue(_sourcePinned(j, E), "every source pinned");
        }
        assertEq(oracle.pinnedBy(address(nvda), E), address(ch), "pinned by the Clearinghouse");
    }

    /// A listed source that is broken in any way blocks the creation: it reverts (its selector is the reason), answers
    /// something that is not the pin selector, or has no code any more.
    function test_failClosed_brokenSourceInTheList_blocksCreation() public {
        MockOraclePriceSource broken = new MockOraclePriceSource();
        vm.prank(admin);
        oracle.setMarket(address(nvda), _list(address(clSource), address(broken)), 0, 0, 0);

        broken.setMode(MockOraclePriceSource.Mode.Reverts);
        _refused(E, _sourceNotPinned(address(broken), MockOraclePriceSource.MockSourceReverted.selector));
        broken.setMode(MockOraclePriceSource.Mode.ShortReply);
        _refused(E, _sourceNotPinned(address(broken), bytes4(0)));
        broken.setMode(MockOraclePriceSource.Mode.Normal);
        vm.mockCall(address(broken), abi.encodeWithSelector(IPriceSource.pin.selector), abi.encode(true));
        _refused(E, _sourceNotPinned(address(broken), bytes4(0)));
        vm.clearMockedCalls();
        bytes memory code = address(broken).code;
        vm.etch(address(broken), "");
        _refused(E, _sourceNotPinned(address(broken), bytes4(0)));
        (bool feedPinned,) = _feedPinned(E);
        assertFalse(feedPinned, "Chainlink's pin rolled back with the rest");

        vm.etch(address(broken), code);
        vm.prank(keeper);
        uint256 longId = ch.createSeries(address(nvda), false, K220, E);
        assertTrue(ch.seriesExists(longId), "created once the source works");
    }

    /// A listed source with no configuration for the underlying blocks the creation (its NoSource is the reason): the
    /// pool removed, the feed removed, or the Data Streams source listed without a feed id (built and disabled, it must
    /// not be listed until it is configured). Configured again, the series is created.
    function test_failClosed_unconfiguredListedSource_blocksCreation() public {
        _useThreeSources();
        uint32 window = poolSource.DEFAULT_WINDOW();
        (uint32 stale, uint16 jump) = (clSource.DEFAULT_MAX_STALE(), clSource.DEFAULT_MAX_ROUND_JUMP_BPS());

        vm.prank(admin);
        poolSource.setPool(address(nvda), address(0), 0, 0);
        _refused(E, _sourceNotPinned(address(poolSource), V2Errors.NoSource.selector));
        vm.startPrank(admin);
        poolSource.setPool(address(nvda), address(pool), POOL_MIN_LIQUIDITY, window);
        clSource.setFeed(address(nvda), address(0), 0, 0);
        vm.stopPrank();
        _refused(E, _sourceNotPinned(address(clSource), V2Errors.NoSource.selector));
        vm.startPrank(admin);
        clSource.setFeed(address(nvda), address(feed), stale, jump);
        dsSource.setFeed(address(nvda), bytes32(0));
        vm.stopPrank();
        _refused(E, _sourceNotPinned(address(dsSource), V2Errors.NoSource.selector));

        vm.prank(admin);
        dsSource.setFeed(address(nvda), DS_NVDA_FEED_ID);
        vm.prank(keeper);
        uint256 longId = ch.createSeries(address(nvda), false, K220, E);
        assertTrue(ch.seriesExists(longId), "created once every listed source is configured");
    }

    /// The hidden pre-pin through the Clearinghouse pointer (coordinator finding): the admin points the oracle at its
    /// own account, pins E with a bad list (the evil feed alone, 1000 bps, 30 minutes), and restores the list, the feed
    /// and the pointer, so every current-configuration view looks clean. The real createSeries of E reverts
    /// PinMismatch. The same trick with the honest list but the evil feed current at the pre-pin leaves Chainlink's
    /// pin of E2 on the evil feed: createSeries of E2 reverts SourceNotPinned(Chainlink, PinMismatch). A pre-pin with
    /// the honest configuration is confirmed by the first series (no second SettlementConfigPinned, pinnedBy moves to
    /// the Clearinghouse) and settles on the honest prices.
    function test_hiddenPrePin_throughTheClearinghousePointer() public {
        address shadow = makeAddr("adminShadow");
        (uint32 stale, uint16 jump) = (clSource.DEFAULT_MAX_STALE(), clSource.DEFAULT_MAX_ROUND_JUMP_BPS());
        (uint32 maxStale, uint16 maxJump) = (clSource.MAX_MAX_STALE(), clSource.MAX_ROUND_JUMP_CEIL_BPS());
        address[] memory evilList = new address[](1);
        evilList[0] = address(clSource);
        address[] memory honestList = _list(address(clSource), address(poolSource));

        // E: bad oracle list and bad feed, pinned through the pointer, then everything restored
        vm.startPrank(admin);
        clSource.setFeed(address(nvda), address(evilFeed), maxStale, maxJump);
        oracle.setMarket(address(nvda), evilList, 1000, 30 minutes, 0);
        oracle.setClearinghouse(shadow);
        vm.stopPrank();
        vm.prank(shadow);
        oracle.pin(address(nvda), E);
        vm.startPrank(admin);
        clSource.setFeed(address(nvda), address(feed), stale, jump);
        oracle.setMarket(address(nvda), honestList, 0, 0, 0);
        oracle.setClearinghouse(address(ch));
        vm.stopPrank();
        (address[] memory current,,,) = oracle.marketConfig(address(nvda));
        assertEq(current.length, 2, "the current configuration looks clean");
        assertEq(oracle.pinnedBy(address(nvda), E), shadow, "but E was pinned by the admin's account");
        vm.prank(keeper);
        vm.expectRevert(V2Errors.PinMismatch.selector);
        ch.createSeries(address(nvda), false, K220, E);
        assertFalse(ch.seriesExists(ch.longIdOf(address(nvda), false, K220, E)), "no series on the hidden pin");

        // E2: the honest oracle list, but the evil feed current while the pre-pin pinned the sources
        vm.startPrank(admin);
        clSource.setFeed(address(nvda), address(evilFeed), maxStale, maxJump);
        oracle.setClearinghouse(shadow);
        vm.stopPrank();
        vm.prank(shadow);
        oracle.pin(address(nvda), E2);
        vm.startPrank(admin);
        clSource.setFeed(address(nvda), address(feed), stale, jump);
        oracle.setClearinghouse(address(ch));
        vm.stopPrank();
        vm.prank(keeper);
        vm.expectRevert(_sourceNotPinned(address(clSource), V2Errors.PinMismatch.selector));
        ch.createSeries(address(nvda), false, K220, E2);
        assertEq(oracle.pinnedBy(address(nvda), E2), shadow, "not confirmed");

        // E3: an honest pre-pin is confirmed and settles honest
        uint40 e3 = E + 14 days;
        vm.prank(admin);
        oracle.setClearinghouse(shadow);
        vm.prank(shadow);
        oracle.pin(address(nvda), e3);
        vm.prank(admin);
        oracle.setClearinghouse(address(ch));
        vm.recordLogs();
        uint256 longId = _createAndWrite(e3, K220);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[0].topics[0], IClearinghouse.SeriesCreated.selector, "a confirmation logs no pin");
        assertEq(oracle.pinnedBy(address(nvda), e3), address(ch), "pinnedBy moved to the Clearinghouse");
        _printHonestWindow(e3);
        vm.warp(e3 + 60);
        vm.prank(keeper);
        oracle.snapshot(address(nvda), e3);
        vm.warp(e3 + V2Constants.FINALIZE_DELAY);
        vm.prank(keeper);
        assertTrue(ch.settle(longId), "settled");
        assertEq(ch.series(longId).settlementPrice, P, "on the honest configuration");
    }

    /// The hidden pre-pin through each source's allow-list: the admin lists its own account on the source, sets a bad
    /// configuration (the evil feed, the evil pool without a floor, another Data Streams feed), pins an expiry through
    /// the account, restores the configuration and delists the account. The real createSeries of that expiry reverts
    /// SourceNotPinned(source, PinMismatch). A pre-pin with the current configuration is confirmed: the series is created
    /// and the pre-pinned source logs no second pin.
    function test_hiddenPrePin_throughEachSourceAllowList() public {
        _useThreeSources();
        address shadow = makeAddr("adminShadow");
        address[3] memory srcs = _sources3();
        for (uint256 i; i < 3; ++i) {
            // casting to 'uint40' is safe because i < 3
            // forge-lint: disable-next-line(unsafe-typecast)
            uint40 bad = E + uint40(i) * 14 days;
            uint40 honest = bad + 7 days;

            _setSourceConfig(i, false);
            _allow(srcs[i], shadow, true);
            vm.prank(shadow);
            ChainlinkFeedSource(srcs[i]).pin(address(nvda), bad);
            _setSourceConfig(i, true);
            vm.prank(shadow);
            ChainlinkFeedSource(srcs[i]).pin(address(nvda), honest);
            _allow(srcs[i], shadow, false);

            _refused(bad, _sourceNotPinned(srcs[i], V2Errors.PinMismatch.selector));

            vm.recordLogs();
            vm.prank(keeper);
            uint256 longId = ch.createSeries(address(nvda), false, K220, honest);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertTrue(ch.seriesExists(longId), "an honest pre-pin is confirmed");
            assertEq(logs.length, 4, "oracle pin, the two other sources' pins, SeriesCreated");
            for (uint256 k; k < logs.length; ++k) {
                assertTrue(logs[k].emitter != srcs[i], "the pre-pinned source logs no second pin");
            }
        }
    }

    /// @dev Source `i` of {_sources3} to its honest configuration, or to a bad one.
    function _setSourceConfig(uint256 i, bool honest) internal {
        vm.startPrank(admin);
        if (i == 0) {
            if (honest) {
                clSource.setFeed(
                    address(nvda), address(feed), clSource.DEFAULT_MAX_STALE(), clSource.DEFAULT_MAX_ROUND_JUMP_BPS()
                );
            } else {
                clSource.setFeed(
                    address(nvda), address(evilFeed), clSource.MAX_MAX_STALE(), clSource.MAX_ROUND_JUMP_CEIL_BPS()
                );
            }
        } else if (i == 1) {
            if (honest) {
                poolSource.setPool(address(nvda), address(pool), POOL_MIN_LIQUIDITY, poolSource.DEFAULT_WINDOW());
            } else {
                poolSource.setPool(address(nvda), address(evilPool), EVIL_POOL_MIN_LIQUIDITY, poolSource.MIN_WINDOW());
            }
        } else {
            dsSource.setFeed(address(nvda), honest ? DS_NVDA_FEED_ID : DS_OTHER_FEED_ID);
        }
        vm.stopPrank();
    }

    /// Migration to a second oracle that shares the sources (the reason they keep an allow-list): series of an expiry
    /// pinned on the first oracle can be created on the second while the sources' configurations are unchanged (each
    /// confirms its pin without a log), and cannot once one changed (SourceNotPinned(Chainlink, PinMismatch)).
    function test_twoOracleMigration_worksOnlyWithUnchangedSources() public {
        SettlementOracle oracle2 = new SettlementOracle(address(manager));
        _wire(address(oracle2), "SettlementOracle", admin, 0);
        vm.startPrank(admin);
        oracle2.setMarket(address(nvda), _list(address(clSource), address(poolSource)), 0, 0, 0);
        oracle2.setClearinghouse(address(ch));
        clSource.setOracle(address(oracle2), true);
        poolSource.setOracle(address(oracle2), true);
        vm.stopPrank();
        vm.startPrank(keeper);
        ch.createSeries(address(nvda), false, K220, E);
        ch.createSeries(address(nvda), false, K220, E2);
        vm.stopPrank();

        V2Types.MarketConfig memory cfg = _nvdaMarket();
        cfg.oracle = address(oracle2);
        vm.prank(admin);
        _reconfigure(ch, address(nvda), cfg);

        vm.recordLogs();
        vm.prank(keeper);
        uint256 putId = ch.createSeries(address(nvda), true, K220, E);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "oracle2's pin and SeriesCreated: the sources confirmed without a log");
        assertEq(logs[0].emitter, address(oracle2), "oracle2 pinned E");
        assertEq(ch.series(putId).oracle, address(oracle2), "on the new oracle");

        _setSourceConfig(0, false);
        vm.prank(keeper);
        vm.expectRevert(_sourceNotPinned(address(clSource), V2Errors.PinMismatch.selector));
        ch.createSeries(address(nvda), true, K220, E2);
    }

    /// @dev Sweep contracts-c11 on the real stack. The oracle bounty gate reads the Clearinghouse's open interest of the
    ///      whole (underlying, expiry), whichever oracle its series settle on. So a second oracle sharing the sources
    ///      (the migration above) paid a FINALIZE bounty for an expiry it had no series of. And after a Clearinghouse
    ///      migration the old Clearinghouse's settle paid its internal finalize's bounty to the old Clearinghouse, where
    ///      no function moves USDG it did not account for. Neither pays now.
    function test_migrations_payNoBountyForAnotherOraclesExpiryNorToTheOldClearinghouse() public {
        _createAndWrite(E, K220);
        uint256 oldLong = _createAndWrite(E2, K220);
        _printHonestWindow(E);

        SettlementOracle oracle2 = new SettlementOracle(address(manager));
        _wire(address(oracle2), "SettlementOracle", admin, 0);
        vm.startPrank(admin);
        oracle2.setMarket(address(nvda), _list(address(clSource), address(poolSource)), 0, 0, 0);
        oracle2.setClearinghouse(address(ch));
        oracle2.setKeeperRewards(address(rewards));
        rewards.setCaller(address(oracle2), true);
        clSource.setOracle(address(oracle2), true);
        poolSource.setOracle(address(oracle2), true);
        vm.stopPrank();

        vm.warp(E + 60);
        vm.prank(keeper);
        oracle.snapshot(address(nvda), E);
        vm.warp(E + V2Constants.FINALIZE_DELAY);
        vm.prank(keeper);
        (bool finalized,) = oracle.finalize(address(nvda), E);
        assertTrue(finalized, "the oracle E is pinned on finalizes it");
        uint256 earned = usdg.balanceOf(keeper);
        assertEq(earned, SNAPSHOT_BOUNTY + FINALIZE_BOUNTY, "and pays");
        vm.prank(keeper);
        (finalized,) = oracle2.finalize(address(nvda), E);
        assertTrue(finalized, "oracle2 captures E from the shared sources");
        assertEq(usdg.balanceOf(keeper), earned, "but pays nothing for an expiry it has no series of");

        Clearinghouse ch2 =
            new Clearinghouse(address(manager), address(usdg), address(calendar), address(splitter), BASE_URI);
        _wire(address(ch2), "Clearinghouse", admin, 0);
        vm.startPrank(admin);
        ch2.setMinter(alice, true);
        ch2.setDefaultOracle(address(oracle));
        ch2.setDefaultMarketFees(EXERCISE_FEE_BPS, 0);
        ch2.registerMarket(address(nvda), STRIKE_TICK, true);
        ch2.setMarketOracle(address(nvda), address(oracle));
        ch2.setMarketFees(address(nvda), EXERCISE_FEE_BPS, 0);
        oracle.setClearinghouse(address(ch2));
        vm.stopPrank();
        vm.prank(keeper);
        uint256 newLong = ch2.createSeries(address(nvda), false, K220, E2);
        assertEq(oracle.pinnedBy(address(nvda), E2), address(ch2), "ch2 confirmed the pin of E2");
        vm.startPrank(alice);
        nvda.approve(address(ch2), type(uint256).max);
        ch2.deposit(address(nvda), 1e18, alice);
        ch2.mint(newLong, 100, alice, bob);
        vm.stopPrank();

        _printHonestWindow(E2);
        vm.warp(E2 + 60);
        vm.prank(keeper);
        oracle.snapshot(address(nvda), E2);
        vm.warp(E2 + V2Constants.FINALIZE_DELAY);
        uint256 oldChUsdg = usdg.balanceOf(address(ch));
        vm.prank(keeper);
        assertTrue(ch.settle(oldLong), "the old Clearinghouse settles its series, finalizing E2 inside");
        assertEq(usdg.balanceOf(address(ch)), oldChUsdg, "no FINALIZE bounty stuck in the old Clearinghouse");
    }

    /// @dev Sweep contracts-c12 on the real stack (the critic's PoC). The feed stalls at 220.00 (its last round,
    ///      START - 10 min, stays inside maxStale) while the market trades near 200. Nobody records the pool inside the
    ///      grace, so 220.00 is a single-source candidate and the guardian vetoes it. The pin keeps the admin from
    ///      adding a source, so at E + 48 h the band is 220 +- 150 bps and 200 is refused. Before the fix the 210 call
    ///      could then only settle in the money or stay held with its collateral locked. From E + 7 days the vetoed
    ///      single price allows a factor of 1.25 either way: it settles at 200, the long is paid nothing, and the
    ///      writer's 10 NVDA come back.
    function test_vetoedWrongSingleSource_settlesAtTheMarketPriceFromSevenDays() public {
        uint40 thu = THU_2026_09_10;
        vm.prank(keeper);
        uint256 longId = ch.createSeries(address(nvda), false, 210_000_000, thu);
        _deposit(alice, address(nvda), 10e18);
        vm.prank(alice);
        ch.setOperator(address(this), true);
        ch.mint(longId, 1000, alice, bob);

        vm.warp(thu + V2Constants.SNAPSHOT_GRACE + 1);
        assertEq(oracle.snapshot(address(nvda), thu), 0, "the pool snapshot was missed");
        (bool finalized,) = oracle.finalize(address(nvda), thu);
        assertFalse(finalized, "a single-source candidate");
        (uint256 cand,,,) = oracle.candidate(address(nvda), thu);
        assertEq(cand, 220_000_000, "the stalled feed's price");
        vm.prank(guardian);
        oracle.veto(address(nvda), thu);

        vm.warp(thu + V2Constants.RESOLVE_DELAY);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.ResolveOutOfBand.selector, 216_700_000, 223_300_000));
        oracle.adminResolve(address(nvda), thu, 200_000_000);
        assertFalse(ch.settle(longId), "held");

        vm.warp(thu + 7 days);
        vm.prank(admin);
        oracle.adminResolve(address(nvda), thu, 200_000_000);
        assertTrue(ch.settle(longId), "settled at the market price");
        uint256 bobBefore = nvda.balanceOf(bob);
        vm.prank(bob);
        ch.redeem(longId, bob);
        assertEq(nvda.balanceOf(bob), bobBefore, "the 210 call expired out of the money: nothing paid");
        uint256 aliceBefore = nvda.balanceOf(alice) + ch.free(alice, address(nvda));
        vm.prank(alice);
        ch.redeem(V2Ids.shortIdOf(longId), alice);
        assertEq(nvda.balanceOf(alice) + ch.free(alice, address(nvda)), aliceBefore + 10e18, "the writer's collateral");
        assertEq(ch.locked(longId), 0, "nothing left locked");
    }

    /// @dev Sweep contracts-c13, accepted and documented (V2-ARCHITECTURE §2.2, §6.6). A series is not a position:
    ///      createSeries is permissionless and needs no collateral. So a stranger who mints nothing still pins an expiry
    ///      up to MAX_TENOR ahead, and a later pool change never reaches it, although nobody holds anything there. Not
    ///      changed: pinning at the first mint is bypassed by minting one unit, and it would leave write-on-fill asks
    ///      resting on an unpinned expiry.
    function test_pin_aSeriesNobodyHoldsStillPinsItsExpiry() public {
        uint40 far = E + 35 days;
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        ch.createSeries(address(nvda), false, 440_000_000, far);
        assertEq(ch.openInterest(address(nvda), far), 0, "nobody holds anything");
        (bool pinned,,,,) = oracle.settlementConfig(address(nvda), far);
        assertTrue(pinned, "pinned anyway");

        vm.prank(admin);
        poolSource.setPool(address(nvda), address(evilPool), EVIL_POOL_MIN_LIQUIDITY, 300);
        (bool poolPinned, address pinnedPool) = _poolPinned(far);
        assertTrue(poolPinned && pinnedPool == address(pool), "the pool change does not reach it");
    }

    /// Whatever gas the first series of an expiry is sent with, it is either created with the oracle and every source
    /// pinned, or not created at all; and with a source that does not list the oracle, no gas limit creates it.
    function test_pin_noGasLimitCreatesASeriesWithAnUnpinnedSource() public {
        uint256 created;
        uint256 refused;
        uint256 snap = vm.snapshotState();
        bytes memory call_ = abi.encodeCall(ch.createSeries, (address(nvda), false, K220, E));
        for (uint256 g = 150_000; g <= 500_000; g += 2_500) {
            (bool ok,) = address(ch).call{gas: g}(call_);
            if (ok) {
                ++created;
                (bool feedPinned,) = _feedPinned(E);
                (bool poolPinned,) = _poolPinned(E);
                (bool oraclePinned,,,,) = oracle.settlementConfig(address(nvda), E);
                assertTrue(oraclePinned && feedPinned && poolPinned, "created only with everything pinned");
            } else {
                ++refused;
                assertFalse(ch.seriesExists(ch.longIdOf(address(nvda), false, K220, E)), "nothing half created");
            }
            vm.revertToState(snap);
        }
        emit log_named_uint("gas limits that created the series", created);
        emit log_named_uint("gas limits that were refused", refused);
        assertGt(created, 0, "enough gas creates it");
        assertGt(refused, 0, "too little does not");

        _allow(address(poolSource), address(oracle), false);
        snap = vm.snapshotState();
        for (uint256 g = 150_000; g <= 1_000_000; g += 5_000) {
            (bool ok,) = address(ch).call{gas: g}(call_);
            assertFalse(ok, "a source that cannot pin: refused at every gas limit");
            vm.revertToState(snap);
        }
        assertFalse(ch.seriesExists(ch.longIdOf(address(nvda), false, K220, E)), "never created");
    }
}
