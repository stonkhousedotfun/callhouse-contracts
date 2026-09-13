# Deploying the vault

The contract-side runbook for mainnet (chain 4663). Hosting the keeper, indexer and frontends is a
separate runbook, `ops/deploy.md` in leekzor/callhouse. Every step here is rehearsed end to end by
`script/rehearse-deploy.sh` on an anvil fork; the latest record is at the bottom.

**Nothing here is done yet.** The contracts are unaudited; do not run the mainnet steps before the
audit engagement has closed and the deployed commit is the audited tag.

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
| `script/Deploy.s.sol` | preflight against the live registry and feed, then libraries + vault. Warns loudly when the admin is a plain key |
| `script/Configure.s.sol` | grants `KEEPER_ROLE` and `GUARDIAN_ROLE`. With `ADMIN_PK` it broadcasts from that key (refuses a key without admin); without, it only writes a Safe Transaction Builder batch |
| `script/HandoverAdmin.s.sol` | `STEP=grant` gives the admin role to the Safe and writes a harmless smoke batch; `STEP=renounce` removes the key's admin role, and refuses until the Safe has executed a transaction after the grant |
| `script/Verify.s.sol` | read-only; about 55–64 checks depending on phase (below). Reverts if any fail |
| `script/rehearsal/ExecuteSafeBatch.s.sol` | rehearsal only: runs a batch file through a Safe with owner keys. Refuses any node that is not anvil |

---

## Before the day

| Item | Detail |
|---|---|
| Deployer key | an EOA kept offline. It is the vault admin until the handover. Fund it for about 7.6M gas (rehearsal: 7,569,702 for the two libraries and the vault) plus the configure and handover transactions |
| Admin Safe | 2 of 3, created in Safe{Wallet} on Robinhood Chain (supported; SafeL2 1.4.1 and SafeProxyFactory 1.4.1 are deployed at their canonical addresses). Owners on hardware. No modules, no guard. `ops/safes.md` §1 (leekzor/callhouse) |
| Fee Safe | receives the protocol fee (5% of premium). Its legal owner is a counsel question, `ops/launch-legal.md` §2 item 5 (leekzor/callhouse) |
| Guardian key | 1 of 1 on separate hardware, as `ops/safes.md` §3 (leekzor/callhouse) requires |
| Keeper key | hot EOA used by the keeper service; it can never move funds. `ops/safes.md` §2 (leekzor/callhouse) |
| RPC | `RH_RPC`, preferably an archive endpoint |
| Explorer verification | Blockscout for 4663 sits behind a Cloudflare challenge that `forge` fails; run `ops/bsproxy.js` (leekzor/callhouse) and point `--verifier-url` at it |
| Commit | the audited tag, checked out, `forge build` clean, unit + invariant and fork suites green on that exact commit. `Verify.s.sol` compares the chain against this checkout's `out/` |

Checks on the day, before broadcasting:

```bash
forge build --sizes                              # Vault under 24,576 B
cast call 0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0 "feesEnabled()(bool)" --rpc-url $RH_RPC
                                                 # false; if true, stop: the engine fee needs a governance decision
```

> **Warning.** Pass `--no-storage-caching` to every `forge script` in this runbook. Forge caches fork state under
> `~/.foundry/cache/rpc/4663/<block>`, and a rehearsal on an anvil fork mines blocks at real chain-4663
> heights, so a stale cache can hand a mainnet run fake rehearsal state. If you have ever run a
> rehearsal on this machine, also clear it: `rm -rf ~/.foundry/cache/rpc/4663`.

Libraries are deployed through the deterministic CREATE2 factory (`0x4e59b44847b379578588920cA78FbF26c0B4956C`,
present on 4663), so their addresses depend only on their bytecode, not on who deploys them. For this
commit: SeaportOrderLib `0xAe4ba02cd5Ace94DA3bbd68f746DafaA66d013f2`, ValoremLib
`0xb1E1aEF7cB829E0890e74eE324e6eEa437761626` (it changed with the 2026-09-13 lot-size fix). If they already exist (anyone may deploy them first), forge
reuses them; `Verify.s.sol` checks their code byte for byte either way.

---

## Path A — bootstrap (the plan)

### A1. Deploy

```bash
export DEPLOYER_PK=...                       # the bootstrap admin key
export ADMIN=$(cast wallet address --private-key $DEPLOYER_PK)
export SAFE_FEE=0x...                        # fee Safe
forge script script/Deploy.s.sol --rpc-url $RH_RPC --broadcast --slow --no-storage-caching \
  --verify --verifier blockscout --verifier-url http://127.0.0.1:<bsproxy-port>/api
```

The preflight refuses a registry whose collateral, exercise token or clearinghouse do not match
NVDA / USDG / Valorem, a lot size other than 1e18, and a feed with a non-positive answer or the wrong
decimals. The script prints a WARNING because the admin is a plain key; that is expected on this path.

Record from `broadcast/Deploy.s.sol/4663/run-latest.json`: the vault address, both library addresses
(`.libraries[]`) and the deploy block.

### A2. Verify, bootstrap, unconfigured

