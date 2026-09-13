# Accounting

The subtlest part of Callhouse. Read this before changing anything under `src/`.

> **Paths.** Paths resolve from the root of this repository, leekzor/callhouse-contracts. A path
> followed by (leekzor/callhouse) lives in the app repository (keeper, indexer, web, ops and the
> project-wide docs), which mounts this repository as a git submodule at `contracts/`, and
> resolves from that repository's root.

Everything here is enforced by tests in `test/`; where a rule has a test, the test is
named so you can go read it.

---

## 1. Two ledgers, deliberately separate

The vault runs **two independent ledgers** and never mixes them.

| Ledger | Unit | Who owns it | How it moves |
|---|---|---|---|
| Collateral | NVDA Stock Token, 18 dp | shares, pro rata | deposit, redeem, write, assignment |
| Premium | USDG, 6 dp | an accrual index | filled listings, assignment proceeds |

`totalAssets()` counts **only** the collateral:

```
totalAssets() = asset.balanceOf(vault) - reservedAssets + lockedAssets()
```

USDG is **not** in the share price. It accrues through `accUsdgPerShare` and is claimed separately
with `claimUsdg()`.

### Why they are separate

Folding premium into the share price would make the price jump the instant a buyer fills. That is
the same dishonesty as marking the short call to market, just later in the week. The product
promises "last week's realized USDG is the only number that matters", and a share price that moves
on unrealised premium quietly breaks that promise.

It also keeps an oracle out of the money path. Nothing in `redeem`, `rollClose`, `harvest` or the
redeem queue reads a price. The feed is a write-gate and a display value, nothing more.

**Consequence you must remember:** the share price only ever moves when the *asset* balance moves.
A filled week does not raise the share price. An assigned week *lowers* it, because collateral left
and the strike proceeds went to the USDG ledger instead.

---

## 2. Units, stated once

| Quantity | Unit | Example |
|---|---|---|
| `assets`, `idleAssets()`, `lockedAssets()`, `reservedAssets` | asset base units, 18 dp | `1e18` = 1.0000 NVDA |
| shares (`cNVDA`) | 18 dp | 1 share = 1 NVDA at launch |
| `spotUsdg`, `strikeUsdg`, every premium | USDG base units, 6 dp | `226_000_000` = $226.00 |
| `contracts` | whole lots | 1 contract covers exactly `lotSize` = `1e18` of asset; a write (`rollOpen` or `writeMore`) refuses a cycle with any other lot |
| every `*Bps` | basis points | `300` = 3% |
| `accUsdgPerShare` | USDG per share, scaled `1e27` | see §4 |

Valorem is the one place that breaks the pattern: `Claim.amountWritten` and
`Claim.amountExercised` are **1e18-scaled scalars**, not contract counts. `contractsAssigned()`
divides them back down. Getting this wrong reports a 10-contract assignment as
`10_000_000_000_000_000_000`.

### Contracts across tranches

A week can be written in more than one tranche: `rollOpen` opens the Valorem claim and
`writeMore(n)` adds `n` contracts to that same claim while the vault is `Listed` and before
`cycleExerciseTs`. There is still exactly one claim per week, so:

| Quantity | What it counts after tranches |
|---|---|
| `contractsWritten` | the running total of every tranche written into this week's claim; zeroed by `rollClose` |
| `CallsWritten(optionId, claimKey, contractsCount, collateral)` | **one tranche**: that write's count and that write's collateral, never the running total. Sum them per `claimKey` |
| `RollOpen.contractsCount` | the opening tranche only. The week's size is `contractsWritten`, or the sum of its `CallsWritten` |
| `lockedAssets()`, `claimedExerciseProceeds()`, `contractsAssigned()` | read `clear.position(claimKey)` / `clear.claim(claimKey)`, which upstream sums over every claim index (one per bucket written into), so they already cover every tranche |
| `contractsRemaining()`, `contractsSold()` | live `clear.balanceOf(vault, optionId)` against `contractsWritten`; a tranche raises both the balance and the total |

