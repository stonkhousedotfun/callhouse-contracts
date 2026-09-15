# Accounting

The subtlest part of Stonkhouse. Read this before changing anything under `src/`.

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
totalAssets() = max(asset.balanceOf(vault) + lockedAssets() - reservedAssets, 0)
```

The reserve comes off the whole book and only the final figure saturates. An earlier form clamped
`balance − reserved` at zero and then added the locked collateral, so an issuer `adminBurn` that took
the balance below the reserve while a call was open overstated NAV by the shortfall (AUDIT-FINDINGS
F-05). While `balance < reservedAssets` deposits are refused outright (§5). While a claim is
STRANDED (§5) the locked term is scaled to the part live shares still own,
`lockedAssets() × strandedRemainingWad / 1e18` (`Vault._lockedForNav`), because every epoch that
settled meanwhile has already taken its share of the claim out of the live shares' hands.

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
| `contracts` | whole lots | 1 contract covers exactly `Policy.LOT` = `1e18` of asset; `rollOpen` refuses to arm a type with any other lot |
| every `*Bps` | basis points | `300` = 3% |
| `accUsdgPerShare` | USDG per share, scaled `1e27` | see §4 |

Valorem is the one place that breaks the pattern: `Claim.amountWritten` and
`Claim.amountExercised` are **1e18-scaled scalars**, not contract counts. `contractsAssigned()`
divides them back down. Getting this wrong reports a 10-contract assignment as
`10_000_000_000_000_000_000`.

### Contracts across fills (write on fill)

Nothing is written at `rollOpen`: it ARMS an option type and snapshots its strike and window. Every
Seaport fill of the cycle's listing writes exactly the filled contracts inside the vault's
`authorizeOrder` hook, so a week is written in as many pieces as it has fills, all into ONE Valorem
claim: the first fill opens it (`clear.write(optionId, k)`), every later fill tops it up
(`clear.write(claimKey, k)`, refused unless the same id comes back). So:

| Quantity | What it counts |
|---|---|
| `contractsWritten` | the running total of every fill this week, which is also the number SOLD; zeroed by `rollClose` |
| `CallsWritten(optionId, claimKey, contractsCount, collateral)` | **one fill**: that fill's count and that fill's collateral, never the running total. Sum them per `claimKey` |
| `RollOpen.contractsCount` | always 0. The week's size is `contractsWritten`, or the sum of its `CallsWritten` |
| `lockedAssets()`, `claimedExerciseProceeds()`, `contractsAssigned()` | read `clear.position(claimKey)` / `clear.claim(claimKey)`, which upstream sums over every claim index (one per bucket written into), so they already cover every fill |
| `clear.balanceOf(vault, optionId)` | always 0 outside a fill. There is no `contractsRemaining`/`contractsSold` pair any more: sold IS written |

Sizing is on the total, at the fill: a fill of `k` passes only if `contractsWritten + k` is within
`maxContractsCap` and within `maxUtilizationBps` of `totalAssets()` (idle plus locked, less
reserved) at that moment. A fill moves asset from idle into Valorem one for one, so it never moves
`totalAssets()` or the share price, except by the Valorem engine fee when governance has accepted
it (15 bps of the fill's notional, charged on every fill, top-ups included, and valued at spot in
the premium floor the fill must clear).

`lockedAssets()` and `written × 1e18 − claim.amountExercised` can differ by a wei: upstream floors
the underlying and the exercised WAD per claim index separately, and the dust stays in Clear
(Zellic 2022 §4.1). The invariant suite allows exactly that wei.

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

**A floor on the share price (AF-05 follow-up).** `deposit` and `mint` revert `DepositsClosed`, and
`maxDeposit`/`maxMint` quote 0, while

```
totalSupply() > totalAssets() * MAX_SHARES_PER_ASSET        MAX_SHARES_PER_ASSET = 1e6, compiled in
```

that is, while one share is worth less than a millionth of an asset base unit. A live book is nowhere
near it: one share is one token at launch, one share per base unit, and the floor sits a million
times further out. Only a book that has lost everything with its shares still outstanding reads like
this: every contract it sold assigned plus an issuer `adminBurn`, or a burn that took the whole idle
balance, with the reserve gate (§4) satisfied because nothing is reserved. Two reasons, neither
governable:

- **A dead book must not sell new shares at nothing.** With `totalAssets()` at a few wei the formula
  above mints `assets × (supply + 1) / (assets + 1)` shares, up to ~1e18 per wei deposited. The
  newcomer buys the book for its dust, and whatever later returns to it (a redeemed stranded claim,
  an issuer restoring tokens) is theirs rather than the burnt holders'.
- **The overflow bound.** Two such deposits put the supply near 1e58, and `shares × accUsdgPerShare`
  (the 1e27-scaled index, §4) passes 2^256 in the queue's per-entry maths, so a queued account
  panicked in `queueRedeem` and `completeRedeem` and could never settle. The queue and index maths
  no longer form that product (§5, "What each entry is paid"), and the floor bounds the supply at
  1e6 times the asset supply on top: with NVDA's ~7.7e22 base units that is ~7.7e28 shares, and a
  share count times a 1e27-scaled index stays around 1e56.

The floor lifts by itself the moment the book is worth 1e-6 base units a share again: collateral
returning at `rollClose`, a stranded claim redeemed, an issuer restoring tokens, or the outstanding
shares queueing out (`totalSupply() == 0` is not below the floor, so an emptied book is reborn at
par). The exact boundary, the wind-down of a dead book through the queue, and the arithmetic are in
`test/regression/AF05_BurnShortfall.t.sol` (`test_deadBook_*`,
`test_queueMaths_doNotNeedShareTimesIndexToFit256Bits`).

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

### When premium becomes claimable

A fill's USDG reaches the vault's balance inside the fill, but it enters `accUsdgPerShare`, and so
`claimableUsdg`, only when a harvest runs: the `deposit`/`mint` checkpoint, `settleQueue`,
`rollClose` or `retryStrandedClaim`. `claimUsdg` does not harvest, and there is no public harvest
function, so premium from a fill is not claimable until one of those runs.

### The deposit checkpoint

`deposit` and `mint` call `_checkpointHarvest()` **before** minting. Without it, a premium that
landed on Tuesday would be distributed at Saturday's `rollClose` across a share supply that grew on
Friday, so anyone could deposit just before the close and take a cut of premium earned entirely by
other people's collateral, with no assignment risk.

Two consequences to hold in mind:

1. A filled week can emit **more than one `Harvest` event**. The indexer must sum them per cycle,
   not treat the last one as the week's result.
2. The protocol fee from a checkpoint accrues into `pendingFeeUsdg` rather than transferring, so
   the checkpoint makes no external call. It is pushed best-effort inside `rollClose` (and
   `retryStrandedClaim`) — and if the recipient cannot receive, anyone can complete it later with
   `sweepFee()` (see §6).

The deposit gate itself closes on the cycle's exercise **timestamp**, not on the phase: after it,
`deposit`/`mint` revert `DepositsClosed` and the previews return 0. One private predicate,
`_depositRefused()`, decides both the revert and the zero quote, and it has seven reasons: a vault
fill that has already written in the same transaction (a contract buyer depositing from its
ERC-1155 receive hook, before its USDG has landed, would otherwise take part of that fill's premium;
AUDIT-FINDINGS-2026-09-14 L-01), a phase other than Idle or Listed, the exercise timestamp in Listed, unclaimed assignment proceeds, a claim
still open while Idle (stranded), `asset.balanceOf(vault) < reservedAssets`, and the share-price
floor `totalSupply() > totalAssets() × 1e6` (§3). The reason is
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
- **Late money can be written against directly** (decision D9, A-6). Every fill sizes on
  `totalAssets()` at that moment, so a fill after the deposit can lock the depositor's own stock
  (`test_lateDepositorDuringListed_canBeWrittenAgainstByALaterFill`). The same holds for assets
  behind shares queued after a fill: queued shares stay in supply and exposed until settlement.
- **Premium already indexed is not theirs.** The checkpoint inside their deposit fixes every fill
  before it into the index; fills after it are shared.
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
                                                   (summed if the owner queues again in the epoch;
                                                   stored as quotient and remainder by 1e27, below)

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

`debt` is the private `_queueAccDebt`, an `AccDebt {usdg, rem}` pair with `debt == usdg × 1e27 +
rem` and `rem < 1e27`; `epochIndex` the private `_epochAccUsdgPerShare`. Neither is in the public
ABI.

### Settling while flat: `settleQueue()`

The queue used to settle only inside `rollClose`, which needs a `rollOpen` first. A queue made
while `Idle` therefore waited for a cycle that might never come: a halt nobody lifts, an option
type whose lot is not one token, an unaccepted Valorem fee, a stale or paused oracle, or less than one lot
idle (the last holder with half a token). Holders who had not queued could still redeem instantly.

```
settleQueue()            anyone; reverts WrongPhase unless phase == Idle, NothingQueued if queuedShares == 0
  _checkpointHarvest()   USDG that arrived since the last close is indexed first, so the escrow's
                         accrual on it goes to the queuers and not to the stayers
  _settleQueue()         exactly as above
