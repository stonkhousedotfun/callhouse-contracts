# Deploying the vault

The contract-side runbook for mainnet (chain 4663). Hosting the keeper, indexer and frontends is a
separate runbook, `ops/deploy.md` in leekzor/callhouse. Every step here is rehearsed end to end by
`script/rehearse-deploy.sh` on an anvil fork; the latest record is at the bottom.

**Nothing here is done yet.** The contracts are unaudited and stay labelled so (owner decision D14:
no external audit; the gate is the test suite, README "CI, and why the local gate is the gate"). Do
not run the mainnet steps on a commit that has not passed the full gate, fork suite and rehearsal
included, or that differs from the commit `Verify.s.sol` will be run from.

---

## The plan: bootstrap admin now, Safe later

`Deploy.s.sol` gives `DEFAULT_ADMIN_ROLE` to exactly one address at construction: `ADMIN` if set,
otherwise `SAFE_ADMIN`. **The launch plan for now is `ADMIN` = the deployer's own address**
("bootstrap"). The deployer key then configures the vault directly, and the admin role moves to the
2-of-3 Safe later with `script/HandoverAdmin.s.sol`.

> **Warning.** Until the handover completes, whoever holds the deployer key holds every admin power: setting the
> protocol fee up to its 20%-of-premium ceiling and its recipient, the deposit cap, the policy inside
> its hard caps, the price age, unhalting, accepting the Valorem engine fee, and granting or revoking
> every role (including granting itself `KEEPER_ROLE`). Keep that key offline, use it only for the
> steps below, and schedule the handover.

The alternative, still supported and rehearsed: pass `SAFE_ADMIN` and no `ADMIN`, so the Safe is
admin from block one and every admin action is a Safe transaction (path B below).

| Script | What it does |
|---|---|
| `script/Deploy.s.sol` | preflight (asset 18 / USDG 6 decimals, Clear `feeBps == 15` and switch off and ERC-1155, Seaport 1.6 with the canonical ConduitController, feed answer and 8 decimals), then libraries + vault. The constructor takes one `Vault.Config` struct (asset, USDG, clearinghouse, Seaport, price feed, `maxPriceAge`, conduit key, admin, fee recipient, deposit cap, name, symbol): there is no registry and no zone parameter, the zone is the vault itself and is derived. Warns loudly when the admin is a plain key |
| `script/DeployClear.s.sol` | OPTIONAL: deploys our own ValoremOptionsClearinghouse from the vendored upstream artifact (`feeTo` = our admin) and asserts `feeBps() == 15`, `feesEnabled() == false`; pass its address to Deploy as `CLEARINGHOUSE` |
| `script/Configure.s.sol` | grants `KEEPER_ROLE` and `GUARDIAN_ROLE`. With `ADMIN_PK` it broadcasts from that key (refuses a key without admin); without, it only writes a Safe Transaction Builder batch |
| `script/HandoverAdmin.s.sol` | `STEP=grant` gives the admin role to the Safe and writes a harmless smoke batch; `STEP=renounce` removes the key's admin role, and refuses until the Safe has executed a transaction after the grant |
| `script/Verify.s.sol` | read-only; 63 checks bootstrap-unconfigured, 69 bootstrap-configured, 72 safe phase with the owner set pinned, 71 without (re-derived by the 2026-09-13 rehearsal; the redesign added the zone, interface, Seaport runtime-hash, Clear fee-state and decimals checks and removed the registry and Overcall-fee ones). Reverts if any fail |
| `script/rehearsal/ExecuteSafeBatch.s.sol` | rehearsal only: runs a batch file through a Safe with owner keys. Refuses any node that is not anvil |

---

## Before the day

