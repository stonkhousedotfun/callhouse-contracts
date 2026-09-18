// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The Chainlink AggregatorV3 proxy surface the round walk reads.
/// @dev Proxy round ids are phase-prefixed: `id = phaseId << 64 | aggregatorRoundId`. Decrementing an id walks back
///      inside one phase only; `phaseId << 64 | 0` is not a round (the live NVDA proxy answers it with zeros), and the
///      previous phase's rounds sit under a different prefix. v1's `src/interfaces/IChainlinkFeed.sol` has no
///      `getRoundData`, and v1 code is not extended for v2.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80 id, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice The Uniswap v3 pool surface the TWAP snapshot reads (v3-core IUniswapV3PoolImmutables/DerivedState).
interface IUniswapV3PoolOracle {
    function token0() external view returns (address);

    function token1() external view returns (address);

    /// @dev `observationCardinality` is how many observations the ring holds now; it only ever grows, and only once the
    ///      ring's index wraps after `increaseObservationCardinalityNext` raised `observationCardinalityNext`.
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
        );

    /// @dev Cumulatives at `block.timestamp - secondsAgos[i]`; reverts `OLD` when the pool's observation buffer does
    ///      not reach back that far.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/// @notice The issuer's oracle halt flag on a Robinhood Stock Token (src/interfaces/IStockToken.sol).
interface IOraclePausable {
    function oraclePaused() external view returns (bool);
}
