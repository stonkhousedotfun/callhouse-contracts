// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IUniV3PoolFactory} from "../periphery/PayoutDeps.sol";

/// @notice A Uniswap v3 factory stand-in for the UniV3PayoutAdapter suites: `getPool` answers whatever a test registered
///         with {setPool}, in either token order, and address(0) otherwise (like the real factory for a missing pool
///         or an unknown fee tier).
contract MockPayoutV3Factory is IUniV3PoolFactory {
    mapping(address tokenA => mapping(address tokenB => mapping(uint24 fee => address))) internal _pools;

    /// @notice Registers `pool` for {tokenA, tokenB} at `fee` (address(0) removes it).
    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        _pools[tokenA][tokenB][fee] = pool;
        _pools[tokenB][tokenA][fee] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return _pools[tokenA][tokenB][fee];
    }
}
