# callhouse-contracts

The Callhouse vault. Solidity 0.8.28, Foundry, OpenZeppelin 5, via-IR.

One non-upgradeable vault on Robinhood Chain (chain id 4663) that runs a weekly covered call on
the NVDA Stock Token: depositors put in NVDA and receive `cNVDA` shares, the keeper ARMS an
out-of-the-money Valorem Clear option type each week and lists it on Seaport 1.6 with the vault as
the order's zone, and every fill of that listing WRITES exactly the filled contracts into Valorem
inside Seaport's `authorizeOrder` hook (**write on fill**: the vault never holds an unsold option
token, so `written == sold` by construction). The USDG premium accrues to holders through a
per-share index. The protocol fee is 5% of premium only; strike proceeds from an assignment are
credited to holders fee-free. There is no dependency on Overcall's registry or order book: the
vault validates the option type from the clearinghouse itself and sells through its own fill page.
Nothing is deployed yet, and the contracts are **unaudited** (owner decision 2026-09-13: no
external audit; the gate is the test suite described below, and that is the whole gate).

This repository is the audit target. The app (keeper, indexer, web, ops) lives in
leekzor/callhouse and mounts this repository as a git submodule at `contracts/`.

| Document | What it is |
|---|---|
| [`docs/AUDIT-SCOPE.md`](docs/AUDIT-SCOPE.md) | the audit scope: what is in and out, the properties to break, the areas of concern, build instructions. Auditors start here |
| [`docs/ACCOUNTING.md`](docs/ACCOUNTING.md) | the money maths: two ledgers, the accrual index, the redeem queue, fees. Read it before changing anything in `src/` |
| [`SECURITY.md`](SECURITY.md) | the threat model (including what a compromised keeper or admin can leak through pricing), the properties enforced in bytecode, the 2026-09-12 internal review and the 2026-09-13 findings, reporting |

Paths in this repository's docs resolve from its root. A path followed by (leekzor/callhouse)
lives in the app repository and resolves from that repository's root; a marker after a list
applies to the whole list. For how the vault fits with the keeper, indexer and web app, see
`docs/ARCHITECTURE.md` (leekzor/callhouse).

---

## Layout

```
src/
  Vault.sol                 shares, deposits, the redeem queue, the phase machine, the roll
  Policy.sol                pure bounds maths; the hard caps live in bytecode here
  Distributor.sol           the USDG accrual index, settle-on-transfer, claims
  AdapterValorem.sol        per-cycle claim accounting, redeem, the mint-only ERC-1155 receiver
  AdapterSeaport.sol        listing lifecycle (PARTIAL_RESTRICTED, zone == the vault), the conduit approval
  lib/SeaportOrderLib.sol   order shape validation and Seaport's three encoders  (LINKED LIBRARY)
  lib/ValoremLib.sol        the arm gate (rollOpen) and the fill gate (writeOnFill), redeem, oracle read  (LINKED LIBRARY)
  interfaces/               IValoremClear, ISeaport (+ IZone, ZoneParameters), IStockToken, IChainlinkFeed
  mocks/                    MockClear (bucketed, upstream-faithful), MockSeaport (1.6 hook order), MockStockToken, MockERC20, MockFeed
test/
  Base.t.sol                the shared fixture; mirrors the live NVDA market, creates its own option types
  helpers/                  RealClearBase (real Valorem 6436c82 bytecode), RealSeaportBase (real Seaport 1.6 runtime, etched)
  fixtures/                 the vendored Clear artifact and the 4663 Seaport 1.6 / ConduitController runtimes
  unit/                     per-surface suites, incl. VaultWriteOnFill (mock hooks) and VaultRealSeaport (every real fulfil path)
  regression/               the five audit PoCs (AF-01..AF-05), each asserting the FIXED behaviour
  invariant/                stateful campaign, ten invariants, with a third-party writer in the vault's bucket
  fork/                     against live chain 4663 (write on fill through the live Seaport and Clear)
script/
  Deploy.s.sol              constructor args, with an on-chain preflight (decimals, Clear fee state, Seaport 1.6)
  DeployClear.s.sol         OPTIONAL: our own ValoremOptionsClearinghouse from the vendored artifact
  Configure.s.sol           keeper and guardian grants: from the admin key, or as a Safe batch
  HandoverAdmin.s.sol       move DEFAULT_ADMIN_ROLE from the bootstrap key to the Safe
  Verify.s.sol              read-only post-deploy check, bytecode and Seaport runtime hash included
  rehearse-deploy.sh        both admin paths on an anvil fork (--code-size-limit 98304), with real Safes
  rehearsal/                ExecuteSafeBatch.s.sol (anvil only)
docs/                       AUDIT-SCOPE.md, ACCOUNTING.md, DEPLOY.md
lib/                        forge-std, openzeppelin-contracts (git submodules)
```

