# Deploying the vault

The contract-side runbook for mainnet (chain 4663). Hosting the keeper, indexer and frontends is a
separate runbook, `ops/deploy.md` in leekzor/callhouse. This file is rehearsed end to end by
`script/rehearse-deploy.sh` on an anvil fork; the latest record is at the bottom.

**Nothing here is done yet.** The contracts are unaudited; do not run the mainnet steps before the
audit engagement has closed and the deployed commit is the audited tag.

---

## The shape of it, and the one thing that changed

`Deploy.s.sol` gives `DEFAULT_ADMIN_ROLE` to the admin Safe in the constructor and to nobody else.
The deployer key never holds any role, so **there is no renounce step** (earlier trackers said
"renounce deployer"; it does not apply). It also means every admin action after deployment,
including granting the keeper and guardian roles, is a Safe transaction.

`Configure.s.sol` therefore does not broadcast in production. It writes a Safe{Wallet} Transaction
Builder batch that the Safe owners import, check and sign. The previous version broadcast with an
`ADMIN_PK` while saying "run as the admin Safe", which cannot work for a Safe; the fork rehearsal
confirmed a key is refused (`ADMIN_PK does not hold DEFAULT_ADMIN_ROLE`).

`Verify.s.sol` is a read-only check that the deployed vault is exactly what launch requires. Run it
before and after the Safe batch.

---

## Before the day

| Item | Detail |
|---|---|
| Admin Safe | 2 of 3, created in Safe{Wallet} on Robinhood Chain (supported; SafeL2 1.4.1 and SafeProxyFactory 1.4.1 are deployed at their canonical addresses). Owners on hardware. `ops/safes.md` §1 (leekzor/callhouse) |
| Fee Safe | receives the protocol fee (5% of premium). Its legal owner is a counsel question, `ops/launch-legal.md` §2 item 5 (leekzor/callhouse) |
| Guardian key | 1 of 1 on separate hardware, as `ops/safes.md` §3 (leekzor/callhouse) requires |
| Keeper key | hot EOA used by the keeper service; it can never move funds. `ops/safes.md` §2 (leekzor/callhouse) |
| Deployer key | a throwaway EOA. It holds no role after deploy. Fund it for about 7.6M gas (rehearsal: 7,514,058 for the two libraries and the vault) plus margin |
| RPC | `RH_RPC`, preferably an archive endpoint |
| Explorer verification | Blockscout for 4663 sits behind a Cloudflare challenge that `forge` fails; run `ops/bsproxy.js` (leekzor/callhouse) and point `--verifier-url` at it |
| Commit | the audited tag, `forge build` clean, `forge test --no-match-path 'test/fork/*'` and the fork suite green on that exact commit |

Checks on the day, before broadcasting:

```bash
forge build --sizes                              # Vault under 24,576 B
cast call 0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0 "feesEnabled()(bool)" --rpc-url $RH_RPC
                                                 # false; if true, stop: the engine fee needs a governance decision
```

---

## 1. Deploy

```bash
export DEPLOYER_PK=...            # throwaway key
export SAFE_ADMIN=0x...           # admin Safe
export SAFE_FEE=0x...             # fee Safe
forge script script/Deploy.s.sol --rpc-url $RH_RPC --broadcast --slow \
  --verify --verifier blockscout --verifier-url http://127.0.0.1:<bsproxy-port>/api
```

The script's preflight refuses a registry whose collateral, exercise token or clearinghouse do not
match NVDA / USDG / Valorem, a feed with a non-positive answer or the wrong decimals. Forge deploys
`SeaportOrderLib` and `ValoremLib` first and links both into the vault automatically.

Record from `broadcast/Deploy.s.sol/4663/run-latest.json`: the vault address, both library addresses
(`.libraries[]`), and the deploy block.

## 2. Verify, before configuration

```bash
export VAULT=0x... SEAPORT_ORDER_LIB=0x... VALOREM_LIB=0x...
export KEEPER=0x... GUARDIAN=0x... DEPLOYER=0x...   # DEPLOYER = address of DEPLOYER_PK
EXPECT_KEEPER_CONFIGURED=false forge script script/Verify.s.sol --rpc-url $RH_RPC
```

Every line must read `ok`, ending in `VERIFY PASSED`: immutables (NVDA registry, not JUGGERNAUT),
launch policy with `protocolFeeBps` 500, deposit cap 20 NVDA, `maxPriceAge` 4 days, fee recipient,
the admin Safe holds admin and is a contract, the deployer holds no role, Safe threshold 2 of 3,
both libraries have code and are linked into the vault runtime, phase Idle, not halted, Valorem fee
not accepted, no cycle opened.