Sizing is on the total: a write passes only if `contractsWritten + n` is within
`maxContractsCap` and within `maxUtilizationBps` of `idleAssets() + lockedAssets()`. Before the
first write that is just idle, which is what `rollOpen` always measured; checking each tranche
against idle alone would let repeated tranches creep towards 100%. A tranche moves asset from
idle into Valorem one for one, so it never moves `totalAssets()` or the share price, except by the
Valorem engine fee when governance has accepted it (15 bps of the tranche's notional, charged on
every tranche as on the opening write).

---

## 3. The share price

Standard ERC-4626 with virtual offsets:

```
shares = assets * (totalSupply + 1) / (totalAssets + 1)
assets = shares * (totalAssets + 1) / (totalSupply + 1)
```

Rounding always favours the vault: deposits floor the shares minted, mints ceil the assets taken,
redemptions floor the assets paid. A caller can never round their way to more than they put in.

**Previews never lie.** `previewRedeem` and `previewWithdraw` return `0` whenever the queue is the
only path, rather than quoting an instant amount the caller cannot get. `maxDeposit` returns `0` in
any phase where `deposit` would revert. This is a deliberate departure from the naive ERC-4626
reading, and it is what an integrator sizing a "max" button needs.

---

## 4. The premium index

`Distributor` uses the standard index pattern with the settle moved into `_update`, so it is
correct across transfers, mints and burns without any caller discipline.

```
on distribution of `pot`:
    indexDelta        = pot * 1e27 / totalSupply
    accUsdgPerShare  += indexDelta
    usdgDust         += pot - (indexDelta * totalSupply / 1e27)

an account's pending:
    (balanceOf(account) * (accUsdgPerShare - snapshot[account])) / 1e27
```

`1e27` rather than `1e18` because USDG has only 6 decimals: at `1e18` a small weekly premium against
a large share supply would round to zero per share.

### The drift, and why it is fine

The index floors **once per distribution**. An account's pending floors **once over the combined
delta** since it last settled. Because

```
floor(b*(d1+d2)/A)  >=  floor(b*d1/A) + floor(b*d2/A)
```

the sum of what everyone can claim can sit a few base units above the sum of what was recorded as
distributed. This is inherent to an index, not a bug.

It used to be a very bad bug anyway, because `usdgOwed()` was a raw subtraction that underflowed
once lifetime claims passed lifetime credits, which permanently bricked `deposit`, `mint` and
`rollClose`; and because `_settleQueue` reserved straight out of the index, a one-base-unit
shortfall could strand a redeemer's entire principal. Both are fixed:

- **Accounting is anchored on a measured balance**, `usdgAccounted`, not on an arithmetic identity.
  New premium is `usdg.balanceOf(vault) - usdgAccounted`. Every outflow calls `_debitUsdgOut`.
- **Every payout is clamped** to `_usdgAvailableForHolders()`, which is the balance less
  `usdgReservedForQueue` and `pendingFeeUsdg`.
- `usdgOwed()` saturates and is informational only. Nothing in the money path reads it.

Net effect: the drift costs at most a few base units of unclaimed dust to the last claimant. It can
never strand principal or brick a roll. See `test_accrualDriftCostsDustAndNothingElse` and
`test_settledRedeemerIsAlwaysPayable`.

### The deposit checkpoint

`deposit` and `mint` call `_checkpointHarvest()` **before** minting. Without it, a premium that
landed on Tuesday would be distributed at Saturday's `rollClose` across a share supply that grew on
Friday, so anyone could deposit just before the close and take a cut of premium earned entirely by
other people's collateral, with no assignment risk.

Two consequences to hold in mind:

1. A filled week can emit **more than one `Harvest` event**. The indexer must sum them per cycle,
   not treat the last one as the week's result.
2. The protocol fee from a checkpoint accrues into `pendingFeeUsdg` rather than transferring, so
   the checkpoint makes no external call. It is pushed once, best-effort, inside `rollClose` — and
   if the recipient cannot receive, anyone can complete it later with `sweepFee()` (see §6).