`Distributor`, `AdapterValorem` and `AdapterSeaport` are **abstract bases the vault inherits**, not
separate deployments. Valorem mints the claim NFT to `msg.sender` and `redeem` reverts for anyone
else; Seaport only accepts `validate` and `cancel` from the offerer and calls the zone's hooks on
the zone. The code has to run in the vault's own context.

## Write on fill (decision D1, A(ii)) and no registry (decision D16)

The 2026-09-13 audit's F-01 (High) was that the vault wrote calls ahead of selling them and never
exercised the unsold ones: anyone could write the same Valorem option id into the vault's bucket
and self-exercise, taking `unsold × (spot − strike)` of depositor principal every in-the-money
week. The redesign closes it by construction rather than by bounding it:

- `rollOpen(optionId)` (keeper) **arms** a cycle and writes nothing. The vault reads the option
  tuple back from the clearinghouse (`tokenType == Option`, our asset and USDG, lot exactly 1e18,
  exercise at least 1 hour out, a window of at least 1 day, a tenor of at most 21 days, Valorem
  fee off or accepted, oracle live, strike inside the OTM band with BOTH bounds) and snapshots
  the strike and window. The keeper creates the weekly type itself with `clear.newOptionType`,
  which is permissionless; nothing outside the vault numbers its cycles.
- `approveListing` authorises ONE `PARTIAL_RESTRICTED` Seaport order with **zone == the vault**,
  one ERC-1155 offer item (the armed id, at most the remaining capacity) and ONE consideration
  item (USDG to the vault; there is no venue fee item). The vault pre-validates it on Seaport, so
  an empty signature fills. The vault has no signing key and no EIP-1271 hook.
- Seaport 1.6 calls the vault's `authorizeOrder` **before any transfer and before recording the
  fill, on every fulfilment path**. The hook checks the order is the live listing, the phase is
  Listed and writes are not halted, then `ValoremLib.writeOnFill` re-runs the clock, the fee
  switch, the oracle, the band FLOOR and the premium floor at live spot (plus fee × spot when the
  engine fee is on), sizes `written + k` on the total, and writes exactly `k`: `clear.write(
  optionId, k)` on the first fill (recording the claim) or `clear.write(claimKey, k)` afterwards.
  Seaport then moves the freshly minted tokens to the buyer. `validateOrder` runs after every
  transfer and reverts `InventoryLeftBehind` unless the vault's option balance is back at its
  pre-fill baseline (kept in transient storage, so the same listing can appear twice in one
  `fulfillAvailableAdvancedOrders`).
- The vault never calls a Seaport fulfil function, so the one caller Seaport exempts from the
  hooks (the zone) never fills. The ERC-1155 receiver accepts only mints from the clearinghouse
  (`from == address(0)`), so nobody can donate option tokens or a claim into the vault.
- `rollClose` with `claimKey == 0` (an unsold week) skips the redeem, harvests, settles the queue
  and returns to Idle, where instant redemption works again.

`test/regression/AF01_UnsoldInventory.t.sol` replays the audit's unsteered and steered attacks on
the real Clear bytecode and asserts the depositor ends exactly where the honest week left her.
`test/unit/VaultRealSeaport.t.sol` drives every real Seaport 1.6 fulfilment path against the vault
(`fulfillOrder`, `fulfillAdvancedOrder`, `fulfillAvailableAdvancedOrders` with the same listing
twice, `matchAdvancedOrders`, `fulfillBasicOrder`), including the whole-transaction revert when
two occurrences overfill the remainder.

---

