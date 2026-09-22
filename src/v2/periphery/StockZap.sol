// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IClearinghouse} from "../interfaces/IClearinghouse.sol";
import {IPayoutRouter} from "../interfaces/IPayoutRouter.sol";
import {IStockZap} from "../interfaces/IStockZap.sol";
import {V2Errors} from "../interfaces/V2Errors.sol";
import {IUniV3SwapRouter02} from "./PayoutDeps.sol";
import {PayoutRouter} from "./PayoutRouter.sol";
import {IV4PoolManager, V4PoolKey, V4SwapParams} from "./BuybackDeps.sol";
import {V4Currency} from "./v4/V4Types.sol";
import {V4UnlockCallback} from "./v4/V4UnlockCallback.sol";

/// @title StockZap
/// @notice Stateless, role-less helpers over the PayoutRouter's guardian-pinned routes. `clearRoute` on that router
///         is this contract's kill switch: callers cannot supply or discover an alternate pool.
/// @dev A write zap only buys and deposits the Stock Token. It deliberately does NOT place an AskWrite: a third
///      party may call `OrderBook.placeFor` only as the maker's persistent AskWrite delegate, while AutoRoller also
///      needs operator grants for itself and the OrderBook. A one-shot helper should require neither grant, so the
///      user places their own ask in a separate transaction. An exit zap similarly starts from the user's wallet;
///      Clearinghouse withdrawals spend only the caller's ledger balance and cannot be delegated to this contract.
///      There is no owner, role, pause, sweep, rescue or other way to move balances left here.
contract StockZap is IStockZap, ReentrancyGuardTransient, V4UnlockCallback {
    using SafeERC20 for IERC20;

    PayoutRouter public immutable payoutRouter;
    IClearinghouse public immutable clearinghouse;
    address public immutable usdg;
    address public immutable v3Router;

    /// @param payoutRouter_ PayoutRouter that owns every usable route and its guardian brake.
    /// @param clearinghouse_ Clearinghouse whose USDG must match the router's and whose ledger receives write output.
    constructor(address payoutRouter_, address clearinghouse_) V4UnlockCallback(_poolManagerOf(payoutRouter_)) {
        if (clearinghouse_.code.length == 0) revert V2Errors.NoSource();
        PayoutRouter router = PayoutRouter(payoutRouter_);
        address usdg_ = router.usdg();
        if (IClearinghouse(clearinghouse_).usdg() != usdg_) revert V2Errors.UnsupportedAsset();

        payoutRouter = router;
        clearinghouse = IClearinghouse(clearinghouse_);
        usdg = usdg_;
        v3Router = router.v3Router();
    }

    /// @inheritdoc IStockZap
    function writeZap(address asset, uint256 usdgIn, uint256 minAssetOut, address to, uint40 deadline)
        external
        nonReentrant
        returns (uint256 assetOut)
    {
        _checkDeadline(deadline);
        _checkRecipient(to);
        IPayoutRouter.Route memory route = payoutRouter.routes(asset);
        if (route.venue == IPayoutRouter.Venue.None) revert V2Errors.UnsupportedAsset();
        if (usdgIn == 0) revert V2Errors.BadUnits();
        if (minAssetOut == 0) revert V2Errors.BadPrice();

        IERC20 dollar = IERC20(usdg);
        IERC20 stock = IERC20(asset);
        uint256 dollarHeld = dollar.balanceOf(address(this));
        uint256 stockHeld = stock.balanceOf(address(this));

        dollar.safeTransferFrom(msg.sender, address(this), usdgIn);
        if (dollar.balanceOf(address(this)) - dollarHeld != usdgIn) revert V2Errors.BadUnits();

        if (route.venue == IPayoutRouter.Venue.V3) {
            _swapV3(asset, usdgIn, minAssetOut, route.fee);
        } else {
            _unlock(abi.encode(asset, usdgIn, route.fee, route.tickSpacing));
        }

        assetOut = stock.balanceOf(address(this)) - stockHeld;
        if (assetOut < minAssetOut) revert V2Errors.BadPrice();
        stock.forceApprove(address(clearinghouse), assetOut);
        clearinghouse.deposit(asset, assetOut, to);
        stock.forceApprove(address(clearinghouse), 0);

        if (stock.balanceOf(address(this)) != stockHeld || dollar.balanceOf(address(this)) != dollarHeld) {
            revert V2Errors.BadUnits();
        }
        emit WriteZapped(to, asset, msg.sender, usdgIn, assetOut, uint8(route.venue));
    }

    /// @inheritdoc IStockZap
    function exitZap(address asset, uint256 assetIn, uint256 minUsdgOut, address to, uint40 deadline)
        external
        nonReentrant
        returns (uint256 usdgOut)
    {
        _checkDeadline(deadline);
        _checkRecipient(to);
        IPayoutRouter.Route memory route = payoutRouter.routes(asset);
        if (route.venue == IPayoutRouter.Venue.None) revert V2Errors.UnsupportedAsset();
        if (assetIn == 0) revert V2Errors.BadUnits();
        if (minUsdgOut == 0) revert V2Errors.BadPrice();

        IERC20 stock = IERC20(asset);
        IERC20 dollar = IERC20(usdg);
        uint256 stockHeld = stock.balanceOf(address(this));
        uint256 dollarHeld = dollar.balanceOf(address(this));

        stock.safeTransferFrom(msg.sender, address(this), assetIn);
        if (stock.balanceOf(address(this)) - stockHeld != assetIn) revert V2Errors.BadUnits();
        stock.forceApprove(address(payoutRouter), assetIn);
        usdgOut = payoutRouter.swapToUsdg(asset, assetIn, minUsdgOut, to);
        stock.forceApprove(address(payoutRouter), 0);

        if (stock.balanceOf(address(this)) != stockHeld || dollar.balanceOf(address(this)) != dollarHeld) {
            revert V2Errors.BadUnits();
        }
        emit ExitZapped(to, asset, msg.sender, assetIn, usdgOut, uint8(route.venue));
    }

    function _onUnlock(bytes calldata data) internal override returns (bytes memory) {
        (address asset, uint256 amountIn, uint24 fee, int24 tickSpacing) =
            abi.decode(data, (address, uint256, uint24, int24));
        V4PoolKey memory key = V4Currency.key(asset, usdg, fee, tickSpacing);
        bool zeroForOne = V4Currency.zeroForOne(key, usdg);
        int256 delta = IV4PoolManager(poolManager)
            .swap(
                key,
                V4SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(amountIn),
                    // source: PayoutRouter.sol:171 -- exact input uses the extreme; minOut is the price guard.
                    sqrtPriceLimitX96: zeroForOne ? V4Currency.MIN_SQRT_PRICE + 1 : V4Currency.MAX_SQRT_PRICE - 1
                }),
                ""
            );

        int128 amount0 = V4Currency.amount0(delta);
        int128 amount1 = V4Currency.amount1(delta);
        uint256 paid;
        uint256 taken;
        if (zeroForOne) {
            if (amount0 >= 0 || amount1 <= 0) revert V2Errors.BadUnits();
            paid = uint256(uint128(-amount0));
            taken = uint256(uint128(amount1));
        } else {
            if (amount1 >= 0 || amount0 <= 0) revert V2Errors.BadUnits();
            paid = uint256(uint128(-amount1));
            taken = uint256(uint128(amount0));
        }
        // source: PayoutRouter.sol:188 -- an exact-input v4 route must consume the whole input.
        if (paid != amountIn) revert V2Errors.BadUnits();
        IV4PoolManager(poolManager).sync(usdg);
        IERC20(usdg).safeTransfer(poolManager, paid);
        IV4PoolManager(poolManager).settle();
        IV4PoolManager(poolManager).take(asset, address(this), taken);
        return abi.encode(taken);
    }

    function _swapV3(address asset, uint256 amountIn, uint256 minOut, uint24 fee) private {
        IERC20 dollar = IERC20(usdg);
        dollar.forceApprove(v3Router, amountIn);
        IUniV3SwapRouter02(v3Router)
            .exactInputSingle(
                IUniV3SwapRouter02.ExactInputSingleParams({
                    tokenIn: usdg,
                    tokenOut: asset,
                    fee: fee,
                    recipient: address(this),
                    amountIn: amountIn,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );
        dollar.forceApprove(v3Router, 0);
    }

    function _checkDeadline(uint40 deadline) private view {
        if (block.timestamp > deadline) revert V2Errors.DeadlinePassed();
    }

    function _checkRecipient(address to) private view {
        if (
            to == address(0) || to == address(this) || to == address(clearinghouse) || to == address(payoutRouter)
                || to == v3Router || to == poolManager
        ) revert V2Errors.NotAuthorized();
    }

    function _poolManagerOf(address payoutRouter_) private view returns (address manager) {
        if (payoutRouter_.code.length == 0) revert V2Errors.NoSource();
        manager = PayoutRouter(payoutRouter_).poolManager();
    }
}