The deposit gate itself closes on the cycle's exercise **timestamp**, not on the phase: after it,
`deposit`/`mint` revert `DepositsClosedForCycle` and the previews return 0. The reason is
assignment — Valorem takes collateral with no callback, so NAV collapses mid-transaction while
the strike proceeds sit in the claim, and minting against that gap was the one critical finding
of the 2026-09-12 review. The checkpoint above is the companion rule for the premium side of the
same week.

### Depositing while a call is open

A deposit in `Listed` (allowed until `cycleExerciseTs`) buys into a book that is already short
this week's call. Stated plainly, because an earlier NatSpec on `deposit` said the opposite:

- **The price ignores the short.** Shares are minted at `totalAssets()`, which values the written
  call at zero (§1). A late depositor pays the same NAV per share as if no call were open.
- **Assignment reaches every share.** If the week ends assigned, collateral leaves at the strike
  and the share price falls for all holders, the late shares included; the strike proceeds are
  credited through the index to everyone holding shares at `rollClose`, the late holder included.
  There is no per-depositor tracking of whose collateral was written.
- **Late money can be written against directly.** `writeMore` sizes on idle plus locked, so a
  tranche written after the deposit can lock the depositor's own stock
  (`test_writeMore_sizesOnTheTotalAndCountsLateDeposits`).
- **Premium already indexed is not theirs.** The checkpoint inside their deposit fixes every fill
  before it into the index; fills after it are shared, including fills of tranches written before
  they arrived.
- **They cannot leave instantly.** Until the week closes the only exit is the queue, which settles
  at `rollClose`.

Worked through to the base unit in
`test_lateDepositorDuringListed_sharesTheAssignmentThroughTheSharePrice` (`VaultAssignment.t.sol`).
The window shuts at `cycleExerciseTs` because nothing can be assigned before it, so the NAV a late
depositor pays is never already marked down by an assignment whose strike proceeds are still in
the claim. The web deposit form warns in `Listed`, and more strongly once live spot is at or above
`strike × (1 − minOtmBps)`.

---

## 5. The redeem queue

Instant `redeem`/`withdraw` work only while the vault is flat (`phase == Idle && contractsWritten
== 0`). Otherwise, and whenever a holder chooses to, redemptions are queued: `queueRedeem` is
allowed in every phase. The mechanics:

```
queueRedeem(shares)      shares move into ESCROW on the vault.
                         The owner's free balance is simply balanceOf; there is no separate lock.
                         Their USDG is settled first, so they keep everything already earned.
  debt[owner] += shares * accUsdgPerShare          the index these shares enter escrow at
                                                   (summed if the owner queues again in the epoch)

_settleQueue()           runs inside rollClose, AFTER the harvest, or from the permissionless
                         settleQueue() while Idle, AFTER a harvest checkpoint (below).
  escrowUsdg  = the escrow's own accrual over the cycle  (belongs to the queuers, not the stayers)
  epochIndex[epochId] = accUsdgPerShare            the index the epoch closed at
  payoutAsset = queuedShares * (idleAssets() + 1) / (totalSupply + 1)
                 the instant-redeem price, virtual share included. Without the +1/+1 a
                 flat settleQueue exit would pay the attacker of a donation inflation more
                 than instant redeem does and make the grief profitable
  burn the escrowed shares
  record Epoch{sharesRemaining, assetsRemaining, usdgRemaining}
  reservedAssets += payoutAsset ;  usdgReservedForQueue += escrowUsdg

completeRedeem(to)       settles the owner's entry out of their epoch (below) and pays it.
```

`debt` is the private `_queueAccDebt`, `epochIndex` the private `_epochAccUsdgPerShare`. Neither is
in the public ABI.

### Settling while flat: `settleQueue()`

The queue used to settle only inside `rollClose`, which needs a `rollOpen` first. A queue made
while `Idle` therefore waited for a write that might never come: a halt nobody lifts, a registry
lot other than one token, an unaccepted Valorem fee, a stale or paused oracle, or less than one lot
idle (the last holder with half a token). Holders who had not queued could still redeem instantly.

