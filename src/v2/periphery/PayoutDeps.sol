// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The SwapRouter02 surface UniV3PayoutAdapter swaps through (Uniswap swap-router-contracts IV3SwapRouter plus
///         PeripheryImmutableState's `factory`).
/// @dev SwapRouter02's ExactInputSingleParams has NO `deadline` field (the original v3-periphery SwapRouter's does):
///      `exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))` is selector 0x04e45aaf. The
///      router deployed on 4663 at 0xcaf681a66d020601342297493863e78c959e5cb2 dispatches 0x04e45aaf and not the
///      deadline variant 0x414bf389 (checked against its runtime code; test/v2/fork/PayoutFork.t.sol swaps through it).
///
///      SENTINELS the router gives special meaning to (swap-router-contracts Constants.sol), which a caller must never
///      pass by accident:
///        - `amountIn == 0` (CONTRACT_BALANCE): swap the ROUTER's own token balance instead of pulling from the caller;
///        - `recipient == address(1)` (MSG_SENDER): pay the router's caller; `address(2)` (ADDRESS_THIS): keep the
///          output in the router.
interface IUniV3SwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @dev Swaps `amountIn` of `tokenIn` for `tokenOut` in the one pool (tokenIn, tokenOut, fee), pulling the input
    ///      from msg.sender inside the pool's callback, and reverts "Too little received" below `amountOutMinimum`.
    ///      With `sqrtPriceLimitX96 == 0` a pool that runs out of liquidity fills PARTIALLY and the router pulls only
    ///      what the pool consumed; the router does not check that the whole `amountIn` was used.
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    /// @dev The Uniswap v3 factory whose pools the router derives (by CREATE2 address) and pays in callbacks.
    function factory() external view returns (address);
}

/// @notice The Uniswap v3 factory lookup (v3-core IUniswapV3Factory.getPool).
interface IUniV3PoolFactory {
    /// @dev Token order does not matter. address(0) when no pool exists for the pair at `fee` (hundredths of a bip).
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}
