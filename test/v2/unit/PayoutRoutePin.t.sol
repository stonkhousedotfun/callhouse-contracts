// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {V4Currency, V4PoolKey} from "../../../src/v2/periphery/v4/V4Types.sol";

/// @notice THE V4 PAYOUT POOL IDS ARE PINNED CONSTANTS, and this is the assertion that they are right.
/// @dev WHY THIS MUST RUN EVEN UNDER BUILD MODE. `setRouteV4(asset, fee, tickSpacing)` does not take a pool id:
///      the router rebuilds the `PoolKey` from those two numbers and never sees the pin. So a wrong fee or a
///      wrong tickSpacing does not revert and does not mismatch anything on chain -- it silently routes every
///      payout for that market through a DIFFERENT POOL. Nothing downstream says so. That is the same shape as
///      the `take`/`quoteTake` selectors F8-02 froze with its assertions unexecuted, which is why the owner
///      directive's pinned-constant exception exists.
///
///      The rule is MIRRORED, not re-reasoned: `script/v2/RegisterMarkets.s.sol:_requirePinnedPool` builds
///      `V4Currency.key(asset, usdg, fee, tickSpacing)` and takes `V4Currency.id(k)`, which is
///      `keccak256(abi.encode(key))` with the currencies sorted and `hooks` zero (`V4Types.sol:44-57`). This
///      re-derives the same way from the compiled library and the committed fixture -- never from a document
///      and never from the task text.
contract PayoutRoutePinTest is Test {
    /// @dev THE VALUES COME FROM THE FIXTURE VIA THE ENVIRONMENT, which is how production reads them:
    ///      `DeployV2Batch.sh:605-618` exports `V2_MARKET_<T>_PAYOUT_{VENUE,FEE,TICK_SPACING,POOL_ID}` out of
    ///      `markets[].v2.payoutRoute` with `jq`, and `RegisterMarkets._requirePinnedPool` reads
    ///      `V2_MARKET_<T>_PAYOUT_POOL_ID` from the environment rather than from the file. This suite is driven
    ///      the same way -- `script/v2/lib/route-pins.sh` prints them from the committed fixture -- because
    ///      `foundry.toml`'s `fs_permissions` does not grant read access to `script/v2/fixtures/`, and the one
    ///      thing this must NOT do is carry the pinned numbers as literals in its own source. A pin asserted
    ///      against a copy of itself proves nothing.
    function _pin(string memory ticker)
        internal
        view
        returns (address asset, uint24 fee, int24 tickSpacing, bytes32 poolId)
    {
        asset = vm.envAddress(string.concat("V2_MARKET_", ticker, "_ASSET"));
        fee = uint24(vm.envUint(string.concat("V2_MARKET_", ticker, "_PAYOUT_FEE")));
        tickSpacing = int24(vm.envInt(string.concat("V2_MARKET_", ticker, "_PAYOUT_TICK_SPACING")));
        poolId = vm.envBytes32(string.concat("V2_MARKET_", ticker, "_PAYOUT_POOL_ID"));
    }

    function _assertPinned(string memory ticker) internal view {
        address usdg = vm.envAddress("V2_USDG");
        (address asset, uint24 fee, int24 tickSpacing, bytes32 pinned) = _pin(ticker);

        V4PoolKey memory k = V4Currency.key(asset, usdg, fee, tickSpacing);
        bytes32 built = V4Currency.id(k);
        assertEq(
            built,
            pinned,
            string.concat(
                ticker,
                ": setRouteV4(fee, tickSpacing) resolves to a different pool than the pinned poolId -- payouts",
                " would swap through it and nothing on chain would say so"
            )
        );
        // The key itself, not just the hash: a hash that matched with the wrong currency order would be a
        // coincidence worth knowing about.
        assertTrue(k.currency0 < k.currency1, "currencies are sorted");
        assertEq(k.hooks, address(0), "a pinned payout pool is hookless");
    }

    function test_nvdaV4RouteResolvesToItsPinnedPoolId() public view {
        _assertPinned("NVDA");
    }

    function test_tslaV4RouteResolvesToItsPinnedPoolId() public view {
        _assertPinned("TSLA");
    }

    /// @dev The two markets must not share a pool: they are different assets against the same USDG.
    function test_theTwoPinnedPoolsAreDifferent() public view {
        (,,, bytes32 nvda) = _pin("NVDA");
        (,,, bytes32 tsla) = _pin("TSLA");
        assertTrue(nvda != tsla, "NVDA and TSLA pin different pools");
    }
}
