// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IPriceSource
/// @notice One price adapter behind the SettlementOracle: ChainlinkFeedSource, UniV3TwapSource or DataStreamsSource
///         (ADR-05, architecture §3.3).
/// @dev Every price is USDG base units (6 dp) per whole share. `latest` and `windowPrice` never revert: a source
///      that cannot answer returns ok = false, which is what lets the oracle's fallback chain move to the next
///      source instead of stalling a payout. Per-market configuration (feed, pool, staleness, jump bounds, which
///      oracles may call {pin}) is CONFIG_ADMIN lane surface on each source (setFeed / setPool / setOracle, 24 h) and
///      not frozen here.
///
///      PINNING (INTERFACE_VERSION 6). SettlementOracle.pin calls {pin} on every source of a market when the first
///      series of an expiry is created, and the creation reverts unless every source pins. From then on
///      `windowPrice(underlying, start, expiry)` and `record(underlying, expiry)` answer with the configuration pinned
///      for that expiry, so a later configuration change cannot re-point a live series; `latest` keeps using the
///      current configuration.
interface IPriceSource {
    /// @notice The source's most recent price for `underlying`.
    /// @dev Anyone. Never reverts. `ok` does not depend on age: the caller applies its own freshness bound using
    ///      `updatedAt` (the oracle's per-market spotMaxAge).
    /// @param underlying 18-dp Stock Token the market is keyed by.
    /// @return ok False when the source has no sane value (unconfigured, answer <= 0, failed sanity checks).
    /// @return price USDG base units (6 dp) per whole share; meaningful only when ok.
    /// @return updatedAt Unix seconds of the observation.
    function latest(address underlying) external view returns (bool ok, uint256 price, uint256 updatedAt);

    /// @notice Time-weighted average price over `[start, end]`.
    /// @dev Anyone. Never reverts. The oracle asks for `[expiry - SETTLEMENT_WINDOW, expiry]`. A replayable source
    ///      (Chainlink round history) computes it on demand; a snapshot source (UniV3TwapSource) returns what
    ///      {record} stored for `(underlying, end)`, or ok = false when nothing was stored. When `end` is an expiry
    ///      {pin} pinned, the pinned configuration is used.
    /// @param underlying 18-dp Stock Token.
    /// @param start Window start, unix seconds.
    /// @param end Window end, unix seconds.
    /// @return ok False when the source cannot cover the window with sane data.
    /// @return price USDG base units (6 dp) per whole share; meaningful only when ok.
    function windowPrice(address underlying, uint40 start, uint40 end) external view returns (bool ok, uint256 price);

    /// @notice Stores whatever this source needs to answer `windowPrice` for `expiry` later.
    /// @dev Anyone; SettlementOracle.snapshot is the normal caller. Idempotent. UniV3TwapSource stores only inside
    ///      `[expiry, expiry + SNAPSHOT_GRACE]` because `pool.observe` is relative to now; sources that are replayable
    ///      store nothing.
    /// @param underlying 18-dp Stock Token.
    /// @param expiry Series expiry, unix seconds.
    /// @return recorded true only the first time something was stored for (underlying, expiry)
    function record(address underlying, uint40 expiry) external returns (bool recorded);

    /// @notice Pins this source's configuration of `underlying` for `expiry`: `windowPrice(underlying, start, expiry)`
    ///         and `record(underlying, expiry)` use the pinned copy from then on, whatever the configuration becomes.
    /// @dev Only an oracle the CONFIG_ADMIN lane registered on the source (setOracle, 24 h; V2Errors.NotAuthorized);
    ///      SettlementOracle.pin is
    ///      the caller, when the first series of an expiry is created. FAILS CLOSED: V2Errors.NoSource when the source
    ///      has no configuration for `underlying` (a source listed for a market must be able to price it), and, for an
    ///      expiry already pinned, V2Errors.PinMismatch unless the pinned copy equals the current configuration (then
    ///      it changes and logs nothing). A pin made earlier through another allowed oracle can therefore never be
    ///      confirmed by a series while the public configuration says something else. Answers `IPriceSource.pin.selector`
    ///      on success; SettlementOracle.pin refuses any other answer. Added in INTERFACE_VERSION 6.
    /// @param underlying 18-dp Stock Token.
    /// @param expiry Series expiry, unix seconds.
    /// @return pinned Always `IPriceSource.pin.selector`.
    function pin(address underlying, uint40 expiry) external returns (bytes4 pinned);
}
