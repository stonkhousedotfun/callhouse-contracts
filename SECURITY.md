# Security

The threat model, the properties the contracts enforce, and the record of what the 2026-09-12
adversarial review, the 2026-09-13 documentation review and the 2026-09-13 second pass found and
what was done about it.

> **Paths.** Paths resolve from the root of this repository, leekzor/callhouse-contracts. A path
> followed by (leekzor/callhouse) lives in the app repository (keeper, indexer, web, ops and the
> project-wide docs), which mounts this repository as a git submodule at `contracts/`; a path
> followed by (leekzor/callhouse-site) lives in the marketing site repository. Both resolve from
> that repository's root.

Read `docs/ARCHITECTURE.md` (leekzor/callhouse) §2 for the trust boundaries and
[docs/ACCOUNTING.md](docs/ACCOUNTING.md) for the money maths. The per-alert response runbooks
are in `ops/alerts.md` (leekzor/callhouse).

---

## 0. The 2026-09-13 redesign: write on fill, no registry

The 2026-09-13 audit (`AUDIT-FINDINGS-2026-09-13.md` in the project handoff folder) found five
things, the first of them High: **the vault wrote calls before selling them and never exercised
the unsold ones** (F-01). Valorem assigns an exercise pro rata by amount WRITTEN across every
writer of an option id, so anyone could write the same id into the vault's bucket, self-exercise,
and take `unsold × (spot − strike)` of depositor principal every in-the-money week; with the
settlement seed fixed at the option key the assignment walk is public and the attack steers.
Bounding it (a cap on unsold inventory) was rejected in favour of closing it:

- **Write on fill (decision D1, A(ii)).** `rollOpen(optionId)` ARMS a cycle and writes nothing.
  Every listing is a `PARTIAL_RESTRICTED` Seaport 1.6 order whose zone is the vault, and the
  vault's `authorizeOrder` hook, which Seaport calls before any transfer and before recording the
  fill on every fulfilment path, writes exactly the filled contracts into Valorem in the same call
  that moves them to the buyer. `validateOrder`, after every transfer, reverts the fill unless the
  vault's option balance is back at its pre-fill baseline. The vault never holds an unsold option
  token, so `written == sold` by construction and the vault can be assigned on at most what it
  sold, every contract of which earned a premium. The vault never calls a Seaport fulfil function
  (the zone is the one caller Seaport exempts from the hooks), has no signing key and no EIP-1271
  hook (pre-validation on Seaport is the only authorisation path), and its ERC-1155 receiver
  accepts only mints from the clearinghouse. `writeMore`, `invalidateStaleListing`, the price-cut
  slots and the Overcall fee item are gone.
- **No registry (decision D16).** The vault used to read the approved rung, the strike and the
  cycle number from Overcall's per-market registry, a contract owned by one third-party EOA. It now
  validates the option type from the clearinghouse itself (`tokenType == Option`, our asset and
  USDG, lot 1e18, exercise ≥ 1 hour out, window ≥ 1 day, tenor ≤ 21 days, fee off or accepted,
  oracle live, strike inside the band with both bounds) and numbers its own cycles. The
  clearinghouse stays a deploy-time choice: Overcall's unmodified instance (whose key holds only the
  15 bps fee switch, opt-in for the vault) or one of our own from `script/DeployClear.s.sol`.
- **The other four** (AF-02 stranded-claim state machine, AF-03 split payout legs, AF-04 utilisation
  ceiling 9,985 plus a post-write reserve check, AF-05 honest NAV with one deposit gate and a
  pro-rata reserve haircut) are recorded in `docs/ACCOUNTING.md` and in the regressions under
  `test/regression/`, one file per finding, each asserting the FIXED behaviour on the real Valorem
  bytecode where the loss lived in Valorem's bucket engine.

**What stands behind this, and what does not (decision D14).** There is no external audit and no
separate internal security gauntlet. The contracts are unaudited. The gate is the test suite:
`forge fmt --check`, `forge build --sizes`, the unit, regression and invariant suites (405 tests;
the invariant campaign runs 64 × 600 calls with a third-party writer and exerciser in the vault's
bucket and asserts after every call, through thirteen invariants, that the vault holds no option
token, that its lifetime assignment never exceeds the contracts it sold, and that every armed id's
option-token supply equals its unexercised collateral and sits with the buyer or the adversary),
the real Seaport 1.6 runtime driven through every fulfilment path (single, advanced fractions, the
same listing twice in one `fulfillAvailableAdvancedOrders` within and beyond the remainder, match,
basic, skip-versus-revert, a hostile contract buyer), the fork suite against chain 4663 (20 tests:
first fill and top-up fill through the live Seaport and Clear; an assigned week exercised by the
buyer and closed by a stranger with assignment equal to what was sold and the strike credited
fee-free; an unfilled week closing flat; a stranded close under the REAL USDG `ASSET_PROTECTION`
freeze of the vault and its permissionless recovery after the unfreeze; the TSTORE/TLOAD create
probe answered by the live node through the RPC), and the deploy rehearsal on an anvil fork with
the chain's 98,304 B code limit (`script/rehearse-deploy.sh`: our own Clear deployed from the
vendored artifact and used on path A, Overcall's on path B, both admin paths, Verify's teeth).
Findings 9, 12, 13, 16 and 17 in §4 describe mechanisms the redesign removed (`writeMore`,
price-cut slots, `invalidateStaleListing`); they stay as history.

## 1. The one-sentence model

**No off-chain component can transfer a token out of the vault, but the keeper chooses the price
the vault sells calls at, and a price is value.** The vault is the Valorem writer and the Seaport
offerer; it authorises listings by hash on chain. The keeper proposes, the vault validates every
field against compiled-in shape rules and the admin-set policy. A fully compromised keeper key
cannot withdraw, redirect or unlock collateral. It chooses the option type (strike and window,
inside the arm gate) and it can sell the week's calls at exactly the policy's premium floor to a
buyer it controls; at launch policy that moves about 1.1% of the sold notional per week from
depositors to that buyer (sold is written, under write on fill), more in a high-volatility week
(§3).

An earlier revision of this section said a compromised keeper "can waste a week; it cannot take a
token". The second half was true of tokens and false of value; §4, finding 10 records the
correction.

## 2. Properties enforced in bytecode

These are not conventions; they are checks in the deployed code, each with regression tests.

- **Hard policy caps.** `Policy.sol` bounds every governance-settable parameter (OTM band,
  premium floor, utilisation, protocol fee, max contracts) in bytecode. The Admin Safe can only
  move policy inside them.
- **The protocol fee never touches principal.** It is charged on premium only (5% at launch,
  20% ceiling): `rollClose` excludes the USDG it measures coming out of the Valorem claim — the
  strike proceeds of an assignment — from the fee base and credits it to holders in full. The
  exclusion is code, not a policy field, so no admin setting can put strike proceeds back under
  the fee. See `docs/ACCOUNTING.md` §6.
- **The deposit window closes on the cycle's exercise timestamp**, not on the phase enum and
  not on anyone calling `lockBook`. After it, `deposit`/`mint` revert `DepositsClosed`
  and `maxDeposit`/`maxMint` return 0. A second, clock-independent line refuses deposits
  whenever unclaimed assignment proceeds exist (NAV has already fallen by the collateral that
  left), a third whenever the asset balance sits below `reservedAssets` (an issuer burn), so
  a newcomer's deposit can never be paid straight out to earlier settled redeemers, and a fourth
  whenever `totalSupply() > totalAssets() × 1e6` (a share worth under 1e-6 base units: a book
  burnt to nothing with its shares outstanding is not sold to a newcomer at nothing, and the share
  supply stays inside what the 1e27-scaled index arithmetic can carry; AF-05 follow-up). One
  predicate and one selector serve every refusal. See §4, finding 1, and AUDIT-FINDINGS F-05.
- **A settled redeemer's Stock Token leg is paid whatever USDG is doing.** `completeRedeem` pays
  the asset leg with `safeTransfer` and the USDG leg best-effort; a USDG pause or freeze defers the
  USDG (`UsdgLegDeferred`, collectable later or to another receiver) and never holds principal.
  If the asset balance has been burnt below the reserve, every uncollected reserved claimant takes
  the same `balance / reservedAssets` fraction (`ReserveHaircut`), never first come, first served.
  See AUDIT-FINDINGS F-03 and F-05.