```

While `Idle` and not stranded the vault holds no claim, so `idleAssets()` is `totalAssets()` and
`payoutAsset = q × (totalAssets() + 1) / (totalSupply + 1)` is to the base unit what `redeem(q)`
would pay at that moment (`test_settleQueue_paysWhatAnInstantRedeemWouldHave`). Nothing moves: the
shares are burnt, the payout is reserved, and `completeRedeem` pays it as for any epoch, so it
works while halted and under an issuer freeze (`test_settleQueue_worksUnderAnIssuerFreeze`). While
`Idle` and stranded, instant redemption is off and this IS the exit: the epoch is paid its slice of
the idle balance now and records its pro-rata share of the stranded claim for later ("A stranded
claim", below).

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

**The product is never formed in 256 bits (AF-05 follow-up).** `shares × epochIndex` is split by
`Math.mulDiv` and `mulmod` into `a × 1e27 + b`; the debt is stored split the same way, `q × 1e27 +
r` (`_addQueueDebt` carries `r` into `q` when it wraps past 1e27); and the entry's floor is exactly
`a − q`, less one when `b < r`, since the difference is `(a − q) × 1e27 + (b − r)` with `|b − r| <
1e27`. `shares × epochIndex >= debt` always holds (the debt sums `shares_j × index_j` with every
`index_j <= epochIndex`), so the subtraction cannot underflow. `Distributor._pending` uses
`Math.mulDiv` for `balance × Δindex / 1e27` for the same reason. Every figure in this section is
unchanged to the base unit; what changed is that no share count times the 1e27-scaled index can
revert a settle, a transfer or a payout, whatever the supply and the index have done since the entry
was made (`test_queueMaths_doNotNeedShareTimesIndexToFit256Bits`, with the index planted at 2^250).
The share-price floor (§3) keeps a real vault far from that bound in the first place.

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

**The two legs of a payout are independent (AUDIT-FINDINGS F-03).** `_payoutOwed` pays the Stock
Token leg with `safeTransfer` and then attempts the USDG leg with a raw call. `owedQueueUsdg`,
`usdgReservedForQueue` and `usdgAccounted` move only if the USDG actually left; on failure
`UsdgLegDeferred(owner, receiver, usdgOwed)` is emitted, the USDG stays booked, and a later
`completeRedeem` (to the same or another receiver) collects it. A call with nothing left but a
blocked USDG leg reverts `UsdgLegBlocked(usdgOwed)` rather than pretending nothing was queued. A
Stock Token pause still reverts the whole call: there is nothing to pay principal with, and the USDG
waits behind it (AUDIT-SCOPE §5 A.2).

**The reserve is haircut pro rata when it is unbacked (AUDIT-FINDINGS F-05).** `reservedAssets` is a
claim on the idle balance, senior to live shares (§1). The issuer's `adminBurn` can take the balance
below it. Then every uncollected reserved claimant is paid `booked × balance / reservedAssets`
(`ReserveHaircut(owner, booked, paid)`), `reservedAssets` is released by the booked amount, and
the fraction is invariant under collection (paying `a × b / r` leaves `b' / r' = b / r`), so the order
people collect in does not matter and the last claimant drains the reserve to exactly the balance.
`previewCompleteRedeem` quotes the haircut figure. Live shares' idle backing is already zero while
the balance is below the reserve, so nothing is taken from them; while a call is open, collateral
returning at `rollClose` refills the balance and a claimant who has not yet collected is then paid
in full, with the burn borne by live shares through NAV. Deposits are refused throughout
(`DepositsClosed`, `maxDeposit == 0`) and reopen once `balance >= reservedAssets` again.

The flush emits **`QueueEntrySettled`** (from both settle paths — the flush and
`completeRedeem` itself), because it changes who the epoch still owes without moving a token.
`CompleteRedeem` only ever reports the payout. Off-chain readers must draw epochs down on the
first event and reserves on the second; watching only `CompleteRedeem` misreads both.

### A stranded claim (AUDIT-FINDINGS F-02)

Valorem's `redeem` pushes the claim's strike USDG and then its unassigned NVDA to the vault in one
call, each leg only if non-zero, and a revert on either leg reverts the redeem. Both tokens have an
issuer who can make a leg revert at will: USDG paused, the vault or Clear frozen on USDG (Clear is the
sender of the USDG leg), Clear's USDG burnt by a supply controller; the vault blocklisted on the Stock
Token (the NVDA leg bites in every week that is not fully assigned). `rollClose` used to let that
revert take it down, and it was the only exit from Listed/Exercisable, so a stablecoin action froze
every idle unit of collateral and the whole queue for as long as it lasted.

`rollClose` now reaches Idle either way. A week in which nothing was sold has no claim at all
(`claimKey == 0`: under write on fill nothing is written until a fill), so the close skips the redeem,
forgets the armed type and cannot strand. Otherwise `ValoremLib.tryRedeemClaim` makes the redeem as a
low-level call; on failure the claim, `optionId` and `contractsWritten` are all **kept**, and the vault is
**stranded**: `isStranded() == phase == Idle && claimKey != 0`, the one state no other path can
produce. A gas-starved call cannot fake the failure: with `gasleft() <= gasBefore / 63` after the
inner call it reverts `RedeemOutOfGas` instead of stranding (EIP-150 leaves a starved callee's caller
at most 1/64 of its gas, a genuine refusal far more).

```
rollClose (redeem fails)   strandGen += 1 ; strandedRemainingWad = 1e18 ; emit ClaimStranded
                           harvest(0) ; _settleQueue() ; phase = Idle
