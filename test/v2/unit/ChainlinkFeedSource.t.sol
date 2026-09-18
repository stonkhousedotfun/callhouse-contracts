// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ChainlinkFeedSource} from "../../../src/v2/oracle/ChainlinkFeedSource.sol";
import {PriceLib} from "../../../src/v2/oracle/lib/PriceLib.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {IPriceSource} from "../../../src/v2/interfaces/IPriceSource.sol";
import {MockRoundFeed} from "../../../src/v2/mocks/MockRoundFeed.sol";
import {MockStockToken} from "../../../src/mocks/MockStockToken.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";

/// @dev A "feed" that answers every call successfully with no data: a typed call to it would revert in the caller
///      while decoding, which is exactly what the source must not do.
contract SilentFeed {
    fallback() external {}
}

/// @notice ChainlinkFeedSource: the step-function TWAP against hand-computed windows, every not-ok rule of
///         architecture §3.3 (stale, history end, phase boundary, paused flag, answers <= 0, jump rule, read cap),
///         `latest`, admin bounds, the 96-read gas bound, and fuzzed agreement with a forward-integrating reference.
/// @dev Self-contained setup (C2-08 consolidates into BaseV2 later). NVDA-shaped feed: 8 decimals, "RHNVDA / USD".
///      Prices in the expectations are USDG base units per share (6 dp); feed answers are 8 dp, so `_ans(p)` is
///      `p * 100`. The window under test is `[start, end]` with `end` one hour before now.
contract ChainlinkFeedSourceTest is Test {
    address internal admin = makeAddr("admin");
    address internal stranger = makeAddr("stranger");

    MockStockToken internal nvda;
    MockRoundFeed internal feed;
    ChainlinkFeedSource internal src;

    uint40 internal end;
    uint40 internal start;

    event FeedSet(address indexed underlying, address indexed feed, uint32 maxStale, uint16 maxRoundJumpBps);

    function setUp() public {
        vm.warp(1_789_000_000);
        nvda = new MockStockToken("NVDA Stock Token", "NVDAx");
        feed = new MockRoundFeed(8, "RHNVDA / USD");
        src = new ChainlinkFeedSource(admin);
        vm.prank(admin);
        src.setFeed(address(nvda), address(feed), 26 hours, 2000);
        end = uint40(block.timestamp - 1 hours);
        start = end - 1800;
    }

    /// @dev 8-dp feed answer for a USDG 6-dp price.
    function _ans(uint256 usdg6) internal pure returns (int256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(usdg6 * 100);
    }

    function _window() internal view returns (bool ok, uint256 price) {
        return src.windowPrice(address(nvda), start, end);
    }

    function _assertWindow(uint256 expected) internal view {
        (bool ok, uint256 price) = _window();
        assertTrue(ok, "window ok");
        assertEq(price, expected, "window price");
    }

    function _assertWindowNotOk() internal view {
        (bool ok, uint256 price) = _window();
        assertFalse(ok, "window must not be ok");
        assertEq(price, 0, "price 0 when not ok");
    }

    /*//////////////////////////////////////////////////////////////
                       STEP-FUNCTION TWAP, BY HAND
    //////////////////////////////////////////////////////////////*/

    function test_window_noRoundInside_isTheRoundInForceAtStart() public {
        feed.push(_ans(214_000_000), start - 3600);
        feed.push(_ans(215_000_000), start - 600);
        _assertWindow(215_000_000);
    }

    /// 200.00 for 300 s, 202.00 for 600 s, 204.00 for 800 s, 203.00 for 100 s:
    /// (60,000 + 121,200 + 163,200 + 20,300) x 1e6 / 1800 = 202,611,111.1 -> 202_611_111 (floored).
    function test_window_severalRounds_handComputed() public {
        feed.push(_ans(199_000_000), start - 7200);
        feed.push(_ans(200_000_000), start - 100);
        feed.push(_ans(202_000_000), start + 300);
        feed.push(_ans(204_000_000), start + 900);
        feed.push(_ans(203_000_000), start + 1700);
        feed.push(_ans(210_000_000), end + 60);
        _assertWindow(202_611_111);
    }

    function test_window_roundExactlyAtStart_isInForceForTheWholeWindow() public {
        feed.push(_ans(200_000_000), start - 50);
        feed.push(_ans(210_000_000), start);
        _assertWindow(210_000_000);
    }

    /// A round stamped exactly `end` is in force for zero seconds of the window, but it is not "after end", so it
    /// is still read and sanity-checked.
    function test_window_roundExactlyAtEnd_weighsNothingButIsChecked() public {
        feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 50);
        uint80 atEnd = feed.push(_ans(201_000_000), end);
        _assertWindow(200_000_000);

        feed.setRound(atEnd, 0, end);
        _assertWindowNotOk();
    }

    /// Rounds after `end` are neither priced nor checked: a 50 % jump and a negative answer after expiry leave the
    /// window's price alone.
    function test_window_roundsAfterEnd_areIgnored() public {
        feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 50);
        feed.push(_ans(300_000_000), end + 1);
        feed.push(-1, end + 2);
        feed.push(_ans(100_000_000), end + 3);
        _assertWindow(200_000_000);
    }

    /// The first round inside the window is at start + 600; its predecessor is the round in force at start.
    /// (200 x 600 + 201 x 1200) / 1800 = 200,666,666.6 -> 200_666_666.
    function test_window_predecessorExactlyMaxStale_isOk() public {
        feed.push(_ans(199_000_000), start - 30 hours);
        feed.push(_ans(200_000_000), start - 26 hours);
        feed.push(_ans(201_000_000), start + 600);
        _assertWindow(200_666_666);
    }

    function test_window_firstRoundAfterStartWithStalePredecessor_notOk() public {
        feed.push(_ans(199_000_000), start - 30 hours);
        feed.push(_ans(200_000_000), start - 26 hours - 1);
        feed.push(_ans(201_000_000), start + 600);
        _assertWindowNotOk();
    }

    function test_window_maxStaleIsPerFeedConfig() public {
        feed.push(_ans(199_000_000), start - 60 hours);
        feed.push(_ans(200_000_000), start - 50 hours);
        _assertWindowNotOk();
        vm.prank(admin);
        src.setFeed(address(nvda), address(feed), 3 days, 2000);
        _assertWindow(200_000_000);
    }

    /*//////////////////////////////////////////////////////////////
                         END OF HISTORY, PHASES
    //////////////////////////////////////////////////////////////*/

    /// Aggregator round 1 is inside the window: there is nothing older in this phase to cover `start`.
    function test_window_historyStartsInsideWindow_notOk() public {
        feed.push(_ans(201_000_000), start + 600);
        _assertWindowNotOk();
    }

    function test_window_getRoundDataReverts_isEndOfHistory() public {
        feed.push(_ans(199_000_000), start - 4000);
        uint80 inForce = feed.push(_ans(200_000_000), start - 50);
        feed.push(_ans(201_000_000), start + 600);
        _assertWindow(200_666_666);

        // The round in force at start can no longer be read.
        feed.setHistoryFloor(inForce + 1);
        _assertWindowNotOk();
    }

    function test_window_roundWithZeroUpdatedAt_isEndOfHistory() public {
        feed.push(_ans(199_000_000), start - 4000);
        uint80 inForce = feed.push(_ans(200_000_000), start - 50);
        feed.push(_ans(201_000_000), start + 600);
        feed.setRound(inForce, _ans(200_000_000), 0);
        _assertWindowNotOk();
    }

    /// The round in force at start must itself pass the jump rule, so it needs a readable predecessor. Here the
    /// predecessor's read reverts: not ok, even though `start` is covered.
    function test_window_predecessorOfStartRoundUnreadable_notOk() public {
        uint80 pred = feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 50);
        feed.setHistoryFloor(pred + 1);
        _assertWindowNotOk();
    }

    /// The round in force at start is aggregator round 1 of its phase (the NVDA proxy's own round 1 was mis-scaled):
    /// no predecessor, not ok.
    function test_window_startRoundIsFirstOfPhase_notOk() public {
        feed.push(_ans(200_000_000), start - 50);
        feed.push(_ans(201_000_000), start + 600);
        _assertWindowNotOk();
    }

    function test_window_newPhaseInsideWindow_doesNotCrossTheBoundary() public {
        feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 100);
        feed.startPhase(2);
        feed.push(_ans(201_000_000), start + 600);
        // Phase 1 alone would price the window, but the walk may not step from phase 2 round 1 into phase 1.
        _assertWindowNotOk();
    }

    /// (200 x 600 + 201 x 1200) / 1800 = 200,666,666.6 -> 200_666_666, all from phase 2.
    function test_window_newPhaseCoveringStart_isOk() public {
        feed.push(_ans(150_000_000), start - 9000);
        feed.startPhase(2);
        feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 100);
        feed.push(_ans(201_000_000), start + 600);
        assertEq(feed.roundId(2, 3) >> 64, 2, "phase-prefixed id");
        _assertWindow(200_666_666);
    }

    /// Non-monotonic timestamps: round 3 claims start + 1500 but round 4 is stamped start + 900. Round 3 is skipped
    /// (its 500.00 answer would fail the jump rule if it were used); 200.00 for 900 s, 204.00 for 900 s.
    function test_window_nonMonotonicRound_isSkipped() public {
        feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 100);
        feed.push(_ans(500_000_000), start + 1500);
        feed.push(_ans(204_000_000), start + 900);
        _assertWindow(202_000_000);
    }

    /*//////////////////////////////////////////////////////////////
                          ANSWERS AND DECIMALS
    //////////////////////////////////////////////////////////////*/

    function test_window_zeroAnswerInside_notOk() public {
        feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 100);
        feed.push(0, start + 900);
        _assertWindowNotOk();
    }

    function test_window_negativeStartRound_notOk() public {
        feed.push(_ans(199_000_000), start - 4000);
        feed.push(-_ans(200_000_000), start - 100);
        _assertWindowNotOk();
    }

    function test_window_otherDecimals_normalise() public {
        feed.setDecimals(18);
        feed.push(215.4e18, start - 4000);
        feed.push(215.5e18, start - 100);
        _assertWindow(215_500_000);

        feed.setDecimals(4);
        feed.setRound(feed.roundId(1, 1), 2_154_000, start - 4000);
        feed.setRound(feed.roundId(1, 2), 2_155_000, start - 100);
        _assertWindow(215_500_000);
    }

    /// 1e11 at 18 dp is 0.0000001 USD: it truncates to 0 USDG base units, which is not a price.
    function test_window_answerNormalisingToZero_notOk() public {
        feed.setDecimals(18);
        feed.push(1e11, start - 4000);
        feed.push(1e11, start - 100);
        _assertWindowNotOk();
    }

    /*//////////////////////////////////////////////////////////////
                                JUMP RULE
    //////////////////////////////////////////////////////////////*/

    function test_jump_exactlyMaxBps_isOk() public {
        feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 100);
        feed.push(_ans(240_000_000), start + 900);
        _assertWindow(220_000_000);
    }

    function test_jump_justAboveMaxBps_notOk() public {
        feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 100);
        feed.push(_ans(240_000_100), start + 900);
        _assertWindowNotOk();
    }

    function test_jump_misScaledUpInsideWindow_notOk() public {
        feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 100);
        feed.push(_ans(200_000_000) * 1e8, start + 900);
        feed.push(_ans(200_000_000), start + 1000);
        _assertWindowNotOk();
    }

    function test_jump_halvingInsideWindow_notOkUnlessConfigured() public {
        feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 100);
        feed.push(_ans(100_000_000), start + 900);
        _assertWindowNotOk();

        vm.prank(admin);
        src.setFeed(address(nvda), address(feed), 26 hours, 5000);
        _assertWindow(150_000_000);
    }

    /// No round inside the window: the round in force at start is still compared with its predecessor.
    function test_jump_startRoundAgainstItsPredecessor_notOk() public {
        feed.push(_ans(100_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 100);
        _assertWindowNotOk();
    }

    /// The SPY scale fault R13 found on chain 4663: round ...623 answered 7349800000000000000 and round ...624
    /// answered 73683695000 (8 dp). Replayed as the predecessor and the round in force at start.
    function test_jump_r13SpyScaleFault_notOk() public {
        feed.push(7_349_800_000_000_000_000, start - 30_000);
        feed.push(73_683_695_000, start - 5000);
        _assertWindowNotOk();
    }

    /*//////////////////////////////////////////////////////////////
                         READ CAP AND GAS BOUND
    //////////////////////////////////////////////////////////////*/

    /// `rounds after end + round in force at start + its predecessor` reads. 94 + 2 = 96: ok.
    function test_readCap_exactly96Reads_isOk() public {
        feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 100);
        for (uint256 i; i < 94; ++i) {
            feed.push(_ans(i % 2 == 0 ? 201_000_000 : 200_000_000), end + 1 + i);
        }
        vm.warp(end + 1 hours);
        _assertWindow(200_000_000);
    }

    /// 95 + 2 = 97 reads: the predecessor of the round in force at start is one read too far.
    function test_readCap_97Reads_notOk() public {
        feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 100);
        for (uint256 i; i < 95; ++i) {
            feed.push(_ans(i % 2 == 0 ? 201_000_000 : 200_000_000), end + 1 + i);
        }
        vm.warp(end + 1 hours);
        _assertWindowNotOk();
    }

    /// The most expensive walk the cap allows: 94 rounds inside the window, the round in force at start and its
    /// predecessor, every one priced and jump-checked. Must stay under 1.5 M gas (C2-03 gate).
    function test_gas_96RoundWalk_under1_5M() public {
        feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 100);
        uint256 weighted = 200_000_000 * uint256(1);
        for (uint256 i; i < 94; ++i) {
            uint256 p = i % 2 == 0 ? 201_000_000 : 200_000_000;
            feed.push(_ans(p), start + 1 + i * 19);
            weighted += p * ((i == 93 ? 1800 : 1 + (i + 1) * 19) - (1 + i * 19));
        }
        uint256 gasBefore = gasleft();
        (bool ok, uint256 price) = src.windowPrice(address(nvda), start, end);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("gas: 96-read windowPrice", used);
        assertTrue(ok, "96-read walk ok");
        assertEq(price, weighted / 1800, "96-read walk price");
        assertLt(used, 1_500_000, "96-round walk under 1.5M gas");
    }

    /*//////////////////////////////////////////////////////////////
                         WINDOW ARGUMENTS, FAILURES
    //////////////////////////////////////////////////////////////*/

    function test_window_badArguments_notOk() public {
        feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 100);
        (bool ok,) = src.windowPrice(address(nvda), end, end);
        assertFalse(ok, "start == end");
        (ok,) = src.windowPrice(address(nvda), end, start);
        assertFalse(ok, "start > end");
        (ok,) = src.windowPrice(address(nvda), uint40(block.timestamp - 1800), uint40(block.timestamp + 1));
        assertFalse(ok, "end in the future");
        (ok,) = src.windowPrice(address(nvda), uint40(block.timestamp - 1800), uint40(block.timestamp));
        assertTrue(ok, "end == now is complete");
        (ok,) = src.windowPrice(makeAddr("unconfigured"), start, end);
        assertFalse(ok, "unconfigured underlying");
    }

    function test_window_feedReverts_notOkNoRevert() public {
        feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 100);
        feed.setReverts(true);
        _assertWindowNotOk();
        (bool ok,,) = src.latest(address(nvda));
        assertFalse(ok, "latest not ok");
    }

    function test_window_feedAnswersWithoutData_notOkNoRevert() public {
        SilentFeed silent = new SilentFeed();
        vm.prank(admin);
        src.setFeed(address(nvda), address(silent), 26 hours, 2000);
        _assertWindowNotOk();
        (bool ok,,) = src.latest(address(nvda));
        assertFalse(ok, "latest not ok");
    }

    /*//////////////////////////////////////////////////////////////
                              ORACLE PAUSED
    //////////////////////////////////////////////////////////////*/

    function test_paused_windowAndLatestNotOk_untilUnpaused() public {
        feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 100);
        nvda.setOraclePaused(true);
        _assertWindowNotOk();
        (bool ok,,) = src.latest(address(nvda));
        assertFalse(ok, "latest while paused");

        nvda.setOraclePaused(false);
        _assertWindow(200_000_000);
        (ok,,) = src.latest(address(nvda));
        assertTrue(ok, "latest after unpause");
    }

    /// An underlying without `oraclePaused()` fails closed.
    function test_paused_tokenWithoutFlag_failsClosed() public {
        MockERC20 plain = new MockERC20("Plain", "PLN", 18);
        vm.prank(admin);
        src.setFeed(address(plain), address(feed), 26 hours, 2000);
        feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 100);
        (bool ok,) = src.windowPrice(address(plain), start, end);
        assertFalse(ok, "window fails closed");
        (ok,,) = src.latest(address(plain));
        assertFalse(ok, "latest fails closed");
    }

    /*//////////////////////////////////////////////////////////////
                                  LATEST
    //////////////////////////////////////////////////////////////*/

    function test_latest_okRegardlessOfAge() public {
        feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 100);
        vm.warp(block.timestamp + 30 days);
        (bool ok, uint256 price, uint256 updatedAt) = src.latest(address(nvda));
        assertTrue(ok, "ok however old");
        assertEq(price, 200_000_000, "price");
        assertEq(updatedAt, start - 100, "updatedAt is the round's");
    }

    function test_latest_firstRoundOfPhase_notOk() public {
        feed.push(_ans(200_000_000), start - 100);
        (bool ok, uint256 price, uint256 updatedAt) = src.latest(address(nvda));
        assertFalse(ok, "no predecessor");
        assertEq(price, 0, "price");
        assertEq(updatedAt, 0, "updatedAt");
    }

    function test_latest_jumpFromPredecessor_notOk() public {
        feed.push(_ans(200_000_000), start - 4000);
        feed.push(_ans(200_000_000) * 1e8, start - 100);
        (bool ok,,) = src.latest(address(nvda));
        assertFalse(ok, "mis-scaled head");
    }

    function test_latest_nonMonotonicPredecessor_isSkipped() public {
        feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(900_000_000), start + 5000);
        feed.push(_ans(200_000_000), start - 100);
        (bool ok, uint256 price,) = src.latest(address(nvda));
        assertTrue(ok, "skips the round stamped after the head");
        assertEq(price, 200_000_000, "price");
    }

    function test_latest_badAnswers_notOk() public {
        feed.push(_ans(199_000_000), start - 4000);
        uint80 head = feed.push(0, start - 100);
        (bool ok,,) = src.latest(address(nvda));
        assertFalse(ok, "zero head");
        feed.setRound(head, _ans(200_000_000), start - 100);
        feed.setRound(feed.roundId(1, 1), -1, start - 4000);
        (ok,,) = src.latest(address(nvda));
        assertFalse(ok, "negative predecessor");
    }

    function test_latest_unconfiguredOrUnreadable_notOk() public {
        (bool ok,,) = src.latest(makeAddr("unconfigured"));
        assertFalse(ok, "unconfigured");
        uint80 pred = feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 100);
        feed.setHistoryFloor(pred + 1);
        (ok,,) = src.latest(address(nvda));
        assertFalse(ok, "predecessor unreadable");
    }

    /*//////////////////////////////////////////////////////////////
                                  RECORD
    //////////////////////////////////////////////////////////////*/

    function test_record_storesNothingAndReturnsFalse() public {
        feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 100);
        vm.prank(stranger);
        assertFalse(src.record(address(nvda), end), "replayable source records nothing");
        assertFalse(IPriceSource(address(src)).record(address(nvda), uint40(block.timestamp + 1 days)), "any time");
        _assertWindow(200_000_000);
    }

    /*//////////////////////////////////////////////////////////////
                                  ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_admin_constructorAndDefaults() public {
        assertTrue(src.hasRole(src.DEFAULT_ADMIN_ROLE(), admin), "admin role");
        assertEq(src.MAX_ROUND_READS(), 96, "read cap");
        assertEq(src.DEFAULT_MAX_STALE(), 26 hours, "default maxStale");
        assertEq(src.DEFAULT_MAX_ROUND_JUMP_BPS(), 2000, "default jump");
        (address f, uint32 maxStale, uint16 jump) = src.feeds(address(nvda));
        assertEq(f, address(feed), "feed");
        assertEq(maxStale, 26 hours, "maxStale");
        assertEq(jump, 2000, "jump");

        vm.expectRevert(V2Errors.NotAuthorized.selector);
        new ChainlinkFeedSource(address(0));
    }

    function test_admin_onlyAdminSetsFeeds() public {
        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        src.setFeed(address(nvda), address(feed), 26 hours, 2000);
    }

    function test_admin_boundsAndInputs() public {
        vm.startPrank(admin);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        src.setFeed(address(0), address(feed), 26 hours, 2000);
        vm.expectRevert(V2Errors.NoSource.selector);
        src.setFeed(address(nvda), makeAddr("eoa"), 26 hours, 2000);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        src.setFeed(address(nvda), address(feed), 1 hours - 1, 2000);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        src.setFeed(address(nvda), address(feed), 7 days + 1, 2000);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        src.setFeed(address(nvda), address(feed), 26 hours, 0);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        src.setFeed(address(nvda), address(feed), 26 hours, 5001);

        src.setFeed(address(nvda), address(feed), 1 hours, 1);
        src.setFeed(address(nvda), address(feed), 7 days, 5000);
        (, uint32 maxStale, uint16 jump) = src.feeds(address(nvda));
        assertEq(maxStale, 7 days, "upper maxStale accepted");
        assertEq(jump, 5000, "ceiling jump accepted");
        vm.stopPrank();
    }

    function test_admin_setAndRemoveEmit() public {
        address tsla = makeAddr("tsla");
        vm.expectEmit(address(src));
        emit FeedSet(tsla, address(feed), 2 hours, 1500);
        vm.prank(admin);
        src.setFeed(tsla, address(feed), 2 hours, 1500);

        feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 100);
        vm.expectEmit(address(src));
        emit FeedSet(address(nvda), address(0), 0, 0);
        vm.prank(admin);
        src.setFeed(address(nvda), address(0), 123, 456);
        (address f, uint32 maxStale, uint16 jump) = src.feeds(address(nvda));
        assertEq(f, address(0), "removed");
        assertEq(maxStale, 0, "removed maxStale");
        assertEq(jump, 0, "removed jump");
        _assertWindowNotOk();
    }

    /*//////////////////////////////////////////////////////////////
                      PINNING (INTERFACE_VERSION 6)
    //////////////////////////////////////////////////////////////*/

    event OracleSet(address indexed oracle, bool allowed);
    event FeedPinned(
        address indexed underlying, uint40 indexed expiry, address feed, uint32 maxStale, uint16 maxRoundJumpBps
    );

    address internal oracleAddr = makeAddr("oracle");

    function _allowOracle() internal {
        vm.prank(admin);
        src.setOracle(oracleAddr, true);
    }

    function _pinEnd() internal {
        vm.prank(oracleAddr);
        src.pin(address(nvda), end);
    }

    /// Only the admin edits the allow-list; only a listed oracle pins (not the admin itself); delisting stops pins.
    function test_pin_allowListAndAccess() public {
        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        src.setOracle(stranger, true);
        vm.prank(oracleAddr);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        src.pin(address(nvda), end);

        vm.expectEmit(address(src));
        emit OracleSet(oracleAddr, true);
        vm.prank(admin);
        src.setOracle(oracleAddr, true);
        assertTrue(src.isOracle(oracleAddr), "listed");
        vm.prank(admin);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        src.pin(address(nvda), end);
        _pinEnd();

        vm.expectEmit(address(src));
        emit OracleSet(oracleAddr, false);
        vm.prank(admin);
        src.setOracle(oracleAddr, false);
        vm.prank(oracleAddr);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        src.pin(address(nvda), end + 1);
    }

    /// The first pin copies the configuration, logs it and answers the pin selector; a later pin with the same
    /// configuration answers it again and changes and logs nothing.
    function test_pin_copiesOnce() public {
        _allowOracle();
        vm.expectEmit(address(src));
        emit FeedPinned(address(nvda), end, address(feed), 26 hours, 2000);
        vm.prank(oracleAddr);
        assertEq(src.pin(address(nvda), end), IPriceSource.pin.selector, "answers the pin selector");
        vm.recordLogs();
        vm.prank(oracleAddr);
        assertEq(src.pin(address(nvda), end), IPriceSource.pin.selector, "an equal re-pin is confirmed");
        assertEq(vm.getRecordedLogs().length, 0, "idempotent");
        (address f, uint32 maxStale, uint16 jump, bool pinned) = src.pinnedFeeds(address(nvda), end);
        assertTrue(pinned, "pinned");
        assertEq(f, address(feed), "the feed at the first pin");
        assertEq(maxStale, 26 hours, "its maxStale");
        assertEq(jump, 2000, "its jump bound");
    }

    /// A pin of an expiry already pinned fails closed when the current configuration differs in any field (the
    /// hidden pre-pin through another allowed oracle): another feed, maxStale or jump bound, or no feed at all. The
    /// pinned copy never moves, and restoring the configuration confirms it again.
    function test_pin_repinOfAChangedConfiguration_reverts() public {
        _allowOracle();
        _pinEnd();
        MockRoundFeed other = new MockRoundFeed(8, "RHNVDA / USD");
        address[4] memory feeds_ = [address(other), address(feed), address(feed), address(0)];
        uint32[4] memory stales = [uint32(26 hours), 27 hours, 26 hours, 0];
        uint16[4] memory jumps = [uint16(2000), 2000, 1999, 0];
        for (uint256 i; i < 4; ++i) {
            vm.prank(admin);
            src.setFeed(address(nvda), feeds_[i], stales[i], jumps[i]);
            vm.prank(oracleAddr);
            vm.expectRevert(V2Errors.PinMismatch.selector);
            src.pin(address(nvda), end);
        }
        (address f,,,) = src.pinnedFeeds(address(nvda), end);
        assertEq(f, address(feed), "the pinned copy did not move");
        vm.prank(admin);
        src.setFeed(address(nvda), address(feed), 26 hours, 2000);
        _pinEnd();
    }

    /// C2-16 finding 1: re-pointing the feed after the pin does not reach the pinned window, nor does removing it. A
    /// window ending anywhere else, and latest, follow the new feed.
    function test_pin_repointedOrRemovedFeed_pinnedWindowUnchanged() public {
        feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 50);
        _allowOracle();
        _pinEnd();

        MockRoundFeed evil = new MockRoundFeed(8, "RHNVDA / USD");
        evil.push(_ans(400_000_000), start - 4000);
        evil.push(_ans(400_000_000), start - 50);
        vm.prank(admin);
        src.setFeed(address(nvda), address(evil), 7 days, 5000);

        _assertWindow(200_000_000);
        (bool ok, uint256 price) = src.windowPrice(address(nvda), start - 1, end - 1);
        assertTrue(ok, "an unpinned window");
        assertEq(price, 400_000_000, "reads the new feed");
        (ok, price,) = src.latest(address(nvda));
        assertTrue(ok, "latest ok");
        assertEq(price, 400_000_000, "latest reads the new feed");

        vm.prank(admin);
        src.setFeed(address(nvda), address(0), 0, 0);
        _assertWindow(200_000_000);
    }

    /// Loosening maxStale after the pin does not rescue a pinned window the pinned bound refused; an unpinned window
    /// with the same staleness gets the new bound.
    function test_pin_loosenedBounds_doNotReachThePinnedWindow() public {
        feed.push(_ans(200_000_000), start - 31 hours);
        feed.push(_ans(200_000_000), start - 30 hours);
        _assertWindowNotOk();
        _allowOracle();
        _pinEnd();
        vm.prank(admin);
        src.setFeed(address(nvda), address(feed), 7 days, 2000);
        _assertWindowNotOk();
        (bool ok,) = src.windowPrice(address(nvda), start + 1, end + 1);
        assertTrue(ok, "an unpinned window gets the looser bound");
    }

    /// Pinning an underlying without a feed fails closed (NoSource) and pins nothing, so the series that asked cannot
    /// be created; once a feed is set the pin succeeds and prices the expiry.
    function test_pin_unconfigured_reverts() public {
        MockStockToken tsla = new MockStockToken("TSLA Stock Token", "TSLAx");
        feed.push(_ans(199_000_000), start - 4000);
        feed.push(_ans(200_000_000), start - 50);
        _allowOracle();
        vm.prank(oracleAddr);
        vm.expectRevert(V2Errors.NoSource.selector);
        src.pin(address(tsla), end);
        (,,, bool pinned) = src.pinnedFeeds(address(tsla), end);
        assertFalse(pinned, "nothing pinned");

        vm.prank(admin);
        src.setFeed(address(tsla), address(feed), 26 hours, 2000);
        vm.expectEmit(address(src));
        emit FeedPinned(address(tsla), end, address(feed), 26 hours, 2000);
        vm.prank(oracleAddr);
        src.pin(address(tsla), end);
        (bool ok,) = src.windowPrice(address(tsla), start, end);
        assertTrue(ok, "priced once configured and pinned");
    }

    /*//////////////////////////////////////////////////////////////
                               PriceLib
    //////////////////////////////////////////////////////////////*/

    function test_priceLib_normalizeAnswer_table() public pure {
        _norm(215_12345678, 8, true, 215_123_456);
        _norm(215_123456, 6, true, 215_123_456);
        _norm(2_151_234, 4, true, 215_123_400);
        _norm(215.123456789e18, 18, true, 215_123_456);
        _norm(0, 8, false, 0);
        _norm(-1, 8, false, 0);
        _norm(99, 8, false, 0); // 0.00000099 USD -> 0 base units
        _norm(1, 6, true, 1);
        _norm(type(int256).max, 255, false, 0);
        _norm(type(int256).max, 83, false, 0); // exponent 77: answered without computing 10^77
        _norm(int256(uint256(type(uint128).max)), 6, true, type(uint128).max);
        _norm(int256(uint256(type(uint128).max)) + 1, 6, false, 0);
        _norm(int256(uint256(type(uint128).max)), 5, false, 0);
        _norm(type(int256).max, 0, false, 0);
    }

    function _norm(int256 answer, uint8 dec, bool expectOk, uint256 expectPrice) internal pure {
        (bool ok, uint256 price) = PriceLib.normalizeAnswer(answer, dec);
        assertEq(ok, expectOk, "normalize ok");
        assertEq(price, expectPrice, "normalize price");
    }

    function test_priceLib_exceedsJump_table() public pure {
        assertFalse(PriceLib.exceedsJump(240, 200, 2000), "+20 % at 2000");
        assertTrue(PriceLib.exceedsJump(241, 200, 2000), "+20.5 % at 2000");
        assertFalse(PriceLib.exceedsJump(160, 200, 2000), "-20 % at 2000");
        assertTrue(PriceLib.exceedsJump(159, 200, 2000), "-20.5 % at 2000");
        assertFalse(PriceLib.exceedsJump(200, 200, 0), "no move at 0");
        assertTrue(PriceLib.exceedsJump(1, 200e8, 5000), "1e8 down-scale at the ceiling");
        assertFalse(PriceLib.exceedsJump(type(uint128).max, type(uint128).max - 1, 1), "extremes do not overflow");
    }

    /*//////////////////////////////////////////////////////////////
                                   FUZZ
    //////////////////////////////////////////////////////////////*/

    /// Up to 12 rounds at random times around the window, each within +-10 % of the previous one: windowPrice
    /// equals a forward integration of the step function, and `latest` is the newest round.
    function testFuzz_window_matchesForwardReference(uint256 seed, uint8 countRaw) public {
        uint256 count = bound(countRaw, 1, 12);
        uint256[] memory times = new uint256[](count + 2);
        uint256[] memory prices = new uint256[](count + 2);
        times[0] = start - 7200;
        prices[0] = 200_000_000;
        times[1] = start - 3600;
        prices[1] = 200_000_000;
        uint256 t = start - 1800;
        for (uint256 i = 2; i < count + 2; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            t += 1 + (seed % 400);
            times[i] = t;
            uint256 moveBps = (seed >> 32) % 1001;
            prices[i] = (seed >> 64) % 2 == 0
                ? prices[i - 1] + prices[i - 1] * moveBps / 10_000
                : prices[i - 1] - prices[i - 1] * moveBps / 10_000;
        }
        for (uint256 i; i < count + 2; ++i) {
            feed.push(_ans(prices[i]), times[i]);
        }

        // Forward reference: the price in force at each second of [start, end).
        uint256 weighted;
        for (uint256 i; i < count + 2; ++i) {
            uint256 from = times[i] < start ? start : times[i];
            uint256 to = i + 1 < count + 2 && times[i + 1] < end ? times[i + 1] : end;
            if (i + 1 < count + 2 && times[i + 1] <= start) continue;
            if (from >= end) break;
            weighted += prices[i] * (to - from);
        }
        _assertWindow(weighted / 1800);

        (bool ok, uint256 p, uint256 at) = src.latest(address(nvda));
        assertTrue(ok, "latest ok");
        assertEq(p, prices[count + 1], "latest price");
        assertEq(at, times[count + 1], "latest updatedAt");
    }

    /// Arbitrary rounds, decimals and windows never make either view revert.
    function testFuzz_views_neverRevert(int256 a0, int256 a1, uint64 t0, uint64 t1, uint8 dec, uint40 s, uint40 e)
        public
    {
        a0 = bound(a0, type(int192).min, type(int192).max);
        a1 = bound(a1, type(int192).min, type(int192).max);
        feed.setDecimals(dec);
        feed.push(a0, t0);
        feed.push(a1, t1);
        src.windowPrice(address(nvda), s, e);
        src.latest(address(nvda));
    }
}
