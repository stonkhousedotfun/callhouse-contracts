// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {V2Types} from "./V2Types.sol";

/// @title ISettlementOracle
/// @notice One settlement price per (underlying, expiry), shared by every strike and both option types: the TWAP of
///         the final SETTLEMENT_WINDOW seconds before expiry, from per-market IPriceSource adapters in priority order
///         (ADR-05, architecture §3.4).
/// @dev The fallback chain has three outcomes. Corroborated: the first ok source that agrees with another ok source
///      within the expiry's maxDeviationBps is final immediately. Uncorroborated: the highest-priority ok source
///      becomes a candidate (status Pending) and is final only after the expiry's uncorroboratedDelay unless the
///      guardian vetoes. Held: vetoed; CONFIG_ADMIN resolves it through {adminResolve} after RESOLVE_DELAY, or
///      GUARDIAN lifts the veto through {unveto}. "The expiry's" parameters are the ones pinned by {pin}, or the
///      market's for an expiry no series pinned.
///      Disagreement is deliberately not terminal: holding a pool off-price for 30 minutes buys an attacker a
///      delay, never a frozen payout. Settlement of one expiry never affects any other.
///
///      Prices are USDG base units (6 dp) per whole share. Market configuration (sources, maxDeviationBps,
///      uncorroboratedDelay, spotMaxAge, the Clearinghouse pointer used for the open-interest bounty gate and for
///      {pin}) is CONFIG_ADMIN implementation surface; only its MarketSourcesSet event is frozen here.
///
///      ACCESS (INTERFACE_VERSION 8). Roles are not on the oracle: the restricted functions are gated by the one
///      AccessManager, and `script/v2/roles.v8.json` maps {veto} and {unveto} to GUARDIAN (no execution delay) and
///      {adminResolve} and the configuration setters to CONFIG_ADMIN (24 h execution delay, so the call is scheduled
///      on the manager first). A caller without the role reverts V2Errors.NotAuthorized, not OpenZeppelin's
///      AccessManagedUnauthorized, because Managed._checkCanCall replaces it. A CONFIG_ADMIN call that was not
///      scheduled, is not ready yet or has expired reverts with the manager's own AccessManagerNotScheduled,
///      AccessManagerNotReady or AccessManagerExpired.
///
///      PINNING (INTERFACE_VERSION 6). The Clearinghouse calls {pin} when it creates a series, so the configuration an
///      expiry settles on is fixed while its series are live: the market's sources, maxDeviationBps and
///      uncorroboratedDelay as they were when the first series of that expiry was created, and each source's own
///      configuration of the underlying at that moment. Configuration changes reach only expiries with no series yet.
///      Pinning fails closed: a series is created only with the oracle and every source pinned, and never on a pin
///      made earlier (outside a series creation) that differs from the configuration current at the creation.
///      {spot} is not settlement and always reads the market's current configuration.
interface ISettlementOracle {
    /// @notice Length of the averaging window before expiry.
    /// @return Seconds; always 1800 (V2Constants.SETTLEMENT_WINDOW).
    function SETTLEMENT_WINDOW() external view returns (uint32); // 1800

    /// @notice Current spot of `underlying` from source 0 (highest priority), for the AutoRoller and the strike band
    ///         at series creation; the Clearinghouse also reads {trySpot} for the floor of a payout conversion.
    /// @dev Anyone. Reverts (V2Errors.NoSource, V2Errors.StaleSpot) unless source 0 is ok, `now - updatedAt` is
    ///      within the market's spotMaxAge (default 1 h) and the token's oraclePaused() is false. A print older than the
    ///      implementation's SPOT_CORROBORATION_AGE (30 min, owner ruling SEC-08b/c) is also StaleSpot when the market's
    ///      source 1 is ok and disagrees with it by more than maxDeviationBps: past that bound, accuracy is judged by
    ///      agreement with the pool rather than by the clock, because the 4663 feeds print on a 0.5 % move or a 24 h
    ///      heartbeat and a quiet session leaves an accurate print hours old. The price is always source 0's. Market-level:
    ///      it reads the market's CURRENT source list, maxDeviationBps and spotMaxAge, never an expiry's pinned copy,
    ///      because it settles nothing.
    /// @param underlying 18-dp Stock Token.
    /// @return price USDG base units (6 dp) per whole share.
    /// @return updatedAt Unix seconds of the observation.
    function spot(address underlying) external view returns (uint256 price, uint256 updatedAt);