## Building and running the tests

Everything runs from the repository root. The submodules are required; nothing builds without
them.

```bash
git clone --recurse-submodules git@github.com:leekzor/callhouse-contracts.git
# or, in an existing checkout:
git submodule update --init --recursive

forge fmt --check                                     # format gate
forge build --sizes                                   # report sizes; the 98,304 B chain limit is the real one (see 1 below)
rm -rf cache/invariant                                # after any behaviour change (see 4 below)
forge test --no-match-path 'test/fork/*'              # unit + invariant, mocks only
forge test --match-path 'test/unit/VaultQueue.t.sol'  # one suite
FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC    # against live chain 4663
```

`RH_RPC` can be the public endpoint, `https://rpc.mainnet.chain.robinhood.com`. The `fork`
profile in `foundry.toml` restricts the run to `test/fork/*`; the `ci` profile only raises
verbosity.

Current state: **397 unit, regression and invariant tests across 23 suites, 16 fork tests** (the
fork suite runs with `FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC`; it needs the live RPC
and is not part of the offline gate). Measured 2026-09-13 on branch `redesign/s3-parallel`.

### CI, and why the local gate is the gate

`.github/workflows/ci.yml` runs two jobs: build, format, unit and invariant tests (with a
non-blocking coverage summary), and the fork tests against chain 4663, using the `RH_RPC` secret
when it is set and the public endpoint otherwise. Every GitHub Actions run on the leekzor account
currently dies with `startup_failure` at the account level (billing), before any step runs. Until
that is fixed CI proves nothing, and the gate is the four commands above run locally:
`forge fmt --check`, `forge build --sizes`, the unit and invariant suite, and the fork suite. Run
them with `set -o pipefail` when piping: a piped failure that hides behind `tee` is a passed gate
that did not pass.

There is no external audit (owner decision D14, 2026-09-13) and no separate security gauntlet.
The contracts are unaudited. What stands behind them is the gate above: 397 tests including the
five audit proofs of concept re-asserted as fixed behaviour on the real Valorem bytecode, the
real Seaport 1.6 runtime driven through every fulfilment path, a 64 × 600 stateful campaign with a
third-party writer in the vault's bucket, and the fork suite against chain 4663.

---

## Four things that will bite you

**1. `Vault` is above EIP-170's 24,576 B, and that is fine on chain 4663.** Robinhood Chain
enforces a **98,304 B** contract code limit (verified with `eth_call --create` probes: 98,304 B
deploys, 98,305 B fails `max code size exceeded`; decision D17), so `foundry.toml` sets
`code_size_limit = 98304` and forge's 24,576 B warnings are noise here. The Vault runtime is
25,470 B after the redesign and the AF-02 stranded-claim state machine (ValoremLib 5,993 B,
SeaportOrderLib 5,170 B); `forge build --sizes` therefore prints a negative "margin" and exits 1,
which is forge measuring against EIP-170 and is ignored by the gate. Two things follow:
a default `anvil` REFUSES the Vault — `script/rehearse-deploy.sh` requires and probes for
`--code-size-limit 98304` — and the contracts are not portable to a chain with the EIP-170 limit
without a library extraction. Sizes are still reported by `forge build --sizes`.

**2. The test tree is near solc's tag-space limit.** Each unit suite deploys the whole fixture and
compiles to roughly 100–122 KB of deployed bytecode. With via-IR on, adding another fixture-heavy
suite can produce:

```
Internal compiler error (CompilerStack.cpp:1417):
Assembly exception for bytecode: Tag too large for reserved space
```

If it appears, factor shared sequences into helpers on `BaseTest` rather than repeating them.

**3. `vm.expectRevert` arms the NEXT external call.** If you compute an argument with a helper that
itself makes an external call — anything reading the vault, the clearinghouse or the fixture — hoist
it into a local first. This has caused eight false failures in this repo already. `vm.expectEmit`
has the same rule: an `approve` between the cheatcode and the fill is the call it will judge.

**4. Clear `cache/invariant` after changing contract behaviour.** Foundry replays persisted
counterexamples, and a stale one surfaces as a mystery failure in an unrelated test.

---

## After a contract change: the ABI flow

