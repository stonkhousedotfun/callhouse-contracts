# callhouse-contracts

The Callhouse vault. Solidity 0.8.28, Foundry, OpenZeppelin 5, via-IR.

One non-upgradeable vault on Robinhood Chain (chain id 4663) that runs a weekly covered call on
the NVDA Stock Token: depositors put in NVDA and receive `cNVDA` shares, the vault writes
out-of-the-money calls on Valorem Clear and sells them through Seaport 1.6 on Overcall's order
book, and the USDG premium accrues to holders through a per-share index. The protocol fee is 5%
of premium only; strike proceeds from an assignment are credited to holders fee-free. Nothing is
deployed yet, and the contracts are unaudited.

This repository is the audit target. The app (keeper, indexer, web, ops) lives in
leekzor/callhouse and mounts this repository as a git submodule at `contracts/`.

| Document | What it is |
|---|---|
| [`docs/AUDIT-SCOPE.md`](docs/AUDIT-SCOPE.md) | the audit scope: what is in and out, the properties to break, the areas of concern, build instructions. Auditors start here |
| [`docs/ACCOUNTING.md`](docs/ACCOUNTING.md) | the money maths: two ledgers, the accrual index, the redeem queue, fees. Read it before changing anything in `src/` |
| [`SECURITY.md`](SECURITY.md) | the threat model, the properties enforced in bytecode, the 2026-09-12 internal review, reporting |

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
  AdapterValorem.sol        write, redeem, claim and position accounting
  AdapterSeaport.sol        listing lifecycle, EIP-1271, the conduit approval
  lib/SeaportOrderLib.sol   order shape validation and Seaport's three encoders  (LINKED LIBRARY)
  lib/ValoremLib.sol        the write/redeem path against Valorem, option-window check  (LINKED LIBRARY)
  interfaces/               IValoremClear, IOvercallRegistry, ISeaport, IStockToken, IChainlinkFeed
  mocks/                    MockClear, MockRegistry, MockSeaport, MockStockToken, MockERC20, MockFeed
test/
  Base.t.sol                the shared fixture; mirrors the live NVDA market
  unit/                     per-surface suites
  invariant/                stateful campaign, eight invariants
  fork/                     against live chain 4663
script/
  Deploy.s.sol              constructor args, with an on-chain preflight
  Configure.s.sol           keeper and guardian grants: from the admin key, or as a Safe batch
  HandoverAdmin.s.sol       move DEFAULT_ADMIN_ROLE from the bootstrap key to the Safe
  Verify.s.sol              read-only post-deploy check, bytecode included
  rehearse-deploy.sh        both admin paths on an anvil fork, with real Safes
  rehearsal/                ExecuteSafeBatch.s.sol (anvil only)
docs/                       AUDIT-SCOPE.md, ACCOUNTING.md, DEPLOY.md
lib/                        forge-std, openzeppelin-contracts (git submodules)
```

`Distributor`, `AdapterValorem` and `AdapterSeaport` are **abstract bases the vault inherits**, not
separate deployments. Valorem mints the claim NFT to `msg.sender` and `redeem` reverts for anyone
else; Seaport only accepts `validate` and `cancel` from the offerer. The code has to run in the
vault's own context.

---

## Building and running the tests

Everything runs from the repository root. The submodules are required; nothing builds without
them.

```bash
git clone --recurse-submodules git@github.com:leekzor/callhouse-contracts.git
# or, in an existing checkout:
git submodule update --init --recursive

forge fmt --check                                     # format gate
forge build --sizes                                   # watch the EIP-170 margin
rm -rf cache/invariant                                # after any behaviour change (see 4 below)
forge test --no-match-path 'test/fork/*'              # unit + invariant, mocks only
forge test --match-path 'test/unit/VaultQueue.t.sol'  # one suite
FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC    # against live chain 4663
```

`RH_RPC` can be the public endpoint, `https://rpc.mainnet.chain.robinhood.com`. The `fork`
profile in `foundry.toml` restricts the run to `test/fork/*`; the `ci` profile only raises
verbosity.

Current state: **310 unit and invariant tests across 12 suites, 21 fork tests, all passing**.

### CI, and why the local gate is the gate

