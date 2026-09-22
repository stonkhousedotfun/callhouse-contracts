# src/v2: file map

The Stonkhouse v2 contracts: one Clearinghouse for every market, an on-chain order board, oracle
settlement with automatic payout, and the periphery around them. Solidity 0.8.28, OpenZeppelin 5,
via-IR, non-upgradeable. **Unaudited** at this commit (no report, no link); audit commissioned by
`OWN8-12`, report linked by `C8-14` (`SECURITY.md` Status). Not deployed as INTERFACE_VERSION 8.

Read first:

- [docs/V2-ARCHITECTURE.md](../../docs/V2-ARCHITECTURE.md): components, trust model, oracle, keepers,
  what is not protected.
- [docs/V2-ACCOUNTING.md](../../docs/V2-ACCOUNTING.md): units, rounding, conservation, fees.
- [docs/V2-GAS.md](../../docs/V2-GAS.md) and [docs/V2-DATA-STREAMS.md](../../docs/V2-DATA-STREAMS.md).

Every contract's NatSpec states its units, trust assumptions and the decisions its task made. Tests
live under `test/v2/`, scripts under `script/v2/` (tables below).

## Core

| File | What it is | Tests |
|---|---|---|
| `Clearinghouse.sol` | ERC-1155 long and short tokens of every series; the collateral ledger (`free`), `mint` / `close`, `settle` on the oracle's price, `redeem` / `redeemBatch` with the optional USDG conversion, exercise fees, guardian pauses of new risk | `test/v2/unit/Clearinghouse*.t.sol` (markets, series, ledger, mint, settle, redeem, redeem access, payout, pauses) |
| `OrderBook.sol` | Bids (USDG escrow), resale asks (long escrow) and write-on-fill asks (mint on fill); `take` with the taker fee, seller fees and maker rebates; fee changes scheduled `FEE_CHANGE_DELAY` = 48 h ahead (`src/v2/interfaces/V2Constants.sol:60`; INTERFACE_VERSION 8 raised this from 24 h); delegates; `prune`; `owed` | `test/v2/unit/OrderBook{Orders,Take,Logs,Fuzz,FeeDelay}.t.sol`, rerun against the real Clearinghouse by `test/v2/integration/OrderBookRealClearinghouse.t.sol` |
| `ExpiryCalendar.sol` | The 16:00 New York expiry grid: DST rule, NYSE holidays, weekly = last session day of the week, special expiries, regular-session check | `test/v2/unit/ExpiryCalendar.t.sol`, vectors `test/v2/fixtures/expiries.json` (`gen-expiries.mjs --check`) |
| `KeeperRewards.sol` | USDG bounties for lifecycle calls, per-action bounty table, rolling daily cap in 6-hour epochs (`KeeperRewardsTest.test_cap_epochsReleaseOneAtATime`) | `test/v2/unit/KeeperRewards.t.sol` |
| `AutoRoller.sol` | Set-and-forget covered calls: each period writes the next call series from the writer's strategy and the oracle's spot and rests a write-on-fill ask; `reprice` for smart pricing | `test/v2/unit/AutoRoller{Cycle,Timing,Strategy}.t.sol` |
| `lib/OptionMath.sol` | Premium, collateral per unit, gross payout, exercise fee, long and short payouts, tick rounding. Pure | `test/v2/unit/OptionMath.t.sol` |

## Oracle (`oracle/`)

