# v8 accepted-risk register and operator runbook

Every finding the v8 security review (`V8-SECURITY-VULNS.md`, 2026-09-20, rounds at `1b92f409` and
`14e02073`) marked as accepted, or as a runbook item rather than a code change. Each entry states the
risk, where it lives, the bound the code actually enforces, who accepted it, and what an operator does
about it.

**Every `file:line` below was re-derived at contracts `v8` `561b5f041c3a8fbd4dc0fe2237630bdcebd61023`.**
The review's own line numbers were read at older tips, and several have moved. Where a premise moved,
the entry says so rather than restating the review. Every line cite was checked again at
`82fa2eeb65eff3b1211a93766458b4509998a4a1` (T-471), and the `Clearinghouse.sol` cites that T-466's
NatSpec edit moved were corrected there. That pass re-pointed line numbers only; it did not
re-review the findings.

This is a register, not a fix list. Nothing here changes contract behaviour. The operator-facing
monitoring and parameter half lives in `stonkhousedotfun/callhouse` (`ops/deploy.md`, `ops/alerts.md`,
task T-SEC-OPS-LAUNCH-PARAMS).

Three questions waited on the owner, listed under [Open owner decisions](#open-owner-decisions). **The
owner walked this register entry by entry on 2026-09-22** (rulings of record:
`stonkhouse-plan/status/OWNER-RISK-REVIEW-2026-09-22.md`, outside this repository); every decision
below now carries its closure, and the entries the rulings turned into fixes describe the code AS
LANDED at contracts `9881a2f977efb6b65559edd79f9d15da8d7c8266` (T-OP-074). The review-era text is kept
under each entry and marked as the premise the ruling moved; nothing historical was rewritten.

| ID | Risk | Status at `561b5f04` → **at `9881a2f9` (2026-09-22 rulings)** | Accepted by |
|---|---|---|---|
| SEC-08a | v1 Vault fills price off a spot up to `maxPriceAge` old | accepted, unchanged → **unchanged; no ruling given, recommendation "accept" stands** | review (P3 ACCEPTED); the code documents it |
| SEC-08b | AutoRoller strikes and asks price off any spot inside the market's `spotMaxAge` | accepted; **the "AutoRoller spotMaxAge = 1 h" knob does not exist** → **FIXED by T-OP-061 `b43eee02` (+ T-OP-087 `9881a2f9`): the spot every roll prices off is now accuracy-gated, decision 1 CLOSED** | review (P3 ACCEPTED); the 1 h value is an open owner decision |
| SEC-08c | Chainlink-source spot freshness is 90,000 s at launch | accepted → **superseded by the accuracy rule, T-OP-061 `b43eee02` / T-OP-087 `9881a2f9`: 90,000 s is the uncorroborated path's bound only** | owner sign-off c01; owner ruling 2026-09-22 ("it should be accurate") |
| SEC-09 | `spot` reads source 0 only; UniV3 source reports `updatedAt = now` | accepted at launch config; refuted as a launch exploit → **residual FIXED by T-OP-062 `87158e83` (`setPool` refuses `minLiquidity == 0`); the source-0-only premise moved with T-OP-061** | review round 2 (refutation); owner ruling 2026-09-22 "fix" |
| SEC-10 | `STALE_SPOT_GRACE` conversion at the settlement price | accepted; architecture doc's bound corrected here → **re-confirmed: decision 2 CLOSED as accept (owner "A", 2026-09-22)** | owner sign-off c01, **given on the understated bound** — see decision 2 |
| SEC-13 | PRICER is a 0-delay key that can reprice a smart ask to `minAskBps` | accepted by design → **FIXED by T-OP-063 `b77280a5`: `MIN_ASK_BPS` 5 → 50 and `MAX_REPRICE_DROP_BPS` 2_500 per call** | review (P3, "accepted in design"); owner ruling 2026-09-22 "FIX" |
| SEC-14 | HouseVault boundary liveness depended on the QUOTER | **premise largely moved**: the boundary no longer needs the QUOTER to act; a bounded QUOTER-caused delay remains → **residual FIXED by T-OP-064 `1147989e`: `sync` is epoch-gated** | review said runbook only; residual recorded |
| SEC-19 / F-CP-03 | EarnVault `totalAssets` has no term for an open short; NAV drops by ~the locked notional on every fill of its own AskWrite | **closed by control at `6b0a4e7c`** → **FIXED by T-OP-065 `8ccae0db`: `convert*`/`preview*` revert `PositionOpen` while open, `indicativeTotalAssets()` for display; decision 4 CLOSED as fix**: the flat boundary (T-184/T-433) prices nothing while a position is open; the residual is that the two `convert*` views quote the understated number | T-OP-026; the residual is an open owner decision (4) |
| SEC-21a | guardian `veto`/`unveto` can be cycled | accepted → **re-confirmed 2026-09-22 (owner "ACCEPT"; a one-veto cap stays available)** | review, matching the documented trust model |
| SEC-21b | `UniV3TwapSource` ignores `oraclePaused()` | accepted → **re-confirmed 2026-09-22 with T-OP-030 F-6's consequence recorded below; T-OP-052 measured no halt ever** | review ("documented"); owner ruling 2026-09-22 "ACCEPT" |
| SEC-21c | Hedger weekend brake is asymmetric | **NOT accepted: open owner decision** → **FIXED by T-OP-066 `ef06d284` (+ T-OP-061/087 on the oracle side); decision 3 CLOSED as fix** | owner ruling 2026-09-22 ("on a weekend can't we just use the live pool price?") |
| item 6 (2026-09-22) | HouseVault one-leg deficit: `_nav` saturates per leg, reserves pay in kind, the short leg fails closed | **accepted 2026-09-22** (fail-closed, deliberate) | owner ruling 2026-09-22 "Accept" |
| item 7 (2026-09-22) | Hedger `pause(true)` stopped `hedge` but not `unwind` | **FIXED by T-OP-067 `3e7162ed`: pause freezes `unwind` too; `repay` stays open** | owner ruling 2026-09-22 "Fix" |
| T-OP-159 (2026-09-22) | `HouseVault.setLimits` is GUARDIAN (0 delay): the guardian key can loosen a House vault's risk caps with no delay | **accepted 2026-09-22 by owner order** ("i dont want these numbers to have a delay at all"); manifest row moved, no contract change | owner order 2026-09-22 05:55Z |

---

## SEC-08 — stale-spot pricing windows

### SEC-08a — v1 Vault fills

- **Risk.** A v1 fill is priced against a Chainlink spot up to `maxPriceAge` old, so over a weekend or
  holiday gap the band floor and premium floor a fill clears are those of the last pre-close print.
- **Where.** `src/Vault.sol:156` (`maxPriceAge`), bounds `src/Vault.sol:92-93` (`MIN_PRICE_AGE` 1 h,
  `MAX_PRICE_AGE_CEIL` 7 days), setter `src/Vault.sol:1774-1777`. The gate is
  `src/lib/ValoremLib.sol:214` inside `writeOnFill` (`:201`), via `spotUsdg` (`:273-277`), which
  reverts `StalePrice` only past `maxAge`.
- **Bound.** Launch value 4 days, compiled ceiling 7 days. The code states its own limit in
  `src/Vault.sol:147-155`: the feed does not re-print at a Stock Token multiplier `effectiveAt`, "the
  keeper is expected to avoid pricing inside such a window; nothing here enforces it".
- **Why days, not hours.** `src/Vault.sol:130-139`: the `us_equities_24/5` feed publishes nothing
  while the market is closed (observed gaps up to 78 h), so an hour-scale rule would refuse every
  weekend fill.
- **Existing mitigations.** Fills stop at `cycleExerciseTs` (`ValoremLib.sol:205`), the issuer
  `oraclePaused()` flag refuses a fill (`:213`), `writesHalted` blocks every fill (`Vault.sol:122-124`).
- **Operator action.** Do not arm or list across a known Stock Token multiplier `effectiveAt`. If a
  corporate action lands while a cycle is listed, set `writesHalted` until the feed has re-printed.
  Keep `maxPriceAge` at the 4-day launch value; raising it toward the 7-day ceiling widens this window.

### SEC-08b — AutoRoller roll pricing

- **Risk.** A roll sets the strike and the ask from any `trySpot` reading the market's oracle calls
  ok, i.e. any source-0 observation inside that market's `spotMaxAge`. A price move since that
  observation leaves an ask priced off the older level until the next roll or reprice.
- **Where.** `src/v2/AutoRoller.sol:494-519` (`_plan`: `_trySpot` at `:505`, the open grace at
  `:508-519`), strike and ask derived at `:528-532`. The freshness test is the oracle's, not the
  roller's: `src/v2/oracle/SettlementOracle.sol:876` (`_spot`), per-market `spotMaxAge` with
  `DEFAULT_SPOT_MAX_AGE = 1 hours` (`:216`) used only when the market was configured with 0, and a
  compiled ceiling `MAX_SPOT_MAX_AGE = 4 days` (`:217`, enforced in `setMarket` at `:321`).
- **PREMISE MOVED — there is no AutoRoller `spotMaxAge`.** The review's "deploy with `spotMaxAge = 1 h`"
  and "compiled bound 4 days (`AutoRoller.sol:475-502`)" describe a knob the AutoRoller does not
  have at this base. The only knob is the SettlementOracle's per-market `spotMaxAge`, and the same
  value also feeds `Clearinghouse._floorPrice` (SEC-08c, SEC-10) and every vault `_checkPrice`.
  Setting it to 1 h would tighten all of them together, which is what owner sign-off c01 declined for
  the conversion floor. That is recorded as [open owner decision 1](#open-owner-decisions), and the
  launch value in `docs/DEPLOY-V2.md` stays 90,000 s until the owner rules.
- **Bound.** The ask stays inside the writer's own `[MIN_ASK_BPS, MAX_ASK_BPS]` band of the spot it
  was planned on (`AutoRoller.sol:115`, `setStrategy` `:217-230`) and the strike inside the OTM band.
  A roll inside `ROLL_OPEN_GRACE` of a session open waits for a same-day in-session print
  (`:508-519`), which removes the overnight-gap case but not an intraday move the feed has not yet
  printed.
- **Operator action.** Watch for rolls whose `updatedAt` is hours old at roll time. A writer can
  withdraw a stale ask with `stop`; anyone can pull an in-the-money one with `cancelStale`
  (`AutoRoller.sol:361`).
- **Ruling 2026-09-22 — FIXED, and decision 1 is CLOSED.** The owner chose option (c), a separate
  roll-pricing bound; the coordinator merged it into T-OP-061 because the roll reads the same `spot` as
  every other consumer, so an accuracy rule on `_spot` covers rolls without a second knob. Landed at
  contracts `b43eee025ab934e27ac46d45f75752e6645c0248` (T-OP-061) and refined at
  `9881a2f977efb6b65559edd79f9d15da8d7c8266` (T-OP-087). What `_spot` enforces now
  (`src/v2/oracle/SettlementOracle.sol`, `SPOT_CORROBORATION_AGE = 30 minutes` at `:227`): a source-0
  print at most 30 minutes old is ok; an older print on a market with a second source is ok only if that
  source is ok and agrees within the market's own `maxDeviationBps` (`_agree`, the settlement band), up
  to the compiled ceiling `MAX_SPOT_MAX_AGE` (4 days); otherwise — single-source market, or the pool not
  ok — the pre-existing rule, ok iff at most `spotMaxAge` old. `AutoRoller._plan` (`:494-532` at the
  review base) reads this spot, so after a gap the roll is refused until the pool agrees the print is
  still right, and a quiet session keeps rolling. The "AutoRoller spotMaxAge = 1 h" knob still does not
  exist and is no longer wanted. The text above this bullet is the premise the ruling moved.

### SEC-08c — Chainlink-source spot freshness is 90,000 s at launch

- **Risk.** A 25-hour-old Chainlink round is "ok" by configuration, so `_floorPrice`, AutoRoller rolls
  and every vault `_checkPrice` accept it.
- **Where.** The value is `spotMaxAgeS: 90000` in the registry (`script/v2/fixtures/registry-v8.json:160`
  here; the live registry is in `stonkhousedotfun/callhouse`), passed to `SettlementOracle.setMarket`
  by `script/v2/RegisterMarkets.s.sol` (`:419` bounds it to `[1, 345600]`).
- **Accepted by.** Owner sign-off c01 (DECISIONS-2026-09-17 §7): the 1 h conversion-floor bound made
  automated redemptions pay in kind because the feed rarely prints within an hour. 25 h is a
  decision, not an oversight.
- **Operator action.** Treat the value as a launch parameter (it is a row in `docs/DEPLOY-V2.md`), and
  do not change it for one consumer without reading every consumer listed there.

- **Ruling 2026-09-22 — superseded by the accuracy rule.** The owner's words: "I don't want it to be 25
  hours old, it should be accurate; at launch or if it's at the right price, let's say 30 min after,
  that's better; we are launching after market close." Not implemented as a 30-minute clock — the feeds
  print on a 0.5 % move or the 24 h heartbeat, so a clock refuses every quiet session and the registry
  validator refuses any `spotMaxAgeS` under heartbeat + 1 h for exactly that reason — but as the
  agreement rule under SEC-08b (T-OP-061 `b43eee02`, T-OP-087 `9881a2f9`). 90,000 s stays in the
  registry as the bound of the UNCORROBORATED path only (single-source markets, or a dual-source
  market whose pool is not ok); the corroborated path is bounded by the compiled 4-day ceiling. c01 is
  not reversed; it is narrowed to the path it always governed.
---

## SEC-09 — `spot` has no cross-source check, and the UniV3 source's freshness is vacuous

- **Risk.** `spot` and `trySpot` read source 0 alone, with no deviation check against another source;
  and `UniV3TwapSource.latest` always reports `updatedAt = block.timestamp`, so `spotMaxAge` can never
  reject it.
- **Where.** `src/v2/oracle/SettlementOracle.sol:868-878` (`_spot`, source 0 read at `:872`);
  `src/v2/oracle/UniV3TwapSource.sol:206-212` (`updatedAt` returned as `block.timestamp` at `:211`).
- **Refuted as a launch exploit, and the refutation belongs with the finding.**
  1. Chainlink is source 0 at launch (`docs/DEPLOY-V2.md`, "Per market": source order is Chainlink
     first, pool second). Chainlink reports a real `updatedAt` and has its own round-jump guard
     (`ChainlinkFeedSource.sol` `maxRoundJumpBps`, `:75`, `:102`).
  2. A spot can only raise the conversion floor, never lower it: `_floorPrice` returns
     `max(settlementPrice, spot)` (`src/v2/Clearinghouse.sol:1175-1176`). A higher floor raises
     `minOut`; a conversion that cannot meet it fails inside `try this.convertPayout` and the payout
     is delivered in kind (`:1123-1129`). A bad spot can force in-kind delivery; it cannot pay a
     holder less than the settlement price.
  3. A stale-high spot only ever overpays holders through that `max`.
- **Correction to the review.** The review says `minLiquidity > 0` "is enforced at registration". It
  is enforced by the **script** (`script/v2/RegisterMarkets.s.sol:718`), not by the contract:
  `UniV3TwapSource.setPool` (`:166-187`) stores whatever `minLiquidity` it is given, including 0. A
  hand-sent `setPool` through the CONFIG_ADMIN lane is not covered by that check.
- **Residual.** Promoting the UniV3 source to source 0 makes freshness vacuous for `spot`. That is an
  owner-trust action through `SettlementOracle.setMarket` (CONFIG_ADMIN, 24 h lane, guardian-cancellable).
- **Operator action.** Never schedule a `setMarket` that puts a UniV3 source first. When reviewing any
  scheduled `setPool` or `setMarket`, confirm `minLiquidity > 0` by reading the calldata, because the
  contract will not refuse 0. Cancel a non-conforming schedule during its delay
  (`docs/DEPLOY-V2.md`, "Rollback", step 0).
- **Ruling 2026-09-22 — residual FIXED, premise moved.** The owner ruled "fix" on the residual: since
  T-OP-062 (contracts `87158e83a6ba8afaa753d5d9f733ad92b8a029fe`) `UniV3TwapSource.setPool`
  (`src/v2/oracle/UniV3TwapSource.sol:170`) reverts `CeilingExceeded` when `minLiquidity == 0` (`:182`),
  so the "Correction to the review" above is now stale in the other direction — the contract DOES
  refuse 0, and the script's check is a second line rather than the only one. The reading-the-calldata
  step in the operator action is no longer load-bearing for the zero case. The first sentence of the
  risk is also no longer exact: since T-OP-061 `spot` reads source 1 as a corroborator for an older
  print (SEC-08b); source 0 alone still SETS the price and the pool never does, so the refutation's
  points 1-3 stand.

---

## SEC-10 — conversion at the settlement price inside `STALE_SPOT_GRACE`

- **Risk.** For a default-preferences holder (not `inKind`), a third party's redemption converts the
  Stock Token payout to USDG with a floor valued at the settlement price whenever no ok spot is
  readable and the call is within 30 minutes of expiry. The same holds, through the `max`, whenever the
  last ok spot has not caught up with the market. What the third party can capture is the market's
  move beyond the price the floor used, less the conversion bound.
- **Where.** `STALE_SPOT_GRACE = 30 minutes` at `src/v2/Clearinghouse.sol:101` (rationale `:97-100`);
  `_floorPrice` at `:1164-1183`, the ok-spot branch at `:1172-1178`, the grace branch at `:1179`.
- **Invariant the docs claimed.** `docs/V2-ARCHITECTURE.md` (§6.8, the conversion floor) bounded the error
  of a stale-but-ok reading by the feed's 0.5 % deviation threshold. **That understates it.** The
  deviation threshold is the condition under which the feed prints; it does not bound when that print
  lands on chain, and nothing in `_floorPrice` waits for it. Until it lands, the floor tracks the older
  observation, and inside the grace the settlement price alone. Corrected in the architecture doc by
  this change. The `_floorPrice` NatSpec made the same understatement until T-466 corrected it
  (landed on `v8` as `ca273aaa69cd9f0b33b0d0803b0b5ee9a188cb21`, source `45505c3e`). It now says
  that no tight bound holds, for an ok spot and inside the grace alike
  (`src/v2/Clearinghouse.sol:1150-1154` and `:1156-1160`), and points here.
- **Why existing guards miss it.** The floor is never below the settlement price
  (`Clearinghouse.sol:1176`), which protects the holder against a *lower* price and says nothing about
  a move up that the oracle has not seen. The conversion bound (`maxPayoutSlippageBps` + route fee)
  limits slippage against the floor, not the floor's own staleness.
- **Accepted by.** Owner sign-off c01. **That sign-off was given on the 0.5 % statement this entry
  corrects**, so it is raised again as [open owner decision 2](#open-owner-decisions).
- **Not established.** How often the feed's print lags the market move by long enough to matter was
  not measured. Nothing was executed.
- **Holder-side mitigation that exists today.** `setPayoutInKind(true)` (`Clearinghouse.sol:592`)
  removes the holder from this path entirely: an in-kind payout is not converted.
- **Operator action.** Around known after-close catalysts (earnings) for a listed underlying, expect
  third-party redemptions inside the grace and compare their conversion prices against the market.
  The two levers already suggested by the review are a shorter grace or defaulting new holders to
  `inKind`; both are code/product changes and neither is made here.

---

## SEC-13 — PRICER is a 0-delay hot key

- **Risk.** A compromised `pricerKey` can reprice any live smart-pricing ask down to the writer's
  `minAskBps` of spot, as low as `MIN_ASK_BPS = 5` (0.05 %).
- **Where.** `src/v2/AutoRoller.sol:398-409` (`reprice`; band check at `:409`); `MIN_ASK_BPS` at
  `:115`; roles in `script/v2/roles.v8.json`: `reprice` → PRICER (`:127`), PRICER delay 0 (`:25`),
  PRICER's role admin OPS_ADMIN (`:31`), OPS_ADMIN delay 0 (`:23`), held by the Admin Safe.
- **Bound.** Only asks of writers who opted into `smartPricing`, only inside each writer's own
  `[minAskBps, maxAskBps]` band (`:409`), same size and expiry. `reprice` refuses once the spot has
  reached the strike (`InTheMoney`, `:407`). PRICER reaches no other function.
- **Accepted by.** The review ("accepted in design"); the capability is described in
  `AutoRoller.sol:102-104`.
- **Operator action.** Alert on a `reprice` that moves an ask to its band floor, or on reprices outside
  the pricer bot's expected cadence. On suspicion, revoke PRICER from `pricerKey` through OPS_ADMIN
  (delay 0, Admin Safe) — revocation takes effect immediately. Writers can protect themselves by
  setting `minAskBps` above the floor.

- **Ruling 2026-09-22 — FIXED.** Owner: "FIX". T-OP-063, contracts
  `b77280a592c8d56d7d3a8c3ebf19e32d43f3c725`, `src/v2/AutoRoller.sol`: `MIN_ASK_BPS` raised 5 → 50
  (`:129`, 0.5 % of spot, the compiled floor under every writer's `[minAskBps, maxAskBps]` band) and a
  per-call cap `MAX_REPRICE_DROP_BPS = 2_500` (`:138`): `reprice` reverts
  `RepriceDropExceeded(current, proposed, floor)` (`:114`, checked at `:439-444`) when the new price is
  below three quarters of the live ask; raising is unbounded. A leaked key can no longer put an ask
  under 0.5 % of spot, and reaching the floor from the default 150 bps ask takes four calls, each a
  `Repriced` event. The operator action shrinks to: revoke `PRICER` through OPS_ADMIN (delay 0) and
  rotate the key (`ops/runbooks/incident-v2.md` §4b/§4d, callhouse). NOTE, recorded by T-OP-082
  (callhouse `ops/alerts.md` §V11j): nothing pages on `Repriced` today — the monitor does not scan it —
  so the four calls are time the operator has only if they are watching; a monitor row is proposed.
---

## SEC-14 — HouseVault boundary liveness

- **Review's claim (at `14e02073`).** `_requireFlat` blocks `rollEpoch` while any position is open, an
  open position has no time bound, and so a lost or malicious QUOTER can stall the boundary
  indefinitely.
- **PREMISE LARGELY MOVED at `561b5f04`.** The boundary no longer needs the QUOTER to act:
  1. Every series the vault can trade expires at or before the epoch boundary: `_seriesInEpoch`
     reverts `BadExpiry` otherwise (`src/v2/periphery/house/HouseVault.sol:1074-1077`), and the
     contract NatSpec states the rule (`:49-54`).
  2. `rollEpoch` now redeems every settled tracked series itself before checking flatness
     (`_redeemSettled`, `:689-700`, called at `:542`; landed as F10 in `dacc7cf9`, after the review
     tip). `Clearinghouse.redeem` is permissionless (`src/v2/Clearinghouse.sol:783`).
  3. A live order counted by `_requireFlat` (`:702-711`) is past its `validUntil` by then, because
     the book caps `validUntil` at the series' expiry (at its mint cutoff for an AskWrite,
     `src/v2/OrderBook.sol:760-770`), and `OrderBook.prune` is permissionless for any
     order at or past `validUntil` (`src/v2/OrderBook.sol:380-400`). An expired AskWrite counts as
     dead without a prune (`HouseVault.sol:1258`).
  4. `Clearinghouse.settle` is permissionless (`:729`).
- **What the boundary still waits for.** The oracle finalising each tracked series and the epoch-end
  price (`rollEpoch` `:545-546`). That is the settlement path's own liveness (see SEC-21a), not a
  QUOTER dependency.
- **Residual QUOTER dependency (new, found while re-deriving; bounded, not indefinite).** A series
  enters `_tracked` only through a re-measure (`_record`, `:1331-1348`), and every re-measure path is
  QUOTER-gated. `place`, `replace` and `take` check `_seriesInEpoch` first, but `sync` (`:901-905`) and
  `close` (`:891-894`) re-measure without it. The receipt hooks accept any Clearinghouse token from
  anyone (`:1009-1021`). So a series the vault holds only because someone transferred it in, and that
  expires after `epochEnd`, can be put into `_tracked` by a QUOTER `sync`, after which `_requireFlat`
  waits for that series to settle. The delay is bounded by that series' expiry. **Not established:**
  the latest expiry such a series can have, and whether any bot path calls `sync` on untracked ids.
  This is a runbook item under this row, not a fix.
- **Not established.** Nothing was executed. Whether a resale refund that `prune` cannot deliver
  (`OrderBook.sol:389-393` leaves such an order live) can arise for an order the vault itself made was
  not traced; the vault's ERC-1155 hook accepts Clearinghouse tokens, so it is not expected.
- **Operator runbook, if `rollEpoch` reverts `NotSettled` after `epochEnd`:**
  1. Read `oracle.settlementPrice(underlying, epochEnd)`. If not Finalized, this is the oracle path:
     run `finalize`, and see SEC-21a if it is Held.
  2. For each tracked series still unsettled, call `Clearinghouse.settle(longId)` (anyone).
  3. Call `OrderBook.prune` on the vault's remaining order ids (anyone).
  4. Retry `rollEpoch` (anyone).
  5. If a tracked series is **not** settled and expires after `epochEnd`, it came in through the
     residual above. Identify how it was tracked (a `sync` or `close` from the QUOTER key), revoke
     QUOTER from that key through OPS_ADMIN (delay 0) if it was not the Admin Safe, and wait for that
     series to settle; step 2 then applies. If the vault holds both legs, QUOTER `close`
     (`HouseVault.sol:891`) releases the pair earlier; the Admin Safe is a QUOTER member with delay 0.
- **Depositors meanwhile.** Queued deposits and withdrawals stay cancellable while the request's epoch
  is current (`cancelDepositRequest` `:394`, `cancelWithdrawRequest` `:425`).
- **Ruling 2026-09-22 — residual FIXED; runbook step 5 revisited.** Owner: "FIX". T-OP-064, contracts
  `1147989e0f371a3307ff075fd956ceb5bc792bb2`, `src/v2/periphery/house/HouseVault.sol`: `sync` is
  epoch-gated like `place` (`:951-957`, `_seriesInEpoch` at `:920`), so a series expiring after
  `epochEnd` can no longer enter `_tracked` through `sync` whatever was transferred in (`:53`). `close`
  is DELIBERATELY not gated (`:931-939`): closing a pair releases collateral and cannot extend the
  boundary. Step 5 above therefore no longer has a `sync` case to identify — a tracked series that
  expires after `epochEnd` is not reachable from the QUOTER key any more; if `rollEpoch` still reverts
  `NotSettled`, steps 1-4 are the whole runbook and the QUOTER revoke in step 5 is not the remedy.
  Kept above as the premise the fix moved.

---

## SEC-19 / F-CP-03 — EarnVault NAV has no term for an open short

- **Review's claim (SEC-19 at `V8-SECURITY-VULNS.md`, P3 [OPEN]; F-CP-03 at
  `v8-review-2026-09-20/findings/02-contracts-periphery.md`, High).** `totalAssets` sums the wallet, the
  free Clearinghouse ledger, the book's Bid escrow and the venue, minus queued-deposit escrow. A fill of
  the vault's own AskWrite debits `free` by the locked collateral and credits a short; neither appears in
  any term, so NAV drops by about the locked notional while economic value barely moves, and a holder
  redeeming mid-position is under-paid while a depositor arriving after a fill is over-minted.
- **The term is still missing at `6b0a4e7c`, and it stays missing.** `src/v2/periphery/earn/EarnVault.sol:981-991`
  is the same five-term sum. (Every `EarnVault.sol` line in this entry is read at the T-OP-026 commit, where the
  NatSpec added above `totalAssets` moves everything after `:962` by +8 relative to `6b0a4e7c`.) The row asked for "the conservative count" -- locked collateral minus the
  worst-case payout, capped at locked -- and for a FULLY COLLATERALISED write, the only kind this vault
  makes, that count is identically zero: a cash-secured put can lose its whole strike collateral, a
  covered call its whole stock. The only non-zero alternative is a mark, which `IEarnVault.totalAssets`
  forbids because a quoter- or oracle-supplied option mark must never move the share price.
- **THE CONSEQUENCE IS CLOSED BY THE FLAT BOUNDARY, which is the row's third option and is what the code
  already does.** Nothing is settled at the understated number:
  1. `deposit` queues while `_positionOpen() || _queueOpen()` (`EarnVault.sol:371-392`), returning 0
     shares and a `DepositQueued` id; the assets sit in escrow that `totalAssets` excludes (`:989-991`).
  2. `redeem` queues while `_positionOpen()` (`:431-433`), burning nothing and paying nothing.
  3. `processQueue` serves nothing while `_positionOpen()` (`:465`) and prices every entry it does serve
     at the NAV of that moment (`:481`, `:524`).
  4. `_positionOpen` (`:1259-1260`) is `hasOpenShort || _holdsLongs || _resaleEscrowOpen`; the short is
     recorded on the mint by the ERC-1155 receive hook (T-298; batch delivery T-433), so the vault cannot
     be short without knowing it.
  5. `skim` (`:631-661`) is the one pricing path outside the boundary. It refuses while a queue is open
     and on a flat-or-losing price, and an understated price can only make a real gain look smaller: the
     fee is deferred and the collateral's return is charged only for the gain it carries, never on its
     own. Measured, not argued: `test/v2/unit/EarnVaultNav.t.sol`
     `test_sec19_skimChargesThePremiumOnceAndNeverTheCollateralRecovery`.
- **Reachability at launch: the ask path is live.** `EarnVault.place` (`:900-928`) accepts `AskWrite`
  under QUOTER (`script/v2/roles.v8.json:218`); `_checkPrice` bounds the price, not the kind; there is
  no bid-only switch; no ops service rests Earn asks, so at launch the path is idle until the QUOTER hot
  key uses it. Pinned: `test_sec19_theAskPathIsLiveForTheQuoterAndForNobodyElse`.
- **What is pinned, to the base unit** (`test/v2/unit/EarnVaultNav.t.sol`, authored under build mode):
  the gap is exactly `units x collateralPerUnit + rent - net premium`; across a write-fill-queue-settle
  episode a queued deposit is minted and a queued redemption paid at exactly the recovered NAV, in BOTH
  arrival orders, and the over-mint and under-payment the depressed number would have produced are
  named and shown not to happen; NAV recovers to flat NAV plus premium once the short is redeemed.
  Proven by breaking, each restored byte-identically: deleting the `redeem` boundary pays the exit
  2,919.02 USDG on the spot against ~5,020 fair (red only when the exit arrives with an empty queue and
  wallet liquidity, which is why the suite has an exit-first episode); deleting the `deposit` boundary
  mints 17,129 shares for 10,000 USDG on the spot; letting the skim mark ratchet down on a losing
  period moves the mark to 0.58 and would charge the collateral's return as performance.
- **Bound the code enforces.** No share is minted or burned, and no redemption paid, at any price other
  than a flat-NAV price. The duration of the understated window is the life of the short plus the time
  until someone redeems it; redemption is permissionless (`src/v2/Clearinghouse.sol:1233`, third-party
  redeem allowed unless the holder opts out, which the vault never does).
- **Residual, and the owner decision it needs.** `convertToShares` / `convertToAssets`
  (`EarnVault.sol:997-1010`) quote the understated rate while a position is open. They are views of
  `totalAssets`, not prices anyone is paid, but a front end that displays them as "your balance is worth"
  will show a holder a number up to the locked notional too low for the life of every written series.
  See decision 4 below.
- **Operator action.** None on-chain. The app should label the Earn share value as indicative while
  `hasOpenPosition()` (`EarnVault.sol:1183`) is true, or read `hasOpenShort()` from the interface.
- **Ruling 2026-09-22 — FIXED, not accepted; decision 4 CLOSED as fix.** Owner: "FIX". The register's
  recommendation (a) above was overruled. T-OP-065, contracts
  `8ccae0db6481b63670bcd543c5f60ec8b0624085`, `src/v2/interfaces/IEarnVault.sol`: `convertToShares`,
  `convertToAssets` and the `preview*` views revert `PositionOpen()` (`:110`) while the vault holds an
  option position (`:197-205`) — a quote off the understated `totalAssets` is a number, not a price
  anyone is paid, and integrators read ERC-4626-shaped views as prices, so the view refuses instead of
  answering. `indicativeTotalAssets()` (`:214-215`) and its per-share twin (`:217-218`) exist for
  DISPLAY ONLY and are conservative in every branch. The interface id was re-pinned in that row; the
  callhouse ABI regeneration is T-OP-079 and the app-side reader fix follows T-OP-078's census. The
  operator action above (label as indicative) is now what `indicativeTotalAssets` is FOR, not a
  workaround for a lying view.

## SEC-21 — guardian and settlement-path dependencies

### SEC-21a — veto/unveto can be cycled

- **Risk.** `veto` and `unveto` are the same instant GUARDIAN permission, so a leaked guardian key can
  cycle an expiry Held → Pending → Held, each unveto restarting `uncorroboratedDelay`.
- **Where.** `src/v2/oracle/SettlementOracle.sol:478-484` (`veto`), `:493-500` (`unveto`, new
  `finalizableAt` at `:497`); roles `script/v2/roles.v8.json:98-99` (GUARDIAN), GUARDIAN delay 0
  (`:24`), GUARDIAN's role admin OPS_ADMIN (`:30`).
- **Bound.** Delay only; the guardian cannot choose a price. CONFIG_ADMIN can `adminResolve` from
  `expiry + RESOLVE_DELAY` (48 h, `src/v2/interfaces/V2Constants.sol:50`; `adminResolve` at
  `SettlementOracle.sol:513`, CONFIG_ADMIN per `roles.v8.json:97`, a 24 h lane), inside the pinned
  deviation band, or from `expiry + 7 days` inside a factor of 1.25 for a Held expiry with one ok
  price (`SettlementOracle.sol:98-108`, `HELD_RESOLVE_DELAY` `:223`, owner sign-off c12).
- **Operator action.** A second `SettlementVetoed` for the same `(underlying, expiry)` after an
  `SettlementUnvetoed` is the signature. Revoke GUARDIAN from the guardian key through OPS_ADMIN
  (delay 0, Admin Safe), then `unveto` from the Admin Safe (itself a GUARDIAN member) and let
  `finalize` run.
- **Ruling 2026-09-22 — re-confirmed, accepted.** Owner: "ACCEPT". No row. The one-veto-per-expiry cap
  (second veto needs CONFIG_ADMIN) remains available if the trust model changes.

### SEC-21b — the UniV3 source ignores `oraclePaused()`

- **Risk.** During an issuer oracle halt, a pool snapshot can still be recorded and served as a
  settlement candidate. Only the veto window stands between it and a final price.
- **Where.** `src/v2/oracle/UniV3TwapSource.sol:217-221` (`windowPrice`) and `:230-250` (`record`)
  never read `oraclePaused()`; the flag is honoured by `ChainlinkFeedSource.sol:188`, `:212`, by
  `DataStreamsSource.sol:367`, `:494`, `:588`, and by `SettlementOracle._spot` (`:871`) — so quoting
  and rolls stop during a halt, but pool-sourced settlement does not.
- **Operator action.** On any issuer `oraclePaused()` for a listed underlying that has a pool source,
  the guardian watches every expiry inside the halt and vetoes a pool-only candidate unless it can be
  checked against another price. The alert wording is in `ops/alerts.md` (callhouse).
- **Ruling 2026-09-22 — re-confirmed, accepted, with the consequence recorded.** Owner: "ACCEPT",
  conditional on T-OP-052's halt history. T-OP-030 F-6 (contracts `064aceae`) spelled out what the
  acceptance means on the launch pair (NVDA, SPCX — the only dual-source markets): an expiry captured
  during an issuer halt has exactly one ok recorded price, the pool's, and **finalizes on it
  `DEFAULT_UNCORROBORATED_DELAY` (6 h) after the candidate unless the GUARDIAN vetoes**
  (`veto(address,uint40)`, delay 0); a vetoed Held expiry with one ok price bounds `adminResolve` to
  that pool price's band from `expiry + 48 h`, and only from `expiry + 7 days` (`HELD_RESOLVE_DELAY`)
  inside a factor of 1.25 — **the admin's resolution follows the pool leg for a week.** T-OP-052
  (callhouse, 2026-09-22) then measured the history: the issuer has **never** raised `oraclePaused()`
  on NVDA or SPCX (zero `OraclePaused` events over the whole chain), and `Stock.sol` transfers check
  `paused()`, not `oraclePaused()`, so a future oracle halt would NOT freeze the pool — F-6's hoped-for
  "TWAP freezes at the pre-halt price" case does not exist. The acceptance therefore rests on "has
  never happened" plus the guardian rota, not on code; the owner's ACCEPT stands on that basis. A
  monitor alert on the `OraclePaused` topic for both tokens is T-OP-083 (callhouse) so a first-ever
  halt pages; the runbook wording with the two numbers is `ops/alerts.md` §V30 (T-OP-082).

### SEC-21c — Hedger weekend brake asymmetry: NOT ACCEPTED → FIXED 2026-09-22 (decision 3 closed)

Recorded here so it is found, and raised as [open owner decision 3](#open-owner-decisions). No
disposition is taken in this document.

- **Fact.** `unwind` requires a fresh spot (`_requireFresh`, `src/v2/periphery/Hedger.sol:268`,
  `:365-368`, `freshnessSeconds` default 1 h at `:58`, ceiling `FRESHNESS_CEIL = 1 days` at `:40`), so
  whenever the feed has not printed within `freshnessSeconds` — every weekend — the Hedger cannot buy
  back stock with its own USDG to reduce the loan. Morpho liquidation of the adapter's position is not
  subject to that brake.
- **What already exists.** `repay` (`Hedger.sol:325-332`) is unrestricted and works while disabled,
  paused or weekend-frozen, but it needs the Stock Token supplied from outside the contract.
  `_requireOpenSession` gates `hedge` only (`:355-363`, NatSpec: "a brake must never trap inventory").
  The HF floor ceiling is `HF_FLOOR_CEIL_BPS = 20_000` (`:29`).
- **Ruling 2026-09-22 — FIXED; decision 3 CLOSED as fix.** The owner's question: "on a weekend can't
  we just use the live pool price? Why would it be a stale spot." The answer landed in two halves. On
  the oracle side (T-OP-061 `b43eee02`, T-OP-087 `9881a2f9`, SEC-08b above) an older Chainlink print is
  ok whenever the market's live pool agrees with it within the band, up to the compiled 4-day ceiling —
  which is what "use the live pool price" means without letting the pool SET the price (SEC-09): the
  pool corroborates the last print, it does not replace it. On the Hedger side (T-OP-066, contracts
  `ef06d28426cdfaa3fd4c939694e17e4f21349695`, `src/v2/periphery/Hedger.sol:20-24`, `:291-318`) `unwind`
  no longer reads `freshnessSeconds` at all: it needs only a spot the oracle stands behind (`trySpot`
  ok; `StaleSpot(updatedAt)` otherwise), so over a weekend with a live pool the Hedger can cut its loan
  while Morpho could liquidate. `hedge` keeps the raw-age brake (`_requireFresh`, `freshnessSeconds`
  default 1 h) and the session guard: a brake on OPENING risk across a quiet feed is a product choice
  the contract keeps. **Operationally the weekend case needed T-OP-087 too**: T-OP-061 first bounded the
  corroborated path by the market's `spotMaxAge` (90,000 s, 25 h), so a Friday-close print was
  `StaleSpot` by Saturday evening; T-OP-087 moved that ceiling to the compiled `MAX_SPOT_MAX_AGE` (4
  days), which covers a weekend plus a Monday holiday (~89 h < 96 h). The text above this bullet is the
  fact set the ruling moved.

---

## Owner-batch items 6 and 7 (2026-09-22)

Two items the owner ruled on in the same review that the security review had not listed here.

### Item 6 — HouseVault one-leg deficit: accepted

- **Risk.** `_nav` saturates each leg to zero separately (T-573/T-594 pinned the shape at the
  `HouseVault.sol` cash and stock legs), reserves are paid in kind, and a short leg that cannot be
  made whole fails closed with `InsufficientCollateral` — so the OWED CLAIMANT absorbs a one-leg
  deficit until the leg is whole, and the pool's NAV never bears it.
- **Alternative offered.** Pool bears it: net the short leg in `_nav` and `_payReserved` (a P1 change
  touching the T-594 / T-OP-032 pins).
- **Ruling 2026-09-22 — accepted** ("Accept"): fail-closed and deliberate. No row. A claimant refused
  by `InsufficientCollateral` is the runbook signal that a leg is short; the pool is not diluted.

### Item 7 — Hedger `pause(true)` did not stop `unwind`: fixed

- **Risk.** `pause(true)` stopped `hedge` but not `unwind`/`repay`, so a paused Hedger could still
  close shorts and spend USDG through `unwind` (bounded by debt, the oracle floor, slippage and the
  notional bucket).
- **Ruling 2026-09-22 — FIXED** ("Fix"). T-OP-067, contracts
  `3e7162eda7be93a294f1b82c671fe8168a507d30`, `src/v2/periphery/Hedger.sol`: `unwind` reverts `Paused()`
  first (`:299`), as `hedge` does (`:243`); `repay` (`:369`) stays open on purpose — it spends nothing
  of the vault's and is the escape hatch. Pause now freezes everything that spends this contract's
  money; the NatSpec at `:69-76` says so.

## T-OP-159 — `HouseVault.setLimits` on GUARDIAN with no delay (2026-09-22)

An owner ORDER, not a review finding: on 2026-09-22 05:55Z the owner said, verbatim, **"i dont want
these numbers to have a delay at all."** "These numbers" are the House vault's `Limits` —
`maxSeriesUnits`, `maxTotalNotional`, `askToleranceBps`, `maxBidBpsOfSpot`, `maxOrderLifetime`,
`maxDailyOutflow`. T-OP-159 (claude-350437, contracts base
`0524fc2b8ed1162a942968817a38c71bb8337785`) carried it out as a MANIFEST-ONLY change: one row of
`script/v2/roles.v8.json` (`.targets.HouseVault["setLimits(...)"]`, `:188`) moved from
`TREASURY_ADMIN` (`delaysS` 86,400 s, guardian-cancellable) to `GUARDIAN` (`delaysS` 0). No contract
changed; `HouseVault.setLimits` (`src/v2/periphery/house/HouseVault.sol:974`) is `restricted` and asks
the manager, and `DeployV8._pendingMapping`, `VerifyV8` check group 9, `DeployHouseVault.s.sol` and
`DevDeploy._wireHouseVault` all read the manifest at run time, so they follow the row. The
`HouseVault.sol` NatSpec at `:44` and `:973` still says TREASURY_ADMIN; touching the contract was
forbidden by the row and that comment is listed for the launch pass in the deferred-verification
ledger.

- **Risk.** The GUARDIAN lane is instant and its holders are the Admin Safe and one owner-held EOA
  (`roles.v8.json` `.holders.adminSafe`, `.holders.guardianKey`). Which EOA: the owner ruled at
  06:12Z the same day (T-OP-160 amendment, operator relay M-277f082e9a7e4d38) that the guardian is
  the existing v7 guardian `0x29741A8d283a253E8Ce10aDfd04C6507438b6F39` — an EOA from the owner's
  ops mnemonic (`DECISIONS-2026-09-17.md` §8, `docs/AUDIT-SCOPE.md` "same mnemonic as the admin"),
  distinct from the deployer/admin key — and that "the owner retunes limits from 0x2974...6F39 at
  0 s". Before this row a change to the caps waited 24 h on the manager,
  visible, and the guardian could cancel it. Now the guardian key SETS them, up or down, in one
  transaction. Tightening is the first kill switch (`V2-HOUSE-VAULT.md`, "Ordered kill switches") and
  gets faster. Loosening removes the bound that makes "QUOTER drains HouseVault" BOUNDED in
  `V8-SECURITY-SWEEP.md` §2.2: with the caps lifted, a compromised QUOTER key can commit depositor
  collateral through the quoting surface up to the vault's TVL, inside the price guards. Only the two
  bps fields have a compiled ceiling (`HouseVault._setLimits`, `:1349-1351`); the size and outflow caps
  have none. So the loss this lane can enable is bounded by the House vault's TVL and needs BOTH a
  guardian action (or a guardian key compromise) AND a QUOTER key compromise; the guardian key alone
  moves no money and cannot quote.
- **What it does not change.** `setPerformanceFeeBps` stays TREASURY_ADMIN, 24 h (the owner asked for
  the limits only). `MakerVault.setLimits` (`roles.v8.json:130`) and `Hedger.setLimits` (`:198`) stay
  TREASURY_ADMIN. TREASURY_ADMIN's own delay is unchanged. No new role and no new target name.
- **Mitigation, as accepted.** The GUARDIAN holders are an owner-held EOA (above) and the 2-of-3
  Admin Safe (all three keys the owner's, V3-D1/V3-D10) — never a bot key. `roleAdmin` of GUARDIAN is
  OPS_ADMIN (delay 0, Safe), so a leaked guardian key is revoked in one Safe transaction. Every
  `setLimits` emits `LimitsSet(Limits)` (`HouseVault.sol:302`), so a loosening is on chain the block it
  happens; the monitor does not scan it today (the T-OP-082 shape).
- **Accepted by.** The owner, 2026-09-22 05:55Z, by direct order, and reaffirmed at 06:08Z after the
  launch limit values were approved ("let me modify it with no delay actually" — relayed by the
  operator, M-4cf8d1365c944766). Recorded here by T-OP-159 so the register says why the guardian lane
  holds a setter that is not a brake.
- **Operator action.** Alert on `LimitsSet` from any House vault, and page on one that RAISES
  `maxTotalNotional`, `maxSeriesUnits` or `maxDailyOutflow`. On suspicion: `setQuotingPaused(true)`
  (GUARDIAN, instant), then revoke QUOTER from the bot key and, if the guardian key itself is
  suspect, revoke GUARDIAN from it through OPS_ADMIN (delay 0, Admin Safe).
- **Hardening option, post-launch, NOT built.** Split `setLimits` into a tighten-instant path (every
  field may only go down; GUARDIAN) and a loosen-delayed path (TREASURY_ADMIN, 24 h). That is a
  contract change and an interface revision (new selector, new manifest row, new pins); the owner did
  not ask for it and it is recorded as the row to cut if the guardian key ever stops being an
  owner-held key.

## Open owner decisions

These are questions. Nothing in this repository answers them. They were raised on Agent Bridge on
2026-09-21 to the coordinator for the owner (decision 3 as question `Q-a0b852df85c0414c`, decisions 1
and 2 in message `M-1425b7afd44e4f64`), from task T-SEC-ACCEPTED-RISKS-RUNBOOK.

1. **SEC-08b — AutoRoller `spotMaxAge = 1 h`.** **CLOSED 2026-09-22 — owner chose (c); delivered as the
   accuracy rule on `_spot` by T-OP-061 `b43eee02` and T-OP-087 `9881a2f9` (see SEC-08b), which covers
   rolls without a second knob.** The review asks for 1 h on roll pricing, but at
   `561b5f04` the AutoRoller has no freshness knob of its own; the only one is the SettlementOracle's
   per-market `spotMaxAge`, launch value 90,000 s, shared with `_floorPrice` and every vault
   `_checkPrice`. Options: (a) keep 90,000 s and accept SEC-08b as recorded; (b) set 1 h on the shared
   field and accept that conversions and vault quotes will also refuse most of the time (the c01
   trade-off reversed); (c) add a separate roll-pricing bound to the AutoRoller, which is a contract
   change and an interface revision.
2. **SEC-10 — re-confirm c01.** **CLOSED 2026-09-22 — owner "A": accepted as bounded (~3 % of one
   payout, T-OP-030); no row; revisit "new holders default to `inKind`" as an app default, not here.**
   Sign-off c01 accepted a staleness error "bounded by the feed's 0.5 %
   deviation threshold". That bound is not what the code enforces (see SEC-10). Does the acceptance
   stand, or should the grace be shortened or new holders default to `inKind`?
3. **SEC-21c — Hedger weekend brake.** **CLOSED 2026-09-22 as FIX — T-OP-066 `ef06d284` (unwind trusts
   the oracle's corroborated spot) with T-OP-061/T-OP-087 on the oracle side; see SEC-21c.** Should
   `unwind` stay blocked on a stale spot (today), or be
   allowed on a stale spot with some other output floor, given that Morpho liquidations are not
   blocked? The review asks for an explicit owner decision; this register does not make it.
4. **SEC-19 / F-CP-03 — accept the understated `convert*` quotes while a position is open.** **CLOSED
   2026-09-22 as FIX — owner "FIX"; option (b) delivered by T-OP-065 `8ccae0db` (views revert
   `PositionOpen`, `indicativeTotalAssets()` for display); the recommendation (a) below was overruled.**
   The
   pricing consequence is closed by the flat boundary (above); what remains is that the share-value
   views are wrong by up to the locked notional for the life of every written series. Options: (a)
   accept, and have the app label the value as indicative while `hasOpenPosition()` is true; (b) have
   the views revert or return 0 while a position is open, which is a contract change and an interface
   revision; (c) forbid asks on the Earn vault at launch by not issuing the QUOTER key a reason to use
   them, which is a runbook statement, not a guard. This register recommends (a) and does not decide it.
