// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPayoutAdapter} from "../interfaces/IPayoutAdapter.sol";
import {V2Constants} from "../interfaces/V2Constants.sol";
import {V2Errors} from "../interfaces/V2Errors.sol";
import {IUniV3PoolFactory, IUniV3SwapRouter02} from "./PayoutDeps.sol";

/// @title UniV3PayoutAdapter
/// @notice Sells an ITM call long's Stock Token payout for USDG in one Uniswap v3 pool through SwapRouter02, for the
///         Clearinghouse's "money auto-flows" conversion (ADR-11, architecture §3.9).
/// @dev UNITS. `amountIn` is base units of the 18-dp Stock Token, `minOut` and `out` are USDG base units (6 dp), pool
///      fees are Uniswap's hundredths of a bip (500 = 0.05 %).
///
///      TRUST. The Clearinghouse does not trust this contract: it approves exactly the payout, judges the result by its
///      own balance and the recipient's USDG balance, and pays in kind on any revert. This contract in turn gives the
///      caller the same guarantee from its side, so a bad route or a thin pool shows up as a revert, never as a
///      partial success:
///        - it pulls exactly `amountIn` from msg.sender (measured, so a fee-on-transfer or short pull reverts);
///        - it sells that amount in the asset's configured pool with amountOutMinimum = `minOut`;
///        - the router must consume ALL of it: with no price limit, a pool that runs out of in-range liquidity fills
///          partially and SwapRouter02 does not object, which would leave part of a holder's payout stranded here, so
///          the adapter's asset balance must be back where it started (BadUnits otherwise);
///        - `to`'s USDG balance must rise by at least `minOut` (BadPrice otherwise), and that measured rise is `out`.
///
///      HOLDS NOTHING BETWEEN CALLS. Every check above is a delta against the balance at entry, never "balance == 0",
///      so tokens someone sends here directly cannot brick conversions and are never swept into a caller's swap; they
///      simply stay (there is deliberately no sweep: the only privilege is route configuration). The router is
///      approved for exactly `amountIn`, which the full-consumption check proves it used, so no allowance survives a
///      successful call and a failed one reverts the approval with everything else.
///
///      NO CALLER RESTRICTION (decided for C2-10). {swapToUsdg} is open to anyone, as IPayoutAdapter documents. It
///      pulls only from msg.sender and holds nothing, so a caller can only sell its own tokens at a floor it chose,
///      which it could do on the router directly. Gating it to the Clearinghouse would add a pointer (immutable: a
///      deploy-order coupling; admin-set: one more privilege) without protecting any value, and would stop operators
///      from probing a route with a tiny real swap or an eth_call before pointing the Clearinghouse at it.
///
///      ROUTES. One pool per asset, single hop, Stock Token -> USDG, chosen by fee tier. {setRoute} checks with the
///      factory that the pool exists, so a typo cannot silently route every payout in kind. The factory is the one the
///      router itself swaps against (read from it at deploy), so the pool the admin checked is the pool the router
///      uses. An asset without a route reverts UnsupportedAsset, which the Clearinghouse turns into an in-kind payout:
///      clearing a route is how the admin switches one market's conversion off without touching the others.
///      {routeFeeBps} reports a route's fee tier in bps rounded up; the Clearinghouse measures its slippage bound above
///      it, so changing a route's tier also moves that market's conversion floor (INTERFACE_VERSION 6). A tier above
///      V2Constants.MAX_ROUTE_FEE_TIER (10000, 1 %) is refused: the Clearinghouse counts at most MAX_ROUTE_FEE_BPS
///      (100) of a route's fee, so such a route would miss the floor on every ordinary conversion and pay in kind.
///
///      REENTRANCY. Every external that changes anything holds the transient guard ({routeFeeBps} is a view). The
///      swap makes three kinds of call (the asset, the router and through it the pool, USDG); none can re-enter
///      {swapToUsdg} or {setRoute}.
contract UniV3PayoutAdapter is IPayoutAdapter, AccessControl, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice The configured pool of one asset.
    /// @dev One slot. `fee == 0` means no route (Uniswap has no zero-fee tier).
    struct Route {
        /// @dev The Uniswap v3 pool of (asset, USDG) at `fee`, as the factory reported it when the route was set.
        address pool;
        /// @dev Pool fee tier, hundredths of a bip.
        uint24 fee;
    }

    /// @notice USDG (6 dp), the output of every swap.
    address public immutable usdg;
    /// @notice SwapRouter02 (0xcaf681a66d020601342297493863e78c959e5cb2 on 4663).
    address public immutable router;
    /// @notice The Uniswap v3 factory the router swaps through, read from `router.factory()` at deploy.
    address public immutable factory;

    /// @notice Route per asset. A zero `fee` means the asset has no route and {swapToUsdg} reverts for it.
    mapping(address asset => Route) public routes;

    /// @notice DEFAULT_ADMIN_ROLE set the route of `asset` to `pool` at `fee` (hundredths of a bip). `pool` and `fee`
    ///         zero: the route was cleared.
    event RouteSet(address indexed asset, address indexed pool, uint24 fee);

    /// @param admin Receives DEFAULT_ADMIN_ROLE: sets routes. Zero reverts NotAuthorized (routes could never be set).
    /// @param usdg_ USDG. Must be a contract (UnsupportedAsset).
    /// @param router_ SwapRouter02. Must be a contract whose `factory()` is a contract (NoSource).
    constructor(address admin, address usdg_, address router_) {
        if (admin == address(0)) revert V2Errors.NotAuthorized();
        if (usdg_.code.length == 0) revert V2Errors.UnsupportedAsset();
        if (router_.code.length == 0) revert V2Errors.NoSource();
        address factory_ = IUniV3SwapRouter02(router_).factory();
        if (factory_.code.length == 0) revert V2Errors.NoSource();
        usdg = usdg_;
        router = router_;
        factory = factory_;
        _grantRole(V2Constants.DEFAULT_ADMIN_ROLE, admin);
    }

    /*//////////////////////////////////////////////////////////////
                                  ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Routes `asset` through its USDG pool at `fee`, or clears its route with `fee == 0`. DEFAULT_ADMIN_ROLE.
    /// @dev Reverts NotAuthorized for any other caller; UnsupportedAsset when `asset` is zero or USDG;
    ///      CeilingExceeded when `fee` is above V2Constants.MAX_ROUTE_FEE_TIER (the Clearinghouse's floor allows for at
    ///      most 1 % of route fee, so a costlier pool would pay every ordinary conversion in kind), checked before the
    ///      factory; NoSource when the factory has no (asset, USDG) pool at `fee` (an unknown fee tier included).
    ///      Pool liquidity is not checked: a thin pool fails the minimum-output check and the payout goes in kind, which
    ///      is the designed fallback.
    ///      Takes effect for the next conversion; nothing is held, so there is nothing to migrate.
    /// @param asset 18-dp Stock Token.
    /// @param fee Pool fee tier, hundredths of a bip (100, 500, 3000, 10000 on 4663; at most
    ///        V2Constants.MAX_ROUTE_FEE_TIER), or 0 to clear.
    function setRoute(address asset, uint24 fee) external nonReentrant onlyRole(V2Constants.DEFAULT_ADMIN_ROLE) {
        address dollar = usdg;
        if (asset == address(0) || asset == dollar) revert V2Errors.UnsupportedAsset();
        if (fee == 0) {
            delete routes[asset];
            emit RouteSet(asset, address(0), 0);
            return;
        }
        if (fee > V2Constants.MAX_ROUTE_FEE_TIER) revert V2Errors.CeilingExceeded();
        address pool = IUniV3PoolFactory(factory).getPool(asset, dollar, fee);
        if (pool == address(0)) revert V2Errors.NoSource();
        routes[asset] = Route({pool: pool, fee: fee});
        emit RouteSet(asset, pool, fee);
    }

    /*//////////////////////////////////////////////////////////////
                                   SWAP
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPayoutAdapter
    /// @dev Anyone. The caller approves this contract for `amountIn` first. Reverts, and so changes nothing:
    ///        - UnsupportedAsset: `asset` has no route;
    ///        - BadUnits: `amountIn == 0` (SwapRouter02 reads 0 as "swap the router's own balance"), fewer or more than
    ///          `amountIn` arrived, or the pool did not consume all of it;
    ///        - BadPrice: `minOut == 0` (a payout swap without a floor is never intended), or `to` gained less than
    ///          `minOut` USDG;
    ///        - NotAuthorized: `to` is address(0), one of SwapRouter02's recipient sentinels address(1) / address(2)
    ///          (they would pay this contract or leave the USDG in the router), this contract or the router, the two
    ///          places where USDG would be left for someone else to take;
    ///        - whatever the token, the router or the pool revert with ("Too little received" below `minOut`).
    ///      The router pays the pool's USDG straight to `to`, so a recipient USDG cannot pay (frozen, paused) reverts
    ///      the swap. The Clearinghouse always has the swap pay itself and then sends the USDG on to the holder; a
    ///      holder USDG cannot pay reverts that transfer, and the Clearinghouse pays in kind.
    function swapToUsdg(address asset, uint256 amountIn, uint256 minOut, address to)
        external
        nonReentrant
        returns (uint256 out)
    {
        uint24 fee = routes[asset].fee;
        if (fee == 0) revert V2Errors.UnsupportedAsset();
        if (amountIn == 0) revert V2Errors.BadUnits();
        if (minOut == 0) revert V2Errors.BadPrice();
        if (uint160(to) <= 2 || to == address(this) || to == router) revert V2Errors.NotAuthorized();

        IERC20 stock = IERC20(asset);
        IERC20 dollar = IERC20(usdg);
        uint256 held = stock.balanceOf(address(this));
        stock.safeTransferFrom(msg.sender, address(this), amountIn);
        if (stock.balanceOf(address(this)) - held != amountIn) revert V2Errors.BadUnits();

        uint256 toBefore = dollar.balanceOf(to);
        stock.forceApprove(router, amountIn);
        IUniV3SwapRouter02(router)
            .exactInputSingle(
                IUniV3SwapRouter02.ExactInputSingleParams({
                tokenIn: asset,
                tokenOut: address(dollar),
                fee: fee,
                recipient: to,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
            );

        // Full consumption: exactly `amountIn` left again, so nothing of the caller's stays here and the exact
        // approval is spent.
        if (stock.balanceOf(address(this)) != held) revert V2Errors.BadUnits();
        // Checked subtraction: a recipient whose balance fell reverts. The router's own minimum is not relied on.
        out = dollar.balanceOf(to) - toBefore;
        if (out < minOut) revert V2Errors.BadPrice();
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPayoutAdapter
    /// @dev routes[asset].fee / 100 rounded up: 100 -> 1, 500 -> 5, 3000 -> 30, 10000 -> 100; 0 without a route. Never
    ///      above MAX_ROUTE_FEE_BPS: {setRoute} refuses a tier above V2Constants.MAX_ROUTE_FEE_TIER.
    function routeFeeBps(address asset) external view returns (uint16 feeBps) {
        // casting to 'uint16' is safe because setRoute stores no tier above MAX_ROUTE_FEE_TIER, so this is at most 100
        // forge-lint: disable-next-line(unsafe-typecast)
        feeBps = uint16((uint256(routes[asset].fee) + 99) / 100);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Every role check reverts with the shared v2 error, including grantRole / revokeRole.
    function _checkRole(bytes32 role, address account) internal view override {
        if (!hasRole(role, account)) revert V2Errors.NotAuthorized();
    }
}