| File | What it is | Tests |
|---|---|---|
| `SettlementOracle.sol` | One settlement price per (underlying, expiry) over the final 1800 s (`InterfaceIdsTest.test_constants_times`): the per-expiry pin taken by the first series (`pin`, INTERFACE_VERSION 6; fails closed on any source, records `pinnedBy`, confirms a pin made elsewhere only against the current configuration), capture, corroboration, candidate with delay, guardian veto, admin resolve inside a band; `spot` | `test/v2/unit/SettlementOracle.t.sol` (chain, bounties, resolve, config, property), `test/v2/unit/SettlementOraclePin.t.sol` (pinning), `test/v2/unit/SettlementOracleSources.t.sol` (with the real sources), `test/v2/integration/PinnedSettlement.t.sol` (pinning on the real stack) |
| `ChainlinkFeedSource.sol` | Source 1: the TWAP of a Chainlink push feed over a window, walked from its round history; jump rule, staleness, phase boundary; the feed pinned per expiry for the oracles on its allow-list (refused without a feed; an earlier pin confirmed only when equal) | `test/v2/unit/ChainlinkFeedSource.t.sol`, `test/v2/fork/SourcesFork.t.sol` |
| `UniV3TwapSource.sol` | Source 2: the Uniswap v3 pool's window price, recorded within 600 s after expiry (`InterfaceIdsTest.test_constants_times`), with a harmonic-mean liquidity floor; the pool and floor pinned per expiry (refused without a pool; an earlier pin confirmed only when equal) | `test/v2/unit/UniV3TwapSource.t.sol`, `test/v2/fork/SourcesFork.t.sol` |
| `DataStreamsSource.sol` | Source 3, built and **disabled**: Chainlink Data Streams v11 reports verified through the VerifierProxy, a ring of observations, sealed windows; the feed version pinned per expiry (refused without a feed id; an earlier pin confirmed only at the current version) | `test/v2/unit/DataStreamsSource.t.sol`, `test/v2/fork/DataStreamsFork.t.sol` |
| `OracleDeps.sol` | The external surfaces the sources read: Chainlink AggregatorV3 proxy, Uniswap v3 pool oracle, Stock Token `oraclePaused()` | — |
| `DataStreamsDeps.sol` | The v11 report struct, the VerifierProxy surface and `uiMultiplier()`, with the upstream commits they were taken from | — |
| `lib/PriceLib.sol` | Feed answer normalisation to USDG 6 dp per share, and the round jump rule | `ChainlinkFeedSourceTest.test_priceLib_normalizeAnswer_table`, `ChainlinkFeedSourceTest.test_priceLib_exceedsJump_table` |
| `lib/FullMath.sol`, `lib/TickMath.sol` | Vendored unchanged from Uniswap v3-core branch `0.8` at `6562c52` (FullMath MIT, TickMath GPL-2.0-or-later); do not edit, diff against the URL in each header | exercised by `test/v2/unit/UniV3TwapSource.t.sol` |

## Access (`access/`)

One OpenZeppelin `AccessManager` for every privileged function. Role ids and execution delays live
in `script/v2/roles.v8.json`, mirrored by `V8Roles.sol`. Targets hold no role table.

| File | What it is | Tests |
|---|---|---|
| `access/Managed.sol` | Thin `AccessManaged` base: an unauthorised caller reverts `V2Errors.NotAuthorized()` instead of `AccessManagedUnauthorized(address)` | `test/v2/unit/ManagedAccess.t.sol` |
| `access/V8Roles.sol` | Compiled `uint64` role ids and per-role delays; the JSON is the source of truth | `test/v2/unit/AccessMatrix.t.sol` |
| `access/V8AccessManagerArtifact.sol` | Bare import of unmodified OpenZeppelin `AccessManager` so `out/AccessManager.sol/AccessManager.json` exists for DeployV8 / VerifyV8 / `export-abis.sh` | — |

## Periphery and market making

