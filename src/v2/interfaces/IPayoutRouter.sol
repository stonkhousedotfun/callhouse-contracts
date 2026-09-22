// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPayoutAdapter} from "./IPayoutAdapter.sol";

/// @title IPayoutRouter
/// @notice The INTERFACE_VERSION 8 payout adapter: one per-asset route to USDG over Uniswap **v3 or a pinned,
///         hookless v4 pool** (03-INTERFACES §2.8, v8 design §6A). It replaces `UniV3PayoutAdapter` and serves both
///         the Clearinghouse's call-payout conversion and the FeeSplitter's fee conversion.
/// @dev {IPayoutAdapter} IS UNCHANGED, which is why the Clearinghouse needs no edit: it still approves exactly
///      `amount`, calls `swapToUsdg`, then demands that exactly `amount` was consumed and that the USDG delta clears
///      a floor it computed itself from the settlement price (or an ok oracle spot above it). The pool is only the
///      execution venue, never the price reference, so a manipulated pool costs a holder nothing: the swap misses the
///      floor and they are paid in kind.
///
///      WHY v4 AT ALL. The 18 of the top-20 markets without a Uniswap v3 pool have deep v4 liquidity. v4 has no
///      on-chain observation array, so it cannot serve as a settlement TWAP source -- but payout does not need one.
///      Settlement corroboration stays Chainlink plus the v3 TWAP; only the route moves.
///
///      A v4 ROUTE IS A PINNED `PoolKey`, NEVER A DISCOVERED ONE. `setRouteV4` stores `(currency0, currency1, fee,
///      tickSpacing, hooks = address(0))` and refuses anything else: a hook is arbitrary code in the swap path and
///      part of the pool's identity, and chain 4663 carries thousands of Stock/USDG pools of which most are junk.
///      Refusals are `V2Errors.RouteRejected(reason)`: the pair is not exactly (asset, USDG) sorted, the pool is not
///      initialised or has no liquidity, the fee carries the dynamic-fee flag, or the fee is above
///      `V2Constants.MAX_ROUTE_FEE_TIER`.
///
///      EXACT INPUT, NO PRICE LIMIT. A v4 exact-input swap WITH a price limit can partially fill, and the
///      Clearinghouse demands the whole `amountIn` be consumed, so the router swaps with the price limit at its
///      extreme (the real guard is `minOut`) and reverts on any leftover. It holds nothing between calls.
///
///      THE ROUTE FEE IS CACHED. The Clearinghouse reads {IPayoutAdapter.routeFeeBps} with a 30,000-gas staticcall
///      and treats anything costlier as 0 (the tighter floor), which a live v4 read could not meet. So the router
///      caches the answer in `Route.feeBps` at `setRouteV3` / `setRouteV4` and exposes a permissionless
///      {refreshRouteFee} that recomputes it (LP fee plus the PoolManager's protocol fee, rounded up).
///
///      BREAKING FOR CONSUMERS: v7's `routes(asset)` answered a different tuple, read POSITIONALLY in the web
///      (`web/lib/v2/conversion.ts`), and `RouteSet(asset, pool, fee)` had three fields and is decoded by the
///      monitor. Both moved; see `status/INTERFACE-CHANGES-V8.md` entry 1.
interface IPayoutRouter is IPayoutAdapter {
    /// @notice Which venue an asset's route uses. `None` is the default: no route, pay in kind.
    enum Venue {
        None,
        V3,
        V4
    }

    /// @notice One asset's route to USDG.
    /// @dev `fee` is hundredths of a bip for BOTH venues (a v3 fee tier, a v4 `PoolKey.fee`). `tickSpacing` and the
    ///      sorted currency pair complete a v4 `PoolKey`, whose `hooks` is always `address(0)` and so is not stored.
    ///      `v3Pool` is the concrete pool for a v3 route and `address(0)` for a v4 one. `feeBps` is the cached answer
    ///      of {IPayoutAdapter.routeFeeBps}, which is what makes that read fit in 30,000 gas.
    struct Route {
        Venue venue;
        uint24 fee; // hundredths of a bip, <= V2Constants.MAX_ROUTE_FEE_TIER
        int24 tickSpacing; // v4 only
        address v3Pool; // v3 only
        uint16 feeBps; // cached routeFeeBps
    }

    /// @notice Routes `asset` to USDG over the Uniswap v3 pool of fee tier `fee`. `CONFIG_ADMIN` (24 h).
    /// @dev The pool is resolved from the v3 factory and must exist. Caches `routeFeeBps` and emits {RouteSet}.
    /// @param asset 18-dp Stock Token.
    /// @param fee v3 fee tier, hundredths of a bip, `<= V2Constants.MAX_ROUTE_FEE_TIER`.
    function setRouteV3(address asset, uint24 fee) external;

    /// @notice Routes `asset` to USDG over the pinned hookless Uniswap v4 pool `(asset, USDG, fee, tickSpacing, 0)`.
    ///         `CONFIG_ADMIN` (24 h).
    /// @dev Hooks are always `address(0)`, so they are not a parameter. Reverts `V2Errors.RouteRejected(reason)`
    ///      unless the pair is exactly (asset, USDG) sorted, the pool is initialised with non-zero liquidity, and the
    ///      fee is static (no dynamic-fee flag) and `<= V2Constants.MAX_ROUTE_FEE_TIER`. Caches `routeFeeBps` and
    ///      emits {RouteSet}.
    /// @param asset 18-dp Stock Token.
    /// @param fee v4 `PoolKey.fee`, hundredths of a bip.
    /// @param tickSpacing v4 `PoolKey.tickSpacing`.
    function setRouteV4(address asset, uint24 fee, int24 tickSpacing) external;

    /// @notice Removes `asset`'s route, so every conversion of it falls back to paying in kind. `GUARDIAN`, instant.
    /// @dev Its own selector precisely so the guardian can pull a bad venue with no delay while route CHANGES wait
    ///      out `CONFIG_ADMIN`'s 24 h.
    /// @param asset 18-dp Stock Token.
    function clearRoute(address asset) external;

    /// @notice Recomputes and re-caches `asset`'s `routeFeeBps`. Anyone.
    /// @dev Needed because a v4 pool's PoolManager protocol fee can be changed by its controller after the route was
    ///      set, and the Clearinghouse's 30,000-gas read cannot recompute it live.
    /// @param asset 18-dp Stock Token with a route.
    function refreshRouteFee(address asset) external;

    /// @notice The stored route of `asset`; `venue == None` when it has none.
    /// @param asset 18-dp Stock Token.
    /// @return The route.
    function routes(address asset) external view returns (Route memory);

    /// @notice A route was set. `venue` is the {Venue} as `uint8`; `poolId` is `keccak256(abi.encode(key))` for v4 and
    ///         the pool address left-padded for v3; `feeBps` is the cached {IPayoutAdapter.routeFeeBps}.
    event RouteSet(address indexed asset, uint8 venue, bytes32 poolId, uint24 fee, uint16 feeBps);
    /// @notice The guardian removed `asset`'s route; conversions of it pay in kind until a new one is set.
    event RouteCleared(address indexed asset);
}
