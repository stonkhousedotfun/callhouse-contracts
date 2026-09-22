# v1 run-off: freezing the solo markets

The contract side of ADR-10 (Stonkhouse v2 plan, `01-architecture.md`): when v2 opens, every v1
`AccountFactory` (`src/solo/`) is frozen, what was already sold runs to expiry, and writers take
their collateral home. v1 positions are not converted. The operational runbook built on this file is
`ops/runbooks/v1-runoff.md` in stonkhousedotfun/callhouse (plan task O2-05); the keeper's side is
`SOLO_WIND_DOWN=1` (K2-06).

Everything below is read from the code at this commit. `src/solo/` is frozen for v2 and nothing in
this runbook changes it.

| Piece | What |
|---|---|
| `script/v2/FreezeV1.s.sol` | per factory in `V1_FACTORIES`: guardian `setWritesHalted(true)`, admin `setDepositCap(0)`; skips what is already done; Safe Transaction Builder batches; post-check |
| `script/v2/freeze-v1.sh` | reads the factories from the registry with `jq` (`deployment.factory != null`) and drives the script: `--check`, `--rehearse`, `--broadcast`, `--dry-run` |
| `test/v2/unit/FreezeV1.t.sol` | 11 tests against mock-backed factories: the script, and every claim this file makes about a frozen market |
| `test/v2/fork/FreezeV1Fork.t.sol` | 3 tests against the live NVDA factory `0xc4A5…2BBb` on a fork, sent by the real role holders, including a listing on the live Seaport and Clear |

---

## What the freeze does

Two calls per factory. Both are instant: no timelock, no delay, effective in the block they land.

| Call | Role | Effect |
|---|---|---|
| `setWritesHalted(true)` | `GUARDIAN_ROLE` (live NVDA: `0x2974…6F39`) | `WriterAccount.list()` reverts `WritesAreHalted` (`src/solo/Account.sol:207`), so nothing new is listed, by the keeper or by an owner. `WriterAccount.authorizeOrder` reverts `WritesAreHalted` (`Account.sol:270`), and Seaport calls it on every fill of a lot order, so **every lot already listed and not yet sold stops filling in the same block**. |
| `setDepositCap(0)` | `DEFAULT_ADMIN_ROLE` (live NVDA: `0xEb82…9d9b`) | `deposit` reverts `DepositCapExceeded` whenever held + amount > cap (`Account.sol:175`): at zero, every deposit of any size. |

**Listed lots do not stay fillable until `exerciseTs` once the halt is set.** Without the halt they
would: a lot order's `endTime` is `listedExerciseTs` (`Account.sol:420`) and the fill gate refuses a
write only from `exerciseTs` on (`src/lib/ValoremLib.sol:205`). With the halt, `authorizeOrder`
reverts first, and Seaport 1.6 bubbles the account's `WritesAreHalted` up to the buyer (asserted on
the live Seaport in `test_fork_freezeStopsListedLots_soldLotRunsOff`). `FreezeV1` always sets the
halt; stopping sales immediately is the point.

Why both calls: the cap alone does not stop sales, and it does not stop an owner calling `list()` on
collateral already deposited (the cap is only checked in `deposit`). The halt alone does not stop
deposits. The script sends the halts first.

## What the freeze does not do

- **It does not cancel the Seaport orders.** They stay validated on Seaport until the account's
  `settle()` bumps its Seaport counter (`Account.sol:333`) or their `endTime` passes. If the guardian
  lifted the halt before `exerciseTs`, the same orders would fill again
  (`test_frozenMarket_liftingTheHaltRevivesListedLots`, and on the live contracts inside the fork
  test). **Leave `writesHalted` true on every v1 factory for good.**
- **It does not release reserved collateral.** An unsold listed lot stays in `reserved` and out of
  `idleAssets()` (`Account.sol:182`) until `settle()`. The writer can withdraw it only after the
  account settles.
- **It does not touch options already sold.** They are Valorem ERC-1155 tokens in the buyers' wallets;
  exercising them is a call to the clearinghouse, which never reads the factory. v1 is physically
  settled and nothing exercises for the buyer: an in-the-money v1 option that is not exercised before
  its expiry expires worthless.