| Item | Detail |
|---|---|
| Deployer key | an EOA kept offline. It is the vault admin until the handover. Fund it for about 8.4M gas (rehearsal 2026-09-13: 8,355,876 for the two libraries and the vault; 5,831,215 when the libraries already exist) plus the configure and handover transactions, and about 3.5M more if `DeployClear.s.sol` is used |
| Admin Safe | 2 of 3, created in Safe{Wallet} on Robinhood Chain (supported; SafeL2 1.4.1 and SafeProxyFactory 1.4.1 are deployed at their canonical addresses). Owners on hardware. No modules, no guard. `ops/safes.md` §1 (leekzor/callhouse) |
| Fee Safe | receives the protocol fee (5% of premium). Its legal owner is a counsel question, `ops/launch-legal.md` §2 item 5 (leekzor/callhouse) |
| Guardian key | 1 of 1 on separate hardware, as `ops/safes.md` §3 (leekzor/callhouse) requires |
| Keeper key | hot EOA used by the keeper service; it can never move funds. `ops/safes.md` §2 (leekzor/callhouse) |
| RPC | `RH_RPC`, preferably an archive endpoint |
| Source verification | **Sourcify** (`--verifier sourcify --chain 4663`), which supports 4663 and holds exact matches for the third-party contracts already; Blockscout then imports the match with one click ("Verify & publish → via Sourcify"). Blockscout's own API sits behind a Cloudflare challenge that `forge` cannot pass, so do not use `--verifier blockscout` against it. Verify the vault AND both libraries |
| Cycle timing (keeper) | the vault reads exercise and expiry from the option type and never the wall clock. The weekly type should expire at the US close, **Friday 16:00 ET = 20:00 UTC while US daylight saving is in effect, 21:00 UTC otherwise** (DST ends 2026-11-01), or Thursday's close when Friday is a full-day NYSE holiday; the arm gate accepts any window from 1 hour + 1 day out to 21 days, so both fit |
| Commit | the release tag, checked out, `forge build` clean, unit + invariant and fork suites and the rehearsal green on that exact commit. `Verify.s.sol` compares the chain against this checkout's `out/` |

Checks on the day, before broadcasting:

```bash
forge build --sizes                              # Vault under 98,304 B (chain 4663's limit; forge's 24,576 B
                                                 # "margin" line and exit 1 are noise here, README item 1)
cast call 0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0 "feesEnabled()(bool)" --rpc-url $RH_RPC
                                                 # false; if true, stop: the engine fee needs a governance decision
```

> **Warning.** Pass `--no-storage-caching` to every `forge script` in this runbook. Forge caches fork state under
> `~/.foundry/cache/rpc/4663/<block>`, and a rehearsal on an anvil fork mines blocks at real chain-4663
> heights, so a stale cache can hand a mainnet run fake rehearsal state. If you have ever run a
> rehearsal on this machine, also clear it: `rm -rf ~/.foundry/cache/rpc/4663`.

Libraries are deployed through the deterministic CREATE2 factory (`0x4e59b44847b379578588920cA78FbF26c0B4956C`,
present on 4663), so their addresses depend only on their bytecode, not on who deploys them, and they
change with every library byte. For this commit (S4 rehearsal, 2026-09-13): SeaportOrderLib
`0x6B617a0B578Ef6EDCD07774468f08b3778272D8A`, ValoremLib `0xd3CB94893EAb55e425cCd77Db98458b38D75Fa3d`
(the pre-redesign pair, SeaportOrderLib `0xAe4b…13f2` and ValoremLib `0xb1E1…1626`, is history). If
they already exist (anyone may deploy them first), forge reuses them; `Verify.s.sol` checks their code
byte for byte either way.

---

## Path A — bootstrap (the plan)

### A0. (Optional) Our own clearinghouse

The vault settles on whichever Valorem Clear it is constructed with. The default is Overcall's
unmodified instance; to remove that dependency entirely, deploy our own from the vendored upstream
artifact first and pass its address to every later step as `CLEARINGHOUSE` (Deploy's preflight and
Verify both read it):

```bash
DEPLOYER_PK=... CLEAR_FEE_TO=$ADMIN \
  forge script script/DeployClear.s.sol --rpc-url $RH_RPC --broadcast --slow --no-storage-caching
export CLEARINGHOUSE=0x...                   # from the "ValoremOptionsClearinghouse" log line
```

`feeTo` is the only power over a Clear instance (the 15 bps fee switch, the URI generator, sweeping
fees); with `CLEAR_FEE_TO=$ADMIN` it follows the vault's admin. The script asserts `feeBps() == 15`,
`feesEnabled() == false` and the wiring before it returns. The rehearsal runs path A on an instance
deployed this way and path B on Overcall's, so both choices are exercised.

### A1. Deploy

