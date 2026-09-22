# v2 Data Streams source (built, disabled)

`src/v2/oracle/DataStreamsSource.sol` is the third settlement price source of ADR-05. It prices a
Stock Token from Chainlink Data Streams RWA Advanced (v11) reports, verified on chain through the
Data Streams VerifierProxy. It is **not registered for any market by any script**. It stays
unused until the owner has Data Streams credentials. [V2-ARCHITECTURE.md §3.8](V2-ARCHITECTURE.md#38-enabling-data-streams)
summarises it and links here; this page stays the detailed reference.

The code is unaudited.

## What it does

- `submit(bytes[] signedReports)`: anyone can call it. Each report is routed by its feed id and
  verified with `VerifierProxy.verify(report, "")`. Data Streams is subscription billed, so no fee
  payload and no value are sent. A report that passes every rule becomes one observation:
  `floor(mid / 1e12) × uiMultiplier() / 1e18` USDG (6 dp) per share, with the multiplier read at
  submit. A report that fails is skipped with a `ReportSkipped(index, feedId, reason)` event, and
  the batch never reverts.
- Storage rules: verified v11 seconds-resolution body, feed id configured, `marketStatus == 2`
  (regular hours), `validFrom ≤ observation ≤ now`, observation at most `MAX_REPORT_AGE` = 60 s
  old, `expiresAt ≥ now`, mid last updated at most `MAX_MID_AGE` = 300 s before the observation,
  at least `MIN_OBSERVATION_SPACING` = 30 s after the underlying's newest observation, token
  `oraclePaused()` false, `uiMultiplier()` in (0, 1e30], price in (0, 2^128].
- Each underlying keeps its last `RING_SIZE` = 256 observations.
- `windowPrice(u, start, end)` needs all of the following:
  - at least 10 observations inside the window
  - no gap over 300 s between observations
  - first observation at or before `start + 300`
  - last observation at or after `end − 300`
  - the window sealed: `now > end + 60`, so no report from inside the window can still arrive
  - the ring still holding the observation before the window
  - the oracle not paused

  The price is time-weighted, and the first observation also covers the stretch back to `start`.
- `record(u, expiry)` stores the sealed settlement window once. The result survives the ring
  wrapping. It returns false (never reverts) until the window is ok.
- `latest(u)` is the newest observation, whatever its age. `inspectWindow` shows why a window is
  not ok.

The schema, the verifier interface and the market-status mapping come from Chainlink's
documentation and smartcontractkit sources. The commits are cited in
`src/v2/oracle/DataStreamsDeps.sol`:

- documentation `b3fe42d` (2026-09-11)
- chainlink-evm `593f99a` (2026-09-15)
- data-streams-sdk `f73484f` (2026-09-15)

Tests:

- `test/v2/unit/DataStreamsSource.t.sol`: a mock verifier, `src/v2/mocks/MockVerifierProxy.sol`
- `test/v2/fork/DataStreamsFork.t.sol`: the live proxy is "VerifierProxy 2.0.0", with a zero
  FeeManager and a zero access controller. An unsigned report is skipped, not reverted.

## Enabling Data Streams for a market

Every step below is **owner-gated** or admin-gated. Nothing here runs by itself.

1. **Owner buys access.** Get a Chainlink Data Streams mainnet subscription with an API key and
   secret, entitled to the market's **Regular Hours** stream. For example,
   `NVDA/USD-Streams-RegularHoursEquityPrice` has feed id
   `0x000b6aa036224454037bab103184565f6aa9ea589c3b349f6d8471ee753524b9`. Confirm the id in
   `callhouse/ops/markets/v2-sources.json` `dataStreamsFeedId` with the entitled account. R13 marks
   21 of the 35 ids as catalog candidates only.
2. **Prove one report on a fork.** Fetch a signed report (`fullReport`) during regular hours, then
   on a 4663 fork call `submit([report])`. Expect `ObservationStored`, not `ReportSkipped`. Check
   that `s_feeManager()` and `s_accessController()` on the VerifierProxy are still zero. If either
   is set, verification fails with `VerifyFailed`. The contract must then be allowlisted by
   Chainlink, or a fee-paying source must be built.
3. **Deploy** `DataStreamsSource(admin, 0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7)` if C2-13 did
   not already deploy it. Record the address in the registry under `v2.contracts.sources.dataStreams`.
4. **Admin sets the feed:** `setFeed(underlying, feedId)`. The id must start `0x000b`, is unique
   per underlying, and the token must answer `uiMultiplier()`. Changing or removing a feed
   restarts that underlying's history and bumps its `feedVersion`: every expiry already pinned
   (INTERFACE_VERSION 6) whose window is not recorded yet stops being priced by this source, and no
   other oracle can pin such an expiry again (`PinMismatch`). The deploy lists the SettlementOracle
   on the source (`setOracle`); check `isOracle(settlementOracle)` and `feedIdOf(underlying) != 0`
   before step 6. Pinning fails closed: while the market lists the source and either is missing,
   every first series of an expiry reverts `SourceNotPinned(dataStreamsSource, NotAuthorized)` or
   `SourceNotPinned(dataStreamsSource, NoSource)`
   (`PinnedSettlementTest.test_failClosed_oracleRevokedOnAnySource_blocksCreationUntilRestored`,
   `PinnedSettlementTest.test_failClosed_unconfiguredListedSource_blocksCreation`). So never list the
   source before its feed is set, and run VerifyV2 afterwards: its pin dry run fails on exactly this.
5. **Run the submitter first.** The keeper (K2-03) submits the latest Regular Hours report every
   60-120 s, at least from 15:25 to 16:00 New York on every expiry day. Reports must be submitted
   within 60 s of their observation, in time order, and at least 30 s apart. If the source will be
   priority 0, the keeper must submit at least once per `spotMaxAge` during the regular session:
   `SettlementOracle.spot()` reads source 0's `latest`. `spotMaxAge` is the market's own registry value,
   **90,000 s (25 h) at launch**, not the oracle's 1 h `DEFAULT_SPOT_MAX_AGE`, which applies only when a
   market is configured with 0.
   Three things read source 0 through that bound: the strike band on `createSeries`, the MakerVault's
   price guards, and — from INTERFACE_VERSION 7, with no extra bound of its own (owner sign-off c01) —
   the Clearinghouse's conversion floor. `AutoRoller.roll`, `reprice` and `cancelStale` read it too.
   Moving a market to a Data Streams source at priority 0 therefore moves ALL of them onto the
   submitter's liveness at once; a gap longer than `spotMaxAge` stops rolls and vault quoting and makes
   late third-party redemptions pay in kind.
6. **Admin adds the source at priority 0.** Set the market's source list on `SettlementOracle` with
   `DataStreamsSource` first, followed by `ChainlinkFeedSource` and `UniV3TwapSource`. **`VerifyV2` will
   then FAIL that market's source-list check**, which expects `[chainlink]` or `[chainlink, univ3]`: that
   refusal is deliberate (a non-Chainlink source at priority 0 also feeds `AutoRoller.cancelStale`'s
   trigger and the open grace, sweep contracts-c16), so switching a market to Data Streams is an owner
   decision that updates the verifier's expectation in the same change. The oracle
   emits `MarketSourcesSet`. The new list applies to expiries whose first series is created from
   then on: an expiry that already has a series keeps the list it pinned (architecture §3.3). For
   those new expiries, the keeper's `snapshot` call in `[expiry + 61 s, expiry + 600 s]` also records
   the Data Streams window.

Existing expiries are not affected by the order of events. `finalize` reads the sealed window at
`expiry + 120 s` or later.

**To disable,** the admin removes the source from the market's list (new expiries), then calls
`setFeed(underlying, 0)`, which also takes the source out of every pinned expiry not recorded yet. In
that order: the other way round, series creation stops in between (pinning fails closed on a listed
source without a feed id).
Snapshots already recorded stay readable. Taking the source out of a pinned expiry is not only a denial:
that expiry then settles on its other pinned sources alone, and with none of them answering
`adminResolve` takes any price from `expiry + 48 h` (architecture §6.6). Withholding reports has the same
effect, so list this source only next to sources the admin and the submitter cannot silence.

## Known limits

- **Early-close days.** The 15:30-16:00 window has no regular-hours prints on an NYSE early-close
  day, so this source is not ok there. The oracle falls back to the other sources.
- **Report selection.** The submitter picks which reports, at least 30 s apart, become
  observations. That can bias the average by the price movement between reports it could have
  picked. Corroboration within the market's `maxDeviationBps` bounds this.
- **Trading halts.** Chainlink does not flag halts. A mid that stops updating for more than 300 s
  is rejected (`StaleMid`), so a halt at the close leaves the window uncovered and the source not
  ok.
- **Real verification gas.** Gas of a real signed verification is unmeasured, because no signed
  report is available without credentials. Measure it in step 2.