ABIs flow one way: this repository's `out/` → `ops/abis/Vault.json` (leekzor/callhouse) → the
generated copies in `indexer/` and `web/` (leekzor/callhouse). The keeper's
`keeper/src/abi.ts` (leekzor/callhouse) is hand-transcribed, and a keeper test checks it against
`contracts/out` (leekzor/callhouse) when the artefacts are present.

1. Here: make the change, run the full local gate, `forge build`, commit.
2. In leekzor/callhouse, bump the submodule pin and rebuild the artefacts there (`out/` is not
   committed):

   ```bash
   git -C contracts fetch && git -C contracts checkout <commit>
   (cd contracts && forge build)
   jq --indent 1 '.abi' contracts/out/Vault.sol/Vault.json > ops/abis/Vault.json
   (cd indexer && pnpm gen:abis)
   (cd web && pnpm gen:abis)
   git add contracts ops/abis indexer web
   ```

   `jq --indent 1` reproduces the committed file byte for byte. If the change touches
   `SeaportOrderLib` or `Policy`, refresh `ops/abis/SeaportOrderLib.json` and `ops/abis/Policy.json`
   (leekzor/callhouse) the same way.

---

## Deploying

`SeaportOrderLib` and `ValoremLib` are `public` libraries and must be deployed and linked before
the vault. Foundry does this automatically during `forge script`; to link manually pass
`--libraries` once per library.

The full runbook, rehearsed on a fork with real Safes, is **[`docs/DEPLOY.md`](docs/DEPLOY.md)**
(`script/rehearse-deploy.sh` reproduces it, including negative checks). The launch plan for now is a
**bootstrap admin**: the deployer key holds `DEFAULT_ADMIN_ROLE` at launch and hands it to the 2-of-3
Safe later. In short (pass `--no-storage-caching` to every call; see the runbook for why):

```bash
ADMIN=<deployer address> forge script script/Deploy.s.sol --rpc-url $RH_RPC --broadcast --slow --verify ...
ADMIN_PHASE=bootstrap EXPECT_KEEPER_CONFIGURED=false forge script script/Verify.s.sol --rpc-url $RH_RPC
ADMIN_PK=... forge script script/Configure.s.sol --rpc-url $RH_RPC --broadcast   # keeper + guardian grants
ADMIN_PHASE=bootstrap forge script script/Verify.s.sol --rpc-url $RH_RPC
# later: the handover
STEP=grant    forge script script/HandoverAdmin.s.sol --rpc-url $RH_RPC --broadcast   # then the Safe executes the smoke batch
STEP=renounce forge script script/HandoverAdmin.s.sol --rpc-url $RH_RPC --broadcast   # refused until the Safe has executed
ADMIN_PHASE=safe forge script script/Verify.s.sol --rpc-url $RH_RPC
```

Until the handover, the deployer key has every admin power (fee up to 20% of premium and its
recipient, deposit cap, policy inside the hard caps, role grants). `Verify.s.sol` compares the
deployed vault and libraries byte for byte with this commit's build and checks every immutable,
parameter, role and Safe setting.

`Deploy.s.sol` runs an on-chain preflight before broadcasting: the asset has 18 decimals and USDG 6
(every unit convention in `Policy` rests on that), the clearinghouse reports `feeBps() == 15` with
the fee switch off and is ERC-1155, Seaport's `information()` reports version 1.6 with the canonical
ConduitController, and the price feed answers with 8 decimals. There is no registry to point at any
more. `CLEARINGHOUSE` defaults to Overcall's unmodified Clear instance
(`0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0`, whose `feeTo` key holds only the 15 bps fee switch,
which the vault treats as opt-in); `script/DeployClear.s.sol` deploys an instance of our own from the
vendored upstream artifact if that dependency is not wanted. `Verify.s.sol` also pins the live
Seaport runtime's `extcodehash` to the 4663 Seaport 1.6 runtime the tests were run against.

Blockscout for chain 4663 sits behind a Cloudflare challenge that keys on the **absence** of a
`Referer` header, which `forge` never sends. `ops/bsproxy.js` (leekzor/callhouse) is a tiny local
proxy that injects one so `forge verify-contract` works.

---

## Roles