```
settleQueue()            anyone; reverts WrongPhase unless phase == Idle, NothingQueued if queuedShares == 0
  _checkpointHarvest()   USDG that arrived since the last close is indexed first, so the escrow's
                         accrual on it goes to the queuers and not to the stayers
  _settleQueue()         exactly as above
```

While `Idle` the vault holds no claim, so `idleAssets()` is `totalAssets()` and
`payoutAsset = q × (totalAssets() + 1) / (totalSupply + 1)` is to the base unit what `redeem(q)`
would pay at that moment (`test_settleQueue_paysWhatAnInstantRedeemWouldHave`). Nothing moves: the
shares are burnt, the payout is reserved, and `completeRedeem` pays it as for any epoch, so it
works while halted and under an issuer freeze (`test_settleQueue_worksUnderAnIssuerFreeze`).

The +1/+1 in `payoutAsset` is load-bearing here. The first draft paid `idleAssets() × q /
totalSupply` with no virtual share, which is more than the instant price whenever `idle > supply`.
Once the settlement was atomic and permissionless, that turned first-depositor inflation back into a
profit: seed 3 wei, donate 20 NVDA, let a 9.8 NVDA deposit round down to one share, then queue and
settle out with 22.35 NVDA for 20 NVDA + 3 wei. Priced with the offset, the same exit pays 17.88
(`test_settleQueue_doesNotMakeDonationInflationProfitable`).

A queue made while a call is open still settles at `rollClose`: `settleQueue` refuses `Listed` and
`Exercisable`. The asset leg is priced on `idleAssets()`, which is the whole NAV only when nothing
is locked in Valorem.

### What each entry is paid

An entry is settled out of its epoch by `_settleEpochEntry`, reached from `completeRedeem` or from
`queueRedeem` flushing a stale slot (below). `previewCompleteRedeem` computes the same two figures
through the same `_entryUsdg`, so the preview is what the payout will be.

```
_settleEpochEntry(owner)
  assets  = ep.assetsRemaining * shares / ep.sharesRemaining                          pro rata
  usdgOut = shares == ep.sharesRemaining
              ? ep.usdgRemaining                                          last claimant: the rest
              : min( (shares * epochIndex[e] - debt[owner]) / 1e27 ,  ep.usdgRemaining )
  debt[owner] = 0
  ep.assetsRemaining -= assets ; ep.usdgRemaining -= usdgOut ; ep.sharesRemaining -= shares
  owedAssets[owner] += assets  ; owedQueueUsdg[owner] += usdgOut
```

**Why the two legs are split differently.** The asset leg is a snapshot: `payoutAsset` is fixed at
settlement from `idleAssets()` and the supply at that moment, and every escrowed share has the same claim on it
however long it sat in escrow, so dividing by shares is exact. The USDG leg is not a snapshot. The
escrow is one account holding everyone's queued shares, and its accrual grows tranche by tranche,
each time premium is indexed (every deposit or mint checkpoint, and the harvest at the close), on
whatever the escrow held at that moment. Shares that entered escrow after a tranche was indexed did
not earn it. `shares * epochIndex - debt` is exactly the index growth over the entry's own time in
escrow, which is what those shares would have accrued as an ordinary balance. What they earned
before queueing was already settled to the owner's `claimableUsdg` by `queueRedeem`.

**Rounding, the cap and the last claimant.** Each entry's figure floors once over its own growth;
the escrow's pot floors once per change in the escrow's balance, which happens at each `queueRedeem`.
So the pot and the sum of the entries' floors can differ by a few base units either way. When the
floors add up to more than the pot, `min(…, ep.usdgRemaining)` stops an entry from taking what is not
there, and an entry that claims after the others have taken their full floors can be short of its own
by those units. When they add up to less, the **last claimant** (whoever settles last in the epoch,
in claim order, not queue order; the one whose `shares == ep.sharesRemaining`) takes
`ep.usdgRemaining`, which absorbs every earlier floor. Either way the epoch pays out its pot to the
base unit and never more. When the pot is exactly the escrow's accrual over the entries' shares, the
last claimant's figure differs from its own index growth by fewer base units than there were
`queueRedeem` calls into the epoch. Three things break that equality, and the difference lands on
the last claims (a surplus entirely on the last claimant; a shortfall on it first, then on the
claims just before it): the `_takeAccrued` clamp to `_usdgAvailableForHolders()` binding at
settlement (the pot is smaller); a residual left in the escrow's accrual by that clamp at an earlier
settlement (larger); and the accrual of shares transferred straight to the vault address, which
have no debt entry (larger).