    /// @notice Non-reverting twin of {spot}.
    /// @dev Anyone. Never reverts; ok = false wherever {spot} would revert.
    /// @param underlying 18-dp Stock Token.
    /// @return ok True when {spot} would succeed.
    /// @return price USDG base units (6 dp) per whole share; meaningful only when ok.
    /// @return updatedAt Unix seconds of the observation.
    function trySpot(address underlying) external view returns (bool ok, uint256 price, uint256 updatedAt);

    /// @notice Calls IPriceSource.record on every source of `underlying` for `expiry`: the expiry's pinned sources
    ///         once {pin} ran, else the market's current list.
    /// @dev Anyone. Idempotent. Meant for the keeper right after expiry (UniV3TwapSource records only inside
    ///      `[expiry, expiry + SNAPSHOT_GRACE]`). Pays the caller the SNAPSHOT bounty only when a source recorded for
    ///      the first time, Clearinghouse.openInterest(underlying, expiry) > 0 and that Clearinghouse pinned the expiry
    ///      on this oracle, so empty expiries, and expiries whose series settle on another oracle, cannot be farmed.
    /// @param underlying 18-dp Stock Token.
    /// @param expiry Expiry, unix seconds.
    /// @return newlyRecorded Number of sources that stored something for the first time in this call.
    function snapshot(address underlying, uint40 expiry) external returns (uint8 newlyRecorded);

    /// Reverts TooEarly before expiry + FINALIZE_DELAY. After that never reverts for "not yet":
    /// returns (false, 0) while no source is ok, an uncorroborated candidate is inside its delay,
    /// or the expiry is held (vetoed). Returns (true, price) once final, idempotently.
    /// @dev Anyone, so a keeper loop can call it blindly. The first call that finds sources captures the recorded
    ///      source prices; the first uncorroborated call sets Pending and emits SettlementCandidate; a call after the
    ///      delay re-checks corroboration (a corroborated answer always wins) before finalizing the candidate. A veto
    ///      blocks only the uncorroborated path: sources that corroborate later finalize even while Held. An already
    ///      final expiry returns (true, price) with no event and no bounty. Pays the FINALIZE bounty only for a call
    ///      that advances the state, and only when Clearinghouse.openInterest(underlying, expiry) > 0 and that
    ///      Clearinghouse pinned the expiry on this oracle; never to the Clearinghouse or to an earlier one.
    /// @param underlying 18-dp Stock Token.
    /// @param expiry Expiry, unix seconds.
    /// @return finalized True once the price is final.
    /// @return price USDG base units (6 dp) per whole share when finalized, else 0.
    function finalize(address underlying, uint40 expiry) external returns (bool finalized, uint256 price);

    /// @notice Settlement state of (underlying, expiry).
    /// @dev Anyone. The Clearinghouse reads this in settle and calls {finalize} when it is not Finalized yet.
    /// @param underlying 18-dp Stock Token.
    /// @param expiry Expiry, unix seconds.
    /// @return status None, Pending, Finalized or Held.
    /// @return price USDG base units (6 dp) per whole share when Finalized, else 0.
    function settlementPrice(address underlying, uint40 expiry)
        external
        view
        returns (V2Types.SettlementStatus status, uint256 price);

