// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Managed} from "../access/Managed.sol";
import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {V2Constants} from "../interfaces/V2Constants.sol";
import {V2Errors} from "../interfaces/V2Errors.sol";
import {IUniswapV3PoolOracle} from "./OracleDeps.sol";
import {PriceLib} from "./lib/PriceLib.sol";
import {TickMath} from "./lib/TickMath.sol";
import {FullMath} from "./lib/FullMath.sol";

/// @title UniV3TwapSource
/// @notice Settlement source 2 (ADR-05): the Uniswap v3 USDG pool's time-weighted price over the settlement window,
///         snapshotted by a keeper just after expiry and gated by a harmonic-mean liquidity floor.
/// @dev UNITS. Prices are USDG base units (6 dp) per whole share (ADR-04); liquidity is the pool's own L units; times
///      are unix seconds.
///
///      WHY A SNAPSHOT. `pool.observe` answers relative to the current block and the pool's observation buffer is a
///      ring that gets overwritten, so the price of a past window is only readable for a while. {record} stores it
///      once, inside `[expiry, expiry + SNAPSHOT_GRACE]`, and {windowPrice} serves the stored value forever.
///
///      THE WINDOW IS [expiry - SETTLEMENT_WINDOW, expiry], NOT "THE LAST 30 MINUTES BEFORE THE CALL". {record} asks the
///      pool for `observe([now - expiry + 1800, now - expiry])`. The cumulatives at a past instant are fixed history,
///      so the snapshot is the same whenever inside the grace the keeper calls: trades after expiry never enter it,
///      the keeper cannot pick a better moment, and the window is exactly the one ChainlinkFeedSource averages, so
///      the oracle's corroboration compares like with like. (Architecture §3.3 says "the SETTLEMENT_WINDOW seconds
///      before now"; this is that window pinned to expiry, at the cost of the pool's buffer having to reach up to
///      SNAPSHOT_GRACE further back. NVDA's pool keeps 6,000 observations, about 68 h of history as of R13.)
///
///      THE RING MUST OUTLAST THE GRACE (sweep contracts-c10). A pool writes at most one observation per block
///      timestamp, and anyone can make it write one every second with a dust in-range mint or burn. A ring of C slots
///      flooded that way from `expiry - SETTLEMENT_WINDOW + 1` no longer holds the window's start from
///      `expiry + C - SETTLEMENT_WINDOW` on, and {record} fails until the grace ends. So {setPool} refuses a pool
///      whose current `observationCardinality` is below V2Constants.MIN_POOL_OBSERVATION_CARDINALITY (2,401): such
///      a ring still holds the window's start at `expiry + SNAPSHOT_GRACE` however it is flooded, and a pool's
///      cardinality never shrinks, so a pinned pool keeps that depth. (The registry pools held 1,800 to 1,860 slots on
///      2026-09-17, except NVDA's 6,000 and SPCX's 3,100; `increaseObservationCardinalityNext` raises them. Owner
///      sign-off c10, DECISIONS-2026-09-17 §7: every other launch market is registered Chainlink-only instead, and the
///      deploy and register preflights and VerifyV2 refuse a shallower registry pool before anything is broadcast.)
///
///      PRICE. The arithmetic-mean tick over the window (floored toward negative infinity, as v3-periphery's
///      OracleLibrary.consult) is converted with OracleLibrary.getQuoteAtTick's arithmetic: `1.0001^tick` is token1
///      base units per token0 base unit, so with USDG as token0 a whole share (10^decimals base units of the asset)
///      costs `10^decimals * 2^192 / sqrtRatioX96^2` USDG base units, and with the asset as token0 it costs
///      `10^decimals * sqrtRatioX96^2 / 2^192`. {_quote} evaluates both with FullMath so no precision is lost to an
///      intermediate overflow, and it cannot revert for any valid tick with decimals <= 38.
///
///      LIQUIDITY FLOOR. The time-weighted harmonic mean of in-range liquidity over the window,
///      `seconds << 128 / delta(secondsPerLiquidityCumulativeX128)`, must be at least the market's `minLiquidity`. The
///      harmonic mean is dominated by the thinnest stretch of the window, which is the stretch a manipulator would use.
///
///      PINNING (INTERFACE_VERSION 6). {pin}, called by a registered oracle ({setOracle}) when the first series of an
///      expiry is created, copies the underlying's PoolConfig for that expiry, and {record} of a pinned expiry reads the
///      pinned pool with the pinned liquidity floor. {setPool} therefore cannot point a live series at a shallow pool
///      or drop its floor. {pin} fails closed: it refuses an underlying without a pool (V2Errors.NoSource), and a pin
///      of an expiry pinned before (through another allowed oracle) only confirms a copy equal to the current
///      configuration (V2Errors.PinMismatch otherwise). {windowPrice} serves the stored snapshot, which was recorded
///      with the pinned configuration; {latest} and {observeWindow} read the current configuration.
///
///      NEVER REVERTS FROM {latest} OR {windowPrice}. The pool is read with a raw `staticcall` and its reply decoded by
///      hand ({_parseObserve}), because `abi.decode` of a malformed reply reverts in the caller where try/catch cannot
///      catch it. {record} returns false instead of storing when the window cannot be priced.
contract UniV3TwapSource is IPriceSource, Managed, ReentrancyGuardTransient {
    /// @notice Per-underlying pool configuration (CONFIG_ADMIN in the v8 AccessManager, 24 h execution delay).
    struct PoolConfig {
        /// @dev Uniswap v3 pool of USDG and the underlying. Zero: unconfigured.
        address pool;
        /// @dev Whether USDG is the pool's token0 (read from the pool at configuration, never assumed).
        bool usdgIsToken0;
        /// @dev The underlying's decimals (18 for every Stock Token; read at configuration).
        uint8 assetDecimals;
        /// @dev Seconds. Length of the TWAP {latest} reports.
        uint32 window;
        /// @dev Harmonic-mean in-range liquidity floor over any priced window, pool L units.
        uint128 minLiquidity;
    }

    /// @notice A PoolConfig pinned for one expiry ({pin}). Two slots, like PoolConfig.
    struct PinnedPool {
        /// @dev As PoolConfig.pool at the pin; never zero ({pin} refuses an underlying without a pool).
        address pool;
        bool usdgIsToken0;
        uint8 assetDecimals;
        /// @dev Seconds (informational: only {latest} uses a window, and it reads the current configuration).
        uint32 window;
        /// @dev True once pinned (whatever the configuration was).
        bool pinned;
        /// @dev Pool L units.
        uint128 minLiquidity;
    }

    /// @notice What {record} stored for (underlying, expiry). One slot.
    struct Snapshot {
        /// @dev USDG base units (6 dp) per whole share. Zero: nothing recorded.
        uint128 price;
        /// @dev Arithmetic-mean tick of the window, for audit.
        int24 meanTick;
        /// @dev Unix seconds of the {record} call.
        uint40 recordedAt;
    }

    /// @notice Recommended `window` for {latest}, seconds (architecture §3.3: a 5-minute TWAP).
    uint32 public constant DEFAULT_WINDOW = 300;
    /// @notice Bounds of `window`, seconds.
    uint32 public constant MIN_WINDOW = 60;
    uint32 public constant MAX_WINDOW = 1 hours;
    /// @notice Largest underlying decimals a pool can be configured for: 10^38 < 2^128 keeps {_quote} exact and
    ///         revert-free at every tick.
    uint8 public constant MAX_ASSET_DECIMALS = 38;

    /// @notice USDG (6 dp), the quote token every configured pool must hold.
    address public immutable usdg;

    /// @notice Pool configuration per underlying.
    mapping(address underlying => PoolConfig) public pools;
    /// @notice Stored snapshots per underlying and expiry.
    mapping(address underlying => mapping(uint40 expiry => Snapshot)) public snapshots;
    /// @notice Oracles allowed to call {pin} ({setOracle}).
    mapping(address oracle => bool) public isOracle;
    /// @notice The configuration pinned per underlying and expiry ({pin}); `pinned` false: not pinned.
    mapping(address underlying => mapping(uint40 expiry => PinnedPool)) public pinnedPools;

    /// @notice The pool configuration of `underlying` changed. `pool == address(0)`: removed.
    event PoolSet(
        address indexed underlying, address indexed pool, bool usdgIsToken0, uint128 minLiquidity, uint32 window
    );
    /// @notice CONFIG_ADMIN allowed or disallowed `oracle` to call {pin}.
    event OracleSet(address indexed oracle, bool allowed);
    /// @notice {pin} fixed the pool {record} reads for `expiry`: `pool` and its harmonic-mean liquidity floor
    ///         `minLiquidity`, pool L units.
    event PoolPinned(address indexed underlying, uint40 indexed expiry, address pool, uint128 minLiquidity);
    /// @notice {record} stored the window price of (underlying, expiry). `price` is USDG 6 dp per share,
    ///         `harmonicMeanLiquidity` in pool L units.
    event Recorded(
        address indexed underlying, uint40 indexed expiry, uint256 price, int24 meanTick, uint256 harmonicMeanLiquidity
    );

    /// @param authority The `AccessManager` mapping this contract's selectors to roles (V8Roles).
    /// @param usdg_ USDG token address.
    constructor(address authority, address usdg_) Managed(authority) {
        if (usdg_ == address(0)) revert V2Errors.UnsupportedAsset();
        usdg = usdg_;
    }

    /*//////////////////////////////////////////////////////////////
                                  ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets or removes the pool of `underlying`.
    /// @dev CONFIG_ADMIN only (V2Errors.NotAuthorized). `pool == address(0)` removes the configuration (the other
    ///      arguments are ignored); snapshots already recorded stay. Reverts V2Errors.UnsupportedAsset when the
    ///      underlying is zero or USDG, when the pool's {token0, token1} is not {USDG, underlying} in either order,
    ///      when the pool's `slot0().observationCardinality` is below V2Constants.MIN_POOL_OBSERVATION_CARDINALITY (2,401: a
    ///      shallower ring can be flooded past a snapshot's window inside the grace, see the contract NatSpec), or
    ///      when the underlying has more than MAX_ASSET_DECIMALS decimals; V2Errors.CeilingExceeded when `window` is
    ///      outside [MIN_WINDOW, MAX_WINDOW] or when `minLiquidity` is 0. THE FLOOR IS THE GUARD (SEC-09): a zero
    ///      floor turns off the harmonic-mean liquidity check in {_observeWindow}, so a manipulator's thin window
    ///      would price a settlement; RegisterMarkets.s.sol refuses 0 in the script, and this refusal is the same
    ///      rule inside the contract, so a later CONFIG_ADMIN call cannot disarm it either. No default is
    ///      substituted -- the operator's value is refused, not repaired. The registry's `univ3MinLiquidity` is the
    ///      intended value. Applies to {latest} and to every expiry not pinned; pinned expiries keep their
    ///      {pinnedPools} entry.
    /// @param underlying 18-dp Stock Token.
    /// @param pool Uniswap v3 pool of USDG and `underlying`, or zero to remove.
    /// @param minLiquidity Harmonic-mean liquidity floor, pool L units.
    /// @param window {latest} TWAP length, seconds; DEFAULT_WINDOW unless the market needs otherwise.
    function setPool(address underlying, address pool, uint128 minLiquidity, uint32 window)
        external
        nonReentrant
        restricted
    {
        if (underlying == address(0) || underlying == usdg) revert V2Errors.UnsupportedAsset();
        if (pool == address(0)) {
            delete pools[underlying];
            emit PoolSet(underlying, address(0), false, 0, 0);
            return;
        }
        if (window < MIN_WINDOW || window > MAX_WINDOW) revert V2Errors.CeilingExceeded();
        if (minLiquidity == 0) revert V2Errors.CeilingExceeded();
        address t0 = IUniswapV3PoolOracle(pool).token0();
        address t1 = IUniswapV3PoolOracle(pool).token1();
        bool usdgIsToken0;
        if (t0 == usdg && t1 == underlying) usdgIsToken0 = true;
        else if (t0 != underlying || t1 != usdg) revert V2Errors.UnsupportedAsset();
        (,,, uint16 cardinality,,,) = IUniswapV3PoolOracle(pool).slot0();
        if (cardinality < V2Constants.MIN_POOL_OBSERVATION_CARDINALITY) revert V2Errors.UnsupportedAsset();
        uint8 dec = IERC20Metadata(underlying).decimals();
        if (dec > MAX_ASSET_DECIMALS) revert V2Errors.UnsupportedAsset();
        pools[underlying] = PoolConfig({
            pool: pool, usdgIsToken0: usdgIsToken0, assetDecimals: dec, window: window, minLiquidity: minLiquidity
        });
        emit PoolSet(underlying, pool, usdgIsToken0, minLiquidity, window);
    }

    /// @notice Allows or disallows `oracle` to call {pin}.
    /// @dev CONFIG_ADMIN only (V2Errors.NotAuthorized). An allow-list for the reason ChainlinkFeedSource.setOracle
    ///      gives: two SettlementOracles may share this source while a market migrates.
    /// @param oracle SettlementOracle.
    /// @param allowed True to allow.
    function setOracle(address oracle, bool allowed) external nonReentrant restricted {
        isOracle[oracle] = allowed;
        emit OracleSet(oracle, allowed);
    }

    /*//////////////////////////////////////////////////////////////
                               IPriceSource
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPriceSource
    /// @dev The TWAP over the last `window` seconds, with the liquidity floor applied. `updatedAt` is now: the TWAP
    ///      ends at this block.
    function latest(address underlying) external view returns (bool ok, uint256 price, uint256 updatedAt) {
        PoolConfig memory cfg = pools[underlying];
        if (cfg.pool == address(0) || block.timestamp <= cfg.window) return (false, 0, 0);
        (ok, price,,) = _observeWindow(cfg, block.timestamp - cfg.window, block.timestamp);
        if (!ok) return (false, 0, 0);
        return (true, price, block.timestamp);
    }

    /// @inheritdoc IPriceSource
    /// @dev The snapshot {record} stored for `(underlying, end)`. Not ok when nothing was stored, or when
    ///      `end - start != SETTLEMENT_WINDOW`: the snapshot covers exactly that window and is no answer for another.
    function windowPrice(address underlying, uint40 start, uint40 end) external view returns (bool ok, uint256 price) {
        Snapshot memory s = snapshots[underlying][end];
        if (s.price == 0 || uint256(start) + V2Constants.SETTLEMENT_WINDOW != end) return (false, 0);
        return (true, s.price);
    }

    /// @inheritdoc IPriceSource
    /// @dev Anyone. Reverts V2Errors.TooEarly(expiry) before `expiry`. Returns false, storing nothing, after
    ///      `expiry + SNAPSHOT_GRACE` (rather than reverting, so SettlementOracle.snapshot and keeper loops that call
    ///      every source late keep going), when `underlying` has no pool, when a snapshot already exists, and when the
    ///      window cannot be priced (observe fails or its buffer does not reach `expiry - SETTLEMENT_WINDOW`, mean tick
    ///      out of range, price 0 or above 2^128, liquidity below the floor). A failed attempt may be retried inside
    ///      the grace; the window is fixed history, so a retry only succeeds if the failure was not about the window.
    ///      "The pool" and "the floor" are the ones pinned for `expiry` when {pin} pinned it, else the current ones.
    function record(address underlying, uint40 expiry) external nonReentrant returns (bool recorded) {
        if (block.timestamp < expiry) revert V2Errors.TooEarly(expiry);
        if (block.timestamp > uint256(expiry) + V2Constants.SNAPSHOT_GRACE) return false;
        PoolConfig memory cfg = _configFor(underlying, expiry);
        if (cfg.pool == address(0) || snapshots[underlying][expiry].price != 0) return false;
        if (expiry <= V2Constants.SETTLEMENT_WINDOW) return false;

        // The only interaction is a STATICCALL to the pool, which cannot re-enter a state-changing path; the effects
        // follow it because they are its result.
        (bool ok, uint256 price, int24 meanTick, uint256 harmonicLiquidity) =
            _observeWindow(cfg, uint256(expiry) - V2Constants.SETTLEMENT_WINDOW, expiry);
        if (!ok) return false;

        // casting to 'uint128' is safe because _observeWindow reports ok only for price <= PriceLib.MAX_PRICE
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 storedPrice = uint128(price);
        snapshots[underlying][expiry] =
            Snapshot({price: storedPrice, meanTick: meanTick, recordedAt: uint40(block.timestamp)});
        emit Recorded(underlying, expiry, price, meanTick, harmonicLiquidity);
        return true;
    }

    /// @inheritdoc IPriceSource
    /// @dev Only an oracle on the allow-list (V2Errors.NotAuthorized). An expiry already pinned: returns without a log
    ///      when {pinnedPools} equals `pools[underlying]` (pool, token order, decimals, window and floor), else reverts
    ///      V2Errors.PinMismatch. Otherwise reverts V2Errors.NoSource when the underlying has no pool, or copies
    ///      `pools[underlying]` into {pinnedPools} and emits {PoolPinned}.
    function pin(address underlying, uint40 expiry) external nonReentrant returns (bytes4) {
        if (!isOracle[msg.sender]) revert V2Errors.NotAuthorized();
        PoolConfig memory cfg = pools[underlying];
        PinnedPool storage p = pinnedPools[underlying][expiry];
        if (p.pinned) {
            if (
                p.pool != cfg.pool || p.usdgIsToken0 != cfg.usdgIsToken0 || p.assetDecimals != cfg.assetDecimals
                    || p.window != cfg.window || p.minLiquidity != cfg.minLiquidity
            ) revert V2Errors.PinMismatch();
            return IPriceSource.pin.selector;
        }
        if (cfg.pool == address(0)) revert V2Errors.NoSource();
        (p.pool, p.usdgIsToken0, p.assetDecimals, p.window, p.pinned) =
        (cfg.pool, cfg.usdgIsToken0, cfg.assetDecimals, cfg.window, true);
        if (cfg.minLiquidity != 0) p.minLiquidity = cfg.minLiquidity;
        emit PoolPinned(underlying, expiry, cfg.pool, cfg.minLiquidity);
        return IPriceSource.pin.selector;
    }

    /*//////////////////////////////////////////////////////////////
                                   VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice What the pool reports for `[start, end]` right now, as {record} would store it.
    /// @dev Anyone. Never reverts. For keepers and ops: {record} is this with `[expiry - SETTLEMENT_WINDOW, expiry]`
    ///      plus storage, and it shows a failed snapshot's reason (`meanTick` and `harmonicLiquidity` are reported
    ///      whenever the pool answered, even when ok is false). Any window still inside the pool's observation buffer
    ///      can be read, which is how the fork test prices a past session window without an archive node. Reads the
    ///      CURRENT pool configuration; for a pinned expiry {record} reads {pinnedPools}.
    /// @param underlying 18-dp Stock Token.
    /// @param start Window start, unix seconds.
    /// @param end Window end, unix seconds; at most now.
    /// @return ok True when the pool answered, the tick is in range, the price is in (0, 2^128] and the harmonic-mean
    ///         liquidity is at least the floor.
    /// @return price USDG base units (6 dp) per whole share; 0 when not ok.
    /// @return meanTick Arithmetic-mean tick over the window, floored.
    /// @return harmonicLiquidity Time-weighted harmonic-mean in-range liquidity, pool L units.
    function observeWindow(address underlying, uint40 start, uint40 end)
        external
        view
        returns (bool ok, uint256 price, int24 meanTick, uint256 harmonicLiquidity)
    {
        PoolConfig memory cfg = pools[underlying];
        if (cfg.pool == address(0)) return (false, 0, 0, 0);
        return _observeWindow(cfg, start, end);
    }

    /*//////////////////////////////////////////////////////////////
                                 INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev The configuration {record} of `expiry` uses: the pinned copy when there is one, else the current.
    function _configFor(address underlying, uint40 expiry) private view returns (PoolConfig memory cfg) {
        PinnedPool memory p = pinnedPools[underlying][expiry];
        if (!p.pinned) return pools[underlying];
        return PoolConfig({
            pool: p.pool,
            usdgIsToken0: p.usdgIsToken0,
            assetDecimals: p.assetDecimals,
            window: p.window,
            minLiquidity: p.minLiquidity
        });
    }

    /// @dev Reads the pool's cumulatives at `start` and `end` and turns them into (price, mean tick, harmonic-mean
    ///      liquidity). See the contract NatSpec for the maths.
    function _observeWindow(PoolConfig memory cfg, uint256 start, uint256 end)
        private
        view
        returns (bool ok, uint256 price, int24 meanTick, uint256 harmonicLiquidity)
    {
        if (start >= end || end > block.timestamp || block.timestamp - start > type(uint32).max) {
            return (false, 0, 0, 0);
        }
        uint32[] memory secondsAgos = new uint32[](2);
        // casting to 'uint32' is safe because the check above returns when now - start > type(uint32).max, and
        // now - end < now - start
        // forge-lint: disable-next-line(unsafe-typecast)
        secondsAgos[0] = uint32(block.timestamp - start);
        // forge-lint: disable-next-line(unsafe-typecast)
        secondsAgos[1] = uint32(block.timestamp - end);
        (bool success, bytes memory ret) =
            cfg.pool.staticcall(abi.encodeCall(IUniswapV3PoolOracle.observe, (secondsAgos)));
        if (!success) return (false, 0, 0, 0);
        (bool parsed, int256 tickCum0, int256 tickCum1, uint256 splCum0, uint256 splCum1) = _parseObserve(ret);
        if (!parsed) return (false, 0, 0, 0);

        // casting to 'int256' is safe because end - start < 2^32 (checked above)
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 len = int256(end - start);
        int256 tickDelta = tickCum1 - tickCum0;
        int256 mean = tickDelta / len;
        // Solidity division truncates toward zero; the mean tick is floored toward negative infinity, as
        // OracleLibrary.consult does, so a negative remainder moves it down one tick.
        if (tickDelta < 0 && tickDelta % len != 0) --mean;
        if (mean < TickMath.MIN_TICK || mean > TickMath.MAX_TICK) return (false, 0, 0, 0);
        // casting to 'int24' is safe because the line above returns outside [MIN_TICK, MAX_TICK]
        // forge-lint: disable-next-line(unsafe-typecast)
        meanTick = int24(mean);

        // secondsPerLiquidityCumulativeX128 is a uint160 that v3-core accumulates unchecked, so the delta is taken
        // modulo 2^160 like the pool's own arithmetic. A real pool adds at least 1 per second (liquidity < 2^128), so a
        // zero delta over a positive window means the reply is not a pool's.
        uint256 splDelta;
        unchecked {
            // casting to 'uint160' is safe because _parseObserve bounded both values to uint160; wrapping is intended
            // forge-lint: disable-next-line(unsafe-typecast)
            splDelta = uint160(splCum1 - splCum0);
        }
        if (splDelta == 0) return (false, 0, meanTick, 0);
        // casting to 'uint256' is safe because len is positive
        // forge-lint: disable-next-line(unsafe-typecast)
        harmonicLiquidity = (uint256(len) << 128) / splDelta;

        uint256 quoted = _quote(meanTick, cfg.usdgIsToken0, cfg.assetDecimals);
        if (quoted == 0 || quoted > PriceLib.MAX_PRICE || harmonicLiquidity < cfg.minLiquidity) {
            return (false, 0, meanTick, harmonicLiquidity);
        }
        return (true, quoted, meanTick, harmonicLiquidity);
    }

    /// @dev USDG base units for one whole share (10^assetDecimals base units of the asset) at `tick`. v3-periphery
    ///      OracleLibrary.getQuoteAtTick with base = the asset, quote = USDG; `baseToken < quoteToken` there is "the
    ///      asset is token0" here. The sqrt-ratio <= 2^128 split keeps `sqrtRatioX96^2` inside 256 bits.
    function _quote(int24 tick, bool usdgIsToken0, uint8 assetDecimals) private pure returns (uint256) {
        uint256 oneShare = 10 ** uint256(assetDecimals);
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            return usdgIsToken0
                ? FullMath.mulDiv(1 << 192, oneShare, ratioX192)
                : FullMath.mulDiv(ratioX192, oneShare, 1 << 192);
        }
        uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
        return
            usdgIsToken0
                ? FullMath.mulDiv(1 << 128, oneShare, ratioX128)
                : FullMath.mulDiv(ratioX128, oneShare, 1 << 128);
    }

    /// @dev Decodes `observe`'s reply, `(int56[] tickCumulatives, uint160[] secondsPerLiquidityCumulativeX128s)` with
    ///      two entries each, without `abi.decode`: two head words hold the arrays' offsets, and each array is a length
    ///      word followed by its entries. Not parsed when an offset or length is out of bounds, a length is not 2, a
    ///      tick cumulative is not a sign-extended int56 or a seconds-per-liquidity value is wider than uint160.
    function _parseObserve(bytes memory ret)
        private
        pure
        returns (bool parsed, int256 tickCum0, int256 tickCum1, uint256 splCum0, uint256 splCum1)
    {
        if (ret.length < 64) return (false, 0, 0, 0, 0);
        (uint256 tickOffset, uint256 splOffset) = abi.decode(ret, (uint256, uint256));
        (bool tickOk, uint256 t0, uint256 t1) = _pairAt(ret, tickOffset);
        (bool splOk, uint256 s0, uint256 s1) = _pairAt(ret, splOffset);
        if (!tickOk || !splOk) return (false, 0, 0, 0, 0);
        // casting to 'int256' reinterprets the ABI word; the checks below accept only sign-extended int56 values
        // forge-lint: disable-next-line(unsafe-typecast)
        tickCum0 = int256(t0);
        // forge-lint: disable-next-line(unsafe-typecast)
        tickCum1 = int256(t1);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (tickCum0 != int56(tickCum0) || tickCum1 != int56(tickCum1)) return (false, 0, 0, 0, 0);
        if (s0 > type(uint160).max || s1 > type(uint160).max) return (false, 0, 0, 0, 0);
        return (true, tickCum0, tickCum1, s0, s1);
    }

    /// @dev The two entries of the length-2 ABI array starting at `offset` inside `data`.
    function _pairAt(bytes memory data, uint256 offset) private pure returns (bool ok, uint256 first, uint256 second) {
        if (offset > data.length || data.length - offset < 96) return (false, 0, 0);
        uint256 len;
        assembly ("memory-safe") {
            let p := add(add(data, 0x20), offset)
            len := mload(p)
            first := mload(add(p, 0x20))
            second := mload(add(p, 0x40))
        }
        return (len == 2, first, second);
    }
}