- **It does not stop:** `settle()` (anyone), `withdraw` of idle collateral and `claimUsdg` (owner),
  `transferOwnership`, `createAccount` (a new account can never deposit), the keeper's `setWeek`
  (harmless: nothing can list on it), and `requestWrite`. `requestWrite` still queues the account in
  `pending` (`Account.sol:192`), so `pendingCount()` can grow on a frozen factory; those entries can
  never list, and only the owner clears one (`requestWrite(0)`). Proven in
  `test_frozenMarket_listRefused_requestWriteStillQueues`.
- **It moves no funds** and changes no policy, fee recipient or role.
- **A failed redeem is now retryable, and this is no longer an operational hazard.** `settle()` redeems
  the account's Valorem claim with a caught call (`ValoremLib.tryRedeemClaim`). If that redeem reverts
  (USDG paused, or the account or Clear frozen on USDG or the Stock Token), `settle()` still completes,
  clears `listedExpiryTs`, and keeps the claim. That state is now named: `WriterAccount.isStranded()` is
  true while a cleared listing still holds an open claim, and **`retryStrandedClaim()` is the way out**
  (SEC-03). It is PERMISSIONLESS, reverts `StillStranded` while the cause persists so it can be retried
  every block, and clears `optionId` on success so the account can list again.

  **This paragraph used to end "the keeper should not crank `settle()` while USDG is paused; anyone else
  still can" — guidance standing in for a recovery path that did not exist.** It was not sound advice:
  `settle()` is permissionless, pauses are not announced, and a keeper declining to call it cannot stop
  anyone else from tripping the dead end. Before the fix a second `settle()` reverted `TooEarly`
  (`Account.sol:328`), `list()` reverted `StillOpen` on the still-set `optionId` (`Account.sol:208`),
  and no other entry point redeemed, so the collateral stayed in Valorem permanently. The keeper no
  longer needs to avoid pauses, because a redeem that fails during one is recoverable rather than final.

## When `settle()` becomes callable, and how long the exercise window lasts

- Each account's option type is created at `list()` with expiry
  `listedExpiryTs = week.baseExpiryTs + account.index` seconds (`Account.sol:228`). The per-account
  offset is what gives every account its own Valorem bucket.
- **`settle()` is callable by anyone from `block.timestamp >= listedExpiryTs`** (`Account.sol:329`;
  before that it reverts `TooEarly`). Valorem's `redeem` opens at the same timestamp (the option type's
  expiry), so a settle is never early for Clear.
- **Exercise window:** Valorem accepts `exercise` for `exerciseTs <= block.timestamp < listedExpiryTs`.
  The factory requires `baseExpiryTs >= exerciseTs + 1 day` (`AccountFactory.sol:145`), and the keeper
  sets exactly `exerciseTs + 86,400` (`keeper/src/calendar.ts`, `EXERCISE_WINDOW_SECONDS`), with
  `exerciseTs` the US close (Friday 16:00 ET = 20:00 UTC in daylight saving, 21:00 UTC otherwise;
  Thursday when Friday is a full-day NYSE holiday). **So a v1 exercise window is 24 hours plus the
  account's index in seconds**: it closes 24 hours after the close it opened at (Saturday 16:00 ET in a
  normal week), plus the index.
- **Length of the run-off.** After the freeze nothing new is listed, so the last v1 option expires at
  the largest `listedExpiryTs` among the accounts in `live` at the freeze. The keeper sets a week only
  after the previous base expiry, for the next Friday close, so that is at most 7 days (plus the index)
  after the freeze; the contracts alone bound it at 21 days from a `list()` (`ValoremLib`
  `MAX_CYCLE_TENOR`). The exact figure is printed by the post-check ("last live listedExpiryTs"), or:

  ```bash
  F=0xc4A5Cd0DE91CaB7F5Ebe2114bc63Fbb43E642BBb
  n=$(cast call $F "liveCount()(uint256)" --rpc-url $RH_RPC)
  for ((i = 0; i < n; i++)); do
    a=$(cast call $F "liveAt(uint256)(address)" $i --rpc-url $RH_RPC)
    echo "$a settle from $(cast call $a 'listedExpiryTs()(uint40)' --rpc-url $RH_RPC)"
  done
  ```

- Every account in `live` holds either an unexpired listing or an expired one nobody has settled yet,
  and an account leaves `live` only through `settle()`, which needs its expiry to have passed. So
  **`liveCount() == 0` means every v1 option ever sold on that factory has expired and been settled.**

