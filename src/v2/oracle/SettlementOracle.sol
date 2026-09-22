// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Managed} from "../access/Managed.sol";
import {IClearinghouse} from "../interfaces/IClearinghouse.sol";
import {IKeeperRewards} from "../interfaces/IKeeperRewards.sol";
import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {ISettlementOracle} from "../interfaces/ISettlementOracle.sol";
import {V2Constants} from "../interfaces/V2Constants.sol";
import {V2Errors} from "../interfaces/V2Errors.sol";
import {V2Types} from "../interfaces/V2Types.sol";
import {IOraclePausable} from "./OracleDeps.sol";

/// @title SettlementOracle
/// @notice One settlement price per (underlying, expiry), shared by every strike and both option types: the TWAP of the
///         final SETTLEMENT_WINDOW seconds before expiry, taken from per-market IPriceSource adapters in priority order
///         through ADR-05's fallback chain (corroborated -> uncorroborated candidate with a veto window -> held).
/// @dev UNITS. Prices are USDG base units (6 dp) per whole share (ADR-04); times are unix seconds; deviations are basis
///      points.
///
///      PINNING AT SERIES CREATION (owner decision 2026-09-17, closes C2-16 finding 1). Clearinghouse.createSeries calls
///      {pin} for every series it creates. The first call for an (underlying, expiry) copies the market's source list,
///      maxDeviationBps, uncorroboratedDelay and spotMaxAge (defaults filled in) into that expiry's PINNED
///      CONFIGURATION and asks each source to pin its own configuration of the underlying for the expiry
///      (IPriceSource.pin: the feed, the pool, the stream). Every settlement path of the expiry ({snapshot},
///      {finalize}, {unveto}, {adminResolve}) then reads the pinned copy, never the market's current one, so
///      {setMarket} and the sources' setters reach only expiries no series has pinned yet: the admin cannot add an
///      agreeing source, re-point a feed or pool, empty the list to open {adminResolve} to any price, or change the
///      deviation or the delay of an expiry that has live series. An expiry nobody created a series for is not pinned
///      (unless the admin pinned it outside a series creation, see below) and settles on the current configuration
///      (there is nothing to protect). {spot} is market-level, not
///      settlement: it always reads the current configuration.
///
///      PINNING FAILS CLOSED. A series exists only with the oracle and every source of its expiry pinned: the first
///      {pin} reverts, and with it the creation, when any source's pin fails (V2Errors.SourceNotPinned: the source does
///      not list this oracle, has no configuration for the underlying, holds a different earlier pin, has no code, or
///      answers anything but the IPriceSource.pin selector). A pin made OUTSIDE a series creation (the admin points
///      {clearinghouse}, or a source's allow-list, at an account of its own and pins through it) can never be
///      settled on while the public configuration says something else: the oracle records which Clearinghouse pinned
///      (`pinnedBy`), and a series creation from any other Clearinghouse must confirm the pin, which reverts
///      V2Errors.PinMismatch unless the pinned copy equals the market's current configuration and every pinned source
///      confirms its own pin against its current configuration the same way. The admin's remaining power over
///      pinning is the one it always had and uses in public: choosing the configuration of an expiry that has no
///      series yet (and blocking series creation on an expiry by pre-pinning it with something else).
///
///      RECORDING. The first {finalize} (or {adminResolve}) that finds at least one `ok` source CAPTURES the expiry: it
///      asks every source of the expiry's configuration (the pinned list, else the market's) for
///      `windowPrice(underlying, expiry - SETTLEMENT_WINDOW, expiry)` and stores (source, ok, price) for each, in
///      priority order, emitting {SourceRecorded} per source (ok = false with price 0 for a source that could not
///      answer). From then on:
///        - an ok entry is never read again. ChainlinkFeedSource replays its window from round history that stops being
///          reachable ~94 rounds later, and a price that has been announced must not move;
///        - a not-ok entry is asked again on every later call and upgraded (with another {SourceRecorded}, ok = true)
///          the first time it answers. This is how the pool snapshot, which a keeper records inside
///          [expiry, expiry + SNAPSHOT_GRACE], corroborates a Chainlink price captured at expiry + FINALIZE_DELAY;
///        - the captured SOURCE LIST AND maxDeviationBps stay as captured, so an index in an event always means the same
///          source and a source added after the fact cannot vote on a past window. For a pinned expiry they are the
///          pinned ones; for an expiry without series this capture is the only pinning (the admin's power over a stuck
///          expiry is {adminResolve} after RESOLVE_DELAY, ADR-09).
///      So each source index gets at most one ok {SourceRecorded}, possibly preceded by one with ok = false.
///
///      THE CHAIN, evaluated on the recorded entries by every {finalize} after the refresh above:
///        | recorded state                                        | status before    | result                          |
///        |-------------------------------------------------------|------------------|---------------------------------|
///        | no source ever ok (not captured)                      | any but Final    | (false, 0), nothing stored      |
///        | first ok source i agreeing with another ok source     | any but Final    | Finalized at p_i, corroborated  |
///        |   -- INCLUDING Held: see the note under HELD below    | (Held too)       | Finalized at p_i, corroborated  |
///        | ok source(s), none agreeing: candidate = first ok     | None / Pending   | new or changed candidate:       |
///        |                                                       |                  |   Pending, SettlementCandidate  |
///        |                                                       | Pending          | same candidate, before          |
///        |                                                       |                  |   finalizableAt: (false, 0)     |
///        |                                                       | Pending          | same candidate, at/after        |
///        |                                                       |                  |   finalizableAt: Finalized      |
///        |                                                       | Held             | (false, 0), candidate untouched |
///      "Agree" is symmetric: |p_i - p_j| x 10_000 <= min(p_i, p_j) x maxDeviationBps. The first index in priority order
///      that agrees with ANY other ok source wins, so a disagreeing primary is skipped when two others agree.
///
///      READ THAT LAST ROW WITH ITS BRANCH, NOT ALONE. It belongs to the "ok source(s), NONE AGREEING" row above it
///      and says nothing about a corroborated expiry. T-223 records this because an audit finding read it in
///      isolation, concluded a Held expiry never advances, and from there concluded that a delay-0 GUARDIAN can
///      freeze redemption on a fully corroborated series. That is not what {_advance} does: it tests `corroborated`
///      and finalizes BEFORE it ever reads `Held`. The veto reaches only the uncorroborated path -- which is
///      precisely the single-source settlement the guardian is authorised to veto.
///
///      A CHANGED CANDIDATE RESTARTS THE DELAY. The candidate is (price, sourceIndex, disagreed). When an upgrade changes
///      it (a higher-priority source starts answering, or a second source answers and disagrees), the new candidate is
///      announced with a fresh `finalizableAt`: the guardian's veto window always belongs to the price that will
///      actually settle. Entries only ever go from not ok to ok, so this happens at most once per source.
///
///      HELD. {veto} blocks only the uncorroborated path: corroboration still finalizes a held expiry. While held the
///      stored candidate is not modified, so a {SettlementCandidate} log always describes a Pending expiry and the
///      indexer's candidate is never silently stale. {unveto} restores the path with the delay restarted: always
///      Pending with `finalizableAt = now + uncorroboratedDelay`. The next {finalize} re-evaluates: an unchanged
///      candidate waits for that time; a changed one, or the first one after a pre-emptive veto (a veto before any
///      candidate existed, which the guardian may place even before expiry), is announced with a fresh delay.
///
///      A VETOED SINGLE PRICE WIDENS THE RESOLVE BAND AFTER 7 DAYS (sweep contracts-c12). {adminResolve} is bounded by
///      the recorded ok prices +- the expiry's maxDeviationBps. When only ONE price was ever recorded ok and it is
///      wrong by more than that (a stalled feed or a scale fault inside the jump bound, a pushed pool while the feed
///      was paused), nothing can record another: ok entries are never re-read, the pool snapshot's grace is over, and
///      the pin fixes the sources. The guardian's veto then left only a wrong settlement or collateral held forever.
///      So from `expiry + HELD_RESOLVE_DELAY` (7 days) a HELD expiry with exactly one ok recorded price p resolves
///      inside [p x (10_000 - HELD_RESOLVE_BAND_BPS) / 10_000, p x 10_000 / (10_000 - HELD_RESOLVE_BAND_BPS)], a factor
///      of 1.25 either way with HELD_RESOLVE_BAND_BPS = 2000, the default jump bound: it reaches the true price behind
///      any print that bound lets through. Two or more ok prices keep the pinned band, which already spans them; a
///      Pending (not vetoed) expiry keeps it too. Both values are compiled. This widens the admin's power over such an
///      expiry from +- maxDeviationBps to that factor, only after a public veto and a week.
///
///      THE DELAY IS PINNED INTO THE CANDIDATE. `finalizableAt` is stored when the candidate is announced or unvetoed,
///      with the expiry's uncorroboratedDelay (the pinned one), so a configuration change never moves a timestamp an
///      event already published.
///
///      BOUNTIES (KeeperRewards, optional). {snapshot} pays ACTION_SNAPSHOT when at least one source recorded for the
///      first time in the call; {finalize} pays ACTION_FINALIZE when the call advanced the state (captured, upgraded a
///      source, announced a candidate, or finalized). Both only when both pointers are set, the caller is not the
///      Clearinghouse (its settle finalizes internally and pays its own SETTLE bounty to the real keeper), the expiry
///      is pinned on THIS oracle by the current Clearinghouse (`pinnedBy == clearinghouse`), the caller is not a
///      contract whose pin a later Clearinghouse confirmed, and `clearinghouse.openInterest(underlying, expiry) > 0`,
///      so an empty expiry cannot be farmed. Open interest is the Clearinghouse's per (underlying, expiry), whichever
///      oracle its series settle on, so without the pin check a second oracle sharing the sources during a migration
///      paid bounties on expiries it has no series of; and after a Clearinghouse migration the old Clearinghouse's
///      settle was paid, into a contract that cannot move USDG it did not account for (sweep contracts-c11). The
///      open-interest
///      read and the reward are raw calls whose failure (revert, no code, short data) only means "no bounty": a
///      bounty can never block a settlement. An already final expiry, a repeat call and a call inside the delay pay
///      nothing.
///
///      LOG ORDER of one {finalize}: {SourceRecorded} per captured or upgraded source (priority order), then
///      {SettlementCandidate} or {SettlementFinalized}, then KeeperRewards' USDG `Transfer` and its `Rewarded`. Of the
///      first {pin} of an expiry: {SettlementConfigPinned}, then each source's own pin log in priority order (none for
///      a source that already held an equal pin). A {pin} that confirms another Clearinghouse's pin logs nothing.
///
///      TRUST. Sources, their order and the parameters are CONFIG_ADMIN's (ADR-09), for expiries not pinned yet.
///      INTERFACE_VERSION 8: that role is a `uint64` in the one AccessManager, not a `bytes32` table on this
///      contract -- `script/v2/roles.v8.json` maps each selector here to CONFIG_ADMIN (24 h execution delay),
///      except {veto} and {unveto}, which are GUARDIAN with no delay. `restricted` is the whole gate.
///      Two sources that read the same upstream (two ChainlinkFeedSource instances on one feed) would corroborate each
///      other: configure independent sources only. Duplicate addresses are rejected for exactly that reason. The admin
///      also sets the Clearinghouse pointer {pin} trusts and each source's oracle allow-list, so it can pin an expiry
///      before any series exists (by pointing them at itself). Such a pin is public ({SettlementConfigPinned} without
///      a SeriesCreated, the sources' pin logs, {settlementConfig}, {pinnedBy}), and it can only BLOCK series creation
///      on that expiry, never be settled on in secret: see PINNING FAILS CLOSED. Integrations still show an expiry's
///      pinned configuration rather than the market's.
contract SettlementOracle is ISettlementOracle, Managed, ReentrancyGuardTransient {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Settlement configuration: per underlying ({setMarket}), and per pinned expiry ({pin}, a copy with every
    ///         default filled in, so a pinned copy's uncorroboratedDelay is never 0 and that is its "pinned" mark).
    /// @dev Two slots: the list's length, then the three parameters and `pinnedBy` packed (240 bits).
    struct Market {
        /// @dev IPriceSource adapters, index 0 = highest priority. Index 0 of the market's list also serves {spot}.
        address[] sources;
        /// @dev Basis points. Two ok sources agree when they differ by at most this share of the lower price. 0: unset.
        uint16 maxDeviationBps;
        /// @dev Seconds from a candidate's announcement (or unveto) until it may finalize. 0: unset (not pinned).
        uint32 uncorroboratedDelay;
        /// @dev Seconds. {spot} rejects an observation older than this. 0: unset. Informational in a pinned copy.
        uint32 spotMaxAge;
        /// @dev Pinned copies only: the Clearinghouse whose {pin} made or last confirmed the pin. Always zero in a
        ///      market row.
        address pinnedBy;
    }

    /// @dev Settlement state of one (underlying, expiry). The first slot holds everything but the candidate price.
    struct Settlement {
        V2Types.SettlementStatus status;
        /// @dev Whether the source results were captured (see RECORDING).
        bool captured;
        /// @dev Final price came from corroborating sources.
        bool corroborated;
        /// @dev Final price was set by {adminResolve}.
        bool resolved;
        /// @dev Priority index of the source whose price finalized (0 when resolved).
        uint8 sourceIndex;
        /// @dev USDG base units (6 dp) per share; non-zero once Finalized.
        uint128 price;
        /// @dev Whether a candidate was ever announced.
        bool hasCandidate;
        bool candidateDisagreed;
        uint8 candidateIndex;
        /// @dev Unix seconds from which the candidate may finalize.
        uint40 finalizableAt;
        /// @dev The expiry's maxDeviationBps at capture (the pinned one, else the market's): agreement and the resolve
        ///      band use it.
        uint16 maxDeviationBps;
        /// @dev USDG base units (6 dp) per share.
        uint128 candidatePrice;
    }

    /// @dev One source's captured result for an expiry.
    struct RecordedSource {
        address source;
        bool ok;
        /// @dev USDG base units (6 dp) per share; 0 while not ok.
        uint128 price;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISettlementOracle
    uint32 public constant SETTLEMENT_WINDOW = V2Constants.SETTLEMENT_WINDOW;

    /// @notice maxDeviationBps when unset, and its ceiling (architecture §3.4).
    uint16 public constant DEFAULT_MAX_DEVIATION_BPS = 150;
    uint16 public constant MAX_DEVIATION_CEIL_BPS = 1000;
    /// @notice uncorroboratedDelay when unset, and its bounds, seconds. Never zero: the veto window is the safety.
    uint32 public constant DEFAULT_UNCORROBORATED_DELAY = 6 hours;
    uint32 public constant MIN_UNCORROBORATED_DELAY = 30 minutes;
    uint32 public constant MAX_UNCORROBORATED_DELAY = 24 hours;
    /// @notice spotMaxAge when unset, and its ceiling, seconds.
    uint32 public constant DEFAULT_SPOT_MAX_AGE = 1 hours;
    uint32 public constant MAX_SPOT_MAX_AGE = 4 days;
    /// @notice A source-0 print no older than this is spot on its own; an older one (up to spotMaxAge) needs the
    ///         market's source 1 to agree with it within maxDeviationBps, unless the market has no usable source 1.
    /// @dev OWNER RULING SEC-08b/08c, 2026-09-22 (T-OP-061): "I don't want it to be 25 hours old, it should be accurate;
    ///      ... let's say 30 min". Thirty minutes is the owner's number. It is NOT the whole rule, because a 30-minute
    ///      clock cannot be: the 4663 equity feeds print on a 0.5 % move OR a 24 h heartbeat, so in a quiet half hour
    ///      there is no print and the last one is accurate by the feed's own rule while being hours old. Age is the wrong
    ///      instrument past this bound; AGREEMENT with the on-chain pool is the right one -- the pool moves when the
    ///      market does, so a stale print across a weekend or a holiday is refused the moment the pool disagrees, and a
    ///      quiet session keeps quoting. See {_spot}.
    uint32 public constant SPOT_CORROBORATION_AGE = 30 minutes;
    /// @notice Most sources per market (source indexes are uint8 in the events).
    uint256 public constant MAX_SOURCES = 8;

    /// @dev {adminResolve} of a Held expiry with exactly one ok recorded price uses the wider band from expiry + this
    ///      (see A VETOED SINGLE PRICE WIDENS THE RESOLVE BAND AFTER 7 DAYS).
    uint256 private constant HELD_RESOLVE_DELAY = 7 days;
    /// @dev That band is [p x (BPS - this) / BPS, p x BPS / (BPS - this)]: a factor of 1.25 either way.
    uint256 private constant HELD_RESOLVE_BAND_BPS = 2000;

    /// @dev Largest price accepted from a source: V2Types.Series.settlementPrice is uint128.
    uint256 private constant MAX_PRICE = type(uint128).max;

    /// @dev {_spot} outcomes.
    uint8 private constant SPOT_OK = 0;
    uint8 private constant SPOT_NO_SOURCE = 1;
    uint8 private constant SPOT_STALE = 2;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The Clearinghouse: the only caller of {pin}, read for the open-interest bounty gate, and excluded from
    ///         bounties. Zero: no bounties and no {pin}, so no series can be created on this oracle.
    address public clearinghouse;
    /// @notice KeeperRewards paying SNAPSHOT and FINALIZE bounties. Zero: no bounties.
    address public keeperRewards;

    mapping(address underlying => Market) private _markets;
    /// @dev The configuration {pin} copied for an expiry; `uncorroboratedDelay == 0` means not pinned.
    mapping(address underlying => mapping(uint40 expiry => Market)) private _pinned;
    mapping(address underlying => mapping(uint40 expiry => Settlement)) private _settlements;
    mapping(address underlying => mapping(uint40 expiry => RecordedSource[])) private _recorded;
    /// @dev Every account whose pin of some expiry a later caller of {pin} confirmed (`pinnedBy` moved away from it: a
    ///      Clearinghouse migration, or a pin made outside a series creation). {_payBounty} never pays such a caller
    ///      when it is a contract: an earlier Clearinghouse settling its series.
    mapping(address pinner => bool) private _supersededPinners;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice The full configuration of `underlying` after a {setMarket}, emitted right after {MarketSourcesSet}.
    ///         Deviation in basis points, delay and age in seconds.
    event MarketConfigured(
        address indexed underlying,
        address[] sources,
        uint16 maxDeviationBps,
        uint32 uncorroboratedDelay,
        uint32 spotMaxAge
    );
    /// @notice CONFIG_ADMIN set the Clearinghouse pointer.
    event ClearinghouseSet(address indexed clearinghouse);
    /// @notice CONFIG_ADMIN set the KeeperRewards pointer.
    event KeeperRewardsSet(address indexed keeperRewards);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param authority The `AccessManager` mapping this contract's selectors to roles (V8Roles).
    constructor(address authority) Managed(authority) {}

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the source list and settlement parameters of `underlying`. Emits {MarketSourcesSet} then
    ///         {MarketConfigured}.
    /// @dev CONFIG_ADMIN only (V2Errors.NotAuthorized). A zero parameter means its default. Reverts
    ///      V2Errors.UnsupportedAsset for a zero underlying; V2Errors.CeilingExceeded for more than MAX_SOURCES sources,
    ///      maxDeviationBps above MAX_DEVIATION_CEIL_BPS, a non-zero uncorroboratedDelay outside
    ///      [MIN_UNCORROBORATED_DELAY, MAX_UNCORROBORATED_DELAY], or spotMaxAge above MAX_SPOT_MAX_AGE; V2Errors.NoSource
    ///      for a zero source, a source without code, or a source listed twice (it would corroborate itself). The new
    ///      configuration applies to {spot} at once and to every expiry not pinned by {pin} (no series yet) and not
    ///      captured. Pinned expiries keep their pinned configuration, captured ones their captured sources and
    ///      maxDeviationBps, candidates their `finalizableAt`. An empty list disables {spot}, the unpinned expiries and
    ///      the creation of new series ({pin} reverts NoSource).
    /// @param underlying 18-dp Stock Token.
    /// @param sources IPriceSource adapters in priority order (index 0 also serves {spot}).
    /// @param maxDeviationBps Basis points; 0 = DEFAULT_MAX_DEVIATION_BPS.
    /// @param uncorroboratedDelay Seconds; 0 = DEFAULT_UNCORROBORATED_DELAY.
    /// @param spotMaxAge Seconds; 0 = DEFAULT_SPOT_MAX_AGE.
    function setMarket(
        address underlying,
        address[] calldata sources,
        uint16 maxDeviationBps,
        uint32 uncorroboratedDelay,
        uint32 spotMaxAge
    ) external nonReentrant restricted {
        if (underlying == address(0)) revert V2Errors.UnsupportedAsset();
        uint256 n = sources.length;
        if (n > MAX_SOURCES) revert V2Errors.CeilingExceeded();
        for (uint256 i; i < n; ++i) {
            if (sources[i] == address(0) || sources[i].code.length == 0) revert V2Errors.NoSource();
            for (uint256 j; j < i; ++j) {
                if (sources[j] == sources[i]) revert V2Errors.NoSource();
            }
        }
        if (maxDeviationBps == 0) maxDeviationBps = DEFAULT_MAX_DEVIATION_BPS;
        if (uncorroboratedDelay == 0) uncorroboratedDelay = DEFAULT_UNCORROBORATED_DELAY;
        if (spotMaxAge == 0) spotMaxAge = DEFAULT_SPOT_MAX_AGE;
        if (
            maxDeviationBps > MAX_DEVIATION_CEIL_BPS || uncorroboratedDelay < MIN_UNCORROBORATED_DELAY
                || uncorroboratedDelay > MAX_UNCORROBORATED_DELAY || spotMaxAge > MAX_SPOT_MAX_AGE
        ) revert V2Errors.CeilingExceeded();

        Market storage m = _markets[underlying];
        m.sources = sources;
        m.maxDeviationBps = maxDeviationBps;
        m.uncorroboratedDelay = uncorroboratedDelay;
        m.spotMaxAge = spotMaxAge;
        emit MarketSourcesSet(underlying);
        emit MarketConfigured(underlying, sources, maxDeviationBps, uncorroboratedDelay, spotMaxAge);
    }

    /// @notice Sets the Clearinghouse whose openInterest gates bounties and which alone may call {pin}.
    ///         CONFIG_ADMIN. Zero disables bounties and {pin}, which stops series creation on this oracle.
    /// @dev Deliberately NOT code-checked, unlike {setKeeperRewards} (SEC-31). A code-less pointer here is loud, not
    ///      silent: the real Clearinghouse's {pin} reverts V2Errors.NotAuthorized, so no series can be created, and
    ///      {_payBounty}'s openInterest staticcall answers no data, so it pays nothing (BOUNTIES). Pointing this at an
    ///      account of the admin's own and pre-pinning through it is the documented admin power (PINNING), and a code
    ///      check would not remove it: the same pin goes through a one-function contract. What stays unguarded is a
    ///      mistyped pointer, which halts series creation until someone reads {ClearinghouseSet}.
    /// @param clearinghouse_ The Clearinghouse (the one whose settle calls {finalize} and createSeries calls {pin}).
    function setClearinghouse(address clearinghouse_) external nonReentrant restricted {
        clearinghouse = clearinghouse_;
        emit ClearinghouseSet(clearinghouse_);
    }

    /// @notice Sets the KeeperRewards that pays SNAPSHOT and FINALIZE bounties. CONFIG_ADMIN. Zero disables them.
    /// @dev The KeeperRewards admin must also register this oracle with `setCaller`, or every reward pays 0.
    ///      Reverts V2Errors.NoSource for a non-zero pointer without code (SEC-31): the reward is a raw call whose
    ///      failure only means "no bounty" (BOUNTIES), so a code-less pointer would disable every bounty with no revert
    ///      and no log saying so. Zero is the one way to disable them, and it says what it does. Mirrors
    ///      Clearinghouse.setKeeperRewards.
    /// @param keeperRewards_ KeeperRewards contract, or address(0) to pay nothing.
    function setKeeperRewards(address keeperRewards_) external nonReentrant restricted {
        if (keeperRewards_ != address(0) && keeperRewards_.code.length == 0) revert V2Errors.NoSource();
        keeperRewards = keeperRewards_;
        emit KeeperRewardsSet(keeperRewards_);
    }

    /*//////////////////////////////////////////////////////////////
                                 PINNING
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISettlementOracle
    /// @dev See PINNING and PINNING FAILS CLOSED on the contract. Checks the caller first (V2Errors.NotAuthorized unless
    ///      it is {clearinghouse}), then:
    ///        - pinned by this caller: returns at once, after one read of the slot that holds `pinnedBy` with the
    ///          parameters (every later series of the expiry: docs/V2-GAS.md);
    ///        - pinned by another caller: V2Errors.PinMismatch unless the pinned list, maxDeviationBps,
    ///          uncorroboratedDelay and spotMaxAge equal the market's current ones; then marks the previous
    ///          `pinnedBy` as superseded (never paid a bounty while it is a contract, see BOUNTIES), records this caller
    ///          as `pinnedBy` and asks every pinned source to pin again, which each source accepts only when its own
    ///          pin equals its current configuration;
    ///        - not pinned: V2Errors.NoSource on an empty market; stores the copy with `pinnedBy`, emits
    ///          {SettlementConfigPinned}, and asks every source to pin.
    ///      State first, source calls last (CEI; the guard is held, so a source cannot re-enter a state change). Any
    ///      source failure reverts the whole call with V2Errors.SourceNotPinned (see {_pinSource}), so no gas limit can
    ///      leave a source unpinned under a created series: a source starved of gas fails like any other, and the
    ///      1/64 of the gas EIP-150 leaves this frame either reverts with the error or runs out itself.
    function pin(address underlying, uint40 expiry) external nonReentrant {
        if (msg.sender != clearinghouse) revert V2Errors.NotAuthorized();
        Market storage p = _pinned[underlying][expiry];
        // `pinnedBy` is set exactly when the expiry is pinned, and msg.sender is never zero.
        if (p.pinnedBy == msg.sender) return;
        address[] memory sources;
        if (p.uncorroboratedDelay != 0) {
            if (!_sameConfig(p, _markets[underlying])) revert V2Errors.PinMismatch();
            _supersededPinners[p.pinnedBy] = true;
            p.pinnedBy = msg.sender;
            sources = p.sources;
        } else {
            Market storage m = _markets[underlying];
            sources = m.sources;
            if (sources.length == 0) revert V2Errors.NoSource();
            uint16 dev = _maxDeviationBps(m);
            uint32 delay = _uncorroboratedDelay(m);
            p.sources = sources;
            p.maxDeviationBps = dev;
            p.uncorroboratedDelay = delay;
            p.spotMaxAge = _spotMaxAge(m);
            p.pinnedBy = msg.sender;
            emit SettlementConfigPinned(underlying, expiry, sources, dev, delay);
        }

        bytes memory data = abi.encodeCall(IPriceSource.pin, (underlying, expiry));
        for (uint256 i; i < sources.length; ++i) {
            _pinSource(sources[i], data);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  SPOT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISettlementOracle
    /// @dev Reverts V2Errors.NoSource when the market has no source, the token's `oraclePaused()` is true or cannot be
    ///      read (fail closed), or source 0's `latest` is not ok, malformed, 0, above 2^128 or stamped in the future;
    ///      V2Errors.StaleSpot(updatedAt) when `now - updatedAt > spotMaxAge`, or when the print is older than
    ///      SPOT_CORROBORATION_AGE and the market's source 1 is ok but disagrees with it by more than maxDeviationBps
    ///      (an old print the market has moved away from is stale in the sense that matters, whatever the clock says).
    ///      Exactly spotMaxAge old is fresh. A print older than spotMaxAge is still ok when source 1 is ok and agrees with
    ///      it, up to the compiled MAX_SPOT_MAX_AGE (4 days): the corroborated path has its own ceiling (T-OP-087), the
    ///      uncorroborated one keeps spotMaxAge. Reads the market's current source list, maxDeviationBps and spotMaxAge,
    ///      never a pinned copy: spot prices no settlement. The three-step rule is in {_spot}.
    function spot(address underlying) external view returns (uint256 price, uint256 updatedAt) {
        uint8 status;
        (status, price, updatedAt) = _spot(underlying);
        if (status == SPOT_NO_SOURCE) revert V2Errors.NoSource();
        if (status == SPOT_STALE) revert V2Errors.StaleSpot(updatedAt);
    }

    /// @inheritdoc ISettlementOracle
    /// @dev All zero when not ok.
    function trySpot(address underlying) external view returns (bool ok, uint256 price, uint256 updatedAt) {
        (uint8 status, uint256 p, uint256 t) = _spot(underlying);
        if (status != SPOT_OK) return (false, 0, 0);
        return (true, p, t);
    }

    /*//////////////////////////////////////////////////////////////
                               SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISettlementOracle
    /// @dev Reverts V2Errors.TooEarly(expiry) before `expiry` (UniV3TwapSource.record would). Returns 0 without calling
    ///      any source once the expiry is Finalized. Calls the captured sources once captured, else the expiry's
    ///      pinned list, else (no series ever pinned it) the market's current list.
    ///      Each `record` is a raw call: a source that reverts, re-enters, or answers malformed data counts as not
    ///      recorded and cannot stop the others. There is no state of this contract to update, so the bounty is the only
    ///      interaction after the loop.
    function snapshot(address underlying, uint40 expiry) external nonReentrant returns (uint8 newlyRecorded) {
        if (block.timestamp < expiry) revert V2Errors.TooEarly(expiry);
        if (_settlements[underlying][expiry].status == V2Types.SettlementStatus.Finalized) return 0;
        address[] memory sources = _sourcesFor(underlying, expiry);
        for (uint256 i; i < sources.length; ++i) {
            (bool success, bytes memory ret) =
                sources[i].call(abi.encodeCall(IPriceSource.record, (underlying, expiry)));
            if (success && ret.length >= 32 && abi.decode(ret, (uint256)) == 1) ++newlyRecorded;
        }
        if (newlyRecorded != 0) _payBounty(underlying, expiry, V2Constants.ACTION_SNAPSHOT);
    }

    /// @inheritdoc ISettlementOracle
    /// @dev See the contract NatSpec for the recording rules, the chain and the bounty. Reverts only
    ///      V2Errors.TooEarly(expiry + FINALIZE_DELAY). The source reads are STATICCALLs (they cannot re-enter a state
    ///      change), so reading and recording per source is safe; the bounty is the last interaction.
    function finalize(address underlying, uint40 expiry) external nonReentrant returns (bool finalized, uint256 price) {
        _requireNotBefore(uint256(expiry) + V2Constants.FINALIZE_DELAY);
        Settlement storage s = _settlements[underlying][expiry];
        if (s.status == V2Types.SettlementStatus.Finalized) return (true, s.price);

        bool advanced = _refresh(underlying, expiry, s);
        if (s.captured && _advance(underlying, expiry, s)) advanced = true;
        if (advanced) _payBounty(underlying, expiry, V2Constants.ACTION_FINALIZE);

        if (s.status == V2Types.SettlementStatus.Finalized) return (true, s.price);
        return (false, 0);
    }

    /// @inheritdoc ISettlementOracle
    /// @dev A veto of an already Held expiry is a no-op without an event. Allowed at any time before finalization,
    ///      including before expiry (a pre-emptive veto).
    function veto(address underlying, uint40 expiry) external nonReentrant restricted {
        Settlement storage s = _settlements[underlying][expiry];
        if (s.status == V2Types.SettlementStatus.Finalized) revert V2Errors.AlreadyFinal();
        if (s.status == V2Types.SettlementStatus.Held) return;
        s.status = V2Types.SettlementStatus.Held;
        emit SettlementVetoed(underlying, expiry);
    }

    /// @inheritdoc ISettlementOracle
    /// @dev Reverts V2Errors.AlreadyFinal once Finalized; a no-op without an event unless Held. Otherwise always Held ->
    ///      Pending with `finalizableAt = now + uncorroboratedDelay` (the expiry's: pinned, else the market's) stored
    ///      and emitted. After a pre-emptive veto (no
    ///      candidate was ever announced) {candidate} stays all zero and the next {finalize} that finds an ok source
    ///      announces one with its own `now + uncorroboratedDelay`, which is never earlier than the unveto's: the
    ///      emitted value is then a lower bound, and nothing can finalize uncorroborated before it.
    function unveto(address underlying, uint40 expiry) external nonReentrant restricted {
        Settlement storage s = _settlements[underlying][expiry];
        if (s.status == V2Types.SettlementStatus.Finalized) revert V2Errors.AlreadyFinal();
        if (s.status != V2Types.SettlementStatus.Held) return;
        uint40 at = _nowPlus(_uncorroboratedDelay(_configOf(underlying, expiry)));
        s.finalizableAt = at;
        s.status = V2Types.SettlementStatus.Pending;
        emit SettlementUnvetoed(underlying, expiry, at);
    }

    /// @inheritdoc ISettlementOracle
    /// @dev Also V2Errors.BadPrice for a price of 0 or above 2^128. Before checking the band it refreshes the recording
    ///      exactly as {finalize} does (capture, or upgrade entries that were not ok), so the band cannot be skipped by
    ///      resolving an expiry nobody finalized; it does not evaluate the chain. The band is
    ///      [min ok price x (10_000 - maxDeviationBps) / 10_000, max ok price x (10_000 + maxDeviationBps) / 10_000]
    ///      with the maxDeviationBps pinned at capture, both floored, inclusive; with no ok recorded price any price is
    ///      accepted. From expiry + 7 days, a Held expiry with exactly one ok recorded price p (counted after the
    ///      refresh) uses [p x 8_000 / 10_000, p x 10_000 / 8_000] instead, both floored, inclusive (see A VETOED
    ///      SINGLE PRICE WIDENS THE RESOLVE BAND AFTER 7 DAYS). The capture reads the expiry's pinned sources, so emptying or changing the market's list does not
    ///      make a pinned expiry unbounded. Works from None, Pending or Held.
    function adminResolve(address underlying, uint40 expiry, uint256 price) external nonReentrant restricted {
        _requireNotBefore(uint256(expiry) + V2Constants.RESOLVE_DELAY);
        Settlement storage s = _settlements[underlying][expiry];
        if (s.status == V2Types.SettlementStatus.Finalized) revert V2Errors.AlreadyFinal();
        if (price == 0 || price > MAX_PRICE) revert V2Errors.BadPrice();
        _refresh(underlying, expiry, s);
        (bool bounded, uint256 lo, uint256 hi) = _band(underlying, expiry);
        if (bounded && (price < lo || price > hi)) revert V2Errors.ResolveOutOfBand(lo, hi);

        s.status = V2Types.SettlementStatus.Finalized;
        // casting to 'uint128' is safe because price <= MAX_PRICE (checked above)
        // forge-lint: disable-next-line(unsafe-typecast)
        s.price = uint128(price);
        s.resolved = true;
        emit SettlementResolved(underlying, expiry, price);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISettlementOracle
    function settlementPrice(address underlying, uint40 expiry)
        external
        view
        returns (V2Types.SettlementStatus status, uint256 price)
    {
        Settlement storage s = _settlements[underlying][expiry];
        status = s.status;
        if (status == V2Types.SettlementStatus.Finalized) price = s.price;
    }

    /// @inheritdoc ISettlementOracle
    /// @dev All zero until a {SettlementCandidate} was emitted, including after an {unveto} of a pre-emptive veto. While
    ///      Held, the values are the last announced candidate (its `finalizableAt` no longer applies until {unveto}
    ///      moves it). After finalization, the last candidate stays readable.
    function candidate(address underlying, uint40 expiry)
        external
        view
        returns (uint256 price, uint8 sourceIndex, bool disagreed, uint40 finalizableAt)
    {
        Settlement storage s = _settlements[underlying][expiry];
        if (!s.hasCandidate) return (0, 0, false, 0);
        return (s.candidatePrice, s.candidateIndex, s.candidateDisagreed, s.finalizableAt);
    }

    /// @notice Everything stored about the settlement of (underlying, expiry) except the candidate.
    /// @param underlying 18-dp Stock Token.
    /// @param expiry Expiry, unix seconds.
    /// @return status None, Pending, Finalized or Held.
    /// @return price USDG base units (6 dp) per share when Finalized, else 0.
    /// @return sourceIndex Priority index of the finalizing source (0 when resolved or not final).
    /// @return corroborated True when final through corroborating sources.
    /// @return resolved True when final through {adminResolve}.
    /// @return captured True once source results were captured.
    function settlementInfo(address underlying, uint40 expiry)
        external
        view
        returns (
            V2Types.SettlementStatus status,
            uint256 price,
            uint8 sourceIndex,
            bool corroborated,
            bool resolved,
            bool captured
        )
    {
        Settlement storage s = _settlements[underlying][expiry];
        return (s.status, s.price, s.sourceIndex, s.corroborated, s.resolved, s.captured);
    }

    /// @notice The captured source results of (underlying, expiry), in priority order. Empty until captured.
    /// @param underlying 18-dp Stock Token.
    /// @param expiry Expiry, unix seconds.
    /// @return sources The pinned IPriceSource adapters.
    /// @return ok Whether each has answered.
    /// @return prices USDG base units (6 dp) per share; 0 while not ok.
    /// @return maxDeviationBps The market's maxDeviationBps pinned at capture, basis points; 0 until captured.
    function recordedSources(address underlying, uint40 expiry)
        external
        view
        returns (address[] memory sources, bool[] memory ok, uint256[] memory prices, uint16 maxDeviationBps)
    {
        maxDeviationBps = _settlements[underlying][expiry].maxDeviationBps;
        RecordedSource[] storage rec = _recorded[underlying][expiry];
        uint256 n = rec.length;
        sources = new address[](n);
        ok = new bool[](n);
        prices = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            (sources[i], ok[i], prices[i]) = (rec[i].source, rec[i].ok, rec[i].price);
        }
    }

    /// @notice The {adminResolve} band as recorded now, at the current status and time (without the refresh
    ///         {adminResolve} performs first).
    /// @param underlying 18-dp Stock Token.
    /// @param expiry Expiry, unix seconds.
    /// @return bounded False when no recorded source is ok (any price is accepted).
    /// @return lo Lowest accepted price, USDG base units (6 dp) per share.
    /// @return hi Highest accepted price, USDG base units (6 dp) per share.
    function resolveBand(address underlying, uint40 expiry)
        external
        view
        returns (bool bounded, uint256 lo, uint256 hi)
    {
        return _band(underlying, expiry);
    }

    /// @notice The current configuration of `underlying`, with defaults filled in for a market never configured. It
    ///         governs {spot} and every expiry not pinned yet; {settlementConfig} is what a given expiry settles on.
    /// @param underlying 18-dp Stock Token.
    /// @return sources IPriceSource adapters in priority order.
    /// @return maxDeviationBps Basis points.
    /// @return uncorroboratedDelay Seconds.
    /// @return spotMaxAge Seconds.
    function marketConfig(address underlying)
        external
        view
        returns (address[] memory sources, uint16 maxDeviationBps, uint32 uncorroboratedDelay, uint32 spotMaxAge)
    {
        Market storage m = _markets[underlying];
        return (m.sources, _maxDeviationBps(m), _uncorroboratedDelay(m), _spotMaxAge(m));
    }

    /// @notice The configuration (underlying, expiry) settles on: the copy {pin} stored when its first series was
    ///         created, or, while no series pinned it, the market's current configuration (which may still change).
    /// @dev Anyone. What a front end should show next to a series. Once captured, {recordedSources} holds the source
    ///      list and deviation actually in use (the same as the pinned ones for a pinned expiry).
    /// @param underlying 18-dp Stock Token.
    /// @param expiry Expiry, unix seconds.
    /// @return pinned True once {pin} ran for the expiry: the values below can no longer change.
    /// @return sources IPriceSource adapters in priority order.
    /// @return maxDeviationBps Basis points.
    /// @return uncorroboratedDelay Seconds.
    /// @return spotMaxAge Seconds (a pinned copy's is informational: {spot} reads the market's).
    function settlementConfig(address underlying, uint40 expiry)
        external
        view
        returns (
            bool pinned,
            address[] memory sources,
            uint16 maxDeviationBps,
            uint32 uncorroboratedDelay,
            uint32 spotMaxAge
        )
    {
        Market storage m = _configOf(underlying, expiry);
        return (
            _pinned[underlying][expiry].uncorroboratedDelay != 0,
            m.sources,
            _maxDeviationBps(m),
            _uncorroboratedDelay(m),
            _spotMaxAge(m)
        );
    }

    /// @notice The Clearinghouse whose {pin} pinned (underlying, expiry), or last confirmed its pin; zero while the
    ///         expiry is not pinned. Added in INTERFACE_VERSION 6.
    /// @dev Anyone. When it is not the current {clearinghouse}, the pin was made through an earlier pointer (a
    ///      Clearinghouse migration, or a pin made before any series): the next series of the expiry must confirm it
    ///      against the current configuration, and cannot be created while they differ (V2Errors.PinMismatch).
    /// @param underlying 18-dp Stock Token.
    /// @param expiry Expiry, unix seconds.
    /// @return The pinning Clearinghouse.
    function pinnedBy(address underlying, uint40 expiry) external view returns (address) {
        return _pinned[underlying][expiry].pinnedBy;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Capture (first time any source is ok) or upgrade not-ok entries. Returns whether anything was stored.
    function _refresh(address underlying, uint40 expiry, Settlement storage s) private returns (bool changed) {
        RecordedSource[] storage rec = _recorded[underlying][expiry];
        if (s.captured) {
            uint256 m = rec.length;
            for (uint256 i; i < m; ++i) {
                if (rec[i].ok) continue;
                (bool upgraded, uint256 p) = _windowPrice(rec[i].source, underlying, expiry);
                if (!upgraded) continue;
                rec[i].ok = true;
                // casting to 'uint128' is safe because _windowPrice reports ok only for p <= MAX_PRICE
                // forge-lint: disable-next-line(unsafe-typecast)
                rec[i].price = uint128(p);
                // casting to 'uint8' is safe because a market holds at most MAX_SOURCES sources
                // forge-lint: disable-next-line(unsafe-typecast)
                emit SourceRecorded(underlying, expiry, uint8(i), true, p);
                changed = true;
            }
            return changed;
        }

        Market storage cfg = _configOf(underlying, expiry);
        address[] memory sources = cfg.sources;
        uint256 n = sources.length;
        bool[] memory oks = new bool[](n);
        uint256[] memory prices = new uint256[](n);
        bool any;
        for (uint256 i; i < n; ++i) {
            (oks[i], prices[i]) = _windowPrice(sources[i], underlying, expiry);
            if (oks[i]) any = true;
        }
        if (!any) return false;

        s.captured = true;
        s.maxDeviationBps = _maxDeviationBps(cfg);
        for (uint256 i; i < n; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            rec.push(RecordedSource({source: sources[i], ok: oks[i], price: uint128(prices[i])}));
            // forge-lint: disable-next-line(unsafe-typecast)
            emit SourceRecorded(underlying, expiry, uint8(i), oks[i], prices[i]);
        }
        return true;
    }

    /// @dev One step of the chain on a captured expiry (see the table on the contract). Returns whether it changed state.
    function _advance(address underlying, uint40 expiry, Settlement storage s) private returns (bool) {
        (uint256 okCount, bool corroborated, uint8 index, uint256 p) =
            _evaluate(_recorded[underlying][expiry], s.maxDeviationBps);
        if (corroborated) {
            _finalize(underlying, expiry, s, index, p, true);
            return true;
        }
        if (s.status == V2Types.SettlementStatus.Held) return false;

        bool disagreed = okCount > 1;
        if (!s.hasCandidate || s.candidateIndex != index || s.candidatePrice != p || s.candidateDisagreed != disagreed)
        {
            uint40 at = _nowPlus(_uncorroboratedDelay(_configOf(underlying, expiry)));
            s.status = V2Types.SettlementStatus.Pending;
            s.hasCandidate = true;
            s.candidateDisagreed = disagreed;
            s.candidateIndex = index;
            s.finalizableAt = at;
            // casting to 'uint128' is safe because recorded prices are uint128
            // forge-lint: disable-next-line(unsafe-typecast)
            s.candidatePrice = uint128(p);
            emit SettlementCandidate(underlying, expiry, p, index, disagreed, at);
            return true;
        }
        if (block.timestamp < s.finalizableAt) return false;
        _finalize(underlying, expiry, s, index, p, false);
        return true;
    }

    /// @dev Stores the final price and emits {SettlementFinalized}.
    function _finalize(
        address underlying,
        uint40 expiry,
        Settlement storage s,
        uint8 index,
        uint256 p,
        bool corroborated
    ) private {
        s.status = V2Types.SettlementStatus.Finalized;
        // casting to 'uint128' is safe because recorded prices are uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        s.price = uint128(p);
        s.sourceIndex = index;
        s.corroborated = corroborated;
        emit SettlementFinalized(underlying, expiry, p, index, corroborated);
    }

    /// @dev The chain's inputs from the recorded entries. `index`/`price` are the first source (priority order) that
    ///      agrees with another ok source when `corroborated`, else the first ok source (undefined when okCount == 0).
    function _evaluate(RecordedSource[] storage rec, uint256 maxDeviationBps)
        private
        view
        returns (uint256 okCount, bool corroborated, uint8 index, uint256 price)
    {
        uint256 n = rec.length;
        bool[] memory ok = new bool[](n);
        uint256[] memory prices = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ok[i] = rec[i].ok;
            prices[i] = rec[i].price;
            if (!ok[i]) continue;
            if (okCount == 0) {
                // forge-lint: disable-next-line(unsafe-typecast)
                (index, price) = (uint8(i), prices[i]);
            }
            ++okCount;
        }
        for (uint256 i; i < n; ++i) {
            if (!ok[i]) continue;
            for (uint256 j; j < n; ++j) {
                if (j == i || !ok[j]) continue;
                // forge-lint: disable-next-line(unsafe-typecast)
                if (_agree(prices[i], prices[j], maxDeviationBps)) return (okCount, true, uint8(i), prices[i]);
            }
        }
    }

    /// @dev |a - b| x BPS <= min(a, b) x maxDeviationBps. Prices < 2^128 and bps <= 1000: no overflow.
    function _agree(uint256 a, uint256 b, uint256 maxDeviationBps) private pure returns (bool) {
        (uint256 lo, uint256 hi) = a < b ? (a, b) : (b, a);
        return (hi - lo) * V2Constants.BPS <= lo * maxDeviationBps;
    }

    /// @dev The {adminResolve} band from the recorded ok prices and the deviation pinned at capture (recorded entries
    ///      exist only once captured, so the pinned value is always set when the band is bounded), or, for a Held
    ///      expiry with exactly one ok price from expiry + HELD_RESOLVE_DELAY, the wider band around that price.
    function _band(address underlying, uint40 expiry) private view returns (bool bounded, uint256 lo, uint256 hi) {
        RecordedSource[] storage rec = _recorded[underlying][expiry];
        uint256 minP = type(uint256).max;
        uint256 maxP;
        uint256 okCount;
        for (uint256 i; i < rec.length; ++i) {
            if (!rec[i].ok) continue;
            ++okCount;
            uint256 p = rec[i].price;
            if (p < minP) minP = p;
            if (p > maxP) maxP = p;
        }
        if (okCount == 0) return (false, 0, 0);
        Settlement storage s = _settlements[underlying][expiry];
        if (
            okCount == 1 && s.status == V2Types.SettlementStatus.Held
                && block.timestamp >= uint256(expiry) + HELD_RESOLVE_DELAY
        ) {
            uint256 keep = V2Constants.BPS - HELD_RESOLVE_BAND_BPS;
            return (true, minP * keep / V2Constants.BPS, maxP * V2Constants.BPS / keep);
        }
        uint256 dev = s.maxDeviationBps;
        bounded = true;
        lo = minP * (V2Constants.BPS - dev) / V2Constants.BPS;
        hi = maxP * (V2Constants.BPS + dev) / V2Constants.BPS;
    }

    /// @dev One source's window price for `expiry`, never reverting: a raw STATICCALL whose reply must be two words, the
    ///      first exactly 1, the second in (0, MAX_PRICE]. An expiry inside the first SETTLEMENT_WINDOW seconds of unix
    ///      time has no window.
    function _windowPrice(address source, address underlying, uint40 expiry)
        private
        view
        returns (bool ok, uint256 price)
    {
        if (expiry < SETTLEMENT_WINDOW) return (false, 0);
        (bool success, bytes memory ret) = source.staticcall(
            abi.encodeCall(IPriceSource.windowPrice, (underlying, expiry - SETTLEMENT_WINDOW, expiry))
        );
        if (!success || ret.length < 64) return (false, 0);
        (uint256 okWord, uint256 p) = abi.decode(ret, (uint256, uint256));
        if (okWord != 1 || p == 0 || p > MAX_PRICE) return (false, 0);
        return (true, p);
    }

    /// @dev {spot} without reverting: the status code, and the observation when it is ok or merely stale. Market-level:
    ///      the current configuration, never a pinned one.
    ///
    ///      THE PRICE IS ALWAYS SOURCE 0's (SEC-09: the pool is manipulable on thin liquidity and its freshness is
    ///      vacuous, so Chainlink is the source and the pool is only ever a WITNESS). Three steps, in order:
    ///        1. the print is at most SPOT_CORROBORATION_AGE old: ok, as before -- a print younger than the owner's bound
    ///           needs no witness;
    ///        2. else, the market has a source 1 whose `latest` is ok: ok iff source 1 AGREES with the print within the
    ///           market's own maxDeviationBps (the same {_agree} settlement corroboration uses; one band, not a wider
    ///           one), and STALE otherwise -- the market has moved and the print has not. The answer is still source
    ///           0's print and timestamp, now corroborated;
    ///        3. else (single-source market, or source 1 not ok): ok iff the print is at most spotMaxAge old -- the rule
    ///           every market had before T-OP-061, unchanged for the single-source ones and for a dual-source market
    ///           whose pool is down.
    ///      TWO CEILINGS, NOT ONE (T-OP-087). The corroborated path (step 2) is bounded by the COMPILED ceiling
    ///      MAX_SPOT_MAX_AGE (4 days), not by the market's spotMaxAge; the uncorroborated path (step 3) keeps
    ///      spotMaxAge. T-OP-061 first put spotMaxAge ahead of step 2 as "the outer bound in every step", and with the
    ///      live rows' 90,000 s (25 h) a Friday print was StaleSpot all weekend (~65.5 h) whatever the pool said -- so
    ///      the owner's SEC-21c weekend ruling ("use the live pool price on a weekend", T-OP-066's unwind) and the
    ///      after-close launch case both died on the outer bound the moment the print was a day old. The 4-day cap is
    ///      the registry validator's own ceiling for spotMaxAgeS, a weekend plus a Monday holiday is ~89 h < 96 h, and
    ///      it is what stops a months-old print passing on a coincidental agreement. Widening spotMaxAgeS in the
    ///      registry instead would have widened the UNCORROBORATED window for every consumer, reversing owner sign-off
    ///      c01 (DECISIONS-2026-09-17 s7); the code keeps 25 h for that case, which is what c01 protects.
    ///      So, with the live rows: at a launch after the close, or on Sunday, the last print is accepted while the pool
    ///      agrees with it and refused once the pool says the market moved; at the open a gap the pool follows refuses
    ///      the stale print until the feed's 0.5 % rule prints; a quiet session keeps quoting; a dual-source market
    ///      whose pool is down falls back to the 25 h clock.
    function _spot(address underlying) private view returns (uint8 status, uint256 price, uint256 updatedAt) {
        Market storage m = _markets[underlying];
        address[] storage sources = m.sources;
        if (sources.length == 0 || _oraclePaused(underlying)) return (SPOT_NO_SOURCE, 0, 0);
        (bool ok, uint256 p, uint256 t) = _latestOf(sources[0], underlying);
        if (!ok) return (SPOT_NO_SOURCE, 0, 0);
        uint256 age = block.timestamp - t;
        if (age <= SPOT_CORROBORATION_AGE) return (SPOT_OK, p, t);
        if (sources.length > 1 && age <= MAX_SPOT_MAX_AGE) {
            (bool ok1, uint256 p1,) = _latestOf(sources[1], underlying);
            if (ok1) return (_agree(p, p1, _maxDeviationBps(m)) ? SPOT_OK : SPOT_STALE, p, t);
        }
        if (age > _spotMaxAge(m)) return (SPOT_STALE, p, t);
        return (SPOT_OK, p, t);
    }

    /// @dev `source.latest(underlying)` as a staticcall, decoded by hand so a revert, short data, a dirty ok word, a zero
    ///      or over-range price or a future timestamp all read as "not ok" rather than reverting the caller. A future
    ///      timestamp is refused here, not clamped, so `block.timestamp - t` in {_spot} cannot underflow.
    function _latestOf(address source, address underlying) private view returns (bool ok, uint256 p, uint256 t) {
        (bool success, bytes memory ret) = source.staticcall(abi.encodeCall(IPriceSource.latest, (underlying)));
        if (!success || ret.length < 96) return (false, 0, 0);
        uint256 okWord;
        (okWord, p, t) = abi.decode(ret, (uint256, uint256, uint256));
        if (okWord != 1 || p == 0 || p > MAX_PRICE || t > block.timestamp) return (false, 0, 0);
        return (true, p, t);
    }

    /// @dev The configuration (underlying, expiry) settles on: the pinned copy once {pin} ran, else the market's
    ///      current one (whose zero parameters mean their defaults; the pinned copy has them filled in).
    function _configOf(address underlying, uint40 expiry) private view returns (Market storage m) {
        m = _pinned[underlying][expiry];
        if (m.uncorroboratedDelay == 0) m = _markets[underlying];
    }

    /// @dev `source.pin(...)` (see {pin}) as a raw call, so every way a source can fail ends in one clear error:
    ///      V2Errors.SourceNotPinned(source, first four bytes of its revert data or zero) unless the call succeeded AND
    ///      answered exactly one ABI word holding the IPriceSource.pin selector. An account without code "succeeds"
    ///      with no data, so it fails the answer check ({setMarket} refuses one, but its code could be gone by now).
    function _pinSource(address source, bytes memory data) private {
        (bool success, bytes memory ret) = source.call(data);
        if (success && ret.length == 32 && bytes32(ret) == bytes32(IPriceSource.pin.selector)) return;
        bytes4 reason;
        if (!success && ret.length >= 4) reason = bytes4(ret);
        revert V2Errors.SourceNotPinned(source, reason);
    }

    /// @dev Whether a pinned copy equals a market's current configuration (defaults filled in on the market side; the
    ///      copy has them filled in already): the same list in the same order and the same three parameters.
    function _sameConfig(Market storage p, Market storage m) private view returns (bool) {
        if (
            p.maxDeviationBps != _maxDeviationBps(m) || p.uncorroboratedDelay != _uncorroboratedDelay(m)
                || p.spotMaxAge != _spotMaxAge(m)
        ) return false;
        address[] storage a = p.sources;
        address[] storage b = m.sources;
        uint256 n = a.length;
        if (b.length != n) return false;
        for (uint256 i; i < n; ++i) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    /// @dev The sources {snapshot} calls: the captured list once captured, else the expiry's configuration.
    function _sourcesFor(address underlying, uint40 expiry) private view returns (address[] memory sources) {
        if (!_settlements[underlying][expiry].captured) return _configOf(underlying, expiry).sources;
        RecordedSource[] storage rec = _recorded[underlying][expiry];
        sources = new address[](rec.length);
        for (uint256 i; i < rec.length; ++i) {
            sources[i] = rec[i].source;
        }
    }

    /// @dev Pays `msg.sender` the `action` bounty when eligible (see BOUNTIES on the contract). Every failure is silent.
    function _payBounty(address underlying, uint40 expiry, bytes32 action) private {
        address ch = clearinghouse;
        address rewards = keeperRewards;
        if (ch == address(0) || rewards == address(0) || msg.sender == ch) return;
        // Only an expiry the current Clearinghouse pinned or confirmed here has series on this oracle to advance; and
        // an earlier Clearinghouse (a contract whose pin a later one confirmed) is never paid. The code-size check
        // keeps the mapping read off an ordinary keeper's path.
        if (_pinned[underlying][expiry].pinnedBy != ch) return;
        if (msg.sender.code.length != 0 && _supersededPinners[msg.sender]) return;
        (bool success, bytes memory ret) =
            ch.staticcall(abi.encodeCall(IClearinghouse.openInterest, (underlying, expiry)));
        if (!success || ret.length < 32 || abi.decode(ret, (uint256)) == 0) return;
        // The try/catch of the spec as a raw call: a typed call to an address without code, or one answering short
        // data, would revert here while decoding, where try/catch cannot catch it. The result is not needed.
        (success,) = rewards.call(abi.encodeCall(IKeeperRewards.reward, (msg.sender, action)));
    }

    /// @dev The issuer's oracle halt flag, read now. Fails closed like ChainlinkFeedSource: a failed or short read counts
    ///      as paused.
    function _oraclePaused(address underlying) private view returns (bool) {
        (bool success, bytes memory ret) = underlying.staticcall(abi.encodeCall(IOraclePausable.oraclePaused, ()));
        if (!success || ret.length < 32) return true;
        return abi.decode(ret, (uint256)) != 0;
    }

    function _maxDeviationBps(Market storage m) private view returns (uint16) {
        uint16 v = m.maxDeviationBps;
        return v == 0 ? DEFAULT_MAX_DEVIATION_BPS : v;
    }

    /// @dev Never zero, even for a market never configured: the veto window is the safety.
    function _uncorroboratedDelay(Market storage m) private view returns (uint32) {
        uint32 v = m.uncorroboratedDelay;
        return v == 0 ? DEFAULT_UNCORROBORATED_DELAY : v;
    }

    function _spotMaxAge(Market storage m) private view returns (uint32) {
        uint32 v = m.spotMaxAge;
        return v == 0 ? DEFAULT_SPOT_MAX_AGE : v;
    }

    /// @dev `block.timestamp + delay` as uint40 (a unix time below 2^40 until the year 36812).
    function _nowPlus(uint32 delay) private view returns (uint40) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint40(block.timestamp + delay);
    }

    /// @dev Reverts V2Errors.TooEarly(notBefore) while `now < notBefore` (clamped to uint40 for the error).
    function _requireNotBefore(uint256 notBefore) private view {
        if (block.timestamp >= notBefore) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        revert V2Errors.TooEarly(notBefore > type(uint40).max ? type(uint40).max : uint40(notBefore));
    }
}
