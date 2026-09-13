# Security

The threat model, the properties the contracts enforce, and the record of what the 2026-09-12
adversarial review found and what was done about it.

> **Paths.** Paths resolve from the root of this repository, leekzor/callhouse-contracts. A path
> followed by (leekzor/callhouse) lives in the app repository (keeper, indexer, web, ops and the
> project-wide docs), which mounts this repository as a git submodule at `contracts/`; a path
> followed by (leekzor/callhouse-site) lives in the marketing site repository. Both resolve from
> that repository's root.

Read `docs/ARCHITECTURE.md` (leekzor/callhouse) §2 for the trust boundaries and
[docs/ACCOUNTING.md](docs/ACCOUNTING.md) for the money maths. The per-alert response runbooks
are in `ops/alerts.md` (leekzor/callhouse).

---

## 1. The one-sentence model

**No off-chain component can move money.** The vault is the Valorem writer and the Seaport
offerer; it authorises listings by hash on chain. The keeper proposes, the vault validates.
A fully compromised keeper key can waste a week; it cannot take a token.

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
  not on anyone calling `lockBook`. After it, `deposit`/`mint` revert `DepositsClosedForCycle`
  and `maxDeposit`/`maxMint` return 0. A second, clock-independent line refuses deposits
  whenever unclaimed assignment proceeds exist (NAV has already fallen by the collateral that
  left). See §4, finding 1.
- **Cycle tenor is capped at 21 days** by a compiled-in constant (`MAX_CYCLE_TENOR`). The
  registry that sets the weekly cycle is a single third-party EOA; a hostile or fat-fingered
  cycle must produce a skipped week, not a years-long lock on depositor principal.
- **The written option's window must equal the cycle's window.** The deposit gate rests on
  "assignment cannot happen before `cycleExerciseTs`", which only holds if the option actually
  written shares that timestamp. `rollOpen` reverts `OptionWindowMismatch` otherwise.
- **The Valorem engine fee is opt-in.** While `clear.feesEnabled()` is on and governance has
  not accepted, `rollOpen` reverts `ValoremFeeNotAccepted`. 15 bps of notional on a weekly
  out-of-the-money call is a governance decision, not a keeper one.
- **The protocol fee push is best-effort.** A blocklisted fee recipient, a paused USDG, or a
  recipient that reverts on receive must not freeze `rollClose` — the only function that
  redeems the claim and settles the queue. The fee accrues into `pendingFeeUsdg` and is
  recoverable by anyone through `sweepFee()`, which always pays the stored recipient.
- **Every payout is clamped to what is actually backed** (`_usdgAvailableForHolders`), and
  accounting is anchored on a measured USDG balance, not an arithmetic identity. The index
  drift costs dust, never principal. See ACCOUNTING.md §4.
- **Rounding always favours the vault** in share maths (ACCOUNTING.md §3).
- **The invariants in ACCOUNTING.md §7** are asserted continuously by the stateful suite.

## 3. What a compromise of each key buys

| Key | Power | Worst case |
|---|---|---|
| Keeper (hot) | propose strike/size/order, call the rolls | a wasted week and gas; the vault re-validates every field |
| Guardian | halt writes, invalidate all listings | denial of new writes until the Admin Safe unhalts; exits stay open |
| Admin Safe (2/3) | policy inside caps, fee recipient, Valorem fee acceptance, deposit cap | degraded terms inside compiled-in caps; still cannot touch a token |
| Registry owner (third-party EOA) | sets the weekly cycle for the whole market | a skipped week; the band, the tenor ceiling and the option-window check refuse anything worse |
| Stock Token issuer | freeze transfers, pause the oracle, upgrade the proxy | settlement stops. Disclosed, not coded around — see §5 |

## 4. The 2026-09-12 adversarial review

An internal adversarial review run across 13 surfaces (vault core, share accounting, phase
machine and reentrancy, the Valorem and Seaport adapters, the order library, the distributor,
access control, token integration, USDG distribution, economic/MEV, and the keeper, indexer
API and web surfaces). 72 raw findings were raised; **51 survived adversarial refutation**
(each finding had to produce a concrete, reachable loss or lie to survive). Everything below
is fixed and carries a regression test in `test/unit/VaultSecurity.t.sol`, which
documents each attack in full.