    /// @notice Vetoes the uncorroborated path for (underlying, expiry): None or Pending -> Held.
    /// @dev GUARDIAN only, with no execution delay (roles.v8.json); any other caller reverts V2Errors.NotAuthorized.
    ///      Reverts V2Errors.AlreadyFinal once Finalized. Blocks the uncorroborated path only: sources that corroborate
    ///      later still finalize through {finalize}.
    /// @param underlying 18-dp Stock Token.
    /// @param expiry Expiry, unix seconds.
    function veto(address underlying, uint40 expiry) external; // GUARDIAN; None|Pending -> Held

    /// @notice Lifts a veto: Held -> Pending, with the uncorroborated delay restarted from this call.
    /// @dev GUARDIAN only, with no execution delay (roles.v8.json); any other caller reverts V2Errors.NotAuthorized.
    ///      v7 also let DEFAULT_ADMIN_ROLE unveto; v8 maps no admin role to it. Emits SettlementUnvetoed.
    /// @param underlying 18-dp Stock Token.
    /// @param expiry Expiry, unix seconds.
    function unveto(address underlying, uint40 expiry) external; // GUARDIAN; Held -> Pending, delay restarts

    /// @notice The uncorroborated candidate of (underlying, expiry), if any.
    /// @dev Anyone. All zero when no candidate was ever set. While Pending, {finalize} may finalize it from
    ///      `finalizableAt` on (unless sources corroborate first); {unveto} restarts the delay and moves
    ///      `finalizableAt`. Added in INTERFACE_VERSION 2 so readers need not know the market's uncorroboratedDelay.
    /// @param underlying 18-dp Stock Token.
    /// @param expiry Expiry, unix seconds.
    /// @return price USDG base units (6 dp) per whole share.
    /// @return sourceIndex Priority index of the candidate source.
    /// @return disagreed True when two or more sources were ok but none agreed.
    /// @return finalizableAt Unix seconds from which the candidate may finalize (since + uncorroboratedDelay).
    function candidate(address underlying, uint40 expiry)
        external
        view
        returns (uint256 price, uint8 sourceIndex, bool disagreed, uint40 finalizableAt);

    /// @notice Sets the final price of an expiry that did not settle through the sources.
    /// @dev CONFIG_ADMIN only, with its 24 h execution delay (roles.v8.json): the call is scheduled on the
    ///      AccessManager first. Any other caller reverts V2Errors.NotAuthorized; an unscheduled, not yet ready or
    ///      expired call reverts with the manager's AccessManagerNotScheduled, AccessManagerNotReady or
    ///      AccessManagerExpired. Reverts V2Errors.TooEarly(expiry + RESOLVE_DELAY) before 48 h after expiry,
    ///      V2Errors.AlreadyFinal once Finalized, and V2Errors.ResolveOutOfBand(lo, hi) when source prices were
    ///      recorded and `price` lies outside the band they span widened by the market's maxDeviationBps, or, from
    ///      expiry + 7 days for a Held expiry with exactly one recorded price p, outside [p x 0.8, p / 0.8] (a vetoed
    ///      single price can then still settle at the right one). Emits SettlementResolved.
    /// @param underlying 18-dp Stock Token.
    /// @param expiry Expiry, unix seconds.
    /// @param price USDG base units (6 dp) per whole share.
    function adminResolve(address underlying, uint40 expiry, uint256 price) external; // CONFIG_ADMIN, 48 h after expiry