### Zero dust, by construction

Each epoch tracks *remaining* shares, assets and USDG, and every claimant is paid out of what is
**left**. The final claimant has `shares == ep.sharesRemaining` and receives exactly the remainder
of both legs, so nothing is stranded. Asserted with deliberately awkward amounts in
`test_zeroDust_threeAwkwardClaimantsLeaveNothingBehind`, and with the per-entry USDG figures derived
by hand in `test_twoQueuedRedeemersThroughAnAssignedWeek_leaveZeroDust`.

### Worked example: an earlier queuer keeps her tranche

From `test_earlierQueuerKeepsTheTrancheOnlyHerSharesEarned`. Alice and bob deposit 10 NVDA each; 10
contracts are written and filled, and 19.00 USDG reaches the vault, not yet indexed.

```
alice queues 5e18                 debt[alice] = 5e18 * 0 = 0            escrow holds 5e18
carol deposits 10e18              checkpoint: gross 19_000_000, fee 950_000, net 18_050_000
                                  indexed over 20e18 supply: index 902_500e9
                                    escrow (alice's 5e18)          4_512_500
                                    alice's unqueued 5e18          4_512_500   claimableUsdg
                                    bob's 10e18                    9_025_000   claimableUsdg
bob queues 10e18                  debt[bob] = 10e18 * 902_500e9           escrow holds 15e18
rollClose, out of the money       nothing more indexed; epoch pot 4_512_500, epochIndex 902_500e9

bob settles first                 (10e18 * 902_500e9 - 10e18 * 902_500e9) / 1e27 = 0
alice settles last                takes ep.usdgRemaining = 4_512_500
                                  (her own figure: 5e18 * 902_500e9 / 1e27 = 4_512_500)
every unit                        4_512_500 + 0 + 4_512_500 + 9_025_000 = 18_050_000
```

The assets split pro rata as before: the 15 NVDA settled for the epoch are 5 for alice and 10 for bob.
Split pro rata by final shares, as the vault did before this repository's `6ed528f`, the same pot
gave alice 1_504_166 and bob about 3_008_333: two thirds of it to shares that were not in escrow
when it was indexed.
The deliberate form, a newcomer depositing 30e18 after a fill (her own deposit being the checkpoint)
and queueing all of it, took 6_768_750 of the 9_025_000 an earlier queuer's 10e18 had earned; it now
takes 0 (`test_depositThenQueueTakesNoneOfAnEarlierQueuersPremium`). Found 2026-09-13 while writing
this documentation; the other regressions are
`test_trancheIndexedBetweenEntriesStaysWithTheEntryItAccruedTo` and the fuzz
`testFuzz_eachEntryIsPaidItsOwnIndexGrowth`, all in `test/unit/VaultQueueFairness.t.sol`.

### Settling is not paying

There is one queue slot per account, so queueing again after an epoch settled has to flush the old
one. That flush **parks** the position into `owedAssets` / `owedQueueUsdg`; it moves no tokens.

That is not an optimisation. Paying out means touching the Stock Token, and the issuer can freeze
transfers. If the flush paid out, a holder carrying an uncollected epoch could not queue at all
during a freeze — which would break the promise that a halt or a freeze never traps a depositor.
Only `completeRedeem` touches tokens, and that is the one leg a freeze is allowed to stop. See
`test_issuerFreezeDoesNotBlockQueueingForAStaleSlotHolder`.

The flush emits **`QueueEntrySettled`** (from both settle paths — the flush and
`completeRedeem` itself), because it changes who the epoch still owes without moving a token.
`CompleteRedeem` only ever reports the payout. Off-chain readers must draw epochs down on the
first event and reserves on the second; watching only `CompleteRedeem` misreads both.

