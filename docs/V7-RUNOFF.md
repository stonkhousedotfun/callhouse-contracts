# v7 run-off: freezing the live contract set before v8

v8 is a full redeploy: a new Clearinghouse, a new OrderBook, new everything. The v7 set deployed on
2026-09-18 is not migrated and not upgraded — it is **frozen and allowed to run off**. Freezing stops
new risk. It does not, and must not, stop anyone getting out.

> **A user must never be trapped in a v7 position by the freeze.** Everything that gets a holder out
> — `close`, `redeem`, `withdraw`, `OrderBook.cancel`, and selling a long on the book — keeps working
> exactly as it did. That is the single property this whole procedure is built around, and
> `test/v2/fork/FreezeV7Fork.t.sol` proves it against the live contracts on a fork.

Everything below is read from the deployed v7 code and from the chain. Nothing here changes `src/v2`.

| Piece | What |
|---|---|
| `script/v2/FreezeV7.s.sol` | reads the live set, reports the run-off, and writes the plan: guardian `setCreatePaused(true)`, admin `setMarketConfig(market, enabled = false)`. **Read-only: no broadcast path, no key input.** |
| `test/v2/integration/FreezeV7.t.sol` | 25 tests against a real Clearinghouse and OrderBook: the refusals, the plan, and every claim this file makes about a frozen market |
| `test/v2/fork/FreezeV7Fork.t.sol` | 8 tests against the **live** v7 set on a fork, applied with the exact bytes the plan holds, sent by the real role holders |

---

## What the freeze does

Two calls. Both are instant: v7 has no timelock (the AccessManager with delays arrives with v8), so
each is effective in the block it lands. That is not inferred from the absence of an AccessManager —
`test/v2/fork/FreezeV7Fork.t.sol` applies both calls against the **live** v7 set on a fork and asserts
the new state immediately, with no time advanced anywhere in the file: `test_fork_freezeAppliesAndIsIdempotent`
reads back `createPaused()` and a disabled market, and `test_fork_afterTheFreeze_newRiskIsRefused` gets
`MarketDisabled` from `mint` and `createSeries`. A delay on either setter would fail both.

| Call | Role | Effect |
|---|---|---|
| `setCreatePaused(true)` | `GUARDIAN_ROLE` (live: `0x2974…6F39`) | `Clearinghouse.createSeries` reverts `CreatePaused` (`Clearinghouse.sol:373`), so no new series id opens in **any** market. Nothing else reads the flag. |
| `setMarketConfig(NVDA, cfg with enabled = false)` | `DEFAULT_ADMIN_ROLE` (live: `0xEb82…9d9b`) | `createSeries` reverts `MarketDisabled` (`:372`) and — the point of it — `mint` reverts `MarketDisabled` (`:478`), so **no unit can be written into a series that already exists**. |

**Why both.** `setCreatePaused` stops new series *ids*; it does not stop `mint` on a series already
created, and 32 v7 series already exist. Disabling the market is what closes that. Conversely the
market disable only covers the market it names, while the create pause covers any market at all. The
script refuses to build a plan that leaves a registered, still-enabled market out
(`FreezeV7.freezeSet`, `test_freezeSet_refusesAnEnabledMarketLeftOut`), and refuses to build a
`setMarketConfig` that differs from the chain's own row in anything but `enabled`
(`_checkFreezeOnly`, `test_plan_flipsEnabledAndNothingElse`). `mintPaused` is guardian-owned and the
Clearinghouse keeps its stored value whatever an admin config push carries, so the freeze cannot lift
a guardian pause either.

Send the guardian's call first: it is the one that covers everything.

## What the freeze does not do

- **It does not pause the order book.** `OrderBook.setTradingPaused` is deliberately not part of the
  freeze, and `FreezeV7.s.sol` cannot even encode it. Pausing the book would stop `place`, `replace`
  and `take`, and taking away resale would take away the only way a holder has of selling a long
  before expiry — that is trapping someone, and it stops no new risk, because a resale moves an
  existing long and mints nothing. `FreezeV7.postCheck` treats a paused book as a **failure**
  (`test_postCheck_failsWhenTheBookWasPaused`). If the book ever does need stopping, that is a
  separate, deliberate owner decision with its own reason.