`.github/workflows/ci.yml` runs two jobs: build, format, unit and invariant tests (with a
non-blocking coverage summary), and the fork tests against chain 4663, using the `RH_RPC` secret
when it is set and the public endpoint otherwise. Every GitHub Actions run on the leekzor account
currently dies with `startup_failure` at the account level (billing), before any step runs. Until
that is fixed CI proves nothing, and the gate is the four commands above run locally:
`forge fmt --check`, `forge build --sizes`, the unit and invariant suite, and the fork suite.

---

## Four things that will bite you

**1. `Vault` has about 1.15 KB of headroom** under the EIP-170 24,576-byte runtime limit (23,426 B
used, 1,150 B margin). via-IR is already on and BOTH `SeaportOrderLib` and `ValoremLib` are
already extracted — the second extraction paid for the deposit-gate and cycle-window checks from
the 2026-09-12 review. Optimiser runs were measured from 1 to 200 and move the figure by under
200 bytes, so if you run out of room the answer is another library extraction, not another
setting.

**2. The test tree is near solc's tag-space limit.** Each unit suite deploys the whole fixture and
compiles to roughly 100–122 KB of deployed bytecode. With via-IR on, adding another fixture-heavy
suite can produce:

```
Internal compiler error (CompilerStack.cpp:1417):
Assembly exception for bytecode: Tag too large for reserved space
```

If it appears, factor shared sequences into helpers on `BaseTest` rather than repeating them.

**3. `vm.expectRevert` arms the NEXT external call.** If you compute an argument with a helper that
itself makes an external call — anything reading the vault, the registry or the fixture — hoist it
into a local first. This has caused eight false failures in this repo already.

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

`Deploy.s.sol` runs an on-chain preflight before broadcasting: it refuses to deploy against a
registry whose `collateralToken`, `exerciseToken` or `clearinghouse` do not match, and it checks the
price feed answers and has 8 decimals. That guard exists because Overcall's frontend config carries
a top-level `registry` key that is the **JUGGERNAUT** market, not NVDA, and wiring it would
collateralise NVDA calls with the wrong token.

Blockscout for chain 4663 sits behind a Cloudflare challenge that keys on the **absence** of a
`Referer` header, which `forge` never sends. `ops/bsproxy.js` (leekzor/callhouse) is a tiny local
proxy that injects one so `forge verify-contract` works.

---

## Roles

| Role | Holder | Powers |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | 2/3 Safe | set the keeper, the fee recipient, the policy inside hard caps, the deposit cap, `maxPriceAge`, accept the Valorem fee, unhalt |
| `KEEPER_ROLE` | hot wallet | `rollOpen`, `approveListing`, `cancelListing`, `invalidateAllListings`, `rollClose` |
| `GUARDIAN_ROLE` | 1/1 hardware key | `haltWrites`, `cancelListing`, `invalidateAllListings` |
| anyone | — | `lockBook` after the exercise timestamp; `rollClose` after expiry + 1 hour; `sweepFee` whenever a fee is pending |

A halt blocks `rollOpen` and `approveListing` **only**. `queueRedeem`, `completeRedeem`,
`claimUsdg`, `cancelListing`, `lockBook` and `rollClose` all keep working, because a halt must
never trap a depositor.

Deposits close on the cycle's exercise **timestamp**, whether or not anyone calls `lockBook`:
after it, `deposit`/`mint` revert `DepositsClosedForCycle` and `maxDeposit`/`maxMint` return 0.
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
| `maxUtilizationBps` | 9500 | ceiling 10000 |
| `protocolFeeBps` | 500 (5% of premium) | ceiling 2000. The fee base is premium only: strike proceeds from assignment are excluded in `Vault._accrueHarvest`, at any setting |
| `maxContractsCap` | 50 | must be non-zero |
| `maxPriceAge` | 4 days | 1 hour to 7 days |
| listings per cycle | 3 | constant |
| cycle tenor | 7 days (Overcall's) | **ceiling 21 days**, `MAX_CYCLE_TENOR` — a bad cycle from the registry EOA skips a week, it cannot lock collateral for years |

---

## Sibling repos

| Repository | What it is | Relationship |
|---|---|---|
| leekzor/callhouse | the app: keeper, indexer, web (app.callhouse.finance), ops runbooks and ABIs, project-wide docs | consumes this repository as a git submodule at `contracts/`, and regenerates `ops/abis/` (then the indexer and web copies) from `out/` after every contract change (see the ABI flow above) |
| leekzor/callhouse-site | the marketing landing, callhouse.finance | none on the code path; publishes the security contact and the unaudited disclosure |
