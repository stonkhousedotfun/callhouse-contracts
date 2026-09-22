// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Managed} from "../access/Managed.sol";
import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {V2Constants} from "../interfaces/V2Constants.sol";
import {V2Errors} from "../interfaces/V2Errors.sol";
import {IOraclePausable} from "./OracleDeps.sol";
import {DataStreamsReportV11, IDataStreamsVerifierProxy, IUiMultiplier} from "./DataStreamsDeps.sol";
import {PriceLib} from "./lib/PriceLib.sol";

/// @title DataStreamsSource
/// @notice Settlement source 3 (ADR-05), BUILT AND DISABLED: Chainlink Data Streams RWA Advanced (v11) reports, pushed
///         by keepers, verified through the chain's VerifierProxy, turned into Stock Token prices and kept as a
///         per-underlying ring of observations that {windowPrice} time-weights. DeployV8 DEPLOYS this contract (it has
///         an address on chain, disabled); no script REGISTERS it as a source for any market (RegisterMarkets lists
///         Chainlink and the pool only). The owner enables it per market once credentials exist (V2-DATA-STREAMS.md).
/// @dev UNITS. Prices are USDG base units (6 dp) per whole share (ADR-04); times are unix seconds unless a name says
///      otherwise. Report schema and verifier surface: see src/v2/oracle/DataStreamsDeps.sol, which cites the
///      Chainlink documentation and smartcontractkit sources (commits and dates) they were taken from.
///
///      SUBMIT. {submit} takes signed reports straight from the Streams API. Each one is routed by the feed id read
///      from its unverified body (unknown feeds cost no verification), verified with `VerifierProxy.verify(report, "")`
///      (subscription billing: no fee payload, no value; `s_feeManager()` is zero on 4663 per R13), and then stored
///      only when every rule below holds. A report that fails is SKIPPED with a {ReportSkipped} reason, never reverted,
///      so one bad report cannot sink a keeper's batch. `verify` is called once per report rather than `verifyBulk`,
///      which reverts as a whole on one bad signature.
///        - the verified body is exactly a v11 seconds-resolution report (448 bytes, every field in its ABI type's
///          range, feed id prefix 0x000b) and its feed id is the one the payload was routed by;
///        - `marketStatus == 2` (Regular hours in the 24/5 US equities mapping, report-schema-v11 docs). Pre-market,
///          post-market, overnight, closed and unknown prints are never stored: settlement is priced on the regular
///          session only, and Chainlink warns that extended-hours streams are single-sourced;
///        - `validFromTimestamp <= observationsTimestamp <= now` (a report from the future is not a report);
///        - `observationsTimestamp + MAX_REPORT_AGE >= now` and `expiresAt >= now`. The age bound is what SEALS a
///          window: once `now > end + MAX_REPORT_AGE`, no report observed inside `[start, end]` can ever be stored, so
///          a window price that is ok never changes. MAX_REPORT_AGE (60 s) is below FINALIZE_DELAY (120 s), so every
///          window is sealed before SettlementOracle's first finalize reads it. `expiresAt` is checked here because
///          neither the VerifierProxy nor the Verifier checks it (only a FeeManager did);
///        - `lastSeenTimestampNs` (the mid's own last update) is at most MAX_MID_AGE before the observation.
///          Chainlink's 24/5 guide: a mid that stops moving means the venue stopped quoting (halt, outage), which
///          marketStatus does not flag;
///        - `observationsTimestamp >= newest stored + MIN_OBSERVATION_SPACING` for that underlying. Observations are
///          therefore strictly time-ordered (the ring is sorted, which {windowPrice} binary-searches), and nobody can
///          flush a window out of the ring by submitting one report per second: 256 slots at >= 30 s apart hold at
///          least 128 minutes, while a 30-minute window holds at most 61;
///        - the underlying's `oraclePaused()` is false and `uiMultiplier()` is in (0, MAX_UI_MULTIPLIER], read NOW;
///        - price = floor(mid / 1e12) x uiMultiplier / 1e18 is in (0, 2^128]. The report's `mid` is the EQUITY price
///          (18 decimals); a Stock Token is worth the equity price times its multiplier, which the issuer moves on
///          dividends and splits, up or down. Truncating to 6 dp before scaling costs at most multiplier/1e18 base
///          units (a few millionths of a dollar) and keeps the product far inside uint256 without FullMath.
///
///      THE WINDOW (architecture §3.3). {windowPrice}(u, start, end) is ok only when:
///        - at least MIN_OBSERVATIONS (10) stored observations fall in `[start, end]`;
///        - no two consecutive ones are more than MAX_GAP (300 s) apart;
///        - the first is at most `start + MAX_GAP` and the last at least `end - MAX_GAP`;
///        - the window is sealed (`now > end + MAX_REPORT_AGE`) and the underlying's `oraclePaused()` is false now;
///        - the ring still holds the observation before the window's first one (or never wrapped): if older slots were
///          overwritten, observations inside the window may be gone, so the answer would be a different one.
///      Price = sum(price_i x seconds_i) / (end - start), floored, with each observation in force from its time to the
///      next one's (the last one to `end`), and the first one also standing in for `[start, first]`, at most MAX_GAP.
///      A keeper that submits the latest report every 60-120 s from 15:25 to 16:00 New York meets every rule with room.
///
///      RECORD. {record}(u, expiry) stores the sealed `[expiry - SETTLEMENT_WINDOW, expiry]` price once, so the ring
///      may later wrap without losing a settlement input; {windowPrice} serves the stored value first. It returns false
///      (never reverts) before the window is sealed or while it is not ok, so SettlementOracle.snapshot can call it
///      blindly; the first successful call is the one that returns true.
///
///      PINNING (INTERFACE_VERSION 6). {pin}, called by a registered oracle ({setOracle}) when the first series of an
///      expiry is created, records the underlying's {feedVersion}, which every {setFeed} that changes the feed id bumps.
///      The observation ring belongs to the underlying and restarts on such a change, so a pinned expiry cannot keep
///      the old stream's prints: {windowPrice} and {record} of a pinned expiry are not ok once the version moved,
///      unless {record} already stored the window. {setFeed} can therefore neither point a live series at another
///      stream nor restart the history inside its window to drop prints (a pin always precedes the window: series are
///      created at least MIN_SERIES_LEAD before expiry); the most it can do is take this source out of that expiry's
///      settlement, as removing the feed always could. {pin} fails closed: it refuses an underlying without a feed id
///      (V2Errors.NoSource), and a pin of an expiry pinned before (through another allowed oracle) only confirms a
///      pin at the current {feedVersion} (V2Errors.PinMismatch otherwise; the version identifies the feed id too,
///      because every change of the id bumps it). {latest} and {inspectWindow} read the current state.
///
///      KNOWN LIMITS. The submitter chooses which reports (at >= 30 s spacing) are sampled, so a submitter can bias the
///      average by at most the price's movement between the reports it could have picked; corroboration against the
///      other sources bounds that. On an NYSE early-close day the 15:30-16:00 window has no regular-hours prints, so
///      this source is simply not ok there and the oracle falls back. If Chainlink ever sets an access controller or a
///      FeeManager on the 4663 VerifierProxy, verification fails (VerifyFailed) until this contract is allowlisted or a
///      new source is deployed.
///
///      Every external read of the token and the proxy's reply is a raw call with lengths checked before decoding: a
///      typed call to a target that answers short data reverts in the caller, where try/catch cannot catch it.
contract DataStreamsSource is IPriceSource, Managed, ReentrancyGuardTransient {
    /// @notice Why {submit} did not store a report (the {ReportSkipped} reason).
    enum SkipReason {
        /// @dev Stored (never emitted).
        None,
        /// @dev The signed payload is not `abi.encode(bytes32[3], bytes, ...)` with a report body of at least 32 bytes.
        Malformed,
        /// @dev No underlying is configured for the payload's feed id (not sent to the verifier).
        UnknownFeed,
        /// @dev `VerifierProxy.verify` reverted or did not answer an ABI-encoded `bytes`.
        VerifyFailed,
        /// @dev The verified body is not a v11 seconds-resolution report (length, field ranges, feed id prefix).
        BadReport,
        /// @dev The verified feed id differs from the one the payload was routed by.
        FeedIdMismatch,
        /// @dev `marketStatus != 2` (not regular hours).
        MarketNotOpen,
        /// @dev `validFromTimestamp > observationsTimestamp`.
        BadTimestamps,
        /// @dev `observationsTimestamp > now`.
        FutureReport,
        /// @dev `observationsTimestamp + MAX_REPORT_AGE < now`.
        StaleReport,
        /// @dev `expiresAt < now`.
        ExpiredReport,
        /// @dev The mid was last updated more than MAX_MID_AGE before the observation.
        StaleMid,
        /// @dev Not at least MIN_OBSERVATION_SPACING after the newest stored observation of the underlying.
        NotNewer,
        /// @dev The underlying's `oraclePaused()` is true or cannot be read.
        OraclePaused,
        /// @dev The underlying's `uiMultiplier()` cannot be read, is 0, or exceeds MAX_UI_MULTIPLIER.
        BadMultiplier,
        /// @dev `mid <= 0`, or the token price is 0 or above 2^128.
        BadPrice
    }

    /// @notice One stored observation. One slot (40 + 128 + 16 = 184 bits).
    struct Observation {
        /// @dev Unix seconds: the report's `observationsTimestamp`.
        uint40 observedAt;
        /// @dev USDG base units (6 dp) per whole Stock Token share: equity mid x uiMultiplier at submit time.
        uint128 price;
        /// @dev WHICH MULTIPLIER REGIME THIS PRICE BELONGS TO (SEC-20). `price` bakes in the `uiMultiplier` read
        ///      at submit, so two observations taken either side of an issuer corporate action are denominated
        ///      differently and averaging them is meaningless. This counter, bumped by {_noteMultiplier} the
        ///      first time a new multiplier is seen, is what lets {_window} notice that rather than blend them.
        uint16 multiplierEpoch;
    }

    /// @notice What {record} stored for (underlying, expiry). One slot.
    struct Snapshot {
        /// @dev USDG base units (6 dp) per whole share. Zero: nothing recorded.
        uint128 price;
        /// @dev Observations the window price was computed from.
        uint16 observations;
        /// @dev Unix seconds of the {record} call.
        uint40 recordedAt;
    }

    /// @notice The pin of one expiry ({pin}). One slot.
    struct PinnedFeed {
        /// @dev True once pinned.
        bool pinned;
        /// @dev The underlying's {feedVersion} at the pin: the expiry is priced only while it is unchanged.
        uint64 version;
    }

    /// @notice The window statistics {inspectWindow} reports and {windowPrice} decides on.
    struct Window {
        /// @dev Every window rule holds (see the contract NatSpec).
        bool ok;
        /// @dev USDG base units (6 dp) per share; 0 unless ok.
        uint256 price;
        /// @dev Stored observations inside `[start, end]`.
        uint256 observations;
        /// @dev Unix seconds of the first and last observation inside the window; 0 when there is none.
        uint40 firstAt;
        uint40 lastAt;
        /// @dev Seconds. Largest gap between consecutive observations inside the window.
        uint40 maxGap;
        /// @dev SEC-20: the window contains observations from more than one multiplier regime, so its prices are
        ///      not in one denomination and no average of them means anything. Never ok when true.
        bool mixedMultiplier;
    }

    /// @notice Observations kept per underlying (architecture §3.3: at least 256).
    uint256 public constant RING_SIZE = 256;
    /// @notice Fewest observations a window needs.
    uint256 public constant MIN_OBSERVATIONS = 10;
    /// @notice Seconds. Largest allowed gap between consecutive observations, and between a window edge and the nearest
    ///         observation.
    uint40 public constant MAX_GAP = 300;
    /// @notice Seconds. Least time between two stored observations of one underlying.
    uint40 public constant MIN_OBSERVATION_SPACING = 30;
    /// @notice Seconds. Oldest a report's observation may be when submitted; also the delay after which a window is
    ///         sealed. Must stay below V2Constants.FINALIZE_DELAY (a unit test pins it).
    uint40 public constant MAX_REPORT_AGE = 60;
    /// @notice Seconds. Oldest the mid's last update (`lastSeenTimestampNs`) may be relative to the observation;
    ///         Chainlink's 24/5 guide uses the same 5-minute staleness threshold.
    uint40 public constant MAX_MID_AGE = 300;
    /// @notice `marketStatus` of the regular session in the v11 24/5 US equities mapping.
    uint32 public constant MARKET_STATUS_REGULAR = 2;
    /// @notice First two bytes of every accepted feed id: timestamp resolution 0 (seconds), schema version 11.
    bytes2 public constant V11_SECONDS_PREFIX = 0x000b;
    /// @notice Bytes of an ABI-encoded v11 report body: 14 static words.
    uint256 public constant REPORT_BODY_LENGTH = 448;
    /// @notice A new `uiMultiplier` was seen for `underlying`; observations from here on carry `epoch` (SEC-20).
    /// @dev Emitted from the submit path, so a keeper watching this knows a settlement window that straddles this
    ///      moment will refuse rather than blend, and can plan to re-record after the window clears.
    event MultiplierRegimeChanged(address indexed underlying, uint256 multiplier, uint16 epoch);

    /// @notice Decimals of `mid` in the equity streams (reference data directory multiplier 1e18).
    uint8 public constant REPORT_PRICE_DECIMALS = 18;
    /// @notice Scale of `uiMultiplier()` (ERC-8056: 1e18 = 1.0).
    uint256 public constant UI_MULTIPLIER_SCALE = 1e18;
    /// @notice Largest multiplier accepted (1e12 x): far beyond any corporate action, and it keeps the price product
    ///         inside uint256.
    uint256 public constant MAX_UI_MULTIPLIER = 1e30;

    /// @notice Chainlink Data Streams VerifierProxy (4663: 0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7).
    address public immutable verifierProxy;

    /// @notice The v11 Regular Hours feed id of each underlying (zero: unconfigured).
    mapping(address underlying => bytes32) public feedIdOf;
    /// @notice The underlying each configured feed id prices (one feed id, one underlying).
    mapping(bytes32 feedId => address) public underlyingOf;
    /// @notice Observations stored for the underlying since its feed was last set; slot `i % RING_SIZE` holds the i-th.
    mapping(address underlying => uint256) public observationCount;

    /// @notice The multiplier regime an underlying is currently in, and the multiplier that defined it (SEC-20).
    /// @dev ONE SLOT, READ ONCE PER SUBMIT. `last` holds the `uiMultiplier` most recently seen by {_store};
    ///      `epoch` counts how many times it has changed. `MAX_UI_MULTIPLIER` is 1e30 < 2^100, so uint240 is
    ///      room to spare and the pair packs into a single word.
    struct MultiplierState {
        uint240 last;
        uint16 epoch;
    }

    /// @notice Per-underlying multiplier regime. Public so a keeper can see a corporate action has been noticed.
    mapping(address underlying => MultiplierState) public multiplierState;
    /// @notice {record} snapshots per underlying and expiry.
    mapping(address underlying => mapping(uint40 expiry => Snapshot)) public snapshots;
    /// @notice How many times {setFeed} changed the underlying's feed id (and restarted its history).
    mapping(address underlying => uint64) public feedVersion;
    /// @notice Oracles allowed to call {pin} ({setOracle}).
    mapping(address oracle => bool) public isOracle;
    /// @notice The pin per underlying and expiry ({pin}); `pinned` false: not pinned.
    mapping(address underlying => mapping(uint40 expiry => PinnedFeed)) public pinnedFeeds;

    mapping(address underlying => mapping(uint256 slot => Observation)) internal _ring;

    /// @notice The feed id of `underlying` changed (zero: removed). Its observation history restarts.
    event FeedSet(address indexed underlying, bytes32 indexed feedId);
    /// @notice CONFIG_ADMIN (v8 AccessManager, 24 h execution delay) allowed or disallowed `oracle` to call {pin}.
    event OracleSet(address indexed oracle, bool allowed);
    /// @notice {pin} tied `expiry` to the underlying's feed id `feedId` at {feedVersion} `version`.
    event FeedPinned(address indexed underlying, uint40 indexed expiry, bytes32 feedId, uint64 version);
    /// @notice {submit} stored an observation. `price` is USDG 6 dp per share; `mid` the report's 18-dp equity price;
    ///         `uiMultiplier` the 1e18-scaled multiplier read at submit.
    event ObservationStored(
        address indexed underlying,
        bytes32 indexed feedId,
        uint40 observedAt,
        uint256 price,
        int256 mid,
        uint256 uiMultiplier
    );
    /// @notice {submit} skipped report `index` of its input. `feedId` is zero when the payload could not be parsed.
    event ReportSkipped(uint256 indexed index, bytes32 indexed feedId, SkipReason reason);
    /// @notice {record} stored the window price of (underlying, expiry), USDG 6 dp per share.
    event Recorded(address indexed underlying, uint40 indexed expiry, uint256 price, uint256 observations);

    /// @param authority The `AccessManager` mapping this contract's selectors to roles (V8Roles).
    /// @param verifierProxy_ Chainlink Data Streams VerifierProxy of this chain.
    constructor(address authority, address verifierProxy_) Managed(authority) {
        if (verifierProxy_.code.length == 0) revert V2Errors.NoSource();
        verifierProxy = verifierProxy_;
    }

    /*//////////////////////////////////////////////////////////////
                                  ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets or removes the Data Streams feed of `underlying`.
    /// @dev CONFIG_ADMIN only (V2Errors.NotAuthorized). `feedId == 0` removes it. Setting the id it already has
    ///      changes nothing. Any change restarts the underlying's observation history (a different stream's prints are
    ///      not this one's); snapshots already recorded stay. Reverts V2Errors.UnsupportedAsset for a zero underlying
    ///      or one whose `uiMultiplier()` does not answer in (0, MAX_UI_MULTIPLIER]; V2Errors.NoSource for a feed id
    ///      that does not start with V11_SECONDS_PREFIX or already prices another underlying. Choosing the Regular Hours
    ///      id (ops/markets/v2-sources.json `dataStreamsFeedId`) and confirming the entitlement is the owner's job. A
    ///      change bumps {feedVersion}: every pinned expiry whose window is not recorded yet stops being priced here.
    /// @param underlying 18-dp Stock Token.
    /// @param feedId v11 Regular Hours feed id, or zero to remove.
    function setFeed(address underlying, bytes32 feedId) external nonReentrant restricted {
        if (underlying == address(0)) revert V2Errors.UnsupportedAsset();
        bytes32 old = feedIdOf[underlying];
        if (feedId == old) return;
        if (feedId != bytes32(0)) {
            // casting to 'bytes2' keeps the id's first two bytes on purpose: they are its schema prefix
            // forge-lint: disable-next-line(unsafe-typecast)
            if (bytes2(feedId) != V11_SECONDS_PREFIX || underlyingOf[feedId] != address(0)) revert V2Errors.NoSource();
            (bool multiplierOk,) = _uiMultiplier(underlying);
            if (!multiplierOk) revert V2Errors.UnsupportedAsset();
            underlyingOf[feedId] = underlying;
        }
        if (old != bytes32(0)) delete underlyingOf[old];
        feedIdOf[underlying] = feedId;
        observationCount[underlying] = 0;
        ++feedVersion[underlying];
        emit FeedSet(underlying, feedId);
    }

    /// @notice Allows or disallows `oracle` to call {pin}.
    /// @dev CONFIG_ADMIN only (V2Errors.NotAuthorized). An allow-list for the reason ChainlinkFeedSource.setOracle
    ///      gives: two SettlementOracles may share this source while a market migrates.
    /// @param oracle SettlementOracle.
    /// @param allowed True to allow.
    function setOracle(address oracle, bool allowed) external nonReentrant restricted {
        isOracle[oracle] = allowed;
        emit OracleSet(oracle, allowed);
    }

    /*//////////////////////////////////////////////////////////////
                                  SUBMIT
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies signed Data Streams reports and stores the ones that pass as observations.
    /// @dev Anyone. Never reverts because of a report: each failure emits {ReportSkipped} with its reason and the call
    ///      continues (see the contract NatSpec for the rules). Order matters: reports of one underlying must come in
    ///      time order, at least MIN_OBSERVATION_SPACING apart, or the later-listed older ones are skipped (NotNewer).
    ///      CEI: phase 1 makes every verification call (the only state-changing interactions, to the immutable
    ///      VerifierProxy), phase 2 checks and stores; the token reads in phase 2 are STATICCALLs.
    /// @param signedReports Full report payloads as the Streams API returns them (`fullReport`).
    /// @return stored How many reports were stored.
    function submit(bytes[] calldata signedReports) external nonReentrant returns (uint256 stored) {
        uint256 n = signedReports.length;
        bytes32[] memory feedIds = new bytes32[](n);
        bytes[] memory bodies = new bytes[](n);
        SkipReason[] memory early = new SkipReason[](n);

        for (uint256 i; i < n; ++i) {
            (bool parsed, bytes32 feedId) = _peekFeedId(signedReports[i]);
            if (!parsed) {
                early[i] = SkipReason.Malformed;
                continue;
            }
            feedIds[i] = feedId;
            if (underlyingOf[feedId] == address(0)) {
                early[i] = SkipReason.UnknownFeed;
                continue;
            }
            (bool verified, bytes memory body) = _verify(signedReports[i]);
            if (!verified) {
                early[i] = SkipReason.VerifyFailed;
                continue;
            }
            bodies[i] = body;
        }

        for (uint256 i; i < n; ++i) {
            SkipReason reason = early[i];
            if (reason == SkipReason.None) reason = _store(feedIds[i], bodies[i]);
            if (reason == SkipReason.None) ++stored;
            else emit ReportSkipped(i, feedIds[i], reason);
        }
    }

    /*//////////////////////////////////////////////////////////////
                               IPriceSource
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPriceSource
    /// @dev The newest stored observation: a regular-hours print, `updatedAt` = its `observationsTimestamp`. Not ok
    ///      when unconfigured, nothing is stored, or the underlying's `oraclePaused()` is true now. Age is not checked.
    function latest(address underlying) external view returns (bool ok, uint256 price, uint256 updatedAt) {
        uint256 count = observationCount[underlying];
        if (feedIdOf[underlying] == bytes32(0) || count == 0 || _oraclePaused(underlying)) return (false, 0, 0);
        Observation memory o = _ring[underlying][(count - 1) % RING_SIZE];
        return (true, o.price, o.observedAt);
    }

    /// @inheritdoc IPriceSource
    /// @dev The {record} snapshot for `(underlying, end)` when one exists and `end - start == SETTLEMENT_WINDOW`;
    ///      otherwise not ok when `end` is a pinned expiry whose {feedVersion} moved since the pin, else the ring
    ///      computation with every window rule of the contract NatSpec.
    function windowPrice(address underlying, uint40 start, uint40 end) external view returns (bool ok, uint256 price) {
        Snapshot memory s = snapshots[underlying][end];
        if (s.price != 0 && uint256(start) + V2Constants.SETTLEMENT_WINDOW == end) return (true, s.price);
        if (!_pinIntact(underlying, end)) return (false, 0);
        Window memory w = _window(underlying, start, end);
        if (!w.ok) return (false, 0);
        return (true, w.price);
    }

    /// @inheritdoc IPriceSource
    /// @dev Anyone, any time; never reverts. Stores the price of `[expiry - SETTLEMENT_WINDOW, expiry]` once it is ok
    ///      (so no earlier than `expiry + MAX_REPORT_AGE + 1`). False when already recorded, not ok (yet), or pinned
    ///      and the {feedVersion} moved since the pin.
    function record(address underlying, uint40 expiry) external nonReentrant returns (bool recorded) {
        if (snapshots[underlying][expiry].price != 0 || expiry <= V2Constants.SETTLEMENT_WINDOW) return false;
        if (!_pinIntact(underlying, expiry)) return false;
        Window memory w = _window(underlying, expiry - V2Constants.SETTLEMENT_WINDOW, expiry);
        if (!w.ok) return false;
        // casting to 'uint128' is safe because stored prices are <= PriceLib.MAX_PRICE, so their weighted mean is too
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 storedPrice = uint128(w.price);
        // casting to 'uint16' is safe because a window cannot hold more observations than RING_SIZE (256)
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 used = uint16(w.observations);
        snapshots[underlying][expiry] =
            Snapshot({price: storedPrice, observations: used, recordedAt: uint40(block.timestamp)});
        emit Recorded(underlying, expiry, w.price, w.observations);
        return true;
    }

    /// @inheritdoc IPriceSource
    /// @dev Only an oracle on the allow-list (V2Errors.NotAuthorized). An expiry already pinned: returns without a log
    ///      when its pinned version is the underlying's current {feedVersion} (so the feed id is the pinned one too),
    ///      else reverts V2Errors.PinMismatch. Otherwise reverts V2Errors.NoSource when the underlying has no feed id,
    ///      or stores the current {feedVersion} in {pinnedFeeds} and emits {FeedPinned}.
    function pin(address underlying, uint40 expiry) external nonReentrant returns (bytes4) {
        if (!isOracle[msg.sender]) revert V2Errors.NotAuthorized();
        PinnedFeed storage p = pinnedFeeds[underlying][expiry];
        uint64 version = feedVersion[underlying];
        if (p.pinned) {
            if (p.version != version) revert V2Errors.PinMismatch();
            return IPriceSource.pin.selector;
        }
        bytes32 feedId = feedIdOf[underlying];
        if (feedId == bytes32(0)) revert V2Errors.NoSource();
        (p.pinned, p.version) = (true, version);
        emit FeedPinned(underlying, expiry, feedId, version);
        return IPriceSource.pin.selector;
    }

    /*//////////////////////////////////////////////////////////////
                                   VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The window statistics behind {windowPrice}, including why it is not ok.
    /// @dev Anyone. Never reverts. Ignores snapshots. For keepers and ops: during the window it shows how many
    ///      observations are in and how far apart; `ok` also needs the window sealed and the oracle not paused.
    /// @param underlying 18-dp Stock Token.
    /// @param start Window start, unix seconds.
    /// @param end Window end, unix seconds.
    /// @return w Statistics; `price` is set only when `ok`.
    function inspectWindow(address underlying, uint40 start, uint40 end) external view returns (Window memory w) {
        return _window(underlying, start, end);
    }

    /// @notice A stored observation by age: `ago == 0` is the newest.
    /// @dev Anyone. Never reverts. Only the RING_SIZE newest are retained.
    /// @param underlying 18-dp Stock Token.
    /// @param ago 0-based position counted back from the newest.
    /// @return exists False past the retained history.
    /// @return observedAt Unix seconds.
    /// @return price USDG base units (6 dp) per share.
    function observationAt(address underlying, uint256 ago)
        external
        view
        returns (bool exists, uint40 observedAt, uint256 price)
    {
        uint256 count = observationCount[underlying];
        if (ago >= count || ago >= RING_SIZE) return (false, 0, 0);
        Observation memory o = _ring[underlying][(count - 1 - ago) % RING_SIZE];
        return (true, o.observedAt, o.price);
    }

    /// @notice Decodes a VERIFIED report body as the v11 schema, without reverting.
    /// @dev Anyone. `ok` is false unless `body` is exactly REPORT_BODY_LENGTH bytes, every word is inside its field's
    ///      ABI type (what `abi.decode(body, (DataStreamsReportV11))` would accept), and the feed id starts with
    ///      V11_SECONDS_PREFIX. Verification is not checked here: never trust an unverified body.
    /// @param body `abi.encode(DataStreamsReportV11)`.
    /// @return ok Whether it decodes.
    /// @return report The decoded fields; all zero when not ok.
    function decodeReport(bytes calldata body) external pure returns (bool ok, DataStreamsReportV11 memory report) {
        return _decode(body);
    }

    /*//////////////////////////////////////////////////////////////
                                 INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Checks one verified body against every storage rule and stores it. Returns the first failing reason, or
    ///      None when stored. The feed id is configured (phase 1 checked it, and nothing ran in between).
    function _store(bytes32 feedId, bytes memory body) private returns (SkipReason) {
        (bool decoded, DataStreamsReportV11 memory r) = _decode(body);
        if (!decoded) return SkipReason.BadReport;
        if (r.feedId != feedId) return SkipReason.FeedIdMismatch;
        if (r.marketStatus != MARKET_STATUS_REGULAR) return SkipReason.MarketNotOpen;
        if (r.validFromTimestamp > r.observationsTimestamp) return SkipReason.BadTimestamps;
        uint256 observedAt = r.observationsTimestamp;
        if (observedAt > block.timestamp) return SkipReason.FutureReport;
        if (observedAt + MAX_REPORT_AGE < block.timestamp) return SkipReason.StaleReport;
        if (r.expiresAt < block.timestamp) return SkipReason.ExpiredReport;
        if (r.lastSeenTimestampNs / 1e9 + MAX_MID_AGE < observedAt) return SkipReason.StaleMid;

        address underlying = underlyingOf[feedId];
        uint256 count = observationCount[underlying];
        if (
            count != 0
                && observedAt < uint256(_ring[underlying][(count - 1) % RING_SIZE].observedAt) + MIN_OBSERVATION_SPACING
        ) return SkipReason.NotNewer;
        if (_oraclePaused(underlying)) return SkipReason.OraclePaused;
        (bool multiplierOk, uint256 multiplier) = _uiMultiplier(underlying);
        if (!multiplierOk) return SkipReason.BadMultiplier;
        (bool priceOk, uint256 equityPrice) = PriceLib.normalizeAnswer(r.mid, REPORT_PRICE_DECIMALS);
        if (!priceOk) return SkipReason.BadPrice;
        // equityPrice <= 2^128 and multiplier <= 1e30 < 2^100: the product cannot overflow.
        uint256 price = equityPrice * multiplier / UI_MULTIPLIER_SCALE;
        if (price == 0 || price > PriceLib.MAX_PRICE) return SkipReason.BadPrice;

        // casting to 'uint40' is safe because observationsTimestamp is a uint32 (checked by _decode)
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 at = uint40(observedAt);
        // casting to 'uint128' is safe because the line above the cast returns for price > PriceLib.MAX_PRICE
        // forge-lint: disable-next-line(unsafe-typecast)
        _ring[underlying][count % RING_SIZE] = Observation({
            observedAt: at, price: uint128(price), multiplierEpoch: _noteMultiplier(underlying, multiplier)
        });
        observationCount[underlying] = count + 1;
        emit ObservationStored(underlying, feedId, at, price, r.mid, multiplier);
        return SkipReason.None;
    }

    /// @dev False only for a pinned expiry whose underlying changed feed id since the pin (see PINNING).
    function _pinIntact(address underlying, uint40 expiry) private view returns (bool) {
        PinnedFeed memory p = pinnedFeeds[underlying][expiry];
        return !p.pinned || p.version == feedVersion[underlying];
    }

    /// @dev The window computation: binary search for the newest observation at or before `end` (the ring is sorted by
    ///      time), then a walk back to the first observation before `start`. Statistics are filled whenever an
    ///      observation lies inside the window; `ok` and `price` only when every rule holds.
    function _window(address underlying, uint40 start, uint40 end) private view returns (Window memory w) {
        uint256 count = observationCount[underlying];
        if (feedIdOf[underlying] == bytes32(0) || count == 0 || start >= end) return w;
        mapping(uint256 slot => Observation) storage ring = _ring[underlying];
        uint256 oldest = count > RING_SIZE ? count - RING_SIZE : 0;
        if (ring[oldest % RING_SIZE].observedAt > end) return w;

        uint256 lo = oldest;
        uint256 hi = count - 1;
        while (lo < hi) {
            uint256 probe = (lo + hi + 1) / 2;
            if (ring[probe % RING_SIZE].observedAt <= end) lo = probe;
            else hi = probe - 1;
        }
        Observation memory last = ring[lo % RING_SIZE];
        if (last.observedAt < start) return w;

        // Prices < 2^128 and seconds < 2^40: the sum cannot overflow.
        uint256 newer = last.observedAt;
        uint256 weighted = uint256(last.price) * (uint256(end) - newer);
        uint256 firstPrice = last.price;
        uint256 used = 1;
        uint256 maxGap;
        // SEC-20: every observation the mean is taken over must belong to the newest one's multiplier regime.
        uint16 epoch = last.multiplierEpoch;
        bool mixed;
        // Complete when the ring still holds what precedes the window's first observation, or never wrapped.
        bool complete = oldest == 0;
        for (uint256 k = lo; k > oldest;) {
            --k;
            Observation memory o = ring[k % RING_SIZE];
            if (o.observedAt < start) {
                complete = true;
                break;
            }
            // Stored observations are strictly increasing in time ({_store}'s spacing rule), so this cannot underflow.
            if (o.multiplierEpoch != epoch) mixed = true;
            uint256 gap = newer - o.observedAt;
            if (gap > maxGap) maxGap = gap;
            weighted += uint256(o.price) * gap;
            newer = o.observedAt;
            firstPrice = o.price;
            ++used;
        }
        weighted += firstPrice * (newer - start);

        w.observations = used;
        // casting to 'uint40' is safe because newer, last.observedAt and maxGap are all <= end, a uint40
        // forge-lint: disable-next-line(unsafe-typecast)
        w.firstAt = uint40(newer);
        w.lastAt = last.observedAt;
        // forge-lint: disable-next-line(unsafe-typecast)
        w.maxGap = uint40(maxGap);
        w.mixedMultiplier = mixed;
        // SEC-20 IS THE `!mixed` TERM, and it is a REFUSAL rather than a correction on purpose. The stored prices
        // either side of a corporate action are in different denominations and nothing here can convert between
        // them: re-scaling the older ones would need the multiplier that was in force when each was taken, which
        // is not stored, and applying today's multiplier to all of them is a different wrong answer. So the
        // window declines to answer. `record` then stores nothing, {SettlementOracle} sees this source produce
        // no price, and the expiry stays unfinalised for it -- loud, and resolvable by the guardian/admin path --
        // instead of finalising a blended number that looks ordinary.
        w.ok = !mixed && complete && used >= MIN_OBSERVATIONS && maxGap <= MAX_GAP && newer <= uint256(start) + MAX_GAP
            && uint256(last.observedAt) + MAX_GAP >= end && uint256(end) + MAX_REPORT_AGE < block.timestamp
            && !_oraclePaused(underlying);
        if (w.ok) w.price = weighted / (end - start);
    }

    /// @dev The feed id of an UNVERIFIED payload `abi.encode(bytes32[3] reportContext, bytes reportData, bytes32[] rs,
    ///      bytes32[] ss, bytes32 rawVs)`: the first word of `reportData`. Hand-parsed with bounds checks, because
    ///      `abi.decode` of a malformed payload would revert the whole batch. Used only for routing; the verified
    ///      body's feed id is what counts.
    function _peekFeedId(bytes calldata payload) private pure returns (bool ok, bytes32 feedId) {
        // Seven head words: three context words, three offsets, rawVs.
        if (payload.length < 224) return (false, bytes32(0));
        uint256 offset = uint256(bytes32(payload[96:128]));
        if (offset > payload.length - 64) return (false, bytes32(0));
        uint256 len = uint256(bytes32(payload[offset:offset + 32]));
        if (len < 32 || len > payload.length - offset - 32) return (false, bytes32(0));
        return (true, bytes32(payload[offset + 32:offset + 64]));
    }

    /// @dev `VerifierProxy.verify(payload, "")` as a raw call, its `bytes` reply unwrapped by hand. Not ok when the
    ///      call reverts or the reply is not a well-formed ABI `bytes`.
    function _verify(bytes calldata payload) private returns (bool ok, bytes memory body) {
        (bool success, bytes memory ret) =
            verifierProxy.call(abi.encodeCall(IDataStreamsVerifierProxy.verify, (payload, bytes(""))));
        if (!success || ret.length < 64) return (false, body);
        uint256 offset;
        assembly ("memory-safe") {
            offset := mload(add(ret, 0x20))
        }
        if (offset > ret.length - 32) return (false, body);
        uint256 len;
        assembly ("memory-safe") {
            len := mload(add(add(ret, 0x20), offset))
        }
        if (len > ret.length - 32 - offset) return (false, body);
        body = new bytes(len);
        assembly ("memory-safe") {
            mcopy(add(body, 0x20), add(add(ret, 0x40), offset), len)
        }
        return (true, body);
    }

    /// @dev See {decodeReport}.
    function _decode(bytes memory body) private pure returns (bool ok, DataStreamsReportV11 memory r) {
        if (body.length != REPORT_BODY_LENGTH) return (false, r);
        // Exactly 448 bytes of uint256 words: this decode cannot revert. The type ranges are checked below.
        uint256[14] memory w = abi.decode(body, (uint256[14]));
        if (bytes2(bytes32(w[0])) != V11_SECONDS_PREFIX) return (false, r);
        if (
            w[1] > type(uint32).max || w[2] > type(uint32).max || w[3] > type(uint192).max || w[4] > type(uint192).max
                || w[5] > type(uint32).max || w[7] > type(uint64).max || w[13] > type(uint32).max
        ) return (false, r);
        if (!_isInt192(w[6]) || !_isInt192(w[8]) || !_isInt192(w[9]) || !_isInt192(w[10]) || !_isInt192(w[11])) {
            return (false, r);
        }
        if (!_isInt192(w[12])) return (false, r);

        // Every cast below is safe: the checks above bound each word to its field's type.
        r.feedId = bytes32(w[0]);
        // forge-lint: disable-next-line(unsafe-typecast)
        r.validFromTimestamp = uint32(w[1]);
        // forge-lint: disable-next-line(unsafe-typecast)
        r.observationsTimestamp = uint32(w[2]);
        // forge-lint: disable-next-line(unsafe-typecast)
        r.nativeFee = uint192(w[3]);
        // forge-lint: disable-next-line(unsafe-typecast)
        r.linkFee = uint192(w[4]);
        // forge-lint: disable-next-line(unsafe-typecast)
        r.expiresAt = uint32(w[5]);
        r.mid = _toInt192(w[6]);
        // forge-lint: disable-next-line(unsafe-typecast)
        r.lastSeenTimestampNs = uint64(w[7]);
        r.bid = _toInt192(w[8]);
        r.bidVolume = _toInt192(w[9]);
        r.ask = _toInt192(w[10]);
        r.askVolume = _toInt192(w[11]);
        r.lastTradedPrice = _toInt192(w[12]);
        // forge-lint: disable-next-line(unsafe-typecast)
        r.marketStatus = uint32(w[13]);
        return (true, r);
    }

    /// @dev Whether an ABI word is a sign-extended int192.
    function _isInt192(uint256 word) private pure returns (bool) {
        // casting to 'int256' reinterprets the word; the comparison accepts only sign-extended int192 values
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 v = int256(word);
        // forge-lint: disable-next-line(unsafe-typecast)
        return v == int256(int192(v));
    }

    /// @dev An ABI word already checked by {_isInt192}.
    function _toInt192(uint256 word) private pure returns (int192) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return int192(int256(word));
    }

    /// @dev The issuer's oracle halt flag, read now. Fails closed: a failed or short read counts as paused.
    function _oraclePaused(address underlying) private view returns (bool) {
        (bool success, bytes memory ret) = underlying.staticcall(abi.encodeCall(IOraclePausable.oraclePaused, ()));
        if (!success || ret.length < 32) return true;
        return abi.decode(ret, (uint256)) != 0;
    }

    /// @dev Records which multiplier regime `multiplier` belongs to and returns it, bumping the counter the first
    ///      time a new value is seen (SEC-20).
    ///
    ///      WHY A COUNTER AND NOT THE MULTIPLIER ITSELF: {Observation} has 88 bits spare in its slot and
    ///      `MAX_UI_MULTIPLIER` needs about 100, so the multiplier does not fit. What {_window} actually needs is
    ///      not the value but the ANSWER TO "were these prices denominated the same way", and a counter answers
    ///      that in 16 bits.
    ///
    ///      THE WRAP IS DELIBERATE AND HARMLESS. At 2^16 the counter wraps, so two regimes 65,536 corporate
    ///      actions apart would alias. A settlement window is 30 minutes; a window that straddled that many
    ///      multiplier changes is not a scenario this contract can be made correct for by a wider counter.
    function _noteMultiplier(address underlying, uint256 multiplier) private returns (uint16) {
        MultiplierState storage m = multiplierState[underlying];
        // casting to 'uint240' is safe: the caller has already checked multiplier <= MAX_UI_MULTIPLIER (1e30).
        // forge-lint: disable-next-line(unsafe-typecast)
        uint240 seen = uint240(multiplier);
        if (m.last == 0) {
            // FIRST OBSERVATION FOR THIS UNDERLYING: epoch 0 is a regime like any other, not a special case.
            m.last = seen;
            return m.epoch;
        }
        if (m.last != seen) {
            m.last = seen;
            unchecked {
                // Wrapping is intended; see the note above.
                m.epoch = m.epoch + 1;
            }
            emit MultiplierRegimeChanged(underlying, multiplier, m.epoch);
        }
        return m.epoch;
    }

    /// @dev The token's display multiplier, read now. Not ok when the read fails, is short, is 0 or exceeds
    ///      MAX_UI_MULTIPLIER.
    function _uiMultiplier(address underlying) private view returns (bool ok, uint256 multiplier) {
        (bool success, bytes memory ret) = underlying.staticcall(abi.encodeCall(IUiMultiplier.uiMultiplier, ()));
        if (!success || ret.length < 32) return (false, 0);
        multiplier = abi.decode(ret, (uint256));
        if (multiplier == 0 || multiplier > MAX_UI_MULTIPLIER) return (false, 0);
        return (true, multiplier);
    }
}