### Fairness

Queued shares keep earning premium right up to settlement, and that accrual is paid out **with the
redemption** rather than left to the holders who stayed. Each entry is paid only what was indexed
while its own shares sat in escrow, never a slice of what earlier entries earned before it arrived
(above). After an assigned week the queue collects a **mix** of leftover NVDA and strike USDG —
never a guarantee of the token back.

`reservedAssets` and `usdgReservedForQueue` are excluded from NAV, so a settled-but-uncollected
redeemer neither dilutes nor is diluted by anyone else.

---

## 6. Fees

Two fees stack, and both are on the premium only.

| Fee | Rate | Mechanism | When |
|---|---|---|---|
| Overcall | 5% of gross premium | the second Seaport consideration item, in the same fill | only on a fill |
| Callhouse | 5% of the premium that reaches the vault (`protocolFeeBps` 500; bytecode ceiling 2000) | `pendingFeeUsdg`, pushed best-effort at `rollClose` | only when harvested premium is positive |

Stacked, that is 9.75% of gross premium: Overcall's 5% of gross, then 5% of the 95% that reaches
the vault. No fee on deposits. No fee on idle collateral. **An unfilled week harvests zero and is
therefore free** — `Policy.splitHarvest` returns `(0, 0)` on a zero amount.

### Strike proceeds are credited fee-free

On an assigned week `rollClose` redeems the Valorem claim and the strike USDG lands in the vault
alongside the premium. The harvest still measures everything new (`balance - usdgAccounted`) and
credits **all** of it, less the fee, to `accUsdgPerShare`. The fee is charged only on the part
that is not strike proceeds:

```
gross = usdg.balanceOf(vault) - usdgAccounted
fee   = floor((gross - usdgFromAssignment) * protocolFeeBps / 10_000)   (saturating at 0)
net   = gross - fee                                                    all of it to the index
```

`usdgFromAssignment` is the USDG the claim redemption actually delivered, measured in the same
`rollClose`. The deposit checkpoint passes `0`, which is correct rather than lenient: strike
proceeds sit inside the claim until `rollClose` redeems it, so none can be in the balance when a
deposit runs. The reason for the exclusion: strike proceeds are the assigned depositors' own
collateral, sold at the strike, not income. A fee on them would be a cut of principal — at the
old 10%-of-everything rate, an assigned week took more than a hundred times the fee on the
premium it was meant to be a cut of.

