// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Converts a 1.0001-spaced integer tick to a Q64.96 square-root price.
/// @dev Only the forward conversion is needed by UniV3TwapSource. The factors are fixed-point
///      evaluations of (10000 / 10001)^(2^i / 2), scaled by 2^128. The first is rounded down
///      and the others up; this preserves the established pool tick-price rounding, including
///      its endpoint values. Multiplication truncates after each selected binary factor.
library TickMath {
    error TickOutOfRange();

    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;

    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        int256 signedTick = int256(tick);
        uint256 magnitude = uint256(signedTick < 0 ? -signedTick : signedTick);
        if (magnitude > uint256(int256(MAX_TICK))) revert TickOutOfRange();

        uint256[20] memory factors = [
            uint256(0xfffcb933bd6fad37aa2d162d1a594001),
            0xfff97272373d413259a46990580e213a,
            0xfff2e50f5f656932ef12357cf3c7fdcc,
            0xffe5caca7e10e4e61c3624eaa0941cd0,
            0xffcb9843d60f6159c9db58835c926644,
            0xff973b41fa98c081472e6896dfb254c0,
            0xff2ea16466c96a3843ec78b326b52861,
            0xfe5dee046a99a2a811c461f1969c3053,
            0xfcbe86c7900a88aedcffc83b479aa3a4,
            0xf987a7253ac413176f2b074cf7815e54,
            0xf3392b0822b70005940c7a398e4b70f3,
            0xe7159475a2c29b7443b29c7fa6e889d9,
            0xd097f3bdfd2022b8845ad8f792aa5826,
            0xa9f746462d870fdf8a65dc1f90e061e5,
            0x70d869a156d2a1b890bb3df62baf32f7,
            0x31be135f97d08fd981231505542fcfa6,
            0x9aa508b5b7a84e1c677de54f3e99bc9,
            0x5d6af8dedb81196699c329225ee605,
            0x2216e584f5fa1ea926041bedfe98,
            0x48a170391f7dc42444e8fa3
        ];

        uint256 ratio = 1 << 128;
        uint256 bit;
        unchecked {
            while (magnitude != 0) {
                if (magnitude & 1 != 0) ratio = (ratio * factors[bit]) >> 128;
                magnitude >>= 1;
                ++bit;
            }

            if (tick > 0) ratio = type(uint256).max / ratio;
            // Round up when reducing Q128.128 to Q64.96.
            sqrtPriceX96 = uint160((ratio + ((1 << 32) - 1)) >> 32);
        }
    }
}
