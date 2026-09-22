# Audit scope — Stonkhouse INTERFACE_VERSION 8

> **Status.** This is the scope of the **external audit of INTERFACE_VERSION 8** that owner decision
> **V3-D33** (2026-09-19) commissions, tracked as `OWN8-12`. At this commit the contracts are
> **unaudited**: no external audit report exists, no engagement is named here, and this repository
> links to no report. `C8-14` adds the link when one exists, and only then may any public copy stop
> saying "unaudited". Nothing described here is deployed: the v8 set has never been broadcast. What
> **is** on chain 4663 is the **v7** set, which this document does not scope
> ([docs/DEPLOY-V2.md](DEPLOY-V2.md), "Pinned deployed runtimes"; run-off is
> [docs/V7-RUNOFF.md](V7-RUNOFF.md)).
>
> The earlier file of this name scoped the **v1** Seaport/Valorem Vault. It is unchanged at
> [docs/AUDIT-SCOPE-V1.md](AUDIT-SCOPE-V1.md) and none of it is in scope here.

> **Paths** resolve from the root of this repository, stonkhousedotfun/callhouse-contracts. A path
> followed by (stonkhousedotfun/callhouse) lives in the app repository, which mounts this one as a
> submodule at `contracts/`.

> **This document does not restate the trust model or the accepted risks.** They live in
> [SECURITY.md](../SECURITY.md) and [docs/V2-ARCHITECTURE.md](V2-ARCHITECTURE.md) and are referenced
> from here on purpose: two copies of a threat model drift, and the copy an auditor reads must be the
> one the team maintains. §2 and §7 below are pointers, not summaries.

---

## Contents

