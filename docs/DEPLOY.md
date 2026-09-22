# Deploying the vault

The contract-side runbook for mainnet (chain 4663). Hosting the keeper, indexer and frontends is a
separate runbook, `ops/deploy.md` in stonkhousedotfun/callhouse. Every step here is rehearsed end to end by
`script/rehearse-deploy.sh` on an anvil fork; the latest record is at the bottom.

**The live vault was deployed on 2026-09-15 on path A** (our own Clear from A0, a bootstrap admin,
keeper and guardian granted); the handover (A4) has not been done. "Live deployment" below records
what is on chain. The contracts are unaudited and stay labelled so (owner decision D14: no external
audit; the gate is the test suite, README "CI, and why the local gate is the gate"). Do not run the
mainnet steps on a commit that has not passed the full gate, fork suite and rehearsal included, or
that differs from the commit `Verify.s.sol` will be run from.

## Live deployment (chain 4663, read 2026-09-15)

| What | On chain |
|---|---|
| Vault | `0x88a98931E3682137E7e4D3426f623247f4A4ecbb`, block 63,467,882 (2026-09-15 07:06 UTC), tx `0x40ed4448…91f2842`, 25,775 B runtime. `name()` "Callhouse NVDA", `symbol()` `cNVDA`, set before the rename |
| SeaportOrderLib | `0x6B617a0B578Ef6EDCD07774468f08b3778272D8A` (CREATE2 factory, block 63,467,831) |
| ValoremLib | `0xd3CB94893EAb55e425cCd77Db98458b38D75Fa3d` (CREATE2 factory, block 63,467,856) |
| Clearinghouse (A0) | our own `0x53d7A6d0489Daf3d67b9A314e0eAB2B78Acab9C6`, block 63,467,465, runtime equal to `script/artifacts/ValoremOptionsClearinghouse.json`; `feesEnabled()` false, `feeBps()` 15 |
| Clear `feeTo` | Safe `0xff1454009F024507f3E455eb2027E98fAF4ccF61`, Safe 1.4.1, **1 of 1** (owner `0x7A3a8C3F6331f63107D5b3aEeA0515e799022C32`), no modules, no guard, nonce 0; no `setFeeTo` pending |
| `DEFAULT_ADMIN_ROLE` | EOA `0xEb82c3D0F89d47453F94f0C2b2a2752e27a19d9b` (the deployer), alone, no timelock |
| `KEEPER_ROLE` | EOA `0x06c131cfEd73A56893f5eB52D17252856FAFC1d2` |
| `GUARDIAN_ROLE` | EOA `0x29741A8d283a253E8Ce10aDfd04C6507438b6F39` (no transaction sent yet) |
| `feeRecipient()` | the admin EOA `0xEb82…9d9b` |
| `policy()` | `minOtmBps` 300, `maxOtmBps` 1200, **`minPremiumBps` 10**, `maxUtilizationBps` 9500, `protocolFeeBps` 500, `maxContractsCap` 50. `minPremiumBps` was lowered from `launchDefaults()`' 40 by `setPolicy` (tx `0x97b7e529…8dc37b`); the admin can change any field inside the compiled bounds, immediately |
| Other parameters | `depositCap()` 20 NVDA, `maxPriceAge()` 345,600 s (4 days), `valoremFeeAccepted()` false, `writesHalted()` false |
| Source verification | vault and both libraries: Sourcify `match` (partial, not `exact_match`). Blockscout: the vault partially verified, no source for the libraries. Our Clear: not source-verified on Sourcify or Blockscout; its runtime equals Overcall's Sourcify-`exact_match` Clear `0x9a7b…C0C0` except the CBOR metadata hash |

Where the live deployment departs from the plan in this runbook:

- The handover (A4) has not been done, and deposits are open (cap 20 NVDA) under the one-key admin
  in the warning below. That key is a hot EOA, and it also receives the protocol fee.
- The fee recipient is the admin EOA, not a fee Safe.
- Our Clear's `feeTo` is a 1-of-1 Safe, not the 2-of-3 admin Safe of the 2026-09-14 owner decision
  in A0.
- The admin, keeper and guardian keys are derived from one mnemonic; the guardian is not a separate
  hardware key.
- This file records no `Verify.s.sol` run against the live deployment, and the script cannot pass
  against it as written: `_parameters` requires `policy.minPremiumBps == 40` from
  `Policy.launchDefaults()` with no override (live is 10), `_freshState` runs unless
  `EXPECT_FRESH=false` and requires phase Idle, cycle 0 and no shares (live: Listed, cycle 1,
  1.06e18 shares), and `feeRecipient` and `depositCap` must be passed as `SAFE_FEE` (the admin EOA)
  and `DEPOSIT_CAP`. So the A4 `VERIFY PASSED` step cannot pass on the live vault unless the
  script or the live policy changes.
- The planned 1-contract fill before the first live week (see "Hand over to the app") was not done:
  cycle 1 was armed and listed without it, and as of 2026-09-15 no fill has happened.

---

