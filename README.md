# contracts

The Callhouse vault. Solidity 0.8.28, Foundry, OpenZeppelin 5, via-IR.

See [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) for how this fits with the keeper, indexer
and web app, and [`../docs/ACCOUNTING.md`](../docs/ACCOUNTING.md) for the money maths. Read the
accounting doc before changing anything in `src/`.

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
  invariant/                stateful campaign, six invariants
  fork/                     against live chain 4663
script/
  Deploy.s.sol              constructor args, with an on-chain preflight
  Configure.s.sol           grant roles, optional policy override
```

`Distributor`, `AdapterValorem` and `AdapterSeaport` are **abstract bases the vault inherits**, not
separate deployments. Valorem mints the claim NFT to `msg.sender` and `redeem` reverts for anyone
else; Seaport only accepts `validate` and `cancel` from the offerer. The code has to run in the
vault's own context.

---

## Running the tests

```bash
forge test                                            # unit + invariant, mocks only
forge test --match-path 'test/unit/VaultQueue.t.sol'  # one suite
FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC    # against live chain 4663
forge fmt --check                                     # CI gate
forge build --sizes                                   # watch the EIP-170 margin
```

Current state: **307 unit and invariant tests across 12 suites, 21 fork tests, all passing**.

---

## Four things that will bite you

**1. `Vault` has about 1.4 KB of headroom** under the EIP-170 24,576-byte runtime limit (23,142 B
used). via-IR is already on and BOTH `SeaportOrderLib` and `ValoremLib` are already extracted —
the second extraction paid for the deposit-gate and cycle-window checks from the 2026-09-12
review. Optimiser runs were measured from 1 to 200 and move the figure by under 200 bytes, so if
you run out of room the answer is another library extraction, not another setting.

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

## Deploying

`SeaportOrderLib` and `ValoremLib` are `public` libraries and must be deployed and linked before
the vault. Foundry does this automatically during `forge script`; to link manually pass
`--libraries` once per library.

```bash
forge script script/Deploy.s.sol --rpc-url $RH_RPC --broadcast \
  --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api

forge script script/Configure.s.sol --rpc-url $RH_RPC --broadcast
```

`Deploy.s.sol` runs an on-chain preflight before broadcasting: it refuses to deploy against a
registry whose `collateralToken`, `exerciseToken` or `clearinghouse` do not match, and it checks the
price feed answers and has 8 decimals. That guard exists because Overcall's frontend config carries
a top-level `registry` key that is the **JUGGERNAUT** market, not NVDA, and wiring it would
collateralise NVDA calls with the wrong token.

Blockscout for chain 4663 sits behind a Cloudflare challenge that keys on the **absence** of a
`Referer` header, which `forge` never sends. `ops/bsproxy.js` is a tiny local proxy that injects one
so `forge verify-contract` works.

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
[`../SECURITY.md`](../SECURITY.md).

## Hard caps, compiled in

Governance cannot exceed these. `Policy.validate` is called on construction and on every update.

| Parameter | Launch | Hard bound |
|---|---|---|
| `minOtmBps` | 300 | **floor** 100 — stops an admin selling at-the-money |
| `maxOtmBps` | 1200 | ceiling 2500 |
| `minPremiumBps` | 40 | floor 10 |
| `maxUtilizationBps` | 9500 | ceiling 10000 |
| `protocolFeeBps` | 1000 | ceiling 2000 |
| `maxContractsCap` | 50 | must be non-zero |
| `maxPriceAge` | 4 days | 1 hour to 7 days |
| listings per cycle | 3 | constant |
| cycle tenor | 7 days (Overcall's) | **ceiling 21 days**, `MAX_CYCLE_TENOR` — a bad cycle from the registry EOA skips a week, it cannot lock collateral for years |