Live NVDA factory, read 2026-09-17 04:07 UTC (block 65,068,318): 1 account, `liveCount()` 0,
`pendingCount()` 0, `writesHalted()` false, `depositCap()` `type(uint256).max`, week 1 with
`exerciseTs` 1,789,761,600 (2026-09-18 20:00 UTC) and `baseExpiryTs` 1,789,848,000 (2026-09-19
20:00 UTC). Frozen at that block there would be nothing to run off.

## When the v1 services can be switched off

| Service | Needed for | Off when |
|---|---|---|
| `keeper-nvda` (and any v1 factory keeper) | cranking `settle()`; in `SOLO_WIND_DOWN=1` it never lists or sets a week | `liveCount() == 0` on every v1 factory. `pendingCount()` may stay above 0 (see above) and does not matter: a pending account has nothing listed. `settle()` is permissionless, so a straggler can still be settled by anyone later |
| `/legacy` exercise panel | buyers exercising v1 options (physically settled: they pay the strike and take the Stock Token) | the last v1 option's expiry + 24 hours (O2-05), i.e. once `liveCount() == 0` and a day has passed |
| `/legacy` account page (withdraw, claim) | writers taking NVDA and USDG home | not tied to expiry: `withdraw` and `claimUsdg` need no keeper and no indexer and work for ever. Keep a way to call them (this page, or the explorer's write-contract tab, documented for users) until the accounts are empty |
| v1 indexer | whatever of `/legacy` still reads it | after the `/legacy` pages that read it are gone. The contracts never need it |

Do not revoke the guardian's or the admin's role on a v1 factory, and never unhalt one. Revoking the
keeper's `KEEPER_ROLE` after the keeper is off is optional hygiene (`setWeek` has no effect on a halted
market).

---

## Owner commands

Owner-gated: nothing here is run by an agent. Keys never go on a command line: load them into the
environment from a silent prompt or your secret store, and unset them afterwards. Every forge call in
the wrapper uses `--no-storage-caching` (`docs/DEPLOY.md` explains the fork cache).

```bash
cd callhouse-contracts                       # the checkout at the tagged commit
export RH_RPC=https://rpc.mainnet.chain.robinhood.com

# 0. Plan only (no node, nothing runs): which factories the registry names, and the commands.
script/v2/freeze-v1.sh --check --dry-run

# 1. Rehearse on a fork first. Mandatory. Sends the batch calls from the registry's guardian and admin
#    on anvil (impersonated, hasRole checked), then must pass the post-check and skip everything on a
#    second run. Ends "REHEARSAL PASSED".
anvil --fork-url $RH_RPC --chain-id 4663 --port 8591 --code-size-limit 98304 &
script/v2/freeze-v1.sh --rehearse --rpc http://127.0.0.1:8591
kill %1

# 2. Read-only state on mainnet. Writes the Safe batches for whatever is not frozen; exit 3 = not frozen.
script/v2/freeze-v1.sh --check --rpc $RH_RPC

# 3a. With keys (today's setup: the guardian and the admin are plain keys).
read -rs GUARDIAN_PK && export GUARDIAN_PK   # silent prompt: not in the process table, not in history
read -rs ADMIN_PK && export ADMIN_PK
script/v2/freeze-v1.sh --broadcast --rpc $RH_RPC   # prints the plan, type the word: freeze
unset GUARDIAN_PK ADMIN_PK
#     It ends with a key-less check against the chain: "FROZEN: ... post-check passed against the chain".
#     A role with no key exported is left to its batch (exit 3).

# 3b. With a Safe for a role: the batches from step 2 (or 3a) are in broadcast/freeze-v1/<utc>/.
#     Decode every call before importing (the file has no checksum; Safe{Wallet} warns, expected):
B=broadcast/freeze-v1/<utc>
jq -r '.transactions[] | .to + " " + .data' $B/guardian-safe-batch.json   # to = each v1 factory
cast calldata-decode "setWritesHalted(bool)" <data>                       # must print: true
jq -r '.transactions[] | .to + " " + .data' $B/admin-safe-batch.json
cast calldata-decode "setDepositCap(uint256)" <data>                      # must print: 0
#     Import in Safe{Wallet} -> Transaction Builder on the guardian Safe and on the admin Safe, sign,
#     execute. Name the Safes with SAFE_GUARDIAN / SAFE_ADMIN to have the script check their roles.

# 4. Verify (after 3a or 3b). Exit 0 and "post-check PASSED: 3 checks on 1 factories" per the registry.
script/v2/freeze-v1.sh --check --rpc $RH_RPC
cast call 0xc4A5Cd0DE91CaB7F5Ebe2114bc63Fbb43E642BBb "writesHalted()(bool)" --rpc-url $RH_RPC     # true
cast call 0xc4A5Cd0DE91CaB7F5Ebe2114bc63Fbb43E642BBb "depositCap()(uint256)" --rpc-url $RH_RPC    # 0

# 5. During the run-off: the liveCount / listedExpiryTs loop above. A manual settle, if the keeper is
#    down, from a foundry keystore (password prompt, no key on the line) or any wallet in the explorer:
cast send <account> "settle()" --account <keystore-name> --rpc-url $RH_RPC
```