## The plan: bootstrap admin now, Safe later

`Deploy.s.sol` gives `DEFAULT_ADMIN_ROLE` to exactly one address at construction: `ADMIN` if set,
otherwise `SAFE_ADMIN`. **The live vault used `ADMIN` = the deployer's own address**
("bootstrap"). The deployer key then configures the vault directly, and the admin role can move to
a Safe later with `script/HandoverAdmin.s.sol` (planned, not done).

> **Warning.** Until the handover completes, whoever holds the deployer key holds every vault admin
> power: setting the protocol fee up to its 20%-of-premium ceiling and its recipient, the deposit
> cap, the policy inside its hard caps, the price age, unhalting, accepting the Valorem engine fee,
> and granting or revoking every role (including granting itself `KEEPER_ROLE`). It does **not**
> hold Clear's `feeTo` (on the live deployment that is the 1-of-1 Safe `0xff14…CF61`). Use that key
> only for admin steps.

The alternative, still supported and rehearsed: pass `SAFE_ADMIN` and no `ADMIN`, so the Safe is
admin from block one and every admin action is a Safe transaction (path B below).

| Script | What it does |
|---|---|
| `script/Deploy.s.sol` | preflight (asset 18 / USDG 6 decimals, Clear `feeBps == 15` and switch off and ERC-1155, Seaport 1.6 with the canonical ConduitController, feed answer and 8 decimals), then libraries + vault. The constructor takes one `Vault.Config` struct (asset, USDG, clearinghouse, Seaport, price feed, `maxPriceAge`, conduit key, admin, fee recipient, deposit cap, name, symbol): there is no registry and no zone parameter, the zone is the vault itself and is derived. Warns loudly when the admin is a plain key |
| `script/DeployClear.s.sol` | OPTIONAL: deploys our own ValoremOptionsClearinghouse from the vendored upstream artifact (`feeTo` = the admin Safe; owner decision 2026-09-14, `HandoverAdmin` never moves it) and asserts `feeBps() == 15`, `feesEnabled() == false`; pass its address to Deploy as `CLEARINGHOUSE` |
| `script/Configure.s.sol` | grants `KEEPER_ROLE` and `GUARDIAN_ROLE`. With `ADMIN_PK` it broadcasts from that key (refuses a key without admin); without, it only writes a Safe Transaction Builder batch |
| `script/HandoverAdmin.s.sol` | `STEP=grant` gives the admin role to the Safe and writes a harmless smoke batch; `STEP=renounce` removes the key's admin role, and refuses until the Safe has executed a transaction after the grant |
| `script/Verify.s.sol` | read-only. Path A (our Clear): **67** bootstrap-unconfigured, **73** bootstrap-configured, **76** safe phase with the owner set pinned (four extra fee-switch-holder checks: `EXPECTED_CLEAR_FEE_TO` required, runtime pin, `feeTo`, `pendingFeeTo` empty). Path B (Overcall): **71**. Reverts if any fail. Env table below A2 |
| `script/rehearsal/ExecuteSafeBatch.s.sol` | rehearsal only: runs a batch file through a Safe with owner keys. Refuses any node that is not anvil |

---

## Before the day

| Item | Detail |
|---|---|
| Deployer key | an EOA kept offline. It is the vault admin until the handover. Fund it for about 8.4M gas (rehearsal 2026-09-13: 8,355,876 for the two libraries and the vault; 5,831,215 when the libraries already exist) plus the configure and handover transactions, and about 3.5M more if `DeployClear.s.sol` is used |
| Admin Safe | 2 of 3, created in Safe{Wallet} on Robinhood Chain (supported; SafeL2 1.4.1 and SafeProxyFactory 1.4.1 are deployed at their canonical addresses). Owners on hardware. No modules, no guard. `ops/safes.md` §1 (stonkhousedotfun/callhouse) |
| Fee Safe | receives the protocol fee (5% of premium). Its legal owner is a counsel question, `ops/launch-legal.md` §2 item 5 (stonkhousedotfun/callhouse) |
| Guardian key | 1 of 1 on separate hardware, as `ops/safes.md` §3 (stonkhousedotfun/callhouse) requires |
| Keeper key | hot EOA used by the keeper service; it can never move funds. `ops/safes.md` §2 (stonkhousedotfun/callhouse) |
| RPC | `RH_RPC`, preferably an archive endpoint |
| Source verification | **Sourcify** (`--verifier sourcify --chain 4663`), which supports 4663 and holds exact matches for the third-party contracts already; Blockscout then imports the match with one click ("Verify & publish → via Sourcify"). Blockscout's own API sits behind a Cloudflare challenge that `forge` cannot pass, so do not use `--verifier blockscout` against it. Verify the vault AND both libraries |
| Cycle timing (keeper) | the vault reads exercise and expiry from the option type and never the wall clock. The weekly type's exercise opens at the US close, **Friday 16:00 ET = 20:00 UTC while US daylight saving is in effect, 21:00 UTC otherwise** (DST ends 2026-11-01), or Thursday's close when Friday is a full-day NYSE holiday, and it expires 24 hours later (`expiryTs = exerciseTs + 86400`, Saturday); the arm gate accepts any window from 1 hour + 1 day out to 21 days, so both fit |
| Commit | the release tag, checked out, `forge build` clean, unit + invariant and fork suites and the rehearsal green on that exact commit. `Verify.s.sol` compares the chain against this checkout's `out/` |

