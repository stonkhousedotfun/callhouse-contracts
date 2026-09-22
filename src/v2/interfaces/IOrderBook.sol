// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFeeDiscount} from "./IFeeDiscount.sol";
import {V2Types} from "./V2Types.sol";

/// @title IOrderBook
/// @notice On-chain order board for Clearinghouse longs: bids, resale asks and write-on-fill asks (ADR-03,
///         architecture §3.6). Takers name the order ids they hit; there is no on-chain sorting and deliberately no
///         matchOrders, so every execution goes through {take} and pays the taker fee.
/// @dev Prices are USDG base units (6 dp) per whole share and multiples of PRICE_TICK (100); units are 0.01-share
///      units; premium(price, units) = price * units / 100. Fees follow ADR-08 (V2Types.FeeParams). The book opts out
///      of third-party redemption in its constructor so nobody can redeem its escrowed longs from under their makers.
///      GUARDIAN may pause place and take (TradingPaused); cancel, prune and claimOwed are never pausable.
///      Fee params (under the V2Constants ceilings) take effect FEE_CHANGE_DELAY after they are scheduled -- 48 h
///      from INTERFACE_VERSION 8, on top of the FEE_MANAGER role's own 48 h execution delay on the manager. Trading
///      stops at expiry for every kind.
///
///      INTERFACE_VERSION 8 FREEZES THE ADMIN SETTERS HERE, which v7 left as implementation surface: they carry role
///      ids in `script/v2/roles.v8.json` now. It also adds three things to {take}, all default-off:
///        - `TakeParams.maxTotalFee`, a HARD CAP on the taker-side fees, checked after the final fee is known and
///          before any USDG moves. {quoteTake} grew a fourth return, `sellerFees`, so a SELLING taker can set that
///          cap exactly; both selectors moved with the struct and `IOrderBook`'s interface id changed.
///        - an optional {IFeeDiscount} module, read once per take under a gas cap and clamped.
///        - an optional PRE-FUND STAGE: a maker contract that CONFIG_ADMIN has allowed, and that turned funding on
///          for itself, is asked to fund its own Clearinghouse ledger before planning. With no funded maker named,
///          the added cost is one storage read per order.
interface IOrderBook {
    /// @notice The Clearinghouse whose longs this book trades.
    /// @return Clearinghouse address.
    function clearinghouse() external view returns (address);

    /// @notice Fee parameters in effect now: what a take in this block pays.
    /// @dev The scheduled change from {pendingFeeParams} once block.timestamp >= its effectiveAt, otherwise the fees
    ///      in effect before it.
    /// @return Fee parameters (bps, and USDG base units for takerFeeFlat).
    function feeParams() external view returns (V2Types.FeeParams memory);

    /// @notice The scheduled fee change that is not in effect yet (INTERFACE_VERSION 6).
    /// @dev A change announced by {FeeParamsScheduled} takes effect once block.timestamp >= effectiveAt, and from then
    ///      on {feeParams} returns it. Zero params and effectiveAt 0 when nothing is scheduled or the scheduled change
    ///      has already taken effect.
    /// @return params The scheduled fee parameters.
    /// @return effectiveAt Unix seconds from which they apply.
    function pendingFeeParams() external view returns (V2Types.FeeParams memory params, uint40 effectiveAt);

    /// @notice Places an order with the caller as maker.
    /// @dev Caller is the maker. Bid escrows premium(price, units) USDG (ERC-20 approval). AskResale escrows `units`
    ///      longs (ERC-1155 approval). AskWrite escrows nothing; the longs are minted from the maker's free collateral
    ///      at fill time, so the maker must have approved the book as Clearinghouse operator. Reverts: TradingPaused,
    ///      UnknownSeries, BadPrice (0 or not a multiple of PRICE_TICK), BadUnits (0), PastCutoff once the series can
    ///      no longer trade this kind (AskWrite: its mint cutoff; Bid and AskResale: its expiry).
    /// @param longId Long id of an existing series.
    /// @param kind Bid, AskResale or AskWrite.
    /// @param price USDG base units (6 dp) per whole share, % 100 == 0.
    /// @param units 0.01-share units.
    /// @param validUntil Unix seconds. 0 = the series' mintCutoff for AskWrite, expiry otherwise; never beyond those.
    /// @return orderId New order id.
    function place(uint256 longId, V2Types.OrderKind kind, uint128 price, uint64 units, uint40 validUntil)
        external
        returns (uint256 orderId);

