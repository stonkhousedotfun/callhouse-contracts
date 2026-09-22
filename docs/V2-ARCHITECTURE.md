# v2 architecture

How the Stonkhouse v2 contracts fit together, who can do what to them, how a settlement price is
chosen, how the permissionless keeper calls work, and what the contracts do not protect against.
[V2-ACCOUNTING.md](V2-ACCOUNTING.md) has the money maths. [V2-GAS.md](V2-GAS.md) has the gas
figures. [V2-DATA-STREAMS.md](V2-DATA-STREAMS.md) has the disabled Data Streams source.
[`src/v2/README.md`](../src/v2/README.md) maps every file.

> **Status.** This page describes **INTERFACE_VERSION 8**. The v2 contracts are **unaudited**: no
> external audit report exists at this commit, and this repository links to none. What stands behind
> the code is the test gate in [§9](#9-where-the-numbers-come-from), and under the owner's build-mode
> directive of 2026-09-19 those suites are written but are not run as a condition of shipping, so a
> figure here is only as good as the last run that produced it. Nothing in this document is deployed
> on chain 4663 under v8; the deploy is owner-gated. The code on branch `v2` is the specification.
> Where this page and the code disagree, the code wins.

> **Paths.** Paths resolve from the root of this repository, stonkhousedotfun/callhouse-contracts. A
> path followed by (stonkhousedotfun/callhouse) lives in the app repository and resolves from that
> repository's root.

> **Numbers.** Every number on this page comes from a test or a command. The test that asserts it
> is named next to it, test contract and function; the commands are in
> [§9](#9-where-the-numbers-come-from). Money is in USDG base units (6 decimals: `1_000_000` = 1.00
> USDG; the Clearinghouse refuses a USDG without 6 decimals,
> `ClearinghouseMarketsTest.test_constructor_rejectsBadUsdg`), prices are USDG base units per whole
> share, sizes are units of 0.01 share, rates are basis points (bps, `10_000` = 100 %;
> `InterfaceIdsTest.test_constants_units`).

---

## Contents

1. [Components](#1-components)
2. [Trust model](#2-trust-model)
3. [Oracle and settlement](#3-oracle-and-settlement)
4. [Keeper model](#4-keeper-model)
5. [Pauses: what stops and what never stops](#5-pauses-what-stops-and-what-never-stops)
6. [What is not protected](#6-what-is-not-protected)
7. [Things that look wrong but are not](#7-things-that-look-wrong-but-are-not)
8. [Decisions the plan left open](#8-decisions-the-plan-left-open)
9. [Where the numbers come from](#9-where-the-numbers-come-from)

---

## 1. Components

### 1.1 The contracts

Every contract is non-upgradeable: no proxy, no `delegatecall` into replaceable code, no
`selfdestruct`. A fix means a new contract and, for the core, a migration. From
INTERFACE_VERSION 8 every privileged function of every one of them is gated by a single
`AccessManager` rather than by a role table of its own ([§2.1](#21-roles)).

| Contract | File | What it holds | Who calls it |
|---|---|---|---|
| `Clearinghouse` | `src/v2/Clearinghouse.sol` | All collateral (USDG and every market's Stock Token), every account's free ledger, accrued exercise fees, the market table, every series and its settlement amounts. ERC-1155 long and short tokens for all markets | writers, holders, the OrderBook, the AutoRoller, keepers |
| `OrderBook` | `src/v2/OrderBook.sol` | USDG escrow of open bids, long tokens escrowed by resale asks, `owed` USDG it could not deliver | makers, takers, delegates, keepers (`prune`) |
| `SettlementOracle` | `src/v2/oracle/SettlementOracle.sol` | One settlement record per (underlying, expiry): status, captured source prices, candidate, final price. Holds no tokens | keepers, the Clearinghouse (`settle` finalizes inside), guardian, admin |
| `ChainlinkFeedSource` | `src/v2/oracle/ChainlinkFeedSource.sol` | Feed configuration only. Prices a window from the feed's round history on demand | the oracle |
| `UniV3TwapSource` | `src/v2/oracle/UniV3TwapSource.sol` | Pool configuration and one stored window price per (underlying, expiry) | the oracle (`snapshot`), anyone (`record`) |
| `DataStreamsSource` | `src/v2/oracle/DataStreamsSource.sol` | Built and **disabled**: no market uses it ([V2-DATA-STREAMS.md](V2-DATA-STREAMS.md)) | nobody yet |
| `AccessManager` | deployed from `src/v2/access/V8AccessManagerArtifact.sol` | The whole permission system: `(target, selector) → role`, who holds each role, and each member's execution delay. Holds no tokens | the Admin Safe and the four hot keys, and every `restricted` target asks it on every privileged call |
| `ExpiryCalendar` | `src/v2/ExpiryCalendar.sol` | The NYSE holiday set and special expiries | the Clearinghouse (new series), the AutoRoller |
| `KeeperRewards` | `src/v2/KeeperRewards.sol` | The bounty budget in USDG (treasury money) | registered protocol contracts |
| `PayoutRouter` | `src/v2/periphery/PayoutRouter.sol` | One route to USDG per Stock Token, over Uniswap v3 or a pinned hookless v4 pool, with the route's fee cached. Holds nothing between calls. Replaces `UniV3PayoutAdapter` for the Clearinghouse and the FeeSplitter (INTERFACE_VERSION 8) | the Clearinghouse (payout conversion), the FeeSplitter, anyone |
| `UniV3PayoutAdapter` | `src/v2/periphery/UniV3PayoutAdapter.sol` | The v7 adapter: one Uniswap v3 route per Stock Token. Still in the tree, superseded by `PayoutRouter`, and the last contract besides the OrderBook that has not moved to the manager | the Clearinghouse (payout conversion), anyone |
| `FeeSplitter` | `src/v2/periphery/FeeSplitter.sol` | The v8 fee sink: it takes the protocol's fees, converts them under an oracle ok-spot floor and splits them once between a buyback balance and the treasury | the OrderBook and Clearinghouse fee paths, keepers (`distribute`), the cranker key (`buyback`) |
| `V4BuybackExecutor` | `src/v2/periphery/V4BuybackExecutor.sol` | Spends the splitter's buyback balance in the pinned STONKHOUSE pool. Has no privileged function and no admin at all | the FeeSplitter only |
| `AutoRoller` | `src/v2/AutoRoller.sol` | Writers' strategies and current positions. Holds no collateral; forwards bounties it receives | writers, keepers (`roll`), the pricer key (`PRICER`, `reprice`) |
| `MakerVault` | `src/v2/mm/MakerVault.sol` | The protocol's market-making inventory (treasury money), its guard rails and exposure bookkeeping | `TREASURY_ADMIN` (funding and limits), the mm bot key (`QUOTER`) |
| `MakerRegistry` | `src/v2/mm/MakerRegistry.sol` | Per-maker rebate tiers | the OrderBook reads it on every fill |
| `RewardsDistributor` | `src/v2/mm/RewardsDistributor.sol` | Weekly Merkle roots and the USDG they pay (treasury money) | `TREASURY_ADMIN` posts roots, anyone pushes claims |

### 1.2 How they call each other

```
 writer ── deposit/withdraw/close ──►  Clearinghouse  ◄── createSeries/settle/redeem ── keeper
   │                                   ▲   │   ▲  │
   │ place AskWrite/Bid/AskResale      │   │   │  └── pin, settlementPrice, finalize ──────► SettlementOracle
   ▼                                   │   │   │                                               │ windowPrice / record / pin
 OrderBook ── mint on fill, escrow ────┘   │   └── convertPayout ──► UniV3PayoutAdapter        ▼
   ▲    └── rebateBps ──► MakerRegistry    │                          (Uniswap v3 SwapRouter02) ChainlinkFeedSource
   │                                        └── reward ──► KeeperRewards ◄── reward ──           UniV3TwapSource
 taker ── take                                                                               (DataStreamsSource, off)
 AutoRoller ── createSeries, placeFor/replace/prune (as the writer's delegate), settle, redeem, trySpot
 MakerVault ── deposit/withdraw (own ledger), place/replace/cancel/take (as maker and taker), close
```

There is no privileged keeper. Every lifecycle call is permissionless ([§4](#4-keeper-model)).

### 1.3 Series and tokens

A series is `(underlying, isPut, strike, expiry)`. It is shared by every writer and every holder.

```
longId  = uint256(keccak256(abi.encode(underlying, isPut, strike, expiry))) & ~1     (low bit 0)
shortId = longId | 1                                                                  (low bit 1)
```

`InterfaceIdsTest.testFuzz_longIdOf_isDocumentedFormula` and
`InterfaceIdsTest.test_seriesIdVectors_matchV2IdsAndReference` pin the formula against the vectors
in `test/v2/fixtures/series-ids.json`, which the TypeScript mirrors are tested against. Clearing one
bit halves the id space, so `createSeries` also compares the stored tuple and reverts
`SeriesIdCollision` rather than argue about the odds (`ClearinghouseSeriesTest.test_createSeries_idCollisionReverts`).

- **Units.** One ERC-1155 unit is 0.01 share; a whole share is 100 units
  (`InterfaceIdsTest.test_constants_units`). 0.1 share is 10 units.
- **Long.** The right to the payout at settlement. Fully fungible across writers.
- **Short.** Minted to the writer with every long. It is the claim on what is left of the collateral
  after the long is paid: at settlement, `collateralPerUnit - grossPayoutPerUnit`
  ([V2-ACCOUNTING.md §5](V2-ACCOUNTING.md#5-settlement)). A short carries no further obligation: the
  collateral is already locked.
- **Transferable.** Both are ordinary ERC-1155 tokens. Transfers are never paused
  (`ClearinghousePausesTest.test_pauseMatrix_beforeSettlement`). The OrderBook trades longs only;
  shorts move by transfer.
- **Close.** Anyone holding both a long and a short of an unsettled series can burn the pair and get
  the collateral back to the free ledger, before or after expiry, until the series settles
  (`ClearinghouseMintTest.test_close_afterExpiryUntilSettled`).
- **Metadata.** `uri(id)` is the admin-set base URI followed by the decimal id
  (`ClearinghouseMarketsTest.test_uri_isBasePlusDecimalId`).

### 1.4 The life of a contract

For an expiry `E` (16:00 New York on a session day, [§3.7](#37-calendar-holidays-early-closes-daylight-saving)).
Every offset in the table is a compiled constant asserted by `InterfaceIdsTest.test_constants_times`:

| When | What happens | Where |
|---|---|---|
| any time up to `E − 1 h`, at most 45 days ahead | anyone creates the series; it pins the market's current oracle and exercise fee, and the first series of `E` pins the settlement configuration of `E` on the oracle and every source ([§3.3](#33-capture-and-pinning)) | `Clearinghouse.createSeries` |
| until the mint cutoff `E − 1800 s` | writers deposit collateral and sell through write-on-fill asks; buyers take. From INTERFACE_VERSION 8 `mint` is callable only by an address on the Clearinghouse's minter allow-list, and at launch that is the OrderBook alone, so a writer reaches its own collateral through the book and not directly (`src/v2/Clearinghouse.sol:634`, `NotMinter`) | `Clearinghouse.mint`, `OrderBook.place` / `take` |
| from `E − 1800 s` | the settlement window starts: no new units can be written (`PastCutoff`); resale asks and bids still trade | `Clearinghouse.mintCutoff` |
| `E` | all trading on the book stops; `close` still works | every order's `validUntil` is at most `E` |
| `[E, E + 600 s]` | a keeper snapshots the pool's window price | `SettlementOracle.snapshot` |
| from `E + 120 s` | a keeper finalizes: corroborated prices are final at once, a single or disagreeing source becomes a candidate with a delay | `SettlementOracle.finalize` ([§3](#3-oracle-and-settlement)) |
| once final | anyone settles each series of the expiry; the three per-unit amounts are stored | `Clearinghouse.settle` |
| after settlement | keepers prune dead orders (returning escrowed longs to their makers), then redeem every holder of every long and short; holders need do nothing | `OrderBook.prune`, `Clearinghouse.redeemBatch` |
| any time | anyone sweeps accrued exercise fees to the fee recipient | `Clearinghouse.sweepFees` |

The integration test `LifecycleTest.test_lifecycle_weeklyLadder_callsAndPuts_itmAndOtm` runs this
whole table for calls and puts, in and out of the money, and checks every balance against an
independent model after every step.

---

## 2. Trust model

### 2.1 Roles

INTERFACE_VERSION 8 replaced v7's per-contract OpenZeppelin `AccessControl` tables with **one**
OpenZeppelin `AccessManager`. It maps `(target, selector) → uint64 role` and holds a per-(role,
member) **execution delay**: a member with a delay calls `schedule`, waits the delay out in public,
and only then executes. No target grants a role to anybody any more; each is a `Managed`
(`src/v2/access/Managed.sol`), which is `AccessManaged` with one change — an unauthorised caller
reverts the same `V2Errors.NotAuthorized()` (`0xea8e4eb5`) as every other v2 refusal, so one selector
still decodes every "you may not" in the system, and the keeper's, the MM bot's, the web's and the
monitor's revert decoders did not have to learn a second one.

The manifest is `script/v2/roles.v8.json`; `src/v2/access/V8Roles.sol` is its compiled mirror and the
access-matrix test compares the two. Every id and delay below is read from
`script/v2/roles.v8.json:3-28`, not from a plan document.

| Role | Id | Delay | Held by | What it reaches |
|---|---:|---:|---|---|
| `ADMIN` | 0 | 48 h | Admin Safe | the manager itself: grants, revokes, the selector map, role admins and role guardians. **No target function is mapped to it** (`script/v2/roles.v8.json:204`), so it is manager-only — an unmapped `restricted` selector falls to `ADMIN` by default, which is exactly the mistake the access-matrix test exists to catch |
| `FEE_MANAGER` | 1 | 48 h | Admin Safe | `OrderBook.setFeeParams`, `setMakerRegistry`, `setDiscountModule`; `MakerRegistry.setTier`; `KeeperRewards.setBounty` and `setDailyCap`; the FeeSplitter's split, cap and slippage setters (`script/v2/roles.v8.json:78-80,110-111,138,151-153`) |
| `MARKET_FEE_MANAGER` | 2 | 72 h | Admin Safe | `Clearinghouse.setMarketFees` and `setDefaultMarketFees` — the exercise fee and the collateral-rent dial. Its own role because it is the only 72 h lane, and a delay belongs to a (role, member) pair (`script/v2/roles.v8.json:65-66`, `src/v2/access/V8Roles.sol:14-16`) |
| `CONFIG_ADMIN` | 3 | 24 h | Admin Safe | pointers that decide where a call goes but never move money: market and default oracle, calendar, payout adapter, keeper rewards, the minter allow-list, the funding allow-list, the six price-source setters, the two payout routes, and `SettlementOracle.adminResolve` (`script/v2/roles.v8.json:67-72,82,86-89,94-104,112,118,146-147`) |
| `TREASURY_ADMIN` | 4 | 24 h | Admin Safe | everything that names or pays the treasury: both fee recipients, every `setTreasury`, `MakerVault.setLimits` / `withdraw` / `withdrawPosition`, `KeeperRewards.defund`, `RewardsDistributor.setRoot` / `defund`, and the FeeSplitter's wiring (`script/v2/roles.v8.json:73,81,113-114,122-125,141-143,154-159`) |
| `LISTING` | 5 | 1 h | Admin Safe | the listing surface: `registerMarket`, `setMarketListing`, `setMinRedeemPayout`, `setBaseUri`, the calendar's holidays and special expiries, `AutoRoller.setMinRollUnits` (`script/v2/roles.v8.json:61-64,106-107,117`). One hour, because a listing is reversible and cheap |
| `OPS_ADMIN` | 6 | 0 | Admin Safe | manager-only, like `ADMIN`: it is the role admin of `GUARDIAN`, `PRICER`, `QUOTER` and `BUYBACK` (`script/v2/roles.v8.json:29-34`), so a compromised hot key is revoked and rotated with two signatures and no delay. It can grant nothing else |
| `GUARDIAN` | 7 | 0 | guardian key **and** the Admin Safe | the instant risk brake: `Clearinghouse.setMintPaused` and `setCreatePaused`, `OrderBook.setTradingPaused`, `SettlementOracle.veto` and `unveto`, `PayoutRouter.clearRoute`, `FeeSplitter.setPaused`, `HouseVault.setQuotingPaused`, `Hedger.pause` (`script/v2/roles.v8.json:74-75,83,90-91,148,160,192,205`); and, from T-OP-159 (owner order 2026-09-22 05:55Z, "i dont want these numbers to have a delay at all"), **`HouseVault.setLimits`** (`:188`) — the House vault's risk caps, moved off TREASURY_ADMIN's 24 h lane, the one guardian power that can loosen as well as tighten ([§2.3](#23-every-guardian-power-and-its-worst-case), `V8-ACCEPTED-RISKS.md`). It is also the **role guardian** of roles 1-5 (`script/v2/roles.v8.json:35-41`): [§2.3](#23-every-guardian-power-and-its-worst-case) |
| `PRICER` | 8 | 0 | pricer bot key | `AutoRoller.reprice`, and nothing else (`script/v2/roles.v8.json:119`) |
| `QUOTER` | 9 | 0 | mm bot key **and** the Admin Safe | the ten `MakerVault` quoter entry points (`script/v2/roles.v8.json:126-135`). The Safe is a member too, so it can cancel and close in an emergency; v7's "quoter OR admin" check inside the vault is gone |
| `BUYBACK` | 10 | 0 | cranker key | `FeeSplitter.buyback(minTokenOut)`, and nothing else (`script/v2/roles.v8.json:161`) |
| anyone | — | — | keepers, users | every lifecycle call ([§4](#4-keeper-model)) |

Holders are `script/v2/roles.v8.json:42-58`. The Admin Safe holds nine of the eleven roles, including
`GUARDIAN`, so it needs no grant to pause; the plan's Safe is 2-of-3 with all three keys the owner's
(owner decisions V3-D1 and V3-D10), which nothing in this repository enforces — the manifest knows only
an address.

**Two delays, not one, on a fee change.** The Admin Safe first `schedule`s the call on the manager and
waits out the role's execution delay; only then does the call reach the target. An `OrderBook` fee
change then waits its own compiled `FEE_CHANGE_DELAY` on top, so a fee change is visible for 48 h
before it is even scheduled on the book and takes another 48 h to bite
(`src/v2/interfaces/V2Constants.sol:55-60`, [§6.9](#69-fee-changes-between-a-quote-and-a-take)).

**Grant delays and target admin delays are 0, deliberately.** `AccessManager.setGrantDelay` and
`setTargetAdminDelay` need at least five days (`minSetback`) to take effect, so v8 does not use them:
a role or mapping change is an `ADMIN` call and is delayed by `ADMIN`'s own 48 h instead
(`script/v2/roles.v8.json:203`, `src/v2/access/V8Roles.sol:22-24`). A scheduled operation expires one
week after it becomes ready (`src/v2/access/V8Roles.sol:25`), so a change nobody executes lapses
rather than waiting forever.

**No EOA holds a delayed lane.** The deployer is the manager's initial admin, wires every mapping
with no delay, grants the roles with their delays and renounces `ADMIN` in the same batch. The
manifest requires that no EOA end up holding roles 0-6 and names `VerifyV8` as the checker
(`script/v2/roles.v8.json:206`); no such script exists in `script/v2` at this commit, so for now that
requirement is written down rather than checked. The four hot keys — guardian, pricer, quoter,
cranker — hold only the instant roles 7-10, which is the trade `OPS_ADMIN` pays for: they can act
with no delay, and they can be revoked with no delay.

**Deliberately unrestricted.** Some entry points look privileged and carry no role on purpose. The
access-matrix test asserts each is *not* restricted, so a later task cannot quietly add a gate, or
forget one, without the manifest moving (`script/v2/roles.v8.json:165-201`): `Clearinghouse.mint` (an
in-contract `isMinter` allow-list plus the writer-or-operator check, **not** a manager role, because
the book's two mint calls sit inside `try … {gas}` and a missing or delayed mapping would turn fills
into silent skips `quoteTake` had already promised) and `sweepFees`; `OrderBook.setFunding` (the maker
itself, and only after `CONFIG_ADMIN` allowed it with `setFundingAllowed`); `MakerVault.deposit`;
`AutoRoller.setStrategy`, `roll` and `cancelStale`; `PayoutRouter.refreshRouteFee` and `swapToUsdg`;
`FeeSplitter.claimOrderBookFees` and `distribute`; `V4BuybackExecutor.execute` (the FeeSplitter only,
checked in the contract — the executor has no privileged function and no admin at all, which is why
its manifest entry is empty); `KeeperRewards.fund` and `reward`; `RewardsDistributor.fund` and `claim`.

**What is wired at this commit, and what is not.** Every target above is a `Managed` carrying
`restricted` except two. `OrderBook` still holds v7's `onlyRole(DEFAULT_ADMIN_ROLE)` on all five of
its setters — `setFeeParams`, `setFeeRecipient`, `setMakerRegistry`, `setDiscountModule` and
`setFundingAllowed` — until `C8-03` and `C8-13` land
(`src/v2/OrderBook.sol:573,587,597,625,636`; the last two carry a `v8-stub` comment naming the task
and the role they become), and the superseded `UniV3PayoutAdapter` is never migrated because
`PayoutRouter` replaces it. The four v7 `bytes32` role constants survive in
`src/v2/interfaces/V2Constants.sol:175-182` only for those two; they are deleted with the last
AccessControl target and nothing v8 reads them (`src/v2/interfaces/V2Constants.sol:162-171`). Read
this section as the manifest the deploy path is being built against, not as a claim about bytecode
that is still being migrated — where the two disagree, the manifest is the target and the source is
the fact.

**The one-line model.** No role can move, freeze or seize a user's free collateral or tokens, and
`close`, `withdraw`, `redeem`, ERC-1155 transfers, order `cancel`, `prune` and `claimOwed` have no
pause. `CONFIG_ADMIN` configures how prices are taken, but that configuration is **pinned per expiry
when its first series is created** (owner decision 2026-09-17, [§3.3](#33-capture-and-pinning)): once
anyone can hold a series, no privileged call re-points its sources, loosens their bounds or changes its
deviation or delay. What is left over a live series is `adminResolve` inside the band of the recorded
prices from `E + 48 h` (any price only when no pinned source ever answered; a factor of 1.25 either way
around a lone recorded price the guardian vetoed, from `E + 7 days`) — a `CONFIG_ADMIN` call, so
scheduled 24 h in public first — and lifting the guardian's veto, which is a `GUARDIAN` call and
instant ([§2.2](#22-every-admin-power-and-its-worst-case)). Configuration changes still reach every
expiry nobody has created a series for. Pinning fails closed: a series is created only with the oracle
and every one of its sources pinned, and a pin made outside a series creation (a "hidden pre-pin") can
only stop series creation on that expiry, never be settled on
([§3.3](#33-capture-and-pinning), [§6.6](#66-the-admin-key)).

### 2.2 Every admin power and its worst case

"Bound" is what the bytecode enforces. "Worst case" assumes the holder is hostile. Each block names
the v8 role that reaches it and that role's execution delay: the call is scheduled on the manager,
sits in public for the delay, and `GUARDIAN` can cancel it the whole time it waits
([§2.3](#23-every-guardian-power-and-its-worst-case)). The instant rows are the ones `GUARDIAN`,
`PRICER`, `QUOTER` and `BUYBACK` hold, which is what makes them a brake and a bot and not an admin.

**SettlementOracle** (`CONFIG_ADMIN`, 24 h; `unveto` is `GUARDIAN` and instant)

| Function | Effect | Bound | Worst case |
|---|---|---|---|
| `setMarket(underlying, sources, maxDeviationBps, uncorroboratedDelay, spotMaxAge)` | Source list and parameters for `spot` now and for every expiry **no series has pinned yet** (and not captured). 0 means the default | at most 8 sources, none zero, codeless or listed twice; deviation at most 1000 bps; delay 30 min to 24 h; spot age at most 4 days (`SettlementOracleConfigTest.test_setMarket_bounds`, `V2DocsNumbersTest.test_docs_contractConstants`) | **Live series are not reachable.** The first series of an expiry pinned its list, deviation and delay: an agreeing source added afterwards is never asked, a wider deviation or shorter delay does not apply, and an emptied list does not open `adminResolve` to any price (`SettlementOraclePinTest.test_pinned_adminAddedAgreeingSource_cannotFinalize`, `SettlementOraclePinTest.test_pinned_widerDeviationAndShorterDelay_doNotApply`, `SettlementOraclePinTest.test_pinned_emptiedMarket_adminResolveStaysBanded`, `PinnedSettlementTest.test_pin_adminAddsAnAgreeingSource_cannotFinalizeTheLiveSeries`). What remains: series created after the change settle on it (visible in `SettlementConfigPinned` and `settlementConfig` before anyone trades them; `PinnedSettlementTest.test_pin_adminRepointsFeedAndPoolAfterCreation_liveSeriesSettleOnTheirPin`); an empty list stops new series (`PinnedSettlementTest.test_pin_createSeriesNeedsSourcesAndTheClearinghousePointer`); `spot`, and so the strike band, the AutoRoller's strikes and the MakerVault's guards, follows the change at once (`SettlementOraclePinTest.test_spot_readsTheCurrentConfigurationNotThePin`). Expiries with no series settle on the current list. A series is not a position: `createSeries` is permissionless and needs no collateral, so anyone can pin any valid expiry up to 45 days ahead for the gas of its first series, with nobody holding it, and a change then reaches only expiries still without series (`PinnedSettlementTest.test_pin_aSeriesNobodyHoldsStillPinsItsExpiry`; sweep contracts-c13, accepted) |
| `adminResolve(underlying, expiry, price)` | Finalizes a Pending, Held or None expiry | only from `E + 48 h`; not once final; price in `[min ok × (10_000 − dev) / 10_000, max ok × (10_000 + dev) / 10_000]` over the captured ok prices with the pinned deviation; it captures the expiry's pinned sources first; **any** price when no source was ok; from `E + 7 days`, a **Held** expiry with exactly one ok price p takes `[p × 0.8, p / 0.8]`, floored, because after a veto of a lone price nothing can record a second one (sweep contracts-c12) (`SettlementOracleResolveTest.test_adminResolve_heldSingleSource_widensAfterSevenDays`, `SettlementOracleResolveTest.test_adminResolve_wideBandOnlyForAHeldExpiryWithOneOkPrice`, `PinnedSettlementTest.test_vetoedWrongSingleSource_settlesAtTheMarketPriceFromSevenDays`, `SettlementOracleResolveTest.test_adminResolve_outOfBandReverts`, `SettlementOracleResolveTest.test_adminResolve_noSources_anyPrice_badPrice`, `PinnedSettlementTest.test_pin_adminEmptiesTheMarketAndRemovesTheSources_resolveStaysBanded`, `InterfaceIdsTest.test_constants_times`) | Picks the band edge (up to the pinned deviation beyond the recorded extremes) for any expiry still unsettled 48 h after expiry; for an expiry with a single ok price that it vetoed (holding every guardian power), any price within a factor of 1.25 of it from 7 days after expiry, which covers every expiry of a Chainlink-only market and every pool market whose snapshot was missed; or any price for an expiry none of whose pinned sources ever answered (a missed pool snapshot and a feed replay that ran out, [§6.3](#63-sequencer-censorship-and-outages); on a market that lists the Data Streams source, also that source taken out by a feed change or withheld reports, [§6.6](#66-the-admin-key)) |
| `unveto(underlying, expiry)` (`GUARDIAN`, instant) | Held → Pending, delay restarted | not once final | Lifts the guardian's veto; the candidate finalizes after the expiry's pinned delay |
| `setClearinghouse`, `setKeeperRewards` | Bounty gate and payer; the Clearinghouse pointer is also the only caller of `pin` | none | Bounties stop, or a payer spends its own budget. A bounty call can never block a settlement (`SettlementOracleBountyTest.test_bounty_failuresNeverRevert`). A zero or wrong Clearinghouse pointer stops series creation (`SettlementOraclePinTest.test_pin_onlyTheClearinghouse`). Pointed at the admin itself, it lets the admin pin an expiry before its first series, but that pin can only **block** the expiry: the oracle records who pinned (`pinnedBy`), and the real Clearinghouse's next series must confirm the pin against the market's current configuration, reverting `PinMismatch` while they differ (`SettlementOraclePinTest.test_pin_hiddenPrePin_blocksTheClearinghouse`, `SettlementOraclePinTest.test_pin_confirmation_refusesEveryDifference`, `PinnedSettlementTest.test_hiddenPrePin_throughTheClearinghousePointer`). The pin is public (`SettlementConfigPinned` without a `SeriesCreated`, `settlementConfig`, `pinnedBy`) and VerifyV8's pin dry run fails on the next expiry (`VerifyV8Test.test_verify_pinDryRun`). The same trick on an expiry that already has series moves `pinnedBy` to the admin's account, so its next series must confirm again: a denial while the configuration differs, never a price |

**Price sources** (`CONFIG_ADMIN`, 24 h)

| Function | Effect | Bound | Worst case |
|---|---|---|---|
| `ChainlinkFeedSource.setFeed(underlying, feed, maxStale, maxRoundJumpBps)` | Which feed, staleness bound and jump bound price every window of an expiry **not pinned yet**, and `spot` | feed has code; `maxStale` 1 h to 7 days; jump 1 to 5000 bps (`ChainlinkFeedSourceTest.test_admin_boundsAndInputs`) | Same as `setMarket`: future series only. A pinned expiry keeps its feed and bounds, even when the feed is removed (`ChainlinkFeedSourceTest.test_pin_repointedOrRemovedFeed_pinnedWindowUnchanged`, `ChainlinkFeedSourceTest.test_pin_loosenedBounds_doNotReachThePinnedWindow`). An underlying without a feed cannot be pinned, so removing the feed of a listed source stops new series of new expiries (`ChainlinkFeedSourceTest.test_pin_unconfigured_reverts`, `PinnedSettlementTest.test_failClosed_unconfiguredListedSource_blocksCreation`); a pin of an expiry pinned before is confirmed only against an equal configuration (`ChainlinkFeedSourceTest.test_pin_repinOfAChangedConfiguration_reverts`) |
| `UniV3TwapSource.setPool(underlying, pool, minLiquidity, window)` | Which pool and floor the snapshots of expiries **not pinned yet** read, and `latest` | the pool must hold exactly USDG and the underlying and its observation ring at least 2401 observations (`slot0().observationCardinality`, [§3.2](#32-the-sources); `UniV3TwapSourceTest.test_admin_setPool_refusesAnObservationRingShallowerThanTheGrace`); `window` 60 to 3600 s; `minLiquidity` may be 0 (`UniV3TwapSourceTest.test_admin_setPool_rejects`) | A shallow pool with no floor for future series. A pinned expiry records its pinned pool with its pinned floor (`UniV3TwapSourceTest.test_pin_repointedPool_recordReadsThePinnedPool`, `UniV3TwapSourceTest.test_pin_droppedFloor_doesNotReachThePinnedExpiry`). Snapshots already recorded stay (`UniV3TwapSourceTest.test_admin_removePool_keepsSnapshots`). Removing the pool while the market lists the source stops new series of new expiries (`UniV3TwapSourceTest.test_pin_noPool_reverts`), and a pin of an expiry pinned before is confirmed only against an equal configuration (`UniV3TwapSourceTest.test_pin_repinOfAChangedConfiguration_reverts`) |
| `DataStreamsSource.setFeed(underlying, feedId)` | Data Streams feed id; a change restarts the history and bumps `feedVersion` | v11 prefix, one underlying per id (`DataStreamsSourceTest.test_admin_setFeed_rejects`) | None today: no market lists the source. Once one does, a change after the pin takes this source out of every pinned expiry whose window was not recorded yet (never another stream's price: `DataStreamsSourceTest.test_pin_feedChangedAfterPin_notOkForThatExpiry`; but the expiry then settles on its other pinned sources alone, and with none of them answering `adminResolve` takes any price, [§6.6](#66-the-admin-key)), and no other oracle can pin that expiry again; listed without a feed id, it stops series creation (`DataStreamsSourceTest.test_pin_unconfiguredOrMovedVersion_reverts`, `PinnedSettlementTest.test_failClosed_unconfiguredListedSource_blocksCreation`) |
| `setOracle(oracle, allowed)` on each of the three sources | Which SettlementOracles may call the source's `pin` (an allow-list: two oracles may share a source while a market migrates) | none | Delisting the oracle on a source the market lists stops the creation of every first series of an expiry (`SourceNotPinned(source, NotAuthorized)`); it can no longer leave a source unpinned under a series and re-point it afterwards (`PinnedSettlementTest.test_failClosed_oracleRevokedOnAnySource_blocksCreationUntilRestored`, `PinnedSettlementTest.test_pin_noGasLimitCreatesASeriesWithAnUnpinnedSource`, `VerifyV8Test.test_verify_pinWiringDrift`). Listing itself lets the admin pin a source's configuration for an expiry before its first series, but a later pin confirms only a copy equal to the source's current configuration, so a hidden pre-pin refuses the series (`SourceNotPinned(source, PinMismatch)`) instead of settling it (`PinnedSettlementTest.test_hiddenPrePin_throughEachSourceAllowList`); VerifyV8 fails when the admin or the cranker is on an allow-list |

**Clearinghouse** (role per row: `LISTING` 1 h, `MARKET_FEE_MANAGER` 72 h, `CONFIG_ADMIN` 24 h, `TREASURY_ADMIN` 24 h)

| Function | Effect | Bound | Worst case |
|---|---|---|---|
| `registerMarket(underlying, strikeTick, enabled)`, `setMarketListing(underlying, enabled, strikeTick)` (`LISTING`, 1 h) | `enabled` gates `createSeries` and `mint` at once; the strike tick applies to **series created afterwards** only | 18-decimal token; tick a non-zero multiple of 100; a v8 market always registers unpaused, so `mintPaused` is the guardian's alone (`src/v2/Clearinghouse.sol:257`; `ClearinghouseMarketsTest.test_registerMarket_rejectsNon18DecimalTokens`, `ClearinghouseMarketsTest.test_registerMarket_strikeTickBounds`) | Delisting a market stops its new series and mints; nothing already written moves. An hour of delay, cancellable by the guardian |
| `setMarketFees(underlying, exerciseFeeBps, mintFeePpm)`, `setDefaultMarketFees(exerciseFeeBps, mintFeePpm)` (`MARKET_FEE_MANAGER`, 72 h) | the exercise fee and the collateral-rent dial, both pinned into **series created afterwards** only | exercise fee at most `EXERCISE_FEE_CEIL_BPS` 200 bps; `mintFeePpm` at most `MINT_FEE_CEIL_PPM` 5000 ppm, which the contract states as 0.5 % of the locked collateral per `MINT_FEE_PERIOD` of 7 days of remaining life (`CeilingExceeded`; `src/v2/interfaces/V2Constants.sol:96-99`, `:64-68`, `:76-77`; `ClearinghouseMarketsTest.test_registerMarket_exerciseFeeCeiling`) | Existing series and resting orders keep the rate and fee pinned at their creation (`ClearinghouseSettleTest.test_settle_feePinnedAtCreation`), and anyone can pre-create series up to 45 days out at today's rate, so a raise reaches those only at their next creation. **The launch rate is 0 on every market and on the default** (`ops/markets/tier1.json` `v2.fees.mintFeePpm` and every `markets[].v2.mintFeePpm`, stonkhousedotfun/callhouse), so the ceiling is not a multiple of anything at launch: it is the whole distance from charging writers nothing to charging them 0.5 % a week. The seller's fee is the premium fee of [§6.9](#69-fee-changes-between-a-quote-and-a-take) instead, and 72 h is the longest lane in the manifest precisely because this row is the one that can start charging a fee that does not exist today. The monitor warns on a `MarketConfigSet` that raises a rate and the notifier alerts the market's AutoRoller writers (sweep contracts-c05) |
| `setMarketOracle(underlying, oracle)`, `setDefaultOracle(oracle)` (`CONFIG_ADMIN`, 24 h) | which oracle **series created afterwards** pin | oracle has code (`ClearinghouseMarketsTest.test_registerMarket_rejectsOracleWithoutCode`) | Points new series at an oracle that never finalizes (their collateral is then stuck, except for `close` by whoever holds both sides) or finalizes at any price. Existing series keep their pinned oracle (`ClearinghouseSettleTest.test_settle_oraclePinnedAtCreation`). Every `SeriesCreated` log carries the oracle and the pinned `mintFeePpm`: integrations should refuse a series whose oracle is not the published SettlementOracle |
| `setMinter(minter, allowed)` (`CONFIG_ADMIN`, 24 h) | who may call `mint` at all. At launch the only minter is the OrderBook, so every long that exists was created inside a fill with a known premium ([V2-ACCOUNTING.md §3.3](V2-ACCOUNTING.md#33-collateral-rent-the-writer-fee)) | an in-contract allow-list, deliberately not a manager role (`script/v2/roles.v8.json:167-169`): the book's two mint calls sit inside `try … {gas}`, so a missing or delayed mapping would turn fills into silent skips that `quoteTake` had already promised | Removing the book stops every write-on-fill and `writeToSell` fill and every AutoRoller roll; it moves no balance. Adding a venue lets that venue mint at a price the protocol does not see, which is the whole point of the 24 h lane and the public schedule |
| `setCalendar(calendar)` (`CONFIG_ADMIN`, 24 h) | Expiry validation for new series, and the AutoRoller's session and expiry reads | has code (`ClearinghouseMarketsTest.test_setCalendar`) | A calendar that accepts any instant: series at a time no source can price, which only `adminResolve` can settle. Existing series keep their expiry (`ClearinghouseSeriesTest.test_createSeries_newCalendarAppliesToNewSeries`) |
| `setPayoutAdapter(adapter, maxSlippageBps)` (`CONFIG_ADMIN`, 24 h) | Converts ITM call payouts to USDG; the bound is measured above each route's pool fee, 30 bps at launch, so floors of 35, 60 and 130 bps below value on the 0.05 %, 0.30 % and 1 % pools ([§6.8](#68-conversion-slippage-and-who-captures-it)) | slippage at most 300 bps; the adapter's route fee counts at most 100 bps and bound + fee at most 300 bps; the Clearinghouse itself checks the USDG received against value at the settlement price, or at a fresh spot above it (`ClearinghouseMarketsTest.test_setPayoutAdapter_ceilingAndRole`, `ClearinghousePayoutTest.test_floor_routeFeeClampedToMax`, `ClearinghousePayoutTest.test_floor_totalCappedAtCeiling`) | Each converted payout is paid up to 300 bps below its value at the settlement price, or falls back to in kind. An adapter that misreports its route fee moves the floor by at most 100 bps, and a failed read counts as 0 (`ClearinghousePayoutTest.test_floor_badRouteFeeReadCountsAsZero`). Holders who chose in kind are not exposed (`ClearinghousePayoutTest.test_convert_stealAttemptTakesNoMore`, `ClearinghousePayoutTest.test_convert_belowMinOut_paysInKind`). The USDG is counted at the Clearinghouse, so an adapter cannot meet the floor with the holder's own USDG (`ClearinghousePayoutTest.test_convert_adapterPayingWithTheHoldersOwnUsdg_paysInKind`) |
| `setKeeperRewards(rewards)` (`CONFIG_ADMIN`, 24 h) | Bounty payer for SETTLE and REDEEM, called raw with the remaining gas | has code or zero (`ClearinghouseMarketsTest.test_setKeeperRewards`) | A payer that burns gas makes keeper calls cost what they are given; it cannot revert a settlement or re-enter the Clearinghouse (`ClearinghouseSettleTest.test_settle_bountyPayerFailuresDoNotBlock`) |
| `setFeeRecipient` (`TREASURY_ADMIN`, 24 h); `setMinRedeemPayout`, `setBaseUri` (`LISTING`, 1 h) | Where swept exercise fees go — the FeeSplitter at launch; the REDEEM bounty threshold, which also gates the SETTLE bounty on the series' collateral value; token metadata base | recipient non-zero (`ClearinghouseMarketsTest.test_setFeeRecipient`) | Protocol fees redirected out of the splitter; misleading token metadata in wallets. No user balance moves |

**OrderBook** (`FEE_MANAGER` 48 h, `TREASURY_ADMIN` 24 h, `CONFIG_ADMIN` 24 h, `GUARDIAN` instant)

| Function | Effect | Bound | Worst case |
|---|---|---|---|
| `setFeeParams(fees)` (`FEE_MANAGER`, 48 h) | **Schedules** a fee change. It takes effect 48 hours later, from the first block with `block.timestamp >= effectiveAt`, for every `take` from then on, **including fills of resting orders**. `FeeParamsScheduled(params, effectiveAt)` announces it and `pendingFeeParams()` returns it until then; `feeParams()` returns the fees in effect. A second schedule before `effectiveAt` replaces the first and restarts the delay; scheduling the fees in effect cancels a pending change | the delay is compiled at 48 h, raised from 24 h by INTERFACE_VERSION 8 (owner decision V3-D13, `src/v2/interfaces/V2Constants.sol:55-60`) (`InterfaceIdsTest.test_constants_times`, `OrderBookFeeDelayTest.test_setFeeParams_schedulesTwentyFourHoursAhead_inEffectAtExactlyEffectiveAt`, `OrderBookFeeDelayTest.test_setFeeParams_rescheduleBeforeDue_replacesAndRestartsTheDelay`, `OrderBookFeeDelayTest.test_setFeeParams_schedulingTheFeesInEffect_cancelsAPendingChange`); checked when the change is scheduled: premium and resale fee at most 1000 bps, taker flat fee at most 1 USDG, taker cap at most 1000 bps, rebate share at most 10_000 bps (`OrderBookFeeDelayTest.test_setFeeParams_ceilingsRevertWhenScheduling`, `OrderBookOrdersTest.test_setFeeParams_onlyAdminAndUnderCeilings`, `InterfaceIdsTest.test_constants_feeCeilings`) | Makers' resting orders fill with a 10 % seller fee; takers pay `min(1 USDG, 10 % of premium)`. Not before 48 hours after the change is on chain, and not before another 48 hours of `FEE_MANAGER` delay before that: makers can cancel and takers can stop in either window, and the guardian can cancel the scheduled operation in the first. A fill before `effectiveAt` pays the old fees and one from `effectiveAt` the new (`OrderBookFeeDelayTest.test_take_restingOrders_payOldFeesBeforeEffectiveAt_newFeesFromIt`, `OrderBookFeeDelayTest.testFuzz_fees_fillPaysTheLatestScheduleInEffectThatWasNotReplaced`). `TakeParams.maxTotalFee` IS enforced: `take` computes the taker fee plus, when selling into bids, the taker's own seller fees, and reverts `V2Errors.FeeAboveMax(totalFee, maxTotalFee)` before any USDG moves (`src/v2/OrderBook.sol:458-463`). A caller that wants the quoted fees or nothing passes the quote's total; a caller that passes `type(uint128).max` has opted out of that bound ([§6.9](#69-fee-changes-between-a-quote-and-a-take)) |
| `setFeeRecipient` (`TREASURY_ADMIN`, 24 h); `setMakerRegistry`, `setDiscountModule` (`FEE_MANAGER`, 48 h); `setFundingAllowed` (`CONFIG_ADMIN`, 24 h) | Where the protocol's share of each take goes — the FeeSplitter at launch; per-maker rebate tiers; the v8 taker-fee discount module; which makers may be funded just in time | recipient not zero and not the book; a rebate is clamped so a take's rebates never exceed its taker fee (`OrderBookTakeTest.test_rebates_registryFailureModesFallBackOrClamp`); the registry is read once per fill with at most 30,000 gas and one word of its answer copied, so a registry that reverts, burns its gas or answers at length reads as the book default (`OrderBookTakeTest.test_rebates_registryBurningGasOrAnsweringHugeData_costsACapPerFill`) | Protocol fees redirected, or split differently between makers and the fee recipient. Takers and makers pay the same, and a take costs at most 30,000 more gas per fill. A hostile discount module cannot zero the taker fee: its answer is clamped to `MAX_DISCOUNT_BPS`, 50 % of the taker fee, and it is read once per take with `DISCOUNT_READ_GAS` 30,000, a revert or a short return counting as no discount (`src/v2/interfaces/V2Constants.sol:105-112`) |
| `setTradingPaused(paused)` (`GUARDIAN`, instant) | The guardian's switch; the Admin Safe holds `GUARDIAN` too, so it needs no grant to use it | `cancel`, `prune`, `claimOwed` never pause | See [§2.3](#23-every-guardian-power-and-its-worst-case) |

**ExpiryCalendar** (`LISTING`, 1 h)

| Function | Effect | Bound | Worst case |
|---|---|---|---|
| `setHolidays(dayIndexes, isHoliday)`, `setSpecialExpiry(ts, allowed)` (`LISTING`, 1 h) | Which instants new series and the AutoRoller may use | none | No valid expiry for new series, or a whitelisted instant no source can price. Existing series keep their expiry (`ExpiryCalendarTest.test_admin_setHolidaysAddsAndRemovesWithEvents`, `ExpiryCalendarTest.test_special_acceptedButNeverWeeklyNorReturned`) |

**KeeperRewards** (`FEE_MANAGER` 48 h on the amounts, `CONFIG_ADMIN` 24 h on the callers, `TREASURY_ADMIN` 24 h on the budget)

| Function | Effect | Bound | Worst case |
|---|---|---|---|
| `setBounty(action, amount)`, `setDailyCap(amount)` (`FEE_MANAGER`, 48 h); `setCaller` (`CONFIG_ADMIN`, 24 h); `defund`, `setTreasury` (`TREASURY_ADMIN`, 24 h) | Who may ask for bounties, how much, the rolling cap, the budget | bounty at most 1 USDG (`InterfaceIdsTest.test_constants_feeCeilings`); the cap has no ceiling, the balance bounds it | The bounty budget (treasury USDG) is withdrawn or wasted. Lifecycle calls keep working with no bounty (`KeeperRewardsTest.test_usdg_callerIsNeverBlocked`) |

**AutoRoller** (`LISTING` 1 h, `CONFIG_ADMIN` 24 h, `PRICER` instant)

| Function | Effect | Bound | Worst case |
|---|---|---|---|
| `setMinRollUnits` (`LISTING`, 1 h); `setKeeperRewards` (`CONFIG_ADMIN`, 24 h) | ROLL bounty payer and threshold. Who may reprice is no longer set here: `PRICER` is granted on the manager by `OPS_ADMIN`, instantly, and revoked the same way | payer has code or zero (`AutoRollerStrategyTest.test_admin_setters_roleAndBounds`) | Roll bounties stop |
| `reprice(writer, underlying, price)` (`PRICER`, instant) | Replaces a smart-pricing writer's live ask | only writers with `smartPricing`; price inside the writer's own `[minAskBps, maxAskBps]` of spot; size and expiry kept (`AutoRollerStrategyTest.test_reprice_bandIsInclusiveAndExact`) | Every smart-pricing writer's ask sits at its own minimum. Writers without smart pricing are untouched |

**PayoutRouter** (`CONFIG_ADMIN` 24 h; `clearRoute` is `GUARDIAN` and instant)

`PayoutRouter` is the INTERFACE_VERSION 8 adapter and takes one route per Stock Token over Uniswap v3
(`setRouteV3(asset, fee)`) or a pinned hookless v4 pool (`setRouteV4(asset, fee, tickSpacing)`); both
refuse a zero tier and a tier above `MAX_ROUTE_FEE_TIER` with `RouteRejected(TIER)`, and `setRouteV3`
refuses a pair the v3 factory does not know (`src/v2/periphery/PayoutRouter.sol:68-81,83-100`).
`clearRoute(asset)` is the guardian's, and clearing a route is how a market is switched to in-kind
payouts with no delay at all. The bounds and the worst case are the v7 adapter's below, which the
Clearinghouse still enforces from its own side.

**UniV3PayoutAdapter**, the superseded v7 adapter (`DEFAULT_ADMIN_ROLE`; it never moved to the manager)

| Function | Effect | Bound | Worst case |
|---|---|---|---|
| `setRoute(asset, fee)` | The pool a Stock Token payout is sold in; its fee tier, reported by `routeFeeBps`, is added to the Clearinghouse's slippage bound for that market | the factory must know the pool (`UniV3PayoutAdapterTest.test_setRoute_rejectsMissingPool`); the fee tier is at most 10000, 1 % (`V2Constants.MAX_ROUTE_FEE_TIER`): the Clearinghouse counts at most 100 bps of route fee, so a costlier route would miss the floor on every ordinary conversion and pay in kind, and `setRoute` refuses it with `CeilingExceeded` (`UniV3PayoutAdapterTest.test_setRoute_rejectsFeeTierAboveOnePercent`, `UniV3PayoutAdapterTest.testFuzz_setRoute_feeTierCeiling`) | A thin pool: conversions miss the Clearinghouse's floor and pay in kind (`UniV3PayoutAdapterClearinghouseTest.test_redeem_badRate_fallsBackInKind`). A 1 % route where a 0.05 % pool exists moves the market's floor from 35 to 130 bps below value at launch, and holders pay the 1 % fee (`UniV3PayoutAdapterClearinghouseTest.test_redeem_launchBoundFloorPerFeeTier`) |

**MakerVault, MakerRegistry, RewardsDistributor** (treasury money, not user collateral)

| Function | Effect | Bound | Worst case |
|---|---|---|---|
| `MakerVault.setLimits`, `withdraw`, `withdrawPosition`, `setTreasury` (`TREASURY_ADMIN`, 24 h) | Treasury control of the vault. Granting `QUOTER` is not a vault call any more: `OPS_ADMIN` grants and revokes it on the manager, instantly | limits' bps at most 10_000; `maxDailyOutflow` has no ceiling and a new cap never refills time that has already passed (`MakerVaultGuardsTest.test_setLimits_boundsAndEvent`, `MakerVaultOutflowTest.test_outflowCap_setLimitsNeverRefillsRetroactively`) | The vault's funds, but only 24 h after the withdrawal is scheduled and visible, and the guardian can cancel it while it waits. From INTERFACE_VERSION 7 `setLimits` takes the full SIX-field tuple `(maxSeriesUnits, maxTotalNotional, askToleranceBps, maxBidBpsOfSpot, maxOrderLifetime, maxDailyOutflow)` -- an incident `cast` line that drops the last field will not compile against the deployed ABI |
| `MakerVault` quoter functions (`QUOTER`, instant) | Quote and trade the vault's inventory | asks never below `intrinsic − spot × askToleranceBps / 10_000`, bids never above `spot × maxBidBpsOfSpot / 10_000`, per-series and total notional caps, which keep counting a resale ask's escrowed longs after the ask expires until a cancel or prune returns them (sweep contracts-c15), at most 16 live orders per series (`MakerVaultGuardsTest.test_askFloor_itmCall`, `MakerVaultGuardsTest.test_bidCap_place`, `MakerVaultGuardsTest.test_seriesCap_bids`, `MakerVaultGuardsTest.test_seriesCap_expiredResaleEscrowStillCounts`, `MakerVaultGuardsTest.test_totalNotionalCap`, `MakerVaultGuardsTest.test_liveOrderCapPerSeries`, `V2DocsNumbersTest.test_docs_contractConstants`); no quoter call names a recipient but the vault (`MakerVaultQuoterTest.test_noEntryPointMovesValueElsewhere`) | Trades the vault's inventory badly inside the guards, repeatedly, until the role is revoked. No quoter call pays anyone but the vault, but value leaves through trades: the guards bound each trade, not turnover, so buying a partner's ask at the bid cap and selling the longs back into its one-tick bid returns exposure to 0 and leaves the partner the premium difference. Repeated, that moves the vault's whole USDG balance to the partner (`MakerVaultQuoterTest.test_compromisedQuoter_roundTripsMoveVaultUsdgToAPartner`; sweep contracts-c14). The key alone is enough, with no capital: the vault writes an out-of-the-money call into the key holder's one-tick bid, buys the longs back at the cap and closes the pair (`MakerVaultQuoterTest.test_compromisedQuoter_aloneNeedsNoCapital`; sweep contracts-c21), so a script can empty the vault before a person revokes the role. **Bounded from INTERFACE_VERSION 7 (sweep contracts-c21)** by `Limits.maxDailyOutflow`, a leaky bucket over `OUTFLOW_WINDOW` (24 h) on the NET USDG a quoter call pays out, measured as `usdg.balanceOf(vault) + orderBook.owed(vault)` immediately before and after the call: at most the cap at once and at most twice the cap in any 24 h, 2,500 USDG at launch. `place(Bid)`, `replace(Bid)` and `take` are booked and enforced (`OutflowCapExceeded(available, outflow)`); `cancel` naming a bid is booked and never enforced; asks, `close`, the ledger moves, `claimOwed` and `sync` are not booked at all, so the whole unwinding path keeps working -- a cap of 0 is a spend freeze, not a lock. Both PoCs now stop at the cap (`MakerVaultQuoterTest.test_compromisedQuoter_aloneIsHeldToTheOutflowCap`, `MakerVaultQuoterTest.test_compromisedQuoter_partnerIsHeldToTheOutflowCap`). What is still NOT bounded: option value sold cheaply inside the price guards and size caps and realised at settlement, about `maxTotalNotional x askToleranceBps / 1e4` (~2,500 USDG) per settlement cycle at launch limits. **INTERFACE_VERSION 8 removed the caller exemption**: v7 booked the admin's calls and never checked them, which was safe only while the mm-bot key never held `DEFAULT_ADMIN_ROLE` -- a `VerifyV2` FAIL that had to keep asserting a property of a key. `_bookOutflow` no longer consults `msg.sender` at all, so the bound is a property of the contract (`src/v2/mm/MakerVault.sol:135-139,652-654`), and it has to be, because the Admin Safe is itself a `QUOTER` member (`script/v2/roles.v8.json:52`) and the exemption would have covered a quoting Safe. Unwinding is still never blocked, because unwinding only ever credits the bucket: `cancel` is booked and never enforced, and `close`, `claimOwed`, `sync`, the ledger moves, `withdraw` and `withdrawPosition` are not booked at all. The one booked call that can charge while selling is `take`, which books whichever side it is on, so a selling take whose premium does not cover the flat taker fee is a net outflow and reverts `OutflowCapExceeded` at a cap of 0 -- v7 hid that case behind the exemption (`src/v2/mm/MakerVault.sol:143-146`). The remaining bounds are `OPS_ADMIN` revoking `QUOTER` on the manager, instantly, and the bot's off-chain realised-loss stop |
| `MakerRegistry.setTier(maker, bps)` (`FEE_MANAGER`, 48 h) | A maker's share of its taker-fee share | at most 10_000 bps (`MakerRegistryTest.test_setTier_adminOnlyBoundedAndLogged`) | Rebates redistributed between makers and the fee recipient |
| `RewardsDistributor.setRoot(epoch, root, total)`, `defund`, `setTreasury` (`TREASURY_ADMIN`, 24 h) | Posts an epoch's Merkle root once; withdraws | once per epoch; claims never exceed the posted total (`RewardsDistributorTest.test_claimsNeverExceedTheEpochTotal`) | A root that pays whoever the admin names, up to the balance |

**FeeSplitter** (`FEE_MANAGER` 48 h on the split, `TREASURY_ADMIN` 24 h on the wiring, `GUARDIAN` instant on the pause, `BUYBACK` instant on the buy)

| Function | Effect | Bound | Worst case |
|---|---|---|---|
| `setBurnBps(bps)`, `setBuybackCap(amount)`, `setConversionSlippageBps(bps)` (`FEE_MANAGER`, 48 h) | how the protocol's fees split between the buyback balance and the treasury, how much one buy may spend, and the floor the conversion must meet | the per-call cap is at most `BUYBACK_CAP_CEIL`, 1,000 USDG (`src/v2/interfaces/V2Constants.sol:133-137`); the launch split is 50/50 and the launch cap 50 USDG (`src/v2/periphery/FeeSplitter.sol:24,37-38`) | The whole fee stream directed to the treasury instead of the buyback, or the reverse. It reaches only fees the splitter has not distributed yet; no user balance is in the splitter |
| `setTreasury`, `setOrderBook`, `setRouter`, `setBuybackExecutor`, `setOracle`, `setToken` (`TREASURY_ADMIN`, 24 h) | the addresses the splitter pays, pulls from, converts through, buys through, prices against and burns | each is a setter so the splitter can be deployed before the things it points at exist; `setOracle` and `setToken` are not in the frozen interface and are mapped to `TREASURY_ADMIN` in the manifest precisely so they are not silent `ADMIN` (`script/v2/roles.v8.json:158-159`) | The fee stream pointed at an address of the holder's choosing, 24 h after it is scheduled in public, with the guardian able to cancel it and to pause the splitter meanwhile |
| `setPaused(bool)` (`GUARDIAN`, instant) | stops the splitter | — | fees accumulate in the splitter until it is unpaused; nothing is lost |
| `buyback(minTokenOut)` (`BUYBACK`, instant) | spends the buyback balance through the executor | at most the configured per-call cap, and no more often than `BUYBACK_COOLDOWN`, 5 minutes, which is compiled and not configurable, so 50-USDG buys cannot be stacked into one sandwichable block (`src/v2/interfaces/V2Constants.sol:61-63`); the executor refuses a pool reporting a hook fee above `MAX_HOOK_FEE_BPS` 300 bps (`:138-141`) | A cranker key that buys at the worst moment it can find, one capped buy every 5 minutes, with `minTokenOut` its own. It spends only the splitter's buyback balance, and `OPS_ADMIN` revokes the role with no delay |

### 2.3 Every guardian power and its worst case

| Function | Effect | Worst case |
|---|---|---|
| `Clearinghouse.setMintPaused(underlying, bool)` | stops `mint` for one market (and so write-on-fill fills and rolls there) | no new units in that market until unpaused |
| `Clearinghouse.setCreatePaused(bool)` | stops `createSeries` for new ids in every market | no new series anywhere until unpaused |
| `OrderBook.setTradingPaused(bool)` | stops `place`, `placeFor`, `replace` and `take` | no trading on the book. Tokens stay transferable, `close` and redemption work, orders can still be cancelled and pruned (`OrderBookOrdersTest.test_pause_stopsNewRiskButNeverCancelPruneOrClaim`) |
| `SettlementOracle.veto(underlying, expiry)` | Held: blocks only the uncorroborated path, at any time before finalization, even before expiry (`SettlementOracleChainTest.test_unveto_beforeExpiry_thenNormalFlow`) | an expiry that no two sources corroborate waits until the admin unvetoes it or resolves it from `E + 48 h`: inside the recorded band, and for a lone recorded price from `E + 7 days` within a factor of 1.25 of it, so a vetoed wrong price can still settle at the right one (`PinnedSettlementTest.test_vetoedWrongSingleSource_settlesAtTheMarketPriceFromSevenDays`). Corroboration still finalizes a held expiry (`SettlementOracleChainTest.test_veto_thenCorroboration_finalizesNormally`) |
| `SettlementOracle.unveto(underlying, expiry)` | Pending again, delay restarted | lifts its own veto |
| `PayoutRouter.clearRoute(asset)` (INTERFACE_VERSION 8) | removes a market's route to USDG | every converted payout of that market falls back in kind at the settlement price, until a route is set again on the 24 h `CONFIG_ADMIN` lane |
| `FeeSplitter.setPaused(bool)` (INTERFACE_VERSION 8) | stops the splitter converting, splitting and buying back | protocol fees accumulate in the splitter until it is unpaused. No user balance is in it |
| `HouseVault.setQuotingPaused(bool)` | stops the House vault quoting (`_requireQuoting` on place/replace/take/close/sync) | no new House quotes until unpaused; `rollEpoch`, the queues and `claim` never pause (`V2-HOUSE-VAULT.md`) |
| `Hedger.pause(bool)` | stops `hedge` and `unwind`; `repay` stays open (T-OP-067) | no new or closed hedges until unpaused |
| `HouseVault.setLimits(Limits)` (**T-OP-159**, owner order 2026-09-22 05:55Z: "i dont want these numbers to have a delay at all"; was TREASURY_ADMIN, 24 h) | sets `maxSeriesUnits`, `maxTotalNotional`, `askToleranceBps`, `maxBidBpsOfSpot`, `maxOrderLifetime`, `maxDailyOutflow` on one House vault, instantly, in either direction | **the only guardian power that is not a brake.** Tightening to zero is the first kill switch (`V2-HOUSE-VAULT.md`). Loosening removes the bound that makes "QUOTER drains HouseVault" BOUNDED (`V8-SECURITY-SWEEP.md` §2.2): a guardian key that is also, or colludes with, a compromised QUOTER can lift the caps and then spend up to the vault's TVL through the quoting surface, with no 24 h window in which a scheduled change is visible and cancellable. Only the two bps fields have a compiled ceiling (`HouseVault._setLimits`). Accepted by the owner 2026-09-22 on the ground that the GUARDIAN holders are the Admin Safe and an owner-held EOA, never a bot key (`V8-ACCEPTED-RISKS.md`, T-OP-159); `setPerformanceFeeBps` stays on TREASURY_ADMIN |

**And the cancel.** `GUARDIAN` is the role guardian of `FEE_MANAGER`, `MARKET_FEE_MANAGER`,
`CONFIG_ADMIN`, `TREASURY_ADMIN` and `LISTING` (`script/v2/roles.v8.json:35-41`), so while any of
those operations waits out its delay the guardian key cancels it on the manager in one transaction
with no delay of its own: a fee change, an exercise-fee or rent change, a pointer change, a treasury
payment, a listing. That cancel is the reason those lanes are delayed rather than instant — a delay
nobody can act on is only a warning.

**What the guardian cannot cancel: role and mapping changes.** Nothing scheduled under `ADMIN` can be
cancelled by a guardian — not a role grant, not a revoke, not a selector remap, not a change of role
admin or role guardian. `AccessManager` never lets `ADMIN_ROLE` be given a guardian
(`src/v2/access/V8Roles.sol:20-21`), and the manifest sets none. The 48 h `ADMIN` lane is therefore
protected by publicity and by another `ADMIN` transaction, and by nothing else. That is accepted
(owner decision V3-D24, 2026-09-19), on the grounds that all Safe keys are the owner's today; it is
the row to revisit first when outside co-signers exist. `OPS_ADMIN` is the deliberate hole in the
other direction: it is instant and manager-only, so revoking a compromised hot key never waits.

A guardian can delay, never redirect: no guardian function touches a balance
(`ClearinghousePausesTest.test_pauses_doNotTouchBalancesOrLedger`). **One qualification since
T-OP-159:** `HouseVault.setLimits` still touches no balance, but it sets the caps that bound what the
QUOTER may commit, so the guardian key now decides the size of a House vault's quoting risk with no
delay — see the last row of the table above and `V8-ACCEPTED-RISKS.md`. Unpausing needs the guardian
role, which the Admin Safe holds outright (`script/v2/roles.v8.json:51`); in v7 the admin had to grant
it to itself first.

### 2.4 Values no role can change

Compiled into the bytecode:

| Value | Where it is asserted |
|---|---|
| 1 unit = 0.01 share = `1e16` base units; 100 units per share; price tick 100 | `InterfaceIdsTest.test_constants_units` |
| settlement window 1800 s; finalize from `E + 120 s`; pool snapshot within `E + 600 s`; `adminResolve` from `E + 48 h`; series at least 1 h and at most 45 days ahead; an OrderBook fee change in effect `FEE_CHANGE_DELAY` after it is scheduled — **48 h**, raised from 24 h by INTERFACE_VERSION 8 (`src/v2/interfaces/V2Constants.sol:60`) | `InterfaceIdsTest.test_constants_times` |
| premium and resale fee ≤ 1000 bps; exercise fee ≤ 200 bps and ≤ 1000 bps (10 %) of the gross payout; taker flat fee ≤ 1 USDG; taker cap ≤ 1000 bps; bounty ≤ 1 USDG; conversion slippage ≤ 300 bps; the route fee added to it ≤ 100 bps | `InterfaceIdsTest.test_constants_feeCeilings` |
| oracle: default deviation 150 bps (ceiling 1000); default delay 6 h (30 min to 24 h); default spot age 1 h (ceiling 4 days; the registry sets 90,000 s, 25 h, per market at launch, and the conversion floor uses the market's value, not the default); at most 8 sources | `V2DocsNumbersTest.test_docs_contractConstants` |
| Chainlink walk: at most 96 round reads; default `maxStale` 26 h (1 h to 7 days); default jump 2000 bps (ceiling 5000) | `V2DocsNumbersTest.test_docs_contractConstants` |
| pool `latest` window: default 300 s (60 s to 3600 s) | `V2DocsNumbersTest.test_docs_contractConstants` |
| AutoRoller strategy: OTM 100 to 2500 bps, ask 5 to 1000 bps; minimum lead 2 h (daily) and 24 h (weekly) | `V2DocsNumbersTest.test_docs_contractConstants` |
| MakerVault: at most 16 live orders per series; outflow window 24 h (added in INTERFACE_VERSION 7), and from INTERFACE_VERSION 8 no caller is exempt from the cap (`src/v2/mm/MakerVault.sol:135-139`) | `V2DocsNumbersTest.test_docs_contractConstants`, `MakerVaultQuoterTest.test_constructor_wiresTheBookAndRoles` |
| collateral rent: `PPM` 1,000,000; `MINT_FEE_PERIOD` 7 days; `MINT_FEE_CEIL_PPM` 5000 ppm — 0.5 % of the locked collateral per 7 days of remaining life, with the launch rate 0 on every market (`src/v2/interfaces/V2Constants.sol:96-99`); `AutoRoller.ROLL_OPEN_GRACE` 30 min; a UniV3 source needs `MIN_POOL_OBSERVATION_CARDINALITY` 2401 observations (added in INTERFACE_VERSION 7) | `InterfaceIdsTest.test_interfaceV7_rentAndPoolConstants` |
| the fee-discount seam (INTERFACE_VERSION 8): `MAX_DISCOUNT_BPS` 5000, half the taker fee and no more, so a compromised or buggy module cannot zero it (`src/v2/interfaces/V2Constants.sol:108`); `DISCOUNT_READ_GAS` 30,000 forwarded to the module's `discountBps` staticcall, once per take, a revert or a short return counting as no discount (`:112`) | `InterfaceIdsTest.test_interfaceV8_constants` |
| just-in-time funding (INTERFACE_VERSION 8): `FUNDING_GAS` 400,000 per `IFundingSource.fund` call (`src/v2/interfaces/V2Constants.sol:121`); `FUNDABLE_READ_GAS` 50,000 per `fundable` staticcall in `quoteTake` (`:124`); `MAX_FUNDED_MAKERS_PER_TAKE` 4, beyond which makers are planned WITHOUT funding rather than skipped (`:127`) | `InterfaceIdsTest.test_interfaceV8_constants` |
| the flywheel (INTERFACE_VERSION 8): `BUYBACK_COOLDOWN` 5 minutes between two FeeSplitter buybacks, compiled and not configurable so 50-USDG buys cannot be stacked into one sandwichable block (`src/v2/interfaces/V2Constants.sol:63`); `BUYBACK_CAP_CEIL` 1,000,000,000 — 1,000 USDG, the ceiling of the CONFIGURED per-call cap, past which the `C3-602` fork spike measured a single buy at 5.60 % total loss instead of 2.20 % at 50 USDG (`:137`); `MAX_HOOK_FEE_BPS` 300, above which the executor refuses to trade rather than price a pool it was not pinned against (`:141`) | `InterfaceIdsTest.test_interfaceV8_constants` |
| the Clearinghouse's USDG; the OrderBook's Clearinghouse and USDG; the AutoRoller's and MakerVault's OrderBook; the adapter's USDG, router and factory (immutables) | constructors |

**Not in this list: the roles themselves.** Role ids and per-member execution delays are `AccessManager`
state, not bytecode. `src/v2/access/V8Roles.sol` is a compiled mirror the access-matrix test and
`VerifyV8` compare the chain against; it does not bind the chain. `ADMIN` can change any delay, any
grant and any `(target, selector) → role` entry — after its own 48 h, in public, and with no guardian
able to cancel it ([§2.3](#23-every-guardian-power-and-its-worst-case)).

Pinned per series or per expiry once written:

- a series' underlying, type, strike, expiry, **oracle** and **exercise fee** (at `createSeries`);
- an expiry's **settlement configuration**: the oracle's source list, deviation and uncorroborated delay,
  each Chainlink source's feed, staleness and jump bounds, each pool source's pool and liquidity floor,
  and the Data Streams feed version (at the first `createSeries` of the expiry,
  [§3.3](#33-capture-and-pinning));
- its settlement price and three per-unit amounts (at `settle`);
- an expiry's captured source list, their ok prices and the deviation (at the first capture);
- a candidate's `finalizableAt` (at announcement; only `unveto` moves it);
- a final price (`veto` and `adminResolve` revert `AlreadyFinal`);
- a RewardsDistributor root (once per epoch).

### 2.5 What a user approves, and what each approval allows

| Approval | Allows | Never allows |
|---|---|---|
| USDG `approve(OrderBook)` | the book pulls bid escrow and a buying take's premium plus taker fee, inside the approver's own `place`, `replace` and `take` | any pull in someone else's call |
| USDG or Stock Token `approve(Clearinghouse)` | `deposit` from the approver | anything else |
| `Clearinghouse.setApprovalForAll(OrderBook)` | the book escrows the approver's longs for its own resale asks and delivers them in its own selling takes | moving tokens in another account's call |
| `Clearinghouse.setOperator(OrderBook, true)` | the book mints from the approver's **free** collateral when the approver's own write-on-fill ask is hit, or in the approver's own `writeToSell` take | touching locked collateral, withdrawing, or minting for anyone else's order |
| `Clearinghouse.setOperator(op, true)`, any other `op` | redeeming an account that opted out of third-party redemption. From INTERFACE_VERSION 8 an operator can mint from the free collateral only if it is **also** on the minter allow-list, which at launch holds the OrderBook alone, so this approval no longer hands an arbitrary operator the account's collateral (`src/v2/Clearinghouse.sol:634-635`) | withdrawing; minting while not an allow-listed minter; choosing where a redemption pays — there is deliberately no `redeemTo` |
| `Clearinghouse.setOperator(AutoRoller, true)` | consent to be rolled, and redeeming the writer's shorts | minting or withdrawing: the roller has no code path that does either (its writes go through the book's write-on-fill asks) |
| `OrderBook.setDelegate(d, true)` | `d` places, replaces and cancels the maker's **write-on-fill asks only** | bids or resale asks for the maker (`OrderBookOrdersTest.test_delegate_cannotPlaceReplaceOrCancelBidsOrResaleAsks`) |

An operator is trusted with the account's upside, so the only operators a front end should propose
are the immutable OrderBook and AutoRoller. The invariant suite checks that no other call moves an
account's value ([§9](#9-where-the-numbers-come-from), invariant 5).

### 2.6 External parties

| Party | What it can do | What v2 does about it |
|---|---|---|
| Chainlink feed owner. The NVDA and TSLA proxies' `owner()` is the Safe `0xeE27D5Ae494300902D90454e8630A3F1C68c9C52`, threshold 4 of 9 owners ([§9](#9-where-the-numbers-come-from), commands C1-C3) | switch the aggregator (a new phase); the node operators publish the answers | the walk never crosses a phase, rejects stale, non-positive and jumping rounds ([§3.2](#32-the-sources)); corroboration against the pool; the candidate delay and the guardian's veto |
| Uniswap v3 NVDA/USDG pool `0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3`, fee tier 500 (command C4) | no admin; its price moves with capital and its liquidity can leave | a moved window disagrees and becomes a delayed candidate, never a final price on its own; a thin window fails the liquidity floor; conversions check their own floor |
| Stock Token issuer | pause, blocklist, `adminBurn`, `oraclePaused`, `uiMultiplier` changes, logic upgrades | [§6.1](#61-stock-token-issuer) |
| USDG issuer | pause, freeze, wipe, burn | [§6.2](#62-usdg-issuer) |
| Robinhood Chain sequencer | ordering, censorship, compliance filtering | [§6.3](#63-sequencer-censorship-and-outages) |
| Data Streams VerifierProxy `0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7` (`VerifierProxy 2.0.0`, no fee manager, no access controller today; command C5) | adding a fee manager or access controller makes every report fail verification | the source is disabled ([V2-DATA-STREAMS.md](V2-DATA-STREAMS.md)) |
| The pinned STONKHOUSE pool and its launch hook (INTERFACE_VERSION 8) | the hook charges 100 bps plus a 100 bps creator tax, frozen at its registration; the pool's price moves with capital | only the FeeSplitter's buyback balance is exposed, never user collateral. `V4BuybackExecutor` refuses a pool reporting a hook fee above `MAX_HOOK_FEE_BPS` 300 bps — a pool charging more is not the venue it was pinned against, so a buy refuses rather than trying to price it (`src/v2/interfaces/V2Constants.sol:138-141`) — and each buy is bounded by the configured per-call cap and `BUYBACK_COOLDOWN` |

The issuer, USDG and sequencer powers are described in detail, with their evidence, in
[SECURITY.md §3](../SECURITY.md#3-what-a-compromise-of-each-key-buys) (the v1 key table; the parties
and their powers are the same for v2).

---

## 3. Oracle and settlement

### 3.1 The settlement price

- One price per `(underlying, expiry)`, shared by every strike, calls and puts.
- It is a time-weighted average over the final 1800 s before expiry, `[E − 1800, E]`
  (`InterfaceIdsTest.test_constants_times`).
- Expiry is 16:00 New York on an NYSE session day, so the window is the last 30 minutes of the
  regular session.
- `finalize` never reads a price from "now". Every source prices that fixed window.

### 3.2 The sources

Each market lists `IPriceSource` adapters in priority order (index 0 first). The plan's order for
markets with a usable pool is `[ChainlinkFeedSource, UniV3TwapSource]`; other markets list Chainlink
alone (`DevDeployTest.test_runWith_wiresTheCoreSet` wires NVDA with two sources and TSLA with one).

**ChainlinkFeedSource.** Computes the window price on demand from the push feed's own round
history, so nothing needs recording.

- It walks back from `latestRoundData` with `getRoundData(id − 1)`. Each round is in force from its
  `updatedAt` until the next round's. Rounds after `end` are skipped. The walk stops at the round in
  force at `start` and reads one more round, its predecessor.
- TWAP = Σ price × seconds in force inside the window / 1800, floored.
- Not ok, and never a revert, when: the token's `oraclePaused()` is true now or unreadable; a read
  fails; the walk reaches the first round of the proxy's phase before it is done; more than 96 rounds
  would be read; an answer is ≤ 0; the round in force at `start` is older than `maxStale`; or any used
  round moves more than `maxRoundJumpBps` from its predecessor (the jump rule). Each case has a test in
  `ChainlinkFeedSourceTest` (for example `ChainlinkFeedSourceTest.test_jump_r13SpyScaleFault_notOk`,
  `ChainlinkFeedSourceTest.test_window_startRoundIsFirstOfPhase_notOk`, `ChainlinkFeedSourceTest.test_readCap_97Reads_notOk`).
- Replay works while the window's rounds are within the 96 reads of the head. The oracle captures the
  price at its first `finalize`, long before that runs out
  (`SettlementOracleSourcesTest.test_captureBeforeSnapshot_poolCorroboratesAfterReplayDies`).

**UniV3TwapSource.** The pool's `observe` answers relative to "now", so a keeper must record the
window soon after expiry.

- `record(underlying, E)` works only in `[E, E + 600 s]`, once. It asks the pool for the cumulatives
  at `E − 1800` and `E`, so the stored price is exactly the window, whenever inside the grace the
  keeper calls (`UniV3TwapSourceTest.test_record_windowPinnedToExpiry`).
- Price = the arithmetic-mean tick of the window converted to USDG per share, in either token order.
- The harmonic-mean in-range liquidity over the window must reach the market's `minLiquidity`, or the
  window is not recorded (`UniV3TwapSourceTest.test_liquidityFloor_shortThinStretchFails`).
- `windowPrice` serves the stored value forever.
- The pool's observation ring must reach `E − 1800` at the call, up to `E + 600`. A pool writes at most one
  observation per second, and anyone can make it write one every second with a dust in-range mint or burn, so
  a ring of C slots flooded from `E − 1799` loses the window's start at `E + C − 1800`. On 2026-09-17 eleven
  of the thirteen registry pools held 1,800 to 1,860 slots: a flood costing about 0.01 ETH of gas denied
  their snapshot at the cranker's `E + 60 s` (sweep contracts-c10). `setPool` therefore refuses a pool whose
  `observationCardinality` is below `1800 + 600 + 1 = 2401`, which no flood can empty before the grace ends,
  and a pool's cardinality never shrinks (`UniV3TwapSourceTest.test_admin_setPool_refusesAnObservationRingShallowerThanTheGrace`,
  `UniV3TwapSourceTest.test_record_floodedRingOf2401Slots_stillRecordsAtTheEndOfTheGrace`,
  `SourcesForkTest.test_fork_setPool_refusesRegistryPoolsWithARingShallowerThanTheGrace`). Anyone can raise a pool's
  ring with `increaseObservationCardinalityNext` ([DEPLOY-V2.md](DEPLOY-V2.md)).

**DataStreamsSource.** Built, tested and not listed by any market. Enabling it is owner-gated:
[V2-DATA-STREAMS.md, "Enabling Data Streams for a market"](V2-DATA-STREAMS.md#enabling-data-streams-for-a-market).
When enabled it goes first in the list.

### 3.3 Capture and pinning

An expiry's settlement configuration is fixed twice: when its first series is created (**pinning**,
owner decision 2026-09-17), and when its source prices are first read (**capture**).

**Pinning at series creation.** `Clearinghouse.createSeries` calls `SettlementOracle.pin(underlying, E)`
for every series it creates, after its checks and before `SeriesCreated`. The first call for an
`(underlying, E)`:

- copies the market's source list, `maxDeviationBps`, `uncorroboratedDelay` and `spotMaxAge` (defaults
  filled in) into the expiry's pinned configuration and emits `SettlementConfigPinned`;
- calls `pin(underlying, E)` on each of those sources, which copies its own configuration for `E`:
  `ChainlinkFeedSource` the feed, `maxStale` and `maxRoundJumpBps` (`FeedPinned`); `UniV3TwapSource` the
  pool, token order, decimals and liquidity floor (`PoolPinned`); `DataStreamsSource` the feed version,
  so a feed change afterwards takes it out of that expiry (`FeedPinned`). Each answers the
  `IPriceSource.pin` selector;
- **fails closed**: when any source's pin fails, the whole pin reverts, and the creation with it, with
  `SourceNotPinned(source, reason)` (`reason` = the first four bytes of the source's revert data, zero
  when there were none). A source fails when it does not list the oracle (`setOracle`; reason
  `NotAuthorized`), has no configuration for the underlying (`NoSource`), holds an earlier pin of `E`
  that differs from its current configuration (`PinMismatch`), has no code, answers anything but the
  selector, or runs out of gas (`SettlementOraclePinTest.test_pin_anySourceFailure_revertsTheWholePin`,
  `SettlementOraclePinTest.test_pin_sourceOutOfGas_revertsTheWholePin`,
  `PinnedSettlementTest.test_failClosed_oracleRevokedOnAnySource_blocksCreationUntilRestored`,
  `PinnedSettlementTest.test_failClosed_brokenSourceInTheList_blocksCreation`,
  `PinnedSettlementTest.test_failClosed_unconfiguredListedSource_blocksCreation`). No gas limit creates a
  series with a source left unpinned (`PinnedSettlementTest.test_pin_noGasLimitCreatesASeriesWithAnUnpinnedSource`);
- reverts `NoSource` when the market has no source, and the creation with it: no series exists on an
  unpriced configuration (`SettlementOraclePinTest.test_pin_emptyMarketReverts_pinnedExpiryUnaffected`).

The oracle records the calling Clearinghouse with the pin (`pinnedBy`, packed into the slot of the
pinned mark). Later calls from that Clearinghouse return at once: every later series of `E` costs one
more call and two storage reads ([V2-GAS.md](V2-GAS.md)). The log order of a first series is
`SettlementConfigPinned`, then each source's pin log in priority order, then `SeriesCreated`
(`PinnedSettlementTest.test_pin_firstSeriesPinsTheOracleAndBothSources_inLogOrder`,
`PinnedSettlementTest.test_failClosed_oracleRevokedOnAnySource_blocksCreationUntilRestored` with the three
sources). Only the Clearinghouse the oracle names may call `pin`
(`SettlementOraclePinTest.test_pin_onlyTheClearinghouse`).

**A pin made elsewhere must be confirmed.** A `pin` of an expiry pinned by another caller (a
Clearinghouse migration, or a pin the admin made through its own account before any series) is accepted
only when the pinned list, `maxDeviationBps`, `uncorroboratedDelay` and `spotMaxAge` equal the market's
current ones, else it reverts `PinMismatch`; it then asks every pinned source to pin again, and each
source confirms only an earlier pin equal to its current configuration (`SourceNotPinned(source,
PinMismatch)` otherwise); then `pinnedBy` becomes the caller, without a log
(`SettlementOraclePinTest.test_pin_newClearinghouse_confirmsAnUnchangedPin`,
`SettlementOraclePinTest.test_pin_confirmation_refusesEveryDifference`,
`SettlementOraclePinTest.test_pin_confirmation_needsEverySource`). The same rule lets a market move to
a second oracle that shares the sources while their configurations are unchanged
(`PinnedSettlementTest.test_twoOracleMigration_worksOnlyWithUnchangedSources`). So an expiry settles on
a configuration that was the current, public one when a series creation pinned or confirmed it.

From then on `snapshot`, `finalize`, `unveto`, `adminResolve` and `settlementConfig` of `E` read the
pinned configuration, and each source answers `windowPrice(underlying, E − 1800, E)` and
`record(underlying, E)` from its pinned copy. Configuration changes reach only expiries without series.
`spot` is not settlement: it always reads the market's current source 0 and `spotMaxAge`
(`SettlementOraclePinTest.test_spot_readsTheCurrentConfigurationNotThePin`). An expiry nobody created a
series for is not pinned (unless the admin pinned it outside a series creation, [§6.6](#66-the-admin-key))
and settles on the configuration current at its capture.

**Capture.** The first `finalize` (or `adminResolve`) that finds at least one ok source **captures** the
expiry:

- it stores every source's result, ok or not, with `SourceRecorded` per source, for the pinned list
  (else the market's);
- it records the source list and `maxDeviationBps` in use for that expiry (`recordedSources`);
- an ok result is never read again;
- a not-ok result is asked again on every later call and upgraded the first time it answers. This is
  how a pool snapshot recorded after the Chainlink capture still corroborates.

`setMarket` changes after capture do not reach that expiry either (`SettlementOracleChainTest.test_sourcesPinnedAtCapture`,
`SettlementOracleChainTest.test_recordedPrice_neverReread`, `SettlementOracleConfigTest.test_paramChanges_pinnedForCapturedExpiry`).
The invariant suite checks, after every call of a campaign in which the admin re-points the market, the
feed and the pool mid-life, takes the oracle off a source's allow-list and pre-pins expiries through the
Clearinghouse pointer and the source allow-lists, that every expiry settles on what its first series
pinned and that every series has the oracle and every real source of its expiry pinned (invariant 6,
[§9](#9-where-the-numbers-come-from); `V2InvariantTest.test_handler_pinningAttacksArePredictedAndBlocked`
walks each attack).

### 3.4 The fallback chain: decision table

"Agree" means `|p_i − p_j| × 10_000 ≤ min(p_i, p_j) × maxDeviationBps`, with the deviation pinned at
capture (`SettlementOracleChainTest.test_agreement_exactlyAtBound_corroborates`,
`SettlementOracleChainTest.test_agreement_justBeyondBound_disagrees`). "First" is priority order. Every row is what
`finalize(underlying, E)` does at or after `E + 120 s`; before that it reverts `TooEarly`
(`SettlementOracleChainTest.test_finalize_tooEarly_onlyBeforeFinalizeDelay`).

| # | Sources ok now | Agreement | Status before | Time | Result | Test |
|---|---|---|---|---|---|---|
| 1 | none | — | None, or Held by a veto placed before any candidate | any | returns `(false, 0)`, nothing stored; retry later | `SettlementOracleChainTest.test_noneOk_thenLaterOk` |
| 2 | at least two | the first ok source that agrees with any other ok source | None, Pending **or Held** | any | **Finalized** at that source's price, `corroborated = true` | `SettlementOracleChainTest.test_corroborated_twoAgree_primaryPrice`, `SettlementOracleChainTest.test_corroborated_primaryDisagrees_secondUsed`, `SettlementOracleChainTest.test_veto_thenCorroboration_finalizesNormally` |
| 3 | exactly one | — | None | any | **Pending**; candidate = that source; `SettlementCandidate(…, disagreed = false, finalizableAt = now + delay)` | `SettlementOracleChainTest.test_singleSource_beforeAndAfterDelay` |
| 4 | at least two | none agree | None | any | **Pending**; candidate = the first ok source; `disagreed = true` | `SettlementOracleChainTest.test_allDisagree_pendingWithHighestPriorityCandidate` |
| 5 | as when announced | as when announced | Pending | before `finalizableAt` | `(false, 0)` | `SettlementOracleChainTest.test_singleSource_beforeAndAfterDelay` |
| 6 | as when announced | as when announced | Pending | at or after `finalizableAt` | **Finalized** at the candidate, `corroborated = false` | `SettlementOracleChainTest.test_singleSource_beforeAndAfterDelay` |
| 7 | changed: a higher-priority source answered, or a second source answered and disagrees | not corroborated | Pending | any | a **new** candidate is announced with a fresh `finalizableAt` | `SettlementOracleChainTest.test_candidateChange_newIndex_restartsDelay`, `SettlementOracleChainTest.test_candidateChange_disagreedFlip_restartsDelay` |
| 8 | any, not corroborated | — | Held | any | `(false, 0)`; the stored candidate is not touched | `SettlementOracleChainTest.test_veto_heldReturnsFalseWithoutRevert` |
| 9 | any | — | Finalized | any | `(true, price)` again, no event, no bounty | `SettlementOracleChainTest.test_finalize_idempotent_noSecondEventNoBounty` |

Human actions on top of the table:

| Action | Who | When | Result | Test |
|---|---|---|---|---|
| `veto` | guardian | any time before final, even before expiry | Held (rows 8 and 2 apply) | `SettlementOracleResolveTest.test_veto_onlyGuardian_andAlreadyFinal`, `SettlementOracleChainTest.test_unveto_beforeExpiry_thenNormalFlow` |
| `unveto` | guardian or admin | while Held | Pending with `finalizableAt = now + delay`; after a veto that came before any candidate, the next `finalize` announces one | `SettlementOracleChainTest.test_unveto_restoresSingleSourcePath_delayRestarts`, `SettlementOracleChainTest.test_unveto_preemptiveVeto_pendingThenCandidate` |
| `adminResolve` | admin | from `E + 48 h`, not final | Finalized at a price inside the band of the captured ok prices, or at any price when none is ok; from `E + 7 days` a Held expiry with exactly one ok price p takes `[p × 0.8, p / 0.8]`; it captures first, so the band cannot be skipped | `SettlementOracleResolveTest.test_adminResolve_inBandSucceedsAndEmits`, `SettlementOracleResolveTest.test_adminResolve_capturesBeforeBand`, `SettlementOracleResolveTest.test_adminResolve_heldSingleSource_widensAfterSevenDays` |

The final price is always a recorded source price or an admin resolution inside the band, whatever
the sequence of calls (`SettlementOraclePropertyTest.testFuzz_finalPriceIsRecordedSourceOrInBandAdmin`).
With the default delay, a single-source or disagreeing expiry is Pending for 6 h
(`V2DocsNumbersTest.test_docs_contractConstants`).

**Why disagreement is not a terminal "disputed" state.** Anyone who can hold the pool away from the
feed for the window would otherwise freeze every payout of that expiry until an admin acts. Treating
disagreement like a single source turns that into a delay the manipulator pays for, while a broken
primary is still caught by the veto (ADR-05).

### 3.5 Worked scenarios

| Scenario | What happens | Test |
|---|---|---|
| Normal NVDA day: snapshot at `E + 60 s`, finalize at `E + 120 s`, feed and pool agree | Finalized at the Chainlink TWAP at `E + 120 s`, corroborated | `LifecycleTest.test_lifecycle_weeklyLadder_callsAndPuts_itmAndOtm`, `V2DocsNumbersTest.test_docs_settlementAndRedemption` |
| The keeper finalizes before the snapshot | Chainlink is captured alone and announced as a candidate; the snapshot inside the grace upgrades the pool entry and the next finalize corroborates | `SettlementOracleSourcesTest.test_captureBeforeSnapshot_poolCorroboratesAfterReplayDies` |
| The snapshot is missed (no call inside `[E, E + 600 s]`) | Chainlink alone: candidate, final after the delay unless vetoed | `SettlementOracleSourcesTest.test_snapshotMissed_chainlinkAloneAfterDelay` |
| The pool is pushed away for the window | Disagreement: candidate at the Chainlink price with `disagreed = true`, final after the delay unless vetoed | `SettlementOracleSourcesTest.test_manipulatedPool_disagreedCandidate` |
| The issuer's `oraclePaused()` is on at `E + 120 s` and no pool snapshot exists | Chainlink is not ok and `spot` reverts; nothing is captured while the flag is on; once it clears, Chainlink alone becomes a candidate. With a pool snapshot, the pool alone would be the candidate and Chainlink would upgrade the capture when the flag clears (row 3, then row 2 or 7) | `SettlementOracleSourcesTest.test_oraclePaused_blocksChainlinkAndSpot` |
| A Chainlink-only market | Every expiry is a single-source candidate and waits the market's delay | `V2ForkTest.test_fork_lastWeeklyCall_settlesOnFeedHistoryAfterTheDelay` |
| Live chain 4663, NVDA, both sources | Settled on the real feed history and the real pool | `V2ForkTest.test_fork_callSeries_settlesOnRealHistory_twoSourcesCorroborate_payoutsConserve` |

### 3.6 Spot

`SettlementOracle.spot(underlying)` is source 0's `latest`, refused when older than the market's
`spotMaxAge`, when the token's `oraclePaused()` is on or unreadable, or when the answer is malformed
(`SettlementOracleConfigTest.test_spot_fresh_andAgeBoundary`, `SettlementOracleConfigTest.test_spot_unreadablePausedFlag_failsClosed`).
It always reads the market's **current** configuration, never an expiry's pin
(`SettlementOraclePinTest.test_spot_readsTheCurrentConfigurationNotThePin`).
Four things read it and none of them settles anything:

- `createSeries` rejects a strike outside `[spot / 2, spot × 2]`, and skips the check when spot is not
  available (`ClearinghouseSeriesTest.test_createSeries_spotBand`, `ClearinghouseSeriesTest.test_createSeries_bandSkippedWithoutSpot`);
- a redemption that converts an ITM call long values its floor at the higher of the settlement price and an
  **ok** spot (one inside the market's own `spotMaxAge`), and without one lets a third party convert only
  within 30 minutes of expiry ([§6.8](#68-conversion-slippage-and-who-captures-it));
- the AutoRoller sets strike and ask from it and does not roll without it
  (`AutoRollerTimingTest.test_spot_stale_noRoll_thenFreshRolls`);
- the MakerVault's price guards use the series' pinned oracle, so a stale spot stops quoting
  (`MakerVaultGuardsTest.test_staleSpotStopsQuotingButNotUnwinding`).

### 3.7 Calendar: holidays, early closes, daylight saving

- Daily expiries are every NYSE session day; the weekly is the last session day of the ISO week
  (Thursday when Friday is closed, Wednesday when Thursday and Friday are closed)
  (`ExpiryCalendarTest.test_weekly_fridayHolidayMovesToThursday`,
  `ExpiryCalendarTest.test_weekly_thursdayAndFridayClosedMovesToWednesday`).
- The US daylight-saving rule is compiled in. 16:00 New York is 20:00 UTC under EDT and 21:00 UTC under
  EST; the grid crosses the 2026-11-01 switch from Friday 2026-10-30 20:00 UTC to Monday 2026-11-02
  21:00 UTC (`V2DocsNumbersTest.test_docs_expiryClockShiftsWithDst`).
- Holidays are admin data seeded at deploy (NYSE 2026 to 2028 in the registry; the devnet seeds them,
  `ExpiryCalendarTest.test_fixture_seedIsNyse2026To2028`). The admin must extend them each year: an
  unseeded holiday is an ordinary session day.
- Early-close days (13:00) are ordinary session days. The Chainlink window simply averages the last
  prints in force; the Data Streams source is not ok there.
- Special expiries are exact instants the admin whitelists. They are valid for `createSeries` but
  never weekly and never returned to the AutoRoller (`ExpiryCalendarTest.test_special_acceptedButNeverWeeklyNorReturned`).

### 3.8 Enabling Data Streams

Owner-gated, step by step in
[V2-DATA-STREAMS.md](V2-DATA-STREAMS.md#enabling-data-streams-for-a-market): buy access to the
Regular Hours stream, prove one signed report on a fork, deploy `DataStreamsSource`, `setFeed`, run
the submitter from before the window on every expiry day, then put the source first in the market's
list with `setMarket`. The deploy already lists the oracle on the source (`setOracle`). Pinning applies:
only expiries whose first series is created after the `setMarket` use the source. Removing it is
`setMarket` without it (expiries already pinned with it keep it in their list), then
`setFeed(underlying, 0)`, which takes it out of every pinned expiry not recorded yet. The
[known limits](V2-DATA-STREAMS.md#known-limits) (early closes, report selection, halts, unmeasured
verification gas) apply.

---

## 4. Keeper model

### 4.1 Every permissionless function

No function below needs a role. The lifecycle calls (`createSeries` to `roll`) are idempotent: a
second call with nothing to do returns without changing state, so a keeper can call them blindly.

| Call | Advances when | What it does | Nothing to do | Bounty |
|---|---|---|---|---|
| `Clearinghouse.createSeries(underlying, isPut, strike, expiry)` | market enabled, not create-paused; strike on the tick and in the spot band; expiry valid, 1 h to 45 days ahead; the market has a price source and its oracle names this Clearinghouse | stores the series, pinning oracle and exercise fee; the first series of an expiry pins its settlement configuration ([§3.3](#33-capture-and-pinning)) | an existing id returns before any check and calls nothing (`ClearinghouseSeriesTest.test_createSeries_idempotentEvenWhenPausedOrDisabled`, `ClearinghouseSeriesTest.test_createSeries_pinsTheExpiryOnItsOracle`) | none |
| `SettlementOracle.snapshot(underlying, E)` | from `E`; the pool records only inside `[E, E + 600 s]` | calls `record` on every source; a failing source cannot stop the others | returns 0 (`SettlementOracleChainTest.test_snapshot_countsNewRecordings_idempotent`) | SNAPSHOT, when a source recorded for the first time, the expiry has open interest and the current Clearinghouse pinned it on this oracle |
| `SettlementOracle.finalize(underlying, E)` | from `E + 120 s` (reverts `TooEarly` before) | capture, upgrade, one step of the chain ([§3.4](#34-the-fallback-chain-decision-table)) | `(false, 0)` while not final; `(true, price)` once final | FINALIZE, per call that advanced, with open interest, on an expiry the current Clearinghouse pinned on this oracle; never to the Clearinghouse or an earlier one |
| `Clearinghouse.settle(longId)` | from `E` (reverts `NotExpired` before); price final (it calls `finalize` itself) | stores the three per-unit amounts | `false` | SETTLE, when the series has long supply whose collateral is worth at least `minRedeemPayout` at the settlement price (`ClearinghouseSettleTest.test_settle_bountyNeedsTheSeriesWorthMinRedeemPayout`) |
| `Clearinghouse.redeem(tokenId, holder)` | settled; holder allows third parties, or the caller is the holder or its operator | burns the holder's whole balance (at most `2^64 − 1` units per call, `ClearinghouseRedeemTest.test_redeem_extremeSizes`) and pays it ([V2-ACCOUNTING.md §6](V2-ACCOUNTING.md#6-redemption)) | `(0, isPut)` for a zero balance, no log | REDEEM, when the payout is worth at least `minRedeemPayout` (1 USDG at deploy, `V2DocsNumbersTest.test_docs_contractConstants`) at the settlement price |
| `Clearinghouse.redeemBatch(tokenId, holders)` | as `redeem`, per holder under try/catch; reverts only for an unknown or unsettled id | skips opted-out holders and zero balances; one bad holder cannot block the rest (`ClearinghouseRedeemAccessTest.test_redeemBatch_oneBadHolderDoesNotBlock`) | returns 0 | REDEEM per eligible holder |
| `OrderBook.prune(orderIds)` | `now ≥ validUntil` | cancels and refunds: bid escrow to the maker, resale longs to the maker | skips unknown, live, filled and cancelled ids; skips a maker that refuses returned tokens or whose hook needs more than the 500,000-gas refund cap, at a cost of at most that cap per such order ([§6.10](#610-makers-that-are-contracts)) | none |
| `AutoRoller.roll(writer, underlying)` | a position past expiry (close-out), or an active strategy with no position inside the regular session with a fresh spot | a close-out settles and redeems the old shorts, prunes the old ask and clears the position, and stops there, even inside the session, so no placement revert can undo it (`AutoRollerCycleTest.test_closeOut_inSession_isItsOwnCall_soAPauseCannotUndoIt`; sweep contracts-c18); a call with no position writes the next series and places the ask | `false` | ROLL, when the roll places at least `minRollUnits` (100 at deploy); SETTLE and REDEEM bounties earned inside are forwarded to the caller |
| `Clearinghouse.sweepFees(asset)` | fees accrued | sends them to the fee recipient | no-op | none |
| `RewardsDistributor.claim(epoch, index, account, amount, proof)` | root posted, unclaimed, valid proof | pays the account | reverts `AlreadyFinal` | none |
| `KeeperRewards.fund`, `RewardsDistributor.fund` | always | adds budget | — | none |
| `DataStreamsSource.submit(reports)` | disabled today | stores verified observations | skips each bad report with a reason | none |

Bounty eligibility is enforced by the calling contract; KeeperRewards pays
`min(bounty, dailyCap − spentToday, balance)` and never reverts a lifecycle call
(`KeeperRewardsTest.test_cap_clampsLastPaymentThenStops`, `KeeperRewardsTest.test_usdg_callerIsNeverBlocked`). The cap
counts payments in 6-hour epochs over the current one and the four before it, so no 24-hour interval
pays more than the cap and capacity comes back between 24 and 30 hours after a payment
(`KeeperRewardsTest.test_cap_epochsReleaseOneAtATime`, [V2-ACCOUNTING.md §9](V2-ACCOUNTING.md#9-keeper-bounties)).
A KeeperRewards contract starts with a daily cap of 0, which pays nothing until the admin sets it.

### 4.2 Cadence for one expiry

The invariant handler's cranker does this under every pause and oracle fault
(`test/v2/invariant/V2Handler.sol`, "the cranker acts on a listed expiry"):

1. `E + 60 s`: `snapshot(underlying, E)`. Inside the pool's grace, before the first finalize.
2. `E + 120 s`: `finalize(underlying, E)`, then `settle(longId)` for every series of the expiry. If
   the expiry is Pending, read `candidate(underlying, E).finalizableAt` and come back then.
3. After settlement: `prune` the series' resale asks and bids **first**, so escrowed longs are back
   with their makers, then `redeemBatch` every long id and every short id over the holders.
4. Any time: `sweepFees`.

The OrderBook opts itself out of third-party redemption at construction, so nobody can redeem its
escrow; that is why pruning comes before redeeming
(`OrderBookTakeTest.test_escrow_settledSeries_thirdPartyCannotRedeemTheBook_pruneReturnsLongs_makerRedeemed`).

### 4.3 Running a keeper

- Use fixed gas limits for `snapshot`, `finalize`, `settle` and `redeemBatch`. The oracle calls each
  source with a raw call; a transaction whose gas was estimated too tightly can succeed while a source
  inside it ran out of gas and recorded nothing (observed on the devnet, callhouse
  `ops/devnet/README.md` (stonkhousedotfun/callhouse)). The gas of every entry point is in
  [V2-GAS.md](V2-GAS.md).
- Simulate before sending. `roll` reverts only for states the writer, the admin or the guardian must
  change (a missing approval, a disabled or mint-paused market, paused series creation or trading);
  skip those writers. A close-out never reverts for those (it does not place), so send it; the
  writer's next roll is a second call.
- The bounties are sized near gas cost, not as income; running a keeper is not expected to be
  profitable.
- The cranker, pricing service and bots live in `keeper/src/v2/` (stonkhousedotfun/callhouse).

---

## 5. Pauses: what stops and what never stops

| Call | create paused | mint paused | market disabled (admin) | trading paused | oracle reverting | Test |
|---|---|---|---|---|---|---|
| `createSeries` (new id) | stops | — | stops | — | runs, spot band skipped; stops if the oracle's `pin` reverts | `ClearinghousePausesTest.test_pauseMatrix_beforeSettlement`, `ClearinghouseSeriesTest.test_createSeries_pinsTheExpiryOnItsOracle` |
| `mint`, write-on-fill fills, `writeToSell` | — | stops | stops | fills stop | runs | same |
| `AutoRoller.roll` placing a new ask (a close-out call never places, and closes out under every pause) | reverts | reverts | reverts | reverts | returns `false` (no fresh spot) | `AutoRollerStrategyTest.test_createPaused_reverts`, `AutoRollerStrategyTest.test_mintPaused_reverts`, `AutoRollerStrategyTest.test_marketDisabled_reverts`, `AutoRollerStrategyTest.test_tradingPaused_reverts`, `AutoRollerTimingTest.test_spot_feedReverts_noRoll` |
| `place`, `placeFor`, `replace`, `take` | — | — | — | stops | runs | `OrderBookOrdersTest.test_pause_stopsNewRiskButNeverCancelPruneOrClaim` |
| `deposit`, `withdraw`, `close`, ERC-1155 transfers, `setOperator` | runs | runs | runs | runs | runs | `ClearinghousePausesTest.test_pauseMatrix_beforeSettlement` |
| `cancel`, `prune`, `claimOwed` | runs | runs | runs | runs | runs | `OrderBookOrdersTest.test_pause_stopsNewRiskButNeverCancelPruneOrClaim` |
| `AutoRoller.cancelStale` (added in INTERFACE_VERSION 7) | runs | runs | runs | runs | returns `false` (no fresh spot) | `AutoRollerStaleTest` |
| `MakerVault` quoter calls that pay USDG out — `place(Bid)`, `replace(Bid)`, `take` (added in INTERFACE_VERSION 7) | — | — | — | stops (the book) | runs | `MakerVaultOutflowTest`. They also revert `OutflowCapExceeded` above the vault's `maxDailyOutflow`; `cancel`, `close`, the ledger moves, `claimOwed`, `sync` and every ask never do |
| `settle` (price already final), `redeem`, `redeemBatch`, `sweepFees` | runs | runs | runs | runs | runs, even with no oracle code at all | `ClearinghousePausesTest.test_pauseMatrix_afterSettlement` |
| `settle` (price not final) | runs | runs | runs | runs | returns `false` | `ClearinghouseSettleTest.test_settle_revertingOracleIsNotFinal` |

Invariant 4 asserts the "runs" cells under random sequences of every pause, oracle fault and USDG
pause or freeze ([§9](#9-where-the-numbers-come-from)).

---

## 6. What is not protected

### 6.1 Stock Token issuer

- **Burn.** `adminBurn` of the Clearinghouse's Stock Tokens leaves the Clearinghouse holding less than
  its ledger says. There is no haircut logic: withdrawals and in-kind payouts of that token succeed
  first come, first served until the balance runs out, and the last claimants' transfers fail. A
  failed redemption transfer is credited to the holder's free ledger instead
  (`ClearinghouseRedeemTest.test_redeem_blocklistedHolderCreditedToLedger`), from which the later
  `withdraw` reverts while the shortfall lasts.
- **Pause or blocklist.** A paused token, or a blocklisted Clearinghouse, stops deposits and
  withdrawals of that token and every in-kind payout; redemptions credit the ledger
  (`ClearinghouseRedeemTest.test_redeem_pausedStockTokenCreditedToLedger`). A blocklisted holder is
  credited too, and can withdraw that credit to another address ([§6.2](#62-usdg-issuer) explains why
  this is accepted). Conversion to USDG needs the token to move, so it falls back as well.
- **`oraclePaused()`.** The Chainlink source and `spot` fail closed while it is on: rolls and vault
  quoting stop, and a settlement captured then rests on the pool alone as a delayed candidate
  ([§3.5](#35-worked-scenarios)).
- **`uiMultiplier` changes.** Balances do not rebase. The feed can lag a multiplier step by up to its
  heartbeat; a lagging print inside the window moves the settlement price by the step, which a
  dividend-sized step keeps inside the jump bound ([§6.4](#64-feed-scale-faults-inside-the-jump-bound)).
- **Termination or logic upgrade** of the token: out of the contracts' reach.

### 6.2 USDG issuer

- A pause, a freeze of the Clearinghouse or the OrderBook, a wipe or a burn stops or shrinks USDG
  held there: put collateral, USDG ledgers, bid escrow, `owed`, bounty and reward budgets. As with a
  Stock Token burn, a shortfall is first come, first served.
- A frozen or paused payee never blocks others: redemptions credit the ledger
  (`ClearinghouseRedeemTest.test_redeem_frozenUsdgHolderCreditedToLedger`), the book credits `owed`
  (`OrderBookTakeTest.test_owed_usdgPaused_sellingTakeCreditsEveryPayee`), bounties pay nothing
  (`KeeperRewardsTest.test_usdg_pausedTokenPaysNothingAndLeavesNoTrace`), a frozen recipient's
  conversion falls back in kind (`ClearinghousePayoutTest.test_convert_holderFrozenForUsdg_paysInKind`).
  The value is not lost. In the OrderBook's `owed` it waits: `claimOwed` pays only the caller. In the
  Clearinghouse ledger it does not: a freeze or blocklist is not mirrored onto the ledger or the ERC-1155
  positions, and `withdraw(asset, amount, to)` pays any `to` from the Clearinghouse's own balance, which the
  token never checks against the frozen account. A frozen USDG holder or a blocklisted Stock Token holder
  can therefore move its free balance, including a payout the freeze sent to the ledger, to another
  address (`ClearinghouseLedgerTest.test_withdraw_frozenOrBlocklistedAccountCanPayAnotherAddress`), and
  can move positions the same way. The issuer cannot wipe that one account's share inside the pool; what
  it can still do is act on the Clearinghouse itself (freeze, blocklist, burn), which reaches every user's
  pooled balance first come, first served, as above. Accepted: any pooled custody contract behaves this
  way, refusing ledger debits would add an issuer read to the exit path without closing position
  transfers, and v2 does not enforce issuer compliance (sweep finding contracts-c03).

### 6.3 Sequencer censorship and outages

Chain 4663 has one sequencer and no sequencer-uptime feed. Nothing on chain notices an outage.

- **Nothing happens without a transaction.** Settlement, payouts, pruning and rolls wait. Exits wait
  too: `close`, `withdraw` and `cancel` are never paused by a role, but they still need to be included.
- **The pool snapshot has a 600 s grace** (`InterfaceIdsTest.test_constants_times`). Censoring or
  delaying keepers past `E + 600 s` removes the pool from that expiry: Chainlink alone, a delayed
  candidate (`SettlementOracleSourcesTest.test_snapshotMissed_chainlinkAloneAfterDelay`).
- **Chainlink replay is bounded.** If no `finalize` lands before the feed prints enough rounds after
  the window to put it beyond 96 reads (`V2DocsNumbersTest.test_docs_contractConstants`), no source is
  ok, and the expiry settles only by `adminResolve` from `E + 48 h` (`InterfaceIdsTest.test_constants_times`),
  at any price (row 1 of [§3.4](#34-the-fallback-chain-decision-table),
  `SettlementOracleResolveTest.test_adminResolve_noSources_anyPrice_badPrice`).
- **Ordering.** Whoever the sequencer lets in first fills first. A `take` has a deadline, a price limit
  and a minimum size, not a fee limit ([§6.9](#69-fee-changes-between-a-quote-and-a-take)).
- The chain's force-inclusion path and filtering are described in
  [SECURITY.md §3](../SECURITY.md#3-what-a-compromise-of-each-key-buys) (Robinhood Chain row).

### 6.4 Feed scale faults inside the jump bound

The jump rule rejects a used round that moves more than `maxRoundJumpBps` (default 2000 bps,
`V2DocsNumbersTest.test_docs_contractConstants`) from its predecessor. It does **not** catch:

- a wrong answer closer to its predecessor than the bound (a bad print up to 20 % away at the default
  passes: `ChainlinkFeedSourceTest.test_jump_exactlyMaxBps_isOk`);
- a fault that began before the round in force at the window's start, so every round the walk uses is
  wrong by the same factor and no used round jumps.

The protection is then corroboration: on a market with a pool, the wrong price disagrees and becomes a
candidate that waits the delay. On a **Chainlink-only market** the wrong price is a single-source
candidate and **finalizes after the delay unless the guardian vetoes it**. Watching every
`SettlementCandidate` and comparing it with an independent price is an operational duty; the
contracts do not do it. The same holds on a pool market whose snapshot was missed.

A veto only holds the price; nothing can record a better one afterwards (an ok entry is never re-read,
the snapshot grace is over, the pin fixes the sources). So a vetoed single price settles through
`adminResolve`: from `E + 48 h` within the pinned deviation of it, and from `E + 7 days` within a
factor of 1.25 of it, `[p × 0.8, p / 0.8]` (sweep contracts-c12). That reaches the true price behind any print the
default 2000 bps jump rule lets through, since such a print is at most 20 % from its predecessor. A
fault larger than that (a stale multiplier step beyond 25 %) still leaves the choice between the band
edge and holding the expiry. The admin power this adds is that factor over an expiry with a single ok
price, after a public veto and a week ([§2.2](#22-every-admin-power-and-its-worst-case)).

### 6.5 Feed precision near the strike

A push feed prints on its deviation threshold or its heartbeat, so the price in force inside the
window can differ from the last trade by up to that threshold, and the last print of a session can
come well before the close (the feed parameters are in the R13 recon, `ops/recon/R13-v2-sources.md`
(stonkhousedotfun/callhouse)). A contract that finishes within that distance of its strike can settle
on the other side of the strike from the official close. Corroboration bounds the error by the market's
deviation; Data Streams removes most of it when enabled.

### 6.6 The admin key

There is no single admin key from INTERFACE_VERSION 8. The heading is kept because other documents
link to it. What v7 called the admin key is now the Admin Safe holding nine of the eleven roles on one
`AccessManager`, and every configuration and money lane waits out an execution delay, in public,
before it reaches a contract: listing 1 h, pointers and treasury 24 h, order-book fees 48 h, the
exercise fee and the collateral-rent dial 72 h (`script/v2/roles.v8.json:16-28`). The guardian can
cancel any of those five while it waits. Role and mapping changes are a sixth lane, `ADMIN`'s own
48 h, and no guardian can cancel that one ([§2.1](#21-roles),
[§2.3](#23-every-guardian-power-and-its-worst-case)). Read "the admin" in the rest of this section
as "the Admin Safe, after that much public notice, unless the guardian cancels it first".

Two things are still immediate, and they are the residual risk this section is about. The Safe holds
`GUARDIAN` and `QUOTER` outright, so every pause, veto, unveto and `clearRoute` is instant for it;
and `OPS_ADMIN` is instant by design, so it can grant itself `PRICER` or `BUYBACK` in one transaction
too. It cannot reach `FEE_MANAGER`, `MARKET_FEE_MANAGER`, `CONFIG_ADMIN`, `TREASURY_ADMIN` or
`LISTING` that way: those are `ADMIN`'s to grant, and `ADMIN` waits 48 h like everything else on its
lane.

**Closed (owner decision 2026-09-17, C2-16 finding 1): the admin can no longer pick the settlement
price of a live series.** Until then `setMarket`, `ChainlinkFeedSource.setFeed` and
`UniV3TwapSource.setPool` applied to every expiry not captured yet, so the admin could re-point the
sources of an expiry whose series people held: two agreeing sources it controlled finalized at once,
and an empty list let `adminResolve` take any price 48 h after expiry. Now the first series of an
expiry pins the oracle's list, deviation and delay and each source's feed, pool and floor
([§3.3](#33-capture-and-pinning)), and every settlement path reads the pin.

What the admin **cannot** do to an expiry that has a series: add, remove or re-order its sources;
re-point, loosen or remove its Chainlink feed; re-point its pool or lower its floor; change its
deviation or its uncorroborated delay; open `adminResolve` to any price by emptying the list; make a
source it added corroborate a disagreement (`PinnedSettlementTest`, `SettlementOraclePinTest`,
`V2InvariantTest` invariant 6).

**Closed (2026-09-17, hardening of the pin): pinning fails closed.** The first version tolerated a
source whose pin failed (it logged `SourcePinFailed` and left that source on its current configuration
for the expiry), and a later `pin` returned early on any existing pin. So the admin could take the
oracle off a source's allow-list, let the first series of an expiry be created with that source
unpinned, and re-point the source afterwards; or pin an expiry with a bad configuration through its own
account (as the Clearinghouse pointer, or on a source's allow-list), restore the clean configuration,
and let the real series settle on the hidden pin while every current-configuration view looked clean.
Now any source pin failure reverts the creation, and a pin made by another caller is confirmed only
against the current configuration ([§3.3](#33-capture-and-pinning)): a series is created only on a pin
that was the current, public configuration at its creation. `SourcePinFailed` is gone.

What the admin **can** still do:

- configure expiries **without** series, which settle on whatever is configured when their first
  series is created. Anyone can create that first series without minting, so a change is certain to reach
  only expiries more than 45 days ahead (`MAX_TENOR`); a source fix (a pool migration, a deprecated feed)
  may miss expiries a stranger pinned weeks ahead that nobody holds yet (sweep contracts-c13, accepted:
  pinning at the first mint is bypassed by minting one unit and would leave write-on-fill asks resting on an
  unpinned expiry; new series of such an expiry can still be pointed at a new oracle with its own source
  instances). That pin is public (`SettlementConfigPinned`, `FeedPinned`, `PoolPinned`, `settlementConfig`)
  before anyone can trade the series; integrations should show an expiry's pinned
  configuration and refuse series whose pin names sources other than the published ones;
- pin an expiry outside a series creation, by pointing the oracle's Clearinghouse pointer or a source's
  allow-list at itself. That can only **block** the expiry: no series of it can be created while the pin
  differs from the current configuration (`PinMismatch`, `SourceNotPinned(source, PinMismatch)`:
  `PinnedSettlementTest.test_hiddenPrePin_throughTheClearinghousePointer`,
  `PinnedSettlementTest.test_hiddenPrePin_throughEachSourceAllowList`), unless the admin makes that
  configuration the current one, in public. The pin is on chain (`SettlementConfigPinned` without a
  `SeriesCreated`, `FeedPinned`/`PoolPinned` from a call that is not the oracle's, `pinnedBy`),
  VerifyV8's pin dry run fails on the next expiry, and VerifyV8 flags the admin or the cranker on an
  allow-list. Through the pointer the admin can also move `pinnedBy` of an expiry that already has
  series, which makes its next series confirm again: a denial of new series while the configuration
  differs, like pausing creation;
- stop series creation by breaking the wiring (a zero pointer, the oracle off a listed source, a listed
  source without configuration): every first series reverts, VerifyV8 fails;
- `adminResolve` from `E + 48 h` inside the band of the recorded prices, or at any price when none of
  the expiry's pinned sources ever answered ([§2.2](#22-every-admin-power-and-its-worst-case), unchanged); and, after
  vetoing an expiry with a single ok price (the admin can grant itself the guardian role), from `E + 7 days`
  at any price within a factor of 1.25 of it ([§6.4](#64-feed-scale-faults-inside-the-jump-bound), sweep
  contracts-c12);
- `unveto` a guardian veto, after which the candidate finalizes after the pinned delay (unchanged; the
  admin can also grant itself the guardian role);
- take the Data Streams source out of a pinned expiry by changing its feed, at any time until the
  source records the window or the oracle captures it ok (`DataStreamsSourceTest.test_pin_feedChangedAfterPin_notOkForThatExpiry`).
  That is never another stream's price, but it is not only a denial either: the expiry then settles on
  its other pinned sources alone, so a corroboration that needed this source becomes a candidate the
  admin (holding every guardian power) can hold until `adminResolve` inside the band, and with no other
  pinned source answering `adminResolve` takes any price from `E + 48 h`
  (`SettlementOracleResolveTest.test_adminResolve_noSources_anyPrice_badPrice`). Whoever submits the
  reports can do the same by withholding them. No market lists the source today (VerifyV8 requires
  `[chainlink]` or `[chainlink, univ3]`); a market should list it only next to sources that neither the
  admin nor the submitter can silence;
- list, for an expiry without series, a source contract of its own. The pin fixes a source's address,
  and only the three published sources pin their own configuration, so such a contract can answer
  anything later. It is public in `SettlementConfigPinned` and `settlementConfig` before anyone trades
  the series, and VerifyV8 fails on any list other than the published sources;
- move `spot` (strike band, AutoRoller strikes, MakerVault guards) at once, and point new series at
  another oracle with `setMarketConfig` (unchanged).

Every one of these now waits out its lane's execution delay on the manager, in public, and the
guardian can cancel it while it waits — which in v7 was true of nothing at all. What the delay does
not do is change the rules: the veto and resolve rules of
[§3.4](#34-the-fallback-chain-decision-table) are unchanged, and a delay is notice, not a veto. The
one holder who can act without notice is the guardian, and every guardian power stops something
([§2.3](#23-every-guardian-power-and-its-worst-case)).

### 6.7 Keeper liveness

Nothing settles, pays or rolls unless someone calls. Bounties make calling cheap, not certain. Holders
can always call `settle` and `redeem` for themselves. A holder who opted out of third-party redemption
is never pushed and must redeem itself or through its operator
(`ClearinghouseRedeemAccessTest.test_optOut_strangerRevertsHolderAndOperatorSucceed`).

### 6.8 Conversion slippage, and who captures it

A converted payout must deliver at least its value at the floor price less the slippage bound,
**measured above the route's own pool fee** ([V2-ACCOUNTING.md §6](V2-ACCOUNTING.md#6-redemption),
`ClearinghousePayoutTest.test_floor_addsRouteFee`):

```
minOut     = owed × floorPrice / 1e18 × (10_000 − min(maxPayoutSlippageBps + routeFee, 300)) / 10_000
floorPrice = max(P, spot)   when the series oracle's trySpot is ok — that is, a reading inside the
                            market's own spotMaxAge (90,000 s, 25 h, at launch), the oracle not paused
                            and the price non-zero. No age bound of the Clearinghouse's own since
                            INTERFACE_VERSION 7 dropped it (owner sign-off c01; v6 also required 1 h).
           = P              otherwise, if the caller is the holder or its operator, or now ≤ E + 30 min
           = no conversion  otherwise (paid in kind)
routeFee   = payoutAdapter.routeFeeBps(asset), clamped to 100
```

The launch bound is **30 bps** (`V2_PAYOUT_SLIPPAGE_BPS`, default `V2DeployBase.LAUNCH_PAYOUT_SLIPPAGE_BPS`,
`DeployV2EnvTest.test_env_everyVariableInOrder`). The compiled ceilings are 300 bps for the bound and 100 bps
for the route fee (`V2Constants.MAX_ROUTE_FEE_BPS`, `InterfaceIdsTest.test_constants_feeCeilings`), and
the sum is capped at 300 bps (`ClearinghousePayoutTest.test_floor_totalCappedAtCeiling`).
`UniV3PayoutAdapter` reports a route's fee tier divided by 100, rounded up: 5 bps for tier 500, 30 for 3000,
100 for 10000, and 0 without a route (`UniV3PayoutAdapterTest.test_routeFeeBps_roundsUpPerTier`,
`UniV3PayoutAdapterTest.test_routeFeeBps_zeroWithoutRoute`). It refuses a route above the 1 % tier
(`CeilingExceeded`, `UniV3PayoutAdapterTest.test_setRoute_rejectsFeeTierAboveOnePercent`), so its answer is never
clamped; the deploy scripts refuse such a registry pool before anything is sent (`DeployV2Batch.sh`,
`RegisterMarkets` preflight, a VerifyV8 FAIL).

**Floors at launch.** Of the registry's 13 pools (command C6):

| Pool fee tier | Floor below value | Registry pools | Converts on the fork |
|---|---:|---|---|
| 0.05 % (500) | 35 bps | AAPL, GOOGL, NVDA, QQQ, SPCX | NVDA, 5 bps short |
| 0.30 % (3000) | 60 bps | AMZN, CRCL, MSFT, MU, SGOV, TSLA, USO | TSLA, 31 and 33 bps short |
| 1 % (10000) | 130 bps | GME | GME, 100 bps short |

A conversion exactly at each floor converts and one bps below pays in kind
(`UniV3PayoutAdapterClearinghouseTest.test_redeem_launchBoundFloorPerFeeTier`).

**Who captures it.** Anyone can call `redeem`, so a caller who moves the pool in the same transaction
can take what the swap would have delivered above the floor. The swap already pays the pool fee, and the
floor allows for exactly that fee, so measured from the floor price the capture is at most
`maxPayoutSlippageBps` less the price impact: about 30 bps of each converted payout on every fee tier.

The floor price is why that holds after the market moves. The pool trades around the clock, and a
redemption can come well after the settlement window (a candidate waits 6 h, `adminResolve` 48 h). Valued
at the settlement price alone, a floor would let a third party redeem a default holder, push the pool back
down to that price, convert and buy back, keeping the whole move above it as well as the bound (sweep
finding contracts-c01). So the Clearinghouse values the payout at the higher of the settlement price and
the series oracle's spot (source 0's `latest`, [§3.6](#36-spot)) whenever the oracle answers **ok** for that
spot: a sandwich down to the settlement price then misses the floor and pays in kind,
while a fill near the spot still converts
(`ClearinghousePayoutTest.test_floorPrice_freshSpotAboveSettlement_valuesThePayoutAtSpot`,
`ClearinghousePayoutTest.testFuzz_floorPrice_convertsIffTheFillMeetsTheHigherPrice`). The freshness bound is
the market's own `spotMaxAge` — 90,000 s, 25 h, at launch — and nothing tighter: INTERFACE_VERSION 7 dropped
the extra 1 h bound v6 applied on top of it, because the real feed cadence rarely met it and automated
redemptions then paid in kind for no gain
(owner sign-off c01, `ClearinghousePayoutTest.test_floorPrice_freshnessIsTheMarketsSpotMaxAgeAndNothingTighter`).
The floor is never below the settlement price either way. What a reading inside `spotMaxAge` does **not**
bound is how far the market has moved since that reading: the feed's 0.5 % deviation threshold is the
condition under which the feed prints, not a bound on when that print lands on chain, and the floor does not
wait for it. Until the print lands the floor uses the older price (security review SEC-10, an accepted risk
recorded in [V8-ACCEPTED-RISKS.md](V8-ACCEPTED-RISKS.md#sec-10--conversion-at-the-settlement-price-inside-stale_spot_grace)).
A spot below the
settlement price never lowers the floor
(`ClearinghousePayoutTest.test_floorPrice_freshSpotBelowSettlement_keepsTheSettlementPrice`). Without an ok
spot (the oracle paused, source 0 silent for longer than `spotMaxAge`, or a malformed answer), the settlement
price alone is used within 30 minutes of expiry — `STALE_SPOT_GRACE`, which `spotMaxAge` plus the settlement
window dwarfs, so inside the grace "no ok spot" means the market has not printed for a day — and whenever the
caller is the holder or its operator, whom nobody else can
sandwich; any other redemption pays in kind
(`ClearinghousePayoutTest.test_floorPrice_noFreshSpot_lateThirdPartyPaysInKind`). What is left beyond the
bound is how far the market has moved past the price the floor used (source 0's last observation that has
landed, or inside the grace the settlement price alone) until the next print lands. The feed's deviation
threshold does not bound that: it only decides that a print is due, and the grace can end before the print
arrives. That is an accepted risk (SEC-10); a holder who sets `setPayoutInKind(true)` is not converted and is
not exposed to it. The spot is read like the route fee, with a staticcall capped at 150,000 gas (on the fork the
real oracle needed under 60,000 with the Chainlink source first and under 120,000 with the pool first); a
revert, a malformed answer or running out of gas counts as no spot, so redemption still needs nothing but the
stored settlement, and an oracle that burns the gas added 140,108 gas to a converted redemption
(`ClearinghousePayoutTest.test_floorPrice_gasBurningOracleCostsAtMostTheCap`, printed).

An adapter that pays the least the
Clearinghouse accepts keeps exactly `maxPayoutSlippageBps` + route fee of the value, and paying one bps less
falls back in kind (`ClearinghousePayoutTest.test_convert_stealAttemptTakesNoMore`); for any bound, route fee answer
and rate, a conversion happens exactly when the output meets the floor
(`ClearinghousePayoutTest.testFuzz_floor_captureBounded`). Holders who choose in kind
(`setPayoutInKind(true)`) are paid Stock Tokens and are not exposed; their redemption does not even read
the route fee (`ClearinghousePayoutTest.test_floor_notReadWithoutAConversion`).

**The USDG is counted where only the swap can add to it.** The adapter pays the Clearinghouse, which checks
its own balance and sends the USDG on to the holder's wallet (or credits a ledger holder). Counted at the
holder's wallet, a hostile adapter could keep the whole payout: during the swap it has a contract the
Clearinghouse's guard does not lock push the holder's own USDG to the holder, an expired bid's escrow
through `OrderBook.prune` or an unclaimed `RewardsDistributor` entry, and tops up any shortfall
(`ClearinghousePayoutTest.test_convert_adapterPayingWithTheHoldersOwnUsdg_paysInKind`, sweep contracts-c30).
While the swap runs, nobody can add to the Clearinghouse's own USDG without giving up USDG of their own.
A holder USDG cannot pay (frozen, paused) makes the transfer revert, and the payout is in kind
(`ClearinghousePayoutTest.test_convert_holderFrozenForUsdg_paysInKind`).

**The route fee is read with bounded trust.** The Clearinghouse does not trust the adapter's answer. It
reads `routeFeeBps` with a staticcall capped at 30,000 gas. A revert, a short answer or running out of gas
counts as 0, the tighter floor, which fails toward in kind
(`ClearinghousePayoutTest.test_floor_badRouteFeeReadCountsAsZero`). An adapter that burns the gas added
26,767 gas to a converted redemption (`ClearinghousePayoutTest.test_floor_gasBurningRouteFeeCostsAtMostTheCap`,
printed). An answer above 100 bps counts as 100 (`ClearinghousePayoutTest.test_floor_routeFeeClampedToMax`),
so a bad adapter can cost a holder at most min(`maxPayoutSlippageBps` + 100, 300) bps of a payout: 130 bps
at launch.

**Why 30 bps.** On a fork of chain 4663 at the RPC's latest block on 2026-09-17, an ITM NVDA call long
owed 9.965549 NVDA (worth 2,164.385993 USDG at a settlement price set to the pool mid) converted through
the 0.05 % NVDA/USDG pool for 2,163.288106 USDG, **5 bps** short, against a 35 bps floor
(`PayoutForkTest.test_fork_itmNvdaCallLong_redeemsToUsdgWithinTheLaunchBound`, printed as "shortfall
bps"; a direct 1 NVDA swap was also 5 bps short, `PayoutForkTest.test_fork_directSwapOnLivePool`). A
same-transaction manipulator can take up to about 30 bps of that payout (35 − 5); at the previous flat
100 bps bound it was about 95 bps. Half of an ITM TSLA call position, worth 1,781.816813 USDG, routed
through the 0.30 % pool converted for 1,776.280861 USDG, **31 bps** short, and the other half, sold into the
pool the first sale had moved, 33 bps short, both against a 60 bps floor. A flat 30 bps floor would have
paid the first half in kind: the pool's quote for it was below value less 30 bps
(`PayoutForkTest.test_fork_tsla_inKindWithoutRoute_andConvertsThroughItsPoolAtTheLaunchBound`). An ITM
GME call long worth 291.492437 USDG converted through the 1 % pool for 288.569014 USDG, **100 bps** short,
against a 130 bps floor (`PayoutForkTest.test_fork_gme_convertsThroughItsOnePercentPoolAtTheLaunchBound`).
Every one of these conversions asserts its shortfall is at most `maxPayoutSlippageBps` + route fee. A pool
pushed 5 % below the settlement price misses the floor and the payout falls back in kind
(`PayoutForkTest.test_fork_poolPushedAway_redemptionFallsBackInKind`). The devnet (`ops/devnet/up.sh`
(stonkhousedotfun/callhouse), DevDeploy's `PAYOUT_SLIPPAGE_BPS` default 30) settled an NVDA call at the
pool's TWAP and converted 3 of 3 ITM long redemptions through the same pool, each 5.4 bps short of its
value at the settlement price against the 35 bps floor (summary line "3 of 3 ITM call long redemptions
paid in USDG"; the shortfall from `addresses.json`: `seed.summary.periphery.payoutAdapter.converted`
against `seed.settle.poolPrice`, on 2026-09-17 with the INTERFACE_VERSION 6 contracts). These figures are read from the live pools and move with
them; re-run the fork suite ([§9](#9-where-the-numbers-come-from)) before relying on them.

Paid in kind, a holder receives Stock Tokens worth the payout at the settlement price. Clearing a
market's route (`setRoute(asset, 0)`) is how the admin switches that market to in kind.

### 6.9 Fee changes between a quote and a take

A fee change takes effect `FEE_CHANGE_DELAY` after it is scheduled on the book. That delay is **48
hours**, compiled, raised from 24 h by INTERFACE_VERSION 8 (owner decision V3-D13,
`src/v2/interfaces/V2Constants.sol:60`, and its reasoning at `:55-59`); the `FEE_MANAGER` role that
schedules it waits another 48 h on the manager first, so a fee change is visible for 48 h before it is
even scheduled here ([§2.1](#21-roles), [§2.2](#22-every-admin-power-and-its-worst-case),
`InterfaceIdsTest.test_constants_times`).
`FeeParamsScheduled(params, effectiveAt)` announces it and `pendingFeeParams()` returns it while
`block.timestamp < effectiveAt`; from the first block with `block.timestamp >= effectiveAt`,
`feeParams()`, `quoteTake` and every take use it, resting orders included, and `pendingFeeParams()`
returns zero (`OrderBookFeeDelayTest.test_setFeeParams_schedulesTwentyFourHoursAhead_inEffectAtExactlyEffectiveAt`,
`OrderBookFeeDelayTest.test_take_restingOrders_payOldFeesBeforeEffectiveAt_newFeesFromIt`). No log marks
that moment, and a take writes no fee state. That first test's name still says twenty-four hours: it was
written against the v7 delay and has not been renamed, and the constant it asserts against is what this
page quotes, not the name.

- **A second schedule before `effectiveAt` replaces the first and restarts the delay**, so no change is
  ever in effect less than 48 hours after the log that announced it
  (`OrderBookFeeDelayTest.test_setFeeParams_rescheduleBeforeDue_replacesAndRestartsTheDelay`).
- **A schedule after `effectiveAt`** keeps the earlier change in effect until the new one is due
  (`OrderBookFeeDelayTest.test_setFeeParams_afterTheChangeIsDue_keepsItInEffectUntilTheNextIsDue`).
- **Cancelling** is scheduling the fees in effect; there is no other cancel
  (`OrderBookFeeDelayTest.test_setFeeParams_schedulingTheFeesInEffect_cancelsAPendingChange`).

A fuzz test drives random schedule and fill times and checks that every fill pays the most recent change
whose `effectiveAt` has passed and that was not replaced before it took effect
(`OrderBookFeeDelayTest.testFuzz_fees_fillPaysTheLatestScheduleInEffectThatWasNotReplaced`).

`quoteTake` is a view at call time, so a take sent just before `effectiveAt` and included after it pays
the new fees; `pendingFeeParams()` shows that change 48 hours ahead. What bounds the difference is
`TakeParams.maxTotalFee`, and INTERFACE_VERSION 8 ENFORCES IT: after the fills are planned and the final
taker-side fees are known, `take` adds the taker fee to the taker's own seller fees when selling into
bids and reverts `V2Errors.FeeAboveMax(totalFee, maxTotalFee)` before any USDG moves
(`src/v2/OrderBook.sol:458-463`, landed in `C8-03`). `quoteTake` returns the same two numbers it will
charge -- `takerFee`, and `sellerFees` when selling (`src/v2/OrderBook.sol:502` returns
`p.buying ? 0 : plan.sellerFees`) -- so a caller can pass their sum and get the quoted fees or a revert.
Passing `type(uint128).max` still works and still means "no limit"; it is an opt-out, not the required
value it was before `C8-03`. The
dapp caps every take's `deadline` at `effectiveAt - 1` while a change is pending, and `take` reverts
`DeadlinePassed` when `block.timestamp > deadline`, so its takes execute at the quoted fees or not at all; a
take built while nothing is pending with a deadline under 48 hours cannot reach a change scheduled after it
(`OrderBookFeeDelayTest.test_take_dappDeadlineRule_paysTheQuotedFeesOrReverts`). The taker fee is still bounded by `min(1 USDG, 10 % of premium)` and the seller fee by 10 % of
premium (`InterfaceIdsTest.test_constants_feeCeilings`).

### 6.10 Makers that are contracts

A resale ask's escrow returns to the maker's address. A maker contract that stops accepting ERC-1155
tokens is skipped by `prune` and cannot `cancel` either, so its escrowed longs stay in the book
(`OrderBookOrdersTest.test_prune_makerRejectingReturnedTokens_isLeftAndOthersContinue`). A bid maker
that rejects tokens is skipped in takes and cannot block others
(`OrderBookTakeTest.test_take_selling_bidMakerRejectingTokens_isSkippedAndCannotRevertOthers`).

A refusal can also be expensive: an acceptance hook that burns all the gas it is given. Every delivery
the book catches (a write-on-fill mint, a sale into a bid from inventory or by writing, a resale refund
in `prune`) therefore runs with at most 500,000 gas, hooks included (`OrderBook.DELIVERY_GAS`), and one
that does not complete within it is skipped like any other refusal. Each such order costs a take or a
prune batch at most that much gas, and the orders after it still fill
(`OrderBookTakeTest.test_take_buying_writerBurningAllHookGas_costsAStipendPerAsk_laterAsksFill`,
`OrderBookTakeTest.test_take_selling_bidMakerBurningAllHookGas_costsAStipendPerBid_laterBidsFill`,
`OrderBookOrdersTest.test_prune_makerBurningAllHookGas_costsAStipendPerOrder_othersPruned`). Before the cap,
two such orders ran any take or batch that named them out of gas (sweep contracts-c06). The cap is per
order, not per maker: `quoteTake` cannot see a refusal, so a client that keeps naming a maker's refused
orders keeps paying for them, and should drop orders a simulated take leaves unfilled. A fill that mints a
series' first supply to fresh balances uses about 160,000 of the cap on the real Clearinghouse, so a mint's
two receivers keep over 300,000 for their hooks; receivers spending 100,000 each still fill
(`OrderBookTakeTest.test_take_receiversSpendingHonestHookGas_stillFill`). A resale ask bought by a taker is
delivered without a cap: the recipient is the taker's own choice.

### 6.11 An auto-roll ask after spot moves

A roll places the writer's ask at `spot × askBps` of the moment it rolls, valid until the series' mint
cutoff: most of a week for a weekly strategy, and overnight or over a weekend for a daily roll
after 14:00 that writes the next session's expiry. Nothing re-checks the ask against spot while it
rests. The book never calls back on a fill, `roll` does nothing inside the period, and `reprice`
(smart-pricing writers only) moves it only inside `[minAskBps, maxAskBps]` of spot, at most 10 %. The
book trades around the clock. After a rally, a buyer takes the ask at its old price, below the call's
intrinsic value once `spot − strike` exceeds the price, and even a perfect pricer cannot follow once
intrinsic value is above 10 % of spot (`AutoRollerStrategyTest.test_ask_afterARally_fillsBelowIntrinsic`).
The writer ends with the covered call its strategy sells, but it is filled mostly when it is
underpriced. v1 closed the same issue with a fill gate
(finding 12, F5, in [the v1 record](../SECURITY.md#found-2026-09-13-second-pass)).

**Fixed in INTERFACE_VERSION 7 (sweep contracts-c16), with residuals.** Three changes:

- **`cancelStale(writer, underlying)` is permissionless.** Anyone — our cranker, the pricer, a
  third party for the `CANCEL_STALE` bounty — may cancel a tracked live ask once the market has reached its
  strike, on a fresh spot from the series oracle (`trySpot` ok: source 0 answered inside the market's
  `spotMaxAge`, the oracle not paused, price non-zero) at or past the strike, no margin. It returns `false`
  rather than reverting for every "nothing to do" case, moves no collateral, and runs under trading, mint and
  create pause and on a disabled market, because `OrderBook.cancel` is never paused. After a cancel the
  position keeps its `longId` and `expiry` with `orderId` 0: **no re-roll inside the same period** (owner
  default), so one position, one `Rolled` and at most one ROLL bounty per period, and the close-out still
  settles and redeems partial fills.
- **`reprice` refuses an in-the-money ask** (`InTheMoney`), between the spot read and the band check, so a
  pricer cannot keep quoting an ask the market has overtaken.
- **A 30-minute open grace on `roll`** (`ROLL_OPEN_GRACE`). Inside the first half hour of a regular session
  `roll` returns `false` unless the reading it holds was itself observed in session that day, so a gap at the
  open cannot set a strike and an ask around yesterday's close
  (`AutoRollerTimingTest.test_openGrace_gapAtTheOpen_rollWaitsForTheOpeningPrint`).

**What is still not protected.** The cancel is a transaction *after the fact*: a taker who backruns the
crossing print, or who trades on an off-chain price before the feed prints, can still fill. While the feed
is live that edge is bounded by its 0.5 % deviation step, but gaps, after-hours and weekend moves the feed
never prints are not bounded, and the book trades 24/7
(`AutoRollerStrategyTest.test_ask_rallyBeforeTheCancel_stillFills`). Keeper liveness matters: nothing is
cancelled unless someone calls, and an outage longer than `spotMaxAge` after the crossing print leaves
nothing cancellable until the next print. A paused or reverting oracle returns `false`. Source 0 is trusted
for both the trigger and the grace, so a UniV3 TWAP listed first would make grief-cancelling possible and
would void the grace — `VerifyV8` checks the oracle's source list starts with the `ChainlinkFeedSource`. And
the product cost stands: a rally past the strike ends the writer's ask for the rest of the week or day, so a
weekly writer can lose most of a week's premium (and keeps the stock's upside). The notifier and the web must
not describe this as protection.

---

## 7. Things that look wrong but are not

- **An ITM call was paid in Stock Tokens.** The holder chose in kind, no adapter or route is set, the
  conversion missed its floor (valued at the spot when a fresh spot is above the settlement price), or a third
  party redeemed more than 30 minutes after expiry without a fresh spot ([§6.8](#68-conversion-slippage-and-who-captures-it)). The Stock Tokens are worth the payout at the settlement price
  (`ClearinghouseRedeemTest.test_redeem_itmCall_longAndShortInKind`).
- **The payout is a little under `(P − K)` per share.** The exercise fee comes out of it, and every
  division floors against the long; the writer's short picks up the dust
  ([V2-ACCOUNTING.md §7](V2-ACCOUNTING.md#7-rounding-every-division)).
- **A settlement sat "Pending" for hours.** Only one source answered, or two disagreed; the candidate
  waits the market's delay so the guardian can look.
- **The pool snapshot is taken after expiry.** It prices `[E − 1800, E]`, not the moment of the call
  (`UniV3TwapSourceTest.test_record_windowPinnedToExpiry`).
- **16:00 New York is 20:00 UTC in September and 21:00 UTC in December**
  (`V2DocsNumbersTest.test_docs_expiryClockShiftsWithDst`).
- **A write-on-fill ask was skipped in a take.** The maker's free collateral did not cover the whole
  fill (fills are whole or skipped), the book was not its operator, the market could not mint
  (`OrderBookTakeTest.test_take_askWrite_wholeOrSkipped_withOneCollateralBudgetPerMaker`,
  `OrderBookTakeTest.test_take_askWrite_skippedWhileTheMarketCannotMint`), or the writer's or the
  recipient's acceptance hook refused the tokens or needed more than the 500,000-gas delivery cap
  ([§6.10](#610-makers-that-are-contracts)).
- **`Redeemed.to` is the Clearinghouse.** The payout went to the holder's free ledger, by preference or
  because the transfer failed.
- **A `Redeemed` log with amount 0.** An out-of-the-money long was burned.
- **The OrderBook holds my long tokens.** They are the escrow of a resale ask; `cancel` or, after
  expiry, `prune` returns them.
- **One taker fee for many orders.** The fee is per `take` call, split between the makers as rebates;
  the rebates never exceed it.
- **The oracle ignores a later Chainlink round.** An ok capture is never re-read.
- **The market's sources changed, but a series still settles on the old ones.** Its expiry was pinned
  when its first series was created; changes apply to expiries without series
  ([§3.3](#33-capture-and-pinning)). `settlementConfig(underlying, expiry)` shows what an expiry settles on.
- **The first series of an expiry costs more gas than the next ones.** It pins the configuration on the
  oracle and every source ([V2-GAS.md](V2-GAS.md)).
- **`createSeries` reverts `SourceNotPinned(source, reason)`.** A source of the market could not pin the
  expiry. `reason` `NotAuthorized` (0xea8e4eb5): the source does not list the oracle (`setOracle`);
  `NoSource` (0x7d19c0ff): the source has no configuration for the underlying; `PinMismatch` (0x52e8e6d6): the source
  pinned that expiry earlier with a configuration it no longer has; zero: no code, a wrong answer or out
  of gas (selectors: `InterfaceIdsTest.test_interfaceV6_pinSignatures`). Wiring faults; VerifyV8's pin dry
  run shows them.
- **`createSeries` reverts `PinMismatch`.** The expiry was pinned outside a series creation (or by a
  previous Clearinghouse) with a configuration that is not the market's current one:
  `settlementConfig(underlying, expiry)` shows the pin, `pinnedBy(underlying, expiry)` who made it. Series
  of that expiry can be created only once they match again.
- **Every strike of an expiry settled at the same price.** The settlement price is per underlying and
  expiry.

---

## 8. Decisions the plan left open

What the tasks decided while building, recorded in their hand-off notes, grouped by contract.

**OptionMath and units.** Long and short payouts are differences (`gross − fee`, `collateral − gross`),
so conservation per unit is exact; rounding favours the short. `registerMarket` rejects a zero tick.

**ExpiryCalendar.** `nextExpiry` ignores special expiries and searches 14 days
(`V2DocsNumbersTest.test_docs_contractConstants`), reverting `BadExpiry` beyond; the regular session
is `[09:30, 16:00)` New York (`ExpiryCalendarTest.test_regularSession_edgesInEdtAndEst`); extra views `holiday`, `specialExpiry`, `isSessionDay`, `closeOf`.

**Price sources.** The pool records exactly `[E − 1800, E]` (`InterfaceIdsTest.test_constants_times`), not "the 30 minutes before the call";
`record` reverts before expiry and returns false after the grace; the jump rule also checks the round
in force at `start` against its predecessor; a failed `oraclePaused()` read counts as paused.

**Pinning (owner decision 2026-09-17).** The configuration is pinned per `(underlying, expiry)`, not per
series: every series of an expiry shares one settlement price, so they share one pin, taken by the first.
The oracle copies its market row; each source copies its own row (a copy, not a version, so a pinned
pool keeps working after the market moves to another), except Data Streams, whose per-underlying
observation ring cannot keep another stream's prints and so pins a feed version instead. Pinning fails
closed (hardening of the same day): any source pin failure reverts the creation with one error naming
the source and the first four bytes of its reason, a source must answer the `IPriceSource.pin` selector
(so a contract that merely accepts the call does not count as pinned), an unconfigured source refuses
to pin, and a pin by another caller is confirmed only against the current configuration, on the oracle
(recording `pinnedBy`, packed into the existing slot so a later series costs what it did) and on each
source. `pin` checks its caller before its idempotency. The sources use an allow-list of oracles rather
than one pointer, so two oracles can share them during a migration. `spot` stays market-level.

**SettlementOracle.** The first finalize with any ok source captures all sources; not-ok entries are
re-asked and upgraded; list and deviation pinned at capture; a changed candidate restarts the delay;
`finalizableAt` is stored at announcement; the guardian may veto before expiry; `unveto` always goes to
Pending with a fresh delay; SNAPSHOT pays per recording call and FINALIZE per advancing call, never
with zero open interest, never on an expiry the current Clearinghouse has not pinned on this oracle (open interest
counts every oracle's series, so a second oracle sharing the sources during a migration would otherwise pay for an
expiry it has no series of), and never to the Clearinghouse or to a contract whose pin a later Clearinghouse
confirmed (an old Clearinghouse settling its series after a migration; sweep contracts-c11,
`SettlementOracleBountyTest.test_bounty_notPaidOnAnExpiryTheClearinghouseDidNotPinHere`,
`SettlementOracleBountyTest.test_bounty_neverPaidToAClearinghouseThePinMovedFrom`,
`PinnedSettlementTest.test_migrations_payNoBountyForAnotherOraclesExpiryNorToTheOldClearinghouse`); `adminResolve` captures before checking the
band, and from `E + 7 days` a Held expiry with exactly one ok price resolves within a factor of 1.25 of it
(sweep contracts-c12: with one price recorded and vetoed, nothing else can ever reach the true one).

**Clearinghouse.** `locked(longId)` is derived, not stored; `createSeries` on an existing id returns
early; the spot band is skipped when spot is unavailable; only ITM call longs convert; `minOut` is
value at the higher of the settlement price and an ok spot, as the market's own `spotMaxAge` defines ok (a spot
read capped at 150,000 gas; without
an ok spot a third party converts only until 30 minutes after expiry) less the slippage bound plus the route's pool fee (a gas-capped read; a
failed read counts as 0, an answer above 100 bps as 100, the sum at most 300 bps), with an exact approval
zeroed afterwards; a
partial pull or short output falls back in kind; a redemption takes at most `2^64 − 1` units per call;
deposits of a disabled market's token are accepted; bounties are raw calls; mint callbacks run after
all three logs and cannot re-enter; ERC-1155 transfers and approvals hold the reentrancy guard.

**OrderBook.** An order is live while `now < validUntil`; `take` plans with views and executes in the
caller's order; a fill that fails at execution stops the round and the book re-plans from the next id;
write-on-fill and sale-from-inventory fills are whole or skipped with one collateral or inventory
budget per account per take; the taker-fee share is pro rata by premium with the last planned fill
absorbing the dust; failed payments are credited to `owed`; `replace` keeps kind, series and
`validUntil`; `quoteTake` uses `msg.sender` as the taker. Fee changes are scheduled
`FEE_CHANGE_DELAY` ahead — 24 hours when the scheduling was introduced in interface version 6, and 48
hours from INTERFACE_VERSION 8 (`src/v2/interfaces/V2Constants.sol:60`): `take` only reads the
schedule, and a change that has become due is copied into storage by the next `setFeeParams`; the
constructor's fees apply at once.

**KeeperRewards.** The rolling cap is five 6-hour epochs; a new contract's cap is 0.

**AutoRoller.** One position per period; `stop` and `setStrategy` keep the position; close-out waits for
settlement only while the writer still holds shorts, and a call that closes out does not also roll; strike and ask round up; `reprice` needs the role,
an active smart-pricing strategy and a price inside the writer's band; bounties earned inside a roll
are forwarded to its caller.

**UniV3PayoutAdapter.** Anyone may call `swapToUsdg` (it pulls only from its caller and holds
nothing); the pool is checked against the router's own factory; the router must consume the whole
amount; `routeFeeBps` is the route's fee tier / 100 rounded up, 0 without a route; `setRoute` refuses a fee tier
above 10000 (the most route fee the Clearinghouse's floor allows for) before it asks the factory.

**MakerVault, MakerRegistry, RewardsDistributor.** Vault guards are post-conditions that refuse only
actions that grow exposure past a cap; a registry tier of 0 means the book default; a Merkle root
cannot be replaced, and claims never pay an epoch beyond its posted total.

**DataStreamsSource.** Verified per report, never reverting the batch; regular-hours prints only;
windows are sealed before the first finalize; not registered for any market.

---

## 9. Where the numbers come from

Run from the repository root.

```bash
forge test --match-contract V2DocsNumbersTest -vv     # the constants, DST clock and worked examples these docs quote
forge test --match-contract InterfaceIdsTest -vv      # V2Constants and the v8 role table: units, times, fee ceilings, roles
forge test --match-contract LifecycleTest -vv         # the whole life of a weekly ladder
forge test --match-path 'test/v2/**' -vv              # every v2 test named on this page
forge test                                            # the whole offline gate
FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC    # the fork suites (test/fork and test/v2/fork)
```

**The invariant suite.** `test/v2/invariant/V2Invariant.t.sol` runs 256 runs × 64 calls per invariant
(its inline `forge-config` lines) through 29 handler actions, including oracle faults, mid-life
reconfiguration of the market, the feed and the pool, the admin's pinning attacks (the oracle taken off
a source's allow-list, pre-pins through the Clearinghouse pointer and the source allow-lists), USDG
pause and freeze, veto and resolve, and unauthorised attempts. `V2InvariantTest.test_handler_walkReachesEveryStage` proves a fixed walk of 16
episodes reaches fills, mints, closes, cancels, prunes, corroborated and uncorroborated finalizations,
settlements, paid redemptions, and finalizations of an expiry whose configuration the admin had changed
after its pin. The invariants, as the file states them:

1. Unsettled series: long supply equals short supply, and `locked` equals long supply × collateral per
   unit; open interest of an expiry is the sum of its series' long supply.
2. Per asset: Σ free + Σ locked + accrued fees equals the Clearinghouse's token balance, which equals
   deposits minus withdrawals, payouts and sweeps.
3. Settled series: long + fee + short equals collateral per unit; payouts and fees never exceed what the
   series held at settlement, and `locked` is what remains.
4. `close`, `redeem`, `withdraw`, `cancel`, `prune`, `settle`, `snapshot`, `finalize`, transfers, sweeps
   and claims never revert where allowed, under every pause and oracle fault; every gate reverts where
   it must.
5. No call moves another account's wallet, ledger or tokens, except a take spending exactly the
   collateral of that account's filled write-on-fill asks, and a redemption, which only pays it.
6. (B1) The book's USDG equals open bid escrow plus Σ owed, exactly.
7. (B2) The book's long tokens per id equal open resale escrow exactly; it never holds a short.
8. (B3) Per take: rebates ≤ taker fee, fills add up to the take, and the book pays out exactly what it
   takes in.
9. (6 in the file) An expiry settles on the configuration its first series pinned, whatever the admin
   changed since: pinned with the source list, deviation and delay in force then, captured with those,
   and an expiry pinned while market, feed and pool were honest never settles at the 400 USDG every
   replacement prices at. Under the pinning attacks, every series on the oracle has its expiry pinned on
   the oracle and on every real source of the pinned list, every pin (oracle, `pinnedBy`, feed, pool) is
   exactly the handler's model, and an expiry is pinned only when the model pinned it.

**Chain facts** (read-only calls; `RH_RPC=https://rpc.mainnet.chain.robinhood.com` works):

```bash
# C1: the NVDA feed proxy's owner (the TSLA proxy 0x4A1166a659A55625345e9515b32adECea5547C38 answers the same)
cast call 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15 "owner()(address)" --rpc-url $RH_RPC
#   0xeE27D5Ae494300902D90454e8630A3F1C68c9C52
# C2: its threshold
cast call 0xeE27D5Ae494300902D90454e8630A3F1C68c9C52 "getThreshold()(uint256)" --rpc-url $RH_RPC
#   4
# C3: its owners (a list of 9 addresses)
cast call 0xeE27D5Ae494300902D90454e8630A3F1C68c9C52 "getOwners()(address[])" --rpc-url $RH_RPC
# C4: the NVDA/USDG pool's fee tier and tokens
cast call 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3 "fee()(uint24)" --rpc-url $RH_RPC      # 500
cast call 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3 "token0()(address)" --rpc-url $RH_RPC  # USDG 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
# C5: the Data Streams VerifierProxy
cast call 0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7 "typeAndVersion()(string)" --rpc-url $RH_RPC   # "VerifierProxy 2.0.0"
cast call 0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7 "s_feeManager()(address)" --rpc-url $RH_RPC    # 0x0000000000000000000000000000000000000000
cast call 0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7 "s_accessController()(address)" --rpc-url $RH_RPC  # 0x0000000000000000000000000000000000000000
# C6: the fee tier of every registry pool (run in stonkhousedotfun/callhouse)
jq -r '.markets[] | select(.v2.univ3Pool) | "\(.ticker) \(.v2.univ3Pool)"' ops/markets/tier1.json |
  while read -r t p; do echo "$t $(cast call "$p" "fee()(uint24)" --rpc-url $RH_RPC)"; done
#   500: AAPL GOOGL NVDA QQQ SPCX; 3000: AMZN CRCL MSFT MU SGOV TSLA USO; 10000: GME
```

These were read on 2026-09-17. Chain state can change; re-run them before relying on them.
