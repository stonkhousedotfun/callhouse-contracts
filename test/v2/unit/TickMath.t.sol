// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "../../../src/v2/oracle/lib/TickMath.sol";

contract TickMathHarness {
    function sqrtRatio(int24 tick) external pure returns (uint160) {
        return TickMath.getSqrtRatioAtTick(tick);
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
