# House vault (operator runbook)

The House vault is one ERC-20 per market. Depositors queue USDG or the market's Stock Token; a permissionless weekly boundary prices the queue; the vault quotes on the OrderBook as the maker of record. This file is what is true on chain, per getter, not a promise about future return.

No APY, APR, projected, annualised, or guaranteed figure belongs in this product. Depositors can lose money: venue and book PnL, a performance fee on realised gain above the high-water mark, and in-kind withdrawals all sit on the vault.

## Epoch

`epochEnd` is a calendar weekly expiry (`ExpiryCalendar.nextExpiry(..., weekly=true)`), stored on the vault and advanced by `rollEpoch`. Getters that describe the live epoch:

- `epochEnd()` — unix time the current boundary is allowed to run
- `epochId()` — how many boundaries have been rolled
- `highWaterMark()` — last per-share NAV the performance fee used
- `performanceFeeBps()` — fee on gain above that mark, compiled-capped by `PERFORMANCE_FEE_CEIL_BPS`
- `nav()` — USDG-denominated value of vault holdings **excluding** unpriced queues
- `pendingDepositUsdg()` / `pendingDepositStock()` / `pendingWithdrawShares()` — unpriced queues
- `owedUsdg()` / `owedStock()` — priced withdrawals not yet `claim`ed

A deposit queued in epoch N is **not** in `nav()` until `rollEpoch` for that boundary succeeds. Calling `requestDeposit` again in a later epoch while an unclaimed priced request exists reverts; claim first.

## What `rollEpoch` requires

`rollEpoch()` is permissionless (`roles.v8.json` `unrestricted.HouseVault`). Anyone can call it. It reverts unless:

1. `block.timestamp >= epochEnd` (`TooEarly`)
2. the vault is **flat** — no live book orders and no leftover option inventory (`_requireFlat`)
3. `oracle.settlementPrice(underlying, epochEnd)` is `Finalized` with a non-zero price (`NotSettled`)

It then: charges the performance fee in USDG to `splitter()` against gain above `highWaterMark`, prices withdrawals pro rata in USDG and Stock Token, mints shares for the deposit batch (burning `MIN_SHARES` to `address(0)` on the first boundary), writes `EpochRates` for that `epochId`, and sets `epochEnd` to the next weekly expiry.

The guardian pause **must not** wrap `rollEpoch`. `setQuotingPaused` only stops quoting (`_requireQuoting` on place/replace/take/close/…). If the boundary needed a role or the pause, queued funds could not be priced and `claim` would never pay.

## Per-instance role batch (48 h)

`AccessManager` maps `(target, selector) → role`. A vault the factory just returned has **no** selectors mapped. `HouseVaultFactory.createVault` is `LISTING` on the factory; it does not map the child.

Before the mm-bot can quote a new vault, the Admin Safe must send that vault its own 14-selector `setTargetFunctionRole` batch (the `targets.HouseVault` rows in `script/v2/roles.v8.json`) under **ADMIN's 48 h execution delay**. Plan a listing around that wait. Depositor paths work immediately; only quoting waits.

Do **not** grant TREASURY_ADMIN, QUOTER, CONFIG_ADMIN, or GUARDIAN **to** a vault or to the factory. A role is `(role, member)` across every target, so granting TREASURY_ADMIN to a vault would also let it call `KeeperRewards.defund`, `RewardsDistributor.setRoot`, `FeeSplitter.setTreasury`, and `Clearinghouse.setFeeRecipient`.

Devnet (`DEV_HOUSE_VAULT`) maps the NVDA instance in the same broadcast as deploy, with delay 0, because the anvil admin is the manager's initial admin. Production is the Safe batch.

## Ordered kill switches

Stop quoting without trapping depositor funds:

1. `setLimits` (GUARDIAN, no delay — **moved from TREASURY_ADMIN by T-OP-159 on the owner's order of 2026-09-22 05:55Z, "i dont want these numbers to have a delay at all"**; this line used to say "TREASURY_ADMIN, 48 h", and the delay on that lane was 24 h, not 48 h) — tighten `maxSeriesUnits` / `maxTotalNotional` / `maxDailyOutflow` to zero so new quotes fail the exposure/outflow checks. The same key can also LOOSEN the caps instantly; that is the owner-accepted risk recorded in `V8-ACCEPTED-RISKS.md` (T-OP-159), and `setPerformanceFeeBps` stays on TREASURY_ADMIN's 24 h lane.
2. `setQuotingPaused(true)` (GUARDIAN, no delay on the guardian lane) — `_requireQuoting` reverts on place/replace/take/close/sync paths that quote.
3. OPS_ADMIN revokes QUOTER from the bot key (manager-only; GUARDIAN / QUOTER are parented to OPS_ADMIN so a hot key can be rotated without ADMIN's 48 h).

`rollEpoch`, `requestDeposit`, `requestWithdraw`, `cancelDepositRequest`, `cancelWithdrawRequest`, and `claim` stay callable.

## Readable on chain (do not invert)

| Getter | What it is |
|---|---|
| `orderBook()` / `clearinghouse()` / `usdg()` / `underlying()` / `calendar()` / `oracle()` / `splitter()` | immutables |
| `limits()` | current `Limits` |
| `quotingPaused()` | guardian quoting switch |
| `protocolAccount(address)` | CONFIG_ADMIN self-deal blocklist |
| `exposure(longId)` / `orderIdsOf(longId)` / `trackedSeries()` | inventory the quoter has open |
| `askFloorOf(longId, primary)` / `bidCap(longId)` / `outflow()` | live quote rails |
| `depositRequest(account)` / `withdrawRequest(account)` | that account's queue |
| `epochRates(epochId)` | what a rolled boundary decided |

There is no getter for "this vault cannot lose money". `nav()` is a spot measurement of balances plus `clearinghouse.free`, not a promised redemption value.

`script/v2/abi-manifest.txt` does not list `HouseVault` / `HouseVaultFactory`. Typed app modules wait on T-78's export. K8-05 / X8-07 / W8-06 cannot generate those ABIs from this commit.