`FreezeV1.s.sol` directly, without the wrapper: `V1_FACTORIES=0x…,0x… forge script
script/v2/FreezeV1.s.sol --rpc-url $RH_RPC --no-storage-caching` (add `--broadcast --slow` with
`GUARDIAN_PK` / `ADMIN_PK` exported). Environment:

| Env | What |
|---|---|
| `V1_FACTORIES` | required. Comma-separated factories; each must be an `AccountFactory` (its implementation's `factory()` points back), no duplicates |
| `GUARDIAN_PK` | broadcast the halts from this key; refused before anything is sent unless it holds `GUARDIAN_ROLE` on every factory still needing a halt |
| `ADMIN_PK` | the same for the caps and `DEFAULT_ADMIN_ROLE` |
| `SAFE_GUARDIAN`, `SAFE_ADMIN` | named in the batch files' `createdFromSafeAddress`; when set without the key, each must hold its role |
| `GUARDIAN_BATCH_OUT`, `ADMIN_BATCH_OUT` | default `broadcast/freeze-v1-{guardian,admin}-safe-batch.json`; the wrapper puts them in its log directory |

Idempotent: a halted factory gets no halt call, a zero cap no cap call ("already halted", "already
0"). The post-check runs when no call is left to a Safe: `writesHalted()` true, `depositCap()` 0, and
`deposit(1)` on a probe account (owner `PROBE_OWNER`, no key, created under `vm.prank` in the
simulation) reverting with exactly `DepositCapExceeded`; before the freeze that probe fails on the
token allowance instead, so the check cannot pass by accident (`test_postCheck_hasTeeth`). Under
`--broadcast` the script's own post-check reads the simulation; the wrapper's key-less re-run is the
check against the chain.

---

## Rehearsal record — 2026-09-17

`script/v2/freeze-v1.sh --rehearse` against `anvil --fork-url https://rpc.mainnet.chain.robinhood.com
--chain-id 4663 --port 8591 --code-size-limit 98304`, fork block **65,076,094**, registry
`ops/markets/tier1.json` (1 row with a factory: NVDA). **Passed.**

| Step | Result |
|---|---|
| state before | NVDA `0xc4A5…2BBb`: `writesHalted` false, `depositCap` `type(uint256).max`, live 0, pending 0; registry guardian and admin both hold their roles |
| key-less run | 2 calls, 2 batch files: guardian `setWritesHalted(true)` = `0xb28ea39f…0001`, admin `setDepositCap(0)` = `0x86651203…0000`; "PENDING: 2" |
| batches sent | guardian call from `0x2974…6F39`, admin call from `0xEb82…9d9b` (impersonated), both status 1 |
| key-less re-run | both skipped ("already halted", "already 0"); post-check **3 of 3** |
| second re-run | nothing to do; post-check **3 of 3** |
| state after | `writesHalted` true, `depositCap` 0 |

The same day, read-only against mainnet (`--check`, block 65,075,871): not frozen, the same two
calldata bytes written to the batches, nothing sent. Fork tests (`FOUNDRY_PROFILE=fork forge test
--fork-url $RH_RPC`, block 65,078,207, 23 of 23 with `test/fork/ForkLive.t.sol`): the halt and the
cap sent from the real holders used 52,080 and 29,975 gas measured around the call; a two-lot
listing on the live Seaport with one lot sold (fill 593,919 gas) stopped filling at the halt with
`WritesAreHalted`, filled again when the halt was lifted in a snapshot, and after the freeze the
buyer exercised on the live Clear, a stranger settled at `listedExpiryTs` and the writer withdrew
the unsold lot and claimed the strike.

What this does **not** prove: the real guardian and admin keys (impersonated here), Safe{Wallet}
importing the files or hardware signing, the keeper's behaviour on a halted market (K2-06), and the
`/legacy` pages.
