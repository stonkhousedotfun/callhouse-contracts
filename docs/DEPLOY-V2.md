# Deploying Stonkhouse v2

The v2 contracts (`src/v2/`, unaudited) go to chain 4663 as ONE set for every market. At
**INTERFACE_VERSION 8** that set is **twenty-two contracts** — one OpenZeppelin `AccessManager` and
twenty-one targets that hold no roles of their own — governed as one, then markets registered on it
wave by wave. Twenty-two reconciles three ways: twenty-two `address` fields on `struct Contracts`,
and twenty-one `.targets` rows in `script/v2/roles.v8.json` plus the `AccessManager` itself, which is
not a target of its own manifest.

**Only SIXTEEN of the twenty-two are CREATEd by `DeployV8`.** The other six — `HouseVault`,
`HouseVaultFactory`, `Hedger`, `RewardsDistributorLender`, `EarnVault` and `StockVenueAdapter` — are
deployed by their own tasks and arrive by environment (`V2_HOUSE_VAULT`, `V2_HOUSE_VAULT_FACTORY`,
`V2_HEDGER`, `V2_LENDER_REWARDS`, `V2_EARN_VAULT`, `V2_STOCK_VENUE_ADAPTER`).

> **ORDERING CONSTRAINT: the externally supplied contracts must already exist before `DeployV8` maps
> them.** `DeployV8._mapTarget` SKIPS an externally supplied target whose address was not given and
> says so, rather than mapping its selectors at `address(0)` — mapping at zero would send
> `setTargetFunctionRole` against nothing and leave the REAL contract unmapped, so its `restricted`
> selectors would answer to `ADMIN` by `AccessManager`'s default (06-QUIRKS §A.8). The skip is not a
> licence to run early: those selectors stay unmapped and `VerifyV8` FAILs on them until the address
> is supplied and the map is re-run. `DeployV2Batch.sh` exports the six unset-when-absent, so an
> absent one keeps its meaning instead of arriving as an empty string.
>
> **AND "THE MAP IS RE-RUN" CANNOT MEAN RE-RUNNING `DeployV8` AFTER ITS HAND-OVER (T-OP-116).** Every one
> of the six needs the core set to exist first (their constructors take the manager, the book, the splitter,
> the oracle…), so none of them CAN exist before `DeployV8` runs — and `DeployV8` maps selectors in its
> step 3 from the deployer at delay 0, then renounces `ADMIN` in its step 9. After that the deployer holds
> nothing and the only path to a mapped external would be the Admin Safe's `ADMIN` lane (48 h). **The owner
> chose to extend the deployer's ADMIN window instead (decision 2026-09-22 05:35Z; T-OP-153):**
> `DeployV8` runs with `V2_DEFER_HANDBACK=true` and stops before step 9; the **externals stage**
> (`script/v2/lib/registry-env.sh` `registry_env_externals`, called by `DeployV2Batch.sh` right after
> `DeployV8` and by `broadcast-v8.sh` at the start of its verify step) deploys each external that has a
> script, records it at `v2.contracts.<key>` and its start block at `v2.externalDeployBlocks.<key>`, exports
> its `V2_*` name; `forge script script/v2/MapExternals.s.sol` maps every SUPPLIED external's selectors at
> delay 0 from the deployer (unsupplied ones skipped by name); then — **amendment #4, T-OP-161, owner decision
> 2026-09-22 05:50Z (M-184a135e2aa74e7e)** — `RegisterMarkets` for the launch set is sent by the DEPLOYER,
> DIRECTLY, still inside the window (it holds LISTING and CONFIG_ADMIN at delay 0 from DeployV8 step 4:
> single run, no schedule, no Safe, no wait, no `rc=90`); only then `forge script script/v2/HandBack.s.sol`,
> the deferred step 9, idempotent, read back `hasRole(ADMIN, deployer) == false`; then `VerifyV8` with the
> deployer. **The accepted hot-key window is `DeployV8` → `HandBack` = deploy → write-back → externals →
> `MapExternals` → `VerifyV8` (gate) → `RegisterMarkets` → `HandBack`**, and both drivers run it back to
> back; on `broadcast-v8.sh` the window spans the operator's core write-back between step 1 and `--from
> verify`, so both are done at once. `ADMIN_PK` is REFUSED by both drivers on that path: the register step's
> signer is the deployer, and the driver exports `V2_ADMIN=<deployer>` + `ADMIN_PK=<the DEPLOYER_PK value>`
> into that one forge process itself; a second key on the box is a liability, not a fallback. The Safe's
> scheduled shape (`rc=90`, LISTING 1 h / CONFIG_ADMIN 24 h) is POST-LAUNCH only. The two scripts are called
> by exactly those names; until T-OP-153 lands they are not at this base and the stage dies naming them —
> the expected state. `--skip-external a,b` names externals the run must not deploy: the DEFAULT is the
> owner's window (`hedger` OUT; `rewardsDistributorLender` and `stockVenueAdapter` pending, skipped until
> told), `none` skips nothing, a list replaces the default; each skip is printed and `V2_SKIP_EXTERNALS`
> carries the **manifest names** (`Hedger,RewardsDistributorLender,StockVenueAdapter`, the spelling T-OP-140
> landed in `VerifyV8`) to `MapExternals` and `VerifyV8`; a key whose address is recorded or exported is
> refused, never skipped.

> **THE SIX, THEIR SCRIPTS AND THE OWNER'S WINDOW (T-225, re-counted by T-OP-116 / T-OP-141 / T-OP-153).**
> "Deployed by their own tasks" describes the intended contract; this is the state of the repository and
> the order the externals stage deploys in:
>
> | externally supplied | supplied by | deploy task in this repo | externals stage (owner window) |
> |---|---|---|---|
> | `HouseVaultFactory` | `V2_HOUSE_VAULT_FACTORY` | **`script/v2/DeployHouseVault.s.sol`** (T-OP-141; not at this base) | 1st, pass A: the factory (core only) |
> | `HouseVault` | `V2_HOUSE_VAULT` | the same script, pass B: `factory.createVault` per launch ticker, sent by the deployer under its transient LISTING self-grant once `MapExternals` has mapped the fresh factory | 1st, pass B; `v2.contracts.houseVault` = the first launch ticker's vault |
> | `EarnVault` | `V2_EARN_VAULT` | **`script/v2/DeployEarnVault.s.sol`** (production; devnet has `DevDeploy._deployEarnVault`) | 2nd: core only |
> | `StockVenueAdapter` | `V2_STOCK_VENUE_ADAPTER` | inside `DeployEarnVault.s.sol`, after the vault, only when `V2_EARN_VENUE` names an ERC-4626 over USDG (`v2-sources.json contracts.earnVenue.address`, which no recon file carries yet) | **skipped by default** (pending the owner) |
> | `RewardsDistributorLender` | `V2_LENDER_REWARDS` | **`script/v2/DeployLenderRewards.s.sol`** (`V2_STONKHOUSE_TOKEN` from registry `shared.token.address`) | **skipped by default** (pending the owner) |
> | `Hedger` | `V2_HEDGER` | none; the constructor needs a Morpho address on 4663 that no registry or recon file names | **skipped by default** (owner: OUT, never removed from the manifest) |
>
> A skip is printed and exported; an external that is neither skipped nor deployable is "reported
> UNSUPPLIED" — a printed line and a `VerifyV8` FAIL on that target — never silently skipped.
>
> The consequence is not that a run breaks. It is that the run SUCCEEDS and the component is absent:
> `_mapTarget` skips it, `VerifyV8` FAILs on its selectors, and the only thing standing between that
> and a launch is someone reading the failure. `ART_EARN_VAULT`, `ART_HEDGER`, `ART_HOUSE_VAULT`,
> `ART_HOUSE_VAULT_FACTORY` and `ART_STOCK_VENUE_ADAPTER` are all declared in
> `script/v2/lib/V2DeployBase.sol:163-169` and none of them is ever passed to `_create` — the artifact
> path was prepared and never used.
>
> **`StockZap` is worse and is not even on the list above.** It has no `ART_` constant, no
> `Contracts` field and no `V2_*` input, so it cannot arrive by address either; the only mentions of
> it in `script/` are the unmanaged-target note in `roles.v8.json` and its line in
> `abi-manifest.txt`. Meanwhile `web/lib/v2/config.ts` already lists `stockZap` among its address
> keys, so a consumer reads an address that nothing upstream can produce — and that file's own
> `local !== upstream` cross-check compares `null` to `null` and reports nothing.
>
> **`StockVenueAdapter` is blocked on an owner input, not on code.** Its constructor requires an
> EXISTING ERC-4626 venue whose `asset()` is the USDG the vault holds
> (`src/v2/periphery/earn/adapters/Erc4626VenueAdapter.sol:60-67`) and fails closed on a zero
> address. No such venue is named anywhere in this repository. Until one is chosen the Earn vault
> deploys with `adapter == address(0)` and its venue sweeps are unreachable — which is the safe
> state, and deliberately not papered over by passing zero.
>
> **The devnet does not mirror this path.** `script/v2/DevDeploy.s.sol` deploys the v7
> `UniV3PayoutAdapter`, not the v8 `PayoutRouter` — `grep -c PayoutRouter script/v2/DevDeploy.s.sol`
> is zero. So the devnet cannot construct `StockZap` at all (its constructor reads `usdg()`,
> `v3Router()` and the v4 pool manager off a `PayoutRouter`, `src/v2/periphery/StockZap.sol:36-48`)
> and cannot exercise v4 payouts. "It works on the devnet" is therefore a narrower statement than it
> sounds for anything downstream of the payout router.

The sixteen CREATEd, and their order, are
`script/v2/lib/V2DeployBase.sol` (`struct Contracts`) and
`script/v2/DeployV8.s.sol:24,49,462`. Everything is driven from the registry,
`ops/markets/tier1.json` in stonkhousedotfun/callhouse, and its recon file
`ops/markets/v2-sources.json`. The v1 per-market factory rollout is cancelled (ADR-02): a registry row
with `status: superseded-by-v2` is refused by `script/DeploySoloBatch.sh` in every mode.

**Owner-gated:** every `--broadcast`, funding, and anything that reads a real key. The scripts below never
read `~/.callhouse-keys/`; keys come from the environment only and never appear on a command line.

After the contracts: callhouse `ops/deploy.md` §15.7 (registry committed, `ops/v2-env.mjs`, bots, services).

> **The v8 deploy path is half landed at this commit, and this page says which half.** Read this
> before running anything.
>
> | Piece | State |
> |---|---|
> | `script/v2/DeployV8.s.sol` | **landed and v8.** Deploys the sixteen and performs the nine-step manager hand-over |
> | `script/v2/lib/V2DeployBase.sol` | **landed and v8.** Sixteen contract fields, eight principals, the flywheel environment, the rent guard inverted |
> | `script/v2/RegisterMarkets.s.sol` | **landed and v8** for the market calls and the rent guard; still reads `V2_ADMIN` and still asserts `DEFAULT_ADMIN_ROLE` on five targets in its set preflight (`:177`, `:239-244`, `:280-285`) |
> | `script/v2/DeployV2.s.sol` | **deleted.** `DeployV8.s.sol` replaces it |
> | `script/v2/DeployV2Batch.sh` | **landed and v8.** It drives `DeployV8.s.sol` (`:1056`, wiring check `:1094`), `RegisterMarkets.s.sol` (`:1122`, `:1179`) and `VerifyV8.s.sol` (`:1214`), pins `INTERFACE_VERSION=8` (`:115`, enforced against the registry at `:194`), and holds no reference to the deleted `DeployV2.s.sol` |
> | `script/v2/VerifyV2.s.sol` | **deleted.** `VerifyV8.s.sol` replaces it, and it is what the wrapper runs (`DeployV2Batch.sh:1214`) |
> | `script/v2/batch-refusals.sh` | **landed and v8**: its cases assert the v8 messages, including "all 16 v2.contracts" (`:111`, `:122`, `:252`) and the INVERTED rent refusals (`:135`, `:161`) |
>
> `C8-10` has landed. The wrapper, the verifier and the refusal suite are all v8, so the supported
> path is `DeployV2Batch.sh` end to end: `DeployV8`, then `RegisterMarkets` per market, then
> `VerifyV8`. A direct **`forge script script/v2/DeployV8.s.sol`** with the environment set by hand
> (below) still works and is what the rehearsal section drives.

## What the registry must carry at INTERFACE_VERSION 8

`DeployV2Batch.sh` refuses a registry whose `v2.interfaceVersion` is not its own `INTERFACE_VERSION`,
which is **8** (`script/v2/DeployV2Batch.sh:122`, refused at `:201`); `tier1.json` carries 8, so they agree.
The fields below are what the v8 scripts themselves read. The ops lane owns
`ops/markets/tier1.json`, `ops/markets/build-markets.mjs` and `ops/markets/README.md` in
stonkhousedotfun/callhouse.

| Path | Value | Read or refused by | Why |
|---|---|---|---|
| `v2.interfaceVersion` | `8` (was 7) | `DeployV2Batch.sh` on any other value (`:201`, against `INTERFACE_VERSION=8` at `:122`) | selectors, event topics and tuples moved again; a v7 consumer mis-decodes a v8 deployment silently rather than failing loudly. `Clearinghouse.registerMarket` alone went `0x45baaccb` (v6) → `0xfb2a821f` (v7) → `0x9ae621ee` (v8, `registerMarket(address,uint64,bool)`). That last value was re-derived for this page with `cast sig` and agrees with the pin at `test/v2/InterfaceIds.t.sol:533-536`; do not copy a selector out of a plan document |
| `shared.safes.admin` | the **2-of-3 Admin Safe**, which must have code **on chain 4663** | `DeployV8` preflight (`V2_ADMIN_SAFE`, `script/v2/DeployV8.s.sol:383-387`) | it holds nine of the eleven roles. `DeployV8` refuses a codeless address outright, where v7's VerifyV2 only printed an `info` line |
| `shared.safes.treasury` | the **Treasury Safe**, which must have code **on chain 4663** | `DeployV8` preflight (`V2_TREASURY_SAFE`, `:388-391`) | it is the only address KeeperRewards, MakerVault, RewardsDistributor and FeeSplitter can ever pay |
| `shared.feeRecipient` | **the FeeSplitter this run deploys** | `DeployV8` (`:344-345` against a resumed splitter, `:585-589` against the one it creates, then `:594` sets it) | the splitter IS the fee recipient of both the Clearinghouse and the book; a mismatch would land every fee where the flywheel cannot reach it. The run refuses it twice over |
| `v2.fees.premiumFeeBps` | `500` (was 0) | `DeployV8` preflight, against `PREMIUM_FEE_CEIL_BPS` only (`script/v2/lib/V2DeployBase.sol:840`) | 5 % of the premium on first sale (owner decision V3-D6/V3-D17). **The v7 rule `premiumFeeBps <= resaleFeeBps` is deleted deliberately** at `script/v2/lib/V2DeployBase.sol:842` — and the live tooling agrees: `VerifyV8.s.sol:89` records the deletion, and `DeployV2Batch.sh:16` and `:314` say the same |
| `v2.fees.resaleFeeBps` | `0` | same | true resales are free; the fee is taken once, at the option's first sale |
| `v2.fees.mintFeePpm` | `0`, and **a non-zero value is refused from any script run** | `script/v2/lib/V2DeployBase.sol:486-506` (`mintFeePpmFromEnv`), which `script/v2/RegisterMarkets.s.sol:221` takes its rates from | v8 launches collateral rent at 0 on every market (V3-D18). Rent is turned on afterwards through `Clearinghouse.setMarketFees`, in the 72 h `MARKET_FEE_MANAGER` lane where it waits in the open and the guardian can cancel it. A deploy script is immediate and unreviewed and is the wrong instrument for that |
| `markets[i].v2.mintFeePpm` | absent, or `0` | same | identical rule per market. The Clearinghouse's own ceiling, `MINT_FEE_CEIL_PPM` 5000, still applies above it (`RegisterMarkets.s.sol:457-476`) |
| `v2.defaults.spotMaxAgeS` (per-market override `markets[i].v2.overrides.spotMaxAgeS`) | **`90000`** (25 h). Never `0`: 0 silently means the contract default, 1 h (`src/v2/oracle/SettlementOracle.sol:216`, substituted at `:318`) | `RegisterMarkets` preflight, `[1, 345600]` s (`script/v2/RegisterMarkets.s.sol:419`); the contract ceiling `MAX_SPOT_MAX_AGE` 4 days (`SettlementOracle.sol:217`); `DeployV2Batch.sh:511` merges it over `v2.defaults.spotMaxAgeS` and `:748` exports it as `V2_MARKET_<T>_SPOT_MAX_AGE_S` | **one value, many consumers**: `SettlementOracle.spot`/`trySpot` freshness (`:420`, `:429`), so the AutoRoller's roll strike and ask (`AutoRoller.sol:505`), `Clearinghouse._floorPrice` (`:1171`), and every vault's quote check. Owner sign-off c01 chose 25 h for the conversion floor. **Since T-OP-061 / T-OP-087 (2026-09-22) this value is the bound of the UNCORROBORATED path only, and the accuracy rule governs**: a source-0 print at most `SPOT_CORROBORATION_AGE` (30 min) old is ok; an older print on a dual-source market is ok iff the pool agrees within `maxDeviationBps`, up to the compiled `MAX_SPOT_MAX_AGE` (4 days), never bounded by this value; only a single-source market, or a dual-source one whose pool is not ok, falls back to "ok iff at most `spotMaxAgeS` old" (`SettlementOracle._spot`). Owner decision 1 (the AutoRoller-only knob) is CLOSED by that rule ([V8-ACCEPTED-RISKS.md](V8-ACCEPTED-RISKS.md#sec-08b--autoroller-roll-pricing)); the value is a configuration for the 33 single-source markets, not a security dial for the launch pair |
| **not in the registry:** `v2-sources.json` `contracts.v4PoolManager.address` / `contracts.v4StateView.address`. There is no `v2.uniswapV4` key, and `build-markets.mjs --check` refuses one, naming this recon path (`validateV2Top`; the note beside `V2_SKELETON.uniswapV3` says why there is no v4 sibling) | the v4 PoolManager and the StateView lens over it; both are in the recon with `codeExists: true` | `DeployV2Batch.sh:312-313` reads them and `:686` exports them; `DeployV8` (`V2_V4_POOL_MANAGER`, `V2_V4_STATE_VIEW`, `script/v2/lib/V2DeployBase.sol:387-388`, code checked at `DeployV8.s.sol:425-426`) | new in v8: the `PayoutRouter`'s v4 leg and the buyback executor's |
| the STONKHOUSE pool pins | `V2_WETH`, `V2_BUYBACK_V3_POOL` from `v2-sources.json` `contracts.weth.address` / `contracts.usdgWethV3Pool.address` (**neither key is in the recon yet**, so the wrapper refuses by name at `DeployV2Batch.sh:354-360`); `V2_TOKEN_POOL_CURRENCY0/1`, `_FEE`, `_TICK_SPACING`, `_HOOKS` from `shared.token.poolKey` (all five `null` in `tier1.json` today). **Not** `v2.flywheel`: its only keys are `feeSplitter`, `buybackExecutor` and `deployBlock` (`build-markets.mjs` `V2_SKELETON.flywheel`, closed by `validateV2Top`) | `DeployV8` preflight (`script/v2/lib/V2DeployBase.sol:442-469`, ceilings and code checks at `DeployV8.s.sol:474-496`) | the buyback venue is pinned at construction. `V2_TOKEN_POOL_CURRENCY0` **must be native ETH (the zero address)**: the v4 leg spends ETH |
| `markets[i].v2.univ3Pool` / `univ3MinLiquidity` | **present only when the recon shows `cardinality >= 2401`** | `DeployV2Batch.sh` from the recon file, the `RegisterMarkets` preflight from `slot0()` on chain, `UniV3TwapSource.setPool` itself, and the verifier after the fact | owner sign-off c10: a shorter ring can be flooded past an expiry's settlement window before the snapshot grace ends. A market without a pool registers Chainlink-only, which also drops its payout route (it pays in kind). To re-add one later: `increaseObservationCardinalityNext(2401)` on its pool, wait for `slot0().observationCardinality` to reach it, re-run the recon, then `--resync` that market |

Not in the registry, and not needed there: the six keeper bounties, the MakerVault limits, and the
whole flywheel parameter set. They default from `script/v2/lib/V2DeployBase.sol` `LAUNCH_*` (`:47-104`)
and are each overridable by a `V2_*` variable; an override is printed in the plan and is part of the
rehearsal fingerprint.

### The rent opt-in is a test-only code path, and v8 inverted which way it points

v7 refused a rate of **0**, because `premiumFeeBps` was 0 and the rent was then the only writer fee.
v8 takes 5 % of the premium on first sale and launches rent at 0 everywhere, so **0 is the expected
value and a non-zero one is what must never reach the chain from a script**
(`script/v2/RegisterMarkets.s.sol:326-334`).

The machinery is the same unspoofable one, and only the sense of the test changed. The opt-in is gated
on the **forge subcommand**, in `V2DeployBase.rentAllowed` / `_inTestContext` (`:484-508`):
`vm.isContext(ForgeContext.TestGroup)` is true under `forge test`, `forge coverage` and `forge
snapshot`, and `forge script` reports `ScriptDryRun`, `ScriptBroadcast` or `ScriptResume` — never
`TestGroup`. Both ways in pass through that one gate: `V2_ALLOW_RENT` from the environment
(`:469-472`), and an `Inputs.allowRent` built in Solidity. So:

- `forge script script/v2/RegisterMarkets.s.sol --rpc-url <live 4663> --broadcast` with
  `V2_ALLOW_RENT=true` and a market at a non-zero rate **reverts** with the rent refusal;
- the same run **without** `--broadcast` reverts identically — a dry run has to answer what a broadcast
  would;
- `forge test` keeps the opt-in, which is the one place it is legitimate.

Nothing an operator controls moves that gate — not an environment variable, a wrapper flag,
`--rpc-url`, the chain id, a fork or the block clock. The chain id in particular proves nothing here:
an anvil fork of 4663 reports 4663, and a fresh fork's head block is minutes old. The devnet path is
untouched: `DevDeploy.s.sol` reads its own `MINT_FEE_PPM` and defaults it to 0 without any refusal.
**Landed:** `DeployV2Batch.sh` carries the v8 flag surface. There is no `--allow-zero-rent` and no
`V2_ALLOW_ZERO_RENT` anywhere in it; the flag is `--allow-rent` (`:155`), it is refused with
`--broadcast` and outside `--dry-run` (`:202-203`), and `V2_ALLOW_RENT` is never exported (`:601`).

## The scripts

| Script | What it does |
|---|---|
| `script/v2/DeployV8.s.sol` | preflight, CREATE of the sixteen contracts from **one** signer, then the nine-step hand-over to the `AccessManager`, then a post-check. `V2_WIRING_CHECK=true`: read-only, reverts `"hand-over incomplete: N call(s) pending"` (`:138-144`). Idempotent — it plans every batch first and sends only what the chain does not already hold, and `"hand-over already complete: nothing to send"` is a clean exit (`:181-185`) |
| `script/v2/RegisterMarkets.s.sol` | per ticker: preflight of token, feed, parameters and pool, and that the oracle names the Clearinghouse; then `setOracle` on the sources the market lists, `setFeed`, `setPool`, `setMarket`, the removal of a pool the registry dropped (after `setMarket` unlisted it: pinning fails closed on a listed source without configuration), the payout route from `markets[].v2.payoutRoute` (`setRouteV4` when venue is v4; a null route is reported, not skipped), and the Clearinghouse calls last. **v8 split v7's one `registerMarket` tuple into up to three calls** on three different lanes: `registerMarket(asset, strikeTick, enabled)` on `LISTING`, `setMarketOracle` on `CONFIG_ADMIN`, `setMarketFees` on `MARKET_FEE_MANAGER`. `--resync` sends `setMarketListing` instead of `registerMarket`. `V2_SCHEDULE=true` (every mode but `--verify`) makes each delayed call schedule → wait → execute from the Safe, as **two** invocations selected by `V2_SCHEDULE_PHASE=schedule|execute`: the wait is a node-clock jump, and a single run that meets a delayed call is refused rather than reverting on chain (`vm.warp` moves the script's EVM, not the node). Delays come from `roles.v8.json` |
| `script/v2/VerifyV8.s.sol` | read-only, and **the v8 verifier**. Bytecode, immutables, pointers, roles, fees, ceilings, the calendar, the vault's approvals and limits, and every registered market's config against the registry, with a dry run of the pin its next series makes. Prints `ok`/`FAIL`/`info` lines, reverts on any FAIL, and ends with `VERIFY PASSED: N checks` (`:213`) |
| `script/v2/lib/V2DeployBase.sol` | the `V2_*` environment the scripts share, the `LAUNCH_*` values the registry does not hold, artifact paths, and the rent gate |
| `script/v2/lib/PinDryRun.sol` | the verifier's pin dry run: calls `pin` under a cheatcode prank and reverts with the outcome (simulation only) |
| `script/v2/roles.v8.json` | **the role manifest, read at run time by the deploy script itself.** `DeployV8` maps every selector from it, grants every role from it at the delay it names, and builds the role-admin and role-guardian trees from it. A target it names that the script does not deploy is a hard revert (`:1252`), as is a holder it does not know (`:1267`) |
| `script/v2/pin-deployed.sh` | the only writer of `script/artifacts/v2-4663/`: builds a clean checkout of the commit that deployed the live set, proves each runtime and deploy transaction against the chain, and writes the pinned artifacts and their manifest. `--check` regenerates and compares ("Pinned deployed runtimes" below). It pins the **v7** set today |
| `script/v2/DeployV2Batch.sh` | the wrapper, **v8 at this commit**: INTERFACE_VERSION 8, sixteen recorded contract keys (`CONTRACT_KEYS`; the recorded-set size is DERIVED from that list as `NKEYS`, never a literal, and the six externally supplied contracts are deliberately not in it), `--allow-rent`, `--register-only` (no CREATE; register DISABLED, then a listing pass that records `v2.status=live` in the write-back and lists only `planned` markets; routes as CONFIG_ADMIN from `payoutRoute`). **The externals stage (T-OP-116 / T-OP-153)** runs right after `DeployV8` (which runs with `V2_DEFER_HANDBACK=true`) and before the markets: `DeployHouseVault.s.sol` (two passes), `DeployEarnVault.s.sol`, `DeployLenderRewards.s.sol` (the last skipped by default), each recorded at `v2.contracts.<key>` + `v2.externalDeployBlocks.<key>`, then `MapExternals.s.sol` (selectors mapped at delay 0 by the deployer); **the markets are then registered by the DEPLOYER directly while its window is open (T-OP-161: `run_forge_direct`, path decided by reading the manager — `register path:` in the log) and `HandBack.s.sol` (the deferred step 9) runs AFTER them, phase 2c**; a closed window (a later wave, `--resync`, `--register-only` after the hand-back) takes `run_forge_scheduled` — the Safe's lanes, `rc=90`, post-launch only. `ADMIN_PK` in the environment is refused in every mode; a deployer that is a registry principal is refused before step 1. `--skip-external a,b` (default: the owner's window) opts out by name. `--no-schedule` is refused for any run that registers or lists, and accepted on `--deploy-only`. `--wave` reads both the top-level `waves` map and `markets[].v2.wave` and refuses a registry where they disagree. `--rehearse` / `--broadcast` / `--verify` |
| `script/v2/broadcast-v8.sh` | **the launch driver (OWN8-03).** Dry run by DEFAULT; `--execute` AND `--chain-id <n>` are both required and a chain mismatch aborts before a transaction exists. Sequences deploy → externals → `VerifyV8` (gate) → **register, by the DEPLOYER directly (T-OP-161)** → `HandBack` → `VerifyV8` with the deployer, and **registration is unreachable unless `VerifyV8` passed in THAT run against THAT deployment**: the pass is bound to a fingerprint over chain id, the 16 `CONTRACT_KEYS` addresses and their **code hashes**, written to `<run-dir>/verify-passed.json`, and the fingerprint is re-derived from the chain immediately before registering. A missing receipt, a missing field, a chain that does not match, or a deployment whose code moved all refuse. `--from deploy\|verify\|register` resumes a stopped run and cannot be used to skip the gate. Keys are read from the environment by the forge scripts; a key-shaped argument is refused by name. **Step 1 runs `DeployV8` with `V2_DEFER_HANDBACK=true` and step 1b (T-OP-116 / T-OP-153)**, at the start of the verify step after the operator's core write-back, is the externals stage: the deploy scripts, the write-back of `v2.contracts.<key>` / `v2.externalDeployBlocks.<key>`, `MapExternals.s.sol`; then step 2 `VerifyV8` with the deployer group deferred (`V2_DEPLOYER` removed: it still holds ADMIN by design) and `V2_EXPECT_FRESH=true` on a fresh deploy; step 3 `RegisterMarkets` per launch market **as the deployer** (`V2_ADMIN=<deployer>`, `ADMIN_PK` from `DEPLOYER_PK` inside that process, no `V2_SCHEDULE`; a closed window is refused by name); step 4 `HandBack.s.sol` + `hasRole(ADMIN, deployer)==false` read back; step 5 `VerifyV8` with the deployer, the receipt then carries `handBack: "done"` — the deployer holds ADMIN from step 1 until step 4, so the write-back and `--from verify` are done at once. An external `ADMIN_PK` is refused at preflight; so is a deployer that is any registry principal. The run dir lives under `./broadcast/v8-launch/` (foundry's one read-write path; a `--run-dir` elsewhere is refused by name). `--skip-external a,b` as in the wrapper |
| `script/v2/BroadcastV8.s.sol` | the read-only fingerprint the driver binds to. **Never sends a transaction** — there is no `startBroadcast` in the file and `broadcast-v8.sh` asserts that before running it. Reverts on an empty address list, a list shorter than `V8_MIN_CONTRACTS`, an address with no code, and a missing `V8_EXPECT_FINGERPRINT`: every one of those is the ABSENT case, and a digest over an absent set hashes happily and matches itself for ever |
| `script/v2/rehearse-v2.sh` | starts an anvil fork on port 8551, runs the batch `--rehearse`, the verifier on the copy, then four drills. `REGISTER_ONLY=1` deploys once then registers the owner D5 19 through the listing path. See `docs/V8-LISTING-REHEARSAL.md` |
| `script/v2/batch-refusals.sh` | every refusal of `DeployV2Batch.sh` and the v1 batch's superseded-by-v2 refusal that needs no node. Measured this task against `script/v2/fixtures/registry-v8.json`; the printed `REFUSALS PASSED: N cases` is the count, not a remembered number. |
| `script/v2/check-env-names.sh` | **containment for the `V2_*` env seam** between the wrapper and the forge scripts. Lifts `CONTRACT_KEYS`, `EXTERNAL_KEYS` and `env_name()` out of `DeployV2Batch.sh` and the `vm.envOr("V2_…")` readers out of `V2DeployBase.contractsFromEnv()` (never a copied list) and refuses, by name, an emitted env name nothing reads (`unread`), two keys on one name (`collision`) or a key with no case (`unmapped`). Catches the T-OP-022 shape: `payoutAdapter` exported as `V2_PAYOUT_ADAPTER` while every forge step read `V2_PAYOUT_ROUTER`, so a `--resume` deployed a second router and `RegisterMarkets` refused `V2_PAYOUT_ROUTER is zero`. Runs in CI before the toolchain; run it by hand whenever `CONTRACT_KEYS`, `env_name()` or `contractsFromEnv()` changes. `--self-test` derives its fixtures from the live files. |
| `script/v2/check-fork-floors.sh` | **containment for the fork execution floor.** Enumerates `test/v2/fork/*.t.sol` every run (never a list of names) and refuses, by file, any suite that does not import `ForkFloor` (`no-import`) or never calls `ForkFloor.requireExecutedAgainstRealFork` (`no-floor`). Catches the T-588 / T-OP-031 shape: a suite guarded only by `block.chainid != 4663 → vm.skip`, which under `FOUNDRY_PROFILE=fork` with no reachable fork prints `0 failed`, exits 0, and reads as a run that checked the chain. Runs in CI before the toolchain and before the fork job; run it by hand when adding a file under `test/v2/fork/`. It reads text only — it cannot judge whether a witness is honest or whether the floor test carries a skip guard; the floor's own comment and a reader do that. |
| `script/v2/check-deploy-inputs.sh` | **containment for the registry → wrapper input seam (T-OP-112; the sourced library since T-OP-137).** Lifts every `jqr '…'` / `jq -r '…'` / `jq -e '…'` path expression out of `DeployV2Batch.sh` **and out of every library the wrapper sources** at run time (never a copied list; the library paths are derived from the wrapper's own `. "$ROOT/…"` lines — T-OP-113 moved `CONTRACT_KEYS`, `EXTERNAL_KEYS`, `jqr()` and about half of the reads, the input reads included, into `script/v2/lib/registry-env.sh`, and a wrapper-only scan died rc=2 at the tip), notes which file each reads (registry, `v2-sources.json`, `roles.v8.json`, a `markets[]` row) and classifies it by where it occurs — a wrapper read by its own line; a read inside a library function by the wrapper line that calls that function (transitively, earliest call wins); a top-level library read by the wrapper's source line; a library function the wrapper never calls listed `uncalled` by name, never dropped: INPUT (before the first `run_forge`, must be non-null, EIP-55 with `cast`, and with `--rpc` holding code), MARKET (evaluated for every row), POST (re-reads of write-back results, listed), WRITE-BACK (every path `write_back()` assigns — today `v2.contracts.*`, `v2.flywheel.*`, `v2.deployBlock`, `v2.bots.*`, `markets[].v2.registeredAt/registerTx/status` — derived by shape from EVERY function in the wrapper and its libraries whose `node -e` body writes the registry (`write_back()`; T-OP-116's `registry_env_record_external()`): a literal `reg.v2.<path> =`, a per-market `m.v2.<leaf> =`, and a variable-keyed `reg.v2.<group>[k]` / `` `v2.<group>.${k}` `` whose key set comes from the branch's `Object.entries({…})` names, the deploy JSON (`CONTRACT_KEYS`), or the node argument at that position followed through the bash positional parameters and every caller until a `for <v> in $<LIST>` loop (`<LIST>` a column-0 word list lifted by name: `CONTRACT_KEYS`, `EXTERNAL_KEYS`, `EXTERNAL_DEPLOY_ORDER`, …) or a bare key at the call site (`externals_landed houseVaultFactory "$addr" …`) is found — so `v2.contracts.<external>` and `v2.externalDeployBlocks.<external>` are lifted without a list typed into the check, and a write whose key set cannot be derived is rc=2 by name; each KEY must exist in the skeleton, or the post-deploy write-back is refused by the builder's `exactKeys`). Null-by-design reads (`shared.feeRecipient`, `poolKey.currency0`, rehearsal `v2.bots`, unregistered/Chainlink-only market fields) are excused only by a rule bound to a literal line that must still occur exactly once across the wrapper and its libraries, else `stale-condition`; the four derivation anchors (`CONTRACT_KEYS`, `EXTERNAL_KEYS`, `write_back()`, `jqr()`) must likewise match exactly once across the union, and the carrying file is named. `--recorded none|any|all` states whether the recorded set must be null (a fresh launch), present (a resume) or either. `$1`-parameterised reads (`contract_of`, `bot`) are expanded from the wrapper's own key lists and call sites; the six `EXTERNAL_KEYS` reads are reported `unhomed` — absent by design AND with no key in either skeleton. Catches the T-OP-081/T-OP-108 shape: five null inputs on the real registry, each a stop of the broadcast found only after a full solc compile. Wired as step 0a of `broadcast-v8.sh` (with `--rpc`, `--recorded` from `--from`), step 0 of `rehearse-v2.sh`, and two CI steps (`--self-test`, then the committed fixture pair — red until the fixture carries the pool key and the per-market write-back keys). `--self-test` derives its fixtures from `fixtures/registry-v8.json` and from scratch copies of whichever scanned file carries the line under test (`--lib <rel>=<copy>`, accepted only inside the self-test): a moved null-ok anchor → `stale-condition`; one INPUT read hidden in the library → the derived count drops by exactly one, the null is refused by name through the real files and passes through the copy (the list is derived, not typed); an uncalled library function → reported by name; a scratch wrapper with an `externals` write-back kind over `$EXTERNAL_KEYS` → all six `v2.externalDeployBlocks.*` keys demanded, the same kind keyed by a name typed in the JS → rc=2, and a scratch library carrying T-OP-116's actual shape (a `process.argv` destructure, two bash hops on `$1`, three keys via `for k in $EXTERNAL_DEPLOY_ORDER` and three as bare literals at the call site) → six `v2.contracts.<external>` and six `v2.externalDeployBlocks.<external>` keys demanded through the call chain; and a refusal raised inside the derivation's nested command substitutions must reach the exit code (a `die` inside `$(...)` exits only the subshell — measured, then guarded). Cannot see a read made through anything but a `jq` literal, nor whether a non-null value is the right one (VerifyV8's job). |

Unit tests (`forge test`): `test/v2/unit/DeployV2Preflight.t.sol`, `RegisterMarketsPreflight.t.sol`,
`VerifyV8.t.sol`, `VerifyV8Pinned.t.sol`, `DeployV2Env.t.sol` (every `V2_*` name read into the right
field), `ZeroRentLocality.t.sol` (the rent gate is unreachable from every script context), and
`AccessMatrix.t.sol` (the role manifest against the tree). Fork:
`test/v2/fork/PinnedRuntimesFork.t.sol` (the bytecode group from this checkout against the live v7
addresses). **None of these was run for this revision of the page** — see "What the verifier checks".

## What is deployed

Sixteen contracts, in this order, from **one** signer. v7 had two — `DEPLOYER_PK` created and
`ADMIN_PK` wired, because every constructor granted `DEFAULT_ADMIN_ROLE` to `V2_ADMIN`. v8 has one:
the deployer is the manager's initial `ADMIN`, maps the selectors, grants itself the working roles at
delay 0, wires, grants the real holders, sets the role tree and renounces. `ADMIN_PK` is not read by
`DeployV8` at all (`script/v2/DeployV8.s.sol:38-41`).

Every contract but the manager takes the manager as its `authority` and holds no role of its own.

| # | Contract | Constructor | Line |
|---|---|---|---|
| 1 | `AccessManager` (OpenZeppelin v5.7.0, unmodified) | `(deployer)` — the deployer is the **initial ADMIN at delay 0**, and renounces it as the last call of the run | `:552` |
| 2 | `FeeSplitter` | `(manager, usdg, treasurySafe, burnBps)`. Before the Clearinghouse because it **is** the Clearinghouse's `feeRecipient_`, which that constructor refuses to leave zero | `:568` |
| 3 | `ExpiryCalendar` | `(manager, V2_HOLIDAYS)`. Before the Clearinghouse, which requires it to have code | `:587` |
| 4 | `ChainlinkFeedSource` | `(manager)` | `:591` |
| 5 | `UniV3TwapSource` | `(manager, usdg)` | `:595` |
| 6 | `DataStreamsSource` | `(manager, VerifierProxy)`: deployed, never configured | `:599` |
| 7 | `SettlementOracle` | `(manager)` — **one** argument; v7 took `(admin, guardian)` | `:605` |
| 8 | `KeeperRewards` | `(usdg, manager, treasurySafe)` — v8 added the treasury, so bounty money can only ever leave to the Safe | `:611` |
| 9 | `Clearinghouse` | `(manager, usdg, expiryCalendar, feeRecipient, baseUri)` | `:621` |
| 10 | `OrderBook` | `(clearinghouse, manager, guardianKey, feeRecipient, fees)`. **The one target still on v7 `AccessControl`**: the manager is passed as its `admin` so no EOA holds `DEFAULT_ADMIN_ROLE`, and its wiring is sent through `manager.execute`. `C8-03` makes it `Managed` | `:638` |
| 11 | `AutoRoller` | `(orderBook, manager)` | `:645` |
| 12 | `PayoutRouter` | `(manager, usdg, swapRouter02, v4PoolManager, v4StateView)` — replaces `UniV3PayoutAdapter` | `:649` |
| 13 | `MakerRegistry` | `(manager)` | `:656` |
| 14 | `MakerVault` | `(orderBook, manager, treasurySafe, limits)` — the third argument is the **treasury**, not the quoter key as in v7 | `:663` |
| 15 | `RewardsDistributor` | `(usdg, manager, treasurySafe)` | `:669` |
| 16 | `V4BuybackExecutor` | one `V4BuybackConfig` struct. **Last**, because it pins the splitter. It has no privileged function and no admin at all | `:679` |


> **These sixteen line numbers were re-derived on 2026-09-21 by `T-526` and all sixteen match.**
> `C8-11 (DEPLOYSEC)` recorded this table as the riskiest block it wrote — its numbers came from a
> research pass, and its author expected "a handful still off by a line or two". They were off by far
> more: `T-494` found every entry drifted, by +82 for the nine before the Clearinghouse and +85 for the
> seven from it onward. Each cite here was matched against its `d.<field> = _create(` site in
> `script/v2/DeployV8.s.sol`, and shifting any one of them by a single line turns that check red. All 56
> explicit `path:line` cites in this document were also range-checked and all 56 resolve.
> Re-derive rather than trust this note if the deploy order changes: nothing enforces it automatically.

Line numbers are `script/v2/DeployV8.s.sol`. Every create goes through `_create` (`:702-709`), from
`vm.getCode(artifact)` rather than a `new` expression, because a script contract holding the whole set's
init code would exceed any limit; forge records each as a CREATE and Sourcify matches it to its artifact.

**Runtime sizes and gas are not restated on this page for v8.** The figures that stood here were
measured on the thirteen-contract v7 set on 2026-09-17 and are wrong for a sixteen-contract set with
three new contracts and a different access base. Read them from `forge build --sizes` and from the
run's `deploy-run-latest.json` at the time you deploy, and record them in the rehearsal record below.
`forge build --sizes` exits 1 on this repository regardless, because the **v1** `src/Vault.sol` is
25,775 B: that predates v2, is byte-identical to the sweep base, and is fine under chain 4663's
98,304 B limit.

### The hand-over, in nine steps

This is the part of a v8 deploy that has no v7 equivalent, and the part that is most expensive to get
wrong. `AccessManager.canCall` resolves `getTargetFunctionRole(target, selector)` and then
`hasRole(role, caller)`, special-casing only `setAuthority` — so **`ADMIN` has no implicit access to
any target function**. A deployer holding nothing but `ADMIN` cannot send `clearinghouse.setMinter`,
not directly and not through `manager.execute`. The order below is the one that works
(`script/v2/DeployV8.s.sol:43-63`, planned at `:190-196` and sent in that order):

1. `AccessManager(deployer)` — the deployer is the initial `ADMIN` at delay 0.
2. The other fifteen contracts, each taking the manager as `authority`.
3. `setTargetFunctionRole` for **every** signature in `script/v2/roles.v8.json` `.targets`
   (`_pendingMapping`, `script/v2/DeployV8.s.sol:785-792`), skipping what the manager already holds.
4. The deployer grants **itself** every role that appears as a value in `.targets`, at delay 0
   (`_pendingSelfGrants`, `script/v2/DeployV8.s.sol:863-879`). This works only while each role's admin is still 0 — see 7.
5. Every pointer and parameter call, sent **directly** to its target (`_pendingWiring`, `script/v2/DeployV8.s.sol:929`) —
   except the `OrderBook`'s, which go through `manager.execute` because the book is still an
   `AccessControl` contract whose admin is the manager (`_viaManager`, `script/v2/DeployV8.s.sol:1260`).
6. `grantRole(role, holder, delaysS[role])` for every pair in `.holders`, at the delay the manifest
   names (`_pendingHolders`, `script/v2/DeployV8.s.sol:1279-1286`).
7. `setRoleAdmin` and `setRoleGuardian` (`_pendingRoleTree`, `script/v2/DeployV8.s.sol:1326-1347`) — **after 4 and 6**.
   `AccessManager._getAdminRestrictions` routes `grantRole` and `revokeRole` through
   `getRoleAdmin(role)`, so once `GUARDIAN`, `PRICER`, `QUOTER` and `BUYBACK` are parented to
   `OPS_ADMIN`, a bare `grantRole(GUARDIAN, …)` from an `ADMIN`-only deployer reverts
   `AccessManagerUnauthorizedAccount(deployer, OPS_ADMIN)`.
8. The deployer renounces every transient working role it still holds.
9. The deployer renounces `ADMIN` — **the last call of the run** (`_pendingHandBack`, `:1173-1204`).

**The renounce guard.** `_assertAdminSafeCanTakeOver` (`:1210-1234`) refuses step 9 unless the Admin
Safe already holds `ADMIN` at the manifest delay **and has code**. Its message is the reason:
`AccessManager._revokeRole` has no last-admin guard, so renouncing the last `ADMIN` would brick all
twenty-two contracts permanently — no role, no selector map and no authority could ever be changed again,
on any of them, by anyone.

**The post-check** (`_postCheck`, `:1288-1308`) re-reads all four planning batches empty and then
asserts the deployer holds no working role and no `ADMIN`. A `DeployV8` run that ends without printing
its post-check has not finished.

**How many calls the hand-over sends is not stated in the code** and is not stated here. It is
manifest-driven: the mapping, self-grant, holder, role-tree and hand-back batches are all counted at
run time, and the run prints `DEPLOY DONE: N contract(s) created, N call(s) sent, N already in place`
(`:147-158`). The only number in the file near one is a buffer-sizing comment for the wiring batch
alone — "9 pointers + 3 bounty callers + 6 bounties + 1 daily cap + 5 splitter pointers + 1 splitter
slippage = 25" (`:766`) — which is an upper bound on **one** of the six batches, not a run total.
Record the printed numbers in the rehearsal record.

### Per market

`RegisterMarkets` plans up to ten calls per market (`:630-740`; the v7 buffer of seven was not enough
once the registration tuple split). In order:

| Call | When |
|---|---|
| `chainlinkSource.setOracle(settlementOracle, true)` | only if the deploy wiring was undone |
| `univ3Source.setOracle(settlementOracle, true)` | only with a pool, and only if undone |
| `chainlinkSource.setFeed(asset, feed, maxStale, maxRoundJumpBps)` | always |
| `univ3Source.setPool(asset, pool, minLiquidity, window)` | only with `v2.univ3Pool` |
| `settlementOracle.setMarket(asset, [chainlink] \| [chainlink, univ3], deviation, delay, spot age)` | always |
| `univ3Source.setPool(asset, 0)` | only to remove a pool the registry dropped — **after** `setMarket` has unlisted it |
| the payout route on `PayoutRouter`, or clearing it | with or without a pool |
| `clearinghouse.registerMarket(asset, strikeTick, enabled)` — **`LISTING` lane, 1 h** | a market the chain does not know (`cur.strikeTick == 0`) |
| `clearinghouse.setMarketListing(asset, enabled, strikeTick)` — **`LISTING` lane, 1 h** | `--resync` of a known market |
| `clearinghouse.setMarketOracle(asset, oracle)` — **`CONFIG_ADMIN` lane, 24 h** | when the market's oracle differs from `defaultOracle()` |
| `clearinghouse.setMarketFees(asset, exerciseFeeBps, mintFeePpm)` — **`MARKET_FEE_MANAGER` lane, 72 h** | when the fees differ from `defaultMarketFees()` |

The three-way split is the whole point and cannot be folded back together: `MARKET_FEE_MANAGER` waits
72 h, three times the `LISTING` lane's hour (`script/v2/RegisterMarkets.s.sol:812-814`). A fresh
market therefore reaches "listed" in an hour and "priced differently from the default" three days
later, which is why the defaults have to be right before the first market is registered.

**Staged listing (C3-102).** `enabled` is `(markets[i].v2.status == "live")`. Planned and paused rows
register **disabled**: `createSeries` reverts `MarketDisabled` until a reviewed registry flip and
`--resync`. `V2_MARKET_<T>_ENABLED` is fail-closed — missing reads as `false`
(`script/v2/lib/V2DeployBase.sol:541-544`), so a hand-run `RegisterMarkets` cannot enable a planned
market by omission.

The source order is the fallback priority: Chainlink first, the pool second. Data Streams, once
enabled by the owner, goes in front (`docs/V2-DATA-STREAMS.md`); these scripts never add it.

Nothing is funded by the scripts: see step 6 below.

## Order of operations

0. **Preconditions (owner).** In callhouse: `ops/v2/derive-bot-keys.sh` has written `v2.bots` (the
   batch refuses null bots for `--broadcast`), `node ops/markets/build-markets.mjs --check` is green, the
   registry is committed, and **both Safes exist on chain and have code** — `DeployV8` refuses a
   codeless `V2_ADMIN_SAFE` or `V2_TREASURY_SAFE` whenever the expected chain id is 4663, which
   includes an anvil fork of it (`script/v2/DeployV8.s.sol:296-303`). The seven
   principals — admin Safe, treasury Safe, guardian, pricer, quoter, cranker, deployer — must be seven
   **different** addresses (`:289`); v7 required five. In this repository: the commit to deploy is
   checked out and clean, `forge build && forge test` green. The deployer holds gas for sixteen
   creates plus the hand-over, and more per pool market. Every `v2.univ3Pool` of the selection holds at
   least 2401 observations (`slot0()`, 4th value `observationCardinality`): `UniV3TwapSource.setPool`
   refuses a shallower ring (sweep contracts-c10) and the RegisterMarkets preflight stops first.
   Raising one is permissionless:
   `cast send -i <pool> "increaseObservationCardinalityNext(uint16)" 2401 --rpc-url $RH_RPC`. That
   raises `observationCardinalityNext` only; `observationCardinality` follows once the ring's index
   wraps, after up to the current cardinality more pool writes (hours on an active pool, days on a
   quiet one: poke it with dust swaps, or register the market Chainlink-only until then).
1. **Rehearse (mandatory).** An anvil fork of 4663 with `--code-size-limit 98304`, then the exact
   selection you will broadcast. `DeployV2Batch.sh --rehearse` drives `DeployV8` against the fork.
   To drive `DeployV8` by hand instead, use the environment below:
   ```bash
   anvil --fork-url https://rpc.mainnet.chain.robinhood.com --chain-id 4663 --port 8551 --code-size-limit 98304 \
     --retries 12 --fork-retry-backoff 1000 --timeout 60000 &
   DEPLOYER_PK=… V2_ADMIN_SAFE=0x… V2_TREASURY_SAFE=0x… <the rest of V2_*> \
     forge script script/v2/DeployV8.s.sol --rpc-url http://127.0.0.1:8551 --broadcast --slow \
       --no-storage-caching --non-interactive
   ```
   It must end in the post-check and `DEPLOY DONE`. Stop the anvil. The public RPC serves state only
   ~15 minutes behind its head, so the whole run must fit in that window. Record it (template below).
2. **Broadcast (owner).** Same selection, same registry file, same commit, within 24 h:
   ```bash
   read -rs DEPLOYER_PK && export DEPLOYER_PK
   # ADMIN_PK must NOT be in the environment on launch day (T-OP-161): both drivers refuse it. The register
   # step is the deployer's; the driver sets V2_ADMIN=<deployer> and ADMIN_PK=<DEPLOYER_PK> for that step itself.
   V2_DEFER_HANDBACK=true forge script script/v2/DeployV8.s.sol --rpc-url $RH_RPC --broadcast --slow --no-storage-caching --non-interactive
   unset DEPLOYER_PK   # only after step 2c below: the window is open until HandBack
   ```
   Add `--verify --verifier sourcify --chain 4663` only when the explorer credential is configured.
   Write `v2.contracts` and `v2.deployBlock` back into the registry — the wrapper does this
   automatically (`script/v2/DeployV2Batch.sh:1050-1059`); by hand, take the addresses from the run's
   `V2_DEPLOY_OUT` JSON (`script/v2/DeployV8.s.sol:160-168`).
2b. **Externals, mapped by the deployer inside its extended ADMIN window (T-OP-116 / T-OP-153).** Step 2's
   `DeployV8` runs with `V2_DEFER_HANDBACK=true` and stops before its step 9 — the deployer keeps `ADMIN`.
   After the core write-back the externals stage (`DeployV2Batch.sh` runs it right after `DeployV8`;
   `broadcast-v8.sh --from verify` runs it first) deploys the owner's window — `HouseVaultFactory` and the
   launch tickers' `HouseVault`(s) through `DeployHouseVault.s.sol` (pass A the factory, `MapExternals` so
   the deployer may `createVault`, pass B the vaults) and `EarnVault` through `DeployEarnVault.s.sol`;
   `Hedger`, `RewardsDistributorLender` and `StockVenueAdapter` are skipped unless `--skip-external` says
   otherwise — records each at `v2.contracts.<key>` and `v2.externalDeployBlocks.<key>`, runs
   `forge script script/v2/MapExternals.s.sol` (every supplied external's selectors at delay 0) and reads every
   mapping back. `HandBack` does NOT run here any more (T-OP-161): see 2c.
2c. **Register the launch set as the DEPLOYER, then hand back (T-OP-161, amendment #4, owner 05:50Z).** While the
   window is open the deployer holds LISTING and CONFIG_ADMIN at execution delay 0 (DeployV8 step 4), so
   `RegisterMarkets` runs in ONE forge process per market with no schedule and no Safe: the driver exports
   `V2_ADMIN=<deployer address>` and `ADMIN_PK=<the DEPLOYER_PK value>` for that process only and removes
   `V2_SCHEDULE` / `V2_SCHEDULE_PHASE`; the log must carry `the signer holds LISTING and CONFIG_ADMIN on the
   accessManager` and `REGISTER DONE`, and a `scheduled` line is a refusal. `DeployV2Batch.sh` decides the path by
   reading the manager (`register path: …`); `broadcast-v8.sh` refuses a closed window by name. Then
   `forge script script/v2/HandBack.s.sol` (the deployer renounces its transient roles and `ADMIN`; idempotent)
   and the read-back `hasRole(ADMIN, deployer) == false` — **the window closes here**, and `VerifyV8` with the
   deployer follows (3). **The accepted hot-key window is `DeployV8` → `HandBack`** = 2 → 2b → 2c: keep the
   write-back and the resume back to back. A failure inside the window leaves the deployer holding `ADMIN` —
   fix the input and re-run the same command (idempotent: reuse, no-op map, register the remainder, hand back);
   nothing else belongs in the window. **`ADMIN_PK` in the environment is refused** by both drivers before
   their first forge step; so is a deployer that is any of the registry's principals (Safes, guardian, ops
   wallet, bots). **Launch-day signers (owner ruling 06:12Z, public derivation facts only):** DEPLOYER = the owner
   hot-wallet index 0 (`0xEb82c3D0…`), GUARDIAN = index 2 (`0x29741A8d…6F39`, the registry's `shared.guardian`);
   the driver refuses DEPLOYER == any principal, so that pairing must hold before step 2 starts.
3. **Verify.** `VerifyV8` is what checks a v8 set: `forge script script/v2/VerifyV8.s.sol`,
   read-only, ending in `VERIFY PASSED: N checks` (`script/v2/VerifyV8.s.sol:213`). A log with NEITHER
   `VERIFY PASSED:` nor `VERIFY FAILED:` is **FAILED-INCOMPLETE** (the run stopped before its last group; T-OP-152
   / T-OP-161 (e)) and both drivers name it so — never "N FAIL lines". `DeployV8`'s own
   post-check and a re-run of `DeployV8` with `V2_WIRING_CHECK=true` still hold as well; the latter is
   read-only and reverts naming every call still pending.
4. **Registry and services (callhouse, ops/deploy.md §15.7).** Commit the written-back registry,
   `build-markets.mjs --check`, `node ops/v2-env.mjs`, `pnpm --filter @callhouse/web gen:markets`.
   Every consumer must move to `interfaceVersion === 8` in the same change: selectors, event topics and
   tuples moved, and a v7 decoder on a v8 deployment mis-decodes silently rather than reverting.
5. **`v2.status` (hand).** Never changed by a script. Set `live` for a registered market when it should
   be shown and cranked (`ops/markets/README.md`: live needs `registeredAt` + `registerTx`).
6. **Funding (owner, Treasury Safe, `cast send -i` prompts for the key):**
   ```bash
   cast send -i $USDG "approve(address,uint256)" $KEEPER_REWARDS 1000000000 --rpc-url $RH_RPC
   cast send -i $KEEPER_REWARDS "fund(uint256)" 1000000000 --rpc-url $RH_RPC          # 1,000 USDG of bounties
   cast send -i $USDG "approve(address,uint256)" $MAKER_VAULT <amount> --rpc-url $RH_RPC
   cast send -i $MAKER_VAULT "deposit(address,uint256)" $USDG <amount> --rpc-url $RH_RPC
   ```
   `MakerVault.deposit` is **permissionless from INTERFACE_VERSION 8** (`script/v2/roles.v8.json:175`):
   it pulls from `msg.sender` and can only add funds, so the Treasury Safe funds the vault with no
   role. `KeeperRewards.fund` is likewise open to anyone. The vault's quoter moves its funds into the
   Clearinghouse ledger (`depositToClearinghouse`). Bot gas: ops/deploy.md §15.6.
7. **Next waves (post-launch).** Same two steps with the next selection. The set is recorded, so the deploy phase is
   a read-only hand-over check; then only the new markets register — **through the Admin Safe's lanes**, because
   the deployer's window is closed: `DeployV2Batch.sh --register-only` schedules (LISTING 1 h / CONFIG_ADMIN
   24 h), stops with `rc=90`, prints every `readyAt`, and is re-run with `V2_SCHEDULE_PHASE=execute` after the
   wait. That shape is post-launch ONLY; the launch set never sees it.

### Changing a registered market

`--resync` re-runs `RegisterMarkets` for already-registered selected markets: a new or removed pool, a
changed deviation/delay/spot age, and `enabled` are sent; `registeredAt`/`registerTx` stay. It refuses
a `strikeTick` change on an enabled market and refuses any exercise-fee or oracle change through the
listing call (`script/v2/RegisterMarkets.s.sol:394-420`) — those go through `setMarketFees` on the
72 h lane and `setMarketOracle` on the 24 h lane, and reach **new series only**. Rehearse `--resync`
first, like any broadcast.

**Price sources: list only what can pin; unlist before unconfiguring.** Pinning fails closed, so while
`settlementOracle.setMarket` lists a source that has no configuration for the asset
(`SourceNotPinned(source, NoSource)`) or does not allow-list the oracle (`SourceNotPinned(source, NotAuthorized)`),
every first series of an expiry on that market reverts. Configure the source (`setFeed` / `setPool`) and
check `isOracle(settlementOracle)` before `setMarket` names it; to drop a source, `setMarket` without it
first, then `setFeed(asset, 0)` / `setPool(asset, 0)`. `RegisterMarkets` sends its calls in that order
(`RegisterMarketsPreflightTest.test_register_droppedPool_unlistsBeforeUnconfiguring`); a change by hand, such as
enabling Data Streams (docs/V2-DATA-STREAMS.md), must follow it too. Under v8 every one of those calls
is a `CONFIG_ADMIN` schedule, so it is an order of *scheduled* operations and each waits 24 h.

### Changing fees after the deploy

**Two delays, not one.** The Admin Safe first schedules `setFeeParams` on the manager and waits out
`FEE_MANAGER`'s 48 h execution delay; only then does the call reach the book, where it waits the
compiled `FEE_CHANGE_DELAY` of **48 h** again (`src/v2/interfaces/V2Constants.sol:55-60`, raised from
24 h by owner decision V3-D13). A fee change is therefore visible for 48 h before it can be scheduled
on the book and takes another 48 h to bite, and the guardian can cancel the manager operation at any
point while it waits. The constructor's fees apply at once, so a fresh deploy charges `v2.fees` from
its first take.

```bash
# the fees every take pays now
cast call $ORDER_BOOK "feeParams()((uint16,uint16,uint32,uint16,uint16))" --rpc-url $RH_RPC
# the pending change and its effectiveAt; zeros when nothing is pending
cast call $ORDER_BOOK "pendingFeeParams()((uint16,uint16,uint32,uint16,uint16),uint40)" --rpc-url $RH_RPC
# the schedule itself is a manager operation from the Admin Safe, not a direct send
```

- Takes in blocks before `effectiveAt` pay the old fees; from `effectiveAt` every take, resting orders
  included, pays the new ones (`OrderBookFeeDelayTest.test_take_restingOrders_payOldFeesBeforeEffectiveAt_newFeesFromIt`).
- Scheduling again before `effectiveAt` replaces the change and restarts the 48 hours; scheduling the
  fees in effect is the cancel (docs/V2-ARCHITECTURE.md §6.9).
- Update `v2.fees` in the registry when you schedule.
- The exercise fee is not a book fee: it is pinned per series from the market config, and it moves on
  the 72 h `MARKET_FEE_MANAGER` lane.
- **Accepted risk (SECURITY.md, "Accepted risks").** `TakeParams` gained a `maxTotalFee` field in
  INTERFACE_VERSION 8, but **`OrderBook.take` does not enforce it at this commit** — `C8-03` owns
  that. Until it lands the operating rule is unchanged and load-bearing: the dapp caps every take's
  `deadline` at `effectiveAt - 1` while a change is pending, and keeps other deadlines under
  `FEE_CHANGE_DELAY`. Before scheduling, confirm the dapp and the bots that rest orders (MakerVault
  quoter, AutoRoller repricing) read the pending schedule.

## Resume and recovery

`DeployV8` plans before it sends and sends only what is missing, so resume is the ordinary path rather
than a special mode. `V2_WIRING_CHECK=true` runs the same planning read-only and reverts
`"hand-over incomplete: N call(s) pending"`; a complete set exits on
`"hand-over already complete: nothing to send"`.

| Failure | What is on disk | Fix |
|---|---|---|
| the run dies part way through the creates | forge's broadcast record holds every mined CREATE | export the mined addresses as their `V2_*` names and re-run: `_reuse` skips an address that already has code and refuses one that does not (`script/v2/DeployV8.s.sol:454`) |
| the run dies during the hand-over | the manager holds whatever was mined | re-run with the same environment; the five planning helpers each skip what the chain already holds |
| a wiring call lost or undone | the wiring check lists it as pending | re-run; only the missing calls are sent |
| the deployer still holds a role at the end | the post-check reverts and says which (`:1299`, `:1302`) | re-run; steps 8 and 9 are planned like any other batch |
| `RegisterMarkets` dies before the Clearinghouse calls | nothing recorded for that market; any source config already sent stays | re-run: sent steps are skipped |
| Sourcify verification fails after the deploy was mined | the set is on chain | verify by hand per contract: `forge verify-contract --verifier sourcify --chain 4663 <address> src/v2/Clearinghouse.sol:Clearinghouse` (constructor arguments are in the run's record) |

**The one failure that cannot be recovered** is a renounce of the last `ADMIN` before the Admin Safe
holds it. `DeployV8` refuses it (`:1210-1234`); nothing else would.

## `DeployV2Batch.sh`

**This section describes the wrapper as it stands, which is v8.** It invokes `script/v2/DeployV8.s.sol`,
`script/v2/RegisterMarkets.s.sol` and `script/v2/VerifyV8.s.sol`, so these commands run a v8 deploy.
`C8-10` rebuilt the wrapper around `DeployV8` and the flag surface survived.

```bash
script/v2/DeployV2Batch.sh --rehearse --rpc http://127.0.0.1:8551 --registry ../callhouse/ops/markets/tier1.json --tickers NVDA [--out copy.json] [--deployer-pk 0x…]
script/v2/DeployV2Batch.sh --broadcast --rpc $RH_RPC --wave canary
script/v2/DeployV2Batch.sh --verify --rpc $RH_RPC [--expect-fresh true]
script/v2/DeployV2Batch.sh --rehearse --rpc http://127.0.0.1:8551 --wave wave1 --dry-run
```

| Flag | |
|---|---|
| `--registry <path>` | default `../callhouse/ops/markets/tier1.json` from the repository root; relative paths resolve against your cwd |
| `--sources <path>` | default `v2-sources.json` next to the registry: holidays, VerifierProxy, each pool's fee |
| `--tickers A,B` / `--wave canary\|wave1\|wave2` | markets to register (`markets[i].v2.wave`); rows with `v2.registeredAt` are skipped; `verification.ok` must be true, `v2.strikeTick` set, a `v2.univ3Pool` must be one of that market's pools in the recon file, with a fee tier of at most 10000 (1 %: the pool is also the payout route, and the Clearinghouse counts at most 100 bps of route fee, so a costlier route would pay every conversion in kind), and come with `v2.univ3MinLiquidity` |
| `--deploy-only` | deploy / check / resume the set, register nothing |
| `--resync` | include registered markets (above) |
| `--resume` | finish a partly recorded set or send missing wiring; `--deploy-block <n>` |
| `--rehearse` | local anvil only (127.0.0.1/localhost, `web3_clientVersion` anvil), chain 4663. Write-back to `--out` (default a temp dir); an `--out` resolving to the real registry is refused; the source registry's sha256 is checked unchanged |
| `--broadcast` | non-local, non-anvil RPC; keys from the environment; `v2.bots` set; a matching rehearsal record ≤ 24 h old; the literal word `deploy` on stdin |
| `--verify` | read-only verification of the recorded set and every market with `registeredAt`. `--expect-fresh true\|false` (default false) |
| `--dry-run` | plan and commands, runs nothing, needs no node |
| `--skip-external a,b` | T-OP-116: externals (registry keys: `houseVault`, `houseVaultFactory`, `hedger`, `rewardsDistributorLender`, `earnVault`, `stockVenueAdapter`) this run must NOT deploy. Default: the owner's window (`hedger,rewardsDistributorLender,stockVenueAdapter`); `none` skips nothing; a list replaces the default. Printed as skipped, exported to `MapExternals` and `VerifyV8` as `V2_SKIP_EXTERNALS` in `V2_*` env names (T-OP-140 spelling); refused for a key that is recorded or exported; part of the rehearsal fingerprint |
| `--allow-zero-rent` | **v7 name, v7 sense.** v8's opt-in is `V2_ALLOW_RENT` and points the other way (above) |

The fingerprint is the sha256 of the artifacts' creation bytecode, `DeployV2Batch.sh`, the scripts it
calls (including `DeployLenderRewards.s.sol` and `DeployEarnVault.s.sol` since T-OP-116), `V2DeployBase.sol`,
the recon file, every file under `script/artifacts/v2-4663/`, the values of the override variables and the
`--skip-external` list. Every forge call passes `--no-storage-caching --non-interactive`; logs,
forge records, address JSON and the rehearsal record go to `broadcast/v2-batch/<utc>/`. The batch drops
every other `V2_*` export of your shell before running forge.

## Environment

Every name starts with `V2_` so no v1 script's variable (`USDG`, `ADMIN`, `ASSET`…) can leak in. The
table below is what the **v8** scripts read, from `script/v2/lib/V2DeployBase.sol` (a bare `:NNN` in the
Line column is a line of that file; every line number in this table was re-derived at `07da7763`, T-OP-017).
Names marked **new** did not exist in v7; names marked **gone** are v7 names the v8 base no longer reads.
`DeployV2Batch.sh` exports the new names it can source — the Safes (`:672`, `:679`), the v4 pair (`:686`),
the buyback leg and pool key (`:690-692`) and the flywheel addresses on resume (`env_name`, `:709-716`) —
and leaves the flywheel dials (`V2_BURN_BPS`, `V2_CONVERSION_SLIPPAGE_BPS`, `V2_BUYBACK_*`) to their
`LAUNCH_*` defaults; it never exports `V2_ALLOW_RENT` (`:702` unsets it).

| Variable | From | Read by | Line |
|---|---|---|---|
| `DEPLOYER_PK` | environment only | `DeployV8` (creates and every hand-over call). Unset with no key: broadcasts from `V2_DEPLOYER` (anvil `--unlocked`) | `DeployV8.s.sol:153-168` |
| `ADMIN_PK` | **refused in the environment on the launch path** (T-OP-161; both drivers, `registry_env_refuse_admin_pk`). `DeployV8` does not read it (`DeployV8.s.sol:39`). `RegisterMarkets` requires its address to be `V2_ADMIN`; on launch day the DRIVER sets both to the deployer for the register step only (`V2_ADMIN=<deployer>`, `ADMIN_PK=<DEPLOYER_PK>`), never the operator | `RegisterMarkets.s.sol:153-183` |
| `V2_ADMIN_SAFE` | `shared.safes.admin` | **new.** The `ADMIN` principal; must have code | `:368` |
| `V2_TREASURY_SAFE` | `shared.safes.treasury` | **new.** The only address money can leave to; must have code | `:369` |
| `V2_ADMIN` | `shared.admin` | **gone** from `V2DeployBase`, which reads `V2_ADMIN_SAFE` instead (`script/v2/lib/V2DeployBase.sol:368` — grepping `V2_ADMIN` there matches `V2_ADMIN_SAFE` and misleads). Still read by `RegisterMarkets.s.sol:213` and still exported by `DeployV2Batch.sh:667`; `C8-10` has landed and left both in place | — |
| `V2_DEPLOYER` | the deployer's address | unlocked sender; holds nothing when the run ends | `:379` |
| `V2_GUARDIAN`, `V2_PRICER`, `V2_MM_QUOTER`, `V2_CRANKER` | `v2.bots` | the four instant roles. v7 gave the cranker no role; v8 gives it `BUYBACK` | `:370-373` |
| `V2_FEE_RECIPIENT` | `shared.feeRecipient` | must equal the FeeSplitter this run deploys | `:378` |
| `V2_ACCESS_MANAGER` | `v2.contracts.accessManager` | **new.** Reuse on a resumed run | `:337` |
| `V2_FEE_SPLITTER` | `v2.flywheel.feeSplitter` | **new** | `:338` |
| `V2_PAYOUT_ROUTER` | `v2.contracts.payoutAdapter` | **new** name, same registry key. `V2_PAYOUT_ADAPTER` is **gone**: it still names the v7 adapter on live 4663. **`DeployV2Batch.sh:716` still emits `V2_PAYOUT_ADAPTER` for this key on resume, which nothing reads** (raised by T-OP-017; the fix belongs to the wrapper, not this page) | `:348-350` |
| `V2_BUYBACK_EXECUTOR` | `v2.flywheel.buybackExecutor` | **new** | `:354` |
| `V2_EXPIRY_CALENDAR`, `V2_SOURCE_CHAINLINK`, `V2_SOURCE_UNIV3`, `V2_SOURCE_DATA_STREAMS`, `V2_SETTLEMENT_ORACLE`, `V2_KEEPER_REWARDS`, `V2_CLEARINGHOUSE`, `V2_ORDER_BOOK`, `V2_AUTO_ROLLER`, `V2_MAKER_REGISTRY`, `V2_MAKER_VAULT`, `V2_REWARDS_DISTRIBUTOR` | `v2.contracts` | reused on resume by all three scripts | `:339-353` |
| `V2_USDG` | `shared.usdg` | symbol `USDG`, 6 dp, checked in the preflight | `:383` |
| `V2_SWAP_ROUTER02`, `V2_UNIV3_FACTORY` | `v2.uniswapV3` | the router's `factory()` must be the factory | `:384-385` |
| `V2_DATA_STREAMS_VERIFIER` | `v2-sources.json` `contracts.verifierProxy.address` (`DeployV2Batch.sh:304`) | the VerifierProxy | `:386` |
| `V2_V4_POOL_MANAGER`, `V2_V4_STATE_VIEW` | `v2-sources.json` `contracts.v4PoolManager.address` / `contracts.v4StateView.address` (`DeployV2Batch.sh:312-313`, exported at `:686`). **Not** `v2.uniswapV4`: the registry has no such key and `build-markets.mjs --check` refuses one, naming this recon path | **new.** The PayoutRouter's v4 leg and the executor's; both must have code (`DeployV8.s.sol:425-426`) | `:387-388` |
| `V2_HOLIDAYS` | `v2-sources.json` `nyseHolidays.*.fullDays[].dayIndex`, strictly increasing | the calendar | `:557` |
| `V2_PREMIUM_FEE_BPS`, `V2_RESALE_FEE_BPS`, `V2_TAKER_FEE_FLAT`, `V2_TAKER_FEE_CAP_BPS`, `V2_MAKER_REBATE_BPS` | `v2.fees` (**500**, 0, …) | the OrderBook constructor. Checked against `PREMIUM_FEE_CEIL_BPS` only; the v7 `premium <= resale` require is gone from the OrderBook | `:393-397` |
| `V2_EXERCISE_FEE_BPS` | `v2.fees.exerciseFeeBps` | RegisterMarkets, per market | `:399` |
| `V2_MINT_FEE_PPM` | `v2.fees.mintFeePpm`, the shared rate | must be 0 outside `forge test`; a non-zero value is refused | `:486-506` |
| `V2_MARKET_<T>_MINT_FEE_PPM` | `markets[i].v2.mintFeePpm` | same rule, per market | `:491-492` |
| `V2_ALLOW_RENT` | **new name** (v7's `V2_ALLOW_ZERO_RENT` is **gone**) | honoured under `forge test` alone; `rentAllowed` / `_inTestContext` is the one gate | `:512-517`, `:532-534`, `:540-545` |
| `V2_BURN_BPS` | **not in the registry**: `LAUNCH_BURN_BPS` 5000 (`:84`) unless the variable overrides it; the wrapper does not export it. There is no `v2.flywheel.burnBps` — `v2.flywheel` holds only `feeSplitter`, `buybackExecutor` and `deployBlock` | **new.** The FeeSplitter's split, constructor argument; at most 10000 (`DeployV8.s.sol:475`) | `:443` |
| `V2_CONVERSION_SLIPPAGE_BPS` | **not in the registry**: `LAUNCH_CONVERSION_SLIPPAGE_BPS` 30 (`:89`) unless overridden | **new.** The splitter's conversion floor, at most `MAX_PAYOUT_SLIPPAGE_CEIL_BPS` (`DeployV8.s.sol:476-479`) | `:445-447` |
| `V2_WETH`, `V2_BUYBACK_V3_POOL` | `v2-sources.json` `contracts.weth.address` / `contracts.usdgWethV3Pool.address` (`DeployV2Batch.sh:341-342`; neither key is in the recon yet, so the wrapper refuses by name at `:354-360`; exported at `:690`). **Not** `v2.flywheel` | **new.** The buyback's v3 leg; both must have code (`DeployV8.s.sol:485-486`) | `:448-449` |
| `V2_TOKEN_POOL_CURRENCY0`, `_CURRENCY1`, `_FEE`, `_TICK_SPACING`, `_HOOKS` | `shared.token.poolKey` (`currency0`, `currency1`, `fee`, `tickSpacing`, `hooks`); `build-markets.mjs` `SHARED_TOKEN_KEYS`/`POOL_KEY_KEYS` make it the only home. **Not** `v2.flywheel.tokenPool`: `--check` refuses that key | **new.** The pinned STONKHOUSE v4 pool. `CURRENCY0` **must be the zero address** (native ETH): the wrapper reads all five (`DeployV2Batch.sh:349-353`), refuses a present non-zero `currency0` (`:373-375`) and never exports it, so `DeployV8` takes its `vm.envOr` default of `address(0)`. `fee` 0 is legal and must be written, not left null (`:365`). Exported at `:691-692` | `:451-455` |
| `V2_BUYBACK_MAX_TOTAL_FEE_BPS`, `_SLIPPAGE_BPS`, `_TWAP_WINDOW_S`, `_MIN_LIQUIDITY` | **not in the registry**: `LAUNCH_BUYBACK_*` 250, 51, 300, 1e18 (`:94-104`) unless overridden | **new.** The executor's guards; `MIN_LIQUIDITY` must be > 0 (`DeployV8.s.sol:495`) | `:457-468` |
| `V2_TICKERS` | the selection | RegisterMarkets (one per run), the verifier (every registered market) | `:566` |
| `V2_MARKET_<T>_ASSET`, `_FEED`, `_POOL`, `_MIN_LIQUIDITY`, `_POOL_FEE`, `_STRIKE_TICK`, `_MAX_DEVIATION_BPS`, `_UNCORROBORATED_DELAY_S`, `_SPOT_MAX_AGE_S`, `_ENABLED` | the registry row | RegisterMarkets, the verifier. `_ENABLED` is fail-closed: missing reads as `false` | `:572-586` |
| `V2_EXPECT_CHAIN_ID` | 4663 | every script, read individually | `DeployV8.s.sol:319` |
| `V2_WIRING_CHECK`, `V2_DEPLOY_OUT` | the operator or the wrapper | the read-only hand-over check; the address JSON path | `DeployV8.s.sol:179`, `:205` |
| `V2_UNREGISTERED_ASSETS`, `V2_EXPECT_FRESH` | the wrapper | the verifier | — |
| `V2_MAX_FEED_AGE_S` | default 345600 (4 days: the 24/5 feeds are silent all weekend) | RegisterMarkets preflight | — |

Launch values the registry does not hold are the `LAUNCH_*` constants at
`script/v2/lib/V2DeployBase.sol:47-104`, each overridable by its `V2_*` variable: the payout slippage
bound, the six keeper bounties, the keeper daily cap, the six MakerVault limits, the base URI, and the
flywheel set above. An override is printed in the plan and is part of the rehearsal fingerprint. Read
the values from that file rather than from this page; they have moved before.

## Preflights

Each prints one `ok` line per check and reverts, before anything is sent, with the values involved.

- **`DeployV8`** (`script/v2/DeployV8.s.sol:319-341` and its helpers). Principals: the seven addresses
  must be distinct (`:369`), and on chain 4663 `V2_ADMIN_SAFE` and `V2_TREASURY_SAFE` must both
  **have code** (`:377-383`) — a plain key is refused, not warned about, where v7's verifier only
  printed an `info` line. Externals: USDG's symbol and 6 decimals
  (`:390`, `:398`), and `swapRouter02.factory() == V2_UNIV3_FACTORY` (`:404-408`). Holidays non-empty and
  strictly increasing (`:324`, `:326`). Parameters under their compiled ceilings: payout slippage
  (`:424-426`), each of the six bounties against `MAX_BOUNTY` (`:429-435`), the vault limits including
  `V2_VAULT_MAX_DAILY_OUTFLOW > 0` — 0 would deploy the vault frozen for spending, which is the
  incident `setLimits` lever and never a deploy value (`:447-449`) — and a base URI that ends in `/`
  (`:459`). Flywheel: `V2_BURN_BPS` at most 10000 (`:466`), the conversion slippage under its ceiling
  (`:468-469`), `V2_TOKEN_POOL_CURRENCY0` native ETH (`:482`), `V2_BUYBACK_MIN_LIQUIDITY > 0` (`:486`).
  Fee recipient: `V2_FEE_RECIPIENT` must be the FeeSplitter of this set (`:335-337`, `:351-355`). Every reused
  address must have code (`:492-499`), and a reused set must link (`_linkage`, `:718-775`).
  **There is no `premiumFeeBps <= resaleFeeBps` refusal in `DeployV8`** — the v8 fee shape needs it
  gone.
- **`RegisterMarkets`, once** (`preflightSet`, `script/v2/RegisterMarkets.s.sol:268-303`): the set has code; the Clearinghouse, univ3 source and
  router use `V2_USDG`; `settlementOracle.clearinghouse()` is the Clearinghouse (else every
  `createSeries` would revert in `pin`); the exercise fee is at most 200 bps. `C8-10` HAS LANDED and this bullet used to say the opposite: the v7-shaped
  `hasRole(DEFAULT_ADMIN_ROLE, V2_ADMIN)` assertion is **gone**, and nothing here reads
  `DEFAULT_ADMIN_ROLE` any more — the only two mentions left in the file are NatSpec. What runs now is
  `_signerCanList` (`:344-396`), which asks the v8 question instead: does the address that will
  actually broadcast hold `LISTING` on the AccessManager, with the role id read from `roles.v8.json`
  rather than typed. It takes the SIGNER, not `V2_ADMIN`; the two are only equal on the `run()` path.
- **`RegisterMarkets`, per market** (`preflightMarket`, `script/v2/RegisterMarkets.s.sol:399-540`): token symbol == ticker, 18 dp, `uiMultiplier()` > 0,
  `oraclePaused()` false; feed description contains the ticker, 8 dp, round and answer > 0, age
  ≤ `V2_MAX_FEED_AGE_S`; strikeTick a non-zero multiple of `PRICE_TICK`; deviation 1..1000 bps, delay
  1800..86400 s, spot age 1..345600 s; **`mintFeePpm` must be 0** and, separately, at most
  `MINT_FEE_CEIL_PPM`; with a pool: tokens {asset, USDG}, `fee()` equal to the recon's and at most
  `MAX_ROUTE_FEE_TIER`, the factory's own pool for (asset, USDG, fee), `liquidity() > 0`,
  `observe([1800, 0])` answers, `slot0().observationCardinality` at least 2401, a floor > 0; without a
  pool, no floor; not registered yet, or registered with exactly this config.

`trySpot` after registration is informational: overnight the 24/5 feeds can print less often than a
short `spotMaxAge`. Rolls and vault quotes wait for a print inside `spotMaxAge`.

## What the verifier checks

**No check count is stated on this page, because none was produced for it.** The figure that stood
here — "144 checks" — was measured on the v7 set on 2026-09-17, and `VerifyV8.s.sol` states no total
anywhere in its source: it accumulates `passes` and `failures` at run time and prints
`VERIFY PASSED: N checks` (`script/v2/VerifyV8.s.sol:213`), which the wrapper parses back out
(`script/v2/DeployV2Batch.sh:1224`). The v8 count is **whatever your run prints**; record it in the
rehearsal record, next to the commit that printed it.

**The list that follows was measured against the v7 verifier and has NOT been re-derived against
`VerifyV8.s.sol`.** It is kept unaltered, and labelled here rather than rewritten, because re-labelling it `VerifyV8`
would assert a v8 provenance nobody has established — and the v7 verifier held rules v8 deliberately
deleted, so a rename would turn stale sentences into confident false ones. Read it as a description of
the v7 verifier, not of what runs today. Re-deriving it item by item against the 2323-line
`script/v2/VerifyV8.s.sol` is open work (T-509 left it; see the deferred-verification ledger).

What `VerifyV2` covered, as a v7 verifier: chain id; code at every recorded address; runtime
bytecode byte for byte outside immutable slots, against the pinned deployed runtime for an address the
pin manifest lists under that name on 4663 and against `out/` for any other; immutables and the
compiled defaults the scripts rely on; dependencies; pointers (calendar, fee recipients, payout
adapter, keeper rewards, base URI, maker registry, exactly the three bounty callers, the oracle naming
the Clearinghouse, and all three sources listing the oracle on their pin allow-list); the MakerVault's
approvals and limits; parameters against the registry; holidays; roles; every registered market's
config, including a **dry run of the pin its next expiry would make**, as the Clearinghouse, rolled
back — which fails on a lost pointer, a listed source that is not wired or not configured, and a hidden
pre-pin; unregistered registry assets; and fresh state.

**What it does not cover, and a `VerifyV8` must**: that the deployer renounced `ADMIN`; that the Admin
Safe holds `ADMIN` at 48 h and has code; that the selector map on the manager equals
`script/v2/roles.v8.json`; that every role holder and every execution delay matches the manifest; and
that the role-admin and role-guardian trees are set. Those are exactly the properties `DeployV8`'s own
post-check establishes at deploy time (`script/v2/DeployV8.s.sol:1288-1308`) and that nothing
re-establishes afterwards. `test/v2/unit/AccessMatrix.t.sol` checks the manifest against the tree
offline, which is not the same as checking it against a chain.

The four groups that are **actively wrong** for v8 are listed at the top of this page.

## Pinned deployed runtimes (the v7 set on chain 4663)

> **Everything in this section is a record of the INTERFACE_VERSION 7 deploy**, the only Stonkhouse v2
> set that has ever been broadcast. It stays because that set is live, is being run off
> ([docs/V7-RUNOFF.md](V7-RUNOFF.md)), and its pins are still what `VerifyV2` compares a live address
> against. A v8 deploy creates **sixteen** contracts at sixteen new addresses, none of which the
> manifest below lists, so every one of them is compared with `out/` until `pin-deployed.sh` is re-run
> ("Re-pinning after a core redeploy" below). The counts and byte sizes here are the v7 set's and were
> measured then; they are not v8 figures.

The live v7 set (thirteen contracts, `v2.deployBlock` 65780341, 2026-09-18) was deployed from commit
`1b087550cfc92fd1878e5f1c0feaabaa91dc415f`. `src/` moved on after that commit — `src/v2/oracle/lib/TickMath.sol`
was rewritten — so a later checkout compiles a different `UniV3TwapSource` (on `d0f1cd7`, the base of the pinning
commit: 8,105 B against the 8,343 B on chain; the other 12 still compiled identically), and a VerifyV2 that
compared the live addresses with `out/` FAILed on code nobody changed on chain. The batch dies on a failed VerifyV2, so no rehearsal record and no
`--broadcast` could come out of a later checkout. Since C3-101 (F1 D12) the live runtimes are pinned.

**How VerifyV2 compares.** `script/artifacts/v2-4663/manifest.json` (`V2DeployBase.PINNED_MANIFEST`) lists the
thirteen v7 registry names with their live addresses. On chain 4663 — a live RPC or an anvil fork of it — an address the
manifest lists under the same registry name is compared with its pinned artifact
(`script/artifacts/v2-4663/<Contract>.json`) and the line reads `runtime == pinned artifact of deployed rev <sha>,
outside immutable slots`. Any other address (a fresh deploy, a rehearsal's new set, a contract replaced later) is
compared with `out/` of this checkout: `runtime == compiled artifact, outside immutable slots`, as before. Off
chain 4663 the manifest is not read at all. The comparison is `BytecodeCheck`'s, unchanged:

- **immutables** — the slots the artifact's `deployedBytecode.immutableReferences` records are masked, and their
  values are VerifyV2's `immutables` group (USDG, book, clearinghouse, router, factory, VerifierProxy through the
  getters). The pin manifest also records every live immutable word, so the pinned artifact plus those words
  reproduces each account's code hash exactly (`VerifyV2Pinned.t.sol`, offline).
- **metadata** — nothing is masked for it: `bytecode_hash = "none"` leaves only `a164736f6c634300081c000a`
  (`{"solc": 0.8.28}`) as the CBOR tail, identical for every build, and it is compared byte for byte.
- **libraries** — no v2 contract links one; `pin-deployed.sh` refuses an artifact with link references.

**What is pinned.** Proven at block 67337641 (`checkedAt` in the manifest; first proven at 67327549): each runtime
equals the artifact of `1b08755` outside its immutable slots; each recorded code hash is the keccak of the live code
(also compared with `eth_getProof`'s `codeHash` for all 13 on 2026-09-19, and with `EXTCODEHASH` by the fork suite);
each deploy transaction has receipt status 1 and `contractAddress` equal to the address, and its input is the
artifact's creation bytecode followed by the constructor arguments (recorded). The build that produced the pins is a
fresh `forge build` of a clean detached checkout of that commit (forge 1.3.5-foundry-zksync-v0.1.9,
solc 0.8.28+commit.7893614a, via-IR, 200 runs, cancun, `bytecode_hash = "none"`, forge-std `bf647bd`, OpenZeppelin
`cab1993`); its 13 runtime and creation bytecodes are identical to those of the `out/` the deploy ran from.

| Registry name | Contract | Address | Runtime bytes | Immutable refs | Deploy tx |
|---|---|---|---|---|---|
| `expiryCalendar` | ExpiryCalendar | `0xd0fCeD9Ee6F533aA900BEe8d0523eF4867a5784a` | 3372 | 0 | `0x8b7210d9fdf9c6ec142c63359100148bd5377ab716e82c34b8f452aabcceaa14` |
| `sources.chainlink` | ChainlinkFeedSource | `0x1a595B2F836b7B76e71C0F85ADA6186ef16fB96A` | 5601 | 0 | `0xd7075935c08e7a47babe22b9ec33ad34935c117f021148aa6cd543264d947b70` |
| `sources.univ3` | UniV3TwapSource | `0x030f05E856c79bC215c5683DC201473e4F88a155` | 8343 | 3 | `0x5cecd8f6b5200d918b37636bcb679c966c1ff259d8f62fdc3feba1ee7ccba202` |
| `sources.dataStreams` | DataStreamsSource | `0xeC049Df6F9908374940065cec593Ac83fc1db4d2` | 9635 | 2 | `0x74fbbd1d41f4271fea040efadda1888bb197fbde80256822d9187b653394a75e` |
| `settlementOracle` | SettlementOracle | `0xb205984b5F2F9010c2bD8aCA46d946Fe1c4F2A54` | 12400 | 0 | `0x7f6581afaf7203bde104b9a1b6fd745cd8e0cbd34143ac88b3ad79e7240636b2` |
| `clearinghouse` | Clearinghouse | `0x22dEf851cD1a3B04Ad7d232bE786d76E6944d424` | 24497 | 7 | `0x1d7f8440be2001d6f9e1a2752384de5bc959afecda11c0429e772fba20c966ce` |
| `orderBook` | OrderBook | `0x9fcAe743C3fA0aEC7DB9b1d01e86464b85759942` | 19597 | 21 | `0x7854e796b008c99207b3b5bbe436fd55a48f3d089707cd35661b21b674ad71fa` |
| `keeperRewards` | KeeperRewards | `0xFB409E6E253bcC12a65ED02B9D5aa3cAbF8f63f3` | 3821 | 5 | `0xf85b182ab0151dab23e0a4f1a0cb8ef7d27ddc87e0c9d4e98a254c828660f4a5` |
| `autoRoller` | AutoRoller | `0xca76e9d57992904a14E31C5103454A4906ebFfee` | 12276 | 16 | `0xef881f4c31babe51b1664804f6680276135eb98c32047e8105b864534e681398` |
| `payoutAdapter` | UniV3PayoutAdapter | `0xf529CE3708bd2002D6bC974dFC0501c92aE72c30` | 3644 | 8 | `0x486545d1256d5337c3b3c156b3abdd6d28e7afc7269c8b8ca4f40d686fe1de1a` |
| `makerRegistry` | MakerRegistry | `0xED816A81F8e311F78496c63c66abaA93A996cD3B` | 1307 | 0 | `0x29c233cc08bd1fc3e9794467fd16c48f9fac72283927e09e8c88d05435f49408` |
| `makerVault` | MakerVault | `0x5EA899580B3dEB99c6866c7CD14dEDc913C8C1d0` | 14456 | 24 | `0x7c96df5cf67d6cd40bb11c110a11eae0c7ff7b13278456cee675a41de9837e79` |
| `rewardsDistributor` | RewardsDistributor | `0xc2Eea33F12e26662c66D632915fD75BCEA13BF4f` | 3103 | 4 | `0x0cb0f1fb8f76bf546528e0c87499068294b2b741e604f4a6ff955f473ccc6aeb` |

**Checks.**

```bash
forge test --match-path test/v2/unit/VerifyV8Pinned.t.sol                     # offline: manifest, code hashes, masking
FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC --match-path test/v2/fork/PinnedRuntimesFork.t.sol -vv
script/v2/DeployV2Batch.sh --verify --rpc $RH_RPC --registry ../callhouse/ops/markets/tier1.json
# regenerate from a clean checkout of the deployed commit and compare (everything but checkedAt must be identical)
script/v2/pin-deployed.sh --check --build <checkout of 1b087550> --registry ../callhouse/ops/markets/tier1.json
```

The public RPC serves state only about 15 minutes behind its head, so `pin-deployed.sh` reads at the head by
default; the set is immutable, so its code, code hashes and immutable words are the same at any block and only
`checkedAt` moves.

**Re-pinning after a core redeploy.** Never hand-edit `script/artifacts/v2-4663/`: `pin-deployed.sh` is its only
writer, and every file in it is part of the rehearsal fingerprint.

1. Deploy the new set with this runbook from a clean checkout of commit `X`; the batch writes the new
   `v2.contracts` and `v2.deployBlock` back into the registry and keeps forge's run record as
   `broadcast/v2-batch/<utc>/deploy-run-latest.json`.
2. Check `X` out on its own, clean, with submodules:
   ```bash
   git worktree add --detach ../tmp-contracts-X X
   git -C ../tmp-contracts-X submodule update --init    # on this machine: from the primary checkout's modules (HANDOFF.md)
   ```
3. From the checkout that will carry the pins (any later commit):
   ```bash
   script/v2/pin-deployed.sh --build ../tmp-contracts-X --registry <the written-back registry> \
     --deploy-record <the deploying checkout>/broadcast/v2-batch/<utc>/deploy-run-latest.json
   ```
   It builds `X`, reads the recorded addresses at the head, proves every runtime and deploy transaction, and
   replaces the directory; any mismatch prints it, writes nothing and exits 1. For a v8 set that is **sixteen**
   addresses, including the AccessManager, the FeeSplitter and the buyback executor — `pin-deployed.sh` still enumerates the
   thirteen v7 registry keys in its `SET` list, `payoutAdapter:UniV3PayoutAdapter` among them and no
   `accessManager`, `feeSplitter` or `buybackExecutor` (`script/v2/pin-deployed.sh:55-59`), so re-pinning a
   v8 set needs that list extended first (`C8-10`).
4. Update the addresses in `test/v2/fork/PinnedRuntimesFork.t.sol` (`_published`, typed on purpose so the
   manifest is checked against something it did not produce), then run the checks above, `forge test` and
   `batch-refusals.sh`. Commit the directory together with the registry change. A rehearsal recorded before the
   re-pin no longer matches the fingerprint: rehearse again.
5. `git worktree remove ../tmp-contracts-X`.

`pin-deployed.sh` pins one commit for the whole set. A single contract replaced later from the current checkout
gets a new address that the manifest does not list, so the verifier compares it with `out/` until the set is
re-pinned — which is also why **every** contract of a fresh v8 deploy is compared with `out/` rather than with a
pin.

## Rollback

There is none in the sense of an undo: the contracts are immutable and nothing is upgradeable. A
broken set is replaced, not repaired. What you CAN do inside the delay window is cancel a scheduled
operation before it executes, and the table below is the whole of it.

### 0. Cancel a scheduled operation during its delay

Every delayed call goes through the `AccessManager` as a scheduled operation, and until its
`schedule` matures it can be cancelled. **Who may cancel depends on the role, and one lane has no
guardian at all.**

| Lane | Delay | Cancellable during the delay by | Source |
|---|---|---|---|
| `FEE_MANAGER` | 48 h | **Guardian Safe** (`roleGuardian.FEE_MANAGER = GUARDIAN`) | `script/v2/roles.v8.json` `delaysS`, `roleGuardian` |
| `MARKET_FEE_MANAGER` | 72 h | **Guardian Safe** | same |
| `CONFIG_ADMIN` | 24 h | **Guardian Safe** | same |
| `TREASURY_ADMIN` | 24 h | **Guardian Safe** | same |
| `LISTING` | 1 h | **Guardian Safe** | same |
| `ADMIN` — role grants/revokes, role admins, target mappings | 48 h | **ADMIN SAFE ONLY. There is no guardian for this lane** — `roleGuardian` has no `ADMIN` entry, and AccessManager forbids one (the admin role cannot have a guardian). The operation is public on chain for 48 h and only the Admin Safe can cancel it | V3-D24; `roles.v8.json` `roleGuardian`, `notes.grantDelays` |
| `OPS_ADMIN`, `GUARDIAN`, `PRICER`, `QUOTER`, `BUYBACK` | 0 | **Nothing to cancel — these execute immediately.** Revoking the holder is the only control, and `OPS_ADMIN` is instant precisely so that never waits | `delaysS` |

```bash
# 1. find the operation id. caller = the Safe that scheduled it; target = the contract; data = the calldata.
cast call $MANAGER "hashOperation(address,address,bytes)(bytes32)" $CALLER $TARGET $DATA --rpc-url $RH_RPC

# 2. when does it become executable? 0 means NO SUCH OPERATION — not "ready now".
cast call $MANAGER "getSchedule(bytes32)(uint48)" $OP_ID --rpc-url $RH_RPC

# 3. cancel it, from the Guardian Safe for the five guarded lanes, from the ADMIN SAFE for an ADMIN operation.
cast send $MANAGER "cancel(address,address,bytes)(uint32)" $CALLER $TARGET $DATA --rpc-url $RH_RPC   # signed by the Safe

# 4. readback. getSchedule must now be 0 AND you must have seen a non-zero value at step 2.
cast call $MANAGER "getSchedule(bytes32)(uint48)" $OP_ID --rpc-url $RH_RPC
```

**What a FAILED step looks like, because two of these fail by returning a plausible number.**
Step 2 returning `0` means the operation does not exist — a wrong `caller`, a wrong `target`, or
calldata that differs by one byte. It does **not** mean "already executable", and reading it that way
sends you to step 3 to cancel nothing, which succeeds-looking and changes nothing. Step 4 returning
`0` proves a cancel only if step 2 returned non-zero first: `0` before and `0` after is the same two
readings you would get for an operation that was never scheduled. **Record both numbers.** A `cancel`
that reverts `AccessManagerUnauthorizedCancel` means you are signing from the wrong Safe — check the
table above before you assume the operation is gone.

### Replacing a broken set

1. **Pause new risk (guardian, minutes).** `clearinghouse.setCreatePaused(true)` (no new series; the
   AutoRoller cannot roll), `clearinghouse.setMintPaused(asset, true)` per market,
   `orderBook.setTradingPaused(true)`; `settlementOracle.veto(asset, expiry)` for a bad candidate price.
   Under INTERFACE_VERSION 8 those are `GUARDIAN` calls and are instant, and `OPS_ADMIN` — also
   instant, also the Admin Safe's — revokes a suspect `QUOTER` or `PRICER` hot key with no delay (then
   cancel the vault's orders). `OPS_ADMIN` is instant precisely so this step never waits.
   Closing, settlement, redemption, `cancel` and `prune` are never paused: holders exit and open series
   settle on the old set.
2. **Deploy a fixed set.** Fix, test, and run this runbook again against a registry whose `v2.contracts`,
   `v2.deployBlock` and every `registeredAt`/`registerTx` are null (git history keeps the old values;
   write them into the incident record). Rehearse, broadcast, verify.
3. **Point the registry at it.** Commit the new write-back, re-render the service env and redeploy the
   services (ops/deploy.md §15). Keep a cranker running against the OLD addresses until every old series
   is settled and redeemed; withdraw the old MakerVault and `defund` the old KeeperRewards.

## Rehearsal record template

Copy under "Rehearsal records" for every rehearsal that precedes a broadcast.

```
### Rehearsal record — <date> (<selection>, <why>)
- commit: <sha> (clean), forge build/test <n>/<n>
- anvil: --fork-url <rpc> --chain-id 4663 --port <p> --code-size-limit 98304; fork block <n>
- command: <the exact forge script or wrapper invocation>
- registry: <path>, sha256 <hex> (unchanged after); copy <path>
- rehearsal record: <path to rehearsal-passed.json>, fingerprint <hex>
- deploy: contracts created <n>, calls sent <n>, already in place <n>, gas <n>  (the DEPLOY DONE line)
- hand-over: post-check passed <yes/no>; deployer holds ADMIN after the run <must be no>
- markets: <T: calls, gas, registeredAt, registerTx> …
- verifier: <VerifyV8 once it exists: VERIFY PASSED <n> checks (fresh <true|false>); today, say which
  VerifyV2 FAILs are the known v7-shaped ones and which are not>
- deviations / warnings: <pool below floor, stale feed, overrides, stand-in bots …>
- not proven: <see below>
- broadcast follows: <yes/no, when, by whom>
```

## Rehearsal records

> **Every record below is of an INTERFACE_VERSION 6 or 7 rehearsal, run in September 2026 against the
> thirteen-contract v7 set and the `DeployV2.s.sol` that no longer exists.** They are kept as the
> deploy history of the set that is live on 4663. Read every "13 contracts created" and every admin-call
> count in them as a statement about that past run, not about a v8 deploy, which creates sixteen.
> No v8 rehearsal has been recorded yet.

### Rehearsal record — 2026-09-17 (the zero-rent opt-in made unreachable from any script run)

**Passed.** The gate for the last release blocker of `DECISIONS-2026-09-17` §11: `V2_ALLOW_ZERO_RENT` was
refused only by `DeployV2Batch.sh --broadcast`, so a direct `forge script RegisterMarkets --rpc-url <live
4663> --broadcast` with it exported still registered a market charging its writers nothing, and a read-only
`VerifyV2` of live 4663 still accepted one. Not a pre-broadcast rehearsal.

- the guard: `V2DeployBase.zeroRentAllowed` / `_inTestContext`, on `vm.isContext(ForgeContext.TestGroup)`.
  See "The zero-rent opt-in is a test-only code path" above. `DeployV2Batch.sh` no longer exports
  `V2_ALLOW_ZERO_RENT` at all and takes `--allow-zero-rent` only with `--dry-run`.
- `forge build --force` clean (only the pre-existing `unsafe-typecast` lint in the v1
  `test/invariant/VaultInvariant.t.sol`), `forge test` **1,614/1,614 in 98 suites** (44 s, 0 skipped),
  `forge fmt --check src/v2 script/v2 test/v2` clean. The 6 new tests are
  `test/v2/unit/ZeroRentLocality.t.sol`, plus the environment half inside `test/v2/unit/DeployV2Env.t.sol`,
  which owns the `V2_*` process environment. Fork suites are untouched by this work and were not re-run.
- registry: the same **real** callhouse `leekzor/v2` `ops/markets/tier1.json` at `1b49006`, sha256
  `89a06359…bd3108`, unchanged after the run.
- command: `PORT=8594 REGISTRY=<a copy of the real registry> script/v2/rehearse-v2.sh`; fork block
  **65,754,985**; the whole run 66 s, first attempt; anvil stopped on exit. 13 contracts created, 21 admin
  calls sent; NVDA registered at `mintFeePpm` 80 and TSLA at 300.
- VerifyV2 in the batch and alone on the copy: **VERIFY PASSED 146 checks**, unchanged — the rehearsal never
  used the opt-in, which is the point: nothing legitimate depended on it.
- all four drills unchanged (nothing to do; lost pointer + `--resume`; lost write-back recovered; one flipped
  Clearinghouse byte).
- `script/v2/batch-refusals.sh --registry <a copy of the real registry>`: **REFUSALS PASSED, 69 cases** (63
  before). The 6 new ones: `--allow-zero-rent` without `--dry-run` on `--rehearse` and on `--verify`, and
  four hand-run `forge script script/v2/RegisterMarkets.s.sol` cases with `V2_ALLOW_ZERO_RENT=true` — an
  explicit 0 refused, the `V2_ALLOW_ZERO_RENT IGNORED` line printed, an absent rate refused the same way, and
  the same command with a rate reaching the chain check, which shows the refusal is the rent one.

### Rehearsal record — 2026-09-17 (INTERFACE_VERSION 7 release-blocker patch, on the REAL v7 registry)

**Passed.** The gate for the three release blockers of `DECISIONS-2026-09-17` §11 and §12 — a market with no
writer rent must never deploy, the `registerMarket` write-back must match the v7 tuple, and the MakerVault
outflow cap must be pinned against a series that charges rent. Not a pre-broadcast rehearsal.

- commit: callhouse-contracts `v2-v7-patch`, three commits on `v2-v7` (`leekzor/v2` at `9c349bc`);
  `forge build --force` clean (only the pre-existing `unsafe-typecast` lint in the v1
  `test/invariant/VaultInvariant.t.sol`), `forge test` **1,608/1,608 in 97 suites** (58 s), `forge fmt --check
  src/v2 script/v2 test/v2` clean, `FOUNDRY_PROFILE=fork forge test` **44/44 in 7 suites** (355 s, `-j 1`).
- registry: the **real** callhouse `leekzor/v2` `ops/markets/tier1.json` at `1b49006`, no patching — ops has
  landed the v7 shape: `v2.interfaceVersion` 7, `v2.fees.premiumFeeBps` **0**, a shared `v2.fees.mintFeePpm`
  **80**, and all 35 markets carrying their own `v2.mintFeePpm` (none absent, none 0). sha256
  `89a06359…bd3108`, unchanged after the run.
- command: `PORT=8593 REGISTRY=<callhouse worktree>/ops/markets/tier1.json script/v2/rehearse-v2.sh`; fork
  block **65,734,602**; the whole run 63 s; anvil stopped on exit. NVDA registered at `mintFeePpm` 80 and
  TSLA at 300, both reaching `clearinghouse.registerMarket` in the plan.
- deploy: 13 contracts created, 21 admin calls sent, 3 already in place.
- VerifyV2 in the batch and alone on the copy: **VERIFY PASSED 146 checks** (144 before this patch). The two
  new ones are each market's `mintFeePpm != 0` floor, which FAILs a live market at 0 however the registry
  reads it.
- drills: nothing to do on a second run; the lost `settlementOracle.keeperRewards` pointer made VerifyV2 FAIL
  exactly that check, `--resume` sent 1 call and passed; TSLA's write-back recovered from the
  `MarketRegistered` log; one flipped Clearinghouse byte failed exactly the runtime check.
- the write-back recorder, end to end: replaying `register_tx` over the run's own
  `broadcast/v2-batch/<run>/{NVDA,TSLA}-run-latest.json` returns the exact hashes and blocks the batch wrote
  back, so the registration is found in the forge record and never falls through to the log scan.
- `script/v2/batch-refusals.sh --registry <the real registry>`: **REFUSALS PASSED, 69 cases** (63, then 48
  before). New: the four zero-or-absent writer-rent refusals (an absent `v2.fees` block, an absent per-market
  rate with a null shared fallback, an explicit per-market 0, an explicit shared 0), three
  `--allow-zero-rent` `--dry-run` cases, `--allow-zero-rent` refused with `--broadcast` and refused again
  without `--dry-run` on both `--rehearse` and `--verify`, four hand-run `forge script RegisterMarkets` cases
  that show `V2_ALLOW_ZERO_RENT` buying nothing outside `forge test`, `REGISTER_SIG` pinned against the
  compiled Clearinghouse ABI, and six `register_tx` recorder cases.
- devnet: `DEVNET_PORT=8592 CONTRACTS_DIR=<this worktree> ops/devnet/up.sh` from a callhouse worktree at
  `leekzor/v2`, then `down.sh`. Both dev markets came up live at `mintFeePpm` 80 (`ops/devnet/up.sh` passes
  the registry's shared rate, because `DevDeploy.s.sol` still defaults `MINT_FEE_PPM` to 0 on its own).

### Rehearsal record — 2026-09-17 (INTERFACE_VERSION 7 integration: NVDA + TSLA Chainlink only, on a copy)

**Passed.** The gate for landing interface version 7 on `v2` — collateral rent as the writer fee (c05), the
MakerVault's daily net USDG outflow cap (c21), the permissionless `AutoRoller.cancelStale` with the
in-the-money `reprice` refusal and the 30-minute open grace (c16) — not a pre-broadcast rehearsal.

- commit: callhouse-contracts `v2-v7` (WP-0 + WP-A + WP-B + WP-C merged, then this integration);
  `forge build --force`, `forge test` 1,601/1,601 in 97 suites, `forge fmt --check src/v2 script/v2 test/v2`
  clean.
- registry: callhouse `leekzor/v2` `ops/markets/tier1.json` + `v2-sources.json` copied to a temp
  `…/callhouse/ops/markets/` and patched into the v7 shape — `v2.interfaceVersion` 7,
  `v2.fees.premiumFeeBps` **0**, a shared `v2.fees.mintFeePpm` 0, a per-market `v2.mintFeePpm` from the
  launch table, and the 11 markets whose pool ring is below 2,401 observations demoted to **Chainlink-only**
  (AAPL 1801, AMZN 1801, CRCL 1801, GME 1860, GOOGL 1801, MSFT 1801, MU 1860, QQQ 1800, SGOV 1800, TSLA 1801,
  USO 1801 — only NVDA at 6,000 and SPCX at 3,100 keep a pool). Input copy sha256
  `f80b9ddc…14c348`, unchanged after.
- command: `PORT=8582 REGISTRY=<temp>/callhouse/ops/markets/tier1.json script/v2/rehearse-v2.sh`
  (TICKERS NVDA,TSLA; CHAINLINK_ONLY TSLA, already pool-less in the copy); fork block **65,658,456**; the
  whole run 62 s; anvil stopped on exit.
- rehearsal record `broadcast/v2-batch/20260917T203715Z/rehearsal-passed.json`, fingerprint
  `7a6aa1f6…e7f54b`, phase `fresh`, admin impersonated; bots anvil #8/#9/#10.
- deploy: 13 contracts created, **21 admin calls** sent (the 20 of v6 plus the `CANCEL_STALE` bounty), 3
  already in place; 37 transactions, **29,998,453 gas** across the deploy and both market registrations
  (v6: 33 transactions, 28,167,197 gas for the deploy alone). The growth is the rent in the Clearinghouse
  (22,179 → 24,497 B runtime, +500,896 deploy gas), `cancelStale` and the grace in the AutoRoller
  (10,023 → 12,276 B, +486,720) and the outflow cap in the MakerVault (12,964 → 14,456 B, +370,836).
- NVDA: 1 `registerMarket` + 5 admin calls; TSLA: 1 + 3.
- VerifyV2 in the batch and alone on the copy: **VERIFY PASSED 144 checks** (v6: 137). The seven new ones are
  each market's `mintFeePpm` against the registry and its ceiling, and its pool's observation ring against
  `MIN_POOL_OBSERVATION_CARDINALITY` (NVDA only — TSLA has no pool), the OrderBook's
  `premiumFeeBps <= resaleFeeBps`, and the `CANCEL_STALE` bounty. Info lines: vault and KeeperRewards
  unfunded, admin a plain key, `makerVault outflow: used 0, available 2500000000 of 2500000000`, both
  markets' `trySpot` **ok** (NVDA 219.672148, TSLA 366.84).
- drills: nothing to do on a second run; the lost `settlementOracle.keeperRewards` pointer made VerifyV2 FAIL
  exactly that check, the wiring check refused, `--resume` sent 1 call (23 in place) and passed 136 checks;
  TSLA's write-back recovered from the `MarketRegistered` log with nothing sent; byte 24,495 of the
  Clearinghouse flipped failed exactly the runtime check and nothing else.
- `script/v2/batch-refusals.sh --registry <temp copy>`: **REFUSALS PASSED, 48 cases** (39 in v6). New: a v6
  registry against v7 scripts; a pool whose recon ring is 1,801; the same market Chainlink-only accepted; a
  market and a shared `mintFeePpm` above 5,000; `premiumFeeBps` above `resaleFeeBps`;
  `V2_VAULT_MAX_DAILY_OUTFLOW=0`; `V2_BOUNTY_CANCEL_STALE` above `MAX_BOUNTY`; the launch rent rate reaching
  the plan banner.

### Rehearsal record — 2026-09-17 (INTERFACE_VERSION 6 integration: NVDA + TSLA Chainlink only, on a copy)

**Passed.** The gate for landing interface version 6 on `v2` (the settlement pin with its fail-closed hardening,
the 24-hour fee change delay, the payout floor above the route fee, the 1 % route tier ceiling); not a
pre-broadcast rehearsal.

- commit: callhouse-contracts `v2-v6-integration` 5853f0d (the docs that follow touch nothing the fingerprint
  covers); forge build --force, forge test 1423/1423 (88 suites), fork suites 43/43, `forge fmt --check` clean;
  registry: callhouse `leekzor/v2` 6c123fa `ops/markets/tier1.json` and `v2-sources.json` copied to a temp
  `…/callhouse/ops/markets/` with `v2.interfaceVersion` set to 6, sha256 `28934a2f…32124`, unchanged after.
- command: `PORT=8571 REGISTRY=<temp>/callhouse/ops/markets/tier1.json script/v2/rehearse-v2.sh` (TICKERS NVDA,TSLA,
  CHAINLINK_ONLY TSLA); fork block **65,353,244**; the whole run 50 s; anvil stopped on exit.
- input copy sha256 `bd9e1743…ebe5c3`; rehearsal record `broadcast/v2-batch/20260917T120544Z/rehearsal-passed.json`,
  fingerprint `81057d3b…ce14d5ba`, phase `fresh`, admin `0xEb82…9d9b` impersonated; bots anvil #8/#9/#10.
- deploy: 13 contracts created, **20 admin calls** sent, 3 already in place; 33 transactions, **28,167,197 gas**
  (sizes and gas in the table above; against the pin hardening record the Clearinghouse grew by the route-fee
  floor, the OrderBook by the fee schedule, and the adapter by `routeFeeBps` and the tier ceiling). The addresses
  are the C2-13 record's (clearinghouse `0xddA8…aB3D`): the admin's nonce at the fork block.
- NVDA: 5 calls, 390,464 gas (`setRoute` 54,555); TSLA: 3 calls, 220,947 gas.
- VerifyV2 in the batch and alone on the copy: **VERIFY PASSED 137 checks**; the new one is NVDA's pool fee tier
  (500) at most 10000. Info lines: vault and KeeperRewards unfunded, admin a plain key, NVDA `trySpot` not ok.
- drills: nothing to do on a second run; the lost `settlementOracle.keeperRewards` pointer made VerifyV2 FAIL
  exactly that check, the wiring check refused, `--resume` sent 1 call (22 in place) and passed 129 checks; TSLA's
  write-back recovered from the log with nothing sent; one flipped byte of the Clearinghouse's trailing CBOR
  failed exactly the runtime check.
- `script/v2/batch-refusals.sh --registry <temp copy>`: REFUSALS PASSED, 39 cases (new: a recon pool fee tier of
  20000; the stale-registry case now uses interface version 4).
- devnet: callhouse `leekzor/v2` 6c123fa, `DEVNET_PORT=8571 CONTRACTS_DIR=<this worktree> ops/devnet/up.sh`: DEVNET
  SEED PASSED with 3 of 3 ITM call long redemptions converted to USDG at the 30 bps bound; addresses unchanged
  (Clearinghouse `0x2256…3C63`, OrderBook `0x7bA8…C5b0`, AutoRoller `0xC42b…2302`, PayoutAdapter `0x8Ad3…f5aA`,
  MakerVault `0xbc7d…74EB`).
- the same rehearsal on the merge commit alone (before the tier ceiling) passed on fork block 65,336,061 with
  136 checks and 28,167,857 gas; its figures went into the merge commit.

### Rehearsal record — 2026-09-17 (fail-closed pin hardening, INTERFACE_VERSION 6: NVDA + TSLA Chainlink only, on a copy)

**Passed.** The gate for making the settlement pin fail closed (a source that cannot pin reverts the
creation; a pin made outside a series creation is confirmed only against the current configuration);
not a pre-broadcast rehearsal.

- commit: callhouse-contracts `v2-pin-oracle-config` 3911944;
  forge test 1386/1386; registry: callhouse `leekzor/v2` `ops/markets/tier1.json` and `v2-sources.json` copied
  to a temp `…/ops/markets/` with `v2.interfaceVersion` set to 6, sha256 `28934a2f…32124`.
- command: `PORT=8571 REGISTRY=<temp>/ops/markets/tier1.json script/v2/rehearse-v2.sh` (TICKERS NVDA,TSLA,
  CHAINLINK_ONLY TSLA); fork block **65,302,752**; the whole run 72 s; anvil stopped on exit.
- input copy sha256 `bd9e1743…ebe5c3`; rehearsal record `broadcast/v2-batch/20260917T104101Z/rehearsal-passed.json`,
  fingerprint `f4105188…da1befb`, phase `fresh`, admin `0xEb82…9d9b` impersonated; bots anvil #8/#9/#10.
- deploy: 13 contracts created, **20 admin calls** sent, 3 already in place; 33 transactions, **27,946,908 gas**
  (the four oracle contracts grew: sizes and gas in the table above).
- NVDA: 5 calls, 390,442 gas; TSLA: 3 calls, 220,947 gas.
- VerifyV2 in the batch and alone on the copy: **VERIFY PASSED 136 checks**. The two new ones are the pin dry
  runs, NVDA and TSLA each pinning expiry 1789675200 (2026-09-17 16:00 New York) as the Clearinghouse.
- drills: nothing to do on a second run; the lost `settlementOracle.keeperRewards` pointer made VerifyV2 FAIL
  exactly that check (1 of 128), the wiring check refused, `--resume` sent 1 call (22 in place) and passed
  128 checks; TSLA's write-back recovered from the log with nothing sent; one flipped byte of the
  Clearinghouse's trailing CBOR failed exactly the runtime check.
- `script/v2/batch-refusals.sh --registry <temp copy>`: REFUSALS PASSED, 38 cases.
- the first two attempts failed in VerifyV2 and are why the dry run lives in `script/v2/lib/PinDryRun.sol`:
  forge refuses a script contract that calls itself ("Usage of `address(this)` detected in script
  contract"), and `forge script <file>` refuses a target file with two contracts.

### Rehearsal record — 2026-09-17 (settlement pin, INTERFACE_VERSION 6: NVDA + TSLA Chainlink only, on a copy)

**Passed.** The gate for the per-expiry settlement pin (owner decision 2026-09-17); not a pre-broadcast
rehearsal.

- commit: callhouse-contracts `v2-pin-oracle-config` d341777 (contracts, scripts and tests of the pin; the
  docs followed without touching anything the fingerprint covers); forge test 1371/1371; registry: callhouse `leekzor/v2` 7bae299 `ops/markets/tier1.json` and `v2-sources.json`
  copied to a temp `…/callhouse/ops/markets/` with `v2.interfaceVersion` set to 6 (the batch now requires
  6; the callhouse registry still says 4 until the ABIs are re-exported), sha256 `28934a2f…32124`.
- command: `PORT=8570 REGISTRY=<temp>/callhouse/ops/markets/tier1.json script/v2/rehearse-v2.sh` (TICKERS
  NVDA,TSLA, CHAINLINK_ONLY TSLA); fork block **65,273,256**; the whole run 43 s; anvil stopped on exit.
- input copy sha256 `bd9e1743…ebe5c3`; rehearsal record `broadcast/v2-batch/20260917T095130Z/rehearsal-passed.json`,
  fingerprint `f8d307e2…7d801fb6`, phase `fresh`, admin `0xEb82…9d9b` impersonated; bots anvil #8/#9/#10.
- deploy: 13 contracts created, **20 admin calls** sent (the three `setOracle(settlementOracle, true)`
  at 48,266 / 48,266 / 48,401 gas, right after `settlementOracle.setClearinghouse`), 3 already in place;
  33 transactions, **27,684,233 gas**. The addresses are the same as in the C2-13 record below (the
  admin's nonce at the fork block, and the new calls come after every CREATE).
- NVDA: 5 calls, 390,448 gas (no `setOracle`: the deploy wired it); TSLA: 3 calls, 220,953 gas.
- VerifyV2 in the batch and alone on the copy: **VERIFY PASSED 134 checks** (the two new ones: every
  source lists the oracle; neither the admin nor the cranker does).
- drills: nothing to do on a second run; the lost `settlementOracle.keeperRewards` pointer made VerifyV2 FAIL
  it, the wiring check refused, `--resume` sent 1 call (22 in place) and passed 126 checks; TSLA's
  write-back recovered from the log with nothing sent; one flipped byte of the Clearinghouse's trailing
  CBOR failed exactly the runtime check.
- `script/v2/batch-refusals.sh --registry <temp copy>`: REFUSALS PASSED, 38 cases.

### Rehearsal record — 2026-09-17 (C2-13 gate: NVDA canary + TSLA Chainlink only, on a copy)

**Passed.** Not a pre-broadcast rehearsal (the input is a copy with TSLA's pool nulled, and the bots are
stand-ins); it is the gate for these scripts.

- commit: callhouse-contracts `v2` e699dae plus this change (the working tree committed with it); forge
  test 1323/1323; registry: callhouse `v2` ac4688f `ops/markets/tier1.json`, sha256 `5df2f2da…2079f7`,
  unchanged after every run.
- command: `script/v2/rehearse-v2.sh` (defaults: port 8551, TICKERS NVDA,TSLA, CHAINLINK_ONLY TSLA), which
  started `anvil --fork-url https://rpc.mainnet.chain.robinhood.com --chain-id 4663 --port 8551
  --code-size-limit 98304 --retries 12 --fork-retry-backoff 1000 --timeout 60000`; fork block
  **65,238,286**; the whole run 54 s; anvil stopped on exit.
- input copy sha256 `5cdee63e…238199`; rehearsal record `broadcast/v2-batch/20260917T085247Z/rehearsal-passed.json`,
  fingerprint `440eb0ed…dca2f385`, markets `NVDA:register,TSLA:register`, phase `fresh`, admin
  `0xEb82c3D0F89d47453F94f0C2b2a2752e27a19d9b` (the registry's `shared.admin`, impersonated).
- bots: null in the registry, so anvil #8/#9/#10 stood in (written into the copy only).
- deploy: 13 contracts created, 17 admin calls sent, 3 already in place (constructor grants); 30
  transactions, **26,610,285 gas**, deploy block 65,238,287. Addresses (deterministic from the admin's
  nonce at that block): clearinghouse `0xddA8d45f8ccf757adA6026A6E9145A21b454aB3D`, orderBook
  `0xFD8e829D6981dE714b7b342D35Ac6288277b5eC3`, settlementOracle `0x98CD2E5d9384A959D24BA5501f256e7f98d67987`,
  expiryCalendar `0x8b654ff2d3CC435df66015Fb1a7f0D59c8cC1DB9`, keeperRewards
  `0xe2c4B7e256a0081df9ef81A1825E3084E19c01e3`, autoRoller `0xb51997AE857F8eE2Fd6B516329d482Ef2565C41F`,
  payoutAdapter `0xb609F55a0F312A1aB6f11fc9fcAc415793E09bd5`, makerVault
  `0x3B9393984995c13Ce47F17c3bA76BeA4C0901fcF`, makerRegistry `0x6189F55d4CD66A6BAFE416300Def135C32169Dd7`,
  rewardsDistributor `0x573e656cA2ac722F0067788abbA9712698d27610`, sources chainlink
  `0x079868d5c37ab719Ef5396BB923Bd9B20E4c4036`, univ3 `0xc9a5f4cD6839ef77176680BBAD44BF2158178Cb4`,
  dataStreams `0xbb7BdE23bFe01BB3F20762c2D9D06eB3611A88E6`.
- NVDA: every preflight line ok (symbol, 18 dp, `uiMultiplier` 1.000775159164630595e18, not paused,
  "RHNVDA / USD" 8 dp, answer 216.33756615 aged 5,071 s, pool `0xd4EB…14a3` fee 500 is the factory's,
  observe ok, liquidity 2.0145e19 ≥ floor 1.7e18); 5 calls, 389,376 gas; registeredAt 1789635184,
  registerTx `0x7ae3c0978d6d9978bb71ddc5b85ce809986e6262d477a69e36dbd149144ed5a0`.
- TSLA (Chainlink only): every preflight line ok ("RHTSLA / USD", answer 362.195 aged 6,162 s); 3 calls,
  220,381 gas; registeredAt 1789635188, registerTx
  `0x7b6a4675559276dee8d1efa03f14ccba6584607e32693b8dfe78d1af49dd7b0f`.
- VerifyV2 in the batch and again alone on the copy (`--verify --expect-fresh true`): **VERIFY PASSED 132
  checks** each. Info lines: vault and KeeperRewards unfunded; admin is a plain key; NVDA and TSLA `trySpot`
  not ok (feeds older than the 1 h `spotMaxAge` at 04:52 New York).
- drills: a second run refused "nothing to do"; `settlementOracle.setKeeperRewards(0)` made VerifyV2 FAIL
  exactly that pointer, the batch's wiring check listed it PENDING and refused, `--resume` sent 1 call
  (19 in place) and passed 124 checks; TSLA's `registeredAt`/`registerTx` blanked in the copy were recovered
  from the `MarketRegistered` log with nothing sent; one byte of the Clearinghouse's trailing CBOR flipped
  made VerifyV2 FAIL the Clearinghouse runtime check and nothing else.

The same script with `CHAINLINK_ONLY=` (the registry as it is, TSLA with its pool `0xf4AC…89E3`, fee 3000,
TSLA as token0) passed on fork block 65,235,746 in 67 s: TSLA got `setPool` (floor 3.4e17, live 9.26e17),
`setMarket` with both sources and `setRoute(TSLA, 3000)`; VerifyV2 132 checks. A first attempt on
2026-09-17 had died at TSLA on a dropped upstream read of the public RPC ("connection reset"); the anvil
retry flags above were added after it. Both runs predate sweep contracts-c10: until the TSLA pool's ring holds
2,401 observations (1,801 on 2026-09-17), `CHAINLINK_ONLY=` stops at TSLA's preflight
(`pool observationCardinality 1801 is below 2401`), and so does any selection with such a pool.

**What a rehearsal does not prove:** Sourcify verification (only `--broadcast` runs it); the real
deployer/admin keys (the registry admin was impersonated); funding; anything after registration (a
series, a mint, a take, a settlement: C2-08's suites and the F2-04 devnet cover those); the services
reading the written-back registry (ops/deploy.md §15.8); and that mainnet state will match the fork's at
broadcast time (the preflights run again then).
