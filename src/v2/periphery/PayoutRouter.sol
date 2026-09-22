// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Managed} from "../access/Managed.sol";
import {IPayoutAdapter} from "../interfaces/IPayoutAdapter.sol";
import {IPayoutRouter} from "../interfaces/IPayoutRouter.sol";
import {V2Constants} from "../interfaces/V2Constants.sol";
import {V2Errors} from "../interfaces/V2Errors.sol";
import {IUniV3PoolFactory, IUniV3SwapRouter02} from "./PayoutDeps.sol";
import {IV4PoolManager, IV4StateView, V4PoolKey, V4SwapParams} from "./BuybackDeps.sol";
import {V4Currency} from "./v4/V4Types.sol";
import {V4UnlockCallback} from "./v4/V4UnlockCallback.sol";

/// @title PayoutRouter
/// @notice INTERFACE_VERSION 8 payout adapter: one per-asset route to USDG over Uniswap v3 or a pinned hookless
///         v4 pool. Replaces `UniV3PayoutAdapter` for the Clearinghouse and the FeeSplitter.
/// @dev Constructor is `(authority, usdg, v3Router, v4PoolManager, v4StateView)`. 03-INTERFACES §2.8 sketched four
///      args; the fifth is `IV4StateView` over the same PoolManager (`BuybackDeps.sol`), which is the only place
///      the cached `routeFeeBps` can read LP fee + protocol fee. Named from that source, not reasoned.
contract PayoutRouter is IPayoutRouter, Managed, ReentrancyGuardTransient, V4UnlockCallback {
    using SafeERC20 for IERC20;

    /// @dev Uniswap v4-core `src/libraries/LPFeeLibrary.sol` `uint24 public constant DYNAMIC_FEE_FLAG = 0x800000`
    ///      (PoolKey.fee natspec names the same bit). A fee with this bit is not a static LP fee.
    uint24 private constant DYNAMIC_FEE_FLAG = 0x800000;

    bytes32 private constant REJECT_PAIR = keccak256("PAIR");
    bytes32 private constant REJECT_HOOK = keccak256("HOOK");
    bytes32 private constant REJECT_DYNAMIC = keccak256("DYNAMIC_FEE");
    bytes32 private constant REJECT_TIER = keccak256("FEE_TIER");
    bytes32 private constant REJECT_INIT = keccak256("NOT_INIT");
    bytes32 private constant REJECT_LIQ = keccak256("NO_LIQUIDITY");

    address public immutable usdg;
    address public immutable v3Router;
    address public immutable v3Factory;
    address public immutable v4StateView;

    mapping(address asset => Route) private _routes;

    /// @param authority_ AccessManager. Code-less reverts `NoSource` via {Managed}.
    /// @param usdg_ USDG. Must be a contract (`UnsupportedAsset`).
    /// @param v3Router_ SwapRouter02. Must be a contract whose `factory()` is a contract (`NoSource`).
    /// @param v4PoolManager_ Uniswap v4 PoolManager (V4UnlockCallback). Must be a contract.
    /// @param v4StateView_ `IV4StateView` over `v4PoolManager_` (`BuybackDeps.sol`). Must be a contract, and its
    ///        `poolManager()` must BE `v4PoolManager_` (`NoSource`) -- the pair is validated here because the
    ///        router is immutable and is also resumed or reused outside `DeployV8`, so the constructor is the
    ///        only place it cannot drift. Mirrors `V4BuybackExecutor`'s check on the same interface.
    constructor(address authority_, address usdg_, address v3Router_, address v4PoolManager_, address v4StateView_)
        Managed(authority_)
        V4UnlockCallback(v4PoolManager_)
    {
        if (usdg_.code.length == 0) revert V2Errors.UnsupportedAsset();
        if (v3Router_.code.length == 0) revert V2Errors.NoSource();
        address factory_ = IUniV3SwapRouter02(v3Router_).factory();
        if (factory_.code.length == 0) revert V2Errors.NoSource();
        if (v4StateView_.code.length == 0) revert V2Errors.NoSource();
        // A route is validated and priced through `v4StateView_` and executed through `v4PoolManager_`. If they
        // are not the same manager, `setRouteV4` caches a floor from a pool the swap never touches. Code at each
        // address does not say they are paired: a fresh `DeployV8` run pairs them by accident, a resumed or mixed
        // one need not. Same comparison as `V4BuybackExecutor`, on the same `IV4StateView.poolManager()`.
        if (IV4StateView(v4StateView_).poolManager() != v4PoolManager_) revert V2Errors.NoSource();
        usdg = usdg_;
        v3Router = v3Router_;
        v3Factory = factory_;
        v4StateView = v4StateView_;
    }

    /// @inheritdoc IPayoutRouter
    function setRouteV3(address asset, uint24 fee) external nonReentrant restricted {
        _assertAsset(asset);
        if (fee == 0 || fee > V2Constants.MAX_ROUTE_FEE_TIER) {
            revert V2Errors.RouteRejected(REJECT_TIER);
        }
        address pool = IUniV3PoolFactory(v3Factory).getPool(asset, usdg, fee);
        if (pool == address(0)) revert V2Errors.NoSource();
        uint16 feeBps = _v3FeeBps(fee);
        _routes[asset] = Route({venue: Venue.V3, fee: fee, tickSpacing: 0, v3Pool: pool, feeBps: feeBps});
        emit RouteSet(asset, uint8(Venue.V3), bytes32(uint256(uint160(pool))), fee, feeBps);
    }

    /// @inheritdoc IPayoutRouter
    function setRouteV4(address asset, uint24 fee, int24 tickSpacing) external nonReentrant restricted {
        _assertAsset(asset);
        if (fee & DYNAMIC_FEE_FLAG != 0) revert V2Errors.RouteRejected(REJECT_DYNAMIC);
        if (fee == 0 || fee > V2Constants.MAX_ROUTE_FEE_TIER) revert V2Errors.RouteRejected(REJECT_TIER);
        V4PoolKey memory k = V4Currency.key(asset, usdg, fee, tickSpacing);
        // Hooks are not a parameter: a hooked pool is a different PoolKey. Defense in depth.
        if (k.hooks != address(0)) revert V2Errors.RouteRejected(REJECT_HOOK);
        bytes32 pid = V4Currency.id(k);
        (uint160 sqrtPrice,,,) = IV4StateView(v4StateView).getSlot0(pid);
        if (sqrtPrice == 0) revert V2Errors.RouteRejected(REJECT_INIT);
        if (IV4StateView(v4StateView).getLiquidity(pid) == 0) revert V2Errors.RouteRejected(REJECT_LIQ);
        uint16 feeBps = _v4FeeBps(pid, V4Currency.zeroForOne(k, asset));
        _routes[asset] =
            Route({venue: Venue.V4, fee: fee, tickSpacing: tickSpacing, v3Pool: address(0), feeBps: feeBps});
        emit RouteSet(asset, uint8(Venue.V4), pid, fee, feeBps);
    }

    /// @inheritdoc IPayoutRouter
    function clearRoute(address asset) external nonReentrant restricted {
        delete _routes[asset];
        emit RouteCleared(asset);
    }

    /// @inheritdoc IPayoutRouter
    function refreshRouteFee(address asset) external nonReentrant {
        Route storage r = _routes[asset];
        if (r.venue == Venue.None) revert V2Errors.UnsupportedAsset();
        if (r.venue == Venue.V3) {
            r.feeBps = _v3FeeBps(r.fee);
        } else {
            V4PoolKey memory k = V4Currency.key(asset, usdg, r.fee, r.tickSpacing);
            r.feeBps = _v4FeeBps(V4Currency.id(k), V4Currency.zeroForOne(k, asset));
        }
    }

    /// @inheritdoc IPayoutAdapter
    function swapToUsdg(address asset, uint256 amountIn, uint256 minOut, address to)
        external
        nonReentrant
        returns (uint256 out)
    {
        Route memory r = _routes[asset];
        if (r.venue == Venue.None) revert V2Errors.UnsupportedAsset();
        if (amountIn == 0) revert V2Errors.BadUnits();
        if (minOut == 0) revert V2Errors.BadPrice();
        if (uint160(to) <= 2 || to == address(this) || to == v3Router || to == poolManager) {
            revert V2Errors.NotAuthorized();
        }

        IERC20 stock = IERC20(asset);
        IERC20 dollar = IERC20(usdg);
        uint256 held = stock.balanceOf(address(this));
        stock.safeTransferFrom(msg.sender, address(this), amountIn);
        if (stock.balanceOf(address(this)) - held != amountIn) revert V2Errors.BadUnits();

        uint256 toBefore = dollar.balanceOf(to);
        if (r.venue == Venue.V3) {
            _swapV3(asset, amountIn, minOut, to, r.fee);
        } else {
            _unlock(abi.encode(asset, amountIn, minOut, to, r.fee, r.tickSpacing));
        }
        if (stock.balanceOf(address(this)) != held) revert V2Errors.BadUnits();
        out = dollar.balanceOf(to) - toBefore;
        if (out < minOut) revert V2Errors.BadPrice();
    }

    /// @inheritdoc IPayoutRouter
    function routes(address asset) external view returns (Route memory) {
        return _routes[asset];
    }

    /// @inheritdoc IPayoutAdapter
    function routeFeeBps(address asset) external view returns (uint16 feeBps) {
        return _routes[asset].feeBps;
    }

    /// @dev THIS ROUTER SELLS THE STOCK, so the direction is taken on `asset` and that is correct here.
    ///      {V4Buy._onUnlock} (`src/v2/periphery/v4/V4Buy.sol:91`) goes the other way, USDG to asset, and
    ///      takes it on `usdg`. The two are mirror images and neither is a copy of the other's bug.
    ///
    ///      RECORDED BECAUSE A LEDGER ROW WAS FILED AGAINST THIS FILE IN ERROR (T-538). The P8-03 / T-96
    ///      suspicion "first check that `_onUnlock` sells `usdg` ... copying PayoutRouter's
    ///      `zeroForOne(k, asset)` would reverse the buy" is about V4Buy, and it names this file only as
    ///      the thing V4Buy must NOT be copied from. It was mined onto `PayoutRouter.sol` because the
    ///      text cites `PayoutRouter.sol:28`. Re-derived at v8 8adcde6f: `swapToUsdg` pulls the stock in
    ///      at :144, so selling `asset` is the whole point of this path; and V4Buy already takes its
    ///      direction on `usdg`, so the suspicion's own subject is satisfied too.
    function _onUnlock(bytes calldata data) internal override returns (bytes memory) {
        (address asset, uint256 amountIn,, address to, uint24 fee, int24 tickSpacing) =
            abi.decode(data, (address, uint256, uint256, address, uint24, int24));
        V4PoolKey memory k = V4Currency.key(asset, usdg, fee, tickSpacing);
        bool zfo = V4Currency.zeroForOne(k, asset);
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
        IV4PoolManager(poolManager).sync(asset);
        IERC20(asset).safeTransfer(poolManager, paid);
        IV4PoolManager(poolManager).settle();
        IV4PoolManager(poolManager).take(usdg, to, taken);
        return abi.encode(taken);
    }

    function _swapV3(address asset, uint256 amountIn, uint256 minOut, address to, uint24 fee) private {
        IERC20(asset).forceApprove(v3Router, amountIn);
        IUniV3SwapRouter02(v3Router)
            .exactInputSingle(
                IUniV3SwapRouter02.ExactInputSingleParams({
                    tokenIn: asset,
                    tokenOut: usdg,
                    fee: fee,
                    recipient: to,
                    amountIn: amountIn,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );
    }

    function _assertAsset(address asset) private view {
        if (asset == address(0) || asset == usdg) revert V2Errors.RouteRejected(REJECT_PAIR);
    }

    function _v3FeeBps(uint24 fee) private pure returns (uint16) {
        // UniV3PayoutAdapter.sol:194 — fee / 100 rounded up. Source of the formula, not re-reasoned.
        return uint16((uint256(fee) + 99) / 100);
    }

    function _v4FeeBps(bytes32 poolId, bool zeroForOne) private view returns (uint16) {
        // IV4StateView.getSlot0 (BuybackDeps.sol): lpFee in pips; protocolFee packs two 12-bit pip values.
        (,, uint24 protocolFee, uint24 lpFee) = IV4StateView(v4StateView).getSlot0(poolId);
        uint256 proto = zeroForOne ? (protocolFee & 0xFFF) : (protocolFee >> 12);
        uint256 pips = uint256(lpFee) + proto;
        uint256 bps = (pips + 99) / 100;
        if (bps > V2Constants.MAX_ROUTE_FEE_BPS) bps = V2Constants.MAX_ROUTE_FEE_BPS;
        return uint16(bps);
    }
}