This was an internal review, not an external audit. Engaging one is still on the plan
(`tasks.md` (leekzor/callhouse) E-05/E-06), along with the fork rehearsal weeks.

### Fixed

| # | Severity | Finding | Fix |
|---|---|---|---|
| 1 | **Critical** (found independently by four surfaces) | Assignment crashes NAV inside the exerciser's own transaction: Valorem takes the collateral and leaves strike USDG in the claim, with no callback. While the vault sat in `Listed` — legitimate for the whole 24-hour exercise window — anyone could exercise, mint shares against the crashed NAV in the same block, and collect a pro-rata slice of the strike proceeds at `rollClose`, taken from the depositors who were actually assigned. Principal round-trips untouched, so the extraction was riskless | Deposit window closes on `cycleExerciseTs`, whether or not `lockBook` is called and whether or not the keeper is alive; plus a clock-independent refusal whenever unclaimed assignment proceeds exist. `test_critical_*` (3 tests) |
| 2 | High | The registry's `setCycle` bounds expiry only from below. A years-long expiry would lock up to 95% of depositor collateral in Valorem for the whole tenor, with no redemption path for anyone | `MAX_CYCLE_TENOR = 21 days`, compiled in; `rollOpen` reverts `BadCycleWindow` before any collateral moves. `test_high_refusesAnAbsurdlyLongCycleBeforeAnyCollateralMoves`, `test_high_normalWeeklyCycleStillWrites` |
| 3 | High | The vault trusted the registry to have validated the option it wrote. Writing an option whose exercise/expiry differed from the cycle's silently broke the deposit gate's "no assignment before `cycleExerciseTs`" premise | `rollOpen` reverts `OptionWindowMismatch` unless the option's window equals the cycle's. `test_high_refusesAnOptionWhoseWindowDiffersFromTheCycle` |
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

### Known and accepted, not bugs to fix

- **The Stock Token issuer can freeze transfers and pause the oracle.** Settlement then stops.
  This is disclosed to depositors and mirrored honestly by the UI; the contracts make sure a
  freeze never traps anyone (queueing and USDG claims keep working; only token-moving legs
  stop). There is no technical mitigation — that is the asset.
- **USDG and the Stock Token are upgradeable proxies.** Their admin keys are outside our
  control. The fee push is best-effort partly because of this.
- **The registry owner is a single EOA.** Bounded by §2: worst case is a skipped week.
- **The 4663 sequencer is centralised** and has no Chainlink uptime feed. An outage surfaces
  as a stale price, which blocks writes — the safe direction.
- **No upgradeability here.** A real bug means Vault v2 and a migration, communicated in
  advance. That is a deliberate choice, not an omission.

## 5. Open questions being closed before launch

Tracked in `tasks.md` (leekzor/callhouse) "Open questions":

1. **EIP-1271 vs Overcall's live validator** — never exercised against their production server.
   One real 1-contract listing is posted before launch (L-04); the self-hosted fill page is
   the fallback.
2. **Keeper prices at exactly the policy floor** — an upward oracle tick between the keeper's
   read and the vault's authorisation reverts `PremiumBelowMinimum`. Self-heals next tick; a
   margin is under consideration.
3. **Deposit-time harvest checkpoint gas cost** — to be measured on the first live week.

## 6. Reporting

If you believe you have found a vulnerability, do not open a public issue. The disclosure
address is published at `https://callhouse.xyz/.well-known/security.txt` (RFC 9116) and on
`https://callhouse.xyz/legal#reporting`. Both read `NEXT_PUBLIC_SECURITY_CONTACT_EMAIL` from
`lib/legal.ts` (leekzor/callhouse-site); until that variable is configured and the site rebuilt, no address is
designated, `security.txt` returns 404 on purpose, and the legal page says so in words. Setting
it is a launch step in `ops/launch-legal.md` (leekzor/callhouse).

A bug bounty with a dedicated disclosure channel opens in mainnet week 2 (`tasks.md` (leekzor/callhouse) E-07). Until
then the contracts are unaudited and a report is a favour, not a claim.