while stranded             deposits refused (DepositsClosed, maxDeposit == 0)
                           instant redeem off (contractsWritten != 0 => !canRedeemInstantly)
                           rollOpen reverts StillStranded (exactly one stranded claim at a time)
                           lockedAssets() still reads the claim; NAV counts only live shares' part:
                             totalAssets = max(balance + locked x strandedRemainingWad / 1e18 - reserved, 0)
                           queueRedeem and settleQueue keep working on the IDLE balance
_settleQueue (claimKey != 0)
  payoutAsset = q x (idleAssets + 1) / (supply + 1)           the idle slice, as always
  share       = strandedRemainingWad x q / supply              the escrow's part of the claim, WAD
  strandedRemainingWad -= share
  epochStrandWad[epochId] = share ; epochStrandGen[epochId] = strandGen ; emit EpochStrandShare
_settleEpochEntry           mine = share x shares / ep.sharesRemaining  (last claimant takes the rest)
                            staged as owedStrandWad[owner] / owedStrandGen[owner]; no token, no value yet
retryStrandedClaim()        anyone, any time; reverts StillStranded until Valorem lets the redeem through
  (a, b) = redeem           NVDA and USDG returned
  queueWad = 1e18 - strandedRemainingWad
  strands[gen] = {assetsIn a, usdgIn b, wadLeft queueWad,
                  assetsLeft a x queueWad / 1e18, usdgLeft b x queueWad / 1e18}
  reservedAssets += assetsLeft ; usdgReservedForQueue += usdgLeft ; usdgAccounted += usdgLeft
  lastResolvedGen = gen ; emit StrandedClaimRecovered
  _harvest(b - usdgLeft)    live shares' USDG goes through the index fee-free, as strike proceeds do;
                            their NVDA is simply in the balance again, so NAV rises by it