- **It does not cancel resting orders, and it does not need to.** A resting `AskWrite` can no longer
  fill, because the book reads the market's `enabled` when it plans a fill
  (`OrderBook.sol:900`) and plans the order as a skip; it escrows nothing, so no funds sit behind it.
  `Bid` and `AskResale` orders keep their escrow and their maker can `cancel` at any time; a keeper
  can `prune` them once `validUntil` passes. Makers should cancel what they no longer want, at their
  own pace. (The live book has no resting orders: `lastOrderId()` is 4, one filled and three already
  cancelled.)
- **It does not stop the cranker.** `SettlementOracle.snapshot` / `finalize`, `Clearinghouse.settle`,
  `redeem` and `redeemBatch` read no pause and no market flag. Every expiry after the freeze settles
  and pays exactly as it would have (`test_afterTheFreeze_theExpiryStillSettlesAndRedeems`).
- **It does not stop the AutoRoller getting a writer out.** `stop` and `cancelStale` are documented to
  run on a disabled market (`AutoRoller.sol:333`), and `roll`'s close-out half — settle, redeem the
  writer's shorts, prune the dead ask — runs too. Only the half that would place a NEW ask reverts
  `MarketDisabled` (`:281`). A strategy stays `active` in storage and simply never rolls again.
- **It moves no funds**, changes no role, no fee, no fee recipient, no payout adapter, no calendar and
  no oracle, and touches no user balance.
- **It has nothing to do with v1.** The v1 solo markets have their own freeze and their own runbook,
  `docs/V1-RUNOFF.md`.

## What a v7 user can and cannot do after the freeze

| A v7 user wants to… | After the freeze | Why |
|---|---|---|
| open a new series | **no** | `createSeries` reverts `MarketDisabled` (`CreatePaused` in any market still enabled) |
| write (mint) more contracts | **no** | `mint` reverts `MarketDisabled` |
| buy a contract from a writer (a primary fill) | **no** | the fill would mint; the book plans it as a skip |
| **buy or sell an existing contract on the book** (resale) | **yes** | `place`, `replace` and `take` read no market flag; the book is not paused |
| **cancel a resting order and get the escrow back** | **yes** | `OrderBook.cancel` and `prune` are never pausable |
| **close a long and short against each other** | **yes** | `close` reads no flag; it refunds the collateral **and** the unused rent |
| **deposit / withdraw collateral** | **yes** | `withdraw` is never pausable; `deposit` is not blocked either |
| **let the expiry settle** | **yes** | `snapshot`, `finalize` and `settle` are permissionless and read no flag |
| **redeem after settlement** | **yes, for ever** | `redeem` / `redeemBatch` pay from collateral the Clearinghouse already holds. There is **no deadline**: an unredeemed position can be redeemed years later |
| stop an AutoRoller strategy, or pull a stale ask | **yes** | `stop`, `cancelStale`, and `roll`'s close-out all run on a disabled market |

Nothing above needs the keeper, the indexer, the web app or any Stonkhouse service. Every one of
these is a direct call the holder can make from a block explorer's write-contract tab, and the
Clearinghouse has no role that can move, freeze or seize a user's collateral or tokens (ADR-09).

## When the run-off ends

Two different dates, and the document has to keep them apart:

- **When the last position expires** — the largest expiry among the series that still carry units at the
  freeze. After it, nothing is open; everything left is a redemption.
- **When the last settlement job is due** — the largest expiry among the series that *exist*. The
  cranker still settles those, whether or not anybody holds them.

Both are computed, never assumed: `script/v2/FreezeV7.s.sol` reads every `SeriesCreated` log of the
Clearinghouse from the deploy block, reads each series back from the chain for its expiry, settled
flag and live long supply, and then walks the expiry grid independently (`ExpiryCalendar.nextExpiry`)
reading `openInterest` at every session close, so an expiry carrying units that the log scan missed is
reported rather than quietly dropped.