    /// delegates may place, replace and cancel AskWrite orders only
    /// @dev `maker` itself or a delegate of `maker` (NotAuthorized). A delegate can never place a Bid (it would spend
    ///      the maker's USDG at a price the delegate picks) or an AskResale (it would sell the maker's tokens). The
    ///      AutoRoller is the only delegate the UI offers. Otherwise identical to {place}.
    /// @param maker Account the order belongs to.
    /// @param longId Long id of an existing series.
    /// @param kind Order kind; AskWrite only when the caller is a delegate.
    /// @param price USDG base units (6 dp) per whole share, % 100 == 0.
    /// @param units 0.01-share units.
    /// @param validUntil Unix seconds; 0 = default as in {place}.
    /// @return orderId New order id.
    function placeFor(
        address maker,
        uint256 longId,
        V2Types.OrderKind kind,
        uint128 price,
        uint64 units,
        uint40 validUntil
    ) external returns (uint256 orderId);

    /// @notice Approves or revokes `delegate` for the caller's AskWrite orders.
    /// @dev Caller is the maker.
    /// @param delegate Delegate address.
    /// @param approved True to approve.
    function setDelegate(address delegate, bool approved) external;

    /// @notice Cancels orders and refunds their remaining escrow to the maker.
    /// @dev Maker or maker's delegate (delegates: AskWrite only; NotAuthorized). Never pausable. After expiry a
    ///      cancelled AskResale hands the longs back to the maker, who is then redeemed like any other holder.
    /// @param orderIds Orders to cancel.
    function cancel(uint256[] calldata orderIds) external; // maker or maker's delegate

    /// @notice Cancels `orderId` and places its replacement in one call, same maker, series and kind.
    /// @dev Maker or maker's delegate (delegates: AskWrite only). Subject to the same checks and pause as {place};
    ///      the old order must be live (OrderNotLive(id)).
    /// @param orderId Order to replace.
    /// @param newPrice USDG base units (6 dp) per whole share, % 100 == 0.
    /// @param newUnits 0.01-share units.
    /// @return newOrderId Id of the replacement order.
    function replace(uint256 orderId, uint128 newPrice, uint64 newUnits) external returns (uint256 newOrderId);

    /// @notice Cancels and refunds orders that can no longer trade: past validUntil, past the mint cutoff (AskWrite),
    ///         or whose series is expired or settled. Live orders are skipped.
    /// @dev Anyone. Never pausable. The cranker prunes a series' resale asks before it pushes that series'
    ///      redemptions, so escrowed longs are back with their makers when they are redeemed.
    /// @param orderIds Candidate orders.
    /// @return pruned Number of orders pruned.
    function prune(uint256[] calldata orderIds) external returns (uint256 pruned); // anyone

    /// @notice Fills against the named orders, in the caller's order, until `p.units` are filled.
    /// @dev Anyone; the taker is the caller. Skips dead, foreign-series, wrong-side, beyond-limitPrice and self orders,
    ///      and AskWrite orders whose maker lacks free collateral. Reverts TradingPaused, DeadlinePassed when now >
    ///      p.deadline, BelowMinUnits(filled, min) when fewer than p.minUnits fill. Buying pulls premium + takerFee in
    ///      USDG once and delivers longs to p.recipient. Selling delivers the caller's longs (or mints them from its
    ///      free collateral when p.writeToSell, book approved as operator) and pays p.recipient
    ///      premium - takerFee - sellerFee. Taker fee = min(takerFeeFlat, premium * takerFeeCapBps / 1e4), once per
    ///      call; maker rebates come out of it. Every fee is priced at {feeParams} in the take's block. Maker proceeds
    ///      are paid immediately, else credited to {owed}.
    ///      INTERFACE_VERSION 8: after the final taker fee is known and BEFORE any USDG moves,
    ///      `fee = takerFee + (p.buying ? 0 : sellerFees)`; `fee > p.maxTotalFee` reverts
    ///      `V2Errors.FeeAboveMax(fee, p.maxTotalFee)`. Any discount module is read ONCE for the whole call. When a
    ///      named order's maker has funding on, the pre-fund stage runs before planning and its `Funded` /
    ///      `FundingFailed` logs come before every fill log; the pinned fill log order itself is unchanged.
    /// @param p Take parameters (units in 0.01-share units, limitPrice in USDG 6 dp per share, deadline unix seconds,
    ///        maxTotalFee in USDG base units -- `type(uint128).max` for no limit).
    /// @return unitsFilled 0.01-share units filled.
    /// @return premium USDG base units, sum of price * units / 100 over the fills.
    /// @return takerFee USDG base units charged to the taker.
    function take(V2Types.TakeParams calldata p)
        external
        returns (uint64 unitsFilled, uint256 premium, uint256 takerFee);

