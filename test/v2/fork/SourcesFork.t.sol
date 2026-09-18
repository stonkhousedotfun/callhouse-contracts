// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {ChainlinkFeedSource} from "../../../src/v2/oracle/ChainlinkFeedSource.sol";
import {UniV3TwapSource} from "../../../src/v2/oracle/UniV3TwapSource.sol";
import {IAggregatorV3, IUniswapV3PoolOracle} from "../../../src/v2/oracle/OracleDeps.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";

interface IFeedDescription {
    function description() external view returns (string memory);
}

interface IPoolFee {
    function fee() external view returns (uint24);
}

/// @notice ChainlinkFeedSource and UniV3TwapSource against the LIVE NVDA feed and NVDA/USDG 0.05 % pool on a fork of
///         chain 4663: the feed's round walk over the last completed session window and the pool's price over the same
///         window agree within 150 bps, the walk matches a TWAP recomputed here round by round, and `record` works on
///         the real pool.
/// @dev Run with:  FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC --match-path "test/v2/fork/SourcesFork.t.sol" -vv
///      Without a fork (chain id != 4663) every test logs and returns, as test/fork/ForkLive.t.sol does.
///
///      NO ROLL, NO WARP. The forks run at the RPC's latest block. The public RPC keeps no historical state (a call
///      at a block ~2.5 h old answers "historical state ... is not available"), so the fork cannot be rolled back to
///      just after a close; and warping backwards would put `block.timestamp` behind the pool's newest observation,
///      which v3-core's Oracle arithmetic does not allow. Neither is needed: the feed's round history is on chain
///      (that is the point of the walk), and the pool's observation ring (cardinality 6,000, about 68 h of history
///      at R13) still holds the cumulatives of a recent past window, which UniV3TwapSource.observeWindow reads with
///      exactly the code `record` uses. `record` itself is exercised with `expiry = now`, the one expiry a
///      latest-block fork can record. When the pool's buffer no longer reaches the last session window (a Monday
///      run after a quiet weekend) the agreement test is SKIPPED with the reason, never passed silently.
///
///      The last session close is the most recent 16:00 America/New_York on a weekday that is not an NYSE full
///      closure in R13's 2026-2028 table (ops/markets/v2-sources.json `nyseHolidays`); the US DST rule is computed
///      here with Howard Hinnant's civil-date algorithms. Extend the table past 2028.
contract SourcesForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address constant NVDA_POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;

    /// @dev The live pool's in-range liquidity was 1.86e19 at R13; a floor an order of magnitude below it.
    uint128 constant NVDA_MIN_LIQUIDITY = 1e18;
    /// @dev The C2-03 gate: the two sources agree within this over the same window.
    uint256 constant AGREE_BPS = 150;

    address admin = makeAddr("admin");
    ChainlinkFeedSource feedSrc;
    UniV3TwapSource poolSrc;

    modifier onlyFork() {
        if (block.chainid != 4663) {
            console2.log("skipping: not forked onto 4663 (chainid %s)", block.chainid);
            return;
        }
        _;
    }

    function setUp() public {
        if (block.chainid != 4663) return;
        feedSrc = new ChainlinkFeedSource(admin);
        poolSrc = new UniV3TwapSource(admin, USDG);
        vm.startPrank(admin);
        feedSrc.setFeed(NVDA, NVDA_FEED, feedSrc.DEFAULT_MAX_STALE(), feedSrc.DEFAULT_MAX_ROUND_JUMP_BPS());
        poolSrc.setPool(NVDA, NVDA_POOL, NVDA_MIN_LIQUIDITY, poolSrc.DEFAULT_WINDOW());
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                         THE LIVE CONTRACTS' SHAPE
    //////////////////////////////////////////////////////////////*/

    function test_fork_liveFeedAndPoolShape() public view onlyFork {
        assertEq(IAggregatorV3(NVDA_FEED).decimals(), 8, "feed decimals");
        assertEq(IFeedDescription(NVDA_FEED).description(), "RHNVDA / USD", "feed description");
        (uint80 id,,,,) = IAggregatorV3(NVDA_FEED).latestRoundData();
        assertGt(id >> 64, 0, "phase-prefixed round ids");

        assertEq(IUniswapV3PoolOracle(NVDA_POOL).token0(), USDG, "USDG is token0");
        assertEq(IUniswapV3PoolOracle(NVDA_POOL).token1(), NVDA, "NVDA is token1");
        assertEq(IPoolFee(NVDA_POOL).fee(), 500, "0.05 % pool");
        (address pool, bool usdgIsToken0, uint8 dec,,) = poolSrc.pools(NVDA);
        assertEq(pool, NVDA_POOL, "configured");
        assertTrue(usdgIsToken0, "source read USDG as token0");
        assertEq(dec, 18, "NVDA decimals");
    }

    /*//////////////////////////////////////////////////////////////
                    LAST SESSION WINDOW: FEED VS POOL
    //////////////////////////////////////////////////////////////*/

    function test_fork_lastSessionWindow_feedWalkAndPoolAgree() public onlyFork {
        uint40 expiry = _lastSessionClose(block.timestamp);
        uint40 start = expiry - V2Constants.SETTLEMENT_WINDOW;
        console2.log("last session close (unix):", expiry);
        console2.log("seconds since the close:", block.timestamp - expiry);

        uint256 gasBefore = gasleft();
        (bool feedOk, uint256 feedPrice) = feedSrc.windowPrice(NVDA, start, expiry);
        uint256 walkGas = gasBefore - gasleft();
        console2.log("feed window price (USDG 6dp):", feedPrice);
        console2.log("gas: live round walk:", walkGas);
        assertTrue(feedOk, "the real feed walk prices the last session window");
        assertLt(walkGas, 1_500_000, "live walk under 1.5M gas");
        assertEq(feedPrice, _referenceFeedTwap(start, expiry), "walk == round-by-round reference");

        uint32[] memory ago = new uint32[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        ago[0] = uint32(block.timestamp - start);
        try IUniswapV3PoolOracle(NVDA_POOL).observe(ago) {}
        catch {
            console2.log("skipping: the pool's observation buffer no longer reaches the window start");
            vm.skip(true);
        }

        (bool poolOk, uint256 poolPrice, int24 meanTick, uint256 harmonicLiquidity) =
            poolSrc.observeWindow(NVDA, start, expiry);
        console2.log("pool window price (USDG 6dp):", poolPrice);
        console2.log("pool mean tick:", meanTick);
        console2.log("pool harmonic-mean liquidity:", harmonicLiquidity);
        assertTrue(poolOk, "the real pool prices the same window above the liquidity floor");

        uint256 bps = _deviationBps(feedPrice, poolPrice);
        console2.log("feed vs pool, bps:", bps);
        assertLe(bps, AGREE_BPS, "feed walk and pool TWAP agree within 150 bps");
    }

    /// The live cost of the longest walk the cap allows. The window is placed so the walk reads 93 rounds newer than
    /// `end`, the round stamped exactly at `end`, the round in force at `start = end - 1`, and that round's
    /// predecessor: 96 reads through the real proxy and aggregator. maxStale is widened to 7 days only so that a
    /// weekend between two rounds that far back cannot make the walk stale; the reads are the same either way.
    function test_fork_96ReadWalkGas() public onlyFork {
        vm.prank(admin);
        feedSrc.setFeed(NVDA, NVDA_FEED, 7 days, 2000);
        (uint80 head,,,,) = IAggregatorV3(NVDA_FEED).latestRoundData();
        (,,, uint256 endAt,) = IAggregatorV3(NVDA_FEED).getRoundData(head - 93);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 end = uint40(endAt);

        uint256 gasBefore = gasleft();
        (bool ok, uint256 price) = feedSrc.windowPrice(NVDA, end - 1, end);
        uint256 used = gasBefore - gasleft();
        console2.log("gas: live 96-read walk:", used);
        console2.log("price (USDG 6dp):", price);
        assertTrue(ok, "96-read live walk ok");
        assertLt(used, 1_500_000, "live 96-read walk under 1.5M gas");
    }

    /*//////////////////////////////////////////////////////////////
                         RECORD ON THE LIVE POOL
    //////////////////////////////////////////////////////////////*/

    function test_fork_recordOnLivePool() public onlyFork {
        uint40 expiry = uint40(block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.TooEarly.selector, expiry + 1));
        poolSrc.record(NVDA, expiry + 1);

        (bool ok, uint256 observed,,) = poolSrc.observeWindow(NVDA, expiry - V2Constants.SETTLEMENT_WINDOW, expiry);
        assertTrue(ok, "the live trailing window prices");

        uint256 gasBefore = gasleft();
        assertTrue(poolSrc.record(NVDA, expiry), "record on the live pool");
        console2.log("gas: record on the live pool:", gasBefore - gasleft());
        assertFalse(poolSrc.record(NVDA, expiry), "second record returns false");

        uint256 stored;
        (ok, stored) = poolSrc.windowPrice(NVDA, expiry - V2Constants.SETTLEMENT_WINDOW, expiry);
        assertTrue(ok, "windowPrice serves the snapshot");
        assertEq(stored, observed, "the snapshot is what observeWindow read");
        console2.log("recorded pool price (USDG 6dp):", stored);
    }

    /// @dev Sweep contracts-c10: `setPool` takes a registry pool only when its observation ring holds at least
    ///      SETTLEMENT_WINDOW + SNAPSHOT_GRACE + 1 = 2401 observations, so no flood of one write per second can overwrite
    ///      a snapshot's window inside the grace. Read live: on 2026-09-17 only NVDA (6,000) and SPCX (3,100) passed;
    ///      the other eleven held 1,800 to 1,860 until `increaseObservationCardinalityNext` raises them.
    function test_fork_setPool_refusesRegistryPoolsWithARingShallowerThanTheGrace() public onlyFork {
        address[13] memory registryPools = [
            0xAae0d815EE56e4092a5E5C2911E676Fea50B2d6D, // AAPL
            0x8AC92DA74AB5F3b1d024Dc1943Ad7e15Dc4179Ef, // AMZN
            0x654E4143e82a5824445Ade0824351C2A9ACD95a8, // CRCL
            0xE9713f453aDB9245B19559790c96F470a18F2fDF, // GME
            0x34D0dC122CF9A8Eb296fC5e0D3A233625D7d19b7, // GOOGL
            0xeb60bCD1D920ad6E102690CCFC6fB488899E1510, // MSFT
            0xd057B1Bc54917855BBee58eAd58647f47caB35E5, // MU
            NVDA_POOL,
            0xD60A5d14dB690B7Afad71F76B108071D7175597d, // QQQ
            0xfAb520051f96F4D2a32c22B6a3dD7fFfdf231bFe, // SGOV
            0xc61284332117c3FB23A2A56cceFFD07F7aF60029, // SPCX
            0xf4ACdAEEB7022862A763C9B1B885e11191c889E3, // TSLA
            0x02175608F1b5E6b5ed221cCFdC7Be197D111D915 // USO
        ];
        uint256 minCardinality = uint256(V2Constants.SETTLEMENT_WINDOW) + V2Constants.SNAPSHOT_GRACE + 1;
        uint32 window = poolSrc.DEFAULT_WINDOW();
        for (uint256 i; i < registryPools.length; ++i) {
            IUniswapV3PoolOracle pool = IUniswapV3PoolOracle(registryPools[i]);
            address asset = pool.token0() == USDG ? pool.token1() : pool.token0();
            (,,, uint16 cardinality,,,) = pool.slot0();
            console2.log("registry pool, observationCardinality:", address(pool), cardinality);
            vm.prank(admin);
            if (cardinality < minCardinality) vm.expectRevert(V2Errors.UnsupportedAsset.selector);
            poolSrc.setPool(asset, address(pool), NVDA_MIN_LIQUIDITY, window);
        }
    }

    /// Both `latest` values are ok on the live contracts and sane against each other. Loose on purpose: the feed's
    /// latest round can be hours old and the pool trades around the clock, so this guards against order, decimals
    /// and scale mistakes (which are off by orders of magnitude), not against the market.
    function test_fork_latestBothOk() public view onlyFork {
        (bool feedOk, uint256 feedPrice, uint256 feedAt) = feedSrc.latest(NVDA);
        (bool poolOk, uint256 poolPrice, uint256 poolAt) = poolSrc.latest(NVDA);
        console2.log("feed latest (USDG 6dp), age s:", feedPrice, block.timestamp - feedAt);
        console2.log("pool 5-min TWAP (USDG 6dp):", poolPrice);
        assertTrue(feedOk, "feed latest ok");
        assertTrue(poolOk, "pool latest ok");
        assertEq(poolAt, block.timestamp, "pool latest is now");
        assertLe(_deviationBps(feedPrice, poolPrice), 1000, "within 10 %");
        assertFalse(feedSrc.record(NVDA, uint40(block.timestamp)), "the feed source records nothing");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev The window TWAP recomputed without the source: collect every round back to the one in force at `start`,
    ///      then integrate forward.
    function _referenceFeedTwap(uint40 start, uint40 end) internal view returns (uint256) {
        uint256[] memory times = new uint256[](96);
        uint256[] memory prices = new uint256[](96);
        uint256 n;
        (uint80 id, int256 answer,, uint256 updatedAt,) = IAggregatorV3(NVDA_FEED).latestRoundData();
        while (true) {
            if (updatedAt <= end) {
                times[n] = updatedAt;
                // forge-lint: disable-next-line(unsafe-typecast)
                prices[n] = uint256(answer) / 100; // 8 dp -> 6 dp
                ++n;
                if (updatedAt <= start) break;
            }
            --id;
            (, answer,, updatedAt,) = IAggregatorV3(NVDA_FEED).getRoundData(id);
        }
        uint256 weighted;
        uint256 to = end;
        for (uint256 i; i < n; ++i) {
            uint256 from = times[i] < start ? start : times[i];
            weighted += prices[i] * (to - from);
            to = from;
        }
        return weighted / (end - start);
    }

    function _deviationBps(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a > b ? a - b : b - a) * 10_000 / a;
    }

    /// @dev Most recent 16:00 New York on a weekday that is not an NYSE full closure, at or before `ts`.
    function _lastSessionClose(uint256 ts) internal pure returns (uint40) {
        uint256 today = ts / 1 days;
        for (uint256 i; i < 14; ++i) {
            uint256 day = today - i;
            uint256 weekday = (day + 4) % 7; // 1970-01-01 was a Thursday; 0 = Sunday
            if (weekday == 0 || weekday == 6 || _isNyseHoliday(day)) continue;
            // 16:00 New York is 20:00 UTC under EDT (UTC-4) and 21:00 UTC under EST (UTC-5), on the same UTC day.
            uint256 close = day * 1 days + (_isEdt(day) ? 20 hours : 21 hours);
            // forge-lint: disable-next-line(unsafe-typecast)
            if (close <= ts) return uint40(close);
        }
        revert("no session close in 14 days");
    }

    /// @dev EDT from the second Sunday of March to the first Sunday of November; the 02:00 switch never matters at
    ///      16:00, so dates are compared.
    function _isEdt(uint256 day) internal pure returns (bool) {
        (uint256 y, uint256 m, uint256 d) = _civilFromDays(day);
        if (m > 3 && m < 11) return true;
        if (m == 3) return d >= _firstSunday(y, 3) + 7;
        if (m == 11) return d < _firstSunday(y, 11);
        return false;
    }

    function _firstSunday(uint256 y, uint256 m) internal pure returns (uint256) {
        uint256 weekdayOfFirst = (_daysFromCivil(y, m, 1) + 4) % 7;
        return 1 + (7 - weekdayOfFirst) % 7;
    }

    /// @dev R13 full closures 2026-2028 as UTC day indexes of the New York date.
    function _isNyseHoliday(uint256 day) internal pure returns (bool) {
        uint16[29] memory closures = [
            20454,
            20472,
            20500,
            20546,
            20598,
            20623,
            20637,
            20703,
            20783,
            20812, // 2026
            20819,
            20836,
            20864,
            20903,
            20969,
            20987,
            21004,
            21067,
            21147,
            21176, // 2027
            21200,
            21235,
            21288,
            21333,
            21354,
            21369,
            21431,
            21511,
            21543 // 2028
        ];
        for (uint256 i; i < closures.length; ++i) {
            if (closures[i] == day) return true;
        }
        return false;
    }

    /// @dev Howard Hinnant's civil_from_days for days >= 0 (1970-01-01).
    function _civilFromDays(uint256 z) internal pure returns (uint256 y, uint256 m, uint256 d) {
        z += 719_468;
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097;
        uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        d = doy - (153 * mp + 2) / 5 + 1;
        m = mp < 10 ? mp + 3 : mp - 9;
        y = yoe + era * 400 + (m <= 2 ? 1 : 0);
    }

    /// @dev Howard Hinnant's days_from_civil for years >= 1970.
    function _daysFromCivil(uint256 y, uint256 m, uint256 d) internal pure returns (uint256) {
        if (m <= 2) --y;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146_097 + doe - 719_468;
    }
}
