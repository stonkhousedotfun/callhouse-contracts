// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A Uniswap v4 PoolKey, ABI-identical to v4-core's.
/// @dev v4-core declares `currency0`/`currency1` as the user-defined value type `Currency` and `hooks` as `IHooks`;
///      both are `address` underneath, so this struct encodes to the same five static words and hashes to the same
///      pool id (`keccak256(abi.encode(key))`). Native ETH is `address(0)`.
struct V4PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @notice v4-core's `IPoolManager.SwapParams`.
/// @dev A negative `amountSpecified` is exact input. `sqrtPriceLimitX96` is a hard bound on the price the swap may
///      reach, not a slippage guard: the extremes leave the whole input to be consumed.
struct V4SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

/// @notice The Uniswap v4 PoolManager surface a single-pool exact-input buy needs (v4-core `IPoolManager`).
/// @dev The lock pattern: {unlock} calls `unlockCallback` back on its own caller, and only inside that callback may
///      {swap}, {sync}, {settle} and {take} be used. Native ETH is settled with `sync(address(0))` followed by
///      `settle{value: amount}()`; C3-602 measured that exact sequence against the live PoolManager.
///
///      {swap} returns v4-core's `BalanceDelta`: `amount0` in the upper 128 bits and `amount1` in the lower, both
///      signed from the caller's point of view (negative is owed to the pool). The value already NETS the hook's
///      `afterSwapReturnDelta` cut, so for a pool with a fee-taking hook the positive side is what the caller can
///      actually {take}, not the pool's gross output.
interface IV4PoolManager {
    function unlock(bytes calldata data) external returns (bytes memory result);
    function swap(V4PoolKey memory key, V4SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

/// @notice The Uniswap v4 StateView lens (v4-periphery), which reads the PoolManager's packed pool state.
/// @dev `getSlot0`'s `protocolFee` packs two 12-bit pip values: the low 12 bits charge zeroForOne swaps and the high
///      12 bits oneForZero ones, each at most 1,000 pips (0.10 %). `lpFee` is the pool's LP fee in pips. Both are
///      read at call time because the PoolManager's protocol-fee controller can change the protocol fee of any pool.
///
///      THAT DIRECTION IS PINNED BY TEST, NOT BY THIS SENTENCE (T-185). `test/v2/unit/V4FeeNibblePin.t.sol` and
///      `test/v2/unit/PayoutRouter.t.sol::test_v4RouteFeeReadsTheNibbleForTheRouteDirection` make both readers fail
///      if either mask is flipped, using two DIFFERENT pip values -- symmetric values cannot tell the halves apart,
///      which is why nothing caught this before: the mocks charge by the same rule the guards declare, and the
///      pinned fork pool's real protocol fee is 0, identical under either mask.
///
///      WHAT IS STILL UNPROVEN: that this convention matches v4-core's. v4-core is not a dependency of this
///      repository, so the pins fix our readers to each other and to a literal, not to the upstream source. Closing
///      that needs `ProtocolFeeLibrary` vendored or a pool with a non-zero, asymmetric protocol fee.
interface IV4StateView {
    function poolManager() external view returns (address);
    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
    function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity);
}

/// @notice The per-pool launch record of the third-party Pons v2 launch hook (`PonsV2MemeHook`, Sourcify exact match
///         on chain 4663), which is where THIS pool's swap fee actually lives.
/// @dev C3-602 correction, recorded in ADR-15 §5 and `docs/V2-FLYWHEEL-ROUTE-SPIKE.md`: the hook's GLOBAL
///      `hookFeeBps()` getter only seeds FUTURE launches and does not apply to an already-registered pool, and it
///      omits the creator tax entirely. The terms that are charged are `launches(poolId).hookFeeBps` plus
///      `launches(poolId).creatorTaxBps` (100 + 100 bps on the pinned pool), frozen at `registerPool` with no setter
///      in the verified source. A fee guard therefore reads this record, never `hookFeeBps()`.
interface IPonsLaunchHook {
    function poolManager() external view returns (address);
    function launches(bytes32 poolId)
        external
        view
        returns (
            bool registered,
            bool memecoinIsCurrency0,
            address memecoin,
            address quoteToken,
            address creator,
            address buybackCreatorRecipient,
            address protocolFeeRecipient,
            uint16 creatorTaxBps,
            uint16 protocolFeeShareBps,
            uint16 buybackBurnBps,
            uint16 hookFeeBps,
            uint16 maxInternalPriceImpactBps,
            bool buybackEnabled
        );
}

/// @notice The canonical WETH9 surface: wrap and unwrap only.
/// @dev `withdraw` pays native ETH back with a plain `call`, so a contract that unwraps must have a `receive`.
interface IWeth9 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

/// @notice The Uniswap v3 pool surface a direct (routerless) swap needs, beside the oracle surface in
///         `../oracle/OracleDeps.sol`'s `IUniswapV3PoolOracle`.
/// @dev {swap} pulls the input inside `uniswapV3SwapCallback`, which the pool makes on its caller. A positive
///      `amountSpecified` is exact input. With the price limit at its extreme the whole input is consumed, so a
///      short fill means the pool ran out of in-range liquidity and the caller must treat it as a failure.
interface IUniV3SwapPool {
    function fee() external view returns (uint24);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}
