// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "../../../src/v2/oracle/lib/TickMath.sol";
import {TickMathUpstream} from "../fixtures/TickMathUpstream.sol";

contract TickMathHarness {
    function sqrtRatio(int24 tick) external pure returns (uint160) {
        return TickMath.getSqrtRatioAtTick(tick);
    }

    function upstreamSqrtRatio(int24 tick) external pure returns (uint160) {
        return TickMathUpstream.getSqrtRatioAtTick(tick);
    }

    /// @dev T-OP-089. Both conversions over every tick in [from, to], inside one call so the library calls are
    ///      internal jumps and the sweep fits a test. `upstreamMinusRewrite` is what every difference is expected to
    ///      be: the rewrite rounds three factors UP, which after the 2^256 / ratio inversion for a positive tick can
    ///      only LOWER the result. `rewriteAbove` counts the opposite sign; `outsideMask` counts a differing tick
    ///      with none of bits 12, 17 and 19 set -- the three factors that differ (see the test). Both must be zero.
    function sweep(int24 from, int24 to)
        external
        pure
        returns (uint256 count, uint256 sumAbs, uint256 maxAbs, uint256 rewriteAbove, uint256 outsideMask)
    {
        uint256 mask = (1 << 12) | (1 << 17) | (1 << 19);
        for (int256 t = from; t <= to; ++t) {
            int24 tick = int24(t);
            // The rewrite allocates its `uint256[20] memory` factor table on every call and, as an internal call in a
            // loop, never gives it back: 221,819 iterations would grow memory by ~140 MB and the quadratic expansion
            // cost runs the 9 Ggas test limit out (measured: every chunk reverted at 8.86 Ggas). Nothing below keeps a
            // memory reference across iterations, so the free-memory pointer is rewound after each pair of calls.
            uint256 fmp;
            assembly ("memory-safe") {
                fmp := mload(0x40)
            }
            uint256 u = TickMathUpstream.getSqrtRatioAtTick(tick);
            uint256 r = TickMath.getSqrtRatioAtTick(tick);
            assembly ("memory-safe") {
                mstore(0x40, fmp)
            }
            if (u == r) continue;
            ++count;
            uint256 d;
            if (r > u) {
                ++rewriteAbove;
                d = r - u;
            } else {
                d = u - r;
            }
            sumAbs += d;
            if (d > maxAbs) maxAbs = d;
            uint256 magnitude = uint256(t < 0 ? -t : t);
            if (magnitude & mask == 0) ++outsideMask;
        }
    }
}