```bash
export DEPLOYER_PK=...                       # the bootstrap admin key
export ADMIN=$(cast wallet address --private-key $DEPLOYER_PK)
export SAFE_FEE=0x...                        # fee Safe
forge script script/Deploy.s.sol --rpc-url $RH_RPC --broadcast --slow --no-storage-caching --non-interactive \
  --verify --verifier sourcify --chain 4663
# if --verify was skipped or failed, per contract:
# forge verify-contract --verifier sourcify --chain 4663 $VAULT src/Vault.sol:Vault \
#   --libraries src/lib/SeaportOrderLib.sol:SeaportOrderLib:$SEAPORT_ORDER_LIB \
#   --libraries src/lib/ValoremLib.sol:ValoremLib:$VALOREM_LIB
# forge verify-contract --verifier sourcify --chain 4663 $SEAPORT_ORDER_LIB src/lib/SeaportOrderLib.sol:SeaportOrderLib
# forge verify-contract --verifier sourcify --chain 4663 $VALOREM_LIB src/lib/ValoremLib.sol:ValoremLib
```

`--non-interactive` is required: the Vault runtime (25,765 B) is above EIP-170's 24,576 B, and
forge's broadcast step stops at a confirmation prompt for such a contract even though
`foundry.toml` raises `code_size_limit` to chain 4663's real 98,304 B limit for the simulation. The
flag only suppresses that prompt; the chain accepts the contract (README "Four things that will bite
you", item 1).

The preflight refuses an asset without 18 decimals or a USDG without 6, a clearinghouse whose
`feeBps` is not 15 or whose fee switch is on (accept it explicitly after deploy instead), a Seaport
that is not 1.6 with the canonical ConduitController, and a feed with a non-positive answer or the
wrong decimals. There is no registry any more. The script prints a WARNING because the admin is a
plain key; that is expected on this path.

Record from `broadcast/Deploy.s.sol/4663/run-latest.json`: the vault address, both library addresses
(`.libraries[]`) and the deploy block.

### A2. Verify, bootstrap, unconfigured

```bash
export VAULT=0x... SEAPORT_ORDER_LIB=0x... VALOREM_LIB=0x...
export KEEPER=0x... GUARDIAN=0x... DEPLOYER=$ADMIN
ADMIN_PHASE=bootstrap EXPECT_KEEPER_CONFIGURED=false \
  forge script script/Verify.s.sol --rpc-url $RH_RPC --no-storage-caching
```

Every line `ok`, ending `VERIFY PASSED` (63 checks in the rehearsal). What it covers:

- chain id; vault and both libraries **byte for byte** against `out/`, with only link sites (each
  checked to hold the right library; how many there are is read from the artifact's `linkReferences`,
  8 at this commit, never hard-coded), immutables (each checked by value) and a library's own address
  word masked — this is what proves the compiled-in hard caps and all logic are this commit's;
- every immutable: asset, USDG, clearinghouse, Seaport, price feed, zero conduit key, **the zone is
  the vault itself**, the ERC-1155 approval target and the approval itself on Valorem, the Seaport
  1.6 zone interface advertised and EIP-1271 not; the dependencies: `seaport.information()` version
  1.6 and the canonical ConduitController, the Seaport runtime `extcodehash` equal to the vendored
  4663 runtime, Clear `feeBps == 15` with the switch off or accepted, token decimals;
- policy field by field, deposit cap 20 NVDA, price age 4 days, fee recipient, share name, symbol,
  decimals;
- roles for the phase; keeper, guardian and deployer distinct; role admins;
- the fee Safe when it is a contract (canonical singleton, threshold, owners, no modules, no guard,
  canonical fallback handler);
- fresh state: Idle, not halted, Valorem fee not accepted, no cycle, option, claim, listing or
  shares, nothing reserved, pending or accounted, epoch 1, no asset or USDG held.

### A3. Configure with the deployer key

```bash
ADMIN_PK=$DEPLOYER_PK forge script script/Configure.s.sol --rpc-url $RH_RPC --broadcast --slow --no-storage-caching
ADMIN_PHASE=bootstrap forge script script/Verify.s.sol --rpc-url $RH_RPC --no-storage-caching
```

`VERIFY PASSED` (69 checks in the rehearsal; exporting `SAFE_ADMIN` adds the Safe's own checks). The
vault is now operable: the keeper can arm a cycle.

### A4. Hand over to the Safe (when scheduled)

```bash
export SAFE_ADMIN=0x...
ADMIN_PK=$DEPLOYER_PK STEP=grant forge script script/HandoverAdmin.s.sol --rpc-url $RH_RPC --broadcast --slow --no-storage-caching
#   prints GRANT_NONCE and writes broadcast/handover-safe-smoke-batch.json
```

The grant refuses a `SAFE_ADMIN` that has no code, a threshold below 2, fewer owners than the threshold,
or any module enabled. Then prove the Safe can act: import `broadcast/handover-safe-smoke-batch.json` in
Safe{Wallet} → Transaction Builder (one call, `setMaxPriceAge` to its current value — it changes
nothing), decode it, sign with two owners, execute.

```bash
cast calldata-decode "setMaxPriceAge(uint32)" $(jq -r '.transactions[0].data' broadcast/handover-safe-smoke-batch.json)
ADMIN_PK=$DEPLOYER_PK STEP=renounce GRANT_NONCE=<from grant> \
  forge script script/HandoverAdmin.s.sol --rpc-url $RH_RPC --broadcast --slow --no-storage-caching
ADMIN_PHASE=safe forge script script/Verify.s.sol --rpc-url $RH_RPC --no-storage-caching
```

Renounce refuses until the Safe's nonce has moved past `GRANT_NONCE`, so the key is never dropped
before the Safe has executed a transaction as admin. After it, `VERIFY PASSED` in the safe phase
(72 checks in the rehearsal, with `EXPECT_SAFE_OWNER_SET` pinning the three owners): the Safe holds
admin, the deployer holds nothing. From here every admin action is a Safe transaction.

---

## Path B — Safe is admin from block one

```bash
DEPLOYER_PK=... SAFE_ADMIN=0x... SAFE_FEE=0x... \
  forge script script/Deploy.s.sol --rpc-url $RH_RPC --broadcast --slow --no-storage-caching --non-interactive \
  --verify --verifier sourcify --chain 4663
SAFE_ADMIN=0x... forge script script/Configure.s.sol --rpc-url $RH_RPC --no-storage-caching   # batch only
```

Decode every call of `broadcast/configure-safe-batch.json` before importing:

```bash
for d in $(jq -r '.transactions[].data' broadcast/configure-safe-batch.json); do
  cast calldata-decode "grantRole(bytes32,address)" $d
done
cast keccak KEEPER_ROLE; cast keccak GUARDIAN_ROLE           # must match the first word of each call
```

Import it in Safe{Wallet} → Transaction Builder (the app warns the batch has no checksum; that is
expected for a generated file and is why the decode is mandatory), sign, execute, then
`ADMIN_PHASE=safe forge script script/Verify.s.sol ...`.

---

## Hand over to the app

In leekzor/callhouse:

- `ops/addresses.json`: the vault, both libraries (add a `valoremLib` slot, it has none), both Safes,
  the guardian and keeper addresses, the deploy block, and which admin phase the vault is in.
- Point the `contracts/` submodule at the deployed tag; refresh `ops/abis/Vault.json` from
  `contracts/out/Vault.sol/Vault.json` and run `pnpm gen:abis` in `indexer/` and `web/`.
- Web: `NEXT_PUBLIC_VAULT`, `NEXT_PUBLIC_VAULT_FROM_BLOCK`, then **rebuild**. Indexer:
  `VAULT_ADDRESS`, `START_BLOCK`. Keeper: its environment and `KEEPER_PK` (runtime only).
- Before the first live week: one real 1-contract fill through the self-hosted page (the vault's
  listing is a restricted Seaport order with the vault as zone; Overcall's book does not list it, and
  there is no EIP-1271 to settle). The keeper creates the week's option type itself with
  `clear.newOptionType` (permissionless) and arms it with `rollOpen(optionId)`; the arm gate
  re-reads the tuple from the clearinghouse, so a wrong strike, lot, window or asset is refused
  before anything is listed.

---

## Rehearsal record — 2026-09-13 (S4, the redesigned contracts)

`script/rehearse-deploy.sh` against `anvil --fork-url https://rpc.mainnet.chain.robinhood.com
--chain-id 4663 --code-size-limit 98304`, fork block **62533535**, every forge call with
`--no-storage-caching`, the deploys with `--non-interactive`, on the tree committed as "harden:
invariants, sizes, scripts, fork tests" on branch `redesign/a2-own-strikes-2026-09-13`. **Passed.**

Setup: admin Safe `0x0fdf84096bd56eDa08632C6c9C90B88C2579c8BC` and fee Safe
`0x686d631f20F05fd017e320baA116B20a5245d8DF`, both 2 of 3, created through the canonical
SafeProxyFactory 1.4.1 on the fork. Preflight: feed answer `21472631815` (214.72631815 USD), feed age
15,679 s (4.4 h). The 30,000 B create probe (`cast call --rpc-url … --create 0x6175306000f3`) passed
on the anvil; a default anvil answers `EVM error CreateContractSizeLimit` to it and the live chain
returns the bytes, both checked by hand the same day.

| Step | Result |
|---|---|
| A0 DeployClear, `CLEAR_FEE_TO` = deployer | our ValoremOptionsClearinghouse at `0xA6Bb16048497Eb06b6314c37644A0B3Fe03a515A`, 16,110 B (the same runtime size as Overcall's `0x9a7b40e5…C0C0`); `feeTo` the deployer, `feesEnabled() == false`, `feeBps() == 15` re-read with `cast` |
| A1 deploy, `ADMIN` = deployer, `CLEARINGHOUSE` = our Clear | SeaportOrderLib `0x6B617a0B578Ef6EDCD07774468f08b3778272D8A` and ValoremLib `0xd3CB94893EAb55e425cCd77Db98458b38D75Fa3d` via CREATE2, Vault `0xf04ac66aeb14d235eb519ede1cec98602f5e3c09` (25,470 B, above EIP-170, accepted); 3 transactions, 8,355,876 gas; `clear()` re-read as our instance; plain-key WARNING printed; verify (bootstrap, unconfigured) **63 of 63** |
| A2 configure with the deployer key; verify | 2 calls; **69 of 69** |
| A3 Verify has teeth (1) | library addresses swapped: 5 FAIL (the 8 link sites, both libraries' deploy-address word and runtime) |
| A4 handover grant | Safe granted; renounce **refused**: "the Safe has not executed a transaction since the grant" |
| A5 smoke batch | executed through the admin Safe, 2 of 3 owners supplied out of address order |
| A6 renounce; verify, safe phase | deployer renounced; **72 of 72** with the owner set pinned; a configure signed by the renounced key refused: "ADMIN_PK does not hold DEFAULT_ADMIN_ROLE" |
| B1 deploy, `SAFE_ADMIN`, Overcall's Clear (the default); configure | Vault `0x69da14d9a33efa32e535c3ea0da9e341ff1b8cfa`, 1 transaction (libraries reused), 5,831,215 gas; `clear()` re-read as Overcall's; batch written, nothing broadcast; decoded independently to `grantRole(keccak("KEEPER_ROLE") = 0xfc8737ab…4fab, keeper)` and `grantRole(keccak("GUARDIAN_ROLE") = 0x55435dd2…5041, guardian)` |
| B2 the Safe executes that exact file; verify | 2 transactions; **71 of 71** |
| B3 executor on a non-anvil node | refused against the public RPC (simulation only): "ExecuteSafeBatch runs on an anvil node only" |
| B4 Verify has teeth (2) | one byte of vault code flipped with `anvil_setCode` (byte 100, 0xcb → 0xca): "vault: runtime == compiled Vault" FAIL |

Found while re-running it after the redesign: (1) the script's create probe had `--rpc-url` after
`--create`, which `cast` (1.3.5) rejects because `--create` is a subcommand, so the probe had never
run; (2) `forge script --broadcast` stops at an interactive EIP-170 confirmation for the 25,765 B
Vault whatever `code_size_limit` says, fatal on a non-terminal, hence `--non-interactive` in the
script and in the A1/B1 commands above. The earlier record (commit `6ed528f`, pre-redesign, fork
block 62212405, Verify 55/61/64/63) is superseded; its finding stands: without
`--no-storage-caching`, the tamper test passed because forge served the vault's code from its fork
cache for an unchanged block number, which is the reason for the warning above.

What this rehearsal does **not** prove:

- The Safe{Wallet} Transaction Builder UI importing these exact files (only the format and calldata
  were checked; the Safe contract executed the same calls).
- Hardware-wallet signing, or the Safe{Wallet} transaction service on 4663.
- Sourcify source verification (not run on a fork; Sourcify verifies against the live chain).
- Anything after configuration: the first `rollOpen`, a listing, a fill. The keeper dry run
  (`keeper/DRYRUN.md` in leekzor/callhouse) covers three full cycles on a separately deployed vault.
