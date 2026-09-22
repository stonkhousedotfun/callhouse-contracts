// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUniV3Pool} from "../../../src/v2/mocks/MockUniV3Pool.sol";

/// @notice The v3 swap callback a pool makes on its caller.
interface IMockUniV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

interface IInFlightV3Attacker {
    function hitV3(address exec, int256 amount0, int256 amount1) external;
}

/// @notice {MockUniV3Pool} (the oracle surface the TWAP floor reads) plus a swap, for the V4BuybackExecutor suites.
/// @dev Price model: `wethOut = usdgIn * wethPerUsdg / 1e6`, i.e. WETH wei per WHOLE 6-dp USDG, then scaled by
///      `payBps`; the pool takes `usdgIn * takeBps / 1e4`. The two knobs are what the unit tests need:
///        - `payBps` below 10,000 is a worse fill than the TWAP floor allows (a front-run, a thin pool);
///        - `takeBps` below 10,000 is a pool that consumed only part of the input, which must come back to the
///          splitter as unspent USDG.
///      Modes:
///        - `Good`: deltas signed as a real pool signs them (the caller's input positive, its output negative), the
///          output paid before the callback asks for the input.
///        - `WrongSide`: both signs flipped, so the pool asks for the token it should be paying out.
///        - `NoCallback`: pays the output without ever asking for the input.
///      The pool pays WETH from its own balance, so a test funds it first, and asserts nothing about what it
///      receives: the executor's own balance deltas are the subject under test.
contract MockBuybackV3Pool is MockUniV3Pool {
    enum Mode {
        Good,
        WrongSide,
        NoCallback
    }

    Mode public mode;
    /// @dev WETH wei per whole USDG (1e6 base units).
    uint256 public wethPerUsdg;
    uint16 public payBps = 10_000;
    uint16 public takeBps = 10_000;
    uint256 public swaps;
    /// @notice If set, `swap` first asks this contract to call the executor's v3 callback as a stranger while the
    ///         buy is on the stack, so the `msg.sender == v3Pool` check is proven independently of the guard.
    address public inFlightAttacker;

    error MockExactOutputNotSupported();

    function setInFlightAttacker(address attacker) external {
        inFlightAttacker = attacker;
    }

    constructor(address token0_, address token1_, uint24 fee_) MockUniV3Pool(token0_, token1_, fee_) {}

    function setSwap(Mode mode_, uint256 wethPerUsdg_, uint16 payBps_, uint16 takeBps_) external {
        mode = mode_;
        wethPerUsdg = wethPerUsdg_;
        payBps = payBps_;
        takeBps = takeBps_;
    }

    /// @dev `zeroForOne` names the token the caller is selling (USDG here); the other one is paid out.
    ///      `amountSpecified` must be positive: the executor only ever asks for exact input.
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        if (amountSpecified <= 0) revert MockExactOutputNotSupported();
        uint256 usdgIn = uint256(amountSpecified);
        uint256 usdgTaken = usdgIn * takeBps / 10_000;
        uint256 wethOut = usdgIn * wethPerUsdg / 1e6 * payBps / 10_000;
        ++swaps;

        int256 inDelta = int256(usdgTaken);
        int256 outDelta = -int256(wethOut);
        (amount0, amount1) = zeroForOne ? (inDelta, outDelta) : (outDelta, inDelta);
        if (mode == Mode.WrongSide) (amount0, amount1) = (-amount0, -amount1);

        IERC20(zeroForOne ? token1 : token0).transfer(recipient, wethOut);
        if (inFlightAttacker != address(0)) {
            IInFlightV3Attacker(inFlightAttacker).hitV3(msg.sender, amount0, amount1);
        }
        if (mode != Mode.NoCallback) {
            IMockUniV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        }
    }
}