| Role | Holder | Powers |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | 2/3 Safe | set the keeper, the fee recipient, the policy inside hard caps, the deposit cap, `maxPriceAge`, accept the Valorem fee, unhalt |
| `KEEPER_ROLE` | hot wallet | `rollOpen(optionId)` (arms a type it or anyone created on the clearinghouse), `approveListing`, `cancelListing`, `invalidateAllListings`, `rollClose` |
| `GUARDIAN_ROLE` | 1/1 hardware key | `haltWrites` (stops arms, listings AND fills instantly), `cancelListing`, `invalidateAllListings` |
| Seaport 1.6 | the protocol contract | `authorizeOrder` / `validateOrder`, the zone hooks that write on every fill; nobody else may call them (`NotSeaport`) |
| anyone | — | `lockBook` after the exercise timestamp; `rollClose` after expiry + 1 hour; `sweepFee` whenever a fee is pending; `settleQueue` while `Idle` with shares queued; buying the listed calls through any Seaport fulfil function |

The keeper cannot move a token, but it sets the sale price inside policy, and a compromised keeper
(or the bootstrap admin, which can loosen policy and grant itself the keeper role) can sell at the
floor to itself. SECURITY.md §3 has the bound per week.

A halt blocks `rollOpen`, `approveListing` and every fill (`authorizeOrder` refuses) **only**.
`queueRedeem`, `settleQueue`, `completeRedeem`, `claimUsdg`, `cancelListing`,
`invalidateAllListings`, `lockBook` and `rollClose` all keep working, because a halt must never
trap a depositor. Inside `fulfillAvailable*` a refused hook SKIPS the vault's order rather than
reverting the buyer's batch; on every other path the fill reverts.

Deposits close on the cycle's exercise **timestamp**, whether or not anyone calls `lockBook`:
after it, `deposit`/`mint` revert `DepositsClosed` and `maxDeposit`/`maxMint` return 0 (the same
selector covers every refusal: wrong phase, unclaimed assignment proceeds, a stranded claim, or an
asset balance below `reservedAssets` after an issuer burn).
Assignment collapses NAV mid-transaction with no callback, so minting against the gap has to be
impossible — that was the critical finding of the 2026-09-12 review, written up in
[`SECURITY.md`](SECURITY.md).

## Hard caps, compiled in

Governance cannot exceed these. `Policy.validate` is called on construction and on every update.

| Parameter | Launch | Hard bound |
|---|---|---|
| `minOtmBps` | 300 | **floor** 100 — stops an admin selling at-the-money |
| `maxOtmBps` | 1200 | ceiling 2500 |
| `minPremiumBps` | 40 | floor 10 |
| `maxUtilizationBps` | 9500 | ceiling 9985 (leaves Valorem's 15 bps fee inside the free balance) |
| `protocolFeeBps` | 500 (5% of premium) | ceiling 2000. The fee base is premium only: strike proceeds from assignment are excluded in `Vault._accrueHarvest`, at any setting |
| `maxContractsCap` | 50 | must be non-zero |
| `maxPriceAge` | 4 days | 1 hour to 7 days |
| listings per cycle | 3 | constant `Policy.MAX_LISTINGS_PER_CYCLE`; every `approveListing` spends one, cancelled or not. A listing is sized to capacity and Seaport tracks the fraction filled, so a relist is a reprice |
| exercise lead / window / tenor | 1 hour / 1 day / 7 days | `ValoremLib.MIN_LEAD` (exercise at least 1 hour after the arm), `MIN_EXERCISE_WINDOW` (at least 1 day), **`MAX_CYCLE_TENOR` 21 days** — a bad option type skips a week, it cannot lock collateral for years or be assigned in the block it was sold |

---

## Sibling repos

| Repository | What it is | Relationship |
|---|---|---|
| leekzor/callhouse | the app: keeper, indexer, web (app.callhouse.finance), ops runbooks and ABIs, project-wide docs | consumes this repository as a git submodule at `contracts/`, and regenerates `ops/abis/` (then the indexer and web copies) from `out/` after every contract change (see the ABI flow above) |
| leekzor/callhouse-site | the marketing landing, callhouse.finance | none on the code path; publishes the security contact and the unaudited disclosure |
