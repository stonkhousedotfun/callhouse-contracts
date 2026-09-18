// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TickMath} from "../oracle/lib/TickMath.sol";

/// @notice A Uniswap v3 pool's oracle surface with a settable price and liquidity history, for the v2 price-source
///         tests.
/// @dev Two ways to drive {observe}:
///      - HISTORY (default). {pushState} appends "from `fromTs` on, the tick is `tick` and in-range liquidity is
///        `liquidity`". {observe} integrates that step function exactly as v3-core's Oracle accumulates it
///        (`tickCumulative += tick x dt`, `secondsPerLiquidityCumulativeX128 += (dt << 128) / max(liquidity, 1)`,
///        unchecked uint160) and reverts `OLD()` for a target before the first state, like a pool whose observation
///        buffer does not reach back that far. The latest state also sets {slot0} and {liquidity}.
///      - OBSERVATION RING. Each state is one observation, written at its `fromTs`, as a pool writes one per block
///        timestamp with a swap or an in-range mint or burn. {slot0} reports `observationCardinality` (65,535 unless
///        {setObservationCardinality} set it), and once more states were pushed than that, {observe} also reverts
///        `OLD()` for a target before the oldest state the ring still holds: the last `observationCardinality` ones.
///      - FIXED. {setObserveResult} makes {observe} return the given arrays for any input, for replies no pool
///        produces (a zero liquidity delta, an out-of-range mean tick, wrong lengths).
///      {setObserveReverts} makes {observe} revert. token0/token1 are whatever the test passes: the sources must read
///      the order from the pool, so the mock does not sort them.
contract MockUniV3Pool {
    struct State {
        uint40 fromTs;
        int24 tick;
        uint128 liquidity;
    }

    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        uint16 observationIndex;
        uint16 observationCardinality;
        uint16 observationCardinalityNext;
        uint8 feeProtocol;
        bool unlocked;
    }

    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;

    uint128 public liquidity;
    Slot0 internal _slot0;
    State[] internal _history;

    bool public observeReverts;
    bool public fixedResult;
    /// @dev The ring size {slot0} reports (as both cardinality fields) and {observe} honours; packed next to the two
    ///      flags {observe} reads anyway, so the ring check adds no cold storage read to the gas figures.
    uint16 internal _observationCardinality = type(uint16).max;
    int56[] internal _fixedTicks;
    uint160[] internal _fixedSpl;

    error OLD();
    error MockObserveReverted();
    error MockStateNotNewer(uint40 last, uint40 fromTs);

    constructor(address token0_, address token1_, uint24 fee_) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
        _slot0.unlocked = true;
    }

    /*//////////////////////////////////////////////////////////////
                                 SETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice From `fromTs` on (until the next state), the pool sits at `tick` with in-range `liquidity`.
    function pushState(uint40 fromTs, int24 tick, uint128 liquidity_) external {
        uint256 n = _history.length;
        if (n > 0 && fromTs <= _history[n - 1].fromTs) revert MockStateNotNewer(_history[n - 1].fromTs, fromTs);
        _history.push(State({fromTs: fromTs, tick: tick, liquidity: liquidity_}));
        liquidity = liquidity_;
        _slot0.tick = tick;
        _slot0.sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
        uint256 ring = _observationCardinality;
        // forge-lint: disable-next-line(unsafe-typecast)
        _slot0.observationIndex = uint16(ring == 0 ? n : n % ring);
    }

    /// @notice The size of the observation ring {slot0} reports and {observe} honours (see OBSERVATION RING).
    function setObservationCardinality(uint16 cardinality) external {
        _observationCardinality = cardinality;
    }

    function setObserveResult(int56[] calldata tickCumulatives, uint160[] calldata splCumulatives) external {
        fixedResult = true;
        _fixedTicks = tickCumulatives;
        _fixedSpl = splCumulatives;
    }

    function clearObserveResult() external {
        fixedResult = false;
        delete _fixedTicks;
        delete _fixedSpl;
    }

    function setObserveReverts(bool on) external {
        observeReverts = on;
    }

    function setLiquidity(uint128 liquidity_) external {
        liquidity = liquidity_;
    }

    function setSlot0(uint160 sqrtPriceX96, int24 tick) external {
        _slot0.sqrtPriceX96 = sqrtPriceX96;
        _slot0.tick = tick;
    }

    /*//////////////////////////////////////////////////////////////
                               POOL SURFACE
    //////////////////////////////////////////////////////////////*/

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        Slot0 memory s = _slot0;
        return (
            s.sqrtPriceX96,
            s.tick,
            s.observationIndex,
            _observationCardinality,
            _observationCardinality,
            s.feeProtocol,
            s.unlocked
        );
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        if (observeReverts) revert MockObserveReverted();
        if (fixedResult) return (_fixedTicks, _fixedSpl);
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        for (uint256 i; i < secondsAgos.length; ++i) {
            (tickCumulatives[i], secondsPerLiquidityCumulativeX128s[i]) =
                cumulativesAt(block.timestamp - secondsAgos[i]);
        }
    }

    /// @notice The accumulators at `target` (unix seconds), integrated from the first state.
    function cumulativesAt(uint256 target) public view returns (int56 tickCumulative, uint160 splCumulative) {
        uint256 n = _history.length;
        if (n == 0 || target < _history[0].fromTs) revert OLD();
        uint256 ring = _observationCardinality;
        if (ring != 0 && n > ring && target < _history[n - ring].fromTs) revert OLD();
        for (uint256 i; i < n; ++i) {
            State memory s = _history[i];
            if (s.fromTs >= target) break;
            uint256 segEnd = i + 1 < n && _history[i + 1].fromTs < target ? _history[i + 1].fromTs : target;
            uint256 dt = segEnd - s.fromTs;
            unchecked {
                // forge-lint: disable-next-line(unsafe-typecast)
                tickCumulative += int56(s.tick) * int56(uint56(dt));
                // forge-lint: disable-next-line(unsafe-typecast)
                splCumulative += uint160((dt << 128) / (s.liquidity > 0 ? s.liquidity : 1));
            }
        }
    }
}