## 3. Configure through the admin Safe

```bash
forge script script/Configure.s.sol --rpc-url $RH_RPC      # no --broadcast, no key
```

It prints each call with its calldata and writes `broadcast/configure-safe-batch.json`. Before
importing, decode every call independently and compare:

```bash
for d in $(jq -r '.transactions[].data' broadcast/configure-safe-batch.json); do
  cast calldata-decode "grantRole(bytes32,address)" $d
done
cast keccak KEEPER_ROLE; cast keccak GUARDIAN_ROLE           # must match the first word of each call
```

In Safe{Wallet}: the admin Safe → Apps → Transaction Builder → drag in the batch. The app warns that
the batch has no checksum; that is expected for a generated file, and it is why the decode above is
mandatory. Each signer checks the target is the vault and the two addresses are the keeper and the
guardian, then signs. Execute.

To change the launch policy in the same batch, set `SET_POLICY=true` and the policy variables
(`script/Configure.s.sol`); every value must sit inside the compiled-in caps or the Safe transaction
reverts.

## 4. Verify, after configuration

```bash
forge script script/Verify.s.sol --rpc-url $RH_RPC          # same exports as step 2
```

`VERIFY PASSED`, now including the keeper and guardian grants.

## 5. Hand over to the app

In leekzor/callhouse:

- `ops/addresses.json`: the vault, both libraries (add a `valoremLib` slot, it has none), both Safes,
  the guardian and keeper addresses, the deploy block.
- Point the `contracts/` submodule at the deployed tag; refresh `ops/abis/Vault.json` from
  `contracts/out/Vault.sol/Vault.json` and run `pnpm gen:abis` in `indexer/` and `web/`.
- Web: `NEXT_PUBLIC_VAULT`, `NEXT_PUBLIC_VAULT_FROM_BLOCK`, then **rebuild**. Indexer:
  `VAULT_ADDRESS`, `START_BLOCK`. Keeper: its environment and `KEEPER_PK` (runtime only).
- Before the first live week: one real 1-contract Overcall listing (L-04) to settle EIP-1271 against
  Overcall's production validator.

---

## Rehearsal record — 2026-09-13

`script/rehearse-deploy.sh` against `anvil --fork-url https://rpc.mainnet.chain.robinhood.com
--chain-id 4663`, on this repository after the D-05 housekeeping commit. **Passed**, run twice; the
second, recorded run on a fresh fork at block **62176750**.

| Step | Result |
|---|---|
| Safes | admin Safe `0x2Ea11b47a1573Ecb7068C2d523374b2818957150` and fee Safe `0x6631a9711D721eBdAC0977d27DF501D849CaAe59`, both 2 of 3, created through the canonical SafeProxyFactory 1.4.1 on the fork |
| Deploy preflight | `registry cycle: 1`, feed answer `21829793457` (218.29793457 USD), feed age 167,823 s (46.6 h, a weekend gap, inside the 4-day window) |
| Deploy broadcast | SeaportOrderLib `0xAe4ba02cd5Ace94DA3bbd68f746DafaA66d013f2`, ValoremLib `0x9068EA27fC0D1BF3e0D64F423e6C222F60C24C1F`, Vault `0x1ACF2372B7F66968Ca894A62E7F3Ec05e67Ce1e8`; 3 transactions, 7,514,058 gas |
| Verify, unconfigured | 27 of 27 ok, including "DEPLOYER holds no role" and both libraries linked |
| Configure, production mode | batch written with 2 calls to the vault; nothing broadcast; keeper still without a role. Batch decoded independently: `grantRole(0xfc8737ab…4fab = keccak("KEEPER_ROLE"), keeper)` and `grantRole(0x55435dd2…5041 = keccak("GUARDIAN_ROLE"), guardian)` |
| Old key-signed flow | refused: `ADMIN_PK does not hold DEFAULT_ADMIN_ROLE` |
| Configure, Safe rehearsal | both calls executed through the admin Safe with 2 of 3 owner signatures, keys supplied out of address order |
| Verify, configured | 27 of 27 ok, `VERIFY PASSED` |

What this rehearsal does **not** prove:

- The Safe{Wallet} Transaction Builder UI importing this exact file (only the format and calldata
  were checked; the Safe contract executed the same calls).
- Hardware-wallet signing, or the Safe{Wallet} transaction service on 4663.
- Blockscout source verification through `ops/bsproxy.js` (not run on a fork).
- Anything after configuration: the first `rollOpen`, a listing, a fill. The keeper dry run
  (`keeper/DRYRUN.md` in leekzor/callhouse) covers three full cycles on a separately deployed vault.