    /// @notice View twin of {take}: what the call would fill and cost now.
    /// @dev Anyone; the taker is msg.sender (set `from` on eth_call). Same skip rules and fee maths as {take}; the
    ///      web app and bots simulate with it before a write. It does NOT enforce `p.maxTotalFee` -- it is what a
    ///      caller uses to choose one -- so a quote passes `type(uint128).max`. A funded maker's budget includes its
    ///      {IFundingSource.fundable} ANSWER, read under a gas cap, which makes this an UPPER BOUND on that maker and
    ///      not an equality: {take} pre-funds first and then fills on what the source actually DELIVERED, and a short
    ///      delivery is saturated at 0 rather than reverted. A source that answers more than it delivers quotes units
    ///      {take} will not fill. Every unfunded maker -- which is every maker at launch, since none is `allowed` --
    ///      quotes exactly.
    ///      INTERFACE_VERSION 8 appended `sellerFees`, without which a taker SELLING into bids could not set the cap
    ///      exactly; the selector moved with `TakeParams` regardless.
    /// @param p Take parameters.
    /// @return unitsFilled 0.01-share units that would fill.
    /// @return premium USDG base units.
    /// @return takerFee USDG base units.
    /// @return sellerFees USDG base units the taker would pay AS A SELLER; 0 when buying.
    function quoteTake(V2Types.TakeParams calldata p)
        external
        view
        returns (uint64 unitsFilled, uint256 premium, uint256 takerFee, uint256 sellerFees);

    /// @notice Orders by id, in the order given. Unknown ids return zero structs.
    /// @param orderIds Order ids.
    /// @return The orders.
    function getOrders(uint256[] calldata orderIds) external view returns (V2Types.Order[] memory);

    /// @notice Paginated ids of the orders placed on a series, so a client can rebuild a book without an indexer.
    /// @dev Anyone. Start with cursor 0; nextCursor == 0 when there is nothing more. May include orders that are no
    ///      longer live: read them with {getOrders}.
    /// @param longId Long id.
    /// @param cursor Position to continue from.
    /// @param limit Maximum ids returned.
    /// @return orderIds Order ids.
    /// @return nextCursor Cursor for the next page, 0 when done.
    function ordersOfSeries(uint256 longId, uint256 cursor, uint256 limit)
        external
        view
        returns (uint256[] memory orderIds, uint256 nextCursor);

    /// @notice Paginated ids of a maker's orders. Same cursor rules as {ordersOfSeries}.
    /// @param maker Maker address.
    /// @param cursor Position to continue from.
    /// @param limit Maximum ids returned.
    /// @return orderIds Order ids.
    /// @return nextCursor Cursor for the next page, 0 when done.
    function ordersOfMaker(address maker, uint256 cursor, uint256 limit)
        external
        view
        returns (uint256[] memory orderIds, uint256 nextCursor);

    /// @notice USDG credited to `account` because a direct payment to it failed.
    /// @param account Maker or taker.
    /// @return USDG base units.
    function owed(address account) external view returns (uint256);

    /// @notice Transfers the caller's {owed} USDG to the caller.
    /// @dev Caller only. Never pausable.
    function claimOwed() external;

    // admin and seams (INTERFACE_VERSION 8)

    /// @notice Sets, or clears with `address(0)`, the optional taker-fee discount module. FEE_MANAGER (48 h).
    /// @dev Read once per {take} under `V2Constants.DISCOUNT_READ_GAS` and clamped to `MAX_DISCOUNT_BPS`; a revert,
    ///      an out-of-gas or short return data counts as no discount. It reduces the TAKER fee only.
    /// @param module IFeeDiscount contract, or `address(0)` to turn the seam off.
    function setDiscountModule(IFeeDiscount module) external;

    /// @notice The discount module, or `address(0)` when none is set (the launch state).
    /// @return Module address.
    function discountModule() external view returns (address);

    /// @notice Allows or forbids `maker` to turn just-in-time funding on for itself. CONFIG_ADMIN (24 h).
    /// @dev Allowing is not enabling: the maker must then call {setFunding} itself. This is the admin half of the
    ///      opt-in, so no role can push an external call into another maker's fills.
    /// @param maker Maker contract implementing {IFundingSource}.
    /// @param allowed True to allow.
    function setFundingAllowed(address maker, bool allowed) external;

    /// @notice Turns just-in-time funding on or off for the CALLER. The maker itself only.
    /// @dev Reverts `V2Errors.NotAuthorized` unless CONFIG_ADMIN allowed the caller. Switching it on reads
    ///      `IFundingSource.fundable(usdg)` once and requires an answer, so an EOA cannot enable it. THE PROBE ASKS
    ///      ABOUT USDG ONLY. A series is funded in its own collateral asset -- USDG for a put, the UNDERLYING for a
    ///      call -- so answering here establishes that the caller answers the interface at all, and nothing about the
    ///      asset any series will ask it for. A source that answers only for USDG enables funding and then contributes
    ///      0 to every call series; the runtime read fails closed to 0, so the cost is that maker's pre-funding.
    /// @param on True to have the book pre-fund this maker inside {take}.
    function setFunding(bool on) external;

