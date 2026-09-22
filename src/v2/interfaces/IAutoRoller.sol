// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {V2Types} from "./V2Types.sol";

/// @title IAutoRoller
/// @notice Set-and-forget covered-call writing: each period the roller writes a new series for the writer and rests
///         an AskWrite at a strategy price (roadmap 5.3, architecture §3.8). Calls only in v2.0.
/// @dev Setup by the writer: deposit into the Clearinghouse, setPayoutToLedger(true), approve the roller as
///      Clearinghouse operator and as OrderBook delegate (AskWrite orders only). Strategy bounds: otmBps 100-2500,
///      askBps 5-1000 (bps of spot). Prices are USDG base units (6 dp) per whole share; units are 0.01-share units.
interface IAutoRoller {
    /// @notice Sets the caller's strategy for `underlying`.
    /// @dev Caller is the writer. Reverts outside the strategy bounds.
    /// @param underlying 18-dp Stock Token.
    /// @param s Strategy (bps fields, maxUnits in 0.01-share units, 0 = all free collateral).
    function setStrategy(address underlying, V2Types.Strategy calldata s) external;

    /// @notice Deactivates the caller's strategy for `underlying`; no further rolls.
    /// @dev Caller is the writer. Positions already written settle and redeem normally.
    /// @param underlying 18-dp Stock Token.
    function stop(address underlying) external;

    /// @notice Advances one writer's roll.
    /// @dev Anyone. Idempotent. (1) Previous series past expiry: settle it, redeem the writer's shorts, cancel the
    ///      stale order; not yet settled returns false. A call that closes out returns true without going on to (2),
    ///      so a revert of the placement cannot undo the close-out; the next call places. (2) No position for the
    ///      current period, oracle.spot fresh and calendar.isRegularSession(now): expiry = calendar.nextExpiry(now +
    ///      minLead, weekly) with minLead 2 h daily / 24 h weekly; strike = spot * (1 + otmBps) rounded up to
    ///      strikeTick; createSeries; units = min(maxUnits, free / UNIT); price = spot * askBps / 1e4 rounded to
    ///      PRICE_TICK; placeFor(writer, AskWrite).
    ///      Pays the ROLL bounty only when the roll places at least the minimum roll size.
    ///      INTERFACE_VERSION 7, two behaviour changes with no signature change: (a) an OPEN GRACE — inside the first
    ///      {ROLL_OPEN_GRACE} of a regular session the roll waits unless the spot it reads was itself observed in
    ///      session that same day, so a gap at the open cannot be written on yesterday's close; (b) the size is free
    ///      collateral NET OF RENT, `free / (UNIT + mintFee per unit)`, so a writer who deposits exactly N shares
    ///      writes N * 100 - 1 units unless the deposit carries rent headroom, and every later fill of the ask still
    ///      fits (less time is left, so each fill's rent is no higher).
    /// @param writer Strategy owner.
    /// @param underlying 18-dp Stock Token.
    /// @return advanced True when the call changed the writer's position or order.
    function roll(address writer, address underlying) external returns (bool advanced);

    /// @notice Withdraws the writer's live ask once the spot has reached its strike (INTERFACE_VERSION 7).
    /// @dev Anyone, permissionless and idempotent; meant for the cranker. Returns false and changes nothing unless
    ///      the roller tracks a live, uncancelled, not fully filled, not yet expired ask for (writer, underlying)
    ///      whose series has not expired, the series oracle's {ISettlementOracle.trySpot} is ok and non-zero (so the
    ///      observation is within the market's spotMaxAge and the oracle is not paused), and that spot has reached the
    ///      strike: `spot >= strike` for a call, `spot <= strike` for a put, with no margin. Cancels the whole
    ///      remainder through OrderBook.cancel, so a revoked delegation reverts NotAuthorized rather than returning
    ///      false. Moves no collateral and runs under the trading, mint and create pauses and on a disabled market.
    ///      After a cancel the position keeps its longId and expiry with orderId 0: there is no re-roll inside the
    ///      same period, and the close-out after expiry still settles and redeems any partial fill.
    ///      Pays the CANCEL_STALE bounty only when the cancelled remainder is at least the minimum roll size.
    ///      LOG ORDER: the book's OrderCancelled, then StaleAskCancelled, then the bounty's logs.
    /// @param writer Strategy owner.
    /// @param underlying 18-dp Stock Token.
    /// @return cancelled True only for the call that withdrew the ask.
    function cancelStale(address writer, address underlying) external returns (bool cancelled);

    /// @notice Replaces the writer's live ask at `newPrice`.
    /// @dev PRICER lane only, no delay (NotAuthorized), and only when the strategy has smartPricing == true and `newPrice` is
    ///      within [minAskBps, maxAskBps] of spot (BadPrice). INTERFACE_VERSION 7: reverts InTheMoney when the spot
    ///      has reached the series' strike (the {cancelStale} test), checked after the spot read and before the band,
    ///      so a rallied ask is withdrawn rather than repriced below intrinsic.
    /// @param writer Strategy owner.
    /// @param underlying 18-dp Stock Token.
    /// @param newPrice USDG base units (6 dp) per whole share, % 100 == 0.
    function reprice(address writer, address underlying, uint128 newPrice) external; // PRICER lane

    /// @notice Strategy of (writer, underlying); all zero when never set.
    /// @param writer Strategy owner.
    /// @param underlying 18-dp Stock Token.
    /// @return The strategy.
    function strategy(address writer, address underlying) external view returns (V2Types.Strategy memory);

    /// @notice Current rolled position of (writer, underlying); zeros when none.
    /// @param writer Strategy owner.
    /// @param underlying 18-dp Stock Token.
    /// @return longId Long id of the current series.
    /// @return orderId OrderBook id of the live AskWrite.
    /// @return expiry Expiry of the current series, unix seconds.
    function position(address writer, address underlying)
        external
        view
        returns (uint256 longId, uint256 orderId, uint40 expiry);

    /// @notice `writer` set its strategy for `underlying`.
    event StrategySet(address indexed writer, address indexed underlying, V2Types.Strategy strategy);
    /// @notice `writer` stopped its strategy for `underlying`.
    event StrategyStopped(address indexed writer, address indexed underlying);
    /// @notice A roll wrote a series and placed an ask. strike, price: USDG 6 dp per share; units: 0.01-share.
    event Rolled(
        address indexed writer,
        address indexed underlying,
        uint256 longId,
        uint256 orderId,
        uint128 strike,
        uint40 expiry,
        uint128 price,
        uint64 units
    );
    /// @notice The PRICER lane replaced the writer's ask. price: USDG 6 dp per share.
    event Repriced(
        address indexed writer, address indexed underlying, uint256 oldOrderId, uint256 newOrderId, uint128 price
    );
    /// @notice {cancelStale} withdrew the writer's ask on `longId` because the spot reached its strike
    ///         (INTERFACE_VERSION 7). spot: USDG 6 dp per share; updatedAt: unix seconds of that observation.
    event StaleAskCancelled(
        address indexed writer,
        address indexed underlying,
        uint256 longId,
        uint256 orderId,
        uint256 spot,
        uint256 updatedAt
    );
}