completeRedeem (later)      _materializeStrand(owner): the staged WAD becomes
                              w == strands[gen].wadLeft ? (assetsLeft, usdgLeft)              the last owner
                                                        : (assetsIn x w / 1e18, usdgIn x w / 1e18)  floors
                            moved from the generation's *Left into owedAssets / owedQueueUsdg,
                            emit StrandShareSettled, then paid by _payoutOwed as any other owed balance
```

**Generations.** Each stranding is a generation; `rollOpen` refuses to open over a stranded claim,
so generations resolve strictly in order and an account never holds unresolved shares of two
generations at once. When an entry of a newer generation is staged against an owner still holding a
share of an older one, the older share is materialised first (`_stageStrandShare`); the preview folds
in the same order and with the same rounding, so `previewCompleteRedeem` still quotes exactly what
`completeRedeem` pays. A share whose generation is not yet redeemed is quoted as nothing, and a
`completeRedeem` with nothing else to collect reverts `StillStranded` rather than `NothingQueued`.

**Zero dust, by construction.** The epoch shares of a generation sum to exactly `1e18 −
strandedRemainingWad`, the owner shares of an epoch sum to exactly the epoch's share, and the last
owner of a generation takes exactly what its `*Left` still hold. The sum of the floors of the others
is at most the generation's `*Left`, so the last slice is never short of its own floor. Nothing is
left in `reservedAssets` or `usdgReservedForQueue` once every owner has collected; invariants 2 and 6
state the reserves as equalities with the uncollected `*Left` on the right-hand side.

**What changes for readers.** `RollClose` on a stranded close reports `assetsReturned == 0` and
`usdgFromAssignment == 0`, immediately preceded by `ClaimStranded(cycleNumber, claimKey, gen)`; the
claim's real proceeds arrive in the later `ClaimRedeemed` and `StrandedClaimRecovered`. The retry's
`Harvest` is emitted under the stranded cycle's number, and it is where a protocol fee the stranded
close could not push (USDG paused, vault frozen) finally leaves. `EpochStrandShare` is what a UI needs
to show a queuer's pending claim share; `StrandShareSettled` is the strand analogue of
`QueueEntrySettled` (books move, no token). Worked to the base unit in
`test/regression/AF02_UsdgFreezeRollClose.t.sol`, on the mock and on the real Clear bytecode.

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

One fee, on the premium only. There is no venue fee item: every listing has ONE consideration item,
USDG to the vault, so gross and net premium are the same figure.

| Fee | Rate | Mechanism | When |
|---|---|---|---|
| Stonkhouse | 5% of the premium (`protocolFeeBps` 500; bytecode ceiling 2000) | `pendingFeeUsdg`, pushed best-effort at `rollClose` and `retryStrandedClaim`, or by anyone through `sweepFee()`, always to `feeRecipient` (today the admin EOA) | only when harvested premium is positive |
| Valorem engine fee (opt-in) | 15 bps of the fill's NOTIONAL in the asset, on top of the collateral, when Clear's switch is on and governance accepted it | pulled by `clear.write` inside the fill; the fill's premium floor is raised by fee × spot | only on a fill, only with the switch on |

No fee on deposits. No fee on idle collateral. **An unfilled week harvests zero and is therefore
free** — `Policy.splitHarvest` returns `(0, 0)` on a zero amount.

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

`protocolFeeBps` is read from `policy` when the harvest runs, not when the fill happened, so a
`setPolicy` before the harvest changes the fee on premium already in the balance (up to the 2000 bps
ceiling).

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

### One consideration item, an exact unit price

```
consideration[0] = unitPrice * contracts     (USDG, recipient = the vault)
```

`approveListing` requires `gross % contracts == 0`: a partial fill pays `gross × k / amount`, Seaport
rejects a fraction it cannot express exactly (`InexactFraction`), and the fill gate re-checks the
premium floor per fill against `gross / amount × k`, so the per-contract price has to be an exact
figure. A premium above the strike is refused as a fat finger (`UnitPriceExceedsStrike`).

## 7. The invariants

Asserted after every call of the stateful suite, `test/invariant/VaultInvariant.t.sol` (64 runs ×
600 calls in the default profile). There are **thirteen** `invariant_*` functions; USDG solvency is
split into an aggregate half and a per-holder half. Formulas below are what the code asserts, not a
paraphrase of intent. `burned` and `burnReserveShortfall` are ghosts of the handler's `adminBurn`
action (the issuer's bare `_burn`, at most two ordinary and two reserve-aimed burns a run, none
before the run's first `rollClose`): the total destroyed, and the part of each burn that took the
balance below the reserve, `max(reserved − balAfter, 0) − max(reserved − balBefore, 0)`.
`strandAssetsLeft` / `strandUsdgLeft` are `Σ strands[g].assetsLeft` / `Σ strands[g].usdgLeft` over
every generation: the settled epochs' share of redeemed stranded claims their owners have not yet
collected (§5). `navLocked` is `lockedAssets()`, or `lockedAssets() × strandedRemainingWad / 1e18`
while a claim is stranded. `totalSold` is the sum of every successful `fill`'s size over the run, in
contracts (under write on fill, also everything the vault ever wrote); `armedOptionIds` is every id
`rollOpen` armed, oldest first.

```
1. asset conservation                                  invariant_assetConservation
   deposited >= withdrawn + assignedOut + burned
   asset.balanceOf(vault) + lockedAssets()  ==  deposited - withdrawn - assignedOut - burned
   (ghosts built from what callers asked for and what the vault returned, never from its balance)

