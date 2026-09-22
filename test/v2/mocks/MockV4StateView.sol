// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MockV4PoolManager} from "./MockV4PoolManager.sol";

/// @notice A Uniswap v4 StateView stand-in for the V4BuybackExecutor suites.
/// @dev It is a lens, not a source: every read goes to the {MockV4PoolManager} it was built over, so the protocol fee
///      and LP fee the executor's guard DECLARES are the same ones the mock manager CHARGES, and a test raises them in
///      one place. {setPoolManager} exists only so a constructor test can point a lens at the wrong manager.
contract MockV4StateView {
    address public poolManager;

    constructor(address poolManager_) {
        poolManager = poolManager_;
    }

    function setPoolManager(address poolManager_) external {
        poolManager = poolManager_;
    }

    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        return MockV4PoolManager(payable(poolManager)).slot0Of(poolId);
    }

    function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity) {
        return MockV4PoolManager(payable(poolManager)).liquidityOf(poolId);
    }
}