Checks on the day, before broadcasting:

```bash
forge build --sizes                              # Vault under 98,304 B (chain 4663's limit; forge's 24,576 B
                                                 # "margin" line and exit 1 are noise here, README item 1)
cast call ${CLEARINGHOUSE:-0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0} "feesEnabled()(bool)" --rpc-url $RH_RPC
                                                 # the vault's Clear: on path A run it after A0 with $CLEARINGHOUSE
                                                 # set (the live vault's is 0x53d7…C6; DeployClear also asserts
                                                 # false); unset, it reads Overcall's Clear (path B)
                                                 # false; if true, stop: the engine fee needs a governance decision
```

> **Warning.** Pass `--no-storage-caching` to every `forge script` in this runbook. Forge caches fork state under
> `~/.foundry/cache/rpc/4663/<block>`, and a rehearsal on an anvil fork mines blocks at real chain-4663
> heights, so a stale cache can hand a mainnet run fake rehearsal state. If you have ever run a
> rehearsal on this machine, also clear it: `rm -rf ~/.foundry/cache/rpc/4663`.

Libraries are deployed through the deterministic CREATE2 factory
(`0x4e59b44847b379578588920cA78FbF26c0B4956C`, present on 4663), so their addresses depend only on
their bytecode, not on who deploys them, and they change with every library byte. For this commit
(S4 rehearsal, 2026-09-13, and the live deployment): SeaportOrderLib
`0x6B617a0B578Ef6EDCD07774468f08b3778272D8A`, ValoremLib
`0xd3CB94893EAb55e425cCd77Db98458b38D75Fa3d` (the pre-redesign pair, SeaportOrderLib `0xAe4b…13f2`
and ValoremLib `0xb1E1…1626`, is history). If they already exist (anyone may deploy them first),
forge reuses them; `Verify.s.sol` checks their code byte for byte either way.

---

## Path A — bootstrap (the plan)

### A0. (Optional) Our own clearinghouse

The vault settles on whichever Valorem Clear it is constructed with. The default is Overcall's
unmodified instance; to remove that dependency entirely, deploy our own from the vendored upstream
artifact first and pass its address to every later step as `CLEARINGHOUSE` (Deploy's preflight and
Verify both read it). **Owner decision 2026-09-14: `CLEAR_FEE_TO` is the admin Safe, not the
bootstrap deployer.** `HandoverAdmin.s.sol` moves only the vault's `DEFAULT_ADMIN_ROLE`; it never
moves Clear's `feeTo`.

```bash
export SAFE_ADMIN=0x...                      # admin Safe; holds Clear's fee switch from deploy
DEPLOYER_PK=... CLEAR_FEE_TO=$SAFE_ADMIN \
  forge script script/DeployClear.s.sol --rpc-url $RH_RPC --broadcast --slow --no-storage-caching
export CLEARINGHOUSE=0x...                   # from the "ValoremOptionsClearinghouse" log line
cast call $CLEARINGHOUSE "feeTo()(address)" --rpc-url $RH_RPC
# must equal $SAFE_ADMIN before Deploy.s.sol
```

`feeTo` is the only power over a Clear instance (the 15 bps fee switch, the URI generator, sweeping
fees). The script asserts `feeBps() == 15`, `feesEnabled() == false` and the wiring before it
returns. The rehearsal runs path A on an instance deployed this way (`EXPECTED_CLEAR_FEE_TO` on
every path-A Verify) and path B on Overcall's, so both choices are exercised.

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

`--non-interactive` is required: the Vault runtime (25,775 B) is above EIP-170's 24,576 B, and
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
export EXPECTED_CLEAR_FEE_TO=$SAFE_ADMIN     # required on our own Clear; omit on Overcall's
ADMIN_PHASE=bootstrap EXPECT_KEEPER_CONFIGURED=false \
  forge script script/Verify.s.sol --rpc-url $RH_RPC --no-storage-caching