- **The vault never holds an unsold option token** (§0). Nothing is written at `rollOpen`;
  `authorizeOrder` writes exactly what Seaport is moving to a buyer in the same call, and
  `validateOrder` reverts the fill if anything stayed behind. The vault is assigned on at most
  what it sold. `test/regression/AF01_UnsoldInventory.t.sol`, `test/unit/VaultWriteOnFill.t.sol`,
  `test/unit/VaultRealSeaport.t.sol`, `invariant_vaultHoldsNoOptionTokens`.
- **Only Seaport can make the vault write, and only for its own live listing.** Both hooks refuse
  any caller but Seaport (`NotSeaport`); `authorizeOrder` refuses any order whose hash is not
  `listingHash` or whose offerer is not the vault (`NotLiveListing`), and the hash commits to the
  zone, the order type, the items, the salt and the counter. A stranger's restricted order naming
  the vault as zone cannot make it write.
- **The arm gate.** `ValoremLib.open` reads the option tuple back from the clearinghouse and
  refuses a claim id or an unknown id (`NotAnOptionType`), another underlying or exercise asset,
  any lot but exactly 1e18 (`UnexpectedLotSize`: the band, the floor and utilisation are all per
  token, §4 finding 6), an exercise timestamp less than `MIN_LEAD` (1 hour) away
  (`ExerciseTooSoon`: nothing sold can be assigned in the same tick), a window under
  `MIN_EXERCISE_WINDOW` (1 day) or a tenor over `MAX_CYCLE_TENOR` (21 days) (`BadCycleWindow`: a
  bad type skips a week, it cannot lock principal for years), the engine fee on and unaccepted, a
  paused or stale oracle, and a strike outside the band, BOTH bounds.
- **The fill gate, at the fill's own spot.** `ValoremLib.writeOnFill` refuses a fill at or after
  `cycleExerciseTs` (`WriteWindowClosed`), while halted, while the engine fee is on and unaccepted,
  on a paused or stale oracle, with the strike inside the band FLOOR (ceiling not re-checked: a
  sell-off makes the call safer, decision D9), with the premium under the floor at live spot plus
  fee × spot when the fee is on (`PremiumBelowFloorAtFill`), or with `written + k` past
  `maxContractsCap` or `maxUtilizationBps` of `totalAssets()` at that moment. After the write the
  asset balance must still cover `reservedAssets` (`ReserveBreached`, AF-04). The approval to the
  clearinghouse is sized to collateral plus fee and zeroed afterwards.
- **The Valorem engine fee is opt-in.** While `clear.feesEnabled()` is on and governance has
  not accepted, an arm and every fill revert `ValoremFeeNotAccepted`. 15 bps of notional on a
  weekly out-of-the-money call is a governance decision, not a keeper one.
- **The close never depends on the claim redeeming** (AF-02). `rollClose` makes Valorem's `redeem`
  as a low-level call (`ValoremLib.tryRedeemClaim`); when it reverts, for any cause a token issuer
  can produce (USDG paused; the vault or Clear frozen on USDG, Clear being the sender of the USDG
  leg; Clear's USDG burnt by a supply controller; the vault blocklisted on the Stock Token, which
  reverts the NVDA leg in every week that is not fully assigned), the vault still reaches `Idle`
  with the claim STRANDED: kept, still counted by `lockedAssets()`, its pro-rata share recorded for
  every epoch that settles meanwhile (`EpochStrandShare`), deposits and instant redemption shut,
  `rollOpen` refused (`StillStranded`), and a permissionless `retryStrandedClaim()` that settles
  it the first time Valorem lets it through. A gas-starved close cannot fake the failure
  (`RedeemOutOfGas`). Generations resolve strictly in order and leave at most a wei of dust per
  owner. `test/regression/AF02_UsdgFreezeRollClose.t.sol` covers every cause above on the mock and
  on the real Clear bytecode, plus an unassigned-week control, the gas ladder and a re-strand in a
  later generation with an uncollected earlier-generation owner; ACCOUNTING.md §5.
- **A queue made while the vault is flat can always be settled.** `settleQueue()` is
  permissionless in `Idle`: it checkpoints the harvest and settles the epoch, moving no tokens,
  so it works while halted and under an issuer freeze. It prices the epoch exactly like an
  instant redemption, virtual share included, so it is never a better exit than `redeem` and
  cannot turn donation inflation into a profit. See §4, findings 8 and 15.
- **Three listings per cycle.** Every `approveListing` spends one of `MAX_LISTINGS_PER_CYCLE = 3`,
  cancelled or not. A listing is sized to capacity and Seaport tracks the fraction filled, so a
  relist is a reprice, and three reprices a week is how far a keeper can walk the quote before the
  guardian must act. `approveListing` also refuses a strike below the live band floor and a gross
  below the live premium floor, as an early refusal for the keeper; the fill gate is the line of
  defence, so a stale listing is simply unfillable rather than needing a permissionless kill.
- **The protocol fee push is best-effort.** A blocklisted fee recipient, a paused USDG, or a
  recipient that reverts on receive must not freeze `rollClose` — the only function that
  redeems the claim and settles the queue. The fee accrues into `pendingFeeUsdg` and is
  recoverable by anyone through `sweepFee()`, which always pays the stored recipient.
- **Every payout is clamped to what is actually backed** (`_usdgAvailableForHolders`), and
  accounting is anchored on a measured USDG balance, not an arithmetic identity. The index
  drift costs dust, never principal. See ACCOUNTING.md §4.
- **Each redeem-queue entry is paid its own escrow accrual.** Queued shares share one escrow, but
  each entry receives only the USDG indexed while its own shares were in it (a reward debt taken
  at `queueRedeem`), so a later queuer cannot take what an earlier queuer's shares earned. See
  ACCOUNTING.md §5 and §4, finding 7.
- **Rounding always favours the vault** in share maths, and the queue's asset leg uses the same
  +1/+1 price as instant redemption (ACCOUNTING.md §3, §5).
- **The invariants in ACCOUNTING.md §7** are asserted continuously by the stateful suite.

## 3. What a compromise of each key buys