| File | What it is | Tests |
|---|---|---|
| `periphery/UniV3PayoutAdapter.sol` | Sells an ITM call payout's Stock Tokens for USDG in one Uniswap v3 pool through SwapRouter02; all-or-nothing; holds nothing; `routeFeeBps` reports each route's fee tier in bps, which the Clearinghouse adds to its slippage bound; `setRoute` refuses a tier above 1 %. Superseded by `PayoutRouter` for new wiring; still compiled | `test/v2/unit/UniV3PayoutAdapter.t.sol`, `test/v2/unit/UniV3PayoutAdapterClearinghouse.t.sol`, `test/v2/fork/PayoutFork.t.sol` |
| `periphery/PayoutDeps.sol` | The SwapRouter02 and factory surfaces the adapter calls | — |
| `periphery/PayoutRouter.sol` | INTERFACE_VERSION 8 payout adapter: one per-asset route to USDG over Uniswap v3 or a pinned hookless v4 pool. Replaces `UniV3PayoutAdapter` for the Clearinghouse and the FeeSplitter | `test/v2/unit/PayoutRouter.t.sol` |
| `periphery/FeeSplitter.sol` | INTERFACE_VERSION 8 fee sink: accept USDG and Stock Token pushes, convert under an oracle ok-spot floor, split into buyback vs treasury, spend the buyback balance through a swappable executor | `test/v2/unit/FeeSplitter.t.sol` |
| `periphery/V4BuybackExecutor.sol` | Pinned v3 USDG→WETH then v4 native-ETH→token buy for the FeeSplitter; only the splitter may call `buy` | `test/v2/unit/V4BuybackExecutor.t.sol`, `V4BuybackExecutorFees.t.sol` |
| `periphery/BuybackDeps.sol` | Uniswap v4 PoolKey / SwapParams / PoolManager / StateView surfaces plus the v3 pool and Pons launch-hook types the executor reads | — |
| `periphery/v4/V4Types.sol` | Canonical INTERFACE_VERSION 8 import path for the shared v4 types (`V4Currency` re-exports `BuybackDeps`) | — |
| `periphery/v4/V4UnlockCallback.sol` | The Uniswap v4 lock pattern once, for every v8 contract that swaps on v4 | — |
| `periphery/StockZap.sol` | Stateless, role-less helpers over the PayoutRouter's guardian-pinned routes (write zap / exit zap); `clearRoute` is the kill switch | `test/v2/unit/StockZap.t.sol` |
| `periphery/house/HouseVault.sol` | User-funded market maker, one instance per market; depositors hold ERC-20 shares; no role can send a non-share asset to an arbitrary address | `test/v2/unit/HouseVault{Base,Epoch,Guards,Interface}.t.sol` |
| `periphery/house/HouseVaultFactory.sol` | LISTING deploys one HouseVault per market and indexes them; each new vault still needs its own AccessManager `setTargetFunctionRole` batch | — |
| `mm/MakerVault.sol` | The treasury-funded market maker: a QUOTER bot (AccessManager role 9) quotes and trades inside price and size guards; no quoter call pays anyone but the vault, and from INTERFACE_VERSION 8 vault money leaves only to `treasury`, though a compromised quoter can still trade value out to a counterparty inside the outflow cap | `test/v2/unit/MakerVault{Quoter,Guards}.t.sol` |
| `mm/MakerRegistry.sol` | Per-maker rebate tiers the OrderBook reads on every fill | `test/v2/unit/MakerRegistry.t.sol` |
| `mm/RewardsDistributor.sol` | Weekly Merkle claims of USDG maker rewards (OpenZeppelin StandardMerkleTree format) | `test/v2/unit/RewardsDistributor.t.sol`, vector `test/v2/fixtures/maker-epoch-2958.oz.json` |

## Interfaces (`interfaces/`), frozen at INTERFACE_VERSION 8

Changing any of these is an interface change for every lane (`v8-plan/status/INTERFACE-CHANGES-V8.md`).

| File | What it is |
|---|---|
| `IClearinghouse.sol`, `IOrderBook.sol`, `ISettlementOracle.sol`, `IPriceSource.sol`, `IExpiryCalendar.sol`, `IKeeperRewards.sol`, `IAutoRoller.sol`, `IPayoutAdapter.sol`, `IMakerRegistry.sol`, `IRewardsDistributor.sol`, `IPayoutRouter.sol`, `IFeeSplitter.sol`, `IBuybackExecutor.sol`, `IFeeDiscount.sol`, `IFundingSource.sol`, `IStockZap.sol` | The cross-repo surfaces: functions, events and NatSpec the indexer, keeper and web generate their ABIs from |
| `V2Types.sol` | Shared structs and enums: `MarketConfig`, `Series`, `Order`, `OrderKind`, `TakeParams`, `FeeParams`, `SettlementStatus`, `Strategy` |
| `V2Constants.sol` | Units, time bounds, fee ceilings, roles, bounty action ids (`InterfaceIdsTest.test_constants_units` and the other `test_constants_*` tests pin them) |
| `V2Errors.sol` | Every custom error, one library; decoders merge its ABI into each contract's (`InterfaceIdsTest.test_errors_artifactAbiHasEveryError`) |
| `V2Ids.sol` | `longIdOf`, `shortIdOf`, `isShortId` (`InterfaceIdsTest.test_seriesIdVectors_matchV2IdsAndReference`, vectors `test/v2/fixtures/series-ids.json`) |