1. [Purpose, and what a good report looks like](#1-purpose-and-what-a-good-report-looks-like)
2. [The system in one page, by reference](#2-the-system-in-one-page-by-reference)
3. [In scope](#3-in-scope)
4. [Out of scope, with reasons](#4-out-of-scope-with-reasons)
5. [Properties to try to break](#5-properties-to-try-to-break)
6. [Areas of concern, ranked](#6-areas-of-concern-ranked)
7. [Trust model and accepted risks, by reference](#7-trust-model-and-accepted-risks-by-reference)
8. [What the tests do and do not prove](#8-what-the-tests-do-and-do-not-prove)
9. [Build and run](#9-build-and-run)
10. [Reporting a finding](#10-reporting-a-finding)
11. [Appendix: what is half-landed at this commit](#11-appendix-what-is-half-landed-at-this-commit)

---

## 1. Purpose, and what a good report looks like

Stonkhouse is a covered-call options protocol on chain 4663. A writer deposits a Stock Token, sells a
call against it, and the collateral sits in an immutable Clearinghouse until the series settles on an
oracle price. INTERFACE_VERSION 8 is a **full redeploy** of that system — not an upgrade, because
nothing is upgradeable — with three changes an auditor should hold in mind throughout:

1. **One `AccessManager` replaces per-contract `AccessControl`.** Eleven `uint64` roles, each with an
   execution delay attached to the *lane* rather than to the key. The manifest is
   `script/v2/roles.v8.json` and `src/v2/access/V8Roles.sol` is its compiled mirror.
2. **Options can only be created inside a trade on an approved venue** (`mint on fill`), so every
   option's first sale carries a 5 % premium fee and true resales pay 0 %. Collateral rent, v7's
   writer fee, is compiled and tested but launches at 0.
3. **A fee flywheel**: a `FeeSplitter` takes the protocol's fees, converts them under an oracle floor
   and splits them 50/50 between a buyback balance and the treasury; a `V4BuybackExecutor` spends the
   buyback balance in a pinned Uniswap v4 pool and burns what it buys.

The core is **immutable**. There is no proxy, no `delegatecall` into replaceable code and no
`selfdestruct`, so a finding in the core is fixed by redeploying the core and migrating, which is the
most expensive outcome this project has. That is the whole reason this audit happens before the
broadcast rather than after.

**The most useful report is one that names a concrete, reachable loss or lie**, with the account that
suffers it and the sequence that gets there, on the code as it stands rather than on the code as this
document describes it. Where this document and the source disagree, **the source is the fact** — and
saying so is itself a finding worth filing (§10).

Severity: use your own scale; we map it onto **P1** wrong or unsafe behaviour, **P2** a guard nothing
would catch if it were deleted, **P3** a comment, doc or API inaccuracy, **P4** cleanup.

---

## 2. The system in one page, by reference

Read these first, in this order. They are maintained; this document is not their summary.

| Read | For |
|---|---|
| [docs/V2-ARCHITECTURE.md](V2-ARCHITECTURE.md) §1 | every contract, what it holds, who calls it, and the call graph |
| [docs/V2-ARCHITECTURE.md](V2-ARCHITECTURE.md) §2 | the trust model: the eleven roles, every admin and guardian power with its bound and its worst case, what no role can change, and what a user's approvals allow |
| [docs/V2-ARCHITECTURE.md](V2-ARCHITECTURE.md) §3 | oracle and settlement: the price, the sources, capture and per-expiry pinning, the fallback decision table |
| [docs/V2-ARCHITECTURE.md](V2-ARCHITECTURE.md) §§4-5 | the permissionless keeper surface, and exactly what each pause stops and never stops |
| [docs/V2-ARCHITECTURE.md](V2-ARCHITECTURE.md) §§6-7 | what is not protected, and the things that look wrong and are not |
| [docs/V2-ACCOUNTING.md](V2-ACCOUNTING.md) | the money maths, unit by unit, and the invariants as asserted (§10) |
| [SECURITY.md](../SECURITY.md) | status, the key-compromise table, what is not protected, and the accepted risks |
| [docs/V2-GAS.md](V2-GAS.md) | the gas figures and where they came from |
| [`src/v2/README.md`](../src/v2/README.md) | a file-by-file map of the tree |
| [docs/DEPLOY-V2.md](DEPLOY-V2.md) | the deploy runbook and the hand-over the manager gets |
| [docs/V2-BUYBACK-EXECUTOR.md](V2-BUYBACK-EXECUTOR.md), [docs/V2-DATA-STREAMS.md](V2-DATA-STREAMS.md) | the buyback venue, and the built-but-disabled price source |

---

## 3. In scope

Everything below is first-party Solidity in this repository that a v8 deploy puts on chain, plus the
scripts that put it there. Line counts are `wc -l` at this commit and are orientation, not a
measurement anyone should quote.

### 3.1 The immutable core

A finding here means a redeploy and a migration. Read these first.

| File | Lines | What it is |
|---|---:|---|
| `src/v2/Clearinghouse.sol` | 1216 | all collateral, every account's free ledger, accrued exercise fees, the market table, every series, ERC-1155 long and short tokens. `mint` is the mint-on-fill entry point and carries the `isMinter` allow-list |
| `src/v2/OrderBook.sol` | 1127 | the book: bids, write-on-fill asks, resale asks, `take`, the fee split, maker rebates, the just-in-time funding hook, the fee-discount seam |
| `src/v2/ExpiryCalendar.sol` | 258 | the NYSE holiday set and special expiries that decide what a valid expiry is |
| `src/v2/KeeperRewards.sol` | 297 | the bounty budget (treasury money) and the daily cap |
| `src/v2/AutoRoller.sol` | 578 | writers' roll strategies, the permissionless `roll` and `cancelStale`, and `reprice` |
| `src/v2/lib/OptionMath.sol` | 212 | pure payoff, collateral and fee maths |
| `src/v2/interfaces/V2Constants.sol` | 207 | every compiled bound: units, time bounds, fee ceilings, gas caps, the flywheel ceilings |
| `src/v2/interfaces/V2Types.sol` | 134 | every tuple that crosses the ABI, including `TakeParams` and `FeeParams` |
| `src/v2/interfaces/V2Errors.sol`, `V2Ids.sol` | 99, 36 | the shared error set and the id packing |

The remaining `src/v2/interfaces/I*.sol` files (about 1,860 lines across sixteen files) are the
published ABI. They are in scope **as documentation that must match the implementation** — a NatSpec
claim the bytecode does not honour is a real finding, and §11 records one we already know about.

### 3.2 The oracle stack — `src/v2/oracle/`

| File | Lines | What it is |
|---|---:|---|
| `src/v2/oracle/SettlementOracle.sol` | 958 | one settlement record per (underlying, expiry): capture, corroboration, the uncorroborated delay, veto, `adminResolve`, and the **per-expiry pin** that stops a live series being re-priced |
| `src/v2/oracle/ChainlinkFeedSource.sol` | 325 | prices a window from a feed's round history, with a staleness bound and a round-to-round jump bound |
| `src/v2/oracle/UniV3TwapSource.sol` | 435 | pool configuration, the snapshot, and the observation-ring depth requirement |
| `src/v2/oracle/DataStreamsSource.sol` | 661 | built and **disabled**: no market lists it. In scope because it can be enabled by configuration alone ([V2-DATA-STREAMS.md](V2-DATA-STREAMS.md)) |
| `src/v2/oracle/lib/PriceLib.sol` | 59 | first-party decimal and scaling maths |
| `src/v2/oracle/lib/TickMath.sol` | 57 | **first-party, not vendored** — see §4 |
| `src/v2/oracle/OracleDeps.sol`, `DataStreamsDeps.sol` | 55, 92 | hand-written minimal interfaces to Chainlink, the v3 pool and the Data Streams verifier, with the upstream schema pinned in comments |

### 3.3 Access — `src/v2/access/`

| File | Lines | What it is |
|---|---:|---|
| `src/v2/access/Managed.sol` | 73 | the shared base of every v8 target: `AccessManaged` with `V2Errors.NotAuthorized()` in place of OpenZeppelin's own error, a current-authority-only `setAuthority`, and a `_checkCanCall` override. One storage slot, deliberately placed where v7's `AccessControl` slot was |
| `src/v2/access/V8Roles.sol` | 139 | the compiled mirror of the manifest: eleven role ids and their execution delays |
| `script/v2/roles.v8.json` | — | **the manifest itself, and the most load-bearing file in the audit.** Every `(target, selector) → role`, every delay, every holder, the role-admin and role-guardian trees, and an explicit list of entry points that carry **no** role on purpose |

The `AccessManager` bytecode is unmodified OpenZeppelin and is out of scope as *code* (§4). **Its
configuration is in scope and is the highest-value thing in this document**: a selector mapped to the
wrong role, a selector left unmapped (which falls to `ADMIN` by default), a delay that is shorter than
the document says, or a role guardian that can cancel something it should not, are all findings here.

### 3.4 Periphery that holds or moves money — `src/v2/periphery/`

| File | Lines | What it is |
|---|---:|---|
| `src/v2/periphery/FeeSplitter.sol` | 274 | the v8 fee sink: it receives the protocol's fees, converts non-USDG fees under an oracle ok-spot floor, and splits once between a buyback balance and the treasury. Holds real balances |
| `src/v2/periphery/PayoutRouter.sol` | 230 | one route to USDG per Stock Token, over Uniswap v3 or a pinned hookless v4 pool, with the route fee cached. Holds nothing between calls |
| `src/v2/periphery/V4BuybackExecutor.sol` | 679 | spends the splitter's buyback balance in the pinned STONKHOUSE pool and burns. Has no privileged function and no admin at all; the splitter is its only caller |
| `src/v2/periphery/StockZap.sol` | 193 | **the zap**: USDG → buy stock → deposit → post a covered-call ask in one call, and the reverse to exit. Stateless and role-less; the guardian's `clearRoute` is its kill switch |
| `src/v2/periphery/v4/V4UnlockCallback.sol`, `v4/V4Types.sol` | 61, 84 | the v4 unlock-callback base and the v4 type re-declarations the executor and the router use |
| `src/v2/periphery/BuybackDeps.sol`, `PayoutDeps.sol` | 107, 41 | hand-written interfaces to the v4 pool manager, the v3 router and factory, WETH and the pool's hook |
| `src/v2/periphery/UniV3PayoutAdapter.sol` | 205 | the **v7** adapter, superseded by `PayoutRouter` and **not migrated to the manager**. In scope only because it is still in the tree and still compiles; a v8 deploy does not create it. Confirm that for us |
| `src/v2/periphery/earn/EarnVault.sol` | 1582 | **the Earn vault**, added since this document first said it did not exist. It is the only real implementation of `IFundingSource` (`:108`) and is what the `take` funding seam calls. Its venue adapters are below |
| `src/v2/periphery/earn/adapters/Erc4626VenueAdapter.sol`, `adapters/StockVenueAdapter.sol` | — | the Earn vault's venue adapters |
| `src/v2/periphery/house/HouseVault.sol`, `house/HouseVaultFactory.sol` | 1356, 98 | **the House vault** and its factory, likewise added since §3.7 was written |

### 3.5 Market making — `src/v2/mm/`

| File | Lines | What it is |
|---|---:|---|
| `src/v2/mm/MakerVault.sol` | 881 | the protocol's own two-sided quoter, funded with treasury money. Price guards, size caps and the `maxDailyOutflow` leaky bucket |
| `src/v2/mm/MakerRegistry.sol` | 42 | per-maker rebate tiers, read once per fill under a gas cap |
| `src/v2/mm/RewardsDistributor.sol` | 212 | weekly Merkle roots and the USDG they pay (treasury money) |

### 3.6 The deploy path

`script/v2/` is in scope because the hand-over it performs is the access model. In particular
`DeployV8.s.sol` grants itself every working role, wires the set, grants the real holders, sets the
role tree and then renounces `ADMIN` **as the last call** — and `AccessManager._revokeRole` has no
last-admin guard, so an ordering mistake there bricks all sixteen contracts permanently.

| File | What to look at |
|---|---|
| `script/v2/DeployV8.s.sol` | the nine-step hand-over and its ordering rationale; the renounce guard; the post-check |
| `script/v2/lib/V2DeployBase.sol` | the `V2_*` environment, the launch values the registry does not hold, and the rent opt-in's `forge test`-only gate |
| `script/v2/RegisterMarkets.s.sol` | per-market preflight and the order of source configuration (pinning fails closed on a listed-but-unconfigured source) |
| `script/v2/VerifyV8.s.sol` | the post-deploy read-only check. `VerifyV2.s.sol` is **deleted**; this replaces it and is what the wrapper runs (`DeployV2Batch.sh:1310`, `:1318`) |
| `script/v2/DeployV2Batch.sh`, `batch-refusals.sh` | the wrapper and its refusals — **still v7-shaped at this commit, §11** |

### 3.7 Named in the engagement, and now written — re-scoped 2026-09-21

**Both landed. They are in scope and they are listed in §3.4.** This section previously said
neither the Earn vault nor the House vault existed, and offered
`grep -rn 'EarnVault\|HouseVault' src/ test/ script/` as proof that it "returns nothing". At this
commit that command returns **492 matches**. `T-530` re-derived it and corrected the section under
the instruction the old text gave for exactly this case.

- **Earn vault** — `src/v2/periphery/earn/EarnVault.sol` (1,582 lines), with
  `earn/adapters/Erc4626VenueAdapter.sol` and `earn/adapters/StockVenueAdapter.sol`.
- **House vault** — `src/v2/periphery/house/HouseVault.sol` (1,356 lines) and
  `house/HouseVaultFactory.sol` (98 lines).

The funding seam is still in scope and its description here was also stale: `EarnVault` **does**
implement `IFundingSource` (`src/v2/periphery/earn/EarnVault.sol:108`), so it is no longer true that
nothing implements it but a mock. `src/v2/mocks/MockFundingSource.sol:13` in fact declares that it is
deliberately **not** `is IFundingSource`, which is the opposite of what this section claimed.

**What this re-scoping does and does not say.** It says where to look. It makes no claim about
whether the code is correct — nobody has audited these two contracts, which is the point of putting
them back in scope.


---

## 4. Out of scope, with reasons

| Out of scope | Reason |
|---|---|
| **OpenZeppelin `AccessManager`, as code** | It is OpenZeppelin v5.7.0's, **unmodified**: no subclass, no wrapper, no dependency bump. `src/v2/access/V8AccessManagerArtifact.sol` is an 18-line import-only anchor that exists solely so solc emits an artifact for the deploy script to create from, and it declares nothing of its own on purpose. Audit our **configuration** of it (§3.3), not its code. A finding *about* OpenZeppelin belongs upstream — but a finding about how v8 *uses* it (the five-day `minSetback` on grant delays, the expiry of a scheduled operation, the special-casing of `setAuthority`) is in scope |
| **`src/v2/oracle/lib/FullMath.sol`** | Vendored verbatim from Uniswap v3-core branch `0.8` at commit `6562c52e8f75f0c10f9deaf44861847585fc8129`. Its header says every line but the comment block and two forgefmt markers is identical to upstream. Diff it against that URL rather than reading it; a diff that is **not** empty is a finding |
| **Uniswap v3 and v4 themselves** — the pools, the SwapRouter02, the PoolManager, the StateView lens, and the STONKHOUSE pool's hook | Third-party deployed code. What is in scope is our assumptions about them: the route-fee ceiling, the observation-ring requirement, the hook-fee ceiling, and every floor we set before a swap |
| **USDG**, the third-party stablecoin | Its issuer can pause, freeze and blocklist, and we do not control it. Its consequences for us are in scope and are written up in [V2-ARCHITECTURE §6.2](V2-ARCHITECTURE.md#62-usdg-issuer) |
| **The Stock Tokens**, third-party tokenised equities | Same: the issuer can freeze, pause and burn, and a shortfall is first come, first served. The consequences are in scope ([V2-ARCHITECTURE §6.1](V2-ARCHITECTURE.md#61-stock-token-issuer)) |
| **Chainlink feeds and the Data Streams verifier** | Third-party. Our staleness bounds, jump bounds, corroboration rule and delay are in scope |
| **The Gnosis Safe contracts** | The 2-of-3 Admin Safe and the Treasury Safe are Safe 1.3.0/1.4.1, verified on 4663 and unmodified. That all three Safe keys belong to one person is an accepted risk, not a bug ([SECURITY.md](../SECURITY.md), "Accepted risks") |
| **The v1 contracts** (`src/Vault.sol` and its adapters and libraries) | A separate system in run-off, scoped by [docs/AUDIT-SCOPE-V1.md](AUDIT-SCOPE-V1.md) and [docs/V1-RUNOFF.md](V1-RUNOFF.md) |
| **The live v7 deployment** | Frozen and run off ([docs/V7-RUNOFF.md](V7-RUNOFF.md)). v8 is a new set at new addresses; nothing migrates in place |
| **`src/v2/mocks/`** (13 files, ~2,000 lines) | Test doubles. They compile as part of `src/` rather than `test/`, which is itself worth one sentence of your report, but no deploy script creates one |
| **Off-chain code**: the keeper, the indexer, the web app, the monitor, the MM bot | All in stonkhousedotfun/callhouse. In scope only where a contract's safety **depends** on off-chain behaviour — and there is one such dependency that matters, the dapp's deadline rule (§6) |

**Not vendored, despite the name.** `src/v2/oracle/lib/TickMath.sol` is **first-party code** and is in
scope. It is a rewritten forward-only `getSqrtRatioAtTick` that uses the same magic factors as
Uniswap's TickMath but evaluates them in a `uint256[20]` loop with its own `TickOutOfRange()` error,
not a copy of upstream. It carries no vendoring header, and rewriting it is exactly why a later
checkout stopped reproducing the live v7 `UniV3TwapSource` bytecode
([docs/DEPLOY-V2.md](DEPLOY-V2.md), "Pinned deployed runtimes"). Read it as ours. Its only dedicated
test is `test/v2/unit/TickMath.t.sol`, 35 lines.

---

## 5. Properties to try to break

These are the claims the system makes. Each is asserted somewhere in `test/v2/`; the question is
whether the assertion is the same statement as the claim.

**Collateral and the ledger**

1. No role can move, freeze or seize a user's free collateral or tokens. `close`, `withdraw`,
   `redeem`, ERC-1155 transfers, order `cancel`, `prune` and `claimOwed` have **no pause** and no
   privileged gate.
2. Per asset: Σ free + Σ locked + accrued fees equals the Clearinghouse's token balance, which equals
   deposits minus withdrawals, payouts and sweeps. No rounding path breaks it.
3. Unsettled series: long supply equals short supply, and `locked` equals long supply × collateral per
   unit. Settled series: long + fee + short equals collateral per unit, and payouts and fees never
   exceed what the series held at settlement.
4. No call moves another account's wallet, ledger or tokens — except a take spending exactly the
   collateral of that account's filled write-on-fill asks, and a redemption, which only pays it.

**The book**

5. The book's USDG equals open bid escrow plus Σ `owed`, exactly. Its long tokens per id equal open
   resale escrow exactly, and it never holds a short.
6. Per take: rebates ≤ the taker fee, the fills add up to the take, and the book pays out exactly what
   it takes in. A delivery that reverts or runs out of gas **skips that fill**; it must never make the
   take pay for a fill that did not happen.
7. Mint on fill: `Clearinghouse.mint` reverts `NotMinter()` for anyone not on the allow-list, and at
   launch the OrderBook is the only minter — so **every long that exists was created inside a fill at
   a premium the protocol saw**. Find a route to a long that does not pay the first-sale fee, other
   than the self-trade the owner accepted.

**Settlement**

8. An expiry settles on the configuration **its first series pinned**, whatever configuration changed
   afterwards. A pin made outside a series creation can only *block* that expiry, never be settled on.
9. Pinning fails closed: while a listed source has no configuration for the underlying, or does not
   allow-list the oracle, no first series of any expiry can be created.
10. Over a live series, the only settlement lever left is `adminResolve` inside the band of the
    recorded prices from `E + 48 h`, or a factor of 1.25 around a lone vetoed price from `E + 7 days`.
    Find a way to settle outside that band.

**Access**

11. Every `restricted` selector has a row in `script/v2/roles.v8.json`. An unmapped `restricted`
    selector falls to `ADMIN` by default, which is a silent privilege escalation, and
    `test/v2/unit/AccessMatrix.t.sol` exists to catch exactly that. **Its target list is written out by
    hand, and it is short.** It probes eight contracts — ExpiryCalendar, MakerRegistry, Clearinghouse,
    PayoutRouter, FeeSplitter, AutoRoller, MakerVault, RewardsDistributor
    (`test/v2/unit/AccessMatrix.t.sol:84-91` and `:123-131`). Five `Managed` targets are **not** probed
    at all: `KeeperRewards`, `SettlementOracle`, `ChainlinkFeedSource`, `UniV3TwapSource` and
    `DataStreamsSource`. Start there.
12. Every entry point in the manifest's `unrestricted` block really is unrestricted, and each is safe
    that way — `Clearinghouse.mint` (allow-list, not a manager role, because the book's mint calls sit
    inside `try … {gas}`), `sweepFees`, `MakerVault.deposit`, `PayoutRouter.swapToUsdg`,
    `FeeSplitter.distribute`, `KeeperRewards.fund` and `reward`, `RewardsDistributor.claim`.
13. No EOA ends up holding roles 0-6. The deployer renounces `ADMIN` last, and the Admin Safe holds
    `ADMIN` at the manifest delay and has code before that renounce is allowed.
14. `GUARDIAN` can delay, never redirect: no guardian function touches a balance, and a guardian
    cannot cancel anything scheduled under `ADMIN`.

**The flywheel**

15. The splitter's buyback balance can only ever be spent buying STONKHOUSE to burn. No path pays it
    anywhere else, and no configuration change redirects it without the 24 h or 48 h lane it belongs
    to.
16. Every conversion the splitter or the router makes has a floor derived from an oracle reading that
    is ok and fresh, and the executor refuses a venue whose fees do not match what it was pinned
    against.

**Gas-capped external calls** — there are five of them, and every one is a reentrancy and
failure-isolation question: the maker registry read, the fee-discount module read, the just-in-time
`fund` / `fundable` pair, the payout conversion, and the ERC-1155 delivery to a contract recipient.

---

## 6. Areas of concern, ranked

Where we would look first, and why. This is where we think the code is weakest, not where we think it
is wrong.

1. **The role manifest against the bytecode.** The single highest-value read in this engagement. Two
   targets have not migrated (§11); the access-matrix test enumerates the targets it probes rather
   than discovering them, and five `Managed` contracts are outside its enumeration (§5, property 11);
   and a selector that nobody mapped is silently `ADMIN`'s. Read `script/v2/roles.v8.json` against
   every `restricted` function in `src/v2/`, in both directions.
2. **The deploy hand-over's ordering.** `DeployV8` grants itself roles at delay 0, wires, grants the
   real holders, then sets the role tree, then renounces — and the order matters because
   `AccessManager._getAdminRestrictions` routes `grantRole` through `getRoleAdmin`, so parenting
   `GUARDIAN` under `OPS_ADMIN` too early locks the deployer out of granting it. A resumed or
   partially-mined deploy is the interesting case.
3. **Mint on fill and the write-on-fill collateral reservation.** The book mints inside `try … {gas}`.
   A mint that fails silently becomes a skipped fill that `quoteTake` already promised. Look for a
   state in which the skip and the accounting disagree.
4. **The just-in-time funding hook.** An external call **inside matching**, gas-capped, in
   `try`/`catch`, under the book's reentrancy guard, with at most `MAX_FUNDED_MAKERS_PER_TAKE` makers
   funded per take. Nothing implements it yet, which means the mock is the only adversary it has met.
5. **The FeeSplitter's conversion floor and the executor's fee guard.** Both price a swap against an
   oracle and a declared fee, and both then measure afterwards. The gap between declared and measured
   is where a hostile pool lives.
6. **`adminResolve`'s band, and the veto that widens it.** The one place a privileged key can put a
   number into a settled series. The widening after seven days on a single vetoed price is the
   subtlest rule in the system.
7. **The per-expiry pin.** It is the answer to "can the admin re-price a live series", and it depends
   on a confirmation the Clearinghouse makes against each source's *current* configuration. Look for
   an ordering in which a pin confirms against something that has already moved.
8. **`MakerVault`'s outflow bucket.** A leaky bucket over a 1-day window, charged on the *net* USDG a
   quoter call moves out, with the v7 admin exemption removed in v8. Look for a call sequence that
   nets to zero per call and still drains.
9. **The dapp's deadline rule** — the one place a contract's safety depends on off-chain behaviour.
   `TakeParams.maxTotalFee` was added in v8 to remove that dependency and **is not enforced yet**
   (§11), so until it is, the only thing standing between a taker and a fee change is that the dapp
   caps every take's deadline at `effectiveAt - 1`.
10. **ERC-1155 delivery to contract recipients**, and makers that are contracts which stop accepting
    tokens. `owed` is the fallback; confirm it always is.

---

## 7. Trust model and accepted risks, by reference

Deliberately not restated here.

- **The threat model and every role's worst case:** [docs/V2-ARCHITECTURE.md §2](V2-ARCHITECTURE.md#2-trust-model),
  with §2.2 and §2.3 giving each privileged function its bound and its worst case, and §2.4 the values
  no role can change.
- **What is not protected:** [docs/V2-ARCHITECTURE.md §6](V2-ARCHITECTURE.md#6-what-is-not-protected)
  and the short form in [SECURITY.md, "Not protected"](../SECURITY.md#not-protected).
- **The risks the owner has accepted, and the operating rules the contracts rely on rather than
  enforce:** [SECURITY.md, "Accepted risks and the operating rules they rely on"](../SECURITY.md#accepted-risks-and-the-operating-rules-they-rely-on).
  Seven of them are the owner's own list from `v8-plan/00-MASTER-2026-09-19.md` §7, including the
  self-trade fee dodge, the absence of a daily buyback cap, a lending hook shipping in an immutable
  core before any borrowers, and all three Safe keys belonging to one person.

**An accepted risk is not out of scope.** If you think one of them is materially worse than the
sentence that accepts it — that the self-trade dodge is cheaper than "sophisticated writers only",
that the buyback cooldown does not do what the acceptance claims — say so. It was accepted on an
understanding, and the understanding is auditable.

---

## 8. What the tests do and do not prove

`test/v2/` is 98 Solidity files across `unit/`, `integration/`, `invariant/`, `fork/` and `lib/`. The
entry points worth opening first:

| File | What it is |
|---|---|
| `test/v2/unit/AccessMatrix.t.sol` | the v8 access-matrix test: reads `script/v2/roles.v8.json`, compares it with `V8Roles`, and walks each target's compiled ABI for a `restricted` selector the manifest does not name. **Its target list is written out by hand and covers eight of the thirteen `Managed` contracts** (§5, property 11) |
| `test/v2/lib/V8Access.sol` | the shared v8 access harness every access test inherits |
| `test/v2/unit/ManagedAccess.t.sol` | `src/v2/access/Managed.sol` itself: the `NotAuthorized` override, `setAuthority`, the delayed path |
| `test/v2/InterfaceIds.t.sol` | **the authoritative pin** for every selector, event topic and interface id. Trust it over any document, including this one |
| `test/v2/integration/Lifecycle.t.sol` | a weekly ladder of calls and puts, every balance checked against an independent model after every step |
| `test/v2/integration/PinnedSettlement.t.sol` | the per-expiry pin, including the hidden-pre-pin attacks |
| `test/v2/invariant/V2Invariant.t.sol` (+ its handler) | the invariants of §5, driven through oracle faults, reconfiguration, pauses and unauthorised attempts |
| `test/v2/fork/` | against live chain 4663: real feed history, real pools, the real SwapRouter02, the real Data Streams verifier, and the v4 buyback route |

**What they do not prove, and you should not assume:**

- **That they pass at this commit.** Under the owner's build-mode directive of 2026-09-19 the suites
  are written but are **not run as a condition of shipping**. Run them yourself; that is the first
  thing to do, and a failure is a finding. The launch verification pass that re-runs everything is
  tracked in `stonkhouse-plan/status/DEFERRED-VERIFICATION.md`, in the project plan folder beside this
  repository (not a repository of its own); ask for it if you do not have it.
- **That the numbers in the docs were measured recently.** Where a doc quotes a count, a gas figure or
  a check count, assume it is stale unless the doc says which run produced it.
- **That the published interface matches the implementation.** The interface log
  (`v8-plan/status/INTERFACE-CHANGES-V8.md`) published two selectors wrong in its first entry — `take`
  and `quoteTake` — and they were caught only because a second consumer derived them independently
  from the compiled ABI and disagreed. Its own correction entry says it: **re-derive every pin from
  the compiled artifact rather than trusting that file.** `test/v2/InterfaceIds.t.sol` is the pin.
- That the Admin Safe's signers are honest, that keepers show up, or how the real issuers, sequencer
  and feed operators behave beyond what the mocks and the fork model.

---

## 9. Build and run

```bash
git submodule update --init --recursive
forge build                                            # solc 0.8.28, via-IR, 200 runs, cancun
forge build --sizes                                    # exits 1 on v1's src/Vault.sol (25,775 B); v2 is unaffected
forge test                                             # the whole offline gate
forge test --match-path 'test/v2/**' -vv               # v2 only
forge test --match-contract AccessMatrix -vv           # the role manifest against the tree
forge test --match-contract InterfaceIdsTest -vv       # the selector, topic and constant pins
FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC -j 1   # the fork suites; the public RPC rate-limits parallel runs
forge fmt --check src/v2 script/v2 test/v2
```

`RH_RPC=https://rpc.mainnet.chain.robinhood.com`. Chain 4663 has a 98,304 B code limit, so an anvil
fork needs `--code-size-limit 98304`; every v2 contract is nonetheless under EIP-170's 24,576 B.

The deploy path is exercised without a chain by
`forge test --match-path 'test/v2/unit/Deploy*' --match-path 'test/v2/unit/Verify*'` and by
`script/v2/batch-refusals.sh`, which runs every wrapper refusal against an unreachable RPC.

---

## 10. Reporting a finding

Send it to **security@stonkhouse.fun** (also published at
`https://stonkhouse.fun/.well-known/security.txt`). Do not open a public issue. There is no bug
bounty today; owner decision V3-D33 puts one at $1 M TVL.

What makes a finding actionable here:

- **The account that loses, and what it loses.** "A role can do X" is in [SECURITY.md](../SECURITY.md)
  already if X is bounded; what we want is the bound being wrong or absent.
- **A sequence, against the code.** A `forge` test that fails on `src/v2` as it stands is worth more
  than any prose. `test/v2/` has a fixture for every contract.
- **Which file and line**, and which of §5's properties it breaks, if any.
- **Where this document is wrong.** It was written against the tree at one commit by someone who did
  not write the contracts. A paragraph here that no longer matches `src/v2` is a P3, and we want it.

---

## 11. Appendix: what is half-landed at this commit

v8 is being built task by task and this tree is a snapshot part-way through. These are the places
where the target state and the code disagree **that we already know about**. They are listed so you do
not spend the engagement rediscovering them — and so that anything you find which is *not* on this
list is genuinely new.

| # | What | Where | Owner |
|---|---|---|---|
| 1 | **`OrderBook` has not migrated to the manager.** All five of its setters still carry v7's `onlyRole(DEFAULT_ADMIN_ROLE)`. `DeployV8` works around it by passing the AccessManager itself as the book's `admin`, so no EOA holds the role and the book's wiring goes through `manager.execute` | `src/v2/OrderBook.sol:573,587,597,626,637` | `C8-03`, `C8-13` |
| 2 | **`UniV3PayoutAdapter` never migrates.** It keeps `onlyRole(V2Constants.DEFAULT_ADMIN_ROLE)` because `PayoutRouter` replaces it and no v8 deploy creates it | `src/v2/periphery/UniV3PayoutAdapter.sol:111` | superseded |
| 3 | **The four v7 `bytes32` role constants still exist**, solely for 1 and 2. Nothing v8 reads them | `src/v2/interfaces/V2Constants.sol:175-182` | deleted with 1 |
| 4 | **`TakeParams.maxTotalFee` is declared and NOT enforced.** The field is in the tuple and `V2Errors.FeeAboveMax(fee, max)` exists, and `IOrderBook` documents the revert — but `OrderBook.take` never reads the field. `quoteTake` likewise answers `sellerFees = 0` for a selling quote by its own admission, so a selling caller must pass `type(uint128).max` | `src/v2/interfaces/V2Types.sol:101`, `src/v2/interfaces/V2Errors.sol:81-84`, `src/v2/interfaces/IOrderBook.sol:122-137`, `src/v2/OrderBook.sol:421-456,463-467` | `C8-03` |
| 5 | **RESOLVED — `VerifyV8` exists and `VerifyV2.s.sol` is deleted.** This row previously read "No `VerifyV8` exists"; `T-585` corrected it on 2026-09-21 after finding the file in the tree. `script/v2/VerifyV8.s.sol` is the live verifier, it is what `DeployV2Batch.sh` invokes (`:1310`, `:1318`), and it no longer carries the two rules v8 inverts — its own header records that INTERFACE_VERSION 8 **deleted** the `premiumFeeBps <= resaleFeeBps` check (`VerifyV8.s.sol:89`). Nothing here is still open | `script/v2/VerifyV8.s.sol:89` | resolved |
| 6 | **RESOLVED — the wrapper is v8.** This row previously read that `DeployV2Batch.sh` calls the deleted `script/v2/DeployV2.s.sol` at six sites and still pins `INTERFACE_VERSION=7`; `T-585` corrected it on 2026-09-21 by grepping the file. It holds **zero** references to `DeployV2.s.sol`, pins `INTERFACE_VERSION=8` (`:122`) and drives `DeployV8.s.sol`, `RegisterMarkets.s.sol` and `VerifyV8.s.sol`. What is NOT yet proven is the v4 environment: `V2_V4_POOL_MANAGER` and `V2_V4_STATE_VIEW` are exported but resolve to EMPTY against `v2-sources.json`, which `script/v2/launch-path-smoke.sh` reports as its two remaining FAILs and which is owner-gated | `script/v2/DeployV2Batch.sh:122` | partly resolved |
| 7 | **The Earn vault and the House vault now EXIST and are in scope** (§3.4). This row previously said they did not; `T-530` corrected it on 2026-09-21 together with §3.7 | `src/v2/periphery/earn/EarnVault.sol`, `src/v2/periphery/house/HouseVault.sol` | re-scoped, not audited |
| 8 | **`FeeSplitter.setOracle` and `setToken` are implemented but absent from `IFeeSplitter`**, so they are absent from the published ABI — although the role manifest maps both to `TREASURY_ADMIN`. Eight of the splitter's ten setters are in the interface; these two are not. The interface log records that the freeze entry for them was never written | `src/v2/periphery/FeeSplitter.sol:203,211` against `src/v2/interfaces/IFeeSplitter.sol:60-96` | `C8-07` follow-up |
| 9 | **The interface log's first entry published two wrong selectors** (`take`, `quoteTake`) and was corrected in place. Any consumer that copied it before the correction is wrong. Re-derive from the compiled artifact | `v8-plan/status/INTERFACE-CHANGES-V8.md`, Entries 1-3 | — |

Items 1-6 mean one thing for this engagement: **read `src/v2` and `script/v2/roles.v8.json` as the
system, and read the deploy wrapper and the verifier as work in progress.** The hand-over that
`DeployV8.s.sol` performs is real and complete; the wrapper around it is not.