| Key | Power | Worst case |
|---|---|---|
| Keeper (hot) | choose and arm the option type inside the arm gate (`rollOpen`: strike inside the band with both bounds, lot one token, window and tenor inside the compiled bounds), propose every order and its price and size up to capacity (`approveListing`), cancel, call the rolls | **value leakage, not only a wasted week.** It can arm the lowest strike the band admits and list the whole capacity at exactly the premium floor to a buyer it controls, and a colluding fill (which is what writes) can follow the authorisation immediately, before a guardian can react. At launch policy (3% OTM floor, 0.40% premium floor) a 7-day 3%-OTM NVDA call is worth about 1.5% of spot at 50% implied volatility, so about **1.1% of the sold notional per week** (up to 95% of NAV sold) goes to the buyer in expectation; about 2.7% at 80% IV. That is the whole bound: under write on fill there is no unsold inventory for a keeper-and-accomplice to write to the cap and leave unlisted (the AF-01 variant that exceeded the earlier bound). It cannot move a token, sell above strike, list past `cycleExerciseTs`, or write outside the band and the caps |
| Bootstrap admin (the deployer EOA holding `DEFAULT_ADMIN_ROLE` until `HandoverAdmin.s.sol` completes; no timelock) | everything the Admin Safe row has, from one hot-signable key | everything the keeper row has, and worse: `setPolicy` to the compiled floors (1% OTM, 0.10% premium, 99.85% utilisation), `grantRole(KEEPER_ROLE, itself)`, then arm, list and sell to itself within a block or two. A 7-day 1%-OTM call is worth about 2.3% of spot at 50% IV, so about **2.2% of the sold notional per week** (about 3.9% at 80% IV), plus a 20% fee on whatever premium is left, routed where it likes. Still no vault function that transfers a token to it, and on the launch plan this key does **not** hold Clear's `feeTo` (`DeployClear` sets `CLEAR_FEE_TO` to the admin Safe; `HandoverAdmin` never moves it; `Verify.s.sol` requires `EXPECTED_CLEAR_FEE_TO`). It can still `acceptValoremFee` on the vault. The engine-fee lever is the Admin Safe row |
| Guardian | halt (`rollOpen`, `approveListing` and every fill), cancel, invalidate all listings | denial of new sales until the admin unhalts, and burnt premium; exits stay open |
| Admin Safe (2/3) | policy inside caps, fee recipient, Valorem fee acceptance, deposit cap, role grants; on our own Clear, that Clear's `feeTo` from deploy (fee switch, fee sweep, `setFeeTo`; `HandoverAdmin` never moves it) | the bootstrap admin row, needing two of three signers instead of one key. After handover the same Safe holds both vault admin and `feeTo`, so `setFeesEnabled(true)` plus `acceptValoremFee(true)` is 2-of-3 with no delay: every fill then pulls **15 bps of its notional from the vault in NVDA** into Clear's fee balance, sweepable to the Safe (plus 15 bps of the strike USDG from every exerciser). Depositors are compensated only through the fill floor, which adds the fee's spot value to the premium the buyer must pay, so the net is a forced sale of 15 bps of NVDA per fill at the oracle's spot less the 5% protocol fee on that extra premium. With 95% of NAV sold that is about 0.14% of NAV a week in NVDA, capped by Clear's compiled 15 bps. No timelock on any of it |
| Anyone | `lockBook`, `rollClose` after expiry + 1 hour, `sweepFee`, `settleQueue` while `Idle`, buying through Seaport, writing the same option id on Valorem and exercising | settling a flat queue at the instant-redeem price; a fill at the listed price inside the fill gate; being assigned alongside the vault pro rata on what the vault SOLD. None moves value from depositors beyond the priced covered call (§0) |
| Clear `feeTo` of whichever clearinghouse the vault is constructed with (Overcall's EOA `0xdAe7…0782` on the default instance, an unfunded key with nonce 0; the admin Safe on an instance from `script/DeployClear.s.sol`) | the 15 bps engine fee switch (`setFeesEnabled`), `setFeeTo` (which emits no event: nomination is visible only in storage; `Verify.s.sol` reads `pendingFeeTo` from slot 3 on our instance), the URI generator, sweeping accumulated fee balances. Clear itself has no owner, no pause, no blocklist and no proxy | on Overcall's instance: a week the vault refuses to arm or fill until governance accepts the fee (`ValoremFeeNotAccepted`); nothing on collateral. On the instance we deploy (the launch choice, `feeTo` = the admin Safe from deploy) the switch is the Safe's from block one; after handover the same Safe also holds `acceptValoremFee`, so the Admin Safe row carries the 15 bps. Upstream Valorem is dormant (last commit 2023-11), so there is no patch path, bounty or incident response behind either instance |
| Seaport 1.6 | no admin, not upgradeable, no pause, no fee switch; the zone hooks run on every fill; `conduitKey == 0` so no conduit owner has power | none beyond the verified 1.6 hook order the design rests on (`authorizeOrder` before any transfer and before the status update on every fulfilment path, `validateOrder` after all transfers, a post-authorise status failure reverts the whole transaction); `Verify.s.sol` pins the runtime hash. No public audit of the 1.6 hook code was found |
| USDG issuer (Paxos). **One EOA, `0x3Af3…024B`, holds every operational power with no timelock** | instant `pause()` (blocks transfer, transferFrom, approve, permit; not views, not mint or burn); instant `freeze`/`wipeFrozenAddress` (enforced on sender, recipient AND the `transferFrom` spender; a zero-value transfer with a frozen party reverts; 27 freezes on 4663 so far, 0 unfreezes ever); SupplyControl manager, so it can grant itself `allowAnyMintAndBurnAddress` and **burn USDG from any non-frozen address with no allowance** in two transactions; owner of the OFT wrapper; proposer, executor and canceller of the 24 h `TimelockController` that gates the UUPS upgrade and facet replacement | premium and strike proceeds in the vault, in Clear (an assigned week's strike USDG sits in Clear until `rollClose`) and owed to the queue can be frozen, wiped or burnt at any moment. Principal (the Stock Token) is never touched. The contracts make sure it never TRAPS anyone: the close strands rather than bricks (AF-02), the Stock Token leg of a queued exit is paid whatever USDG does (AF-03), the fee push is best-effort, and a wipe re-anchors `usdgAccounted` to the lower balance (accepted, §4). An earlier revision of this file said freeze and wipe sat "behind a 24 h timelock"; only the upgrade does |
| Stock Token issuer (RHJ / Robinhood; 13 registry roles, each held by exactly one EOA, none behind a multisig or timelock) | `adminBurn(from, amount)`, a bare `_burn` with **no pause and no blocklist modifier**, so it works even on a paused token or a blocklisted holder; registry-wide and per-token `pause()`; a per-address blocklist enforced on sender and recipient; `pauseOracle()`; `updateMultiplier`, where the multiplier **can decrease and can apply immediately** (WEEK went 2.0 → 1.0 on chain) while the price feed re-prints only on its 0.5% deviation trigger (≈11.8 h lag observed at NVDA's 2026-09-10 step); the beacon upgrader re-points the logic of all 204 Stock Tokens in one transaction; the prospectus adds seizure, and an Issuer Redemption Option that terminates the Series on **30 calendar days' notice**, after which tokens are redeemable only with KYC the vault cannot satisfy | vault NVDA destroyed (NAV and the reserve diverge: AF-05's honest NAV, deposit refusal and pro-rata haircut are the response), every NVDA-moving leg stopped (fills, `clear.write`, the redeem's NVDA leg, `completeRedeem`'s asset leg, instant redemption), the band priced on a stale per-token basis for the hours a multiplier step leads the feed, or a terminated Series the vault holds with no redemption path. Disclosed, not coded around: that is the asset |
| Robinhood Chain (RHDA, LLC): a single sequencer running ArbOS 61 | first-come-first-served ordering; **compliance filtering**: any transaction touching a restricted address can be dropped at the sequencer (burns to `0x0` exempt); force inclusion through the L1 Delayed Inbox after **4 days**, and whether force-included transactions are also filtered depends on optional components whose status on 4663 is unknown; the L1 Security Council (7-of-8, no delay) and the 6-of-8 proposer Safe behind a 7-day timelock can change any chain rule | if the vault, a depositor, the keeper or Seaport is restricted, nothing the vault does helps: no transaction reaches it. A censoring sequencer can delay `rollClose` and every exit for as long as it censors; the only remedy is force inclusion after 4 days, and only if that path is not filtered too. The vault has no sequencer-uptime feed to read (none exists on 4663), and `maxPriceAge` at 4 days does not notice an outage shorter than that |

**How the leakage figures are computed.** Black-Scholes value of a 7-day call at zero rates,
strike at the band floor, expressed as a share of spot, minus the policy premium floor (charged on
the gross of the one consideration item; there is no venue fee any more, so gross is net). The
buyer's expected profit is the vault's expected loss, paid out through assignment and a share
price that falls on assigned weeks. It is a bound per undetected week, not a one-off: nothing on
chain notices a sale at the floor, so it repeats until someone halts. The honest keeper also
prices at `max(policy floor, last fill)` (plan 5.2; the keeper is not yet ported to write on fill,
§5), so on a thin book with no recent fill it sells at the floor too, and depositors bear the same
gap without anyone being compromised.

**Mitigations considered and NOT implemented (open decisions).** None of these is in the code or
the launch plan today:

1. **Admin behind a `TimelockController`**, so a `setPolicy`, a fee change or a `KEEPER_ROLE`
   grant is visible for a delay before it can be used. Today every admin action is immediate.
2. **Higher compiled floors.** `Policy.MIN_PREMIUM_FLOOR_BPS = 10` and `MIN_OTM_FLOOR_BPS = 100`
   are what bound the admin row. Raising them (for example towards the launch 40 and 300) caps
   the admin's lever at the keeper's; it needs a redeploy, since they are bytecode constants.
3. **A listing start delay.** `SeaportOrderLib` refuses `startTime > now`
   (`ListingStartsInFuture`), so a listing is fillable in the block it is authorised. Requiring a
   delay would give the guardian a window to see and invalidate a floor-priced listing.
4. **Vol-model keeper pricing.** Price asks from an implied-volatility model with the policy floor
   as a backstop only, instead of `max(floor, last fill)`. Off-chain; it helps the honest-keeper
   case and does nothing against a compromised key.
5. **No deposits before the Safe handover.** Hold `depositCap` at 0 (or do not publish the vault)
   until `HandoverAdmin.s.sol` has completed, so the one-key bootstrap row never has depositor
   money under it.

## 4. The 2026-09-12 adversarial review

An internal adversarial review run across 13 surfaces (vault core, share accounting, phase
machine and reentrancy, the Valorem and Seaport adapters, the order library, the distributor,
access control, token integration, USDG distribution, economic/MEV, and the keeper, indexer
API and web surfaces). 72 raw findings were raised; **51 survived adversarial refutation**
(each finding had to produce a concrete, reachable loss or lie to survive). Everything in
the "Fixed" table below is fixed and carries a regression test in `test/unit/VaultSecurity.t.sol`,
which documents each attack in full.

This was an internal review, not an external audit, and no external audit followed it (owner
decision D14, 2026-09-13; §0). What did follow was the 2026-09-13 internal audit whose five
findings are recorded below under "The 2026-09-13 audit".

### Fixed

| # | Severity | Finding | Fix |
|---|---|---|---|
| 1 | **Critical** (found independently by four surfaces) | Assignment crashes NAV inside the exerciser's own transaction: Valorem takes the collateral and leaves strike USDG in the claim, with no callback. While the vault sat in `Listed` — legitimate for the whole 24-hour exercise window — anyone could exercise, mint shares against the crashed NAV in the same block, and collect a pro-rata slice of the strike proceeds at `rollClose`, taken from the depositors who were actually assigned. Principal round-trips untouched, so the extraction was riskless | Deposit window closes on `cycleExerciseTs`, whether or not `lockBook` is called and whether or not the keeper is alive; plus a clock-independent refusal whenever unclaimed assignment proceeds exist. `test_critical_*` (3 tests) |
| 2 | High | The registry's `setCycle` bounds expiry only from below. A years-long expiry would lock up to 95% of depositor collateral in Valorem for the whole tenor, with no redemption path for anyone | `MAX_CYCLE_TENOR = 21 days`, compiled in; `rollOpen` reverts `BadCycleWindow` before any collateral moves. `test_high_refusesAnAbsurdlyLongCycleBeforeAnyCollateralMoves`, `test_high_normalWeeklyCycleStillWrites` |
| 3 | High | The vault trusted the registry to have validated the option it wrote. Writing an option whose exercise/expiry differed from the cycle's silently broke the deposit gate's "no assignment before `cycleExerciseTs`" premise | At the time: `rollOpen` reverted `OptionWindowMismatch` unless the option's window equaled the registry cycle's (`test_high_refusesAnOptionWhoseWindowDiffersFromTheCycle`). **Superseded by decision D16 (§0):** there is no registry cycle to compare against; the vault snapshots `cycleExerciseTs`/`cycleExpiryTs` from the option type itself and bounds them in the arm gate (`ExerciseTooSoon`, `BadCycleWindow`), so the mismatch cannot arise. `OptionWindowMismatch` no longer exists; the regression is `test_high_cycleWindowIsTheOptionsOwn` |
| 4 | Medium | The protocol fee was pushed inside `rollClose` with a hard transfer, so a blocklisted fee Safe, a paused USDG, or a reverting recipient froze every unit of collateral, stranded the queue and blocked every future cycle — over a fee that harms only us | The push is best-effort and cannot revert the close; the fee accrues into `pendingFeeUsdg`; `sweepFee()` is the permissionless recovery and always pays the stored recipient. `test_medium_blockedFeeRecipientDoesNotFreezeTheVault` |
| 5 | Medium | The Valorem fee acceptance switch was wired through but still could not write: the engine fee is charged **on top of** the collateral, so approving only the collateral made every write revert on allowance once the switch flipped. With no upgradeability, that ended the product's ability to write | The write approves collateral + fee and scrubs the allowance after. `test_medium_acceptedValoremFeeActuallyLetsTheVaultWrite` |

### Hardening landed in the same pass

- **`QueueEntrySettled` event.** `queueRedeem` auto-settling a stale epoch moved value into the
  owner's owed balances with no event — the only state change in the vault an off-chain reader
  could not see, and a false "unclaimed epoch" alert in the making. Now emitted by both settle
  paths and indexed. (`test_queueEntrySettledIsEmitted*`.)
- **Error/ABI refresh.** The keeper was missing 32 custom-error fragments (it would have shown
  a bare selector instead of a revert name during simulation), and the ops/indexer/web ABI
  copies (leekzor/callhouse) predated the fixes. All regenerated; the web ABI now has a committed generator
  (`web/scripts/gen-abis.mjs` (leekzor/callhouse)) like the indexer's.
- **Indexer coverage of `FeeSwept`**, so fee recovery is visible off-chain, plus domain-event
  logging across the keeper and indexer for every alert the runbooks page on.

### Found 2026-09-13, after the review

Found 2026-09-13 during documentation review, verified with PoC, fixed in `6ed528f`. The
2026-09-12 review missed both. Each surfaced while the protocol documentation was being written,
was then verified adversarially with an executable proof of concept against the unfixed code, and
was fixed with regression tests that document the attack. Severities are our own assessment; no
external auditor has seen either finding or either fix.

| # | Severity | Finding | Fix |
|---|---|---|---|
| 6 | High (needs the third-party registry owner to act) | `rollOpen` checked the OTM band, the premium floor and utilisation per one token (`Policy.LOT = 1e18`) but wrote whatever `lotSize` the Overcall registry reported. The registry owner can change `lotSize` between cycles (`setLotSize` refuses only while a cycle is live) and list a ladder whose strikes were not rescaled. At lot 2e18 a strike of 227 USDG per contract is 113.50 per token against 220 spot, yet the band saw it 3.2% out of the money: the proof of concept wrote 23 contracts, a buyer filled at the premium floor, exercised, and took about $4,879 of an $11,000 book. Any lot above about 1.03e18 wrote an in-the-money call; with cap sizing, a lot above 1/0.95 also locked assets already reserved for settled redeemers | `ValoremLib.writeCalls` (since the second pass, `ValoremLib.write`) reverts `UnexpectedLotSize(1e18, lotSize)` unless the cycle's lot is exactly 1e18, before any approval or collateral moves. Library-only; `Vault` bytecode unchanged. `test/unit/VaultLotSize.t.sol` (5 tests) |
| 7 | High | The redeem queue's escrow is one account, and its USDG accrual was split among the epoch's entries pro rata by shares at settlement. But the accrual is earned tranche by tranche, each time premium is indexed, on whatever the escrow held at that moment. A deposit that indexed premium between two queue entries moved value from the earlier queuer to the later one (in the proof of concept the earlier queuer's epoch USDG was 1,504,166 base units instead of 4,512,500), and a newcomer who deposited 30e18 after a fill, her own deposit being the checkpoint, and queued it took 6,768,750 of the 9,025,000 an earlier queuer's shares had earned, while earning nothing. Premium only, never principal; a checkpoint in `queueRedeem` would not have fixed it | Each account records a reward debt (`shares × accUsdgPerShare` when its shares enter escrow) and each epoch records the index it settled at; an entry is paid `floor((shares × epochIndex − debt) / 1e27)`, capped at what the epoch still holds, and the last claimant takes the remainder. Private storage only; public ABI unchanged. `test/unit/VaultQueueFairness.t.sol` (3 tests and a 256-run fuzz); ACCOUNTING.md §5 |

### Found 2026-09-13, second pass

A second internal pass on 2026-09-13 over the contracts as fixed in `6ed528f`, followed by
adversarial rounds against the fixes themselves. Findings 8 to 12 are the pass's own; 13 to 17
were raised against the first drafts of those fixes and confirmed with a proof of concept or by
reading the code. Everything below was committed as the checkpoint `25f4328` and then redesigned
(§0); the test names are the regressions as they stood at that checkpoint, and rows marked
**removed by the redesign** describe mechanisms that no longer exist. Severities are our own; no
external auditor has seen any of it. (Sizes at the checkpoint: `Vault` 22,854 B, `ValoremLib`
6,073 B, seven link sites; after the redesign and the L-01 fix `Vault` is 25,775 B, `ValoremLib` 5,993 B,
`SeaportOrderLib` 5,170 B, eight link sites, and EIP-170 headroom is not a constraint on chain
4663, README item 1.)

| # | Severity | Finding | Fix | Regression tests |
|---|---|---|---|---|
| 8 (F1) | Medium (PoC-confirmed) | **Shares queued while the vault is `Idle` could be trapped.** `queueRedeem` is allowed in every phase and there is no dequeue, but the queue settled only inside `rollClose`, which needs a `rollOpen` first. Anything that blocks the next write froze the queuer while holders who had not queued redeemed instantly: a halt nobody lifts, a registry lot other than 1e18, an unaccepted Valorem fee, a stale or paused oracle, or less than one lot idle. PoC (a): alice and bob deposit 10 each, alice queues 10 in `Idle`, the guardian halts, bob redeems, and alice's `completeRedeem` still reverts `EpochNotSettled(1, 1)` a year later while `rollClose` reverts `WrongPhase`. PoC (b): the sole holder deposits 0.5 and queues it all; `rollOpen(…, 1)` reverts `ContractsAboveUtilization(1, 0)` for ever | Permissionless `settleQueue()` (`nonReentrant`): reverts `WrongPhase` outside `Idle` and `NothingQueued` on an empty queue, then `_checkpointHarvest()` and `_settleQueue()`. While flat `idleAssets()` is the whole NAV, so the settlement is an instant redemption paid through `completeRedeem`; it moves no tokens, so it works while halted and under an issuer freeze | `test/unit/VaultQueue.t.sol`: `test_settleQueue_freesSharesQueuedWhileIdleUnderAHaltNobodyLifts`, `test_settleQueue_freesTheLastHolderBelowOneLot`, `test_settleQueue_paysTheEscrowsAccrualToTheQueuer`, `test_settleQueue_paysWhatAnInstantRedeemWouldHave`, `test_settleQueue_revertsOutsideIdleAndWhenNothingIsQueued`, `test_settleQueue_worksUnderAnIssuerFreeze`; handler action `settleQueue` and `test_handlerReachesTheThirdPartyBucketAndFlatSettlement` (renamed from `test_handlerReachesTranchesStaleKillsAndFlatSettlement` by the redesign) in `test/invariant/VaultInvariant.t.sol` |
| 9 (F2) | **Restated 2026-09-13 as High and adversarial** (it was recorded as Medium, economic, passive); closed by the redesign | **Unsold calls are assigned by other writers' exercises, and an attacker can make that deterministic and total.** Valorem assigns an exercise across every writer of the option id, bucket by bucket, pro rata by what each wrote, not by what each sold, and the vault never exercised its own unsold options. The passive form: the vault writes 50 and sells 10, other writers write 50 and sell all of it; on an in-the-money expiry the vault expects 30 assigned while only 10 of its contracts earned a premium. The adversarial form (AUDIT-FINDINGS F-01, reproduced on the real Clear bytecode and on a fork of live 4663): after a rally, anyone writes the same option id into the vault's bucket 0 before the first exercise and self-exercises, taking `unsold × (spot − strike)` of depositor principal pro rata; and because the bucket walk is public (`settlementSeed` is the option key, never re-seeded), an attacker who exercises once and then writes into the fresh bucket can steer the draw and assign the vault on 100% of its unsold inventory. The same rally made `approveListing` refuse to relist and let anyone kill the live listing, so the conditions arrived together. Tranche writes bounded this at the unsold tranche and did not close it | **Write on fill (decision D1, A(ii); §0).** Nothing is written at `rollOpen`; every Seaport fill writes exactly its size inside `authorizeOrder`, so `written == sold` by construction and the vault has no unsold inventory to be assigned on. `writeMore` is removed. The original tranche fix is kept below as history: **Tranche writes.** `writeMore(uint112 n)` (`KEEPER_ROLE`, `nonReentrant`) tops up this cycle's claim through `clear.write(claimKey, n)` and reverts `WriteReturnedWrongClaim` unless the same id comes back. It shares one gate with `rollOpen` (`ValoremLib.write`): `Listed`, not halted, `block.timestamp < cycleExerciseTs` (`WriteWindowClosed`), `n != 0`, registry write window open, live cycle number equal to the snapshot, option approved, option asset/exercise asset/lot/window equal to the live cycle, Valorem fee off or accepted (approval sized collateral + fee and scrubbed to 0), oracle not paused and fresh, strike band re-checked at live spot, and `Policy.checkContracts(contractsWritten + n, idleAssets() + lockedAssets())`. `contractsWritten` accumulates; `lockedAssets()` and `contractsAssigned()` already read the claim's aggregate across buckets (confirmed on live Clear). `MockClear.write(claimId, n)` now tops up as upstream `6436c823` does. **Exposure is bounded only when the keeper writes per listing.** The keeper change that does (`rollOpen` writes the first tranche, `writeMore` the next once a listing sells through, `keeper/src/roll.ts` and `keeper/src/roll.tranche.test.ts` (leekzor/callhouse)) is uncommitted in that repository's working tree (§5) | Current regressions: `test/regression/AF01_UnsoldInventory.t.sol` (`test_unsteeredAttack_vaultAssignedOnlyWhatItSold_depositorLossZero`, `test_steeredAttack_buyerAsleep_fullAssignmentIsStillOnlyWhatWasSold`, `test_control_sleepingBuyerNoAttacker_collateralComesHome`, all on the real Clear bytecode), `invariant_vaultHoldsNoOptionTokens`, `invariant_assignedNeverExceedsSold`. Historical (deleted with `writeMore`): `test/unit/VaultTranche.t.sol` (12): `test_writeMore_topsUpTheSameClaim`, `test_writeMore_topUpIsListableAndSells`, `test_trancheCycle_partialAssignmentSettlesExactly`, `test_writeMore_sizesOnTheTotalAndCountsLateDeposits`, `test_writeMore_revertsOutsideListed`, `test_writeMore_revertsForNonKeeperZeroAndHalt`, `test_writeMore_revertsOnceExerciseCanStart`, `test_writeMore_revertsWhenTheRegistryHasMovedOn` (cycle changed; not approved), `test_writeMore_honoursTheValoremFeeSwitch`, `test_writeMore_revertsOnAPausedOrStaleOracle`, `test_writeMore_reChecksTheStrikeBandAtLiveSpot`, `test_writeMore_revertsWhenTheTotalPassesTheCap`; handler action `writeMore`; fork `test_fork_writeMoreTopsUpTheLiveClaim` against the real clearinghouse. No test demonstrates the assignment benefit itself (`MockClear` does not model multi-writer buckets) |
| 10 (F3) | Medium (documentation; economic) | **SECURITY.md §1 and §3 said a compromised keeper "can waste a week; it cannot take a token".** It can list at exactly the premium floor to a colluding buyer: about 1.1% of written notional per week at launch policy and 50% IV. The bootstrap admin (the deployer EOA before the Safe handover, no timelock) can `setPolicy` to 1% OTM and a 0.10% floor and grant itself `KEEPER_ROLE`: about 2.2% per week. The honest keeper prices at `max(policy floor, last fill)`, so on a thin book it undersells as well | Documentation only, by decision: §1 and §3 rewritten with the bound. The mitigations (admin timelock, higher compiled floors, a listing start delay, vol-model pricing, no deposits before the handover) are listed in §3 as open decisions and are not implemented | none (no code change) |
| 11 (F4) | Low | **`Vault.deposit` NatSpec said "a late depositor cannot be assigned against a call they were never part of writing".** False: a deposit in `Listed` is priced on a NAV that values the short call at zero, assignment losses reach every share through the share price, and since finding 9 a later tranche can be written against the new deposit directly | NatSpec corrected (0 bytes); ACCOUNTING.md §5 states the late-depositor economics. The web deposit form warns in `Listed`, more strongly when live spot is at or above `strike × (1 − minOtmBps)` (`web/components/DepositForm.tsx` (leekzor/callhouse), uncommitted) | `test_lateDepositorDuringListed_isNotWrittenAgainstButSharesTheAssignment` renamed to `test_lateDepositorDuringListed_sharesTheAssignmentThroughTheSharePrice` (`VaultAssignment.t.sol`); `test_writeMore_sizesOnTheTotalAndCountsLateDeposits` |
| 12 (F5) | Low; **removed by the redesign** (the fill gate re-prices every fill at live spot, so a stale listing is unfillable rather than snipeable, and there is no price-cut budget and no `invalidateStaleListing`; every `approveListing` spends one of three slots, cancelled or not) | **Stale fixed-price listings get sniped.** A listing lives until `cycleExerciseTs`; after a mid-week rally a buyer fills at the old premium one second before exercise opens and exercises. Repricing burnt one of three listing slots and a cancel never refunded one, so after three reprices the keeper could not relist at all, and with a dead keeper only the guardian's `invalidateAllListings` stopped it | (a) **Slots count price cuts.** `lowestListedUnitUsdg` (reset at `rollOpen`) records the lowest gross/amount authorised this cycle; the first listing, or one strictly below that price, spends a slot (`TooManyListings` when none are left) and becomes the lowest; at or above it is free. `listingsThisCycle` keeps its name for ABI stability and now counts price levels; `ListingApproved.seq` is that count, so two listings can share a `seq`. (b) **Permissionless `invalidateStaleListing()`** (`nonReentrant`): `NoLiveListing` with nothing live; a paused Stock Token oracle counts as stale; otherwise, at live spot (a stale feed reverts), it kills only when the strike is below the band floor or the gross below the premium floor for `listingAmount`, else `ListingStillValid` | `test/unit/VaultListing.t.sol`: `test_threePriceCutsPerCycleThenNoMore` (was `test_threeListingsPerCycleThenNoMore`), `test_relistAtOrAboveTheLowestPriceIsFreeEvenWithTheBudgetSpent`, `test_relistsAtOnePriceSpendOneSlot`, `test_listingBudgetResetsOnTheNextRollOpen`, `test_invalidateStaleListing_afterARallyPastTheBandFloor`, `test_invalidateStaleListing_whenTheFloorRisesAboveTheListingGross`, `test_invalidateStaleListing_whileTheOracleIsPaused`, `test_invalidateStaleListing_revertsWhileStillValidOrWithoutAPrice`, `test_invalidateStaleListing_revertsWithNoLiveListing`; `test_rollOpen_resetsTheSpentListingBudget` (`VaultRoll.t.sol`); handler action `invalidateStaleListing` |
| 13 | Low (adversarial round, PoC-confirmed); **removed by the redesign** with `invalidateStaleListing`; `approveListing` still refuses a strike below the live band floor, and the fill gate is the line of defence | **`invalidateStaleListing` could kill a listing `approveListing` had just authorised.** The kill fired on `cycleStrikeUsdg < strikeBand(spot).min`, but `approveListing` checked only the premium floor. After a 2.3% rally (spot 220 → 225, band floor 231.75 over a 231 strike) the keeper could list, anyone could kill it in the same block, and a free same-price relist was killed again: five rounds in one block in the PoC, the vault selling nothing for the rest of the week while its written inventory stayed assignable. A competing writer of the same option id is the obvious beneficiary | `approveListing` refuses a strike below the live band floor (`StrikeBelowBand`), and both paths read the floors from one `_listingFloors`, so they cannot disagree at the same spot. Only the lower bound: after a sell-off the strike above the band ceiling is safer to sell, not riskier | Current: `test_approveListing_refusesAStrikeBelowTheLiveBandFloorButNotAboveTheCeiling` (`VaultListing.t.sol`). At the checkpoint: `test_approveListing_refusesAStrikeBelowTheLiveBandFloor`, `test_invalidateStaleListing_cannotKillWhatApproveListingJustAccepted` (deleted with `invalidateStaleListing`) |
| 14 | Low (adversarial round, confirmed from the artifact) | **`Verify.s.sol` hard-coded five library link sites.** The fixes added `ValoremLib` call sites, so a byte-perfect deployment has seven; `VerifyVault._bytecode` would print FAIL and `run()` revert, breaking `script/rehearse-deploy.sh` and the launch verification, and training operators to ignore the check that catches swapped libraries | The expected count is read from the artifact's `linkReferences`, with at least one site required per library. `docs/DEPLOY.md` and this file updated | `test_verifyScript_acceptsAByteForByteDeployment` (`Smoke.t.sol`; also asserts swapped libraries still fail) |
| 15 | Low (adversarial round, PoC-confirmed) | **The first `settleQueue` draft bypassed the virtual-share offset.** `_settleQueue` paid `idleAssets() × q / totalSupply()` with no +1/+1, and `settleQueue` made that an atomic, permissionless exit while flat, halted or not. On an empty vault: seed 3 wei, donate 20 NVDA, a victim's 9.8 NVDA rounds to one share, queue and settle out for 22.35 NVDA against 20 NVDA + 3 wei paid, 2.35 NVDA of the victim's deposit (up to about 25% of a victim's deposit in general). The instant path would have paid 17.88 | `_settleQueue` pays `q × (idleAssets() + 1) / (totalSupply() + 1)`, the instant-redeem price; it cannot exceed `idleAssets()`. The inflation grief is bounded by the donation again | `test_settleQueue_doesNotMakeDonationInflationProfitable`, `test_settleQueue_paysWhatAnInstantRedeemWouldHave` (now exact); the handler's `settleQueue` asserts the +1/+1 price on every call; `test_queueEpochDrawsDownToZeroDust` re-derived by hand (one base unit more to the epoch) |
| 16 | Low (adversarial round, read from app source); **superseded by the redesign**: `CallsWritten` now fires once per FILL and `RollOpen.contractsCount` is always 0, so the app must sum fills (ACCOUNTING.md §2) | **Off-chain readers assumed one `CallsWritten`/`RollOpen` per cycle.** The indexer overwrote vault state on every `CallsWritten`, so `rollOpen(5)`, a fill of 5 and `writeMore(4)` indexed as 4 written / 0 sold / 4e18 locked against 9 / 5 / 9e18 on chain; the week's history took its size from `RollOpen` alone; the keeper ABI lacked `writeMore`, `settleQueue`, `invalidateStaleListing` and the new errors. `QueueSettled` from `settleQueue` is stamped with the closed week's cycle number | leekzor/callhouse working tree, uncommitted: `Vault:CallsWritten` accumulates a tranche into the open claim (`indexer/src/vault.ts`), history sums tranches (`web/lib/history.ts`), a flat settlement is recorded as `SettleQueue`, keeper ABI regenerated | app repo: `indexer/scripts/fork-sync/expected.test.ts` ("publishes a week written in tranches as the claim's total…"), `web/lib/history.test.ts` ("a writeMore tranche adds to the week's contracts…"). Not forge-testable |
| 17 | Low (adversarial round, PoC-confirmed); **removed by the redesign**: `listingsThisCycle` counts authorisations again (three per cycle, a relist is a reprice) and `ListingApproved.seq` is unique per cycle | **The keeper still read `listingsThisCycle` as a count of authorisations.** Its relist price never goes down, so on chain the counter stays at 1 all week: the dry run's assertions (counter equals seq; a fourth approval reverts `TooManyListings(3, 3)`) failed, every relist got the same `seq`, and `latestListingForCycle` could return an older, cheaper row whose price would then spend a real slot | leekzor/callhouse working tree, uncommitted: `listingSlotRefused` mirrors the price-cut rule, `seq` is a local monotonic per-cycle sequence (`store.nextListingSeq`), the dry run asserts the new behaviour | `test_relistsAtOnePriceSpendOneSlot` pinned the on-chain behaviour at the checkpoint (deleted with the price-cut slots); app repo: `keeper/src/policy.test.ts` ("listing slots count price cuts…"), `keeper/src/state.test.ts` ("listings: seq is a local per-cycle sequence…") |

### The 2026-09-13 audit

An internal multi-agent audit (`AUDIT-FINDINGS-2026-09-13.md` in the project handoff folder;
`callhouse-contracts-91`: 10 reviewers in parallel, a triage pass with an adversarial skeptic per
candidate and an exploit engineer for Medium and above, a gap round of 4 more reviewers; 38 agents,
20 raw findings, 5 confirmed with proofs of concept passing on the then-final `src/`). It ran on
the checkpoint `25f4328` and found the first four things below to be launch-blocking. Every proof
of concept is now a regression under `test/regression/`, one file per finding, asserting the FIXED
behaviour; where the loss lived in Valorem's bucket engine the regression runs on the real Clear
bytecode (`test/helpers/RealClearBase.sol`). Severities are the audit's. There is no external
audit (D14).

| # | Severity | Finding | Fix | Regression tests |
|---|---|---|---|---|
| AF-01 (F-01) | **High** | Anyone can take the in-the-money value of the vault's unsold call inventory by writing the same Valorem option id into its bucket and self-exercising; steerable to 100% of the unsold inventory; repeatable every in-the-money week; also let a compromised keeper write to the cap and never list, exceeding the §3 bound. Restated finding 9 above | **Write on fill** (§0, decision D1 A(ii)): `rollOpen` arms and writes nothing; every Seaport fill writes exactly its size in the vault's `authorizeOrder` zone hook; `validateOrder` reverts the fill if a token stays behind; the ERC-1155 receiver accepts only mints. The vault never holds an unsold option token, so the attack has nothing to take. `writeMore`, `invalidateStaleListing`, EIP-1271 and the price-cut slots removed. Decision D16 removed the Overcall registry at the same time | `test/regression/AF01_UnsoldInventory.t.sol` (3, real Clear): `test_unsteeredAttack_vaultAssignedOnlyWhatItSold_depositorLossZero`, `test_steeredAttack_buyerAsleep_fullAssignmentIsStillOnlyWhatWasSold`, `test_control_sleepingBuyerNoAttacker_collateralComesHome`; `test/unit/VaultWriteOnFill.t.sol` (20); `test/unit/VaultRealSeaport.t.sol` (13, real Seaport 1.6 runtime, every fulfilment path); `invariant_vaultHoldsNoOptionTokens`, `invariant_assignedNeverExceedsSold`, `invariant_longSupplyIsUnexercisedCollateral` with the handler's `thirdPartyWrite`/`thirdPartyExercise`; fork `test_fork_writeOnFillAgainstLiveSeaportAndClear`, `test_fork_assignedWeekSettlesOnLiveClear` |
| AF-02 (F-02) | Medium | A USDG pause or blocklist of the vault in an assigned week reverted `clear.redeem` inside `rollClose`, the only exit from Listed/Exercisable, freezing all principal and the queue for as long as it lasted. The recon widened the trigger set: Clear frozen on USDG, Clear's USDG burnt by a supply controller, and an NVDA-side blocklist of the vault (which bites in every week that is not fully assigned) | **Stranded-claim state machine** (§2; ACCOUNTING.md §5): low-level redeem with a gas-starvation guard, Idle with the claim kept, per-epoch stranded entitlements, permissionless `retryStrandedClaim`, deposits and instant redemption shut meanwhile, `rollOpen` refused, dust ≤ 1 wei per owner per generation | `test/regression/AF02_UsdgFreezeRollClose.t.sol` (9 on the mock, the same 9 on the real Clear): `test_usdgPause_assignedWeek_strandsThenRecovers`, `test_vaultFrozenOnUsdg_assignedWeek_strandsThenRecovers`, `test_clearFrozenOnUsdg_assignedWeek_strandsThenRecovers`, `test_clearUsdgBurntBySupplyController_assignedWeek_strandsUntilRefunded`, `test_vaultBlockedOnNvda_unassignedWeek_strandsThenRecovers`, `test_control_unassignedWeekClosesUnderAVaultUsdgFreeze`, `test_gasStarvedRollCloseNeverStrands`, `test_restrandInALaterGenerationWithAnUncollectedEarlierGenOwner`, `test_reQueuingWhileStrandedStagesTheClaimShareWithoutPayingIt`; `invariant_strandSharesAreConserved`, `invariant_depositGateTracksTheReserve`, `invariant_phaseSanity`, `test_handlerReachesAStrandAndRecovers`, `test_handlerReachesANvdaBlocklistStrand`; fork `test_fork_usdgFreezeStrandsTheCloseAndRetryRecoversIt` under the real USDG `ASSET_PROTECTION` role |
| AF-03 (F-03) | Medium | `completeRedeem` paid the Stock Token and USDG legs atomically, so a USDG pause or blocklist trapped settled queuers' principal while non-queuers redeemed instantly; a queuer whose own receiver is USDG-frozen was trapped the same way | **Split payout legs**: the asset leg by `safeTransfer`, the USDG leg by a raw call that on failure leaves the USDG booked (`UsdgLegDeferred`) for a later `completeRedeem`, to the same or another receiver; a call with nothing left but a blocked USDG leg reverts `UsdgLegBlocked` | `test/regression/AF03_CompleteRedeemLegs.t.sol` (5): `test_usdgPause_paysTheNvdaLegAndDefersTheUsdgLeg`, `test_vaultFrozenOnUsdg_stillPaysQueuedPrincipal`, `test_frozenReceiver_getsTheNvdaAndCollectsUsdgElsewhere`, `test_healthyTokens_payBothLegsInOneCall`, `test_stockPause_blocksQueueUsdgBehindThePrincipal`; the handler's `completeRedeem` asserts the deferred leg stays booked in full |
| AF-04 (F-04) | Low | Write sizing ignored Valorem's 15 bps engine fee; above ~99.85% utilisation with the fee on and accepted, the fee came out of `reservedAssets` | `MAX_UTILIZATION_CEIL_BPS` 10,000 → **9,985** (`Policy.sol`), the fee valued at spot inside the fill's premium floor, and a post-write **`ReserveBreached`** check that the balance still covers `reservedAssets` | `test/regression/AF04_FeeSizing.t.sol` (4): `test_governanceCannotSetFullUtilisation`, `test_feeStaysInsideTheFreeBalanceAtTheCeiling`, `test_reserveBreachIsCaughtAfterTheWrite`, `testFuzz_ceilingLeavesRoomForTheFee`; `test_fill_acceptedFeeRaisesTheFloorPullsTheFeeAndScrubsTheApproval` |
| AF-05 (F-05) | Low | The saturating `balance − reservedAssets` hid a Stock Token `adminBurn` shortfall: NAV read 0 in Idle and was overstated in Listed, deposits stayed open, and later depositors funded earlier settled redeemers first come, first served | **Honest NAV** `max(balance + locked − reserved, 0)`, one `DepositsClosed` gate that also shuts whenever `balance < reservedAssets`, and a **pro-rata reserve haircut** (`ReserveHaircut`) so every uncollected reserved claimant takes the same fraction whatever order they collect in. **Follow-up:** a compiled-in **share-price floor** in the same gate (`MAX_SHARES_PER_ASSET` 1e6: no deposit or mint while `totalSupply() > totalAssets() × 1e6`, so a book burnt to nothing with its shares outstanding is not sold to a newcomer at one wei a share and the share supply stays bounded), and queue and index maths that never form `shares × accUsdgPerShare` in 256 bits (`AccDebt` quotient/remainder, `Math.mulDiv`), so an account that queued can always settle | `test/regression/AF05_BurnShortfall.t.sol` (7): `test_idle_adminBurnShortfallIsSharedByTheReserveAndClosesDeposits`, `test_listed_shortfallIsHonestlyPricedAndClosesDeposits`, `test_listed_returningCollateralRefillsTheReserveAndReopensDeposits`, `testFuzz_haircutFractionIsTheSameForEveryClaimant`, `test_deadBook_sharePriceFloorClosesDepositsAtExactlyOneMillionSharesPerBaseUnit`, `test_deadBook_queueStillSettlesAndCompletesAndTheBookIsRebornOnceEmpty`, `test_queueMaths_doNotNeedShareTimesIndexToFit256Bits`; `invariant_noFreeShares`, `invariant_reservesAreReal`, `invariant_depositGateTracksTheReserve`, `test_handlerReachesABurnShortfallAndTheHaircut` |

Two items the audit recorded as plausible and unproven are accepted below rather than fixed: the
USDG wipe re-anchor and the split-multiplier feed discontinuity.

### The 2026-09-14 review

A single-reviewer internal pass over `src/` at `79cee08` (`AUDIT-FINDINGS-2026-09-14.md` in the
project handoff folder): no Critical, High or Medium; one Low with a proof of concept, fixed below;
one Informational, the admin's hold on our own Clear's fee switch, now in the admin rows of §3.

| # | Severity | Finding | Fix | Regression tests |
|---|---|---|---|---|
| L-01 | Low | Seaport transfers the offer item before the consideration, so a contract buyer's `onERC1155Received` ran after `authorizeOrder` had written its fill and before its USDG reached the vault. A `deposit` from inside that hook passed every gate and its harvest checkpoint saw no new USDG, so the new shares took a pro-rata slice of the premium of the very fill paying for them (PoC: alice 20e18, a buyer fills 10 contracts at 1.90 and deposits 20e18 in the hook; alice is left 9.025000 of the fill's 18.050000 net USDG). Premium only, and not a profit for the buyer after the fee; the one ordering that sidestepped the deposit checkpoint | `_depositRefused` reason 7: no deposit or mint once any fill of the transaction has written (`_fillArmed`, the transient flag the fill baseline already kept); `maxDeposit`/`maxMint` quote zero from the same predicate. Sticky for the rest of that transaction by design. `foundry.toml` sets `isolate = true` so a test's calls run as separate transactions, as on chain. No ABI change | `test/regression/L01_InFillDeposit.t.sol` (2): `test_depositInsideTheBuyersReceiveHookIsRefused`, `test_control_theSameDepositAfterTheFillIsOpenAndEarnsNoneOfIt`; `test/unit/VaultRealSeaport.t.sol` `test_inFillDepositFromTheBuyersReceiveHookIsRefused` on the real Seaport 1.6 runtime; `test_buyerReenteringTheVaultMidFillIsBlocked` now asserts the refusal |

### Known and accepted, not bugs to fix

- **The Stock Token issuer can burn, pause, blocklist, pause the oracle, move the multiplier and
  upgrade** (§3), each from one key with no delay, and can terminate the Series on 30 days'
  notice. Settlement then stops, or NAV falls. This is disclosed to depositors and mirrored
  honestly by the UI; the contracts make sure none of it TRAPS anyone (queueing, `settleQueue`,
  USDG claims and the stranded-claim retry keep working; only token-moving legs stop; a burn is
  shared by the reserve pro rata and shuts deposits, AF-05). There is no technical mitigation for
  the asset itself — that is the asset.
- **USDG's operational powers sit with one EOA and act instantly** (§3): pause, freeze, wipe,
  burn-from. Only the upgrade is behind the 24 h timelock, whose proposer and executor are the
  same key. The fee push is best-effort, the payout legs are split and the close strands rather
  than bricks because of this. Two consequences are accepted as they are: a **wipe of the vault's
  USDG re-anchors `usdgAccounted`** to the lower balance, so later premium backs older claims first
  come, first served (the audit's plausible-unproven Low; reachable only through the issuer);
  and premium or strike USDG frozen or wiped is simply gone for the holders it was owed to.
- **The price feed can lag the token** (the audit's plausible-unproven Medium claimed, Info on
  review, "split-multiplier discontinuity"): a Stock Token multiplier step applies at
  `effectiveAt` with no feed round, and the feed re-prints only on its 0.5% deviation trigger
  (≈11.8 h after NVDA's 2026-09-10 dividend step). For those hours the band and premium floor are
  priced on a stale per-token basis. Under D16 no third-party ladder acts on the same wrong feed;
  the exposure is the keeper arming or a buyer filling inside that window, bounded by the band.
  Accepted at the contract level; the keeper is expected to skip such windows. The frozen weekend
  answer likewise predates the close by up to a few hours (`Vault.maxPriceAge` NatSpec).
- **There is no registry any more** (decision D16). The option type is validated from the
  clearinghouse (§0); the only third-party key left on the path is Clear's `feeTo`, bounded to the
  opt-in fee switch, and removable by deploying our own instance. Nothing depends on Overcall's
  API, book, fee configuration, operator or terms.
- **Upstream Valorem is dormant** (last commit 2023-11; Zellic's January 2023 findings 3.2/3.3 on
  the public, seedable bucket walk were never fixed). The Clear bytecode is immutable and has no
  admin beyond `feeTo`; the vault's design assumes exactly the assignment semantics the recon
  verified on chain (`test/unit/MockClearDiff.t.sol` keeps the mock faithful to them), and there is
  nobody to patch a Clear bug for us.
- **Pricing discretion leaks value inside policy.** A compromised keeper, a compromised bootstrap
  admin, or an honest keeper on a book with no fills can sell at the premium floor, below fair
  value. §3 quantifies it and lists the mitigations that were considered and not built.
- **Valorem assigns across all writers of an option id, pro rata by amount written, and the walk
  is public** (Zellic Jan-2023 3.2/3.3 were never fixed upstream). Under write on fill the vault
  has written exactly what it sold, so the most a third-party writer and exerciser can do is assign
  the vault fully on the calls it was paid a premium for: the priced covered-call exposure, not a
  loss beyond it (`AF01_UnsoldInventory`, steered and unsteered).
- **Anyone can settle a flat queue, including someone else's entry.** An entry cannot be withdrawn
  once queued anyway, and `settleQueue` pays it the instant-redeem price at that moment, so a
  third party choosing the moment gains nothing and moves no value.
- **The 4663 sequencer is a single operator with compliance filtering, and there is no uptime
  feed** (§3). An outage does NOT surface through `maxPriceAge` unless it outlasts 4 days; during
  one, nothing happens at all, which is the safe direction for writes and the wrong one for exits.
  A restriction of the vault's address, or censorship of its callers, has no on-chain remedy short
  of the 4-day force-inclusion path, which may itself be filtered. Disclosed.
- **No upgradeability here.** A real bug means Vault v2 and a migration, communicated in
  advance. That is a deliberate choice, not an omission.

## 5. Open questions being closed before launch

Tracked in `tasks.md` (leekzor/callhouse) "Open questions":

1. **Overcall's order book is not a venue for this vault.** Its schema requires open orders with
   zone 0 and pre-held inventory; the vault lists restricted orders with itself as zone and holds
   no inventory. Sales go through the self-hosted fill page and any Seaport fulfil path. Closed by
   decision D1; L-04 was dropped (D2 = b).
2. **Keeper prices at exactly the policy floor** — an upward oracle tick between the keeper's
   read and the vault's authorisation reverts `PremiumBelowMinimum` (or `StrikeBelowBand`, since
   `approveListing` also re-checks the band floor). Self-heals next tick; a margin is under
   consideration. Pricing at the floor is also the leakage in §3.
3. **Deposit-time harvest checkpoint gas cost** — to be measured on the first live week.
4. **The keeper, indexer and web are not yet ported to write on fill.** `rollOpen(optionId)`,
   PARTIAL_RESTRICTED orders with the vault as zone, an empty signature, no Overcall POST, and
   fills detected from `OrderFulfilled` (a batch that skips the vault's order still succeeds) are
   the app-side changes; until they land the vault can be operated only by hand.
5. **The open decisions in §3**: an admin timelock, higher compiled floors, a listing start delay,
   vol-model pricing, and no deposits before the Safe handover.

## 6. Reporting

If you believe you have found a vulnerability, do not open a public issue. Send it to
**security@callhouse.finance**. The same address is published, machine-readably, at
`https://callhouse.finance/.well-known/security.txt` (RFC 9116) and on
`https://callhouse.finance/legal#reporting`. Both read `NEXT_PUBLIC_SECURITY_CONTACT_EMAIL` from
`lib/legal.ts` (leekzor/callhouse-site), which was set 2026-09-13; the mailbox is a Cloudflare
Email Routing forward to the operator.

A bug bounty with a dedicated disclosure channel opens in mainnet week 2 (`tasks.md` (leekzor/callhouse) E-07). Until
then the contracts are unaudited and a report is a favour, not a claim.