    /// @notice Whether `maker` is allowed to fund and whether it currently has funding on.
    /// @param maker Maker address.
    /// @return allowed CONFIG_ADMIN allowed it.
    /// @return on The maker turned it on.
    function fundingOf(address maker) external view returns (bool allowed, bool on);

    /// @notice An order was placed. price: USDG 6 dp per share; units: 0.01-share; validUntil: unix seconds (resolved).
    event OrderPlaced(
        uint256 indexed orderId,
        address indexed maker,
        uint256 indexed longId,
        V2Types.OrderKind kind,
        uint128 price,
        uint64 units,
        uint40 validUntil
    );
    /// @notice An order was cancelled (pruned = through {prune}); `unitsRemaining` were unfilled.
    event OrderCancelled(uint256 indexed orderId, uint64 unitsRemaining, bool pruned);
    /// one per maker order touched. primary = units were minted in this fill
    /// @dev premium, sellerFee and makerRebate in USDG base units; units 0.01-share; price USDG 6 dp per share.
    ///      `recipient` is the take's TakeParams.recipient: it received the longs when `takerIsBuyer`, the USDG
    ///      otherwise, so the buyer of record is `recipient` for an ask hit and `maker` for a bid hit
    ///      (`recipient` added in INTERFACE_VERSION 4).
    event OrderFilled(
        uint256 indexed orderId,
        uint256 indexed longId,
        address indexed taker,
        address maker,
        uint64 units,
        uint128 price,
        uint256 premium,
        uint256 sellerFee,
        uint256 makerRebate,
        bool primary,
        bool takerIsBuyer,
        address recipient
    );
    /// one per take call
    /// @dev premium and takerFee in USDG base units; units 0.01-share.
    event Taken(
        address indexed taker, uint256 indexed longId, bool buying, uint64 units, uint256 premium, uint256 takerFee
    );
    /// @notice The initial fee parameters, set by the constructor under the compiled ceilings and in effect at once.
    /// @dev Emitted only at construction. Later changes are announced by {FeeParamsScheduled}.
    event FeeParamsSet(V2Types.FeeParams params);
    /// @notice FEE_MANAGER scheduled fee parameters under the compiled ceilings (INTERFACE_VERSION 6; 48 h lane in v8).
    /// @dev They take effect once block.timestamp >= effectiveAt = the scheduling block's timestamp +
    ///      V2Constants.FEE_CHANGE_DELAY (48 h from INTERFACE_VERSION 8), for every take from then on, resting orders included. A later
    ///      FeeParamsScheduled before effectiveAt replaces this change and restarts the delay; after effectiveAt this
    ///      change stays in effect until the next scheduled change takes effect. No log marks the moment a change
    ///      takes effect.
    event FeeParamsScheduled(V2Types.FeeParams params, uint40 effectiveAt);
    /// @notice `maker` approved or revoked `delegate`.
    event DelegateSet(address indexed maker, address indexed delegate, bool approved);
    /// @notice GUARDIAN paused or resumed place and take (v7 accepted the admin too; v8 is GUARDIAN only).
    event TradingPausedSet(bool paused);
    /// @notice FEE_MANAGER set, or cleared with `address(0)`, the taker-fee discount module (INTERFACE_VERSION 8).
    event DiscountModuleSet(address indexed module);
    /// @notice CONFIG_ADMIN allowed or forbade `maker` to turn just-in-time funding on (INTERFACE_VERSION 8).
    event FundingAllowedSet(address indexed maker, bool allowed);
    /// @notice `maker` turned just-in-time funding on or off for itself (INTERFACE_VERSION 8).
    event FundingSet(address indexed maker, bool on);
    /// @notice The pre-fund stage asked `maker` for `requested` base units of `asset` and measured `delivered`
    ///         arriving in its Clearinghouse ledger (INTERFACE_VERSION 8). `delivered` is a balance delta, never the
    ///         maker's own claim, and may be less than `requested` -- those orders then simply skip.
    event Funded(address indexed maker, address indexed asset, uint256 requested, uint256 delivered);
    /// @notice The pre-fund call to `maker` reverted or ran out of its gas cap (INTERFACE_VERSION 8). The take
    ///         continues on real balances; that maker's orders skip like any under-collateralised AskWrite.
    event FundingFailed(address indexed maker, address indexed asset, uint256 requested);
}