**The hard ceiling** is `freeze time + MAX_TENOR`, 45 days (`V2Constants.MAX_TENOR`): `createSeries`
refuses an expiry beyond it, so **no series created before the freeze can expire more than 45 days
after it**, whatever else is true. Run the tool at freeze time for the exact figure.

### The live set, read at block 67,497,154 (2026-09-20 00:04:09 UTC)

- **32 series**, all NVDA calls, across six expiries: 2026-09-18, -21, -22, -23, -25 and 2026-10-02.
- **One series carries units:** the **$225.00 call expiring 1,789,761,600 = 2026-09-18 20:00:00 UTC
  (Friday 2026-09-18, 16:00 America/New_York)**. It is already settled, at 219.781808 USDG, so it
  expired out of the money: the long payout is 0 and the short payout is the whole collateral. The
  writer has already redeemed its 100 shorts; **100 long units (1.00 share) held by
  `0x3bE5…Ef6a` are still unredeemed**, and worth nothing. That holder can redeem whenever they like.
- **Six expired series are not yet settled.** All six hold zero open interest, so settling them moves
  no money and pays no bounty; `settle` stays callable by anyone for ever.
- **Last expiry over any series: 1,790,971,200 = 2026-10-02 20:00:00 UTC (Friday 2026-10-02, 16:00
  America/New_York).** Frozen at this block, that is when v7's settlement work ends.
- **Last expiry still holding units: 2026-09-18 20:00:00 UTC — already past.** Frozen at this block,
  **no v7 user has an unexpired position at all**; the run-off is one redemption of a worthless long.

The live pricer keeps opening series until the freeze lands, so **re-run the tool at freeze time and
quote its figures, not these**. These are what the fork dry run recorded.

## When the v7 services can be switched off

| Service | Needed for | Off when |
|---|---|---|
| cranker (`snapshot` / `finalize` / `settle` / `redeem`) | settling each remaining expiry and pushing payouts | every series past its expiry is settled, and no expiry reports open interest. All three calls stay permissionless afterwards, so a straggler can still be settled by anyone |
| MM quoter, pricer, AutoRoller keeper | quoting and rolling | at the freeze. There is nothing left to quote or roll: every `roll` that would place reverts `MarketDisabled` |
| indexer-v2, web, site | whatever of the v7 route still reads them | after the legacy v7 route is retired (`W8-03`). The contracts never need them — `close`, `withdraw`, `cancel` and `redeem` work from a block explorer |
| notifier | v7 activity | at the freeze; its cursor into the **v7** feed must be reset before it is pointed at v8 (`06-QUIRKS.md` §G) |

Freeze the v7 ABIs for the legacy route **before** exporting v8's: the exporters delete what is no
longer listed (`06-QUIRKS.md` §B6). Do not lift `createPaused` and do not re-enable a v7 market:
leave both as the freeze leaves them, for good.

---

## Owner commands

Owner-gated: nothing here is run by an agent, and `FreezeV7.s.sol` cannot send a transaction on any
path — it has no broadcast mode and takes no key. Keys never go on a command line: load them from a
silent prompt or your secret store and unset them afterwards. Every `forge` call uses
`--no-storage-caching` (`docs/DEPLOY.md` explains the fork cache).