    /// @notice Pins the settlement configuration of (underlying, expiry): copies the market's current source list,
    ///         maxDeviationBps, uncorroboratedDelay and spotMaxAge (defaults filled in) for that expiry, and asks each
    ///         of those sources to pin its own configuration of `underlying` for it (IPriceSource.pin). From then on
    ///         {snapshot}, {finalize}, {unveto}, {adminResolve} and the settlement views of that expiry use the pinned
    ///         copy; a later configuration change applies only to expiries not pinned yet. Added in INTERFACE_VERSION 6.
    /// @dev Only the Clearinghouse this oracle is configured with (V2Errors.NotAuthorized): Clearinghouse.createSeries
    ///      calls it for every series it creates, and a revert here reverts the creation. FAILS CLOSED. The first call
    ///      reverts V2Errors.NoSource when the market has no source, and V2Errors.SourceNotPinned(source, reason) when
    ///      any source's own pin fails (the source does not list this oracle, has no configuration for the
    ///      underlying, was pinned differently before, has no code, or answers anything but the IPriceSource.pin
    ///      selector): a series exists only with the oracle and every one of its sources pinned. A later call from the
    ///      Clearinghouse that pinned the expiry changes nothing and emits nothing. A later call from another
    ///      Clearinghouse (a migration, or an expiry pinned before any series through an earlier pointer) must confirm
    ///      the pin: it reverts V2Errors.PinMismatch unless the pinned list, maxDeviationBps, uncorroboratedDelay and
    ///      spotMaxAge equal the market's current ones, asks every pinned source to confirm its own pin the same way,
    ///      and then records the caller as the pinning Clearinghouse, without a log.
    /// @param underlying 18-dp Stock Token.
    /// @param expiry Expiry, unix seconds.
    function pin(address underlying, uint40 expiry) external; // CLEARINGHOUSE; first series of an expiry

    /// @notice A source's result captured for (underlying, expiry). `sourceIndex` is the market's priority order.
    event SourceRecorded(address indexed underlying, uint40 indexed expiry, uint8 sourceIndex, bool ok, uint256 price);

    /// @notice The price is final. `corroborated` is false when a candidate finalized after its delay.
    event SettlementFinalized(
        address indexed underlying, uint40 indexed expiry, uint256 price, uint8 sourceIndex, bool corroborated
    );

    /// first uncorroborated attempt: the candidate that will finalize after the market's delay unless vetoed
    /// @dev `disagreed` is true when two or more sources were ok but none agreed (as opposed to a single ok source).
    ///      `finalizableAt` = this call's timestamp + the market's uncorroboratedDelay (INTERFACE_VERSION 2).
    event SettlementCandidate(
        address indexed underlying,
        uint40 indexed expiry,
        uint256 price,
        uint8 sourceIndex,
        bool disagreed,
        uint40 finalizableAt
    );

    /// @notice GUARDIAN vetoed the uncorroborated path.
    event SettlementVetoed(address indexed underlying, uint40 indexed expiry);

    /// @notice {unveto} lifted the veto: Held -> Pending; the candidate may finalize from `finalizableAt` (the unveto
    ///         timestamp + the market's uncorroboratedDelay). Added in INTERFACE_VERSION 2.
    event SettlementUnvetoed(address indexed underlying, uint40 indexed expiry, uint40 finalizableAt);

    /// @notice CONFIG_ADMIN resolved the price through {adminResolve}.
    event SettlementResolved(address indexed underlying, uint40 indexed expiry, uint256 price);

    /// @notice The market's source list or its settlement parameters changed (CONFIG_ADMIN, through setMarket).
    event MarketSourcesSet(address indexed underlying);

    /// @notice {pin} fixed the configuration (underlying, expiry) settles on (INTERFACE_VERSION 6). Emitted once per
    ///         (underlying, expiry), before the sources' own pin logs and, normally, the Clearinghouse's SeriesCreated
    ///         in the same transaction. One without a SeriesCreated is a pin made outside a series creation (through a
    ///         Clearinghouse pointer CONFIG_ADMIN moved): no series can be created on it unless it equals the
    ///         configuration current at that creation.
    /// @dev `sources` in priority order (the indexes of SourceRecorded and SettlementCandidate); `maxDeviationBps` in
    ///      basis points; `uncorroboratedDelay` in seconds. Both with defaults filled in.
    event SettlementConfigPinned(
        address indexed underlying,
        uint40 indexed expiry,
        address[] sources,
        uint16 maxDeviationBps,
        uint32 uncorroboratedDelay
    );
}