```bash
export VAULT=0x... SEAPORT_ORDER_LIB=0x... VALOREM_LIB=0x...
export KEEPER=0x... GUARDIAN=0x... DEPLOYER=$ADMIN
ADMIN_PHASE=bootstrap EXPECT_KEEPER_CONFIGURED=false \
  forge script script/Verify.s.sol --rpc-url $RH_RPC --no-storage-caching
```

Every line `ok`, ending `VERIFY PASSED` (55 checks in the rehearsal). What it covers:

- chain id; vault and both libraries **byte for byte** against `out/`, with only link sites (each
  checked to hold the right library), immutables (each checked by value) and a library's own address
  word masked — this is what proves the compiled-in hard caps and all logic are this commit's;
- every immutable: asset, USDG, clearinghouse, Seaport, the NVDA registry (not JUGGERNAUT), price
  feed, Overcall fee recipient, zero conduit key, zero zone, the ERC-1155 approval target and the
  approval itself on Valorem;
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

`VERIFY PASSED` (61 checks with `SAFE_ADMIN` exported, which adds the Safe's own checks). The vault is
now operable: the keeper can open a cycle.

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
(64 checks in the rehearsal, with `EXPECT_SAFE_OWNER_SET` pinning the three owners): the Safe holds
admin, the deployer holds nothing. From here every admin action is a Safe transaction.

---

## Path B — Safe is admin from block one

```bash
DEPLOYER_PK=... SAFE_ADMIN=0x... SAFE_FEE=0x... \
  forge script script/Deploy.s.sol --rpc-url $RH_RPC --broadcast --slow --no-storage-caching --verify ...
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
- Before the first live week: one real 1-contract Overcall listing (L-04) to settle EIP-1271 against
  Overcall's production validator.

---

## Rehearsal record — 2026-09-13

`script/rehearse-deploy.sh` against `anvil --fork-url https://rpc.mainnet.chain.robinhood.com
--chain-id 4663`, fork block **62212405**, every forge call with `--no-storage-caching`, on commit `6ed528f` (after the lot-size and queue-fairness fixes). **Passed.**

Setup: admin Safe `0x40B2B8fAf07563A99203b55377ed2c9148a30468` and fee Safe
`0x2e91b07AB8c64CF2e0Bb3593945818fEF387BC05`, both 2 of 3, created through the canonical SafeProxyFactory
1.4.1 on the fork. Preflight: registry cycle 1, feed answer `21829793457` (218.29793457 USD), feed age
171,469 s (47.6 h, a weekend gap, inside the 4-day window).

| Step | Result |
|---|---|
| A1 deploy, `ADMIN` = deployer | SeaportOrderLib `0xAe4ba02cd5Ace94DA3bbd68f746DafaA66d013f2` and ValoremLib `0xb1E1aEF7cB829E0890e74eE324e6eEa437761626` via CREATE2, Vault `0x1ACF2372B7F66968Ca894A62E7F3Ec05e67Ce1e8`; 3 transactions, 7,569,702 gas; plain-key WARNING printed |
| A2 verify, bootstrap, unconfigured | 55 of 55 |
| A3 configure with the deployer key; verify | 2 calls; 61 of 61 |
| Verify has teeth (1) | library addresses swapped: 3 FAIL (link sites, both library bytecodes) |
| A4 handover grant | Safe granted; renounce **refused**: "the Safe has not executed a transaction since the grant" |
| A5 smoke batch | executed through the admin Safe, 2 of 3 owners supplied out of address order |
| A6 renounce; verify, safe phase | deployer renounced; 64 of 64 with the owner set pinned; a configure signed by the renounced key refused: "ADMIN_PK does not hold DEFAULT_ADMIN_ROLE" |
| B1 deploy, `SAFE_ADMIN`; configure | Vault `0x69da14d9a33efa32e535c3ea0da9e341ff1b8cfa`, 1 transaction (libraries reused), 5,445,268 gas; batch written, nothing broadcast; decoded independently to `grantRole(keccak("KEEPER_ROLE") = 0xfc8737ab…4fab, keeper)` and `grantRole(keccak("GUARDIAN_ROLE") = 0x55435dd2…5041, guardian)` |
| B2 the Safe executes that exact file; verify | 2 transactions; 63 of 63 |
| B3 executor on a non-anvil node | refused against the public RPC (simulation only): "ExecuteSafeBatch runs on an anvil node only" |
| Verify has teeth (2) | one byte of vault code flipped with `anvil_setCode` (byte 100, 0xab → 0xaa): "vault: runtime == compiled Vault" FAIL |

Found while building it: without `--no-storage-caching`, the tamper test passed, because forge served
the vault's code from its fork cache for an unchanged block number. That is the reason for the warning
above, and the chain-4663 cache on the rehearsal machine was cleared.

What this rehearsal does **not** prove:

- The Safe{Wallet} Transaction Builder UI importing these exact files (only the format and calldata
  were checked; the Safe contract executed the same calls).
- Hardware-wallet signing, or the Safe{Wallet} transaction service on 4663.
- Blockscout source verification through `ops/bsproxy.js` (not run on a fork).
- Anything after configuration: the first `rollOpen`, a listing, a fill. The keeper dry run
  (`keeper/DRYRUN.md` in leekzor/callhouse) covers three full cycles on a separately deployed vault.