```

Every line `ok`, ending `VERIFY PASSED` (67 checks on path A). What it covers:

Verify env (in addition to the address overrides Deploy.s.sol already documents):

| Env | Required when | What it pins |
|---|---|---|
| `EXPECTED_CLEAR_FEE_TO` | the vault's `clear()` is not Overcall's `0x9a7b40e5…C0C0` | that address holds our Clear's fee switch (`feeTo()`), no `setFeeTo` nomination is pending (`pendingFeeTo` slot 3 is zero), and the runtime matches the vendored artifact. Missing the env is a FAIL. On Overcall's instance the check is skipped |

- chain id; vault and both libraries **byte for byte** against `out/`, with only link sites (each
  checked to hold the right library; how many there are is read from the artifact's `linkReferences`,
  8 at this commit, never hard-coded), immutables (each checked by value) and a library's own address
  word masked — this is what proves the compiled-in hard caps and all logic are this commit's;
- every immutable: asset, USDG, clearinghouse, Seaport, price feed, zero conduit key, **the zone is
  the vault itself**, the ERC-1155 approval target and the approval itself on Valorem, the Seaport
  1.6 zone interface advertised and EIP-1271 not; the dependencies: `seaport.information()` version
  1.6 and the canonical ConduitController, the Seaport runtime `extcodehash` equal to the vendored
  4663 runtime, Clear `feeBps == 15` with the switch off or accepted, token decimals; on our own
  Clear, `EXPECTED_CLEAR_FEE_TO` (the admin Safe) holds `feeTo` with nothing pending;
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
ADMIN_PHASE=bootstrap EXPECTED_CLEAR_FEE_TO=$SAFE_ADMIN \
  forge script script/Verify.s.sol --rpc-url $RH_RPC --no-storage-caching
```

