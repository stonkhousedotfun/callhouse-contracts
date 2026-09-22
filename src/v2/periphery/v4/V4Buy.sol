// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {V2Constants} from "../../interfaces/V2Constants.sol";
import {V2Errors} from "../../interfaces/V2Errors.sol";
import {IV4PoolManager, V4PoolKey, V4SwapParams} from "../BuybackDeps.sol";
import {V4Currency} from "./V4Types.sol";
import {V4UnlockCallback} from "./V4UnlockCallback.sol";

/// @title V4Buy
/// @notice Exact-input USDG → asset swap over a pinned hookless v4 pool. The buy-side leg
///         {PayoutRouter.swapToUsdg} does not have (PayoutRouter is asset → USDG only).
/// @dev Mirrors {PayoutRouter._onUnlock} (`PayoutRouter.sol:160-194`) with the sold currency
///      reversed. Locking is inherited from {V4UnlockCallback}; this file does not reimplement
///      `unlockCallback`. Every v4 primitive is imported from {V4Currency} — none are redefined.
abstract contract V4Buy is V4UnlockCallback {
    using SafeERC20 for IERC20;

    /// @dev PayoutRouter.sol:28 — Uniswap v4-core `LPFeeLibrary.DYNAMIC_FEE_FLAG`. Not retyped
    ///      as a bare literal at the guard; this is the named source PayoutRouter already pinned.
    uint24 private constant DYNAMIC_FEE_FLAG = 0x800000;

    bytes32 private constant REJECT_DYNAMIC = keccak256("DYNAMIC_FEE");
    bytes32 private constant REJECT_TIER = keccak256("FEE_TIER");

    /// @notice USDG, the exact-input currency this base always sells.
    address public immutable usdg;

    /// @param poolManager_ Pinned v4 PoolManager ({V4UnlockCallback}).
    /// @param usdg_ USDG. Must be a contract (`UnsupportedAsset`).
    constructor(address poolManager_, address usdg_) V4UnlockCallback(poolManager_) {
        if (usdg_.code.length == 0) revert V2Errors.UnsupportedAsset();
        usdg = usdg_;
    }

    /// @dev Pulls `amountIn` USDG from `msg.sender`, opens the lock, and requires the measured
    ///      recipient `asset` delta ≥ `minOut` (PayoutRouter.sol:139-147: minOut is the recipient
    ///      delta, not the swap return). This contract holds nothing between calls
    ///      (PayoutRouter.sol:145 / IPayoutRouter.sol:29).
    function _buyExactInput(address asset, uint256 amountIn, uint256 minOut, address to, uint24 fee, int24 tickSpacing)
        internal
        returns (uint256 out)
    {
        if (asset == address(0) || asset == usdg) revert V2Errors.UnsupportedAsset();
        if (amountIn == 0) revert V2Errors.BadUnits();
        if (minOut == 0) revert V2Errors.BadPrice();
        if (fee & DYNAMIC_FEE_FLAG != 0) revert V2Errors.RouteRejected(REJECT_DYNAMIC);
        if (fee == 0 || fee > V2Constants.MAX_ROUTE_FEE_TIER) {
            revert V2Errors.RouteRejected(REJECT_TIER);
        }

        IERC20 dollar = IERC20(usdg);
        IERC20 stock = IERC20(asset);
        // F-CP-05: SPENT FROM THIS CONTRACT'S OWN BALANCE, NOT PULLED FROM THE CALLER.
        //
        // This used to `safeTransferFrom(msg.sender, ...)`. Every caller of this function is a `restricted` entry
        // point, so msg.sender was a ROLE KEY -- a hot key -- which meant the key paid for the swap while the
        // proceeds landed in the contract: losses settled on the operator, gains accrued here. The funds this is
        // meant to spend were sitting on `address(this)` the whole time.
        //
        // Spending our own money changes what the caller-supplied route and `minOut` mean: they stop being a way
        // for a caller to lose its OWN money and become a way to lose OURS. Callers must therefore bound `minOut`
        // themselves against a source the caller does not control; {Hedger.unwind} does that against the oracle
        // spot and its configured slippage, mirroring {Hedger.hedge}.
        uint256 held = dollar.balanceOf(address(this));
        if (held < amountIn) revert V2Errors.BadUnits();

        uint256 toBefore = stock.balanceOf(to);
        _unlock(abi.encode(asset, amountIn, minOut, to, fee, tickSpacing));
        if (dollar.balanceOf(address(this)) != held - amountIn) revert V2Errors.BadUnits();
        out = stock.balanceOf(to) - toBefore;
        if (out < minOut) revert V2Errors.BadPrice();
    }

    /// @inheritdoc V4UnlockCallback
    /// @dev Direction is USDG → asset: {V4Currency.zeroForOne} is taken on `usdg`, not the
    ///      stock. Price limit at the extreme because a v4 exact-input swap WITH a limit can
    ///      partially fill (IPayoutRouter.sol:27-29). `paid != amountIn` reverts `BadUnits`
    ///      (PayoutRouter.sol:188). Settle order is sync → safeTransfer → settle → take
    ///      (PayoutRouter.sol:189-192), selling USDG and taking `asset` to `to`.
    function _onUnlock(bytes calldata data) internal override returns (bytes memory) {
        (address asset, uint256 amountIn,, address to, uint24 fee, int24 tickSpacing) =
            abi.decode(data, (address, uint256, uint256, address, uint24, int24));
        V4PoolKey memory k = V4Currency.key(asset, usdg, fee, tickSpacing);
        bool zfo = V4Currency.zeroForOne(k, usdg);
        int256 delta = IV4PoolManager(poolManager)
            .swap(
                k,
                V4SwapParams({
                    zeroForOne: zfo,
                    amountSpecified: -int256(amountIn),
                    sqrtPriceLimitX96: zfo ? V4Currency.MIN_SQRT_PRICE + 1 : V4Currency.MAX_SQRT_PRICE - 1
                }),
                ""
            );
        int128 amt0 = V4Currency.amount0(delta);
        int128 amt1 = V4Currency.amount1(delta);
        uint256 paid;
        uint256 taken;
        if (zfo) {
            if (amt0 >= 0 || amt1 <= 0) revert V2Errors.BadUnits();
            paid = uint256(uint128(-amt0));
            taken = uint256(uint128(amt1));
        } else {
            if (amt1 >= 0 || amt0 <= 0) revert V2Errors.BadUnits();
            paid = uint256(uint128(-amt1));
            taken = uint256(uint128(amt0));
        }
        if (paid != amountIn) revert V2Errors.BadUnits();
        IV4PoolManager(poolManager).sync(usdg);
        IERC20(usdg).safeTransfer(poolManager, paid);
        IV4PoolManager(poolManager).settle();
        IV4PoolManager(poolManager).take(asset, to, taken);
        return abi.encode(taken);
    }
}