## Mocks (`mocks/`), for tests only

| File | Stands in for |
|---|---|
| `MockClearinghouse.sol` | the Clearinghouse, for the OrderBook suites written before it merged |
| `MockSettlementOracle.sol` | the SettlementOracle, answers set by the test |
| `MockOraclePriceSource.sol` | a scriptable, misbehaving `IPriceSource` |
| `MockOpenInterestClearinghouse.sol` | the Clearinghouse's `openInterest` and its call into `finalize` |
| `MockRoundFeed.sol` | a Chainlink AggregatorV3 proxy with a settable round history and phases |
| `MockUniV3Pool.sol` | a Uniswap v3 pool's oracle surface |
| `MockVerifierProxy.sol` | the Data Streams VerifierProxy and Verifier |
| `MockPayoutAdapter.sol` | a payout adapter that behaves well or badly on demand, including its `routeFeeBps` answer (any word, revert, short, gas burn) |
| `MockPayoutSwapRouter.sol`, `MockPayoutV3Factory.sol`, `MockPayoutTaxToken.sol` | SwapRouter02, the v3 factory, a fee-on-transfer token |
| `MockMakerRegistry.sol` | a registry with failure modes |

The Stock Token and USDG mocks are v1's `src/mocks/MockStockToken.sol` and `src/mocks/MockERC20.sol`
(pause, freeze, blocklist, `oraclePaused`, `uiMultiplier`, `adminBurn`).

## Tests (`test/v2/`)

| Path | What it holds |
|---|---|
| `BaseV2.t.sol` | the shared fixture: actors, clock, USDG and two Stock Token markets |
| `InterfaceIds.t.sol` | constants, id formula and error ABI pins |
| `unit/` | one suite (or several) per contract, over mocks where the neighbour is not the subject |
| `integration/V2IntegrationBase.t.sol` | every core contract, real, wired as a deploy would wire them |
| `integration/Lifecycle.t.sol` | a whole weekly ladder of calls and puts, every balance against an independent model |
| `integration/V2Gas.t.sol` | the figures of `docs/V2-GAS.md` |
| `integration/V2DocsNumbers.t.sol` | the constants and worked examples `docs/V2-ARCHITECTURE.md` and `docs/V2-ACCOUNTING.md` quote |
| `integration/OrderBookRealClearinghouse.t.sol` | the OrderBook suites against the real Clearinghouse |
| `integration/PinnedSettlement.t.sol` | the per-expiry settlement pin on the real stack: what the admin can no longer change for a live series, that pinning fails closed (a source off the allow-list, unconfigured or broken), the hidden pre-pins through the Clearinghouse pointer and each source allow-list, and the two-oracle migration |
| `invariant/V2Handler.sol`, `invariant/V2Invariant.t.sol` | the stateful suite: Clearinghouse invariants 1-5, book invariants B1-B3, invariant 6 (every expiry settles on its pinned configuration while the admin reconfigures mid-life, revokes a source's allow-list and pre-pins expiries) |
| `fork/` | against live chain 4663; they skip themselves on any other chain, so run them with `FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC` |
| `fixtures/` | series-id vectors, expiry instants and their generator, the maker-rewards Merkle vector |

## Scripts (`script/v2/`)

| File | What it does |
|---|---|
| `DeployV8.s.sol`, `RegisterMarkets.s.sol`, `VerifyV8.s.sol`, `lib/V2DeployBase.sol`, `lib/PinDryRun.sol`, `DeployV2Batch.sh`, `rehearse-v2.sh`, `batch-refusals.sh` | the production deploy, market registration and read-only verification, driven from the registry; runbook `docs/DEPLOY-V2.md` |
| `DevDeploy.s.sol` | the core set on a local anvil fork of 4663 for the devnet (callhouse `ops/devnet/up.sh`); refuses any other node. Not a production deploy |
| `EmitSeriesIds.s.sol` | regenerates `test/v2/fixtures/series-ids.json` |
| `export-abis.sh`, `abi-manifest.txt` | publish every v2 ABI listed in the manifest to callhouse `ops/abis/v2/` (`--check` for drift) |
| `FreezeV1.s.sol`, `freeze-v1.sh` | freeze the v1 solo markets; runbook `docs/V1-RUNOFF.md` |

