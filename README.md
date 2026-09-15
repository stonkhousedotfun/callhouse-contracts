# callhouse-contracts

Renamed from Callhouse (callhouse.finance) to Stonkhouse (stonkhouse.fun) on 2026-09-15. Repo, package, service, env and on-chain names still say callhouse.

Stonkhouse contracts. Solidity 0.8.28, Foundry, OpenZeppelin 5, via-IR.

Live product is isolated 1-NVDA accounts (`src/solo/`): `AccountFactory` clones a `WriterAccount`
per user. The user deposits NVDA, requests N lots, and the keeper lists N full Seaport 1.6 orders
of 1 contract on that account's own Valorem option type. A fill writes that user's NVDA and pays
that user. Unfilled lots return at settle.

Factory on chain 4663: `0x7850Ae4ac03b651263cE78EC5FcED11b0d0e05A7`.
Clear: `0x53d7A6d0489Daf3d67b9A314e0eAB2B78Acab9C6`. App venue: `app.stonkhouse.fun/book`.
`docs/DEPLOY.md` "Live deployment" lists every address, who holds each key and what is
source-verified. The contracts are **unaudited**: there is no external audit yet. One is pending
(owner, 2026-09-15; decision D14 of 2026-09-13 had ruled one out). What stands behind them is the test suite described below and the internal reviews in
`SECURITY.md` §4, the latest on 2026-09-14 (no Critical, High or Medium findings).

This repository is the contracts, and the thing any review would target. The app (keeper,
indexer, web, ops) lives in stonkhousedotfun/callhouse and mounts this repository as a git submodule at
`contracts/`.

| Document | What it is |
|---|---|
| [`docs/AUDIT-SCOPE.md`](docs/AUDIT-SCOPE.md) | the review scope: what is in and out, the properties to break, the areas of concern, what the tests do and do not prove, build instructions. Anyone reading the code for bugs starts here |
| [`docs/ACCOUNTING.md`](docs/ACCOUNTING.md) | the money maths: two ledgers, the accrual index, the redeem queue, the stranded-claim state, fees, the thirteen invariants as asserted. Read it before changing anything in `src/` |
| [`SECURITY.md`](SECURITY.md) | the threat model (including what a compromised keeper or admin can leak through pricing, and what each third-party key can do), the properties enforced in bytecode, the 2026-09-12 internal review and the 2026-09-13 audit findings with their fixes, reporting |
| [`docs/DEPLOY.md`](docs/DEPLOY.md) | the contract-side runbook: bootstrap admin, optional own clearinghouse, Verify, the Safe handover, the fork rehearsal record |