**Reconciling `Harvest` on an assigned week.** The event ABI did not change, so
`Harvest.grossUsdg` on the close still **includes** the strike proceeds and `feeUsdg / grossUsdg`
is not the fee rate. Take `usdgFromAssignment` from the `RollClose` event in the same transaction
(it is emitted immediately before the close's `Harvest`) and check
`feeUsdg == floor((grossUsdg - usdgFromAssignment) * protocolFeeBps / 10_000)`. On a checkpoint
`Harvest`, and on any close with `usdgFromAssignment == 0`, that reduces to
`feeUsdg == floor(grossUsdg * protocolFeeBps / 10_000)`.

### The push is best-effort, on purpose

`rollClose` is the only function that redeems the claim, clears `contractsWritten` and settles
the redeem queue. A hard fee transfer inside it would let a blocklisted fee recipient, a paused
USDG, or a recipient that reverts on receive freeze every unit of collateral and every future
cycle — a stablecoin-side problem taking the product offline over a fee that harms only us. So
the push cannot revert the close: on failure the fee simply stays in `pendingFeeUsdg`, and
`sweepFee()` is the permissionless recovery. It always pays the stored `feeRecipient`, never the
caller, and it reverts rather than burn the fee while the recipient still cannot receive. See
`test_medium_blockedFeeRecipientDoesNotFreezeTheVault`.

### Overcall's rounding is load-bearing

```
feePerContract    = floor(unitPrice * 500 / 10_000)
writerPerContract = unitPrice - feePerContract
consideration[1]  = feePerContract    * contracts
consideration[0]  = writerPerContract * contracts
```

Round **per contract, then multiply**. Rounding on the total produces an order that signs, validates
and then cannot be partially filled — Seaport rejects the fraction with `InexactFraction`. Since
every Overcall listing is `PARTIAL_OPEN`, that silently makes the listing full-fill-only, and a
listing a buyer's UI cannot fill is an unfilled week.

Both the contract (`Policy.splitPremium`) and the keeper (`keeper/src/seaport.ts` (leekzor/callhouse)) implement this,
and `SplitDiff.t.sol` is a differential test that keeps them in agreement.

There is also a floor: a unit price below **20 USDG base units** floors the 5% to zero, and
Overcall's schema rejects a zero-amount consideration item. `Policy.minListableUnitPrice()`.

---

## 7. The invariants

Asserted after every call of the stateful suite, `test/invariant/VaultInvariant.t.sol` (64 runs ×
600 calls in the default profile). There are **eight** `invariant_*` functions; USDG solvency is
split into an aggregate half and a per-holder half. Formulas below are what the code asserts, not a
paraphrase of intent.

```
1. asset conservation                                  invariant_assetConservation
   deposited >= withdrawn + assignedOut
   asset.balanceOf(vault) + lockedAssets()  ==  deposited - withdrawn - assignedOut
   (ghosts built from what callers asked for and what the vault returned, never from its balance)

2. USDG books balance (aggregate)                      invariant_usdgBooksBalance
   usdgOwed() + usdgReservedForQueue + usdgDust + usdgUnallocated + pendingFeeUsdg
       <=  usdg.balanceOf(vault) + maxIndexRoundingDrift
   usdgAccounted <= usdg.balanceOf(vault)                                   (no allowance)
   usdgReservedForQueue == sum(epoch.usdgRemaining) + sum(owedQueueUsdg)    (no allowance)

3. USDG holder solvency (per holder)                   invariant_usdgHolderSolvency
   sum(claimableUsdg) + usdgReservedForQueue + usdgDust + usdgUnallocated + pendingFeeUsdg
       <=  usdg.balanceOf(vault) + maxIndexRoundingDrift

4. share accounting                                    invariant_shareAccounting
   totalSupply() == sum of holder balances (escrow at the vault included)
   balanceOf(optionBuyer) == 0
   queuedShares == balanceOf(vault)

5. no free shares                                      invariant_noFreeShares
   totalSupply() > 0  =>  convertToAssets(totalSupply()) <= totalAssets()
   sum(convertToAssets(holder balance)) + reservedAssets  <=  asset.balanceOf(vault) + lockedAssets()

6. reserves are real                                   invariant_reservesAreReal
   reservedAssets <= asset.balanceOf(vault)
   usdgReservedForQueue <= usdg.balanceOf(vault)
   usdgReservedForQueue + pendingFeeUsdg <= usdg.balanceOf(vault)
   reservedAssets == sum(epoch.assetsRemaining) + sum(owedAssets)
   contractsAssigned() <= contractsWritten
   lockedAssets() == (contractsWritten - contractsAssigned()) * 1e18

7. phase sanity                                        invariant_phaseSanity
   contractsWritten > 0  =>  phase != Idle
   phase == Idle         =>  claimKey == 0, lockedAssets() == 0, canRedeemInstantly()
   phase != Settling     (Settling is entered and left inside one rollClose)

8. the fee never touches strike proceeds               invariant_feeNeverTouchesStrikeProceeds
   protocolFeeBps == Policy.launchDefaults().protocolFeeBps   (one rate per run; pinned)
   (usdg.balanceOf(feeRecipient) + pendingFeeUsdg) * 10_000  <=  premiumToVault * protocolFeeBps
   (premiumToVault is a ghost measured as the vault's USDG balance change on every successful fill)
```

`maxIndexRoundingDrift` is not slack. The index floors once per distribution while an account's
pending accrual floors once over its combined delta, so holders can be promised a base unit per
account per distribution more than was credited (§4). The handler bounds that exactly, and the run
is refused if it ever reaches a dollar. The queue reserve and the pending fee are asserted with no
allowance at all (invariant 6), because they are the obligations that must be backed to the unit.

With `rollClose` passing 0 instead of the claim redemption to the harvest (the pre-2026-09-13 fee
rule, §6), invariant 8 failed with a counterexample that shrinks to seven calls: mint shares, roll open
(3 contracts), approve a listing, fill, exercise 1, warp, roll close.

**Tranches, flat settlement and stale-listing kills (2026-09-13 second pass).** The handler now
registers 20 actions; the three new ones are `writeMore`, `settleQueue` and
`invalidateStaleListing`. No formula above changed: invariant 6's `lockedAssets() ==
(contractsWritten − contractsAssigned()) × 1e18` holds with `contractsWritten` as the running total
of a multi-tranche claim, and invariant 7 still requires `Idle ⇒ claimKey == 0`, which is why
`settleQueue` may only run in `Idle`. What the new actions add is asserted inline on every
successful call, not by a new `invariant_*` function:

```
writeMore(n)             claimKey unchanged; contractsWritten == before + n; totalAssets() unchanged
settleQueue()            epoch.sharesRemaining == queuedShares before
                         epoch.assetsRemaining == q * (idleAssets() + 1) / (totalSupply + 1)   (before)
                         queuedShares == 0; asset.balanceOf(vault) unchanged
invalidateStaleListing() called only when the handler's own arithmetic says the listing is stale;
                         any revert fails the run
```

The handler's `approveListing` keeps spot at or below the highest price whose band floor still
admits the written strike (the vault now refuses a listing below it), and once three price cuts
are spent it lifts its price to `lowestListedUnitUsdg` instead of skipping.
`test_handlerReachesTranchesStaleKillsAndFlatSettlement` proves each of the three is reachable
with no reverted call. The handler never sets the Valorem fee on, so the fee exception to
"a tranche never moves `totalAssets()`" is covered by `test_writeMore_honoursTheValoremFeeSwitch`
only.

The per-entry USDG split of §5 changes no formula above: an entry's `usdgOut` is still drawn out of
`ep.usdgRemaining` and capped by it, so invariants 2 and 6 hold as written. None of the eight checks
that each entry received its own index growth. The handler queues and deposits, so that code runs
in every run, but the figures are asserted only in `test/unit/VaultQueueFairness.t.sol` (three
deterministic tests and a fuzz over three entries around two tranches).

---

## 8. Worked example

20 NVDA deposited. 10 contracts written at the $231 strike for $2.00 per contract.

```
gross premium            20.000000 USDG   (2.00 x 10)
  -> Overcall 5%          1.000000        consideration[1], paid in the fill
  -> vault 95%           19.000000        consideration[0], paid in the fill

harvest at rollClose
  gross                  19.000000
  -> protocol fee 5%      0.950000        floor(19_000_000 * 500 / 10_000) = 950_000, to the fee Safe
  -> depositors          18.050000        into accUsdgPerShare

expiry out of the money
  collateral returned    10.000000 NVDA   all of it
  totalAssets()          20e18            unchanged
  share price            unchanged        premium is not in the share price
  claimableUsdg(alice)   18.050000 USDG
```

The same week, assigned in full instead:

```
collateral given up      10.000000 NVDA
strike proceeds        2310.000000 USDG   (231.00 x 10)   RollClose.usdgFromAssignment
totalAssets()            10e18            the vault is now underweight; v1 does not rebuy
harvested (gross)       2329.000000 USDG  (19.00 premium + 2310.00 strike)   Harvest.grossUsdg
  fee-bearing             19.000000       gross - usdgFromAssignment
  -> protocol fee          0.950000       floor(19_000_000 * 500 / 10_000); strike proceeds not fee'd
  -> depositors         2328.050000       2310.00 strike + 18.05 premium net of fee
```

The protocol fee is the same 0.95 USDG whether or not the week was assigned. Both paths are
asserted in `Smoke.t.sol` and `VaultAssignment.t.sol`.