```bash
cd callhouse-contracts                       # the checkout at the tagged commit
export RH_RPC=https://rpc.mainnet.chain.robinhood.com

# 1. Read the live set: the switches, every series, the run-off dates, and the plan.
#    It writes broadcast/freeze-v7-{guardian,admin}-safe-batch.json and sends nothing.
forge script script/v2/FreezeV7.s.sol --rpc-url $RH_RPC --no-storage-caching --non-interactive

# 2. Rehearse on a fork. Mandatory. Applies the plan from the real role holders and proves that
#    close / redeem / withdraw / cancel / resale all still work afterwards. 8 tests.
FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC --no-storage-caching \
  --match-path "test/v2/fork/FreezeV7Fork.t.sol" -j 1 -vv

# 3. Send the two calls, guardian first. Either from the keys, one at a time:
read -rs GUARDIAN_PK && export GUARDIAN_PK    # silent prompt: not in the process table, not in history
cast send 0x22dEf851cD1a3B04Ad7d232bE786d76E6944d424 "setCreatePaused(bool)" true \
  --private-key $GUARDIAN_PK --rpc-url $RH_RPC
unset GUARDIAN_PK
read -rs ADMIN_PK && export ADMIN_PK
cast send 0x22dEf851cD1a3B04Ad7d232bE786d76E6944d424 <the admin calldata from step 1> \
  --private-key $ADMIN_PK --rpc-url $RH_RPC
unset ADMIN_PK
#    or from Safes: import broadcast/freeze-v7-guardian-safe-batch.json on the guardian Safe and
#    broadcast/freeze-v7-admin-safe-batch.json on the admin Safe (Transaction Builder). The files
#    have no checksum, so Safe{Wallet} warns; decode every call before signing:
cast calldata-decode "setCreatePaused(bool)" 0x83bcec85…                      # must print: true
cast calldata-decode "setMarketConfig(address,(bool,bool,uint64,uint16,address,uint32))" 0x8a8e5070…
#    must print NVDA and the market row with enabled = false and EVERY other field as step 1 read it

# 4. Verify. Re-run step 1: it must plan 0 calls and print the post-check.
forge script script/v2/FreezeV7.s.sol --rpc-url $RH_RPC --no-storage-caching --non-interactive
cast call 0x22dEf851cD1a3B04Ad7d232bE786d76E6944d424 "createPaused()(bool)" --rpc-url $RH_RPC   # true
cast call 0x22dEf851cD1a3B04Ad7d232bE786d76E6944d424 \
  "market(address)((bool,bool,uint64,uint16,address,uint32))" \
  0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC --rpc-url $RH_RPC        # enabled = false, rest unchanged
cast call 0x9fcAe743C3fA0aEC7DB9b1d01e86464b85759942 "tradingPaused()(bool)" --rpc-url $RH_RPC  # FALSE

# 5. During the run-off: re-run step 1 for the remaining series and their expiries. A manual settle,
#    if the cranker is off, from anyone's wallet:
cast send 0x22dEf851cD1a3B04Ad7d232bE786d76E6944d424 "settle(uint256)" <longId> \
  --account <keystore-name> --rpc-url $RH_RPC
```

### The exact transactions, in order

As the tool read them at block 67,497,154. The admin calldata embeds the market row that was on
chain at that block: **regenerate it in step 1 at freeze time** and send what that run prints.

**1 — guardian `0x29741A8d283a253E8Ce10aDfd04C6507438b6F39` → Clearinghouse
`0x22dEf851cD1a3B04Ad7d232bE786d76E6944d424`**

`setCreatePaused(true)`

```
0x83bcec850000000000000000000000000000000000000000000000000000000000000001
```

**2 — admin `0xEb82c3D0F89d47453F94f0C2b2a2752e27a19d9b` → Clearinghouse
`0x22dEf851cD1a3B04Ad7d232bE786d76E6944d424`**

`setMarketConfig(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, {enabled: false, mintPaused: false,
strikeTick: 2500000, exerciseFeeBps: 25, oracle: 0xb205984b5F2F9010c2bD8aCA46d946Fe1c4F2A54,
mintFeePpm: 80})` — the live row with `enabled` flipped and nothing else moved.

```
0x8a8e5070000000000000000000000000d0601ce157db5bdc3162bbac2a2c8af5320d9eec
  0000000000000000000000000000000000000000000000000000000000000000
  0000000000000000000000000000000000000000000000000000000000000000
  00000000000000000000000000000000000000000000000000000000002625a0
  0000000000000000000000000000000000000000000000000000000000000019
  000000000000000000000000b205984b5f2f9010c2bd8aca46d946fe1c4f2a54
  0000000000000000000000000000000000000000000000000000000000000050
```

(one 32-byte word per line; send it as a single hex string).

There is no third transaction. In particular **do not** send `setTradingPaused`.

### Environment, running the script directly