Paths in this repository's docs resolve from its root. A path followed by (stonkhousedotfun/callhouse)
lives in the app repository and resolves from that repository's root; a marker after a list
applies to the whole list. For how the vault fits with the keeper, indexer and web app, see
`docs/ARCHITECTURE.md` (stonkhousedotfun/callhouse).

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
  regression/               the audit PoCs (AF-01..AF-05, L-01), each asserting the FIXED behaviour
  invariant/                stateful campaign, thirteen invariants, with a third-party writer in the vault's bucket
  fork/                     against live chain 4663 (a whole week on a test-deployed vault through the live Seaport and Overcall's Clear, the real USDG freeze)
script/
  Deploy.s.sol              constructor args, with an on-chain preflight (decimals, Clear fee state, Seaport 1.6)
  DeployClear.s.sol         OPTIONAL: our own ValoremOptionsClearinghouse from the vendored artifact
  Configure.s.sol           keeper and guardian grants: from the admin key, or as a Safe batch
  HandoverAdmin.s.sol       move DEFAULT_ADMIN_ROLE from the bootstrap key to the Safe
  Verify.s.sol              read-only post-deploy check, bytecode and Seaport runtime hash included
  rehearse-deploy.sh        both admin paths on an anvil fork (--code-size-limit 98304), with real Safes; path A on our own Clear (A0), path B on Overcall's
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
`test/unit/VaultRealSeaport.t.sol` drives five of the real Seaport 1.6 runtime's eight fulfilment
entrypoints against the vault (`fulfillOrder`, `fulfillAdvancedOrder`,
`fulfillAvailableAdvancedOrders` with the same listing twice, `matchAdvancedOrders`,
`fulfillBasicOrder`), including the whole-transaction revert when two occurrences overfill the
remainder. No test calls `fulfillAvailableOrders`, `matchOrders` or
`fulfillBasicOrder_efficient_6GL6yc`.

### Buying and exercising

The app's cycle page serves the keeper's listing, a pre-validated order with an empty signature,
after checking it against `vault.listingHash()`; the same order also fills through any Seaport 1.6
client. A buyer receives ERC-1155 id `vault.optionId()` on the Clear. Each unit is the right to buy
1 NVDA Stock Token for `cycleStrikeUsdg` USDG base units (cycle 1: 223 USDG), and the Clear's
`exercise` accepts it only while `exerciseTimestamp <= block.timestamp < expiryTimestamp` (cycle 1:
Fri 2026-09-18 20:00 UTC to Sat 2026-09-19 20:00 UTC).

The live app has no exercise control: the Exercise card described next is not deployed to
`app.stonkhouse.fun` (checked 2026-09-15), so today a holder exercises on the Clear directly, as in
the paragraph after it.

Once deployed, the card appears on the cycle page only for a connected wallet whose balance of
`vault.optionId()` is above zero. It shows that balance, the strike, the NVDA received per contract,
the exercise and expiry times (UTC and Eastern) and exact USDG totals, and it takes the window from
the chain's latest block, not the device clock. The Exercise button is enabled only inside the
window. The holder picks a whole number of contracts up to the balance; the app simulates
`exercise(optionId, amount)` and shows what the result means, asks for a USDG approval to the Clear
of exactly the total (the strike cost plus the Clear fee if fees are ever switched on) only when the
current allowance is below that total, then calls `exercise`. It warns, and requires explicit
confirmation, when spot times the NVDA received is at or below that total (exercising then costs at
least as much as the NVDA is worth) or when spot cannot be read. A simulation that fails for a
reason the app does not recognise leaves the button enabled, and the wallet shows the outcome.
After expiry the card says the options expired worthless, but only while the vault still names that
option: `rollClose` zeroes `vault.optionId()` unless the claim strands, and the card then
disappears.

Without the app, call `exercise(uint256 optionId, uint112 amount)` on the Clear
`0x53d7A6d0489Daf3d67b9A314e0eAB2B78Acab9C6` directly, after approving the Clear for
`exerciseAmount × amount` USDG (plus `max(floor(that × 15 / 10_000), 1)` if `feesEnabled()`). The
Clear burns the options (no ERC-1155 approval needed), pulls the USDG, sends 1e18 NVDA base units
per contract, and does not check whether the option is in the money. Nothing is exercised
automatically: from `expiryTimestamp` the call reverts `ExpiredOption` and the tokens are worthless.

---

## Building and running the tests

Everything runs from the repository root. The submodules are required; nothing builds without
them.

```bash
git clone --recurse-submodules git@github.com:stonkhousedotfun/callhouse-contracts.git
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

Current state: **405 unit, regression and invariant tests across 24 suites, 20 fork tests** (the
fork suite runs with `FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC`; it needs the live RPC
and is not part of the offline gate). Measured 2026-09-14 on branch
`redesign/a2-own-strikes-2026-09-13` after the L-01 fix. `foundry.toml` sets `isolate = true`, so
every call a test makes runs as its own transaction, as it does on chain.

### CI, and why the local gate is the gate

`.github/workflows/ci.yml` runs two jobs: build, format, unit and invariant tests (with a
non-blocking coverage summary), and the fork tests against chain 4663, using the `RH_RPC` secret
when it is set and the public endpoint otherwise. The runs for `165b4ab` and `0e2f6f6` on `main`
(2026-09-15) pass the fork job and fail the build job: two suites, `VaultInvariant.t.sol` and
`VaultQueue.t.sol`, revert `CreateContractSizeLimit` deploying their test contract under forge
`stable`, so that job ran 341 tests (339 passed, 2 failed) instead of 405. The last green build job
was `634bf55` on 2026-09-13. Until the build job is green, CI does not confirm the offline suite,
and the gate is the four commands above run locally:
`forge fmt --check`, `forge build --sizes`, the unit and invariant suite, and the fork suite. Run
them with `set -o pipefail` when piping: a piped failure that hides behind `tee` is a passed gate
that did not pass.

There is no external audit yet and no separate security gauntlet. An external audit is pending (owner, 2026-09-15; it reverses decision D14 of 2026-09-13).
The contracts are unaudited. What stands behind them is the gate above: 405 tests including the
five audit proofs of concept re-asserted as fixed behaviour on the real Valorem bytecode, the
real Seaport 1.6 runtime driven through five of its eight fulfilment entrypoints, a 64 × 600 stateful campaign with a
third-party writer in the vault's bucket (thirteen invariants, among them: the vault never holds
an unsold option token, its lifetime assignment never exceeds what it sold, and option-token
supply equals unexercised collateral for every id it ever armed), the fork suite against chain
4663 (on a vault the suite deploys against the live Seaport and Overcall's live Clear
`0x9a7b…C0C0`, whose runtime equals ours except the metadata hash; it never touches the live vault
or our Clear: an assigned week and an unfilled week settled, a stranded close under the real USDG freeze role and its recovery, the TSTORE probe answered by the
live node), and `script/rehearse-deploy.sh` on an anvil fork of 4663 with the chain's 98,304 B
code limit (our own Clear deployed and used on path A, Overcall's on path B; `docs/DEPLOY.md`).

---

## Four things that will bite you

**1. `Vault` is above EIP-170's 24,576 B, and that is fine on chain 4663.** Robinhood Chain
enforces a **98,304 B** contract code limit (verified with `eth_call --create` probes: 98,304 B
deploys, 98,305 B fails `max code size exceeded`; decision D17), so `foundry.toml` sets
`code_size_limit = 98304` and forge's 24,576 B warnings are noise here. The Vault runtime is
25,775 B after the redesign, the AF-02 stranded-claim state machine, the AF-05 share-price
floor and the L-01 in-fill deposit refusal (ValoremLib 5,993 B,
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

ABIs flow one way: this repository's `out/` → `ops/abis/Vault.json` (stonkhousedotfun/callhouse) → the
generated copies in `indexer/` and `web/` (stonkhousedotfun/callhouse). The keeper's
`keeper/src/abi.ts` (stonkhousedotfun/callhouse) is hand-transcribed, and a keeper test checks it against
`contracts/out` (stonkhousedotfun/callhouse) when the artefacts are present.

1. Here: make the change, run the full local gate, `forge build`, commit.
2. In stonkhousedotfun/callhouse, bump the submodule pin and rebuild the artefacts there (`out/` is not
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
   (stonkhousedotfun/callhouse) the same way.

---

## Deploying

`SeaportOrderLib` and `ValoremLib` are `public` libraries and must be deployed and linked before
the vault. Foundry does this automatically during `forge script`; to link manually pass
`--libraries` once per library.

The full runbook, rehearsed on a fork with real Safes, is **[`docs/DEPLOY.md`](docs/DEPLOY.md)**
(`script/rehearse-deploy.sh` reproduces it, including negative checks). The live vault was deployed
with a **bootstrap admin**: the deployer, the hot EOA `0xEb82c3D0F89d47453F94f0C2b2a2752e27a19d9b`,
holds `DEFAULT_ADMIN_ROLE` alone, with no timelock. Handing it to a Safe (`HandoverAdmin.s.sol`,
which refuses a threshold below 2) is planned and has not been done. In short (pass
`--no-storage-caching` to every call; see the runbook for why):

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
parameter, role and Safe setting. As written it cannot pass against the live vault: it requires
`policy.minPremiumBps == 40` (`Policy.launchDefaults()`, no override; live is 10) and, unless
`EXPECT_FRESH=false`, a vault with no cycle and no shares (`docs/DEPLOY.md`, "Live deployment").

`Deploy.s.sol` runs an on-chain preflight before broadcasting: the asset has 18 decimals and USDG 6
(every unit convention in `Policy` rests on that), the clearinghouse reports `feeBps() == 15` with
the fee switch off and is ERC-1155, Seaport's `information()` reports version 1.6 with the canonical
ConduitController, and the price feed answers with 8 decimals. There is no registry to point at any
more. `CLEARINGHOUSE` defaults to Overcall's unmodified Clear instance
(`0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0`, whose `feeTo` key holds only the 15 bps fee switch,
which the vault treats as opt-in); `script/DeployClear.s.sol` deploys an instance of our own from the
vendored upstream artifact if that dependency is not wanted. The live vault uses such an instance,
`0x53d7A6d0489Daf3d67b9A314e0eAB2B78Acab9C6`, whose `feeTo` is the 1-of-1 Safe
`0xff1454009F024507f3E455eb2027E98fAF4ccF61`. `Verify.s.sol` also pins the live
Seaport runtime's `extcodehash` to the 4663 Seaport 1.6 runtime the tests were run against.

Source verification goes through **Sourcify**, which supports chain 4663 (`forge verify-contract
--verifier sourcify --chain 4663 <address> <contract>` for the vault and both libraries, or
`--verify --verifier sourcify` on the deploy); Blockscout then imports the match with one click
("Verify & publish → via Sourcify"). Blockscout's own API sits behind a Cloudflare challenge that
`forge` cannot pass, so do not point `--verifier blockscout` at it.

Live verification status: the vault and both libraries are a Sourcify `match` (partial, not
`exact_match`); Blockscout shows the vault as partially verified and holds no source for the
libraries. Our Clear is not source-verified on Sourcify or Blockscout. Its 16,110 B runtime is
byte-identical to Overcall's Clear `0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0` except the CBOR
metadata hash, and that instance is a Sourcify `exact_match` to `valorem-labs-inc/clear` @
`6436c823`.

**Cycle timing** is a keeper concern, not a contract one: the vault reads exercise and expiry from
the option type it arms and never the wall clock. The weekly type the keeper creates opens exercise at the
US close, Friday 16:00 ET, which is 20:00 UTC while US daylight saving is in effect and 21:00 UTC
otherwise (DST ends 2026-11-01), and expires 24 hours later, on Saturday (`expiryTs = exerciseTs +
86400`); a full-day NYSE holiday on a Friday moves the exercise time to Thursday's close. `MAX_CYCLE_TENOR` (21 days) tolerates both.

---

## Roles

| Role | Holder | Powers |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | hot EOA `0xEb82…9d9b` (the deployer), alone; no timelock; the handover to a Safe is planned, not done | grant and revoke every role, set the fee recipient, the policy inside hard caps, the deposit cap (unbounded), `maxPriceAge`, accept the Valorem fee, halt and unhalt. Every change takes effect immediately |
| `KEEPER_ROLE` | hot EOA `0x06c1…C1d2` | `rollOpen(optionId)` (arms a type it or anyone created on the clearinghouse), `approveListing`, `cancelListing`, `invalidateAllListings`, `rollClose` |
| `GUARDIAN_ROLE` | EOA `0x2974…6F39`, derived from the same mnemonic as the admin and keeper keys | `haltWrites` (stops arms, listings AND fills instantly), `cancelListing`, `invalidateAllListings`. It can stop, never start: `unhaltWrites` is admin-only |
| Seaport 1.6 | the protocol contract | `authorizeOrder` / `validateOrder`, the zone hooks that write on every fill; nobody else may call them (`NotSeaport`) |
| anyone | — | `lockBook` after the exercise timestamp; `rollClose` after expiry + 1 hour; `settleQueue` while `Idle` with shares queued; `retryStrandedClaim` whenever a claim is stranded; `sweepFee` whenever a fee is pending; buying the listed calls through any Seaport fulfil function; writing the same option id on Valorem and exercising (assigning the vault pro rata on what it SOLD, nothing more) |

The keeper cannot move a token, but it chooses the option type (strike, window) inside the arm
gate and sets the sale price inside policy, and a compromised keeper (or the bootstrap admin,
which can loosen policy and grant itself the keeper role) can sell at the floor to itself: about
1.5% of sold notional per week at the live policy (3% OTM band floor, 0.10% premium floor, 50%
implied volatility), about 2.2% for the admin. SECURITY.md §3 has the derivation.

A halt blocks `rollOpen`, `approveListing` and every fill (`authorizeOrder` refuses) **only**.
`queueRedeem`, `settleQueue`, `completeRedeem`, `claimUsdg`, `retryStrandedClaim`,
`cancelListing`, `invalidateAllListings`, `lockBook` and `rollClose` all keep working, because a
halt must never trap a depositor. Inside `fulfillAvailable*` a refused hook SKIPS the vault's
order rather than reverting the buyer's batch; on every other path the fill reverts.

**A stranded claim** (a `rollClose` whose Valorem redeem reverted because USDG was paused, the
vault or Clear frozen on USDG, Clear's USDG burnt, or the vault blocklisted on the Stock Token) does
not stop the close: the vault goes to `Idle` with the claim kept, the queue settles on what is idle
and records its share of the claim, deposits and instant redemption stay shut, `rollOpen` reverts
`StillStranded`, and anyone can `retryStrandedClaim()` until Valorem lets the redeem through
(`docs/ACCOUNTING.md` §5, `test/regression/AF02_UsdgFreezeRollClose.t.sol`).

Deposits close on the cycle's exercise **timestamp**, whether or not anyone calls `lockBook`:
after it, `deposit`/`mint` revert `DepositsClosed` and `maxDeposit`/`maxMint` return 0 (the same
selector covers every refusal: wrong phase, unclaimed assignment proceeds, a stranded claim, an
asset balance below `reservedAssets` after an issuer burn, or a share price below the floor of one
share per 1e-6 asset base unit, so a book burnt to nothing with its shares outstanding sells no new
shares; `docs/ACCOUNTING.md` §3).
Assignment collapses NAV mid-transaction with no callback, so minting against the gap has to be
impossible — that was the critical finding of the 2026-09-12 review, written up in
[`SECURITY.md`](SECURITY.md).

## Hard caps, compiled in

Governance cannot exceed these. `Policy.validate` is called on construction and on every update.

| Parameter | Live (`policy()`, 2026-09-15) | Hard bound |
|---|---|---|
| `minOtmBps` | 300 | **floor** 100 — stops an admin selling at-the-money |
| `maxOtmBps` | 1200 | ceiling 2500 |
| `minPremiumBps` | 10 (`Policy.launchDefaults()` sets 40; the admin lowered it with `setPolicy` on 2026-09-15 and can change it again, down to the floor) | floor 10 |
| `maxUtilizationBps` | 9500 | ceiling 9985 (leaves Valorem's 15 bps fee inside the free balance) |
| `protocolFeeBps` | 500 (5% of premium) | ceiling 2000. The fee base is premium only: strike proceeds from assignment are excluded in `Vault._accrueHarvest`, at any setting |
| `maxContractsCap` | 50 | must be non-zero |
| `maxPriceAge` | 4 days | 1 hour to 7 days |
| `depositCap` | 20 NVDA | none: `setDepositCap` is unbounded, and 0 closes deposits |
| listings per cycle | 3 | constant `Policy.MAX_LISTINGS_PER_CYCLE`; every `approveListing` spends one, cancelled or not. A listing is sized to capacity and Seaport tracks the fraction filled, so a relist is a reprice |
| exercise lead / window / tenor | compiled, not a policy field | `ValoremLib.MIN_LEAD` (exercise at least 1 hour after the arm), `MIN_EXERCISE_WINDOW` (at least 1 day), **`MAX_CYCLE_TENOR` 21 days** — a bad option type skips a week, it cannot lock collateral for years or be assigned in the block it was sold |

---

## Sibling repos

| Repository | What it is | Relationship |
|---|---|---|
| stonkhousedotfun/callhouse | the app: keeper, indexer, web (app.stonkhouse.fun), ops runbooks and ABIs, project-wide docs | consumes this repository as a git submodule at `contracts/`, and regenerates `ops/abis/` (then the indexer and web copies) from `out/` after every contract change (see the ABI flow above) |
| stonkhousedotfun/callhouse-site | the marketing landing, stonkhouse.fun | none on the code path; publishes the security contact and the unaudited disclosure |
