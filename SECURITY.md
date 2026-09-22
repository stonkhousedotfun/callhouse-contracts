# Security

Two parts. **[v2](#v2)** first: the status of the v2 contracts (`src/v2/`), what stands behind them,
and their threat model in summary, with the full detail in
[docs/V2-ARCHITECTURE.md](docs/V2-ARCHITECTURE.md). Then **the v1 record** (from
[§0](#0-the-2026-09-13-redesign-write-on-fill-no-registry)): the threat model, the properties the v1
contracts enforce, and what the 2026-09-12 adversarial review, the 2026-09-13 documentation review
and the 2026-09-13 second pass found and what was done about it, kept as written with its dates.
[Reporting](#6-reporting) covers both.

> **Paths.** Paths resolve from the root of this repository, stonkhousedotfun/callhouse-contracts. A path
> followed by (stonkhousedotfun/callhouse) lives in the app repository (keeper, indexer, web, ops and the
> project-wide docs), which mounts this repository as a git submodule at `contracts/`; a path
> followed by (stonkhousedotfun/callhouse-site) lives in the marketing site repository. Both resolve from
> that repository's root.

---

## v2

### Status

- **Unaudited.** No external audit report of v2 exists at this commit, and this repository links to
  none. That is a statement about today, not a policy: owner decision **V3-D33** (2026-09-19,
  `v8-plan/00-MASTER-2026-09-19.md` §2) withdrew the earlier decision that no audit would be
  commissioned, and **INTERFACE_VERSION 8 launches verified and audited**. The audit is commissioned by
  `OWN8-12` and its report is linked from this page by `C8-14`; while no link is here, no third party
  has reviewed this code. V3-D33 supersedes both the owner's 2026-09-16 decision in the v2 plan and the
  2026-09-15 note in [§0](#0-the-2026-09-13-redesign-write-on-fill-no-registry) that an external audit
  was pending, and it is what [the v1 record's D14](#4-the-2026-09-12-adversarial-review) now reads
  against.
- **The v8 set is deployed on chain 4663.** It was deployed on 2026-09-22 from commit
  `aeab59779b994ddad97df5b10c9b2383defab0b0`, whose `src/` tree is identical to this commit's, at the
  registry's `v2.deployBlock` 69512673. `Clearinghouse` is `0x1A67948175DFf13426F0d61bfB483579D2ff2EeE`
  and `createPaused()` reads `false`. The launch set is NVDA and SPCX; the other markets in the app
  registry are not part of it. **So this page describes code that is running on chain today.**
  Two qualifications, both measured rather than planned:
  `script/artifacts/v2-4663/manifest.json` has **not** been re-pinned — it still records the v7 set at
  `v2.deployBlock` 65780341 from `1b087550cfc92fd1878e5f1c0feaabaa91dc415f`
  ([docs/DEPLOY-V2.md](docs/DEPLOY-V2.md), "Pinned deployed runtimes") — so the pinned-runtime check
  does not yet cover a v8 address. And the **v7** set is still live beside v8 and has **not** been
  frozen: its `Clearinghouse` `0x22dEf851cD1a3B04Ad7d232bE786d76E6944d424` still returns
  `createPaused() == false`. Freezing it and running it off is owner decisions V3-D1 and V3-D8, and
  has not happened.
- **No bug bounty** ([§6](#6-reporting)). V3-D33 puts a follow-up review and a bug bounty at $1 M TVL.
- **The v8 migration is half landed in this tree, and this page says where.** `OrderBook` still carries
  v7's `onlyRole(DEFAULT_ADMIN_ROLE)` on all five of its setters
  (`src/v2/OrderBook.sol:573,587,597,626,637`, until `C8-03` and `C8-13`), and the superseded
  `UniV3PayoutAdapter` never migrates at all (`src/v2/periphery/UniV3PayoutAdapter.sol:111`;
  `PayoutRouter` replaces it). Every other target is a `Managed` against the one manager
  ([V2-ARCHITECTURE §2.1](docs/V2-ARCHITECTURE.md#21-roles)). Where the role manifest and the bytecode
  disagree, the manifest is the target and the source is the fact; the rest of this page names which is
  which.

### What stands behind v2

**No gate figure on this page was produced by the commit that wrote it.** Under the owner's build-mode
directive of 2026-09-19 the suites are written but are not run as a condition of shipping, so this
section names what each gate covers and quotes no test count, check count or gas figure. The counts
that stood here before were measured on branch `v2` on 2026-09-17, at INTERFACE_VERSION 7, on a tree
that has since replaced four per-contract `bytes32` role tables with one `AccessManager` and added a
FeeSplitter, a PayoutRouter, a V4BuybackExecutor, a fee-discount seam, a just-in-time funding hook and
mint-on-fill. Carrying them forward would have been a claim about code they never ran against; they are
in git history. What the launch verification pass has to re-measure is listed in the deferred-verification ledger,
`stonkhouse-plan/status/DEFERRED-VERIFICATION.md`, in the project plan folder beside this repository.

| Gate | What it covers |
|---|---|
| `forge test` | the v2 unit suites per contract; `LifecycleTest` (a weekly ladder of calls and puts, every wallet, ledger and fee balance checked against an independent model after every step); `V2GasTest`; `V2DocsNumbersTest` (the figures the v2 docs quote); the OrderBook suites rerun against the real Clearinghouse; `ClearinghouseMintFeeTest` and `C05MintFeeTest` (the collateral-rent charge, its pro-rata refund and its settle accrual, with the two c05 avoidance PoCs flipped); `AutoRollerStaleTest` and `AutoRollerTimingTest` (the stale cancel, the in-the-money reprice refusal and the open grace, with the two c16 PoCs flipped); `MakerVaultOutflowTest` (the outflow cap, with the c14 and c21 PoCs flipped); and, for INTERFACE_VERSION 8, the access-matrix test that compares `script/v2/roles.v8.json` with `src/v2/access/V8Roles.sol` and with what each target actually restricts |
| the invariant suite, inside `forge test` | `V2InvariantTest` (Clearinghouse invariants 1-5, 2′ and 7 — held rent always covers every refund it owes — book invariants B1-B3 and invariant 6, and that every expiry settles on the configuration its first series pinned: [docs/V2-ACCOUNTING.md §10](docs/V2-ACCOUNTING.md#10-the-invariants-as-asserted), [V2-ARCHITECTURE §9](docs/V2-ARCHITECTURE.md#9-where-the-numbers-come-from)); plus `AutoRollerStaleInvariantTest` and `MakerVaultOutflowInvariantTest`. Driven under oracle faults, mid-life reconfiguration of the market and its sources, the pinning attacks, USDG pause and freeze, guardian pauses, veto and admin resolve, and unauthorised attempts on other accounts |
| `FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC` | against live chain 4663 (run serially, `-j 1`: the public RPC rate-limits parallel suites): a two-source settlement on the real NVDA feed history and pool, the observation-ring depth `setPool` requires, a feed-only weekly through the delay, the feed walk, payout conversion through the live SwapRouter02, the live Data Streams VerifierProxy, the devnet deploy, the v1 freeze, and the pinned runtimes of the live v7 set |
| `forge fmt --check src/v2 script/v2 test/v2` | formatting |

The commands are in [V2-ARCHITECTURE §9](docs/V2-ARCHITECTURE.md#9-where-the-numbers-come-from).

What the tests do not establish: that the Admin Safe's signers are honest (they are trusted, see
below), that keepers show up, how the real issuers, sequencer and feed operators behave beyond what the
mocks and the fork model, and the gas of a real signed Data Streams verification. Under build mode they
do not establish that they pass, either.

### The model in one paragraph

No role can move, freeze or seize a user's free collateral or tokens, and `close`, `withdraw`,
`redeem`, ERC-1155 transfers, order `cancel`, `prune` and `claimOwed` have no pause. From
INTERFACE_VERSION 8 every privileged function in the system is gated by **one** OpenZeppelin
`AccessManager` holding **eleven** roles, not by a `DEFAULT_ADMIN_ROLE` inside each contract: the
manifest is `script/v2/roles.v8.json` and `src/v2/access/V8Roles.sol` is its compiled mirror. Nine of
the eleven go to a **2-of-3 Admin Safe** and the instant ones to four hot bot keys
(`script/v2/roles.v8.json:42-58`); the Safe being 2-of-3 with all three keys the owner's is owner
decisions V3-D1 and V3-D10, which nothing in this repository enforces — the manifest knows only an
address. The **execution delay belongs to the lane, not to the key**: 48 h on `ADMIN` and
`FEE_MANAGER`, 72 h on `MARKET_FEE_MANAGER`, 24 h on `CONFIG_ADMIN` and `TREASURY_ADMIN`, 1 h on
`LISTING`, and 0 on `OPS_ADMIN`, `GUARDIAN`, `PRICER`, `QUOTER` and `BUYBACK`
(`script/v2/roles.v8.json:16-28`, `src/v2/access/V8Roles.sol:91-101`). A delayed call is scheduled on
the manager, sits in public for its delay, and only then executes; while it waits the guardian can
cancel it — for every delayed lane except `ADMIN`'s, which no guardian can touch
([§2.3](docs/V2-ARCHITECTURE.md#23-every-guardian-power-and-its-worst-case)). An `OrderBook` fee change
then waits its own compiled `FEE_CHANGE_DELAY` of **48 h** on top
(`src/v2/interfaces/V2Constants.sol:60`, raised from 24 h by owner decision V3-D13), so it is visible
for 48 h before it can even be scheduled on the book and takes another 48 h to bite. `CONFIG_ADMIN`
configures which price sources settle an expiry, but only until the expiry's first series is created:
that series pins the oracle's sources and parameters and each source's feed and pool (owner decision
2026-09-17, closing C2-16 finding 1), so no role can re-price a live series. Pinning fails closed: a
series is created only with every source pinned, and a pin made outside a series creation (through the
Clearinghouse pointer or a source's allow-list) can only stop series creation on that expiry, never be
settled on ([V2-ARCHITECTURE §6.6](docs/V2-ARCHITECTURE.md#66-the-admin-key)). Over a live series what
is left is `adminResolve` inside the band of the recorded prices from expiry + 48 h (any price only
when no pinned source ever answered; within a factor of 1.25 of a lone recorded price the guardian
vetoed, from expiry + 7 days) — itself a `CONFIG_ADMIN` call, so scheduled 24 h in public first — and
lifting the guardian's veto, which is instant. Configuration changes reach only expiries without
series, whose pinned configuration is public before anyone trades them. The guardian can only stop new
risk, hold uncorroborated settlements, clear a payout route and cancel a scheduled operation.

### What a compromise of each v2 key buys

Roles are the `uint64` ids of `script/v2/roles.v8.json:3-15`; the delay beside each is that role's
execution delay from `script/v2/roles.v8.json:16-28`. The **Admin Safe holds every role in this table
except `PRICER` and `BUYBACK`** (`script/v2/roles.v8.json:43-52`), so "a compromise of the Safe" is the
union of its rows, each still paying its own delay, with `GUARDIAN` able to cancel everything but
`ADMIN`'s and `OPS_ADMIN`'s. The four hot keys hold one instant role each and nothing else.

| Key | Worst case | Detail |
|---|---|---|
| `ADMIN` (id 0, 48 h) — Admin Safe | the manager itself: grant or revoke any role, remap any `(target, selector)`, change any role admin or role guardian. **No target function is mapped to it** (`script/v2/roles.v8.json:204`), so it reaches nothing directly — it reaches everything by first giving itself the role that does, 48 h later and in public. **No guardian can cancel an `ADMIN` operation**: `AccessManager` never lets `ADMIN_ROLE` be given a role guardian, and the manifest sets none (`src/v2/access/V8Roles.sol:20-21`, [§2.3](docs/V2-ARCHITECTURE.md#23-every-guardian-power-and-its-worst-case)). That lane is protected by publicity and by a second `ADMIN` transaction, and by nothing else — accepted, V3-D24, below | [V2-ARCHITECTURE §2.1](docs/V2-ARCHITECTURE.md#21-roles) |
| `FEE_MANAGER` (1, 48 h) | the book's fees to their ceilings — seller fee `PREMIUM_FEE_CEIL_BPS` 10 % of premium, taker fee `min(TAKER_FEE_FLAT_CEIL` 1 USDG`, TAKER_FEE_CAP_CEIL_BPS` 10 %`)` (`src/v2/interfaces/V2Constants.sol:75,82,84`) — including on resting orders, 48 h after the scheduled change becomes executable and 48 h after that again (`FEE_CHANGE_DELAY`); the maker registry and the discount module the book reads (both bounded: a rebate is clamped so a take's rebates never exceed its taker fee, a discount is clamped to `MAX_DISCOUNT_BPS` 50 % of the taker fee and read once with `DISCOUNT_READ_GAS` 30,000, `src/v2/interfaces/V2Constants.sol:105-112`); the keeper bounties and their daily cap; the FeeSplitter's burn share, per-buy cap and conversion slippage | [§2.2](docs/V2-ARCHITECTURE.md#22-every-admin-power-and-its-worst-case) |
| `MARKET_FEE_MANAGER` (2, 72 h) | the exercise fee and the collateral-rent dial, both pinned into series created **afterwards** only. Ceilings: exercise fee `EXERCISE_FEE_CEIL_BPS` 200 bps; rent `MINT_FEE_CEIL_PPM` **5,000 ppm — 0.5 % of the locked collateral per `MINT_FEE_PERIOD` of 7 days of remaining life** (`src/v2/interfaces/V2Constants.sol:77,99,68`). v8 launches every market and the default at **rent 0** (owner decision V3-D18: writers pay the 5 % premium fee on first sale and nothing else; the tested dial stays in the contract, set to 0), so the ceiling is not a multiple of any live rate — it is the whole distance from charging writers nothing to charging them 0.5 % a week. Existing series and resting orders keep the rate pinned at their creation, and anyone can pre-create series up to `MAX_TENOR` 45 days out at today's rate (`:52`), so a raise reaches those only at their next creation. 72 h is the longest lane in the manifest precisely because this row is the one that can start charging a fee that does not exist today | [§2.2](docs/V2-ARCHITECTURE.md#22-every-admin-power-and-its-worst-case) |
| `CONFIG_ADMIN` (3, 24 h) | the settlement configuration of every expiry that has no series yet, chosen in public (a series is created only on a pin equal to the configuration current at its creation; a pin made outside a series creation can only block that expiry's series: `PinnedSettlementTest.test_hiddenPrePin_throughTheClearinghousePointer`, `PinnedSettlementTest.test_hiddenPrePin_throughEachSourceAllowList`); stopping series creation by breaking the pin wiring; new series pinned to an oracle that never settles or settles anywhere; for live series only `adminResolve` inside the recorded band from expiry + 48 h (any price when none of the expiry's pinned sources ever answered; after a veto of an expiry with a single ok price, any price within a factor of 1.25 of it from expiry + 7 days, `SettlementOracleResolveTest.test_adminResolve_heldSingleSource_widensAfterSevenDays`); the minter allow-list, so a venue that mints at a price the protocol never sees; the payout routes, so ITM call conversions paid up to 300 bps under value (bound plus route fee; a payout adapter that misreports its route fee moves a floor by at most 100 bps, `ClearinghousePayoutTest.test_floor_routeFeeClampedToMax`; the USDG is counted at the Clearinghouse, so an adapter cannot meet the floor with the holder's own USDG pushed to the holder during the swap, `ClearinghousePayoutTest.test_convert_adapterPayingWithTheHoldersOwnUsdg_paysInKind`, sweep contracts-c30); the funding allow-list | [§2.2](docs/V2-ARCHITECTURE.md#22-every-admin-power-and-its-worst-case), [§6.6](docs/V2-ARCHITECTURE.md#66-the-admin-key) |
| `TREASURY_ADMIN` (4, 24 h) | everything that names or pays the treasury: both fee recipients, every `setTreasury`, the treasury budgets of KeeperRewards, MakerVault and RewardsDistributor, the MakerVault's limits and withdrawals, and the FeeSplitter's wiring. Treasury money, never user collateral | [§2.2](docs/V2-ARCHITECTURE.md#22-every-admin-power-and-its-worst-case) |
| `LISTING` (5, 1 h) | registering a market, enabling or disabling one, the strike tick, the redeem floor, the base URI, the calendar's holidays and special expiries, the AutoRoller's minimum roll size. One hour, because a listing is reversible and cheap — and one hour is the shortest notice in the table | [§2.2](docs/V2-ARCHITECTURE.md#22-every-admin-power-and-its-worst-case) |
| `OPS_ADMIN` (6, 0) | manager-only and instant: it is the role admin of `GUARDIAN`, `PRICER`, `QUOTER` and `BUYBACK` (`script/v2/roles.v8.json:29-34`), so it can revoke a compromised hot key with no delay — and grant those four roles to anyone with no delay either. It can grant nothing else. The deliberate hole in the other direction from `ADMIN`: rotation that waits is not rotation | [§2.1](docs/V2-ARCHITECTURE.md#21-roles) |
| `GUARDIAN` (7, 0) — guardian key and the Admin Safe | no new series, mints or trading; uncorroborated settlements held until the veto is lifted or the expiry is resolved (a held single price opens the `CONFIG_ADMIN` factor-of-1.25 band from expiry + 7 days); a market's payout route cleared, so its converted payouts fall back in kind until a route is set again on the 24 h lane; the FeeSplitter paused. And, as the **role guardian of roles 1-5** (`script/v2/roles.v8.json:35-41`), the cancel of any scheduled fee, market-fee, config, treasury or listing operation while it waits. No guardian function touches a balance | [§2.3](docs/V2-ARCHITECTURE.md#23-every-guardian-power-and-its-worst-case) |
| `PRICER` (8, 0) — pricer bot key | `AutoRoller.reprice` and nothing else (`script/v2/roles.v8.json:119`): smart-pricing writers' asks moved to the bottom of each writer's own band. Since INTERFACE_VERSION 7 it cannot reprice an ask the market has already reached at all (`InTheMoney`) | [§2.2](docs/V2-ARCHITECTURE.md#22-every-admin-power-and-its-worst-case) |
| `QUOTER` (9, 0) — mm bot key and the Admin Safe | the MakerVault's whole USDG balance, moved to a counterparty by trading until the role is revoked. No quoter call pays anyone but the vault, but the guards bound each trade, not turnover: buying a partner's ask at the bid cap and selling the longs back into its one-tick bid returns exposure to 0 and leaves the partner the premium difference, round trip after round trip (`MakerVaultQuoterTest.test_compromisedQuoter_roundTripsMoveVaultUsdgToAPartner`; sweep contracts-c14). The key needs no partner and no capital: the vault writes an out-of-the-money call from its own collateral into the key holder's one-tick bid (the ask floor is 0), buys the longs back at the cap and closes the pair, up to `maxBidBpsOfSpot` of spot a share per round trip and up to `maxSeriesUnits` a series, with nothing on chain bounding how often (`MakerVaultQuoterTest.test_compromisedQuoter_aloneNeedsNoCapital`; sweep contracts-c21). A script empties the vault faster than a person can revoke the role. **Bounded from INTERFACE_VERSION 7** by `Limits.maxDailyOutflow`, a leaky bucket over `MakerVault.OUTFLOW_WINDOW` of 1 day on the net USDG a quoter call pays out: at most the cap at once and at most twice the cap in any window. `place(Bid)`, `replace(Bid)` and `take` revert `OutflowCapExceeded(available, outflow)` above it; `cancel`, `close`, the ledger moves, `claimOwed`, `sync` and every ask are never blocked, so a cap of 0 is a spend freeze that still allows the whole unwinding path (`MakerVaultOutflowTest`, `MakerVaultOutflowInvariantTest`). **INTERFACE_VERSION 8 removed v7's admin exemption** from that cap (`src/v2/mm/MakerVault.sol:136-146`): the bound is now a property of the contract rather than of who holds which key, which it had to be, because the Admin Safe is itself a `QUOTER` member (`script/v2/roles.v8.json:52`) and v7's exemption would have applied to it. What is still NOT bounded: option value sold cheaply inside the price guards and size caps and realised at settlement, at most about `maxTotalNotional × askToleranceBps / 1e4` per settlement cycle, which daily expiries make a daily figure. A second `QUOTER` holder shares the budget. Treasury money, not user collateral | [§2.2](docs/V2-ARCHITECTURE.md#22-every-admin-power-and-its-worst-case) |
| `BUYBACK` (10, 0) — cranker key | `FeeSplitter.buyback(minTokenOut)` and nothing else (`script/v2/roles.v8.json:161`): it chooses **when** the splitter spends its buyback balance and what slippage floor to name, and it can spend it repeatedly. Every buy is bounded by the configured per-call cap (50 USDG at launch, `src/v2/periphery/FeeSplitter.sol:36-38`) under the compiled `BUYBACK_CAP_CEIL` of 1,000 USDG (`src/v2/interfaces/V2Constants.sol:137`) and by the compiled `BUYBACK_COOLDOWN` of 5 minutes between buys (`:63`). There is **no daily cap**, by owner decision (below). The balance can only ever be spent buying STONKHOUSE to burn, so the worst case is bad execution repeated, not a withdrawal | [§2.2](docs/V2-ARCHITECTURE.md#22-every-admin-power-and-its-worst-case) |
| any keeper | chooses when to call; can take up to the conversion slippage bound (30 bps at launch, measured above the route's pool fee: floors of 35 / 60 / 130 bps on the 0.05 % / 0.30 % / 1 % pools) of a converted payout, less the swap's price impact, by moving the pool in the same transaction (`ClearinghousePayoutTest.testFuzz_floor_captureBounded`), plus however far the market has moved above the price the floor is valued at. That price is the higher of the settlement price and the oracle's spot whenever the oracle answers ok for it — a reading inside the market's own `spotMaxAge`, with no extra bound of the Clearinghouse's own since INTERFACE_VERSION 7 (owner sign-off c01) — so a move after the settlement window is not free to take (`ClearinghousePayoutTest.test_floorPrice_freshSpotAboveSettlement_valuesThePayoutAtSpot`, `ClearinghousePayoutTest.test_floorPrice_freshnessIsTheMarketsSpotMaxAgeAndNothingTighter`); without an ok spot a third party converts on the settlement price only within 30 minutes of expiry and pays in kind after that (`ClearinghousePayoutTest.test_floorPrice_noFreshSpot_lateThirdPartyPaysInKind`); bounties are capped | [§6.8](docs/V2-ARCHITECTURE.md#68-conversion-slippage-and-who-captures-it) |
| Chainlink feed owner, Uniswap pool, Stock Token issuer, USDG issuer, sequencer | as for v1 ([§3](#3-what-a-compromise-of-each-key-buys)), with the v2 consequences in the architecture | [§2.6](docs/V2-ARCHITECTURE.md#26-external-parties), [§6](docs/V2-ARCHITECTURE.md#6-what-is-not-protected) |

### Not protected

Issuer freeze, pause and burn (shortfalls are first come, first served; a freeze or blocklist of a
holder is not mirrored onto the Clearinghouse ledger or positions, so that holder can withdraw its free
balance to another address, and the issuer's lever is then the pooled Clearinghouse balance); USDG issuer actions;
sequencer censorship and outages (the pool snapshot grace and the feed replay bound can be run out);
feed scale faults inside the jump bound (caught only by corroboration or the guardian's veto, and a vetoed single
price settles only through `adminResolve`: within a factor of 1.25 of it from expiry + 7 days); feed
precision near the strike; the Admin Safe's signers, who are one person (below); keeper liveness;
conversion slippage; maker contracts that stop accepting tokens. Each is written up in
[docs/V2-ARCHITECTURE.md §6](docs/V2-ARCHITECTURE.md#6-what-is-not-protected).

Two items that were open in INTERFACE_VERSION 6 were **fixed in 7, with residuals that still stand**:

- **An AutoRoller ask that keeps its roll-time price after spot rallies** (sweep contracts-c16). Anyone may
  call `cancelStale(writer, underlying)` to withdraw a tracked live ask the market has reached, on a
  fresh spot at or past the strike; `reprice` refuses an in-the-money ask; and a 30-minute open grace stops
  a roll pricing off a pre-open reading. **Residual:** the cancel is a transaction after the fact, so a
  taker who backruns the crossing print — or who trades on an off-chain price before the feed prints — can
  still fill, and gaps, after-hours and weekend moves the feed never prints are not bounded while the book
  trades 24/7. Nothing cancels unless someone calls, and a keeper outage longer than the market's
  `spotMaxAge` after the crossing print leaves nothing cancellable until the next print. A paused or
  reverting oracle returns false. The product cost stands: a rally past the strike ends the writer's ask for
  the rest of the period with no same-period re-roll.
- **The writer fee was avoidable** (sweep contracts-c05): a writer who minted outside the book and resold
  the long paid nothing. v7 answered it with collateral rent at `Clearinghouse.mint`, refunded pro rata
  by `close`, which every route to a long pays identically. **INTERFACE_VERSION 8 answers it a second,
  stronger way and turns the rent off** (owner decisions V3-D7, V3-D17, V3-D18): options can only be
  created inside a trade on an approved venue — `Clearinghouse.mint` now reverts `NotMinter()` for
  anyone not on the `CONFIG_ADMIN` allow-list, and at launch the OrderBook is the only minter
  (`src/v2/interfaces/V2Errors.sol:85-88`) — so every option's first sale carries the 5 % premium fee
  and true resales stay at 0 %. The rent dial stays compiled and tested at 0.
  **Residuals:** self-trading still skips the fee (accepted, below); the fee shape inverts the v7
  relation `premiumFeeBps <= resaleFeeBps`, and at this commit the deploy path has only half caught up —
  the deploy path has since caught up in full. `script/v2/VerifyV2.s.sol` is **deleted** and
  `script/v2/VerifyV8.s.sol` replaces it; its header records that INTERFACE_VERSION 8 **deleted** the
  `premiumFeeBps <= resaleFeeBps` check rather than inverting it (`VerifyV8.s.sol:89`), so the FAIL this
  paragraph warned about cannot occur. `VerifyV8` is what the wrapper runs (`DeployV2Batch.sh:1310`,
  `:1318`). Corrected by `T-585` on 2026-09-21; the earlier text named `V2DeployBase.sol:744`, a line
  that has since drifted to unrelated code, which is why this now cites the verifier rather than a line
  number in the deploy library.

One more thing every consumer must act on: **the ABI churn reaches every decoder again.** v8 moved
selectors, event topics and tuples a second time — `Clearinghouse.registerMarket` alone went
`0x45baaccb` → `0xfb2a821f` (v7) → **`0x9ae621ee`** (v8, `registerMarket(address,uint64,bool)`; derived
here with `cast sig` and pinned at `test/v2/InterfaceIds.t.sol:533-536`) — so a consumer left on v7
ABIs mis-decodes a v8 deployment **silently** rather than failing loudly. Every lane gates on
`interfaceVersion === 8`.

### Accepted risks and the operating rules they rely on

The first block is the owner's list, `v8-plan/00-MASTER-2026-09-19.md` §7, in its final state. The
second block is the operating rules the contracts rely on rather than enforce.

- **~~v8 ships unaudited~~ — withdrawn 2026-09-19 (V3-D33).** v8 launches verified and audited: before
  the broadcast the owner reopens verification, a launch verification pass runs every gate and clears
  the deferred-verification ledger, an external audit is done and its findings are fixed. **What
  remains true:** the core is immutable, so anything the audit misses still means a redeploy, not a
  patch. Today, at this commit, no report exists ([Status](#status)).
- **The 5 % premium fee can be skipped by self-trading.** A writer can sell to their own second wallet
  at the minimum price and resell at 0 %. Accepted (V3-D18): it is forgone revenue from sophisticated
  writers only, nobody's funds are at risk, and the pattern is visible in the indexer, which flags it.
- **No rent, so there is no fee floor under the 5 %.** Accepted (V3-D18) for simplicity for writers:
  the rent dial is compiled, tested and set to 0, and can be turned on later through
  `Clearinghouse.setMarketFees` with no redeploy — in the 72 h `MARKET_FEE_MANAGER` lane, in the open,
  and cancellable by the guardian the whole time it waits.
- **No daily buyback cap.** Accepted (V3-D20): the buyback balance can only ever be spent buying and
  burning STONKHOUSE, and what remains is the compiled 5-minute `BUYBACK_COOLDOWN` and the compiled
  `BUYBACK_CAP_CEIL` of 1,000 USDG over the configured per-call cap
  (`src/v2/interfaces/V2Constants.sol:63,137`).
- **A lending hook ships in an immutable core before any stock-lending market has borrowers.** Accepted
  (V3-D3, V3-D19): lending is core to the thesis, and the hook is opt-in, gas-capped, and a failure
  only skips that maker's order rather than failing the take.
- **All three Admin Safe keys belong to one person.** Accepted (V3-D10): 2-of-3 removes single-key
  compromise now, and signers can rotate to outsiders later without a redeploy. Nothing in this
  repository can tell a 2-of-3 Safe from an EOA; the manifest knows only an address.
- **The guardian cannot cancel role or mapping changes, only fee / config / treasury / listing
  operations.** Accepted 2026-09-19 (V3-D24). `AccessManager` never lets `ADMIN_ROLE` be given a role
  guardian and the manifest sets none, so the 48 h `ADMIN` lane is protected by publicity and by a
  second `ADMIN` transaction and by nothing else. Revisit first when outside co-signers exist.

- **A take pays the fees in effect when it is mined, not when it was signed — and v8's fix for that is
  DECLARED BUT NOT YET WIRED.** `TakeParams` gained a `maxTotalFee` field in INTERFACE_VERSION 8
  (`src/v2/interfaces/V2Types.sol:83-101`) and `V2Errors.FeeAboveMax(fee, max)` exists for it
  (`src/v2/interfaces/V2Errors.sol:81-84`), but **`OrderBook.take` does not read the field and cannot
  revert `FeeAboveMax` at this commit** (`src/v2/OrderBook.sol:421-456`) — the enforcement is `C8-03`'s, and `quoteTake` still answers
  `sellerFees = 0` for a selling quote by its own admission (`src/v2/OrderBook.sol:463-467`). Until it
  lands, a take signed before a scheduled fee change and mined at or after its `effectiveAt` pays the
  new fees, up to the ceilings, and passing a cap buys nothing. **Operating rule, unchanged and still
  load-bearing:** while a change is pending (`pendingFeeParams()` returns a non-zero `effectiveAt`),
  every take's `deadline` is capped at `effectiveAt - 1`. `OrderBook.take` reverts `DeadlinePassed`
  when `block.timestamp > deadline`, and the new fees apply only from `block.timestamp >= effectiveAt`,
  so such a take either pays the fees it was quoted or does not execute. A take built while nothing is
  pending, with a deadline less than `FEE_CHANGE_DELAY` after the block it read, cannot reach a change
  scheduled later. A selling caller must keep passing `type(uint128).max` as its cap until `C8-03`
  lands. Any other integration that builds takes must apply the same rules.
- **Resting orders fill at the fees in effect at the fill.** A resting order filled at or after
  `effectiveAt` pays the new seller fee and earns the new rebate, whatever the fees were when it was
  placed (`OrderBookFeeDelayTest.test_take_restingOrders_payOldFeesBeforeEffectiveAt_newFeesFromIt`).
  Makers get `FEE_CHANGE_DELAY` — 48 h from INTERFACE_VERSION 8 — of notice through
  `FeeParamsScheduled(params, effectiveAt)` and `pendingFeeParams()`, on top of the 48 h the Admin Safe
  waits on the manager before it can schedule at all, and `cancel` is never paused, so a maker who does
  not accept the change cancels before `effectiveAt`. Whoever rests orders for others (the MakerVault
  quoter, the AutoRoller's writers through the dapp) should act on that notice.
- **A price source is listed only once it can pin.** Pinning fails closed: while a market's `setMarket`
  list names a source that has no configuration for the underlying (`SourceNotPinned(source, NoSource)`)
  or does not allow-list the oracle (`SourceNotPinned(source, NotAuthorized)`), no first series of any
  expiry can be created (`PinnedSettlementTest.test_failClosed_unconfiguredListedSource_blocksCreation`,
  `PinnedSettlementTest.test_failClosed_oracleRevokedOnAnySource_blocksCreationUntilRestored`). Operating rule:
  configure the source (`setFeed` / `setPool`) and allow-list the oracle (`setOracle(oracle, true)`) before
  `setMarket` lists it; to remove a source, `setMarket` without it first and unconfigure it afterwards.
  `RegisterMarkets.s.sol` keeps this order (`RegisterMarketsPreflightTest.test_register_droppedPool_unlistsBeforeUnconfiguring`);
  a change by hand (enabling Data Streams, docs/V2-DATA-STREAMS.md) must too, and the verifier's pin dry
  run fails on a market that breaks it. Under v8 each of those calls is a `CONFIG_ADMIN` schedule, so
  the order is an order of *scheduled* operations and each waits 24 h.
- **A pool source is configured only with an observation ring that outlasts the snapshot grace.** A Uniswap v3 pool
  writes at most one observation per second, and anyone can make it write one every second with dust mints and
  burns, so a ring shallower than `MIN_POOL_OBSERVATION_CARDINALITY` — `SETTLEMENT_WINDOW + SNAPSHOT_GRACE + 1`,
  2,401 slots (`src/v2/interfaces/V2Constants.sol:44,48,156`) — can be flooded past `expiry - 1800` before
  `expiry + 600`, which removes the pool from that expiry's settlement for about 0.01 ETH of gas (sweep
  contracts-c10). `UniV3TwapSource.setPool` refuses such a pool
  (`UniV3TwapSourceTest.test_admin_setPool_refusesAnObservationRingShallowerThanTheGrace`) and
  the RegisterMarkets preflight stops first. Operating rule: raise every registry pool with
  `increaseObservationCardinalityNext(2401)` and wait for `slot0().observationCardinality` to reach it before
  registering it (docs/DEPLOY-V2.md, step 0).

---

## The v1 record

Read `docs/ARCHITECTURE.md` (stonkhousedotfun/callhouse) §2 for the trust boundaries and
[docs/ACCOUNTING.md](docs/ACCOUNTING.md) for the money maths. The per-alert response runbooks
are in `ops/alerts.md` (stonkhousedotfun/callhouse). Alerts are not delivered today: the keeper logs and
stores them, and the relay that would send them is not deployed.

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
  15 bps fee switch, opt-in for the vault) or one of our own from `script/DeployClear.s.sol`. The
  live vault uses our own, `0x53d7A6d0489Daf3d67b9A314e0eAB2B78Acab9C6`.
- **The other four** (AF-02 stranded-claim state machine, AF-03 split payout legs, AF-04 utilisation
  ceiling 9,985 plus a post-write reserve check, AF-05 honest NAV with one deposit gate and a
  pro-rata reserve haircut) are recorded in `docs/ACCOUNTING.md` and in the regressions under
  `test/regression/`, one file per finding, each asserting the FIXED behaviour on the real Valorem
  bytecode where the loss lived in Valorem's bucket engine.

**What stands behind this, and what does not (decision D14, and its reversal).** **Decision D14 is no
longer the standing decision.** D14 ruled that there would be no external audit; a 2026-09-15 note here
said one was pending, reversing it; the owner's 2026-09-16 decision in the v2 plan restored it; and
owner decision **V3-D33** of 2026-09-19 (`v8-plan/00-MASTER-2026-09-19.md` §2) reversed it for good.
**INTERFACE_VERSION 8 launches verified and audited**, with a follow-up review and a bug bounty at
$1 M TVL. What is true at this commit, as a fact rather than a policy: **no external audit report of
these contracts exists and this repository links to none** — the v1 contracts described in this section
have never been audited, and the v8 audit is commissioned by `OWN8-12`, with its link added by `C8-14`
(see [v2, Status](#status)). Behind the v1 code are the internal reviews in §4 (the latest,
2026-09-14, found no Critical, High or Medium) and the test suite:
`forge fmt --check`, `forge build --sizes`, the unit, regression and invariant suites (the counts that
stood here were measured on v1 in September 2026 and are not re-measured by the commit that wrote this
line; they are in git history;
the invariant campaign runs 64 × 600 calls with a third-party writer and exerciser in the vault's
bucket and asserts after every call, through thirteen invariants, that the vault holds no option
token, that its lifetime assignment never exceeds the contracts it sold, and that every armed id's
option-token supply equals its unexercised collateral and sits with the buyer or the adversary),
the real Seaport 1.6 runtime driven through five of its eight fulfilment entrypoints (single, advanced fractions, the
same listing twice in one `fulfillAvailableAdvancedOrders` within and beyond the remainder, match,
basic, skip-versus-revert, a hostile contract buyer), the fork suite against chain 4663 (
on a vault the suite deploys against the live Seaport and Overcall's live Clear `0x9a7b…C0C0`,
whose runtime equals ours except the metadata hash; no test touches the live vault or our Clear:
first fill and top-up fill; an assigned week exercised by the
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
buyer it controls; at the live policy (3% OTM band floor, 0.10% premium floor) and 50% implied
volatility that moves about 1.5% of the sold notional per week from depositors to that buyer (sold
is written, under write on fill), more in a high-volatility week (§3).

An earlier revision of this section said a compromised keeper "can waste a week; it cannot take a
token". The second half was true of tokens and false of value; §4, finding 10 records the
correction.

## 2. Properties enforced in bytecode

These are not conventions; they are checks in the deployed code, each with regression tests.

- **Hard policy caps.** `Policy.sol` bounds every governance-settable parameter (OTM band,
  premium floor, utilisation, protocol fee, max contracts) in bytecode. The admin (today the hot
  EOA `0xEb82…9d9b`) can only move policy inside them.
- **The protocol fee never touches principal.** It is charged on premium only (5% live,
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
  relist is a reprice: a cycle allows the first listing and at most two reprices, after which the
  keeper cannot list again until the next `rollOpen`. `approveListing` also refuses a strike below the live band floor and a gross
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
| Keeper (hot EOA `0x06c1…C1d2`) | choose and arm the option type inside the arm gate (`rollOpen`: strike inside the band with both bounds, lot one token, window and tenor inside the compiled bounds), propose every order and its price and size up to capacity (`approveListing`), cancel, call the rolls | **value leakage, not only a wasted week.** It can arm the lowest strike the band admits and list the whole capacity at exactly the premium floor to a buyer it controls, and a colluding fill (which is what writes) can follow the authorisation immediately, before a guardian can react. At the live policy (3% OTM floor; 0.10% premium floor, lowered from `launchDefaults()`'s 0.40% by the admin's `setPolicy` of 2026-09-15) a 7-day 3%-OTM NVDA call is worth about 1.6% of spot at 50% implied volatility, so about **1.5% of the sold notional per week** (up to 95% of NAV sold) goes to the buyer in expectation; about 3.0% at 80% IV. That is the whole bound: under write on fill there is no unsold inventory for a keeper-and-accomplice to write to the cap and leave unlisted (the AF-01 variant that exceeded the earlier bound). It cannot move a token, sell above strike, list past `cycleExerciseTs`, or write outside the band and the caps |
| Admin (the hot deployer EOA `0xEb82…9d9b`, which holds `DEFAULT_ADMIN_ROLE` alone today; no timelock; the handover to a Safe with `HandoverAdmin.s.sol` is planned and not done. The keeper and guardian keys are derived from the same mnemonic, so a leak of that mnemonic is this row) | every admin power from one hot key: policy inside the caps, fee recipient (today `feeRecipient()` is this same EOA), Valorem fee acceptance, deposit cap (unbounded), `maxPriceAge`, halt and unhalt, every role grant and revocation, all effective immediately, mid-cycle included | everything the keeper row has, and worse: `setPolicy` to the compiled floors (1% OTM, 0.10% premium, 99.85% utilisation), `grantRole(KEEPER_ROLE, itself)`, then arm, list and sell to itself within a block or two. A 7-day 1%-OTM call is worth about 2.3% of spot at 50% IV, so about **2.2% of the sold notional per week** (about 3.9% at 80% IV), plus a 20% fee on whatever premium is left, routed where it likes. Still no vault function that transfers a token to it. It does **not** hold our Clear's `feeTo`, which is the 1-of-1 Safe `0xff14…CF61` (`HandoverAdmin` never moves `feeTo`), but it can `acceptValoremFee` on the vault; the engine-fee lever that needs both is in the Clear `feeTo` row |
| Guardian (EOA `0x2974…6F39`, from the same mnemonic as the admin and keeper keys; it has never sent a transaction) | halt (`rollOpen`, `approveListing` and every fill), cancel, invalidate all listings | denial of new sales until the admin unhalts, and burnt premium; exits stay open |
| A Safe as admin, after `HandoverAdmin.s.sol` (planned, not done) | the admin row's powers | the admin row, needing the Safe's threshold of signers (the grant refuses a threshold below 2) instead of one key. It does not move Clear's `feeTo` |
| Anyone | `lockBook`, `rollClose` after expiry + 1 hour, `sweepFee`, `settleQueue` while `Idle`, buying through Seaport, writing the same option id on Valorem and exercising | settling a flat queue at the instant-redeem price; a fill at the listed price inside the fill gate; being assigned alongside the vault pro rata on what the vault SOLD. None moves value from depositors beyond the priced covered call (§0) |
| Clear `feeTo`. Live: our Clear `0x53d7…C6`, whose `feeTo` is the 1-of-1 Safe `0xff14…CF61` (Safe 1.4.1, sole owner `0x7A3a…2C32`, no modules, no guard). Overcall's Clear `0x9a7b…C0C0`, `Deploy.s.sol`'s default and not used by the live vault, has the EOA `0xdAe7…0782` | the 15 bps engine fee switch (`setFeesEnabled`), `setFeeTo` (which emits no event: nomination is visible only in storage; `Verify.s.sol` reads `pendingFeeTo` from slot 3 on our instance), the URI generator, sweeping accumulated fee balances. Clear itself has no owner, no pause, no blocklist and no proxy | fees switched on while the vault has not accepted them (`valoremFeeAccepted()` is false today): `rollOpen` and every fill revert `ValoremFeeNotAccepted`, so no sales until the admin accepts or the switch goes off, nothing on collateral, and every exerciser pays 15 bps of the strike USDG on top. Fees on AND accepted by the admin EOA (two transactions from two different addresses, the Safe's sole owner and the admin EOA, with no delay on either): every fill pulls **15 bps of its notional from the vault in NVDA** into Clear's fee balance, sweepable by `feeTo`. Depositors are compensated only through the fill floor, which adds the fee's spot value to the premium the buyer must pay, so the net is a forced sale of 15 bps of NVDA per fill at the oracle's spot less the 5% protocol fee on that extra premium. With 95% of NAV sold that is about 0.14% of NAV a week in NVDA, capped by Clear's compiled 15 bps. Upstream Valorem is dormant (last commit 2023-11), so there is no patch path, bounty or incident response behind the Clear |
| Seaport 1.6 | no admin, not upgradeable, no pause, no fee switch; the zone hooks run on every fill; `conduitKey == 0` so no conduit owner has power | none beyond the verified 1.6 hook order the design rests on (`authorizeOrder` before any transfer and before the status update on every fulfilment path, `validateOrder` after all transfers, a post-authorise status failure reverts the whole transaction); `Verify.s.sol` pins the runtime hash. No public audit of the 1.6 hook code was found |
| USDG issuer (Paxos). **One EOA, `0x3Af3…024B`, holds every operational power with no timelock** | instant `pause()` (blocks transfer, transferFrom, approve, permit; not views, not mint or burn); instant `freeze`/`wipeFrozenAddress` (enforced on sender, recipient AND the `transferFrom` spender; a zero-value transfer with a frozen party reverts; 27 freezes on 4663 so far, 0 unfreezes ever); SupplyControl manager, so it can grant itself `allowAnyMintAndBurnAddress` and **burn USDG from any non-frozen address with no allowance** in two transactions; owner of the OFT wrapper; proposer, executor and canceller of the 24 h `TimelockController` that gates the UUPS upgrade and facet replacement | premium and strike proceeds in the vault, in Clear (an assigned week's strike USDG sits in Clear until `rollClose`) and owed to the queue can be frozen, wiped or burnt at any moment. Principal (the Stock Token) is never touched. The contracts make sure it never TRAPS anyone: the close strands rather than bricks (AF-02), the Stock Token leg of a queued exit is paid whatever USDG does (AF-03), the fee push is best-effort, and a wipe re-anchors `usdgAccounted` to the lower balance (accepted, §4). An earlier revision of this file said freeze and wipe sat "behind a 24 h timelock"; only the upgrade does |
| Stock Token issuer (RHJ / Robinhood; 13 registry roles, each held by exactly one EOA, none behind a multisig or timelock) | `adminBurn(from, amount)`, a bare `_burn` with **no pause and no blocklist modifier**, so it works even on a paused token or a blocklisted holder; registry-wide and per-token `pause()`; a per-address blocklist enforced on sender and recipient; `pauseOracle()`; `updateMultiplier`, where the multiplier **can decrease and can apply immediately** (WEEK went 2.0 → 1.0 on chain) while the price feed re-prints only on its 0.5% deviation trigger (≈11.8 h lag observed at NVDA's 2026-09-10 step); the beacon upgrader re-points the logic of all 204 Stock Tokens in one transaction; the prospectus adds seizure, and an Issuer Redemption Option that terminates the Series on **30 calendar days' notice**, after which tokens are redeemable only with KYC the vault cannot satisfy | vault NVDA destroyed (NAV and the reserve diverge: AF-05's honest NAV, deposit refusal and pro-rata haircut are the response), every NVDA-moving leg stopped (fills, `clear.write`, the redeem's NVDA leg, `completeRedeem`'s asset leg, instant redemption), the band priced on a stale per-token basis for the hours a multiplier step leads the feed, or a terminated Series the vault holds with no redemption path. Disclosed, not coded around: that is the asset |
| Robinhood Chain (RHDA, LLC): a single sequencer running ArbOS 61 | first-come-first-served ordering; **compliance filtering**: any transaction touching a restricted address can be dropped at the sequencer (burns to `0x0` exempt); force inclusion through the L1 Delayed Inbox after **4 days**, and whether force-included transactions are also filtered depends on optional components whose status on 4663 is unknown; the L1 Security Council (7-of-8, no delay) and the 6-of-8 proposer Safe behind a 7-day timelock can change any chain rule | if the vault, a depositor, the keeper or Seaport is restricted, nothing the vault does helps: no transaction reaches it. A censoring sequencer can delay `rollClose` and every exit for as long as it censors; the only remedy is force inclusion after 4 days, and only if that path is not filtered too. The vault has no sequencer-uptime feed to read (none exists on 4663), and `maxPriceAge` at 4 days does not notice an outage shorter than that |

**How the leakage figures are computed.** Black-Scholes value of a 7-day call at zero rates,
strike at the band floor, expressed as a share of spot, minus the policy premium floor (charged on
the gross of the one consideration item; there is no venue fee any more, so gross is net). The
buyer's expected profit is the vault's expected loss, paid out through assignment and a share
price that falls on assigned weeks. It is a bound per undetected week, not a one-off: nothing on
chain notices a sale at the floor, so it repeats until someone halts, and no alert is delivered
off chain today. The honest keeper runs in vol mode (its default, and the production setting): it
takes the strike at about 0.15 delta from Cboe's free delayed NVDA option quotes (clamped to 5% to
11.5% above spot under the live band), then asks `max(ceil(floorUnit × 1.005), ceil(fair × 1.10))`
per contract, capped at the strike, where `floorUnit` is the vault's premium floor per contract,
`fair` is the quoted mid interpolated at the strike, and 1.005 is `KEEPER_PREMIUM_MARGIN_BPS=50`
(the code default is 100). When that data is missing, stale or inconsistent it skips the week
rather than fall back to the floor. That keeps an honest ask above its own estimate of fair value,
but the estimate rests on delayed quotes the keeper accepts up to 4 days old, and it does nothing
against a compromised key. Cycle 1's live listing was priced by the keeper version before vol mode.

**Mitigations considered (open decisions).** Only item 4 is implemented, and it is off-chain:

1. **Admin behind a `TimelockController`**, so a `setPolicy`, a fee change or a `KEEPER_ROLE`
   grant is visible for a delay before it can be used. Today every admin action is immediate.
2. **Higher compiled floors.** `Policy.MIN_PREMIUM_FLOOR_BPS = 10` and `MIN_OTM_FLOOR_BPS = 100`
   are what bound the admin row. Raising them (for example towards `launchDefaults()`' 40 and 300)
   caps the admin's lever at the keeper's; it needs a redeploy, since they are bytecode constants.
3. **A listing start delay.** `SeaportOrderLib` refuses `startTime > now`
   (`ListingStartsInFuture`), so a listing is fillable in the block it is authorised. Requiring a
   delay would give the guardian a window to see and invalidate a floor-priced listing.
4. **Vol-model keeper pricing.** Implemented: vol mode, described above, is the keeper's default
   and runs in production. Off-chain; it helps the honest-keeper case and does nothing against a
   compromised key.
5. **No deposits before the Safe handover.** Not adopted: deposits are open under `depositCap()` =
   20 NVDA while the one-key admin row applies.

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
  copies (stonkhousedotfun/callhouse) predated the fixes. All regenerated; the web ABI now has a committed generator
  (`web/scripts/gen-abis.mjs` (stonkhousedotfun/callhouse)) like the indexer's.
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
| 9 (F2) | **Restated 2026-09-13 as High and adversarial** (it was recorded as Medium, economic, passive); closed by the redesign | **Unsold calls are assigned by other writers' exercises, and an attacker can make that deterministic and total.** Valorem assigns an exercise across every writer of the option id, bucket by bucket, pro rata by what each wrote, not by what each sold, and the vault never exercised its own unsold options. The passive form: the vault writes 50 and sells 10, other writers write 50 and sell all of it; on an in-the-money expiry the vault expects 30 assigned while only 10 of its contracts earned a premium. The adversarial form (AUDIT-FINDINGS F-01, reproduced on the real Clear bytecode and on a fork of live 4663): after a rally, anyone writes the same option id into the vault's bucket 0 before the first exercise and self-exercises, taking `unsold × (spot − strike)` of depositor principal pro rata; and because the bucket walk is public (`settlementSeed` is the option key, never re-seeded), an attacker who exercises once and then writes into the fresh bucket can steer the draw and assign the vault on 100% of its unsold inventory. The same rally made `approveListing` refuse to relist and let anyone kill the live listing, so the conditions arrived together. Tranche writes bounded this at the unsold tranche and did not close it | **Write on fill (decision D1, A(ii); §0).** Nothing is written at `rollOpen`; every Seaport fill writes exactly its size inside `authorizeOrder`, so `written == sold` by construction and the vault has no unsold inventory to be assigned on. `writeMore` is removed. The original tranche fix is kept below as history: **Tranche writes.** `writeMore(uint112 n)` (`KEEPER_ROLE`, `nonReentrant`) tops up this cycle's claim through `clear.write(claimKey, n)` and reverts `WriteReturnedWrongClaim` unless the same id comes back. It shares one gate with `rollOpen` (`ValoremLib.write`): `Listed`, not halted, `block.timestamp < cycleExerciseTs` (`WriteWindowClosed`), `n != 0`, registry write window open, live cycle number equal to the snapshot, option approved, option asset/exercise asset/lot/window equal to the live cycle, Valorem fee off or accepted (approval sized collateral + fee and scrubbed to 0), oracle not paused and fresh, strike band re-checked at live spot, and `Policy.checkContracts(contractsWritten + n, idleAssets() + lockedAssets())`. `contractsWritten` accumulates; `lockedAssets()` and `contractsAssigned()` already read the claim's aggregate across buckets (confirmed on live Clear). `MockClear.write(claimId, n)` now tops up as upstream `6436c823` does. **Exposure is bounded only when the keeper writes per listing.** The keeper change that does (`rollOpen` writes the first tranche, `writeMore` the next once a listing sells through, `keeper/src/roll.ts` and `keeper/src/roll.tranche.test.ts` (stonkhousedotfun/callhouse)) is uncommitted in that repository's working tree (§5) | Current regressions: `test/regression/AF01_UnsoldInventory.t.sol` (`test_unsteeredAttack_vaultAssignedOnlyWhatItSold_depositorLossZero`, `test_steeredAttack_buyerAsleep_fullAssignmentIsStillOnlyWhatWasSold`, `test_control_sleepingBuyerNoAttacker_collateralComesHome`, all on the real Clear bytecode), `invariant_vaultHoldsNoOptionTokens`, `invariant_assignedNeverExceedsSold`. Historical (deleted with `writeMore`): `test/unit/VaultTranche.t.sol` (12): `test_writeMore_topsUpTheSameClaim`, `test_writeMore_topUpIsListableAndSells`, `test_trancheCycle_partialAssignmentSettlesExactly`, `test_writeMore_sizesOnTheTotalAndCountsLateDeposits`, `test_writeMore_revertsOutsideListed`, `test_writeMore_revertsForNonKeeperZeroAndHalt`, `test_writeMore_revertsOnceExerciseCanStart`, `test_writeMore_revertsWhenTheRegistryHasMovedOn` (cycle changed; not approved), `test_writeMore_honoursTheValoremFeeSwitch`, `test_writeMore_revertsOnAPausedOrStaleOracle`, `test_writeMore_reChecksTheStrikeBandAtLiveSpot`, `test_writeMore_revertsWhenTheTotalPassesTheCap`; handler action `writeMore`; fork `test_fork_writeMoreTopsUpTheLiveClaim` against the real clearinghouse. No test demonstrates the assignment benefit itself (`MockClear` does not model multi-writer buckets) |
| 10 (F3) | Medium (documentation; economic) | **SECURITY.md §1 and §3 said a compromised keeper "can waste a week; it cannot take a token".** It can list at exactly the premium floor to a colluding buyer: about 1.1% of written notional per week at launch policy and 50% IV. The bootstrap admin (the deployer EOA before the Safe handover, no timelock) can `setPolicy` to 1% OTM and a 0.10% floor and grant itself `KEEPER_ROLE`: about 2.2% per week. The honest keeper prices at `max(policy floor, last fill)`, so on a thin book it undersells as well | Documentation only, by decision: §1 and §3 rewritten with the bound. The mitigations (admin timelock, higher compiled floors, a listing start delay, vol-model pricing, no deposits before the handover) are listed in §3 as open decisions; as of 2026-09-15 only vol-model pricing is implemented, off-chain | none (no code change) |
| 11 (F4) | Low | **`Vault.deposit` NatSpec said "a late depositor cannot be assigned against a call they were never part of writing".** False: a deposit in `Listed` is priced on a NAV that values the short call at zero, assignment losses reach every share through the share price, and since finding 9 a later tranche can be written against the new deposit directly | NatSpec corrected (0 bytes); ACCOUNTING.md §5 states the late-depositor economics. The web deposit form warns in `Listed`, more strongly when live spot is at or above `strike × (1 − minOtmBps)` (`web/components/DepositForm.tsx` (stonkhousedotfun/callhouse)) | `test_lateDepositorDuringListed_isNotWrittenAgainstButSharesTheAssignment` renamed to `test_lateDepositorDuringListed_sharesTheAssignmentThroughTheSharePrice` (`VaultAssignment.t.sol`); historical (deleted with `writeMore`): `test_writeMore_sizesOnTheTotalAndCountsLateDeposits` |
| 12 (F5) | Low; **removed by the redesign** (the fill gate re-prices every fill at live spot, so a stale listing is unfillable rather than snipeable, and there is no price-cut budget and no `invalidateStaleListing`; every `approveListing` spends one of three slots, cancelled or not) | **Stale fixed-price listings get sniped.** A listing lives until `cycleExerciseTs`; after a mid-week rally a buyer fills at the old premium one second before exercise opens and exercises. Repricing burnt one of three listing slots and a cancel never refunded one, so after three reprices the keeper could not relist at all, and with a dead keeper only the guardian's `invalidateAllListings` stopped it | (a) **Slots count price cuts.** `lowestListedUnitUsdg` (reset at `rollOpen`) records the lowest gross/amount authorised this cycle; the first listing, or one strictly below that price, spends a slot (`TooManyListings` when none are left) and becomes the lowest; at or above it is free. `listingsThisCycle` keeps its name for ABI stability and now counts price levels; `ListingApproved.seq` is that count, so two listings can share a `seq`. (b) **Permissionless `invalidateStaleListing()`** (`nonReentrant`): `NoLiveListing` with nothing live; a paused Stock Token oracle counts as stale; otherwise, at live spot (a stale feed reverts), it kills only when the strike is below the band floor or the gross below the premium floor for `listingAmount`, else `ListingStillValid` | `test/unit/VaultListing.t.sol`: `test_threePriceCutsPerCycleThenNoMore` (was `test_threeListingsPerCycleThenNoMore`), `test_relistAtOrAboveTheLowestPriceIsFreeEvenWithTheBudgetSpent`, `test_relistsAtOnePriceSpendOneSlot`, `test_listingBudgetResetsOnTheNextRollOpen`, `test_invalidateStaleListing_afterARallyPastTheBandFloor`, `test_invalidateStaleListing_whenTheFloorRisesAboveTheListingGross`, `test_invalidateStaleListing_whileTheOracleIsPaused`, `test_invalidateStaleListing_revertsWhileStillValidOrWithoutAPrice`, `test_invalidateStaleListing_revertsWithNoLiveListing`; `test_rollOpen_resetsTheSpentListingBudget` (`VaultRoll.t.sol`); handler action `invalidateStaleListing` |
| 13 | Low (adversarial round, PoC-confirmed); **removed by the redesign** with `invalidateStaleListing`; `approveListing` still refuses a strike below the live band floor, and the fill gate is the line of defence | **`invalidateStaleListing` could kill a listing `approveListing` had just authorised.** The kill fired on `cycleStrikeUsdg < strikeBand(spot).min`, but `approveListing` checked only the premium floor. After a 2.3% rally (spot 220 → 225, band floor 231.75 over a 231 strike) the keeper could list, anyone could kill it in the same block, and a free same-price relist was killed again: five rounds in one block in the PoC, the vault selling nothing for the rest of the week while its written inventory stayed assignable. A competing writer of the same option id is the obvious beneficiary | `approveListing` refuses a strike below the live band floor (`StrikeBelowBand`), and both paths read the floors from one `_listingFloors`, so they cannot disagree at the same spot. Only the lower bound: after a sell-off the strike above the band ceiling is safer to sell, not riskier | Current: `test_approveListing_refusesAStrikeBelowTheLiveBandFloorButNotAboveTheCeiling` (`VaultListing.t.sol`). At the checkpoint: `test_approveListing_refusesAStrikeBelowTheLiveBandFloor`, `test_invalidateStaleListing_cannotKillWhatApproveListingJustAccepted` (deleted with `invalidateStaleListing`) |
| 14 | Low (adversarial round, confirmed from the artifact) | **`Verify.s.sol` hard-coded five library link sites.** The fixes added `ValoremLib` call sites, so a byte-perfect deployment has seven; `VerifyVault._bytecode` would print FAIL and `run()` revert, breaking `script/rehearse-deploy.sh` and the launch verification, and training operators to ignore the check that catches swapped libraries | The expected count is read from the artifact's `linkReferences`, with at least one site required per library. `docs/DEPLOY.md` and this file updated | `test_verifyScript_acceptsAByteForByteDeployment` (`Smoke.t.sol`; also asserts swapped libraries still fail) |
| 15 | Low (adversarial round, PoC-confirmed) | **The first `settleQueue` draft bypassed the virtual-share offset.** `_settleQueue` paid `idleAssets() × q / totalSupply()` with no +1/+1, and `settleQueue` made that an atomic, permissionless exit while flat, halted or not. On an empty vault: seed 3 wei, donate 20 NVDA, a victim's 9.8 NVDA rounds to one share, queue and settle out for 22.35 NVDA against 20 NVDA + 3 wei paid, 2.35 NVDA of the victim's deposit (up to about 25% of a victim's deposit in general). The instant path would have paid 17.88 | `_settleQueue` pays `q × (idleAssets() + 1) / (totalSupply() + 1)`, the instant-redeem price; it cannot exceed `idleAssets()`. The inflation grief is bounded by the donation again | `test_settleQueue_doesNotMakeDonationInflationProfitable`, `test_settleQueue_paysWhatAnInstantRedeemWouldHave` (now exact); the handler's `settleQueue` asserts the +1/+1 price on every call; `test_queueEpochDrawsDownToZeroDust` re-derived by hand (one base unit more to the epoch) |
| 16 | Low (adversarial round, read from app source); **superseded by the redesign**: `CallsWritten` now fires once per FILL and `RollOpen.contractsCount` is always 0, so the app must sum fills (ACCOUNTING.md §2) | **Off-chain readers assumed one `CallsWritten`/`RollOpen` per cycle.** The indexer overwrote vault state on every `CallsWritten`, so `rollOpen(5)`, a fill of 5 and `writeMore(4)` indexed as 4 written / 0 sold / 4e18 locked against 9 / 5 / 9e18 on chain; the week's history took its size from `RollOpen` alone; the keeper ABI lacked `writeMore`, `settleQueue`, `invalidateStaleListing` and the new errors. `QueueSettled` from `settleQueue` is stamped with the closed week's cycle number | stonkhousedotfun/callhouse working tree, uncommitted: `Vault:CallsWritten` accumulates a tranche into the open claim (`indexer/src/vault.ts`), history sums tranches (`web/lib/history.ts`), a flat settlement is recorded as `SettleQueue`, keeper ABI regenerated | app repo: `indexer/scripts/fork-sync/expected.test.ts` ("publishes a week written in tranches as the claim's total…"), `web/lib/history.test.ts` ("a writeMore tranche adds to the week's contracts…"). Not forge-testable |
| 17 | Low (adversarial round, PoC-confirmed); **removed by the redesign**: `listingsThisCycle` counts authorisations again (three per cycle, a relist is a reprice) and `ListingApproved.seq` is unique per cycle | **The keeper still read `listingsThisCycle` as a count of authorisations.** Its relist price never goes down, so on chain the counter stays at 1 all week: the dry run's assertions (counter equals seq; a fourth approval reverts `TooManyListings(3, 3)`) failed, every relist got the same `seq`, and `latestListingForCycle` could return an older, cheaper row whose price would then spend a real slot | stonkhousedotfun/callhouse working tree, uncommitted: `listingSlotRefused` mirrors the price-cut rule, `seq` is a local monotonic per-cycle sequence (`store.nextListingSeq`), the dry run asserts the new behaviour | `test_relistsAtOnePriceSpendOneSlot` pinned the on-chain behaviour at the checkpoint (deleted with the price-cut slots); app repo: `keeper/src/policy.test.ts` ("listing slots count price cuts…"), `keeper/src/state.test.ts` ("listings: seq is a local per-cycle sequence…") |

### The 2026-09-13 audit

An internal multi-agent audit (`AUDIT-FINDINGS-2026-09-13.md` in the project handoff folder;
`callhouse-contracts-91`: 10 reviewers in parallel, a triage pass with an adversarial skeptic per
candidate and an exploit engineer for Medium and above, a gap round of 4 more reviewers; 38 agents,
20 raw findings, 5 confirmed with proofs of concept passing on the then-final `src/`). It ran on
the checkpoint `25f4328` and found the first four things below to be launch-blocking. Every proof
of concept is now a regression under `test/regression/`, one file per finding, asserting the FIXED
behaviour; where the loss lived in Valorem's bucket engine the regression runs on the real Clear
bytecode (`test/helpers/RealClearBase.sol`). Severities are the audit's. This was an INTERNAL
audit; no external audit report of v1 exists ([v2, Status](#status): D14 was reversed by V3-D33 for
v8, and the v1 contracts were never covered by it).

| # | Severity | Finding | Fix | Regression tests |
|---|---|---|---|---|
| AF-01 (F-01) | **High** | Anyone can take the in-the-money value of the vault's unsold call inventory by writing the same Valorem option id into its bucket and self-exercising; steerable to 100% of the unsold inventory; repeatable every in-the-money week; also let a compromised keeper write to the cap and never list, exceeding the §3 bound. Restated finding 9 above | **Write on fill** (§0, decision D1 A(ii)): `rollOpen` arms and writes nothing; every Seaport fill writes exactly its size in the vault's `authorizeOrder` zone hook; `validateOrder` reverts the fill if a token stays behind; the ERC-1155 receiver accepts only mints. The vault never holds an unsold option token, so the attack has nothing to take. `writeMore`, `invalidateStaleListing`, EIP-1271 and the price-cut slots removed. Decision D16 removed the Overcall registry at the same time | `test/regression/AF01_UnsoldInventory.t.sol` (3, real Clear): `test_unsteeredAttack_vaultAssignedOnlyWhatItSold_depositorLossZero`, `test_steeredAttack_buyerAsleep_fullAssignmentIsStillOnlyWhatWasSold`, `test_control_sleepingBuyerNoAttacker_collateralComesHome`; `test/unit/VaultWriteOnFill.t.sol` (20); `test/unit/VaultRealSeaport.t.sol` (14, real Seaport 1.6 runtime, five of its eight fulfilment entrypoints); `invariant_vaultHoldsNoOptionTokens`, `invariant_assignedNeverExceedsSold`, `invariant_longSupplyIsUnexercisedCollateral` with the handler's `thirdPartyWrite`/`thirdPartyExercise`; fork `test_fork_writeOnFillAgainstLiveSeaportAndClear`, `test_fork_assignedWeekSettlesOnLiveClear` |
| AF-02 (F-02) | Medium | A USDG pause or blocklist of the vault in an assigned week reverted `clear.redeem` inside `rollClose`, the only exit from Listed/Exercisable, freezing all principal and the queue for as long as it lasted. The recon widened the trigger set: Clear frozen on USDG, Clear's USDG burnt by a supply controller, and an NVDA-side blocklist of the vault (which bites in every week that is not fully assigned) | **Stranded-claim state machine** (§2; ACCOUNTING.md §5): low-level redeem with a gas-starvation guard, Idle with the claim kept, per-epoch stranded entitlements, permissionless `retryStrandedClaim`, deposits and instant redemption shut meanwhile, `rollOpen` refused, dust ≤ 1 wei per owner per generation | `test/regression/AF02_UsdgFreezeRollClose.t.sol` (9 on the mock, the same 9 on the real Clear): `test_usdgPause_assignedWeek_strandsThenRecovers`, `test_vaultFrozenOnUsdg_assignedWeek_strandsThenRecovers`, `test_clearFrozenOnUsdg_assignedWeek_strandsThenRecovers`, `test_clearUsdgBurntBySupplyController_assignedWeek_strandsUntilRefunded`, `test_vaultBlockedOnNvda_unassignedWeek_strandsThenRecovers`, `test_control_unassignedWeekClosesUnderAVaultUsdgFreeze`, `test_gasStarvedRollCloseNeverStrands`, `test_restrandInALaterGenerationWithAnUncollectedEarlierGenOwner`, `test_reQueuingWhileStrandedStagesTheClaimShareWithoutPayingIt`; `invariant_strandSharesAreConserved`, `invariant_depositGateTracksTheReserve`, `invariant_phaseSanity`, `test_handlerReachesAStrandAndRecovers`, `test_handlerReachesANvdaBlocklistStrand`; fork `test_fork_usdgFreezeStrandsTheCloseAndRetryRecoversIt` under the real USDG `ASSET_PROTECTION` role |
| AF-03 (F-03) | Medium | `completeRedeem` paid the Stock Token and USDG legs atomically, so a USDG pause or blocklist trapped settled queuers' principal while non-queuers redeemed instantly; a queuer whose own receiver is USDG-frozen was trapped the same way | **Split payout legs**: the asset leg by `safeTransfer`, the USDG leg by a raw call that on failure leaves the USDG booked (`UsdgLegDeferred`) for a later `completeRedeem`, to the same or another receiver; a call with nothing left but a blocked USDG leg reverts `UsdgLegBlocked` | `test/regression/AF03_CompleteRedeemLegs.t.sol` (5): `test_usdgPause_paysTheNvdaLegAndDefersTheUsdgLeg`, `test_vaultFrozenOnUsdg_stillPaysQueuedPrincipal`, `test_frozenReceiver_getsTheNvdaAndCollectsUsdgElsewhere`, `test_healthyTokens_payBothLegsInOneCall`, `test_stockPause_blocksQueueUsdgBehindThePrincipal`; the handler's `completeRedeem` asserts the deferred leg stays booked in full |
| AF-04 (F-04) | Low | Write sizing ignored Valorem's 15 bps engine fee; above ~99.85% utilisation with the fee on and accepted, the fee came out of `reservedAssets` | `MAX_UTILIZATION_CEIL_BPS` 10,000 → **9,985** (`Policy.sol`), the fee valued at spot inside the fill's premium floor, and a post-write **`ReserveBreached`** check that the balance still covers `reservedAssets` | `test/regression/AF04_FeeSizing.t.sol` (4): `test_governanceCannotSetFullUtilisation`, `test_feeStaysInsideTheFreeBalanceAtTheCeiling`, `test_reserveBreachIsCaughtAfterTheWrite`, `testFuzz_ceilingLeavesRoomForTheFee`; `test_fill_acceptedFeeRaisesTheFloorPullsTheFeeAndScrubsTheApproval` |
| AF-05 (F-05) | Low | The saturating `balance − reservedAssets` hid a Stock Token `adminBurn` shortfall: NAV read 0 in Idle and was overstated in Listed, deposits stayed open, and later depositors funded earlier settled redeemers first come, first served | **Honest NAV** `max(balance + locked − reserved, 0)`, one `DepositsClosed` gate that also shuts whenever `balance < reservedAssets`, and a **pro-rata reserve haircut** (`ReserveHaircut`) so every uncollected reserved claimant takes the same fraction whatever order they collect in. **Follow-up:** a compiled-in **share-price floor** in the same gate (`MAX_SHARES_PER_ASSET` 1e6: no deposit or mint while `totalSupply() > totalAssets() × 1e6`, so a book burnt to nothing with its shares outstanding is not sold to a newcomer at one wei a share and the share supply stays bounded), and queue and index maths that never form `shares × accUsdgPerShare` in 256 bits (`AccDebt` quotient/remainder, `Math.mulDiv`), so an account that queued can always settle | `test/regression/AF05_BurnShortfall.t.sol` (7): `test_idle_adminBurnShortfallIsSharedByTheReserveAndClosesDeposits`, `test_listed_shortfallIsHonestlyPricedAndClosesDeposits`, `test_listed_returningCollateralRefillsTheReserveAndReopensDeposits`, `testFuzz_haircutFractionIsTheSameForEveryClaimant`, `test_deadBook_sharePriceFloorClosesDepositsAtExactlyOneMillionSharesPerBaseUnit`, `test_deadBook_queueStillSettlesAndCompletesAndTheBookIsRebornOnceEmpty`, `test_queueMaths_doNotNeedShareTimesIndexToFit256Bits`; `invariant_noFreeShares`, `invariant_reservesAreReal`, `invariant_depositGateTracksTheReserve`, `test_handlerReachesABurnShortfallAndTheHaircut` |

Two items the audit recorded as plausible and unproven are accepted below rather than fixed: the
USDG wipe re-anchor and the split-multiplier feed discontinuity.

### The 2026-09-14 review

A single-reviewer internal pass over `src/` at `79cee08` (`AUDIT-FINDINGS-2026-09-14.md` in the
project handoff folder): no Critical, High or Medium; one Low with a proof of concept, fixed below;
one Informational, who holds our own Clear's fee switch, now in the admin and Clear `feeTo` rows of
§3.

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
  Accepted at the contract level. The keeper has no explicit skip for such a window; in vol mode it
  refuses to price when the feed's token spot and Cboe's NVDA share price differ by more than 300
  bps, which catches a large step and not a small one. The frozen weekend
  answer likewise predates the close by up to a few hours (`Vault.maxPriceAge` NatSpec).
- **There is no registry any more** (decision D16). The option type is validated from the
  clearinghouse (§0). The live vault runs on our own Clear, whose `feeTo` (the opt-in fee switch)
  is the 1-of-1 Safe `0xff14…CF61` set at its deployment, so no third-party key is left on the
  Clear path. Nothing depends on Overcall's API, book, fee configuration, operator or terms.
- **Upstream Valorem is dormant** (last commit 2023-11; Zellic's January 2023 findings 3.2/3.3 on
  the public, seedable bucket walk were never fixed). The Clear bytecode is immutable and has no
  admin beyond `feeTo`; the vault's design assumes exactly the assignment semantics the recon
  verified on chain (`test/unit/MockClearDiff.t.sol` keeps the mock faithful to them), and there is
  nobody to patch a Clear bug for us.
- **Pricing discretion leaks value inside policy.** A compromised keeper or a compromised admin
  can sell at the premium floor, below fair value, and an honest keeper whose delayed quotes
  misstate fair value can sell below it too. §3 quantifies it and lists the mitigations considered.
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

## 5. Open questions, and where they stand

Open questions, and where they stand:

1. **Overcall's order book is not a venue for this vault.** Its schema requires open orders with
   zone 0 and pre-held inventory; the vault lists restricted orders with itself as zone and holds
   no inventory. The one venue is the app's cycle page, `app.stonkhouse.fun/vault/nvda/cycle`;
   the order also fills through any Seaport fulfil path. Closed by decision D1; L-04 was dropped
   (D2 = b).
2. **Keeper pricing at exactly the policy floor.** Closed: the keeper adds a margin over the floor
   (`KEEPER_PREMIUM_MARGIN_BPS`, 50 bps in production) and in vol mode asks the larger of that and
   fair value plus 10%. A rally between the keeper's read and a fill can still make a listing
   unfillable (`PremiumBelowFloorAtFill`, `StrikeBelowBand`) until it is repriced.
3. **Deposit-time harvest checkpoint gas cost** — to be measured on the first live week.
4. **Porting the keeper, indexer and web to write on fill.** Done: the keeper creates each week's
   option type, arms it with `rollOpen(optionId)` and authorises `PARTIAL_RESTRICTED` listings with
   the vault as zone and an empty signature (cycle 1 on chain since 2026-09-15), and the cycle page
   serves that order and fills it through Seaport. No fill has happened on the live vault yet.
5. **The open decisions in §3**: an admin timelock, higher compiled floors and a listing start
   delay are open; vol-model pricing is implemented off-chain; deposits opened before the Safe
   handover.

## 6. Reporting

If you believe you have found a vulnerability, do not open a public issue. Send it to
**security@stonkhouse.fun**. The same address is published, machine-readably, at
`https://stonkhouse.fun/.well-known/security.txt` (RFC 9116) and on
`https://stonkhouse.fun/legal#reporting`. Both read `NEXT_PUBLIC_SECURITY_CONTACT_EMAIL` through
`lib/legal.ts` (stonkhousedotfun/callhouse-site).

There is no bug bounty **today**, and no external audit report of these contracts exists at this
commit, so a report is a favour, not a claim. Owner decision V3-D33 (2026-09-19) puts a follow-up
review and a bug bounty at **$1 M TVL**, and commissions an external audit of v8 before its broadcast
(`OWN8-12`); until `C8-14` adds that report's link here, treat everything in this repository as
unreviewed by anyone outside it. The live `https://stonkhouse.fun/legal` page still carries an older
sentence (checked 2026-09-15) saying a bug bounty opens in the second week after mainnet launch; no
bounty programme exists, and reports go to security@stonkhouse.fun on the terms above.
