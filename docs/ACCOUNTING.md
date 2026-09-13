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
| `contracts` | whole lots | 1 contract covers exactly `lotSize` = `1e18` of asset |
| every `*Bps` | basis points | `300` = 3% |
| `accUsdgPerShare` | USDG per share, scaled `1e27` | see §4 |

Valorem is the one place that breaks the pattern: `Claim.amountWritten` and
`Claim.amountExercised` are **1e18-scaled scalars**, not contract counts. `contractsAssigned()`
divides them back down. Getting this wrong reports a 10-contract assignment as
`10_000_000_000_000_000_000`.

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

---

## 5. The redeem queue

While a call is open, redemptions are queued. The mechanics:

```
queueRedeem(shares)      shares move into ESCROW on the vault.
                         The owner's free balance is simply balanceOf; there is no separate lock.
                         Their USDG is settled first, so they keep everything already earned.

_settleQueue()           runs inside rollClose, AFTER the harvest.
  escrowUsdg  = the escrow's own accrual over the cycle  (belongs to the queuers, not the stayers)
  payoutAsset = idleAssets() * queuedShares / totalSupply
  burn the escrowed shares
  record Epoch{sharesRemaining, assetsRemaining, usdgRemaining}
  reservedAssets += payoutAsset ;  usdgReservedForQueue += escrowUsdg

completeRedeem(to)       draws the owner's share out of their epoch and pays it.
```

### Zero dust, by construction

Each epoch tracks *remaining* shares, assets and USDG, and every claimant takes their proportion of
what is **left**:

```
assets = ep.assetsRemaining * shares / ep.sharesRemaining
```

The final claimant has `shares == ep.sharesRemaining`, so they receive exactly the remainder and
nothing is stranded. Asserted with deliberately awkward amounts in
`test_zeroDust_threeAwkwardClaimantsLeaveNothingBehind`.

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
redemption** rather than left to the holders who stayed. After an assigned week the queue collects
a **mix** of leftover NVDA and strike USDG — never a guarantee of the token back.

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
