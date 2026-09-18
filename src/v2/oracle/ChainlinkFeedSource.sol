// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {V2Errors} from "../interfaces/V2Errors.sol";
import {IAggregatorV3, IOraclePausable} from "./OracleDeps.sol";
import {PriceLib} from "./lib/PriceLib.sol";

/// @title ChainlinkFeedSource
/// @notice Settlement source 1 (ADR-05): the time-weighted average of a Chainlink push feed over a window, computed on
///         demand from the feed's own round history. Nothing is stored, so no keeper is needed and any past window can
///         be replayed while its rounds are within {MAX_ROUND_READS} of the head.
/// @dev UNITS. Prices are USDG base units (6 dp) per whole share (ADR-04); times are unix seconds.
///
///      THE STEP FUNCTION. A push feed prints a new round on a 0.5 % move or its heartbeat, and each round's answer is
///      the price "in force" from its `updatedAt` until the next round's. {windowPrice} walks backwards from
///      `latestRoundData` through `getRoundData(id - 1)`:
///        - a round with `updatedAt > end` is skipped (it is not in force inside the window, so it is neither priced nor
///          sanity-checked: a bad print after expiry cannot void a window that was fine);
///        - a round whose `updatedAt` is later than the newer round already accepted is skipped too. Round ids are the
///          order the aggregator published in; a timestamp that runs backwards is a feed fault, and the newer round is
///          what was in force;
///        - every other round is in force from its `updatedAt` to the newer accepted round's (or `end`), clipped to
///          `start`;
///        - the walk stops at the first round with `updatedAt <= start`: that round is in force at `start`.
///      TWAP = sum(price_i x seconds_i) / (end - start), floored.
///
///      WHEN IT IS NOT OK (every case returns ok = false; nothing here reverts):
///        - the underlying's `oraclePaused()` is true NOW, or the call fails (fail closed: a token without the flag is
///          not a Stock Token this source knows how to trust);
///        - a read reverts, returns short data, or returns `updatedAt == 0`: that is the end of the readable history,
///          and a window it has not covered cannot be priced;
///        - the walk reaches aggregator round 1 of the current phase before it is done. The proxy's previous phase is a
///          different aggregator under a different id prefix (architecture §3.3: never cross a phase boundary);
///        - {MAX_ROUND_READS} rounds were read before it is done;
///        - an answer used is <= 0, or normalises to 0 or above 2^128 (PriceLib.normalizeAnswer);
///        - the round in force at `start` was published more than the feed's `maxStale` before `start`;
///        - THE JUMP RULE: a used round (every round in force inside the window, and the one in force at `start`)
///          differs from its predecessor by more than `maxRoundJumpBps`. This is why the walk reads one round past
///          `start`, and why the round in force at `start` must have a predecessor in its phase: the NVDA proxy's
///          phase-1 round 1 answered 2082200000000000000 at 8 dp, and SPY once went 7349800000000000000 ->
///          73683695000 (R13); an unchecked first round is exactly where a mis-scaled print would slip through.
///
///      THE 96-READ BOUND. R13 (F2-02) walked 200 rounds per feed: NVDA printed 0.6 rounds per trading hour on
///      average, at most 1 round in any 15:30-16:00 window, and its largest move between consecutive rounds was 114
///      bps (TSLA 129; SPY's 10,000 is the scale fault above), so the 2,000 bps default rejects scale faults and never
///      real moves. 96 reads cover the window plus days of later prints; SettlementOracle captures the price at its
///      first finalize attempt (FINALIZE_DELAY after expiry), long before a replay could run out of reads. A 96-read
///      walk cost 661k gas through the live NVDA proxy (test/v2/fork/SourcesFork.t.sol), under the 1.5 M bound.
///
///      PINNING (INTERFACE_VERSION 6). {pin}, called by a registered oracle ({setOracle}) when the first series of an
///      expiry is created, copies the underlying's FeedConfig for that expiry. `windowPrice(underlying, start, end)`
///      with `end` a pinned expiry walks the pinned feed with the pinned `maxStale` and `maxRoundJumpBps`, so {setFeed}
///      cannot re-point, loosen or remove the feed of a live series. {pin} fails closed: it refuses an underlying
///      without a feed (V2Errors.NoSource), and a pin of an expiry pinned before (through another allowed oracle)
///      only confirms a copy equal to the current configuration (V2Errors.PinMismatch otherwise), so a pin made
///      outside a series creation blocks the series instead of pricing it. {latest} keeps reading the current
///      configuration.
///
///      Every external read is a raw `staticcall` with its length checked before decoding, because a typed call whose
///      target has no code or returns short data reverts in the caller, where try/catch cannot catch it.
contract ChainlinkFeedSource is IPriceSource, AccessControl, ReentrancyGuardTransient {
    /// @notice Per-underlying feed configuration (DEFAULT_ADMIN_ROLE).
    struct FeedConfig {
        /// @dev Chainlink AggregatorV3 proxy for the Stock Token's USD price (e.g. "RHNVDA / USD"). Zero: unconfigured.
        address feed;
        /// @dev Seconds. The round in force at a window's start may be at most this old.
        uint32 maxStale;
        /// @dev Basis points. The largest move allowed between a used round and its predecessor.
        uint16 maxRoundJumpBps;
    }

    /// @notice A FeedConfig pinned for one expiry ({pin}). One slot.
    struct PinnedFeed {
        /// @dev As FeedConfig.feed at the pin; never zero ({pin} refuses an unconfigured underlying).
        address feed;
        /// @dev Seconds.
        uint32 maxStale;
        /// @dev Basis points.
        uint16 maxRoundJumpBps;
        /// @dev True once pinned (whatever the configuration was).
        bool pinned;
    }

    /// @dev One round as read. `exists` is false when the read failed in any way (see {_read}).
    struct Round {
        bool exists;
        uint80 id;
        int256 answer;
        uint256 updatedAt;
    }

    /// @notice Most rounds one {windowPrice} or {latest} call reads, `latestRoundData` included.
    uint256 public constant MAX_ROUND_READS = 96;
    /// @notice Recommended `maxStale`, seconds (architecture §3.3): the feeds' 24 h heartbeat plus 2 h of slack.
    uint32 public constant DEFAULT_MAX_STALE = 26 hours;
    /// @notice Recommended `maxRoundJumpBps` (architecture §3.3; R13 max real move 129 bps).
    uint16 public constant DEFAULT_MAX_ROUND_JUMP_BPS = 2000;
    /// @notice Bounds of `maxStale`, seconds.
    uint32 public constant MIN_MAX_STALE = 1 hours;
    uint32 public constant MAX_MAX_STALE = 7 days;
    /// @notice Ceiling of `maxRoundJumpBps`. A print mis-scaled DOWN moves by just under 10,000 bps, so a bound near
    ///         10,000 would let it through; 5,000 still allows any real one-round move.
    uint16 public constant MAX_ROUND_JUMP_CEIL_BPS = 5000;

    /// @dev Low 64 bits of a proxy round id: the aggregator's own round number inside the phase.
    uint256 private constant AGGREGATOR_ROUND_MASK = type(uint64).max;

    /// @notice Feed configuration per underlying.
    mapping(address underlying => FeedConfig) public feeds;
    /// @notice Oracles allowed to call {pin} ({setOracle}).
    mapping(address oracle => bool) public isOracle;
    /// @notice The configuration pinned per underlying and expiry ({pin}); `pinned` false: not pinned.
    mapping(address underlying => mapping(uint40 expiry => PinnedFeed)) public pinnedFeeds;

    /// @notice The feed configuration of `underlying` changed. All zero: removed.
    event FeedSet(address indexed underlying, address indexed feed, uint32 maxStale, uint16 maxRoundJumpBps);
    /// @notice DEFAULT_ADMIN_ROLE allowed or disallowed `oracle` to call {pin}.
    event OracleSet(address indexed oracle, bool allowed);
    /// @notice {pin} fixed the configuration windows ending at `expiry` use: `feed`, `maxStale` in seconds,
    ///         `maxRoundJumpBps` in basis points.
    event FeedPinned(
        address indexed underlying, uint40 indexed expiry, address feed, uint32 maxStale, uint16 maxRoundJumpBps
    );

    /// @param admin DEFAULT_ADMIN_ROLE holder (sets feeds).
    constructor(address admin) {
        // A zero admin would leave the source permanently unconfigurable.
        if (admin == address(0)) revert V2Errors.NotAuthorized();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /*//////////////////////////////////////////////////////////////
                                  ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets or removes the feed of `underlying`.
    /// @dev DEFAULT_ADMIN_ROLE only (V2Errors.NotAuthorized). `feed == address(0)` removes the configuration (the other
    ///      arguments are ignored). Reverts V2Errors.UnsupportedAsset for a zero underlying, V2Errors.NoSource for a
    ///      feed without code, and V2Errors.CeilingExceeded when `maxStale` is outside [MIN_MAX_STALE, MAX_MAX_STALE]
    ///      or `maxRoundJumpBps` outside [1, MAX_ROUND_JUMP_CEIL_BPS]. Checking the feed's description and freshness is
    ///      the deploy preflight's job (C2-13), not this setter's. Applies to {latest} and to every expiry not pinned;
    ///      pinned expiries keep their {pinnedFeeds} entry.
    /// @param underlying 18-dp Stock Token.
    /// @param feed Chainlink AggregatorV3 proxy, or zero to remove.
    /// @param maxStale Seconds; DEFAULT_MAX_STALE unless the market needs otherwise.
    /// @param maxRoundJumpBps Basis points; DEFAULT_MAX_ROUND_JUMP_BPS unless the market needs otherwise.
    function setFeed(address underlying, address feed, uint32 maxStale, uint16 maxRoundJumpBps) external nonReentrant {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert V2Errors.NotAuthorized();
        if (underlying == address(0)) revert V2Errors.UnsupportedAsset();
        if (feed == address(0)) {
            delete feeds[underlying];
            emit FeedSet(underlying, address(0), 0, 0);
            return;
        }
        if (feed.code.length == 0) revert V2Errors.NoSource();
        if (
            maxStale < MIN_MAX_STALE || maxStale > MAX_MAX_STALE || maxRoundJumpBps == 0
                || maxRoundJumpBps > MAX_ROUND_JUMP_CEIL_BPS
        ) revert V2Errors.CeilingExceeded();
        feeds[underlying] = FeedConfig({feed: feed, maxStale: maxStale, maxRoundJumpBps: maxRoundJumpBps});
        emit FeedSet(underlying, feed, maxStale, maxRoundJumpBps);
    }

    /// @notice Allows or disallows `oracle` to call {pin}.
    /// @dev DEFAULT_ADMIN_ROLE only (V2Errors.NotAuthorized). An allow-list rather than one pointer: series pin their
    ///      SettlementOracle at creation and a market can move to a new oracle while series on the old one still
    ///      settle, so two oracles may share this source during a migration and each must be able to pin.
    /// @param oracle SettlementOracle.
    /// @param allowed True to allow.
    function setOracle(address oracle, bool allowed) external nonReentrant {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert V2Errors.NotAuthorized();
        isOracle[oracle] = allowed;
        emit OracleSet(oracle, allowed);
    }

    /*//////////////////////////////////////////////////////////////
                               IPriceSource
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPriceSource
    /// @dev The latest round with the window walk's sanity rules: oracle not paused, answer normalises, and the round
    ///      is within `maxRoundJumpBps` of its predecessor in the same phase (so the first round of a phase is not ok
    ///      until a second one prints). Age is deliberately not checked (the oracle applies spotMaxAge).
    function latest(address underlying) external view returns (bool ok, uint256 price, uint256 updatedAt) {
        FeedConfig memory cfg = feeds[underlying];
        if (cfg.feed == address(0) || _oraclePaused(underlying)) return (false, 0, 0);
        (bool decOk, uint8 dec) = _decimals(cfg.feed);
        if (!decOk) return (false, 0, 0);

        Round memory head = _read(cfg.feed, abi.encodeCall(IAggregatorV3.latestRoundData, ()));
        if (!head.exists) return (false, 0, 0);
        (bool headOk, uint256 headPrice) = PriceLib.normalizeAnswer(head.answer, dec);
        if (!headOk) return (false, 0, 0);

        uint80 id = head.id;
        for (uint256 reads = 1; reads < MAX_ROUND_READS; ++reads) {
            if ((id & AGGREGATOR_ROUND_MASK) <= 1) return (false, 0, 0);
            --id;
            Round memory prev = _read(cfg.feed, abi.encodeCall(IAggregatorV3.getRoundData, (id)));
            if (!prev.exists) return (false, 0, 0);
            // Same skip rule as the walk: a predecessor stamped after the head is a feed fault, not the head's
            // predecessor in time.
            if (prev.updatedAt > head.updatedAt) continue;
            (bool prevOk, uint256 prevPrice) = PriceLib.normalizeAnswer(prev.answer, dec);
            if (!prevOk || PriceLib.exceedsJump(headPrice, prevPrice, cfg.maxRoundJumpBps)) return (false, 0, 0);
            return (true, headPrice, head.updatedAt);
        }
        return (false, 0, 0);
    }

    /// @inheritdoc IPriceSource
    /// @dev The round walk described on the contract, over the configuration pinned for `end` when {pin} pinned it,
    ///      else the current one. Also not ok when that configuration has no feed, when `start >= end`, or when `end` is
    ///      still in the future (a round printed before `end` could still change the answer).
    function windowPrice(address underlying, uint40 start, uint40 end) external view returns (bool ok, uint256 price) {
        FeedConfig memory cfg = _configFor(underlying, end);
        if (cfg.feed == address(0) || start >= end || end > block.timestamp) return (false, 0);
        if (_oraclePaused(underlying)) return (false, 0);
        (bool decOk, uint8 dec) = _decimals(cfg.feed);
        if (!decOk) return (false, 0);

        Round memory r = _read(cfg.feed, abi.encodeCall(IAggregatorV3.latestRoundData, ()));
        uint256 reads = 1;
        // `bound`: the newest `updatedAt` the next accepted round may have, i.e. the moment it stops being in force.
        uint256 bound = end;
        // Sum of price x seconds in force inside [start, end]. Prices < 2^128 and seconds < 2^40: no overflow.
        uint256 weighted;
        // Price of the last accepted round. The next accepted round is its predecessor, so the jump rule compares them.
        uint256 newerPrice;
        bool covered;
        while (true) {
            if (!r.exists) return (false, 0);
            if (r.updatedAt <= bound) {
                (bool pOk, uint256 p) = PriceLib.normalizeAnswer(r.answer, dec);
                if (!pOk) return (false, 0);
                if (newerPrice != 0 && PriceLib.exceedsJump(newerPrice, p, cfg.maxRoundJumpBps)) return (false, 0);
                // This round was read only as the predecessor of the round in force at `start`: its check is done.
                if (covered) return (true, weighted / (end - start));
                if (r.updatedAt <= start) {
                    // `r.updatedAt <= start < 2^40`, so the sum cannot overflow.
                    if (r.updatedAt + cfg.maxStale < start) return (false, 0);
                    weighted += p * (bound - start);
                    covered = true;
                } else {
                    weighted += p * (bound - r.updatedAt);
                }
                bound = r.updatedAt;
                newerPrice = p;
            }
            if ((r.id & AGGREGATOR_ROUND_MASK) <= 1 || reads == MAX_ROUND_READS) return (false, 0);
            // The id asked for, not the one echoed back: a feed echoing another id cannot make the walk loop or jump.
            uint80 prevId = r.id - 1;
            r = _read(cfg.feed, abi.encodeCall(IAggregatorV3.getRoundData, (prevId)));
            r.id = prevId;
            ++reads;
        }
    }

    /// @inheritdoc IPriceSource
    /// @dev The round history is replayable, so there is nothing to store: always false, for every caller and time.
    function record(address, uint40) external pure returns (bool recorded) {
        return false;
    }

    /// @inheritdoc IPriceSource
    /// @dev Only an oracle on the allow-list (V2Errors.NotAuthorized). An expiry already pinned: returns without a log
    ///      when {pinnedFeeds} equals `feeds[underlying]` (feed, maxStale and maxRoundJumpBps), else reverts
    ///      V2Errors.PinMismatch. Otherwise reverts V2Errors.NoSource when the underlying has no feed, or copies
    ///      `feeds[underlying]` into {pinnedFeeds} and emits {FeedPinned}.
    function pin(address underlying, uint40 expiry) external nonReentrant returns (bytes4) {
        if (!isOracle[msg.sender]) revert V2Errors.NotAuthorized();
        FeedConfig memory cfg = feeds[underlying];
        PinnedFeed storage p = pinnedFeeds[underlying][expiry];
        if (p.pinned) {
            if (p.feed != cfg.feed || p.maxStale != cfg.maxStale || p.maxRoundJumpBps != cfg.maxRoundJumpBps) {
                revert V2Errors.PinMismatch();
            }
            return IPriceSource.pin.selector;
        }
        if (cfg.feed == address(0)) revert V2Errors.NoSource();
        (p.feed, p.maxStale, p.maxRoundJumpBps, p.pinned) = (cfg.feed, cfg.maxStale, cfg.maxRoundJumpBps, true);
        emit FeedPinned(underlying, expiry, cfg.feed, cfg.maxStale, cfg.maxRoundJumpBps);
        return IPriceSource.pin.selector;
    }

    /*//////////////////////////////////////////////////////////////
                                 INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev The configuration a window ending at `expiry` uses: the pinned copy when there is one, else the current.
    function _configFor(address underlying, uint40 expiry) private view returns (FeedConfig memory cfg) {
        PinnedFeed memory p = pinnedFeeds[underlying][expiry];
        if (!p.pinned) return feeds[underlying];
        return FeedConfig({feed: p.feed, maxStale: p.maxStale, maxRoundJumpBps: p.maxRoundJumpBps});
    }

    /// @dev One `latestRoundData` or `getRoundData` read. Not `exists` when the call reverts, returns fewer than the
    ///      five words, returns an id wider than uint80 (a proxy never does; decoding it as uint80 would revert), or
    ///      returns `updatedAt == 0` (a round the aggregator does not have).
    function _read(address feed, bytes memory callData) private view returns (Round memory r) {
        (bool success, bytes memory ret) = feed.staticcall(callData);
        if (!success || ret.length < 160) return r;
        (uint256 id, int256 answer,, uint256 updatedAt,) = abi.decode(ret, (uint256, int256, uint256, uint256, uint256));
        if (id > type(uint80).max || updatedAt == 0) return r;
        // casting to 'uint80' is safe because the line above returns on id > type(uint80).max
        // forge-lint: disable-next-line(unsafe-typecast)
        r = Round({exists: true, id: uint80(id), answer: answer, updatedAt: updatedAt});
    }

    /// @dev The feed's decimals, read on every call rather than cached at configuration: a proxy reports the decimals
    ///      of its current phase, and every round a walk uses is in that phase.
    function _decimals(address feed) private view returns (bool ok, uint8 dec) {
        (bool success, bytes memory ret) = feed.staticcall(abi.encodeCall(IAggregatorV3.decimals, ()));
        if (!success || ret.length < 32) return (false, 0);
        uint256 d = abi.decode(ret, (uint256));
        if (d > type(uint8).max) return (false, 0);
        // casting to 'uint8' is safe because the line above returns on d > type(uint8).max
        // forge-lint: disable-next-line(unsafe-typecast)
        return (true, uint8(d));
    }

    /// @dev The issuer's oracle halt flag, read now. Fails closed: a failed or short read counts as paused.
    function _oraclePaused(address underlying) private view returns (bool) {
        (bool success, bytes memory ret) = underlying.staticcall(abi.encodeCall(IOraclePausable.oraclePaused, ()));
        if (!success || ret.length < 32) return true;
        return abi.decode(ret, (uint256)) != 0;
    }
}