2. USDG books balance (aggregate)                      invariant_usdgBooksBalance
   usdgOwed() + usdgReservedForQueue + usdgDust + usdgUnallocated + pendingFeeUsdg
       <=  usdg.balanceOf(vault) + maxIndexRoundingDrift
   usdgAccounted <= usdg.balanceOf(vault)                                   (no allowance)
   usdgReservedForQueue == sum(epoch.usdgRemaining) + sum(owedQueueUsdg) + strandUsdgLeft
                                                                            (no allowance)

3. USDG holder solvency (per holder)                   invariant_usdgHolderSolvency
   sum(claimableUsdg) + usdgReservedForQueue + usdgDust + usdgUnallocated + pendingFeeUsdg
       <=  usdg.balanceOf(vault) + maxIndexRoundingDrift

4. share accounting                                    invariant_shareAccounting
   totalSupply() == sum of holder balances (escrow at the vault included)
   balanceOf(optionBuyer) == 0
   queuedShares == balanceOf(vault)

5. no free shares                                      invariant_noFreeShares
   totalSupply() > 0  =>  convertToAssets(totalSupply()) <= totalAssets()
   sum(convertToAssets(holder balance)) + min(reservedAssets, asset.balanceOf(vault))
       <=  asset.balanceOf(vault) + lockedAssets()
   totalAssets() == max(asset.balanceOf(vault) + navLocked - reservedAssets, 0)
   (min(reserved, balance) is the reserve's real claim: under a shortfall the haircut pays exactly
    the balance across all claimants, §5; navLocked scales a stranded claim to live shares' part)

6. reserves are real                                   invariant_reservesAreReal
   reservedAssets <= asset.balanceOf(vault) + burnReserveShortfall
   (a shortfall of the balance below the reserve can originate only in a burn; with no burn in the
    run this is reservedAssets <= asset.balanceOf(vault))
   usdgReservedForQueue <= usdg.balanceOf(vault)
   usdgReservedForQueue + pendingFeeUsdg <= usdg.balanceOf(vault)
   reservedAssets == sum(epoch.assetsRemaining) + sum(owedAssets) + strandAssetsLeft   (no allowance)
   claimKey != 0  =>  claim.amountWritten == contractsWritten * 1e18,
                      claim.amountExercised <= claim.amountWritten,
                      |lockedAssets() - (claim.amountWritten - claim.amountExercised)| <= 1 wei
   claimKey == 0  =>  lockedAssets() == 0
   contractsAssigned() <= contractsWritten
   (Valorem floors the underlying and the exercised WAD per claim index separately, so the two can
    disagree by a wei of dust that stays in Clear; the vault's share of a bucket it shares with a
    third-party writer is fractional, hence the WAD form)

7. phase sanity                                        invariant_phaseSanity
   contractsWritten > 0  =>  phase != Idle  ||  isStranded()
   phase == Idle && !isStranded()  =>  claimKey == 0, lockedAssets() == 0, canRedeemInstantly(),
                                       strandGen == lastResolvedGen
   phase == Idle &&  isStranded()  =>  claimKey != 0, contractsWritten > 0, !canRedeemInstantly(),
                                       maxDeposit() == 0, strandGen == lastResolvedGen + 1,
                                       strandedRemainingWad <= 1e18
   phase != Idle         =>  strandGen == lastResolvedGen   (no cycle opens over a stranded claim)
   phase != Settling     (Settling is entered and left inside one rollClose)

8. the fee never touches strike proceeds               invariant_feeNeverTouchesStrikeProceeds
   protocolFeeBps == Policy.launchDefaults().protocolFeeBps   (one rate per run; pinned)
   (usdg.balanceOf(feeRecipient) + pendingFeeUsdg) * 10_000  <=  premiumToVault * protocolFeeBps
   (premiumToVault is a ghost measured as the vault's USDG balance change on every successful fill)

9. the deposit gate tracks the reserve and the floor   invariant_depositGateTracksTheReserve
   asset.balanceOf(vault) < reservedAssets  =>  maxDeposit() == 0 && maxMint() == 0
   isStranded()                             =>  maxDeposit() == 0 && maxMint() == 0
   totalSupply() > totalAssets() * 1e6      =>  maxDeposit() == 0 && maxMint() == 0
   maxDeposit() != 0  =>  balance >= reservedAssets, phase in {Idle, Listed}, !isStranded(),
                          totalSupply() <= totalAssets() * 1e6,
                          maxDeposit() == depositCap - totalAssets()

10. stranded-claim shares are conserved                invariant_strandSharesAreConserved
   for every generation g:
     g > lastResolvedGen  =>  strandedRemainingWad + sum(epochStrandWad | epochStrandGen == g)
                                + sum(owedStrandWad | owedStrandGen == g)  ==  1e18
     g <= lastResolvedGen =>  sum(epochStrandWad | gen g) + sum(owedStrandWad | gen g)
                                ==  strands[g].wadLeft

11. the vault holds no option tokens                   invariant_vaultHoldsNoOptionTokens
   optionId != 0  =>  clear.balanceOf(vault, optionId) == 0      (written == sold, F-01 closure)
   claimKey != 0  =>  clear.balanceOf(vault, claimKey) == 1

12. assignment never exceeds what was sold             invariant_assignedNeverExceedsSold
   assignedOut <= totalSold * 1e18                               (lifetime, every cycle summed)
   contractsAssigned() <= contractsWritten
   claimKey != 0  =>  claim.amountExercised <= contractsWritten * 1e18
   (the F-01 bound in the form a depositor cares about: with the third-party writer steering the
    bucket and exercising far more than the vault sold, the vault's lifetime assignment is still
    bounded by the contracts it sold; the pre-redesign handler, writing at arm, fails this in the
    first in-the-money week)

13. long supply is unexercised collateral              invariant_longSupplyIsUnexercisedCollateral
   for every id in armedOptionIds (live and past cycles alike):
     clear.optionSupply(id) == clear.unexercisedContracts(id)
     clear.optionSupply(id) == balanceOf(buyer, id) + balanceOf(thirdPartyWriter, id) + balanceOf(vault, id)
     clear.balanceOf(vault, id) == 0
   (MockClear tracks the supply upstream Clear keeps implicitly: write mints exactly what it
    collateralises, exercise burns exactly what it assigns, an expired id's longs are never burnt and
    its buckets never move again, so the identity has to survive the close; every outstanding option
    token is in a buyer's or the adversary's hands, never the vault's, for every id it ever armed)
```

The handler's `completeRedeem` also asserts, on every successful call, that `reservedAssets` fell by
the BOOKED amount (staged balance plus the entry's share of its epoch) whatever was paid, that a
payment below the booked amount happened only while the balance was below the reserve, and that
`previewCompleteRedeem` quoted exactly what was paid. `adminBurn` asserts that NAV after the burn is
the formula in invariant 5 and that both deposit quotes read zero the instant the reserve is
unbacked. `test_handlerReachesABurnShortfallAndTheHaircut` proves the shortfall, the shut gate, the
haircut and the reopening are all reachable with no reverted call.

`maxIndexRoundingDrift` is not slack. The index floors once per distribution while an account's
pending accrual floors once over its combined delta, so holders can be promised a base unit per
account per distribution more than was credited (§4). The handler bounds that exactly, and the run
is refused if it ever reaches a dollar. The queue reserve and the pending fee are asserted with no
allowance at all (invariant 6), because they are the obligations that must be backed to the unit.

**Issuer actions and the stranded claim (2026-09-13, AF-02).** The handler registers 26 actions
(the 17 user, keeper and clock actions, `settleQueue`, `adminBurn`, the two third-party actions
below, a second `fill` slot, `retryStrandedClaim` and the three issuer toggles).
The four added for F-02 are `toggleUsdgPause`, `toggleUsdgFreeze` (the vault or Clear),
`toggleNvdaBlock` (the vault's Stock Token blocklist) and `retryStrandedClaim`. Every existing action
skips exactly the calls the tokens' own gates would refuse (a deposit into a blocklisted vault, a
`claimUsdg` under a pause, a fill into a frozen vault, an exercise into a frozen Clear), and nothing
else: `rollClose` in particular is never skipped for a token state, because it must reach Idle
either way. The handler decides from the token state whether the redeem CAN go through and asserts
that the close stranded exactly when it could not, that `retryStrandedClaim` is refused
`StillStranded` exactly while a non-zero leg is blocked, and on success that the generation's
`assetsIn`/`usdgIn` equal the claim's `lockedAssets()`/`claimedExerciseProceeds()`, that its
`*Left` are the pro-rata floors of the queue's WAD, and that the reserves grew by exactly those.
`completeRedeem` asserts the reserve was released by the BOOKED amount including any stranded-claim
share folded in by the call (measured as the drop in `strandAssetsLeft`), and, while USDG cannot
leave the vault, that the USDG leg moved nothing and stayed booked in full (F-03).
`test_handlerReachesAStrandAndRecovers` and `test_handlerReachesANvdaBlocklistStrand` prove the
USDG-side and NVDA-side strands, a deferred USDG leg, a refused retry and a full recovery are all
reachable with no reverted call.

With `rollClose` passing 0 instead of the claim redemption to the harvest (the pre-2026-09-13 fee
rule, §6), invariant 8 failed with a counterexample that shrinks to seven calls: mint shares, roll open
(3 contracts), approve a listing, fill, exercise 1, warp, roll close.

**Write on fill and the third-party writer (2026-09-13 redesign).** The handler arms with
`rollOpen(optionId)` (writes nothing), lists up to capacity, and FILLS through the mock Seaport's
1.6 hook order, which is where the vault writes; `writeMore` and `invalidateStaleListing` no longer
exist. Two new actions play the F-01 adversary: `thirdPartyWrite` puts a stranger's contracts into
the vault's bucket on the same option id, and `thirdPartyExercise` exercises them (warping into the
window). Invariant 6's identity became `lockedAssets() == written × 1e18 − claim.amountExercised`
(± 1 wei of per-index rounding), stated against Valorem's own WAD figure because the vault's share
of a shared bucket is fractional, with `contractsAssigned() ≤ contractsWritten` alongside it. An
eleventh invariant, `invariant_vaultHoldsNoOptionTokens`, asserts after every call that
`clear.balanceOf(vault, optionId) == 0` and that the vault holds its claim NFT. The S4 hardening
pass (2026-09-13) added the twelfth and thirteenth: `invariant_assignedNeverExceedsSold` states the
F-01 bound cumulatively over the run (`assignedOut ≤ totalSold × 1e18`, the ghost being every
fill's size summed), and `invariant_longSupplyIsUnexercisedCollateral` ties each armed id's
outstanding option tokens to its unexercised buckets and to the buyer's and adversary's balances,
for past cycles as well as the live one. Asserted inline on every successful call:

```
rollOpen(id)             contractsWritten == 0; claimKey == 0; cycleNumber == before + 1
fill(k)                  contractsWritten == before + k; clear.balanceOf(vault, id) == 0;
                         the claim is opened on the first fill and unchanged by every later one;
                         premium in == unitPrice × k; totalAssets() unchanged
thirdPartyWrite(n)       lockedAssets(), totalAssets() and the vault's option balance unchanged
exercise / thirdPartyExercise
                         totalAssignedOut += the drop in lockedAssets() (the vault's pro-rata share);
                         claim.amountExercised <= claim.amountWritten == contractsWritten × 1e18
settleQueue()            epoch.sharesRemaining == queuedShares before
                         epoch.assetsRemaining == q * (idleAssets() + 1) / (totalSupply + 1)   (before)
                         queuedShares == 0; asset.balanceOf(vault) unchanged
```

The handler's `approveListing` keeps spot at or below the highest price whose band floor still
admits the armed strike, prices at or above the premium floor, and stops at three listings a
cycle; `fill` re-stamps the feed at the same answer (a live feed keeps ticking) and caps the fill
at the capacity the gate would admit. `test_handlerReachesTheThirdPartyBucketAndFlatSettlement`
proves the adversary and the flat settlement are reachable with no reverted call. The handler
never sets the Valorem fee on; the fee-on fill path is covered by `VaultWriteOnFill.t.sol` and
`AF04_FeeSizing.t.sol`.

The per-entry USDG split of §5 changes no formula above: an entry's `usdgOut` is still drawn out of
`ep.usdgRemaining` and capped by it, so invariants 2 and 6 hold as written. None of the thirteen
checks that each entry received its own index growth. The handler queues and deposits, so that code runs
in every run, but the figures are asserted only in `test/unit/VaultQueueFairness.t.sol` (three
deterministic tests and a fuzz over three entries around two tranches).

---

## 8. Worked example

20 NVDA deposited. 10 contracts sold (and so written) at the $231 strike for $1.90 per contract.

```
premium                  19.000000 USDG   (1.90 x 10), the one consideration item, paid in the fill

harvest at rollClose
  gross                  19.000000
  -> protocol fee 5%      0.950000        floor(19_000_000 * 500 / 10_000) = 950_000, to feeRecipient
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