contract TickMathTest is Test {
    TickMathHarness internal math = new TickMathHarness();

    function test_knownTickPrices() public view {
        assertEq(math.sqrtRatio(TickMath.MIN_TICK), 4295128739);
        assertEq(math.sqrtRatio(-1), 79224201403219477170569942574);
        assertEq(math.sqrtRatio(0), 79228162514264337593543950336);
        assertEq(math.sqrtRatio(1), 79232123823359799118286999568);
        assertEq(math.sqrtRatio(TickMath.MAX_TICK), 1461446703485210103287273052203988822378723970342);
    }

    function test_outsideTickRangeReverts() public {
        vm.expectRevert(TickMath.TickOutOfRange.selector);
        math.sqrtRatio(TickMath.MIN_TICK - 1);
        vm.expectRevert(TickMath.TickOutOfRange.selector);
        math.sqrtRatio(TickMath.MAX_TICK + 1);
    }

    function testFuzz_adjacentTicksAreStrictlyIncreasing(int24 rawTick) public view {
        int24 tick = int24(bound(rawTick, TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        assertLt(math.sqrtRatio(tick), math.sqrtRatio(tick + 1));
    }
}

/// @notice T-OP-089. The rewrite (src/v2/oracle/lib/TickMath.sol) held against Uniswap v3-core's TickMath at commit
///         6562c52e, vendored byte-identically as test/v2/fixtures/TickMathUpstream.sol. The two differ in exactly
///         three of the twenty Q128 factors -- bits 12, 17 and 19 -- each +1 ulp in the rewrite (T-OP-076,
///         re-derived here by reading both tables: 0x...aa5825/0x...aa5826, 0x...ee604/0x...ee605,
///         0x...e8fa2/0x...e8fa3). THESE TESTS PIN WHAT THAT DOES TO THE PRICE, over every tick, so a change to
///         either table or to the rounding goes red by number rather than by story.
///
///         MEASURED (Python mirror of both algorithms over all 1,774,545 ticks, then this suite): for every
///         NEGATIVE tick and for 0 the two agree exactly -- a +1 in a Q128 factor moves the Q128 ratio by at most
///         1 and the final `>> 32` hides it unless a 2^32 boundary is crossed, which happens nowhere in the range.
///         For POSITIVE ticks the inversion `2^256 / ratio` at :63 turns that +1 into a relative error that grows
///         with the price: 20,325 ticks differ, ALWAYS rewrite < upstream, first at tick 132822 (by 1), first by
///         more than 1 at tick 222679 (by 2), the largest absolute difference 85,392,153,667,293,937,560,935 at
///         tick 749860 -- a RELATIVE 5.63e-23 of that sqrt price, the worst over the whole range. Every differing
///         tick has bit 12, 17 or 19 set. The endpoints agree. T-OP-076's ledger bound "at most +1 in
///         sqrtPriceX96" is therefore true of the negative half only; the positive half is bounded in RELATIVE
///         terms (below 2^-64, measured 5.63e-23) and not in absolute ones. It is still not a finding: 1e-22 of
///         a price is far below any tick, any fee and any band in this repo.
///
///         THE SWEEP IS SPLIT INTO EIGHT EQUAL CHUNKS of 221,819 ticks so each stays inside the test gas limit and
///         the eight run in parallel; together they cover every tick exactly once. Each chunk pins its own count,
///         sum and maximum of |upstream - rewrite|, and that no tick differs in the other direction or outside the
///         three-bit mask. The expected numbers were computed by the off-chain mirror first and confirmed by the
///         chain sweep, so a mirror that had mis-modelled either algorithm would have shown here as a mismatch.
contract TickMathUpstreamDiffTest is Test {
    TickMathHarness internal math = new TickMathHarness();

    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;
    int24 internal constant CHUNK = 221819; // ceil(1,774,545 / 8)

    /// @dev Chunk `c` of eight: [MIN_TICK + c x CHUNK, min(MAX_TICK, MIN_TICK + (c + 1) x CHUNK - 1)].
    function _chunk(uint256 c) internal pure returns (int24 from, int24 to) {
        int256 a = int256(MIN_TICK) + int256(c) * int256(CHUNK);
        int256 b = a + int256(CHUNK) - 1;
        if (b > int256(MAX_TICK)) b = int256(MAX_TICK);
        return (int24(a), int24(b));
    }

    function _pin(uint256 c, uint256 count, uint256 sumAbs, uint256 maxAbs) internal view {
        (int24 from, int24 to) = _chunk(c);
        (uint256 n, uint256 s, uint256 m, uint256 above, uint256 outside) = math.sweep(from, to);
        assertEq(n, count, "count of differing ticks");
        assertEq(s, sumAbs, "sum of |upstream - rewrite|");
        assertEq(m, maxAbs, "largest |upstream - rewrite|");
        assertEq(above, 0, "a tick where the rewrite is ABOVE upstream: the rounding direction changed");
        assertEq(outside, 0, "a differing tick with none of bits 12, 17, 19 set: a fourth factor changed");
    }

    /// The eight chunks tile the range exactly once: the first starts at MIN_TICK, the last ends at MAX_TICK, and
    /// each begins where the previous one ended.
    function test_chunksTileTheWholeRange() public pure {
        (int24 from0,) = _chunk(0);
        assertEq(from0, MIN_TICK, "first chunk starts at MIN_TICK");
        for (uint256 c = 1; c < 8; ++c) {
            (, int24 prevTo) = _chunk(c - 1);
            (int24 from,) = _chunk(c);
            assertEq(int256(from), int256(prevTo) + 1, "a gap or an overlap between chunks");
        }
        (, int24 to7) = _chunk(7);
        assertEq(to7, MAX_TICK, "last chunk ends at MAX_TICK");
    }

    // NEGATIVE HALF AND ZERO: identical, every tick.
    function test_diff_chunk0_negativeTicks_identical() public view {
        _pin(0, 0, 0, 0);
    }

    function test_diff_chunk1_negativeTicks_identical() public view {
        _pin(1, 0, 0, 0);
    }

    function test_diff_chunk2_negativeTicks_identical() public view {
        _pin(2, 0, 0, 0);
    }

    function test_diff_chunk3_negativeTicksAndZero_identical() public view {
        _pin(3, 0, 0, 0); // [-221815, 3]
    }

    // POSITIVE HALF: the +1-ulp factors survive the inversion; rewrite < upstream, bounded as pinned.
    function test_diff_chunk4_positiveTicks_206ticksOffByOne() public view {
        _pin(4, 206, 206, 1); // [4, 221822]
    }

    function test_diff_chunk5_positiveTicks_187ticksUpTo55() public view {
        _pin(5, 187, 1314, 55); // [221823, 443641]
    }

    function test_diff_chunk6_positiveTicks_19912ticks() public view {
        _pin(6, 19912, 402400256811473711644, 18087705981032512113); // [443642, 665460]
    }

    function test_diff_chunk7_positiveTicks_20ticks_worstCase() public view {
        _pin(7, 20, 89671554098324724388887, 85392153667293937560935); // [665461, 887272]
    }

    /// Named ticks, pinned exactly: the single-bit tick for each differing factor (only bit 19 shows after the
    /// inversion; bits 12 and 17 alone stay under a 2^32 boundary), the first differing tick, the first that
    /// differs by more than one, and the worst case. The negative single-bit ticks agree, as the whole half does.
    function test_diff_namedTicks() public view {
        assertEq(math.upstreamSqrtRatio(4096) - math.sqrtRatio(4096), 0, "bit 12 alone, positive");
        assertEq(math.upstreamSqrtRatio(131072) - math.sqrtRatio(131072), 0, "bit 17 alone, positive");
        assertEq(math.upstreamSqrtRatio(524288) - math.sqrtRatio(524288), 13659671983082, "bit 19 alone, positive");
        assertEq(math.upstreamSqrtRatio(-4096), math.sqrtRatio(-4096), "bit 12 alone, negative");
        assertEq(math.upstreamSqrtRatio(-131072), math.sqrtRatio(-131072), "bit 17 alone, negative");
        assertEq(math.upstreamSqrtRatio(-524288), math.sqrtRatio(-524288), "bit 19 alone, negative");
        assertEq(math.upstreamSqrtRatio(132822) - math.sqrtRatio(132822), 1, "first differing tick");
        assertEq(math.upstreamSqrtRatio(222679) - math.sqrtRatio(222679), 2, "first tick off by more than one");
        assertEq(
            math.upstreamSqrtRatio(749860) - math.sqrtRatio(749860),
            85392153667293937560935,
            "the worst case, 5.63e-23 of the sqrt price"
        );
        assertEq(math.upstreamSqrtRatio(MAX_TICK), math.sqrtRatio(MAX_TICK), "MAX_TICK agrees");
        assertEq(math.upstreamSqrtRatio(MIN_TICK), math.sqrtRatio(MIN_TICK), "MIN_TICK agrees");
    }
}