| Env | What |
|---|---|
| `V7_CLEARINGHOUSE`, `V7_ORDER_BOOK` | default the live addresses above; the book must point at the Clearinghouse |
| `V7_MARKETS` | comma-separated underlyings to disable. Default: every market the `MarketRegistered` logs name. A set that leaves a registered, enabled market out is **refused** |
| `V7_GUARDIAN`, `V7_ADMIN` | default the registry's; each must hold its role on the Clearinghouse or the run stops before anything is planned |
| `V7_FROM_BLOCK`, `V7_LOG_CHUNK`, `V7_MAX_SERIES` | the `SeriesCreated` scan: start block (default the deploy block 65,780,341), blocks per `eth_getLogs` call, buffer size |
| `V7_REGISTERED_MARKETS`, `V7_SERIES` | the registered markets and the series ids given instead of read, for a node that caps `eth_getLogs`. The dates are then only as complete as the lists; the grid cross-check is what catches a short one |
| `V7_GRID_FROM`, `V7_EXTRA_EXPIRIES` | grid cross-check start (default the deploy timestamp) and any admin-whitelisted **special** expiry, which is off the grid and cannot be enumerated on chain (none exist on the live set) |
| `V7_PLAN` | `false` to report without writing the plan files |
| `V7_GUARDIAN_PLAN_OUT`, `V7_ADMIN_PLAN_OUT` | default `broadcast/freeze-v7-{guardian,admin}-safe-batch.json` |
| `V7_EXPECT_CHAIN_ID` | default 4663 |

Idempotent: a Clearinghouse already create-paused gets no pause call, a market already disabled no
config call, and a run with nothing left plans nothing and runs the post-check instead.

---

## Fork dry-run record — 2026-09-20

`FOUNDRY_PROFILE=fork forge test --fork-url https://rpc.mainnet.chain.robinhood.com
--no-storage-caching --match-path "test/v2/fork/FreezeV7Fork.t.sol" -j 1 -vv`, fork block
**67,497,154** (timestamp 1,789,862,649 = 2026-09-20 00:04:09 UTC). **8 of 8 passed.** Read-only
against mainnet: the freeze was applied to the local fork with `vm.prank`, nothing was broadcast and
no key was used.

| Check | Result |
|---|---|
| role holders | the registry's guardian `0x2974…6F39` holds `GUARDIAN_ROLE` and admin `0xEb82…9d9b` holds `DEFAULT_ADMIN_ROLE` on the live Clearinghouse; the guardian is not the admin; the book points at the Clearinghouse |
| the plan | exactly 2 calls, both to the Clearinghouse, the two selectors above and no others; building it changed nothing on chain |
| the run-off | 32 series, 1 carrying units (100), 6 expired and unsettled; last expiry 1,790,971,200; last expiry holding units 1,789,761,600; every expiry on the 16:00 New York grid; the grid cross-check found no expiry with open interest the scan had missed |
| the freeze applied | the guardian's call from the guardian and the admin's from the admin, byte for byte from the plan: `createPaused()` true, `market(NVDA).enabled` false, `tradingPaused()` still **false**; a second run planned 0 calls and the post-check passed 3 of 3 |
| new risk refused | `mint` reverts `MarketDisabled`; `createSeries` on a new strike reverts `MarketDisabled`, and `CreatePaused` after the market was re-enabled on the fork |
| **nobody is trapped** | after the freeze, on the live book and Clearinghouse: a buyer **took** 10 units from a resting resale ask; the maker **cancelled** the rest and the escrowed longs came back; the bidder **cancelled** and the escrowed USDG came back; the writer **closed** 30 units and was credited the collateral plus the rent refund; the writer **withdrew** the whole free balance to its own wallet; and the buyer **listed** its longs for resale |
| the live position | the real holder `0x3bE5…Ef6a` of the settled $225.00 2026-09-18 call **redeemed** all 100 units after the freeze |

What this does **not** prove: the real guardian and admin keys (pranked here), Safe{Wallet} importing
the batch files or hardware signing, the keeper's and MM's behaviour on a frozen market, or the web
app's legacy v7 route.