`VERIFY PASSED` (73 checks on path A; exporting `SAFE_ADMIN` adds the Safe's own checks). The vault
is now operable: the keeper can arm a cycle.

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
ADMIN_PHASE=safe EXPECTED_CLEAR_FEE_TO=$SAFE_ADMIN \
  forge script script/Verify.s.sol --rpc-url $RH_RPC --no-storage-caching
```

Renounce refuses until the Safe's nonce has moved past `GRANT_NONCE`, so the key is never dropped
before the Safe has executed a transaction as admin. After it, `VERIFY PASSED` in the safe phase
(on the live vault only once `Verify.s.sol` accepts the live policy; see "Live deployment") (76
checks on path A, with `EXPECT_SAFE_OWNER_SET` pinning the three owners): the Safe holds admin,
the deployer holds nothing, and Clear's `feeTo` is still the Safe (it never moved). From here every
admin action is a Safe transaction.

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

In stonkhousedotfun/callhouse:

- `ops/addresses.json`: the vault, both libraries (add a `valoremLib` slot, it has none), both Safes,
  the guardian and keeper addresses, the deploy block, and which admin phase the vault is in.
- Point the `contracts/` submodule at the deployed tag; refresh `ops/abis/Vault.json` from
  `contracts/out/Vault.sol/Vault.json` and run `pnpm gen:abis` in `indexer/` and `web/`.
- Web: `NEXT_PUBLIC_VAULT`, `NEXT_PUBLIC_VAULT_FROM_BLOCK`, then **rebuild**. Indexer:
  `VAULT_ADDRESS`, `START_BLOCK`. Keeper: its environment and `KEEPER_PK` (runtime only).
- Planned before the first live week, and not done: one real 1-contract fill through the app's cycle page,
  `app.stonkhouse.fun/vault/nvda/cycle` (the vault's listing is a restricted Seaport order with the
  vault as zone; Overcall's book does not list it, and there is no EIP-1271 to settle). Cycle 1 was armed and listed
  without it, and as of 2026-09-15 no fill has happened on the live vault. The keeper creates the week's option type
  itself with `clear.newOptionType` (permissionless) and arms it with `rollOpen(optionId)`; the arm
  gate re-reads the tuple from the clearinghouse, so a wrong strike, lot, window or asset is refused
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
run; (2) `forge script --broadcast` stops at an interactive EIP-170 confirmation for the 25,470 B
Vault whatever `code_size_limit` says, fatal on a non-terminal, hence `--non-interactive` in the
script and in the A1/B1 commands above. The earlier record (commit `6ed528f`, pre-redesign, fork
block 62212405, Verify 55/61/64/63) is superseded; its finding stands: without
`--no-storage-caching`, the tamper test passed because forge served the vault's code from its fork
cache for an unchanged block number, which is the reason for the warning above.

## Rehearsal record — 2026-09-14 (feeTo = admin Safe)

`script/rehearse-deploy.sh` on `anvil --fork-url https://rpc.mainnet.chain.robinhood.com --chain-id
4663 --port 8555 --code-size-limit 98304`, fork block **63380078**, every forge call with
`--no-storage-caching`, on `redesign/a2-own-strikes-2026-09-13` after L-01 (`bec4dbd`) plus this
script-only change. **Passed.** `src/` and the Vault ABI were byte-identical to `bec4dbd`.

| Step | Result |
|---|---|
| A0 DeployClear, `CLEAR_FEE_TO` = admin Safe | our Clear `0xA6Bb16048497Eb06b6314c37644A0B3Fe03a515A`, 16,110 B; `feeTo()` the admin Safe `0x6DA2…0fE11`; `feesEnabled() == false`, `feeBps() == 15` |
| A1 deploy against our Clear; Verify | Vault `0xf04a…3c09` (25,775 B); preflight `clear feeTo` the Safe; **67 of 67** |
| A1b Verify teeth on the fee switch | missing `EXPECTED_CLEAR_FEE_TO` FAIL; pending `setFeeTo(deployer)` FAIL; deployer `acceptFeeTo` + `setFeesEnabled(true)` FAIL on holder (and on the fee-on check); Safe `acceptFeeTo` restores, deployer's `setFeesEnabled` reverts; **67 of 67** |
| A2 configure; Verify | **73 of 73** |
| A3 swapped libraries | 5 FAIL (link sites, both libraries' deploy-address word and runtime) |
| A4–A6 handover | renounce refused until the smoke batch; then **76 of 76**; a renounced-key configure refused |
| B2 Overcall's Clear, Safe from block one | **71 of 71** (no `EXPECTED_CLEAR_FEE_TO`; Overcall's `feeTo` is unchanged) |
| B3–B4 | executor refuses a non-anvil node; one flipped vault byte FAIL |

The 2026-09-13 record above is the redesigned-contracts rehearsal; its A0 still deployed `feeTo` =
the deployer, which this run closes.

What this rehearsal does **not** prove:

- The Safe{Wallet} Transaction Builder UI importing these exact files (only the format and calldata
  were checked; the Safe contract executed the same calls).
- Hardware-wallet signing, or the Safe{Wallet} transaction service on 4663.
- Sourcify source verification (not run on a fork; Sourcify verifies against the live chain).
- Anything after configuration: the first `rollOpen`, a listing, a fill. The keeper dry run
  (`keeper/DRYRUN.md` in stonkhousedotfun/callhouse) covers three full cycles on a separately deployed vault.

---

## Solo factory markets (Tier 1)

The live product is one `AccountFactory` per market (`src/solo/`; the pooled Vault above is closed and
is never redeployed). Every market's inputs come from the registry, `ops/markets/tier1.json` in
stonkhousedotfun/callhouse (read `ops/markets/README.md` there first): `asset`, `feed`, `depositCap`,
`ticker`, `deployment.keeper`, `deployment.guardian`, `deployment.admin`, `deployment.feeRecipient`.
`script/DeploySoloBatch.sh` drives the three scripts below for a set of markets and writes
`deployment.factory`, `implementation`, `deployBlock`, `deployTx`, `sourcify` and `configuredAt` back;
it writes nothing else in the registry (`status` and `wave` stay hand-maintained). The live NVDA
factory `0xc4A5Cd0DE91CaB7F5Ebe2114bc63Fbb43E642BBb` was verified against this checkout's build on
2026-09-16 (below); it is not touched by any of this.

| Script | What it does |
|---|---|
| `script/DeploySolo.s.sol` | preflight (below), then `new AccountFactory(...)`, whose constructor deploys and locks the `WriterAccount` implementation. `ValoremLib` (linked by `WriterAccount`, 4 call sites) is deployed through the CREATE2 factory if absent; on 4663 it already exists at `0xd3CB94893EAb55e425cCd77Db98458b38D75Fa3d`, so a market deploy is ONE transaction (4,766,283 gas on the fork; 4,766,595 for the live NVDA factory) |
| `script/ConfigureSolo.s.sol` | grants `KEEPER_ROLE` and `GUARDIAN_ROLE`; optionally `setDepositCap` / `setPolicy`. Idempotent: a grant already held is skipped ("already granted"), the cap only when `DEPOSIT_CAP` is set and differs, a policy only when `SET_POLICY=true` and it differs. With `ADMIN_PK` it broadcasts from that key (refuses a key without `DEFAULT_ADMIN_ROLE`); without, it only writes a Safe Transaction Builder batch. Refuses keeper == guardian, or either == the admin |
| `script/VerifySolo.s.sol` | read-only. **60** checks on a fresh, configured factory (**56** with `EXPECT_FRESH=false`, e.g. the live NVDA market): chain id; factory runtime against `out/AccountFactory.sol/AccountFactory.json` with immutable slots masked; implementation runtime against `out/Account.sol/WriterAccount.json` with immutables and the 4 `ValoremLib` link sites masked (each checked to hold `VALOREM_LIB`, the count read from the artifact); `ValoremLib` runtime and self-address word; every immutable on both by value, the implementation locked with no owner; the asset's symbol, decimals, `uiMultiplier()`, `oraclePaused()`; USDG decimals; the feed's description, decimals, live answer, age within `maxPriceAge`; Seaport 1.6; Clear `feeBps`, switch, ERC-1155; policy field by field, cap, price age, fee recipient, not halted, fee not accepted; roles (admin, keeper exactly `KEEPER_ROLE`, guardian exactly `GUARDIAN_ROLE`, three distinct, role admins); fresh state (no week, no account, nothing pending or live). Reverts if any fail |
| `script/lib/BytecodeCheck.sol` | the masking helpers, copied from `Verify.s.sol` (which is unchanged so its recorded counts stay exact) and generalised to one linked library |
| `script/DeploySoloBatch.sh` | Deploy → Configure → Verify → write-back per market, from the registry (flags below). `set -euo pipefail`: a piped `forge script` once hid a failure here |
| `script/rehearse-solo.sh` | starts an anvil fork (`--code-size-limit 98304`), runs the batch with `--rehearse`, checks the real registry's sha256 is unchanged, flips one byte of a factory (`anvil_setCode`) and shows VerifySolo FAIL, kills the anvil on exit |

### `DeploySolo.s.sol` preflight and environment

Every default is the live NVDA market, so `DEPLOYER_PK=... ADMIN=... SAFE_FEE=... forge script
script/DeploySolo.s.sol ...` still deploys NVDA exactly as before; the batch exports the rest per
market. The preflight prints one `ok` line per check and reverts, before anything is broadcast, with
a message naming the value read and the value expected:

| Env | Default | Preflight |
|---|---|---|
| `DEPLOYER_PK` | required | pays for the deploy; holds no role afterwards |
| `ADMIN` (else `SAFE_ADMIN`) | required | `DEFAULT_ADMIN_ROLE` at construction; a WARNING is printed when it is a plain key |
| `SAFE_FEE` | required | `feeRecipient()`: the protocol-fee consideration item of every lot order |
| `ASSET` | NVDA `0xd060…9EEC` | `symbol() == EXPECTED_TICKER` (a fat-fingered address reverts `asset symbol mismatch: ASSET 0x… is "AAPL", EXPECTED_TICKER is "TSLA"`); `decimals() == 18`; `uiMultiplier()` answers by staticcall and is > 0; `oraclePaused()` answers and is false (both probed the way `ValoremLib` does: a token without them is not a Stock Token) |
| `PRICE_FEED` | NVDA/USD `0x379E…9F15` | `description()` contains `EXPECTED_TICKER` (`"RHTSLA / USD"`, `"Robinhood GME / USD"`; a wrong feed reverts `feed description mismatch: PRICE_FEED 0x… is "…", EXPECTED_TICKER is "…"`); `decimals() == 8`; `roundId != 0`; `answer > 0`; `updatedAt` within `MAX_PRICE_AGE` (4 days) of `block.timestamp`, the bound the factory applies to every write |
| `EXPECTED_TICKER` | `NVDA` | the two checks above. An empty value matches nothing |
| `DEPOSIT_CAP` | `20e18` | must be > 0 (per-account cap, asset base units; the registry's `depositCap`) |
| `USDG` | `0x5fc5…d168` | `decimals() == 6` |
| `CLEARINGHOUSE` | our Clear `0x53d7…b9C6` | `feeBps() == 15`, fee switch off, ERC-1155 |
| `SEAPORT` | `0x0000…B395` | `information()` version `1.6` and the canonical ConduitController `0x00000000F9490004C11Cef243f5400493c00Ad63` |
| `PREFLIGHT_SKIP_CONDUIT_CONTROLLER` | `false` | TEST ONLY: `MockSeaport.information()` answers a zero controller, so the unit test skips that one line (and shows it is on by default). The batch never sets it; a WARN line is printed when it is on |

`test/unit/DeploySoloPreflight.t.sol` drives the script through `vm.setEnv` + `run()` against the
mocks (`MockStockToken` "TSLA", `MockFeed` 8 dp "Robinhood TSLA / USD", `MockClear`, `MockSeaport`):
the happy path returns a factory whose immutables, cap, fee recipient, admin, locked implementation
and policy match, and each refusal (symbol, description, feed decimals, stale feed, answer ≤ 0,
oracle paused, cap 0, token decimals, not a Stock Token, Clear fee on, wrong conduit controller,
empty ticker) reverts with its message. The cases run in ONE test function, in order: `vm.setEnv`
writes the process environment that forge's parallel test threads share, so separate functions
would race for `ASSET`. `ConfigureSolo.t.sol` (8 tests) drives `runWith(Inputs)`, the script's
explicit-input entry, for the same reason.

### `ConfigureSolo.s.sol` environment

| Env | What |
|---|---|
| `FACTORY`, `KEEPER`, `GUARDIAN` | required. The registry row's `deployment.keeper` (one hot key per market, `keeperKeyIndex`) and `deployment.guardian` |
| `ADMIN_PK` | key-admin mode. Without it: batch only, nothing broadcast |
| `DEPOSIT_CAP` | optional; `setDepositCap` only when set and ≠ `depositCap()` (the batch passes the registry cap, which the constructor already set, so it is skipped) |
| `SET_POLICY` + `MIN_OTM_BPS`, `MAX_OTM_BPS`, `MIN_PREMIUM_BPS`, `MAX_UTILIZATION_BPS`, `PROTOCOL_FEE_BPS`, `MAX_CONTRACTS_CAP` | optional, as `Configure.s.sol`; applied only when it differs from `policy()` |
| `SAFE_ADMIN`, `SAFE_BATCH_OUT` | the Safe named in the batch file; where it goes (default `broadcast/configure-solo-safe-batch.json`; the batch writes `broadcast/solo-batch/<utc>/<TICKER>-configure-safe-batch.json`) |

After a key-admin broadcast the script re-reads `hasRole` for both and `depositCap()` and prints
them ("post-check"); `VerifySolo.s.sol` against the chain is still the gate.

### `VerifySolo.s.sol` environment

| Env | Default | What it pins |
|---|---|---|
| `FACTORY` | required | the AccountFactory (its `implementation()` is read from it) |
| `KEEPER`, `GUARDIAN`, `ADMIN` | required | `ADMIN` = the `DEFAULT_ADMIN_ROLE` holder (bootstrap: the deployer) |
| `FEE_RECIPIENT` | required | `feeRecipient()` |
| `EXPECTED_TICKER` | `NVDA` | asset `symbol()`, feed `description()` |
| `DEPOSIT_CAP` | `20e18` | `depositCap()` (the live NVDA factory: `type(uint256).max`) |
| `ASSET`, `PRICE_FEED`, `USDG`, `CLEARINGHOUSE`, `SEAPORT` | DeploySolo's defaults | every immutable, on the factory and on the implementation |
| `VALOREM_LIB` | read from the implementation's first link site | all 4 link sites, then the library's runtime against `out/ValoremLib.sol/ValoremLib.json` with its self-address word checked, which is what makes a derived address safe |
| `EXPECT_KEEPER_CONFIGURED` | `true` | `false` before ConfigureSolo: keeper and guardian hold nothing |
| `EXPECT_FRESH` | `true` | `false` on a market that has run |
| `EXPECT_CHAIN_ID` | `4663` | |
| `SET_POLICY` + `MIN_OTM_BPS`… | launchDefaults | the policy to expect when ConfigureSolo set one |

### `DeploySoloBatch.sh`

```bash
script/DeploySoloBatch.sh --rehearse --rpc http://127.0.0.1:8546 --tickers TSLA,GME,SPY [--out copy.json] [--deployer-pk 0x…] [--force]
script/DeploySoloBatch.sh --broadcast --rpc $RH_RPC --wave canary          # DEPLOYER_PK and ADMIN_PK in the environment
script/DeploySoloBatch.sh --rehearse --rpc http://127.0.0.1:8546 --wave wave1 --dry-run
```

| Flag | |
|---|---|
| `--registry <path>` | default `../callhouse/ops/markets/tier1.json` from the repository root |
| `--tickers A,B,C` / `--wave canary\|wave1\|wave2` | which rows. `--wave live` is refused; a row with `deployment.factory` set is skipped unless `--force` (and a `status: live` row is never redeployed on mainnet); a row with `verification.ok == false` is refused; a row with `status: superseded-by-v2` (every planned row since 2026-09-16) is refused in every mode, `--force` included: those markets list on v2 (`docs/DEPLOY-V2.md`, `script/v2/batch-refusals.sh` checks it) |
| `--rpc <url>` | default `$RH_RPC` |
| `--rehearse` | `--rpc` must be `127.0.0.1`/`localhost`, chain id 4663, and the node must answer `web3_clientVersion` as anvil and accept a 30,000 B contract (the `--code-size-limit 98304` probe). Deployer = admin = anvil account #0 (or `--deployer-pk`). Write-back goes to `--out` (default a fresh temp directory, printed), never the real file, whose sha256 is checked unchanged at the end. forge's records go under the run's log directory (`FOUNDRY_BROADCAST`), so `broadcast/DeploySolo.s.sol/4663/run-latest.json`, the mainnet NVDA record, is not overwritten |
| `--broadcast` | `--rpc` must be non-local and not anvil; `DEPLOYER_PK` and `ADMIN_PK` from the environment (never printed, never on a command line: forge runs in a subshell that exports them); `ADMIN_PK`'s address must equal each row's `deployment.admin`; prints the plan and waits for the literal word `deploy` on stdin before the first transaction; adds `--verify --verifier sourcify --chain 4663`; writes the REAL registry after each market; stops at the first failure |
| `--dry-run` | prints the per-market environment and the three commands, runs nothing, needs no RPC; with `--broadcast` (even `--broadcast --dry-run`), `DEPLOYER_PK` and `ADMIN_PK` must still be exported — the plan step derives and checks the admin address |

Per market it exports `ASSET`, `PRICE_FEED`, `DEPOSIT_CAP`, `EXPECTED_TICKER`, `ADMIN`, `SAFE_FEE`,
runs `forge script script/DeploySolo.s.sol --rpc-url … --broadcast --slow --no-storage-caching
--non-interactive [--verify …]`, reads the factory address, block, tx, gas and the `ValoremLib`
address from `run-latest.json` (`jq`), `implementation()` with `cast`, then `ConfigureSolo` with
`ADMIN_PK`, `KEEPER`, `GUARDIAN`, `DEPOSIT_CAP`, then `VerifySolo` with `EXPECT_FRESH=true` and
requires its `VERIFY PASSED` line, then `node` rewrites the six `deployment` fields (2-space JSON +
newline, the builder's own serialisation, so nothing else in the file moves). Logs:
`broadcast/solo-batch/<utc>/{batch.log, <T>-deploy.log, <T>-configure.log, <T>-verify.log,
<T>-run-latest.json, <T>-configure-safe-batch.json}`.

### Sizes (`forge build --sizes`, this commit)

| Contract | Runtime | Initcode |
|---|---|---|
| `AccountFactory` | 6,403 B | 22,766 B (it carries `WriterAccount`'s initcode) |
| `WriterAccount` | 14,653 B | 15,288 B |

Both are under EIP-170's 24,576 B, so unlike the Vault neither needs chain 4663's 98,304 B limit;
`--non-interactive` and the anvil flag are kept for uniformity with the rest of this runbook.

### Rehearsal record — 2026-09-16 (Tier 1 batch)

`script/rehearse-solo.sh` (anvil `--fork-url https://rpc.mainnet.chain.robinhood.com --chain-id 4663
--port 8546 --code-size-limit 98304`), fork block **64170688**, every forge call with
`--no-storage-caching --non-interactive`, on the working tree of `5eb84d1` plus these scripts
(`src/` unchanged). **Passed.** Deployer and admin: anvil account #0
`0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`; keeper, guardian and fee recipient from the registry
rows; `ValoremLib` reused at `0xd3CB94893EAb55e425cCd77Db98458b38D75Fa3d` (already on chain), so
each market is one transaction.

| Market | Preflight (feed answer 8 dp, age; `uiMultiplier`) | Factory / implementation | Block, gas | Verify |
|---|---|---|---|---|
| TSLA (canary, cap 27 TSLA) | `35624000000`, 1,312 s; `1e18`; description `"RHTSLA / USD"` | `0xF94AB55a20B32AC37c3A105f12dB535986697945` / `0x54f8dEbD81e25Fb3e33bf2412d5d7A2f4344813c` | 64170689, 4,766,283 | **60 of 60** |
| GME (wave2, cap 466 GME) | `2142499999`, 26,111 s; `1e18`; `"Robinhood GME / USD"` | `0x364C7188028348566E38D762f6095741c49f492B` / `0xab7CFa26b99409C07355dB52dE7E9D3922970783` | 64170692, 4,766,283 | **60 of 60** |
| SPY (wave1, cap 13 SPY) | `75750500000`, 45,571 s; `1e18`; `"RHSPY / USD"` | `0xC3549920b94a795D75E6C003944943D552C46F97` / `0x96d7B523011a3629D09ce07A3B907dF76b5054d3` | 64170695, 4,766,283 | **60 of 60** |

Every preflight printed all 16 `ok` lines (symbol, decimals, `uiMultiplier`, `oraclePaused`, USDG,
description, feed decimals, roundId, answer, age, Clear ×3, Seaport ×2, cap) and the plain-key
WARNING. ConfigureSolo broadcast 2 calls per market from anvil #0 and skipped `setDepositCap`
("already 27000000000000000000"); post-check printed both roles held. VerifySolo read
`VALOREM_LIB` from the batch (`run-latest.json` `.libraries[]`) and passed all 4 link sites and the
library runtime. The registry copy (`broadcast/solo-rehearsal/20260916T030142Z/tier1.rehearsal.json`)
holds the three `deployment` rows with `sourcify: null` and `configuredAt: "2026-09-16"`; the real
registry's sha256 `51a917a0…edcd1` was identical before and after, and
`broadcast/DeploySolo.s.sol/4663/run-latest.json` (the live NVDA record) was byte-identical too.

Negative check: byte 100 of TSLA's factory flipped `0x14 → 0x15` with `anvil_setCode`; VerifySolo
printed `FAIL  factory: runtime == compiled AccountFactory, outside immutable slots` and reverted.
The batch's own refusals were exercised without a node: `--broadcast` with a local RPC, `--rehearse`
with the public RPC, `--wave live`, `--tickers NVDA` (skipped, already deployed), `--broadcast`
without `DEPLOYER_PK`, and `--broadcast` with an `ADMIN_PK` whose address is not the row's
`deployment.admin`.

**Live NVDA factory, read-only, same day** (public RPC, simulation only, nothing sent):
`FACTORY=0xc4A5…2BBb EXPECTED_TICKER=NVDA DEPOSIT_CAP=<uint256 max> EXPECT_FRESH=false …
forge script script/VerifySolo.s.sol` → **56 of 56**: the live factory and its implementation
`0xe412…45EC` are byte-identical to this checkout's `out/` outside immutable and link slots, linked to
the same `ValoremLib`, policy `launchDefaults()`, keeper `0x06c1…C1d2`, guardian `0x2974…6F39`, admin
and fee recipient `0xEb82…9d9b` (a plain key). So the `DeploySoloBatch.sh --broadcast` path deploys
the same bytes the live market runs.

What this rehearsal does **not** prove: Sourcify verification (`--verify` runs only on `--broadcast`,
against the live chain); the real deployer and admin keys (anvil #0 stood in for
`0xEb82…9d9b`, so the batch's `deployment.admin == address(ADMIN_PK)` check was exercised only as a
refusal); anything after configuration (the first `setWeek`, a `createAccount`, a listing, a fill);
and the keeper and indexer processes reading the written-back rows.
