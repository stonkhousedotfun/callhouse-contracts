// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {V4PoolKey, V4SwapParams, IV4PoolManager, IV4StateView} from "../BuybackDeps.sol";

/// @notice The canonical INTERFACE_VERSION 8 import path for the Uniswap v4 types the periphery shares
///         (03-INTERFACES §1.4). `PayoutRouter` (`C8-06`) and `V4BuybackExecutor` (`C8-08`) both swap through one
///         pinned pool, and they must use the SAME `PoolKey` type: two structurally identical structs declared in two
///         files would be two Solidity types and two `internalType` strings in the exported ABIs.
/// @dev The declarations themselves live in `../BuybackDeps.sol`, where the `C3-602` fork spike put them and where
///      `V4BuybackExecutor` already reads them; they were checked against the live PoolManager on chain 4663. This
///      file re-exports them under the path 03-INTERFACES names, and adds the currency helpers a second consumer
///      needs. Nothing is duplicated: `V4PoolKey` here and `V4PoolKey` in `BuybackDeps.sol` are the same type.
///
///      `V4PoolKey` is ABI-identical to v4-core's `PoolKey`: v4-core declares `currency0` / `currency1` as the
///      user-defined value type `Currency` and `hooks` as `IHooks`, both `address` underneath, so it encodes to the
///      same five static words and hashes to the same pool id. Native ETH is `address(0)`.
library V4Currency {
    /// @notice Native ETH as a v4 currency.
    address internal constant NATIVE = address(0);

    /// @dev v4-core `TickMath` bounds. A swap given one of these as its `sqrtPriceLimitX96` has no effective price
    ///      limit, which is the only way an exact-input swap is guaranteed to consume the WHOLE input -- what the
    ///      Clearinghouse demands of every conversion.
    uint160 internal constant MIN_SQRT_PRICE = 4_295_128_739;
    uint160 internal constant MAX_SQRT_PRICE = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    /// @notice Sorts two currencies the way v4 does: ascending by address, native ETH first.
    /// @param a One currency.
    /// @param b The other.
    /// @return currency0 The lower address.
    /// @return currency1 The higher address.
    function sort(address a, address b) internal pure returns (address currency0, address currency1) {
        return a < b ? (a, b) : (b, a);
    }

    /// @notice A hookless `PoolKey` over the sorted pair `(a, b)`.
    /// @dev Hooks are deliberately not a parameter: the payout router accepts hookless pools only.
    /// @param a One currency.
    /// @param b The other.
    /// @param fee Static LP fee, hundredths of a bip.
    /// @param tickSpacing Pool tick spacing.
    /// @return key The pinned key.
    function key(address a, address b, uint24 fee, int24 tickSpacing) internal pure returns (V4PoolKey memory) {
        (address currency0, address currency1) = sort(a, b);
        return
            V4PoolKey({
                currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: address(0)
            });
    }

    /// @notice v4's pool id: `keccak256(abi.encode(key))`.
    /// @param k The pool key.
    /// @return The pool id the PoolManager and the StateView lens use.
    function id(V4PoolKey memory k) internal pure returns (bytes32) {
        return keccak256(abi.encode(k));
    }

    /// @notice Whether a swap selling `assetIn` out of `k` goes `zeroForOne`.
    /// @dev Per asset, never assumed: NVDA sorts above USDG on 4663, TSLA below it.
    /// @param k The pool key.
    /// @param assetIn The currency being sold.
    /// @return True when `assetIn` is `currency0`.
    function zeroForOne(V4PoolKey memory k, address assetIn) internal pure returns (bool) {
        return k.currency0 == assetIn;
    }

    /// @notice The `amount0` half of v4-core's packed `BalanceDelta`.
    /// @dev `swap` returns `int256` with `amount0` in the upper 128 bits and `amount1` in the lower, both signed from
    ///      the caller's point of view (negative is owed to the pool). The value already NETS a hook's
    ///      `afterSwapReturnDelta`, so the positive side is what the caller can actually `take`.
    /// @param delta The packed delta.
    /// @return The signed `amount0`.
    function amount0(int256 delta) internal pure returns (int128) {
        return int128(delta >> 128);
    }

    /// @notice The `amount1` half of v4-core's packed `BalanceDelta`.
    /// @param delta The packed delta.
    /// @return The signed `amount1`.
    function amount1(int256 delta) internal pure returns (int128) {
        return int128(int256(delta));
    }
}
