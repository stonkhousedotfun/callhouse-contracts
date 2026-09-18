// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UniV3TwapSource} from "../../../src/v2/oracle/UniV3TwapSource.sol";
import {TickMath} from "../../../src/v2/oracle/lib/TickMath.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {IPriceSource} from "../../../src/v2/interfaces/IPriceSource.sol";
import {MockUniV3Pool} from "../../../src/v2/mocks/MockUniV3Pool.sol";
import {MockStockToken} from "../../../src/mocks/MockStockToken.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";

/// @dev A pool whose `observe` reply is whatever bytes the test sets, for replies no Uniswap pool (and no typed mock)
///      produces: short data, out-of-bounds offsets, words that are not int56/uint160.
contract RawReplyPool {
    address public token0;
    address public token1;
    bytes internal _reply;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function setReply(bytes calldata reply) external {
        _reply = reply;
    }

    /// @dev A deep observation ring (the 4th word), so {UniV3TwapSource.setPool} accepts the pool.
    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (0, 0, 0, type(uint16).max, type(uint16).max, 0, true);
    }

    fallback() external {
        bytes memory r = _reply;
        assembly {
            return(add(r, 0x20), mload(r))
        }
    }
}

/// @notice UniV3TwapSource: tick-to-price conversion for both token orders against exact powers of 1.0001, the
///         mean tick of a step function (including floor rounding of negative means), harmonic-mean liquidity and its
///         floor, the snapshot window (TooEarly / grace / once), the window pinned to expiry, `latest`, malformed pool
///         replies, admin configuration, and fuzzed never-revert and order-symmetry properties.
/// @dev Self-contained setup (C2-08 consolidates into BaseV2 later). NVDA trades against a pool with USDG as token0
///      (the live NVDA pool's order); TSLA against a pool with the asset as token0. Expected prices come from
///      `1e18 / 1.0001^tick` evaluated with 90-digit integer arithmetic in node, independently of TickMath:
///        tick 222615 -> 214_999_159, 222616 -> 214_977_661, 222664 -> 213_948_292, 276324 -> 1_000_002,
///        191000 -> 5_074_463_338, 250000 -> 13_905_313 (USDG base units per share; the asset-token0 pool at -tick
///        is the same number). The conversion floors, so assertions allow 1 base unit.
contract UniV3TwapSourceTest is Test {
    uint40 internal constant T0 = 1_789_000_000;
    uint40 internal constant E = T0 + 1 days;
    uint128 internal constant L = 1e19;
    uint128 internal constant MIN_LIQ = 1e18;

    address internal admin = makeAddr("admin");
    address internal stranger = makeAddr("stranger");

    MockERC20 internal usdg;
    MockStockToken internal nvda;
    MockStockToken internal tsla;
    MockUniV3Pool internal poolA; // token0 = USDG, token1 = NVDA
    MockUniV3Pool internal poolB; // token0 = TSLA, token1 = USDG
    UniV3TwapSource internal src;

    event PoolSet(
        address indexed underlying, address indexed pool, bool usdgIsToken0, uint128 minLiquidity, uint32 window
    );
    event Recorded(
        address indexed underlying, uint40 indexed expiry, uint256 price, int24 meanTick, uint256 harmonicMeanLiquidity
    );

    function setUp() public {
        vm.warp(T0);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        nvda = new MockStockToken("NVDA Stock Token", "NVDAx");
        tsla = new MockStockToken("TSLA Stock Token", "TSLAx");
        poolA = new MockUniV3Pool(address(usdg), address(nvda), 500);
        poolB = new MockUniV3Pool(address(tsla), address(usdg), 500);
        src = new UniV3TwapSource(admin, address(usdg));
        vm.startPrank(admin);
        src.setPool(address(nvda), address(poolA), MIN_LIQ, 300);
        src.setPool(address(tsla), address(poolB), MIN_LIQ, 300);
        vm.stopPrank();
    }

    function _snapshotPrice(address underlying, uint40 expiry) internal view returns (uint256 price, int24 meanTick) {
        (uint128 p, int24 t,) = src.snapshots(underlying, expiry);
        return (p, t);
    }

    /*//////////////////////////////////////////////////////////////
                        PRICE CONVERSION, BOTH ORDERS
    //////////////////////////////////////////////////////////////*/

    function test_price_usdgToken0_matchesExactPowers() public {
        int24[5] memory ticks = [int24(222615), 222616, 276324, 191000, 250000];
        uint256[5] memory expected = [uint256(214_999_159), 214_977_661, 1_000_002, 5_074_463_338, 13_905_313];
        _checkTable(poolA, address(nvda), ticks, expected);
    }

    function test_price_assetToken0_matchesExactPowers() public {
        int24[5] memory ticks = [int24(-222615), -222616, -276324, -191000, -250000];
        uint256[5] memory expected = [uint256(214_999_159), 214_977_661, 1_000_002, 5_074_463_338, 13_905_313];
        _checkTable(poolB, address(tsla), ticks, expected);
    }

    /// Each tick holds for 10,000 s; the window [segment + 100, segment + 1900] sits inside it.
    function _checkTable(MockUniV3Pool pool, address underlying, int24[5] memory ticks, uint256[5] memory expected)
        internal
    {
        for (uint256 i; i < 5; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            pool.pushState(uint40(T0 + i * 10_000), ticks[i], L);
        }
        vm.warp(T0 + 60_000);
        for (uint256 i; i < 5; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint40 s = uint40(T0 + i * 10_000 + 100);
            (bool ok, uint256 price, int24 meanTick, uint256 hl) = src.observeWindow(underlying, s, s + 1800);
            assertTrue(ok, "ok");
            assertEq(meanTick, ticks[i], "mean tick of a constant tick");
            assertApproxEqAbs(price, expected[i], 1, "price vs exact 1.0001^tick");
            // Each segment accumulates a floored (dt << 128) / L, so a window crossing a segment edge can lose 1.
            assertApproxEqAbs(hl, L, 1, "constant liquidity");
        }
    }

    /*//////////////////////////////////////////////////////////////
                          MEAN TICK, STEP FUNCTION
    //////////////////////////////////////////////////////////////*/

    /// 900 s at 222566 and 900 s at 222664: mean 222615 exactly.
    function test_meanTick_stepFunction_recorded() public {
        poolA.pushState(T0, 222566, L);
        poolA.pushState(E - 900, 222664, L);
        vm.warp(E);
        assertTrue(src.record(address(nvda), E), "recorded");
        (uint256 price, int24 meanTick) = _snapshotPrice(address(nvda), E);
        assertEq(meanTick, 222615, "mean tick");
        assertApproxEqAbs(price, 214_999_159, 1, "price at the mean tick");
    }

    /// Positive half tick truncates down; negative half tick floors toward negative infinity (OracleLibrary.consult).
    function test_meanTick_halfTicks_floorTowardNegativeInfinity() public {
        poolA.pushState(T0, 222615, L);
        poolA.pushState(E - 900, 222616, L);
        poolB.pushState(T0, -222615, L);
        poolB.pushState(E - 900, -222616, L);
        vm.warp(E);

        (bool ok, uint256 priceA, int24 tickA,) = src.observeWindow(address(nvda), E - 1800, E);
        assertTrue(ok, "A ok");
        assertEq(tickA, 222615, "+222615.5 -> 222615");
        assertApproxEqAbs(priceA, 214_999_159, 1, "A price");

        (bool okB, uint256 priceB, int24 tickB,) = src.observeWindow(address(tsla), E - 1800, E);
        assertTrue(okB, "B ok");
        assertEq(tickB, -222616, "-222615.5 -> -222616");
        assertApproxEqAbs(priceB, 214_977_661, 1, "B price");
    }

    /*//////////////////////////////////////////////////////////////
                         HARMONIC-MEAN LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    /// 900 s at 1e18 and 900 s at 3e18: 1800 / (900/1e18 + 900/3e18) = 1.5e18.
    function test_liquidity_harmonicMean() public {
        poolA.pushState(T0, 222615, 1e18);
        poolA.pushState(E - 900, 222615, 3e18);
        vm.warp(E);
        (,,, uint256 hl) = src.observeWindow(address(nvda), E - 1800, E);
        assertApproxEqAbs(hl, 1.5e18, 1, "harmonic mean");
    }

    function test_liquidityFloor_boundary() public {
        poolA.pushState(T0, 222615, uint128(1 << 60));
        vm.warp(E);
        vm.prank(admin);
        src.setPool(address(nvda), address(poolA), uint128(1 << 60), 300);
        (bool ok,,, uint256 hl) = src.observeWindow(address(nvda), E - 1800, E);
        assertTrue(ok, "exactly the floor is ok");
        assertEq(hl, 1 << 60, "exact harmonic mean");

        vm.prank(admin);
        src.setPool(address(nvda), address(poolA), uint128(1 << 60) + 1, 300);
        uint256 price;
        int24 tick;
        (ok, price, tick, hl) = src.observeWindow(address(nvda), E - 1800, E);
        assertFalse(ok, "one below the floor");
        assertEq(price, 0, "no price below the floor");
        assertEq(tick, 222615, "tick still reported");
        assertEq(hl, 1 << 60, "liquidity still reported");
        assertFalse(src.record(address(nvda), E), "record refuses");
        (bool latestOk,,) = src.latest(address(nvda));
        assertFalse(latestOk, "latest refuses");
    }

    /// Deep for 1,790 s, nearly empty for 10 s: the arithmetic mean is ~9.9e19 but the harmonic mean (~1.8e12) is
    /// what the floor sees, because the thin stretch is where the price is cheap to move.
    function test_liquidityFloor_shortThinStretchFails() public {
        poolA.pushState(T0, 222615, 1e20);
        poolA.pushState(E - 10, 222615, 1e10);
        vm.warp(E);
        (bool ok,,, uint256 hl) = src.observeWindow(address(nvda), E - 1800, E);
        assertFalse(ok, "thin stretch fails the floor");
        assertApproxEqRel(hl, 1.8e12, 0.001e18, "harmonic mean ~1.8e12");
        assertFalse(src.record(address(nvda), E), "record refuses");
    }

    /*//////////////////////////////////////////////////////////////
                             SNAPSHOT WINDOW
    //////////////////////////////////////////////////////////////*/

    function test_record_tooEarlyBeforeExpiry() public {
        poolA.pushState(T0, 222615, L);
        vm.warp(E - 1);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.TooEarly.selector, E));
        src.record(address(nvda), E);
    }

    function test_record_atExpiry_onceOnly() public {
        poolA.pushState(T0, 222615, L);
        vm.warp(E);
        (, uint256 expectPrice, int24 expectTick, uint256 expectHl) = src.observeWindow(address(nvda), E - 1800, E);
        vm.expectEmit(address(src));
        emit Recorded(address(nvda), E, expectPrice, expectTick, expectHl);
        vm.prank(stranger);
        assertTrue(src.record(address(nvda), E), "first record");

        (bool ok, uint256 price) = src.windowPrice(address(nvda), E - V2Constants.SETTLEMENT_WINDOW, E);
        assertTrue(ok, "windowPrice ok");
        assertEq(price, expectPrice, "stored price");
        (,, uint40 recordedAt) = src.snapshots(address(nvda), E);
        assertEq(recordedAt, E, "recordedAt");

        vm.warp(E + 60);
        assertFalse(src.record(address(nvda), E), "second record returns false");
        (, price) = src.windowPrice(address(nvda), E - V2Constants.SETTLEMENT_WINDOW, E);
        assertEq(price, expectPrice, "unchanged");
    }

    function test_record_graceBoundary() public {
        poolA.pushState(T0, 222615, L);
        uint40 e2 = E + 1 hours;
        vm.warp(uint256(E) + V2Constants.SNAPSHOT_GRACE);
        assertTrue(src.record(address(nvda), E), "last second of the grace");

        vm.warp(uint256(e2) + V2Constants.SNAPSHOT_GRACE + 1);
        assertFalse(src.record(address(nvda), e2), "one second after the grace: false, no revert");
        (uint128 p,,) = src.snapshots(address(nvda), e2);
        assertEq(p, 0, "nothing stored");
        (bool ok,) = src.windowPrice(address(nvda), e2 - V2Constants.SETTLEMENT_WINDOW, e2);
        assertFalse(ok, "windowPrice not ok");
    }

    /// The snapshot is the window [expiry - 1800, expiry], whenever in the grace it is taken: a 20 %+ move one second
    /// after expiry does not enter a snapshot taken at the end of the grace, although "the last 30 minutes before
    /// now" would include 599 seconds of it.
    function test_record_windowPinnedToExpiry() public {
        poolA.pushState(T0, 222615, L);
        poolA.pushState(E + 1, 220615, L);
        vm.warp(uint256(E) + V2Constants.SNAPSHOT_GRACE);
        (bool nowOk, uint256 lastThirtyMinutes,,) =
            src.observeWindow(address(nvda), uint40(block.timestamp - 1800), uint40(block.timestamp));
        assertTrue(nowOk, "trailing window readable");

        assertTrue(src.record(address(nvda), E), "recorded late in the grace");
        (uint256 price, int24 meanTick) = _snapshotPrice(address(nvda), E);
        assertEq(meanTick, 222615, "only pre-expiry ticks");
        assertApproxEqAbs(price, 214_999_159, 1, "pre-expiry price");
        assertGt(lastThirtyMinutes, price + 5_000_000, "a trailing window would have moved");
    }

    function test_windowPrice_onlyTheRecordedWindow() public {
        poolA.pushState(T0, 222615, L);
        vm.warp(E);
        src.record(address(nvda), E);
        (bool ok,) = src.windowPrice(address(nvda), E - 1799, E);
        assertFalse(ok, "a different start");
        (ok,) = src.windowPrice(address(nvda), E - 1800 - 60, E - 60);
        assertFalse(ok, "an unrecorded end");
        (ok,) = src.windowPrice(address(tsla), E - 1800, E);
        assertFalse(ok, "another underlying");
    }

    function test_record_unconfigured() public {
        address other = address(new MockStockToken("Other", "OTH"));
        vm.warp(E - 1);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.TooEarly.selector, E));
        src.record(other, E);
        vm.warp(E);
        assertFalse(src.record(other, E), "no pool: false");
        (bool ok,,) = src.latest(other);
        assertFalse(ok, "no pool: latest not ok");
    }

    /// The pool's observation buffer starts 1,000 s before expiry: observe reverts OLD, record returns false.
    function test_record_bufferDoesNotReach() public {
        poolA.pushState(E - 1000, 222615, L);
        vm.warp(E);
        assertFalse(src.record(address(nvda), E), "OLD -> false");
        (bool ok,,,) = src.observeWindow(address(nvda), E - 1800, E);
        assertFalse(ok, "observeWindow not ok");
    }

    /*//////////////////////////////////////////////////////////////
                                  LATEST
    //////////////////////////////////////////////////////////////*/

    function test_latest_isTheConfiguredTrailingTwap() public {
        poolA.pushState(T0, 222615, L);
        poolA.pushState(E - 300, 222664, L);
        vm.warp(E);
        (bool ok, uint256 price, uint256 updatedAt) = src.latest(address(nvda));
        assertTrue(ok, "ok");
        assertApproxEqAbs(price, 213_948_292, 1, "5-minute TWAP sees only the new tick");
        assertEq(updatedAt, E, "updatedAt is now");

        vm.prank(admin);
        src.setPool(address(nvda), address(poolA), MIN_LIQ, 600);
        (ok, price,) = src.latest(address(nvda));
        assertTrue(ok, "ok");
        assertLt(price, 214_999_159, "10-minute TWAP below the old price");
        assertGt(price, 213_948_292, "and above the new one");
    }

    /*//////////////////////////////////////////////////////////////
                         FAILING AND MALFORMED POOLS
    //////////////////////////////////////////////////////////////*/

    function test_pool_observeReverts_notOkNoRevert() public {
        poolA.pushState(T0, 222615, L);
        poolA.setObserveReverts(true);
        vm.warp(E);
        assertFalse(src.record(address(nvda), E), "record false");
        (bool ok,,) = src.latest(address(nvda));
        assertFalse(ok, "latest not ok");
        (ok,,,) = src.observeWindow(address(nvda), E - 1800, E);
        assertFalse(ok, "observeWindow not ok");
    }

    function test_pool_fixedRepliesNoPoolGives_notOk() public {
        vm.warp(E);
        int56[] memory ticks = new int56[](2);
        uint160[] memory spl = new uint160[](2);

        // Zero seconds-per-liquidity delta.
        ticks[1] = 222615 * 1800;
        spl[0] = 5;
        spl[1] = 5;
        poolA.setObserveResult(ticks, spl);
        _assertAllNotOk(address(nvda));

        // Mean tick one above MAX_TICK.
        ticks[1] = int56(TickMath.MAX_TICK + 1) * 1800;
        spl[1] = 1000;
        poolA.setObserveResult(ticks, spl);
        _assertAllNotOk(address(nvda));

        // Mean tick at MAX_TICK: the price floors to 0 USDG per share with USDG as token0.
        ticks[1] = int56(TickMath.MAX_TICK) * 1800;
        poolA.setObserveResult(ticks, spl);
        _assertAllNotOk(address(nvda));

        // One entry instead of two.
        poolA.setObserveResult(new int56[](1), new uint160[](1));
        _assertAllNotOk(address(nvda));
    }

    function test_pool_rawReplies_neverRevert() public {
        RawReplyPool raw = new RawReplyPool(address(usdg), address(nvda));
        vm.prank(admin);
        src.setPool(address(nvda), address(raw), MIN_LIQ, 300);
        vm.warp(E);

        int56[] memory ticks = new int56[](2);
        uint160[] memory spl = new uint160[](2);
        ticks[1] = 222615 * 1800;
        spl[1] = uint160((uint256(1800) << 128) / L);

        // A well-formed reply decodes and prices.
        raw.setReply(abi.encode(ticks, spl));
        (bool ok, uint256 price,,) = src.observeWindow(address(nvda), E - 1800, E);
        assertTrue(ok, "hand-decoded ABI reply");
        assertApproxEqAbs(price, 214_999_159, 1, "price");

        raw.setReply(hex"01");
        _assertAllNotOk(address(nvda));

        raw.setReply(abi.encode(uint256(1 << 200), uint256(64)));
        _assertAllNotOk(address(nvda));

        // Tick cumulative word that is not a sign-extended int56.
        bytes memory bad = abi.encode(ticks, spl);
        uint256 firstTickWordOffset = 32 + 64 + 32; // bytes length word, two head words, array length word
        assembly {
            mstore(add(bad, firstTickWordOffset), shl(60, 1))
        }
        raw.setReply(bad);
        _assertAllNotOk(address(nvda));

        // Seconds-per-liquidity word wider than uint160.
        bad = abi.encode(ticks, spl);
        uint256 lastWordOffset = bad.length; // the last word of the reply is spl[1]
        assembly {
            mstore(add(bad, lastWordOffset), shl(161, 1))
        }
        raw.setReply(bad);
        _assertAllNotOk(address(nvda));
    }

    function _assertAllNotOk(address underlying) internal {
        (bool ok, uint256 price,,) = src.observeWindow(underlying, E - 1800, E);
        assertFalse(ok, "observeWindow not ok");
        assertEq(price, 0, "no price");
        (ok,,) = src.latest(underlying);
        assertFalse(ok, "latest not ok");
        assertFalse(src.record(underlying, E), "record false");
    }

    /*//////////////////////////////////////////////////////////////
                                  ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_admin_constructor() public {
        assertTrue(src.hasRole(src.DEFAULT_ADMIN_ROLE(), admin), "admin role");
        assertEq(src.usdg(), address(usdg), "usdg");
        assertEq(src.DEFAULT_WINDOW(), 300, "default window");
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        new UniV3TwapSource(address(0), address(usdg));
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        new UniV3TwapSource(admin, address(0));
    }

    function test_admin_setPool_readsTokenOrderAndEmits() public {
        MockStockToken amd = new MockStockToken("AMD Stock Token", "AMDx");
        MockUniV3Pool p0 = new MockUniV3Pool(address(usdg), address(amd), 3000);
        MockUniV3Pool p1 = new MockUniV3Pool(address(amd), address(usdg), 3000);

        vm.expectEmit(address(src));
        emit PoolSet(address(amd), address(p0), true, 5, 60);
        vm.prank(admin);
        src.setPool(address(amd), address(p0), 5, 60);
        (address pool, bool usdgIsToken0, uint8 dec, uint32 window, uint128 minLiq) = src.pools(address(amd));
        assertEq(pool, address(p0), "pool");
        assertTrue(usdgIsToken0, "USDG token0");
        assertEq(dec, 18, "decimals");
        assertEq(window, 60, "window");
        assertEq(minLiq, 5, "floor");

        vm.expectEmit(address(src));
        emit PoolSet(address(amd), address(p1), false, 0, 3600);
        vm.prank(admin);
        src.setPool(address(amd), address(p1), 0, 3600);
        (, usdgIsToken0,,,) = src.pools(address(amd));
        assertFalse(usdgIsToken0, "asset token0");
    }

    function test_admin_setPool_rejects() public {
        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        src.setPool(address(nvda), address(poolA), MIN_LIQ, 300);

        vm.startPrank(admin);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        src.setPool(address(nvda), address(poolB), MIN_LIQ, 300); // TSLA/USDG pool for NVDA
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        src.setPool(address(0), address(poolA), MIN_LIQ, 300);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        src.setPool(address(usdg), address(poolA), MIN_LIQ, 300);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        src.setPool(address(nvda), address(poolA), MIN_LIQ, 59);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        src.setPool(address(nvda), address(poolA), MIN_LIQ, 3601);

        MockERC20 wide = new MockERC20("Wide", "WIDE", 39);
        MockUniV3Pool widePool = new MockUniV3Pool(address(usdg), address(wide), 500);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        src.setPool(address(wide), address(widePool), MIN_LIQ, 300);
        vm.stopPrank();
    }

    /// @dev Sweep contracts-c10. `record(u, E)` needs the pool's observation ring to still hold an observation at or
    ///      before E - 1800 when it is called, which may be as late as E + SNAPSHOT_GRACE. A pool writes at most one
    ///      observation per block timestamp. So anyone who sends one dust in-range mint or burn per second from
    ///      E - 1799 on fills a ring of C slots with later observations by E + (C - 1800). That denied the snapshot
    ///      on the registry pools that held 1800, 1801 or 1860 slots on 2026-09-17, for about 0.01 ETH of gas per
    ///      expiry. setPool now refuses a pool whose current observationCardinality is below
    ///      SETTLEMENT_WINDOW + SNAPSHOT_GRACE + 1 = 2401. A pool's cardinality never shrinks, so a pinned pool
    ///      keeps the depth it was configured with.
    function test_admin_setPool_refusesAnObservationRingShallowerThanTheGrace() public {
        uint16[4] memory shallow = [uint16(1800), 1801, 1860, 2400];
        vm.startPrank(admin);
        for (uint256 i; i < 4; ++i) {
            MockUniV3Pool p = new MockUniV3Pool(address(usdg), address(nvda), 3000);
            p.setObservationCardinality(shallow[i]);
            vm.expectRevert(V2Errors.UnsupportedAsset.selector);
            src.setPool(address(nvda), address(p), MIN_LIQ, 300);
        }
        MockUniV3Pool deep = new MockUniV3Pool(address(usdg), address(nvda), 3000);
        deep.setObservationCardinality(2401);
        src.setPool(address(nvda), address(deep), MIN_LIQ, 300);
        vm.stopPrank();
        (address pool,,,,) = src.pools(address(nvda));
        assertEq(pool, address(deep), "2401 slots: accepted");
    }

    /// @dev The contracts-c10 flood against the shallowest ring setPool accepts. One observation per second from
    ///      E - 1799 through E + 600 (2,400 of them) still leaves the observation at E - 1800 in a 2401-slot ring,
    ///      so the snapshot records at the last second of the grace. With one slot fewer the window's start is gone.
    function test_record_floodedRingOf2401Slots_stillRecordsAtTheEndOfTheGrace() public {
        MockUniV3Pool p = new MockUniV3Pool(address(usdg), address(nvda), 3000);
        p.setObservationCardinality(2401);
        vm.prank(admin);
        src.setPool(address(nvda), address(p), MIN_LIQ, 300);
        p.pushState(E - 1800, 222615, L);
        for (uint40 t = E - 1799; t <= E + 600; ++t) {
            p.pushState(t, 222615, L);
        }
        vm.warp(E + V2Constants.SNAPSHOT_GRACE);

        p.setObservationCardinality(2400); // the mock can shrink; a pool cannot
        (bool ok,,,) = src.observeWindow(address(nvda), E - 1800, E);
        assertFalse(ok, "2400 slots: the observation at E - 1800 is overwritten");
        p.setObservationCardinality(2401);
        assertTrue(src.record(address(nvda), E), "2401 slots: recorded at E + 600");
        (uint256 price,) = _snapshotPrice(address(nvda), E);
        assertApproxEqAbs(price, 214_999_159, 1, "the window's price");
    }

    function test_admin_removePool_keepsSnapshots() public {
        poolA.pushState(T0, 222615, L);
        vm.warp(E);
        assertTrue(src.record(address(nvda), E), "recorded");

        vm.expectEmit(address(src));
        emit PoolSet(address(nvda), address(0), false, 0, 0);
        vm.prank(admin);
        src.setPool(address(nvda), address(0), 1, 1);

        (bool ok,,) = src.latest(address(nvda));
        assertFalse(ok, "latest not ok without a pool");
        vm.warp(E + 60);
        assertFalse(src.record(address(nvda), E + 60), "cannot record without a pool");
        (ok,) = src.windowPrice(address(nvda), E - 1800, E);
        assertTrue(ok, "the stored snapshot is still served");
    }

    /*//////////////////////////////////////////////////////////////
                      PINNING (INTERFACE_VERSION 6)
    //////////////////////////////////////////////////////////////*/

    event OracleSet(address indexed oracle, bool allowed);
    event PoolPinned(address indexed underlying, uint40 indexed expiry, address pool, uint128 minLiquidity);

    address internal oracleAddr = makeAddr("oracle");

    function _pinNvda(uint40 expiry) internal {
        vm.prank(oracleAddr);
        src.pin(address(nvda), expiry);
    }

    function _allowOracle() internal {
        vm.prank(admin);
        src.setOracle(oracleAddr, true);
    }

    /// Only the admin edits the allow-list, only a listed oracle pins, the first pin logs and later ones do not.
    function test_pin_allowListAccessAndIdempotency() public {
        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        src.setOracle(oracleAddr, true);
        vm.prank(oracleAddr);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        src.pin(address(nvda), E);

        vm.expectEmit(address(src));
        emit OracleSet(oracleAddr, true);
        _allowOracle();
        vm.expectEmit(address(src));
        emit PoolPinned(address(nvda), E, address(poolA), MIN_LIQ);
        _pinNvda(E);
        vm.recordLogs();
        _pinNvda(E);
        assertEq(vm.getRecordedLogs().length, 0, "idempotent");
        (address pool, bool usdgIsToken0, uint8 dec, uint32 window, bool pinned, uint128 floor) =
            src.pinnedPools(address(nvda), E);
        assertTrue(pinned, "pinned");
        assertEq(pool, address(poolA), "pool");
        assertTrue(usdgIsToken0, "token order");
        assertEq(dec, 18, "decimals");
        assertEq(window, 300, "window");
        assertEq(floor, MIN_LIQ, "floor");

        vm.prank(admin);
        src.setOracle(oracleAddr, false);
        vm.prank(oracleAddr);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        src.pin(address(nvda), E + 1);
    }

    /// C2-16 finding 1: pointing the underlying at a pool the admin moves cheaply (another fee tier, no floor) after
    /// the pin does not reach the pinned expiry's snapshot; an unpinned expiry records the new pool.
    function test_pin_repointedPool_recordReadsThePinnedPool() public {
        poolA.pushState(T0, 222615, L);
        MockUniV3Pool shallow = new MockUniV3Pool(address(usdg), address(nvda), 3000);
        shallow.pushState(T0, 216407, 1); // 399.99 USDG, 1 L
        _allowOracle();
        _pinNvda(E);
        vm.prank(admin);
        src.setPool(address(nvda), address(shallow), 0, 60);

        vm.warp(E);
        assertTrue(src.record(address(nvda), E), "pinned expiry recorded");
        (uint256 price,) = _snapshotPrice(address(nvda), E);
        assertApproxEqAbs(price, 214_999_159, 1, "from the pinned pool");

        vm.warp(E + 1);
        assertTrue(src.record(address(nvda), E + 1), "unpinned expiry recorded");
        (price,) = _snapshotPrice(address(nvda), E + 1);
        assertGt(price, 399_000_000, "from the new pool");
    }

    /// The pinned floor holds: dropping it to zero after the pin does not let a thin window record for that expiry.
    function test_pin_droppedFloor_doesNotReachThePinnedExpiry() public {
        poolA.pushState(T0, 222615, MIN_LIQ / 2);
        _allowOracle();
        _pinNvda(E);
        vm.prank(admin);
        src.setPool(address(nvda), address(poolA), 0, 300);
        vm.warp(E);
        assertFalse(src.record(address(nvda), E), "pinned floor: too thin");
        vm.warp(E + 1);
        assertTrue(src.record(address(nvda), E + 1), "an unpinned expiry uses the new floor");
    }

    /// Pinning an underlying without a pool fails closed (NoSource) and pins nothing; once a pool is set the pin
    /// succeeds and the expiry records from it.
    function test_pin_noPool_reverts() public {
        address other = address(new MockStockToken("Other", "OTH"));
        _allowOracle();
        vm.prank(oracleAddr);
        vm.expectRevert(V2Errors.NoSource.selector);
        src.pin(other, E);
        (,,,, bool pinned,) = src.pinnedPools(other, E);
        assertFalse(pinned, "nothing pinned");

        MockUniV3Pool otherPool = new MockUniV3Pool(address(usdg), other, 500);
        otherPool.pushState(T0, 222615, L);
        vm.prank(admin);
        src.setPool(other, address(otherPool), MIN_LIQ, 300);
        vm.expectEmit(address(src));
        emit PoolPinned(other, E, address(otherPool), MIN_LIQ);
        vm.prank(oracleAddr);
        assertEq(src.pin(other, E), IPriceSource.pin.selector, "answers the pin selector");
        vm.warp(E);
        assertTrue(src.record(other, E), "records once configured and pinned");
    }

    /// A pin of an expiry already pinned fails closed when the current configuration differs in any field: another
    /// pool (with the other token order), another floor, another window, or no pool. Restoring it confirms again.
    function test_pin_repinOfAChangedConfiguration_reverts() public {
        _allowOracle();
        _pinNvda(E);
        MockUniV3Pool flipped = new MockUniV3Pool(address(nvda), address(usdg), 3000);
        address[4] memory pools_ = [address(flipped), address(poolA), address(poolA), address(0)];
        uint128[4] memory floors = [MIN_LIQ, MIN_LIQ + 1, MIN_LIQ, 0];
        uint32[4] memory windows = [uint32(300), 300, 301, 0];
        for (uint256 i; i < 4; ++i) {
            vm.prank(admin);
            src.setPool(address(nvda), pools_[i], floors[i], windows[i]);
            vm.prank(oracleAddr);
            vm.expectRevert(V2Errors.PinMismatch.selector);
            src.pin(address(nvda), E);
        }
        (address pinnedPool,,,,,) = src.pinnedPools(address(nvda), E);
        assertEq(pinnedPool, address(poolA), "the pinned copy did not move");
        vm.prank(admin);
        src.setPool(address(nvda), address(poolA), MIN_LIQ, 300);
        vm.recordLogs();
        vm.prank(oracleAddr);
        assertEq(src.pin(address(nvda), E), IPriceSource.pin.selector, "equal again: confirmed");
        assertEq(vm.getRecordedLogs().length, 0, "without a log");
    }

    /*//////////////////////////////////////////////////////////////
                                   GAS
    //////////////////////////////////////////////////////////////*/

    function test_gas_record() public {
        poolA.pushState(T0, 222615, L);
        vm.warp(E + 300);
        uint256 gasBefore = gasleft();
        assertTrue(src.record(address(nvda), E), "recorded");
        emit log_named_uint("gas: record (mock pool)", gasBefore - gasleft());
    }

    /*//////////////////////////////////////////////////////////////
                                   FUZZ
    //////////////////////////////////////////////////////////////*/

    /// For any valid tick, neither order reverts, and a USDG-token0 pool at `tick` and an asset-token0 pool at `-tick`
    /// (the same market) agree whenever both are ok: within 1 base unit, or within 1e-15 of the price for prices far
    /// above any share price, where the Q64.96 sqrt ratio's own resolution (squared) is more than a base unit.
    function testFuzz_price_tokenOrderSymmetry(int24 tickRaw) public {
        int24 tick = int24(bound(tickRaw, TickMath.MIN_TICK, TickMath.MAX_TICK));
        MockUniV3Pool a = new MockUniV3Pool(address(usdg), address(nvda), 500);
        MockUniV3Pool b = new MockUniV3Pool(address(tsla), address(usdg), 500);
        a.pushState(T0, tick, L);
        b.pushState(T0, -tick, L);
        vm.startPrank(admin);
        src.setPool(address(nvda), address(a), 0, 300);
        src.setPool(address(tsla), address(b), 0, 300);
        vm.stopPrank();
        vm.warp(E);

        (bool okA, uint256 priceA, int24 tickA,) = src.observeWindow(address(nvda), E - 1800, E);
        (bool okB, uint256 priceB, int24 tickB,) = src.observeWindow(address(tsla), E - 1800, E);
        assertEq(tickA, tick, "mean tick A");
        assertEq(tickB, -tick, "mean tick B");
        if (okA && okB) {
            uint256 diff = priceA > priceB ? priceA - priceB : priceB - priceA;
            uint256 larger = priceA > priceB ? priceA : priceB;
            assertTrue(diff <= 1 || diff * 1e15 <= larger, "orders agree");
        }
        src.latest(address(nvda));
        src.latest(address(tsla));
        src.record(address(nvda), E);
        src.record(address(tsla), E);
    }

    /// Arbitrary cumulatives never make a view revert or `record` revert after expiry.
    function testFuzz_pool_arbitraryCumulatives_neverRevert(int56 t0, int56 t1, uint160 s0, uint160 s1, uint32 ago)
        public
    {
        int56[] memory ticks = new int56[](2);
        uint160[] memory spl = new uint160[](2);
        (ticks[0], ticks[1], spl[0], spl[1]) = (t0, t1, s0, s1);
        poolA.setObserveResult(ticks, spl);
        vm.warp(E);
        uint40 s = uint40(bound(ago, 0, E));
        src.observeWindow(address(nvda), s, E);
        src.observeWindow(address(nvda), E - 1800, E);
        src.latest(address(nvda));
        src.record(address(nvda), E);
    }
}
