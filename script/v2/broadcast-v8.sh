#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# broadcast-v8.sh — OWN8-03. The owner broadcasts v8, and VerifyV8 must pass before anything is
# registered. This driver exists to make that ordering impossible to get wrong.
#
# THE REFUSAL IS THE PRODUCT. A driver that broadcasts and then verifies has exactly the failure
# mode this script was written to prevent, and that is not hypothetical: script/v2/DeployV2Batch.sh
# prints its plan as the RegisterMarkets loop FIRST and `forge script script/v2/VerifyV8.s.sol` last,
# with a comment calling the pass "required" while nothing in the ordering can enforce it. Here,
# registration is unreachable unless VerifyV8 passed IN THIS RUN AGAINST THIS DEPLOYMENT, and "this
# deployment" is a fingerprint over chain id, addresses and CODE HASHES that is re-derived from the
# chain immediately before registering — not a claim the script makes about itself.
#
#   ./script/v2/broadcast-v8.sh --registry ops/markets/tier1.json --rpc $RH_RPC
#       dry run. Prints the plan and every refusal it would apply. Sends nothing. THIS IS THE DEFAULT.
#
#   ./script/v2/broadcast-v8.sh --registry ... --rpc ... --execute --chain-id 4663
#       the real thing. BOTH flags are required; either alone is refused.
#
#   --from <phase>      deploy | verify | register. Resume a run that stopped. `--from register`
#                       still re-derives the fingerprint and still requires this run's verify receipt,
#                       so resuming cannot be used to skip the gate.
#
#   THE SEQUENCE (T-OP-161, amendment #4, owner decision 2026-09-22 05:50Z), and the hot-key window it
#   defines. Every step from 1 to 4 is sent by the DEPLOYER, which holds ADMIN from DeployV8 until HandBack:
#     1.  DeployV8 (V2_DEFER_HANDBACK=true: stops before its step 9)      --from deploy
#         -> the operator writes the sixteen back (callhouse write-back-v8.mjs) and resumes AT ONCE
#     1b. externals: deploy what has a script, record, MapExternals        --from verify
#     2.  VerifyV8, THE GATE, with the deployer group deferred (it still holds ADMIN by design)
#     3.  RegisterMarkets per launch market, sent by the DEPLOYER DIRECTLY   --from register
#         (it holds LISTING and CONFIG_ADMIN at delay 0 from DeployV8 step 4: single run, no schedule,
#         no Safe, no 1 h / 24 h wait; the driver sets the register step's env itself, see below).
#         Each market's registeredAt / registerTx is WRITTEN BACK into --registry right after its run
#         (T-OP-194: lib/register-tx.sh, the wrapper's own derivation), so step 5 sees it registered.
#     4.  HandBack: the deferred step 9 -- the deployer renounces; read back hasRole(ADMIN, deployer)==false
#     5.  VerifyV8 again WITH the deployer: the read-back that it shed everything. The receipt is final here.
#   THE ACCEPTED HOT-KEY WINDOW is 1 -> 4. A run that stops inside it leaves the deployer holding ADMIN and
#   says so; re-run --from verify (idempotent: reuse, no-op map, gate, register the remainder, hand back).
#   POST-LAUNCH registrations and listings (a later wave, --resync, a re-list) happen after the window has
#   closed and go through the Admin Safe's LISTING / CONFIG_ADMIN lanes: DeployV2Batch.sh --register-only, the
#   rc=90 "scheduled, come back after readyAt" shape. This driver does not schedule anything; if the window is
#   found closed at step 3 it refuses by name and points at the wrapper.
#
#   ADMIN_PK IS REFUSED. The register step's signer is the deployer, and for that one forge process the driver
#   itself exports V2_ADMIN=<deployer address> and ADMIN_PK=<the DEPLOYER_PK value> (the environment
#   RegisterMarkets' single-run path already accepts: admin.addr == V2_ADMIN, _signerCanList at delay 0) and
#   unsets V2_SCHEDULE / V2_SCHEDULE_PHASE. An ADMIN_PK supplied from OUTSIDE is a second key on the box that
#   nothing on this path needs; it is refused before the first forge step (registry_env_refuse_admin_pk).
#   --run-dir <dir>     where the receipt lives (default .broadcast-v8/<utc timestamp>).
#   --tickers A,B       the markets to register. Default: the registry's root `launchSet.markets` (the
#                       owner's launch set, NVDA and SPCX) minus those already registered. Whatever the
#                       source, the selection passes the SAME launch-set guard DeployV2Batch.sh applies
#                       (registry_env_launch_guard, T-OP-104) and this driver has NO --allow-off-launch:
#                       a market outside the set is refused by name. V2_TICKERS in the environment is
#                       honoured as the selection when --tickers is absent (the resume shape step 3
#                       names), and is read BEFORE the projection scrubs stale V2_* exports.
#
#   THE ENVIRONMENT (T-OP-113). Every V2_* variable DeployV8, VerifyV8 and RegisterMarkets read is
#   projected from the registry and v2-sources.json by script/v2/lib/registry-env.sh -- the ONE table
#   DeployV2Batch.sh exports from -- and loaded here before each forge step. This driver used to export
#   V2_EXPECT_CHAIN_ID alone, so its first forge step died in vm.envAddress on every input the wrapper
#   would have supplied (T-OP-095 drift item 1, T-192 suspicion 5). Nothing here types a V2_ value.
#
#   V2_DEPLOYER         (environment) the address VerifyV8 checks has shed every role. Derived from
#                       DEPLOYER_PK when not exported; --execute refuses to verify with neither.
#
#   THE EXTERNALS (T-OP-116, amendment #3 / T-OP-153, owner decision 2026-09-22 05:35Z). DeployV8 creates
#   sixteen contracts and, here, runs with V2_DEFER_HANDBACK=true: it stops before its step 9 and the
#   DEPLOYER KEEPS ADMIN. The six `roles.v8.json` targets it does not create (houseVault,
#   houseVaultFactory, hedger, rewardsDistributorLender, earnVault, stockVenueAdapter) are deployed by the
#   externals stage of lib/registry-env.sh at the START of step 2, after the operator's core write-back:
#   each through its own script where one exists (DeployHouseVault.s.sol T-OP-141, DeployEarnVault.s.sol,
#   DeployLenderRewards.s.sol), recorded at v2.contracts.<key> + v2.externalDeployBlocks.<key> in
#   --registry, exported under its V2_* name; then `forge script script/v2/MapExternals.s.sol` maps the
#   supplied externals' selectors at delay 0 from the deployer, then `forge script script/v2/HandBack.s.sol`
#   is the deferred step 9, then VerifyV8. THE ACCEPTED HOT-KEY WINDOW is DeployV8 -> HandBack, and on
#   this driver it spans the operator's write-back between step 1 and `--from verify`: do the write-back
#   at once and resume at once. Until T-OP-153 lands the two scripts are not at this base and the stage
#   dies naming them: the expected state.
#   --skip-external a,b   externals this run must NOT deploy. DEFAULT: the owner's window (hedger OUT;
#                       rewardsDistributorLender and stockVenueAdapter pending, skipped until told); `none`
#                       skips nothing; a list replaces the default. Each skip is printed and
#                       V2_SKIP_EXTERNALS carries the MANIFEST names (Hedger, …) to MapExternals and VerifyV8; a key
#                       whose address is recorded or exported is refused, never skipped.
#
# KEYS NEVER APPEAR ON A COMMAND LINE. DEPLOYER_PK and ADMIN_PK are read from the environment by the
# forge scripts themselves. This file never prints, defaults or forwards either key, and it looks at
# DEPLOYER_PK only to test whether it is set. What it does derive is the deployer's ADDRESS, for
# VerifyV8: when V2_DEPLOYER is not exported it runs script/lib/KeyAddress.s.sol with
# KEY_ENV=DEPLOYER_PK, so the key stays in that forge process's environment and only the address comes
# back. Passing a key as an argument is refused by name (see `refuse_key_in_argv`), because a flag
# lands in the shell history, in `ps` output and in any log that echoes the invocation.
#
# WHAT A FAILED STEP LOOKS LIKE is written next to every step below. A runbook that documents only
# success is how an operator learns to read a silent failure as a quiet success.
# -------------------------------------------------------------------------------------------------
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

die() { printf '\n!! %s\n' "$*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
# THE RPC URL IS A SECRET-SHAPED STRING (T-OP-182). The archive endpoint the owner supplied carries its API key in
# the PATH (`https://<host>/v2/<key>`), and every line this driver prints is tee'd into a run-dir log that outlives
# the shell -- the T-OP-118 key-on-disk shape. So nothing here ever prints $RPC: it prints `rpc_host_of "$RPC"`,
# scheme + host[:port] only, with the path, the query and any user:pass@ stripped. `--self-test` proves it on a
# URL with a key-shaped path segment.
rpc_host_of() {
  local url=$1 scheme="" rest hostport
  case "$url" in *://*) scheme=${url%%://*}; rest=${url#*://} ;; *) rest=$url ;; esac
  hostport=${rest%%/*}; hostport=${hostport%%\?*}; hostport=${hostport%%\#*}; hostport=${hostport##*@}
  if [ -n "$scheme" ]; then printf '%s://%s\n' "$scheme" "$hostport"; else printf '%s\n' "$hostport"; fi
}

# THE ONE PROJECTION (T-OP-113): registry -> V2_* environment, and with it CONTRACT_KEYS -- the 11
# named v2.contracts slots, the 3 sources and the 2 flywheel contracts = 16 addresses, IN DEPLOY
# ORDER. This used to be a second copy of DeployV2Batch.sh's list, held equal by --self-test; now both
# callers read the lib's one list, and --self-test proves the parity against the lib as a regression
# guard for anyone who copies the list back. `die` is defined above because the lib refuses through it.
. "$HERE/lib/registry-env.sh"
# T-OP-194: register_tx (forge's broadcast record), register_tx_logs (the chain) and register_record (the
# registry write) -- the wrapper's derivation of a market's registeredAt / registerTx, shared, never re-parsed.
# shellcheck source=script/v2/lib/register-tx.sh
. "$HERE/lib/register-tx.sh"
# DERIVED FROM THE LIST, NEVER A LITERAL — the same rule DeployV2Batch.sh:130 applies for the same
# reason. A hand-written count is a second copy of the set that can drift from the first, and it
# drifts SILENTLY downward: a number smaller than the real set still passes every check below while
# fingerprinting less than it claims to. (I wrote `14` here first, carried over from
# ops/v2/finish-dev-deploy.sh, which counts a DIFFERENT set — 11 named v2.contracts slots plus the 3
# sources. CONTRACT_KEYS has 16. Two true numbers for two different sets, and the wrong one here
# would have weakened the fingerprint by two contracts with nothing to notice.)
MIN_CONTRACTS=$(printf '%s\n' $CONTRACT_KEYS | wc -l | tr -d ' ')

# WHERE EACH KEY IS RECORDED. flywheel.* live at v2.flywheel, everything else at v2.contracts: the
# mapping DeployV2Batch.sh's contract_of() applies (DeployV2Batch.sh:124, :328-334), and the shape of
# fixtures/registry-v8.json. The first version of this file read EVERY key under v2.contracts, so on a
# correctly written registry the flywheel pair came back null, the count stopped at 14 of 16, and the
# driver refused a correct deployment for ever. A second copy of a mapping drifts exactly like a
# second copy of a list, so --self-test runs DeployV2Batch.sh's own contract_of() against this
# function for every key and goes red on any key the two route differently.
registry_path_of() {
  case "$1" in
    flywheel.*) printf '.v2.flywheel.%s' "${1#flywheel.}" ;;
    *) printf '.v2.contracts.%s' "$1" ;;
  esac
}

REGISTRY=""
RPC=""
EXECUTE=0
CHAIN_ID=""
FROM="deploy"
RUN_DIR=""
SELF_TEST=0
DEPLOYER_ADDR=""
DEPLOYER_SRC=""
TICKERS_ARG=""
SKIP_EXTERNAL=""
# The resume shape step 3 prints ("re-run with --from register and V2_TICKERS set to the remainder") is
# read HERE, before registry_env_export_shared scrubs every V2_* that is not a tunable override.
TICKERS_ENV_IN=${V2_TICKERS:-}

[ "${MIN_CONTRACTS:-0}" -gt 0 ] || die "CONTRACT_KEYS is empty: the fingerprint's minimum set size cannot be derived"

# Sets WANT_FP and WANT_CHAIN, or dies. EVERY CHECK IS A `|| die`, NOT AN `if present then check`.
# A missing receipt, a missing field and an empty field are the ABSENT cases, and absent is exactly
# what this gate exists to catch: `--from register` on a fresh run dir reaches here with no receipt
# at all, and an `if [ -f ... ]` wrapper would skip straight past it into registration.
require_verify_receipt() {
  local receipt=$1 chain_on_rpc=$2
  [ -f "$receipt" ] \
    || die "no verify receipt at $receipt. VerifyV8 has not passed in this run, so registration is refused. This is the gate working — run without --from register, or point --run-dir at the run whose verify passed"
  WANT_FP=$(jq -r '.fingerprint // empty' "$receipt")
  WANT_CHAIN=$(jq -r '.chainId // empty' "$receipt")
  [ -n "$WANT_FP" ] || die "$receipt has no fingerprint field. A receipt that does not name a deployment binds the pass to nothing"
  [ -n "$WANT_CHAIN" ] || die "$receipt has no chainId field"
  [ "$WANT_CHAIN" = "$chain_on_rpc" ] \
    || die "the receipt verified chain $WANT_CHAIN and this RPC answers $chain_on_rpc. A pass on one chain does not authorise registration on another"
}

# THREE CONDITIONS, AND ALL ARE LOAD-BEARING. VerifyV8 reverts on a failed check, so a non-zero exit
# is one signal -- but a VerifyV8 replaced by a stub that does nothing exits 0 and prints nothing,
# and exit status alone reads that as a pass. Requiring the PASSED line is what lets this gate tell
# "verified" from "did not run", which is the whole difference this task is about. A function so
# `--self-test` can stub it both ways and require the red.
#
# THE THIRD CONDITION (T-OP-152): a log with NO SUMMARY LINE AT ALL is a VerifyV8 that STOPPED, not
# one that failed. `forge script` aborts the whole script on certain faults (measured: an external
# self-call, "Usage of `address(this)` detected in script contract"), and the log of an aborted run
# looks normal up to the group it died in -- some `ok` lines, maybe some `FAIL` lines, then forge's
# error. Reading that as "N checks failed" is wrong in both directions: the FAIL lines it does carry
# may be the input-explained ones everybody expects, and the groups after the abort were never run,
# so their failures are invisible. It is named FAILED-INCOMPLETE, before the exit status is even
# consulted, so nobody counts FAIL lines out of a log that has no last line.
require_verify_passed() {
  local rc=$1 log=$2
  [ -f "$log" ] \
    || die "VerifyV8 exited $rc and wrote no log at $log. A run with no record of what was checked is not a pass"
  [ -s "$log" ] \
    || die "VerifyV8 exited $rc and printed nothing, not even a 'VERIFY PASSED:' line. That is NOT a pass -- it is a VerifyV8 that did not run its checks. NOTHING IS REGISTERED"
  if ! grep -qE "^\s*VERIFY (PASSED|FAILED):" "$log"; then
    die "VerifyV8 FAILED-INCOMPLETE (exited $rc): $log ends without a 'VERIFY PASSED:' or 'VERIFY FAILED:' summary line, so VerifyV8 STOPPED before its last group ran -- a forge abort mid-script, not a verdict. The $(grep -cE '^\s+FAIL' "$log" || true) FAIL line(s) it does carry are NOT a count of what failed; the groups after the stop were never run. Read the tail of $log for forge's error. NOTHING IS REGISTERED"
  fi
  [ "$rc" = 0 ] \
    || die "VerifyV8 exited $rc. NOTHING IS REGISTERED. Read $log: each failed check prints as '  FAIL  <what>' and the summary line counts them: $(grep -E '^\s*VERIFY FAILED:' "$log" | tail -1)"
  grep -q "VERIFY PASSED:" "$log" \
    || die "VerifyV8 exited 0 but printed no 'VERIFY PASSED:' line. That is NOT a pass -- it is a VerifyV8 that did not run its checks. NOTHING IS REGISTERED"
}

# The guard that BroadcastV8.s.sol cannot send a transaction, as a function of the file so
# `--self-test` can point it at a file that DOES contain one and require the red.
# COMMENT LINES ARE STRIPPED FIRST, and that is not a convenience. The first version grepped the
# whole file and went RED on the shipped BroadcastV8.s.sol -- because its own NatSpec says "there is
# no vm.startBroadcast in this file". A guard that fires on its own documentation is unusable, and it
# would have been "fixed" by deleting the sentence that explains the property. The --self-test
# positive control is what caught it: every refusal case passed and only "the shipped file must be
# ACCEPTED" failed. Stripping comments errs toward a false ALARM (a trailing comment on a code line
# still trips it), never toward a miss.
refuse_if_can_broadcast() {
  ! grep -vE '^[[:space:]]*(///|//|\*|/\*)' "$1" | grep -q "startBroadcast" \
    || die "$1 contains startBroadcast in code. It is the read-only fingerprint of the deployment and must never send a transaction; a version that can is not fit to gate one"
}

# Reads the address set from registry $1 into ADDRS (comma-joined, absent slots dropped), COUNT and
# MISSING, one key at a time IN CONTRACT_KEYS ORDER. ORDER IS PART OF THE VALUE: BroadcastV8.s.sol
# hashes the address array in order, so the same set read in another order fingerprints a different
# deployment, and a flywheel pair appended after the other fourteen would never match a fingerprint
# computed in deploy order.
# COUNT IS COUNTED, NOT PARSED BACK OUT OF ADDRS. The first version ran `printf '%s' "$ADDRS" | awk`,
# and printf of an empty string emits no line, so awk saw no record and COUNT came back EMPTY rather
# than 0. The refusal still fired, but as "integer expression expected" and " of 16 contract
# addresses", which names nothing.
read_contract_addrs() {
  local reg=$1 k path a
  ADDRS=""; COUNT=0; MISSING=""
  for k in $CONTRACT_KEYS; do
    path=$(registry_path_of "$k")
    a=$(jq -r "$path // empty" "$reg" 2>/dev/null) || die "could not read $path from $reg"
    if [ -n "$a" ]; then
      ADDRS="${ADDRS:+$ADDRS,}$a"; COUNT=$((COUNT + 1))
    else
      MISSING="${MISSING:+$MISSING }$k"
    fi
  done
}

# The registered / unregistered split VerifyV8 is told about, read from the registry as it is NOW (it moves
# between steps: step 3 writes registeredAt back per market, T-OP-194). Sets REG_T (tickers) and UNREG (assets).
registered_sets() {
  REG_T=$(jq -r '[.markets[] | select(.v2.registeredAt != null) | .ticker] | join(",")' "$REGISTRY")
  UNREG=$(jq -r '[.markets[] | select(.v2.registeredAt == null) | .asset] | join(",")' "$REGISTRY")
}

# ABSENT IS NOT ZERO AND IT IS NOT OK. A registry whose contract slots are still null produces an
# empty list, and a fingerprint over an empty list would hash happily and match itself for ever.
# The flywheel pair recorded under v2.contracts.flywheel is named separately: that is the shape
# DeployV2Batch.sh's contracts write-back currently produces, and no reader looks there.
require_contract_count() {
  local reg=$1 misplaced=""
  [ "$COUNT" -ge "$MIN_CONTRACTS" ] && return 0
  [ -z "$(jq -r '.v2.contracts.flywheel // empty' "$reg" 2>/dev/null)" ] \
    || misplaced=" The flywheel pair is recorded under v2.contracts.flywheel; every reader, this one included, looks for it at v2.flywheel."
  die "$COUNT of $MIN_CONTRACTS contract addresses in $reg (missing: $MISSING).$misplaced A FAILED step here looks like a registry that has not been written back after a deploy, NOT like a small deployment — and a fingerprint over a partial set is not a fingerprint"
}

# THE DEPLOYER VerifyV8 ASSERTS ABOUT. VerifyV8 reads V2_DEPLOYER with a zero default and every
# deployer assertion skips zero (the ADMIN hand-over, the 0..6 sweep, the exact-role sweep and the
# funding sweep), so a gate run without it says nothing about the one principal that held every role
# during the deploy. Sets DEPLOYER_ADDR (empty for none) and DEPLOYER_SRC, or dies.
# The address comes from KeyAddress.s.sol, the helper DeployV2Batch.sh addr_of() uses, and NOT from
# `cast wallet address --private-key`: that takes the key on argv, which is what the helper exists to
# avoid. With neither variable a dry run carries on and VerifyV8 reports the group as NOT CHECKED;
# --execute is refused here, before anything is sent.
resolve_deployer() {
  local execute=$1 out
  DEPLOYER_ADDR=""; DEPLOYER_SRC=""
  if [ -n "${V2_DEPLOYER:-}" ]; then
    DEPLOYER_ADDR=$V2_DEPLOYER; DEPLOYER_SRC="V2_DEPLOYER, exported"
  elif [ -n "${DEPLOYER_PK:-}" ]; then
    out=$(KEY_ENV=DEPLOYER_PK forge script "$ROOT/script/lib/KeyAddress.s.sol:KeyAddress" --non-interactive 2>/dev/null \
      | grep -E '^[[:space:]]*0x[0-9a-fA-F]{40}[[:space:]]*$' | tail -1 | tr -d '[:space:]' || true)
    [ -n "$out" ] || die "DEPLOYER_PK is set, but script/lib/KeyAddress.s.sol derived no address from it: it is not a valid key, or forge could not run the helper"
    DEPLOYER_ADDR=$out; DEPLOYER_SRC="derived from DEPLOYER_PK by script/lib/KeyAddress.s.sol"
  elif [ "$execute" = 1 ]; then
    die "--execute needs the deployer's address for VerifyV8, and neither V2_DEPLOYER nor DEPLOYER_PK is set. Without it VerifyV8 asserts nothing about the deployer shedding its roles. Export V2_DEPLOYER=<deployer address>, or DEPLOYER_PK"
  else
    return 0
  fi
  # The value is never echoed: a key pasted into V2_DEPLOYER by mistake would land in the log.
  [[ $DEPLOYER_ADDR =~ ^0x[0-9a-fA-F]{40}$ ]] \
    || die "the deployer address ($DEPLOYER_SRC) is not a 20-byte hex address. The value is not printed, in case it is a key in the wrong variable"
  [[ ! $DEPLOYER_ADDR =~ ^0x0{40}$ ]] \
    || die "the deployer address ($DEPLOYER_SRC) is the zero address. VerifyV8 skips a zero deployer, so that is the same as passing none"
}

# Runs "$@" with V2_DEPLOYER set to DEPLOYER_ADDR in ITS environment only, or with V2_DEPLOYER removed
# when there is none, so an exported empty value never reaches VerifyV8 as "".
with_deployer() {
  if [ -n "$DEPLOYER_ADDR" ]; then V2_DEPLOYER="$DEPLOYER_ADDR" "$@"; else env -u V2_DEPLOYER "$@"; fi
}

# Step 2's VerifyV8 invocation, as a function so `--self-test` can run it against a stub forge and
# require that the process it starts is the one handed the deployer. Returns VerifyV8's own status.
# `$2` = "deferred" runs it WITHOUT V2_DEPLOYER (step 2, the gate, while the deployer still holds ADMIN by design:
# VerifyV8 reports the deployer group NOT CHECKED there and everything else is asserted); anything else runs it
# WITH the deployer (step 5, the read-back after HandBack).
run_verify() {
  if [ "${2:-}" = deferred ]; then
    V2_EXPECT_CHAIN_ID="${CHAIN_ID:-$CHAIN_ON_RPC}" \
      env -u V2_DEPLOYER forge script "$HERE/VerifyV8.s.sol:VerifyV8" --rpc-url "$RPC" --no-storage-caching --non-interactive \
      2>&1 | tee "$1"
  else
    V2_EXPECT_CHAIN_ID="${CHAIN_ID:-$CHAIN_ON_RPC}" \
      with_deployer forge script "$HERE/VerifyV8.s.sol:VerifyV8" --rpc-url "$RPC" --no-storage-caching --non-interactive \
      2>&1 | tee "$1"
  fi
  return "${PIPESTATUS[0]}"
}

# Step 3's RegisterMarkets invocation, one market per forge run, sent by the DEPLOYER (T-OP-161). The register
# step's environment is set HERE and only for this process: V2_ADMIN is the deployer's address (RegisterMarkets
# requires admin.addr == V2_ADMIN), ADMIN_PK is the DEPLOYER_PK value (the same key; never printed, never argv),
# V2_SCHEDULE / V2_SCHEDULE_PHASE are removed so the single-run path is the only one. A function so
# `--self-test` can run it against a stub forge and require that the process saw exactly this and no more.
run_register_direct() { # log ticker
  V2_EXPECT_CHAIN_ID="${CHAIN_ID:-$CHAIN_ON_RPC}" V2_TICKERS="$2" V2_ADMIN="$DEPLOYER_ADDR" V2_ADMIN_SAFE="$DEPLOYER_ADDR" ADMIN_PK="${DEPLOYER_PK:?DEPLOYER_PK must be in the environment to register as the deployer}" \
    env -u V2_SCHEDULE -u V2_SCHEDULE_PHASE -u V2_RESYNC \
    forge script "$HERE/RegisterMarkets.s.sol:RegisterMarkets" --rpc-url "$RPC" --broadcast --slow --no-storage-caching --non-interactive \
    2>&1 | tee "$1"
  return "${PIPESTATUS[0]}"
}

# T-OP-194: THE WRITE-BACK step 3 never did. After a market's RegisterMarkets run, its registeredAt / registerTx
# are derived from forge's own broadcast record by lib/register-tx.sh -- register_tx, the ONE parser
# DeployV2Batch.sh uses; a second parser of run-latest.json here is the drift shape -- with the Clearinghouse's
# MarketRegistered logs as the fallback for a market an earlier run registered without recording (a resume
# after a run that died between the send and the write-back, or after a driver older than this row). The pair is
# recorded in $REGISTRY by register_record, so registered_sets and step 5's VerifyV8 see the launch markets as
# registered IN THE SAME RUN. Before this, a fully correct broadcast reached step 5 with registeredAt still null,
# registered_sets told VerifyV8 nothing was registered and VerifyV8 FAILED the correct deployment (T-OP-175 #2).
#   REFUSES: a register log without the 'REGISTER DONE' line, or with a forge 'Error:' line -- a run the log does
#   not vouch for records nothing; a run whose record and logs hold no successful registerMarket for the asset.
#   IDEMPOTENT: a resume drops recorded markets from the selection before this is reached, and register_record
#   itself treats the same values as a no-op and refuses to overwrite different ones.
# The forge record is $ROOT/broadcast/RegisterMarkets.s.sol/<chain>/run-latest.json; the caller removes it before
# each market's run (below) so a previous ticker's record is never read as this one's.
record_register() { # ticker
  local T=$1 log="$RUN_DIR/register-$1.log" run="$ROOT/broadcast/RegisterMarkets.s.sol/$CHAIN_EXPECT/run-latest.json"
  local ch asset from tx blk at line
  [ -f "$log" ] || die "$T: no register log at $log: nothing to record. THE DEPLOYER STILL HOLDS ADMIN"
  grep -q "REGISTER DONE" "$log" \
    || die "$T: $log has no 'REGISTER DONE' line: the run did not vouch for a registration, so nothing is recorded. THE DEPLOYER STILL HOLDS ADMIN"
  ! grep -qE "^Error:" "$log" \
    || die "$T: $log carries a forge 'Error:' line: a failed run records nothing. Read the log; re-run with --from register once fixed. THE DEPLOYER STILL HOLDS ADMIN"
  ch=$(jq -r '.v2.contracts.clearinghouse // empty' "$REGISTRY")
  asset=$(jq -r --arg t "$T" '.markets[] | select(.ticker == $t) | .asset // empty' "$REGISTRY")
  [ -n "$ch" ] && [ -n "$asset" ] || die "$T: the registry records no v2.contracts.clearinghouse or no asset for $T: the write-back has nothing to match"
  tx=""; blk=""
  if [ -f "$run" ]; then
    cp "$run" "$RUN_DIR/register-$T-run-latest.json"
    read -r tx blk <<<"$(register_tx "$run" "$ch" "$asset")"
  fi
  if [ -z "$tx" ]; then
    from=$(jq -r '.v2.deployBlock // 0' "$REGISTRY")
    read -r tx blk <<<"$(register_tx_logs "$RPC" "$ch" "$asset" "$from")"
    [ -z "$tx" ] || info "$T: registerMarket not in this run's forge record (registered by an earlier run); recording the Clearinghouse's MarketRegistered log"
  fi
  [ -n "$tx" ] && [ -n "$blk" ] \
    || die "$T: no mined, successful registerMarket($asset, ...) to $ch in $run and no MarketRegistered log for it on the chain: nothing to record. THE DEPLOYER STILL HOLDS ADMIN"
  at=$(cast block "$((blk))" --field timestamp --rpc-url "$RPC") || die "$T: cast block $((blk)) failed on $(rpc_host_of "$RPC"): the timestamp of the registration could not be read"
  line=$(register_record "$REGISTRY" "$T" "$at" "$tx") || die "$T: write-back refused: $line. THE DEPLOYER STILL HOLDS ADMIN"
  info "$line (block $((blk)))"
}

# A key on the command line is refused before anything else happens, including before --help would
# have printed. By the time we could warn about it, it is already in the history file.
refuse_key_in_argv() {
  for a in "$@"; do
    case "$a" in
      --deployer-pk|--admin-pk|--private-key|--mnemonic|0x[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]*)
        die "a key or key-shaped argument was passed on the command line. This driver reads DEPLOYER_PK and ADMIN_PK from the ENVIRONMENT only. An argument is in your shell history, in ps output and in every log that echoes this invocation. Unset it, rotate it if it was real, and export it instead"
        ;;
    esac
  done
}
refuse_key_in_argv "$@"

while [ $# -gt 0 ]; do
  case "$1" in
    --registry) REGISTRY=${2:?--registry needs a path}; shift 2 ;;
    --rpc) RPC=${2:?--rpc needs a url}; shift 2 ;;
    --execute) EXECUTE=1; shift ;;
    --chain-id) CHAIN_ID=${2:?--chain-id needs a number}; shift 2 ;;
    --from) FROM=${2:?--from needs deploy|verify|register}; shift 2 ;;
    --run-dir) RUN_DIR=${2:?--run-dir needs a path}; shift 2 ;;
    --tickers) TICKERS_ARG=${2:?--tickers needs A,B}; shift 2 ;;
    --skip-external) SKIP_EXTERNAL=${2:?--skip-external needs a,b}; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help) sed -n '2,54p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# ---------------------------------------------------------------- --self-test
# Every refusal this driver makes that can be proved WITHOUT a node, a key or a transaction, run
# against the REAL functions rather than a re-implementation of their reasoning. Two of the cases
# are positive controls: a suite that only ever expects red cannot tell a working gate from a
# script that dies on its first line.
self_test() {
  local pass=0 fail=0 tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  printf '{"v2":{"contracts":{}}}' > "$tmp/registry.json"

  # `$0 ...` must DIE, and its output must contain <want>.
  refuses() {
    local want=$1; shift
    local out rc=0
    # `set -e` would kill the whole suite on the very first refusal, which is the outcome every
    # case here is trying to produce. Capture the status instead of dying on it.
    out=$("$0" "$@" 2>&1) || rc=$?
    if [ "$rc" = 0 ]; then
      printf '  FAIL  did not refuse: %s\n' "$*"; fail=$((fail + 1)); return
    fi
    case "$out" in
      *"$want"*) printf '  ok    refused: %s\n' "$want"; pass=$((pass + 1)) ;;
      *) printf '  FAIL  refused for the WRONG reason: wanted %s, got: %s\n' "$want" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"; fail=$((fail + 1)) ;;
    esac
  }
  # A function call in a subshell must die (die exits, so the subshell must be non-zero).
  fn_refuses() {
    local want=$1; shift
    local out rc=0
    out=$( "$@" 2>&1 ) || rc=$?
    if [ "$rc" = 0 ]; then printf '  FAIL  did not refuse: %s\n' "$1"; fail=$((fail + 1)); return; fi
    case "$out" in
      *"$want"*) printf '  ok    refused: %s\n' "$want"; pass=$((pass + 1)) ;;
      *) printf '  FAIL  wrong reason: wanted %s, got: %s\n' "$want" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"; fail=$((fail + 1)) ;;
    esac
  }
  accepts() {
    local what=$1; shift
    if ( "$@" ) >/dev/null 2>&1; then printf '  ok    accepted: %s\n' "$what"; pass=$((pass + 1));
    else printf '  FAIL  refused what it must accept: %s\n' "$what"; fail=$((fail + 1)); fi
  }

  printf '\n== broadcast-v8 --self-test (no node, no key, no transaction)\n'

  # --- the flags
  refuses "key or key-shaped argument" --registry "$tmp/registry.json" --rpc http://x --private-key 0xdeadbeef
  refuses "--execute requires --chain-id" --registry "$tmp/registry.json" --rpc http://x --execute
  refuses "--registry is required" --rpc http://x
  refuses "registry not found" --registry "$tmp/nope.json" --rpc http://x
  refuses "--from must be deploy, verify or register" --registry "$tmp/registry.json" --rpc http://x --from whenever

  # --- T-OP-182: the RPC URL never reaches a log with its key. A URL with a key-shaped path segment, a query and
  # user:pass@ prints as scheme://host[:port] only; the positive control is that a plain host round-trips.
  fake="https://user:pw@rpc.example.test:8545/v2/K3yK3yK3yK3yK3yK3y?token=T0k3n#frag"
  got=$(rpc_host_of "$fake")
  if [ "$got" = "https://rpc.example.test:8545" ]; then printf '  ok    rpc_host_of strips path, query, fragment and userinfo: %s\n' "$got"; pass=$((pass + 1));
  else printf '  FAIL  rpc_host_of printed %s for a keyed URL\n' "$got"; fail=$((fail + 1)); fi
  case "$got" in *K3yK3y*|*T0k3n*|*pw@*) printf '  FAIL  rpc_host_of leaked a secret-shaped segment\n'; fail=$((fail + 1)) ;; esac
  got=$(rpc_host_of "http://127.0.0.1:8561")
  if [ "$got" = "http://127.0.0.1:8561" ]; then printf '  ok    rpc_host_of keeps a bare host:port as is\n'; pass=$((pass + 1));
  else printf '  FAIL  rpc_host_of mangled a bare host:port: %s\n' "$got"; fail=$((fail + 1)); fi
  # and the driver itself: no line of this file interpolates $RPC into a print. The pattern is the same
  # grep a reviewer would run; `rpc_host_of "$RPC"` is the one allowed shape.
  # (the scan's own lines carry the word "interpolates" and are excluded by it)
  leaks=$(grep -nE '(info|say|die|echo|printf) .*\$\{?RPC\}?' "$0" | grep -v 'rpc_host_of "\$RPC"' | grep -v 'interpolates' | grep -v '^[0-9]*:\s*#' || true)
  if [ -n "$leaks" ]; then
    printf '  FAIL  a print in %s still interpolates $RPC:\n' "$0"; printf '%s\n' "$leaks" | sed 's/^/        /'; fail=$((fail + 1))
  else printf '  ok    no print in broadcast-v8.sh interpolates $RPC except through rpc_host_of\n'; pass=$((pass + 1)); fi

  # --- the fingerprint script must not be able to broadcast
  printf 'contract X { function f() external { vm.startBroadcast(); } }\n' > "$tmp/CanBroadcast.sol"
  fn_refuses "contains startBroadcast" refuse_if_can_broadcast "$tmp/CanBroadcast.sol"
  accepts "the shipped BroadcastV8.s.sol sends nothing" refuse_if_can_broadcast "$HERE/BroadcastV8.s.sol"

  # --- VerifyV8 must have PASSED, and "did not run" must not read as "passed"
  # forge prints console lines under "== Logs ==" indented by two spaces; every fixture keeps that shape,
  # because an anchored `^VERIFY` called a REAL fork log incomplete while a column-0 fixture passed (T-OP-152).
  printf '== Logs ==\n  chain\n    ok    chain id 4663\n  VERIFY FAILED: 3 check(s) failed of 40\n' > "$tmp/verify-failed.log"
  fn_refuses "VerifyV8 exited 1" require_verify_passed 1 "$tmp/verify-failed.log"
  # THE CASE CRITERION 6 NAMES: VerifyV8 stubbed to do nothing. Exit 0, no output, and exit status
  # alone would call that a pass and register into an unverified deployment.
  : > "$tmp/verify-stub.log"
  fn_refuses "did not run its checks" require_verify_passed 0 "$tmp/verify-stub.log"
  fn_refuses "wrote no log" require_verify_passed 0 "$tmp/verify-absent.log"
  # T-OP-152: THE CASE THAT WAS READ AS "2 FAIL". The log of a VerifyV8 that forge aborted mid-walk: a
  # few groups, two FAIL lines, forge's error, and NO summary line. It must be named FAILED-INCOMPLETE,
  # not counted, whatever the exit status says. (The exit-0 variant is the same log from a stubbed
  # runner; it too has no summary and must not read as "did not run its checks" alone.)
  printf '== Logs ==\n  chain\n    ok    chain id 4663\n  roles\n    FAIL  hedger: role walk\n    FAIL  houseVault: role walk\nError: script failed: Usage of `address(this)` detected in script contract.\n' > "$tmp/verify-aborted.log"
  fn_refuses "FAILED-INCOMPLETE" require_verify_passed 1 "$tmp/verify-aborted.log"
  fn_refuses "FAILED-INCOMPLETE" require_verify_passed 0 "$tmp/verify-aborted.log"
  # POSITIVE CONTROL: a real pass must be accepted, or the gate above proves only that it always dies.
  printf '== Logs ==\n  chain\n    ok    chain id 4663\n  VERIFY PASSED: 40 checks\n' > "$tmp/verify-ok.log"
  accepts "a real VerifyV8 pass" require_verify_passed 0 "$tmp/verify-ok.log"
  # and a real, complete FAILURE is refused for being a failure, with its own count quoted, not as incomplete
  printf '== Logs ==\n  roles\n    FAIL  hedger: role walk\n\n  VERIFY FAILED: 1 check(s) failed of 40\n' > "$tmp/verify-complete-fail.log"
  fn_refuses "VerifyV8 exited 1" require_verify_passed 1 "$tmp/verify-complete-fail.log"

  # --- THE GATE. The first case is the one that matters: no receipt at all.
  fn_refuses "no verify receipt at" require_verify_receipt "$tmp/absent.json" 4663
  printf '{"chainId":"4663"}' > "$tmp/no-fp.json"
  fn_refuses "has no fingerprint field" require_verify_receipt "$tmp/no-fp.json" 4663
  printf '{"fingerprint":"0xaa"}' > "$tmp/no-chain.json"
  fn_refuses "has no chainId field" require_verify_receipt "$tmp/no-chain.json" 4663
  printf '{"fingerprint":"0xaa","chainId":"1"}' > "$tmp/wrong-chain.json"
  fn_refuses "does not authorise registration on another" require_verify_receipt "$tmp/wrong-chain.json" 4663
  # POSITIVE CONTROL: a well-formed receipt on the right chain must be ACCEPTED. Without this, a
  # require_verify_receipt that died unconditionally would score a perfect suite.
  printf '{"fingerprint":"0xaa","chainId":"4663"}' > "$tmp/good.json"
  accepts "a matching receipt" require_verify_receipt "$tmp/good.json" 4663

  # POSITIVE CONTROL: the set size is DERIVED and is the size of CONTRACT_KEYS, not a literal.
  local n; n=$(printf '%s\n' $CONTRACT_KEYS | wc -l | tr -d ' ')
  if [ "$MIN_CONTRACTS" = "$n" ] && [ "$n" -ge 16 ]; then
    printf '  ok    MIN_CONTRACTS is derived from CONTRACT_KEYS (%s)\n' "$n"; pass=$((pass + 1))
  else
    printf '  FAIL  MIN_CONTRACTS %s is not the derived size of CONTRACT_KEYS %s\n' "$MIN_CONTRACTS" "$n"; fail=$((fail + 1))
  fi

  # --- the address set: read from where DeployV2Batch.sh records it, in CONTRACT_KEYS order.
  # The oracle for "where" is the REAL contract_of() (lib/registry-env.sh, the one DeployV2Batch.sh
  # runs), lifted out of that file and run here, not registry_path_of: a test that asks the function under test where to look agrees with
  # it whatever it says. ABSENT IS A FAILURE, NOT A SKIP: a parity check that cannot find the thing
  # it compares against has checked nothing.
  # T-OP-113: contract_of() and CONTRACT_KEYS moved from DeployV2Batch.sh into lib/registry-env.sh, which
  # both callers source; the parity check reads them from the lib's TEXT, so a list copied back into
  # either caller would be caught by the sourced value disagreeing with the file.
  local batch="$HERE/lib/registry-env.sh" batch_fn batch_keys k got want rc theirs mine bad
  batch_fn=$(sed -n '/^contract_of() {$/,/^}$/p' "$batch" 2>/dev/null)
  batch_keys=$(sed -n 's/^CONTRACT_KEYS="\(.*\)"$/\1/p' "$batch" 2>/dev/null)
  # `contract_of <key>` as DeployV2Batch.sh defines it, with its jqr bound to registry $1.
  batch_contract_of() { ( reg=$1; jqr() { jq -r "$1" "$reg"; }; eval "$batch_fn"; contract_of "$2" ); }
  # The registry path DeployV2Batch.sh reads <key> from: the same function with jqr echoing its filter.
  batch_path_of() { ( jqr() { printf '%s' "${1% // empty}"; }; eval "$batch_fn"; contract_of "$1" ); }
  # Prints "<count> <addrs>" for a registry the driver ACCEPTS, or dies with the driver's refusal.
  addr_set_of() { read_contract_addrs "$1"; require_contract_count "$1"; printf '%s %s' "$COUNT" "$ADDRS"; }

  if [ -z "$batch_fn" ] || [ -z "$batch_keys" ]; then
    printf '  FAIL  no contract_of() or CONTRACT_KEYS found in %s: parity cannot be checked\n' "$batch"; fail=$((fail + 1))
  else
    # (4) PARITY. The key list, then the key -> path mapping for every key.
    if [ "$batch_keys" = "$CONTRACT_KEYS" ]; then
      printf '  ok    CONTRACT_KEYS is lib/registry-env.sh'"'"'s list, in its order\n'; pass=$((pass + 1))
    else
      printf '  FAIL  CONTRACT_KEYS differs from lib/registry-env.sh:\n        here:  %s\n        lib:   %s\n' "$CONTRACT_KEYS" "$batch_keys"; fail=$((fail + 1))
    fi
    bad=""
    for k in $CONTRACT_KEYS; do
      theirs=$(batch_path_of "$k"); mine=$(registry_path_of "$k")
      [ -n "$theirs" ] && [ "$theirs" = "$mine" ] || bad="$bad $k (here $mine, batch ${theirs:-<none>})"
    done
    if [ -z "$bad" ]; then
      printf '  ok    every key is read from the path lib/registry-env.sh contract_of() reads it from\n'; pass=$((pass + 1))
    else
      printf '  FAIL  key -> registry path differs from lib/registry-env.sh contract_of():%s\n' "$bad"; fail=$((fail + 1))
    fi
  fi

  # The fixtures start from the shipped registry-v8.json, so they carry the real registry shape
  # (v2.contracts with a nested sources object, v2.flywheel beside it) rather than one this file
  # invented. `full` fills every v2.contracts leaf and the v2.flywheel pair with a DISTINCT address
  # (so order is checked, not only count), written by path shape and not by registry_path_of.
  local shipped="$HERE/fixtures/registry-v8.json"
  if [ ! -f "$shipped" ]; then
    printf '  FAIL  %s is missing: the address-set cases have no registry to run against\n' "$shipped"; fail=$((fail + 1))
  else
    jq 'def addr(i): "0x" + (("0000000000000000000000000000000000000000" + (i | tostring)) | .[-40:]);
        reduce ([(.v2.contracts | paths(type != "object") | ["v2", "contracts"] + .),
                 ["v2", "flywheel", "feeSplitter"], ["v2", "flywheel", "buybackExecutor"]] | to_entries[]) as $e
          (.; setpath($e.value; addr($e.key + 1)))' "$shipped" > "$tmp/full.json"
    jq '.v2.flywheel.feeSplitter = null | .v2.flywheel.buybackExecutor = null' "$tmp/full.json" > "$tmp/no-flywheel.json"
    jq '.v2.contracts.flywheel = {feeSplitter: .v2.flywheel.feeSplitter, buybackExecutor: .v2.flywheel.buybackExecutor}
        | .v2.flywheel.feeSplitter = null | .v2.flywheel.buybackExecutor = null' "$tmp/full.json" > "$tmp/misplaced.json"

    # (1) POSITIVE CONTROL: a fully written registry is ACCEPTED, with every key counted and the
    # addresses in CONTRACT_KEYS order as DeployV2Batch.sh's contract_of() reads them.
    want=""
    for k in $CONTRACT_KEYS; do want="${want:+$want,}$(batch_contract_of "$tmp/full.json" "$k")"; done
    rc=0; got=$(addr_set_of "$tmp/full.json" 2>&1) || rc=$?
    if [ "$rc" = 0 ] && [ "$got" = "$MIN_CONTRACTS $want" ]; then
      printf '  ok    accepted: a fully written registry, %s of %s, in CONTRACT_KEYS order\n' "$MIN_CONTRACTS" "$MIN_CONTRACTS"; pass=$((pass + 1))
    else
      printf '  FAIL  a fully written registry: wanted "%s <%s addresses in order>", got: %s\n' "$MIN_CONTRACTS" "$MIN_CONTRACTS" "$(printf '%s' "$got" | tr '\n' ' ' | cut -c1-200)"; fail=$((fail + 1))
    fi

    # (2) the flywheel pair absent: refused, naming the shortfall and the two keys.
    fn_refuses "$((MIN_CONTRACTS - 2)) of $MIN_CONTRACTS contract addresses in $tmp/no-flywheel.json (missing: flywheel.feeSplitter flywheel.buybackExecutor)" \
      addr_set_of "$tmp/no-flywheel.json"
    # (2b) the pair where DeployV2Batch.sh's write-back currently puts it: refused, and says where it is.
    fn_refuses "recorded under v2.contracts.flywheel" addr_set_of "$tmp/misplaced.json"

    # (3) the shipped, never-written registry: every slot null. Refused with a COUNT of 0, and with
    # no shell arithmetic error: the first version printed "integer expression expected" here.
    rc=0; got=$(addr_set_of "$shipped" 2>&1) || rc=$?
    case "$rc:$got" in
      0:*) printf '  FAIL  did not refuse: an all-null registry\n'; fail=$((fail + 1)) ;;
      *"integer expression"*) printf '  FAIL  an all-null registry refused with a shell error: %s\n' "$(printf '%s' "$got" | tr '\n' ' ' | cut -c1-160)"; fail=$((fail + 1)) ;;
      *"!! 0 of $MIN_CONTRACTS contract addresses"*) printf '  ok    refused: 0 of %s contract addresses (all-null registry)\n' "$MIN_CONTRACTS"; pass=$((pass + 1)) ;;
      *) printf '  FAIL  an all-null registry refused for the WRONG reason: %s\n' "$(printf '%s' "$got" | tr '\n' ' ' | cut -c1-160)"; fail=$((fail + 1)) ;;
    esac
  fi

  # --- the deployer reaches VerifyV8. run_verify is the REAL step-2 invocation, run against a stub
  # forge on PATH that records its argv and prints the V2_DEPLOYER its own process was handed. The
  # KeyAddress branch is exercised the same way: the stub answers it only when KEY_ENV names
  # DEPLOYER_PK, and the recorded argv must not contain the key.
  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/forge" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_ARGV_LOG"
case "$*" in
  *KeyAddress.s.sol*) [ "${KEY_ENV:-}" = DEPLOYER_PK ] && [ -n "${DEPLOYER_PK:-}" ] && printf '  0x00000000000000000000000000000000000000c4\n' ;;
  *RegisterMarkets.s.sol*)
    # T-OP-161: the register step's environment, as the process saw it. ADMIN_PK is reported only as
    # "same as DEPLOYER_PK" / "differs" / "unset": the value never reaches a log.
    if [ -z "${ADMIN_PK-}" ]; then apk=unset; elif [ "${ADMIN_PK-}" = "${DEPLOYER_PK-}" ]; then apk=same-as-DEPLOYER_PK; else apk=differs; fi
    printf 'stub register saw V2_ADMIN=%s ADMIN_PK=%s V2_SCHEDULE=%s V2_SCHEDULE_PHASE=%s V2_TICKERS=%s\n' \
      "${V2_ADMIN-<unset>}" "$apk" "${V2_SCHEDULE-<unset>}" "${V2_SCHEDULE_PHASE-<unset>}" "${V2_TICKERS-<unset>}"
    printf '  ok    the signer holds LISTING and CONFIG_ADMIN on the accessManager, and all five targets share it\nREGISTER DONE: 1 market(s)\n' ;;
  *) printf 'stub forge saw V2_DEPLOYER=%s\n' "${V2_DEPLOYER-<unset>}" ;;
esac
STUB
  chmod +x "$tmp/bin/forge"
  local dep=0x00000000000000000000000000000000000000d1 sentinel=0xKEY-SENTINEL-NOT-A-REAL-KEY
  # V2_DEPLOYER=$1 and DEPLOYER_PK=$2 in the environment ("-" for absent), execute flag $3. Prints what
  # the VerifyV8 process saw, or dies with the driver's refusal.
  verify_saw() {
    ( if [ "$1" = - ]; then unset V2_DEPLOYER; else export V2_DEPLOYER=$1; fi
      if [ "$2" = - ]; then unset DEPLOYER_PK; else export DEPLOYER_PK=$2; fi
      export PATH="$tmp/bin:$PATH" STUB_ARGV_LOG="$tmp/argv.log"
      CHAIN_ON_RPC=4663; RPC=http://stub
      resolve_deployer "$3"
      run_verify "$tmp/verify-stub.log" >/dev/null
      sed -n 's/^stub forge saw //p' "$tmp/verify-stub.log" )
  }
  saw() {
    local want=$1 what=$2 got rc=0; shift 2
    got=$(verify_saw "$@" 2>&1) || rc=$?
    if [ "$rc" = 0 ] && [ "$got" = "$want" ]; then printf '  ok    %s: VerifyV8 saw %s\n' "$what" "$want"; pass=$((pass + 1))
    else printf '  FAIL  %s: wanted VerifyV8 to see %s, got: %s\n' "$what" "$want" "$(printf '%s' "$got" | tr '\n' ' ' | cut -c1-160)"; fail=$((fail + 1)); fi
  }
  saw "V2_DEPLOYER=$dep" "an exported V2_DEPLOYER, --execute" "$dep" - 1
  saw "V2_DEPLOYER=$dep" "the export wins over DEPLOYER_PK" "$dep" "$sentinel" 1
  : > "$tmp/argv.log"
  saw "V2_DEPLOYER=0x00000000000000000000000000000000000000c4" "derived from DEPLOYER_PK by KeyAddress.s.sol" - "$sentinel" 1
  if grep -q "KeyAddress.s.sol" "$tmp/argv.log" && ! grep -qF "$sentinel" "$tmp/argv.log"; then
    printf '  ok    KeyAddress.s.sol ran and no forge argv carried DEPLOYER_PK\n'; pass=$((pass + 1))
  else
    printf '  FAIL  KeyAddress.s.sol did not run, or a forge argv carried DEPLOYER_PK: %s\n' "$(tr '\n' ' ' < "$tmp/argv.log" | cut -c1-200)"; fail=$((fail + 1))
  fi
  saw "V2_DEPLOYER=<unset>" "a dry run with neither" - - 0
  saw "V2_DEPLOYER=<unset>" "an exported EMPTY V2_DEPLOYER is removed, not passed as \"\"" "" - 0
  fn_refuses "neither V2_DEPLOYER nor DEPLOYER_PK is set" verify_saw - - 1
  fn_refuses "is the zero address" verify_saw 0x0000000000000000000000000000000000000000 - 1
  fn_refuses "is not a 20-byte hex address" verify_saw 0xd1 - 1

  # --- the externals skip list (T-OP-116): the REAL externals_parse_skip from lib/registry-env.sh, against
  # the shipped all-null registry. A skip must never hide a supplied contract from VerifyV8, and what
  # VerifyV8 is told is the MANIFEST NAMES (the T-OP-140 spelling as landed), never registry keys or env names.
  # skip_result <registry> <--skip-external value> [<V2_* name>=<addr> to export first] -> "<V2_SKIP_EXTERNALS>|<EXT_SKIP>"
  skip_result() {
    ( STATE=$1; SKIP_EXTERNAL=$2; [ -z "${3:-}" ] || export "$3"
      externals_parse_skip; printf '%s|%s' "${V2_SKIP_EXTERNALS-<unset>}" "$EXT_SKIP" )
  }
  if [ -f "$shipped" ]; then
    fn_refuses "not one of the six externals" skip_result "$shipped" hedger,feeSplitter
    jq '.v2.contracts.earnVault = "0x0000000000000000000000000000000000000e01"' "$shipped" > "$tmp/ext-recorded.json"
    fn_refuses "its address is already recorded at v2.contracts.earnVault" skip_result "$tmp/ext-recorded.json" earnVault
    fn_refuses "V2_HEDGER is exported" skip_result "$shipped" hedger "V2_HEDGER=0x0000000000000000000000000000000000000e02"
    # POSITIVE CONTROLS: an absent external may be skipped, and VerifyV8 is told in manifest names, in order.
    rc=0; got=$(skip_result "$shipped" hedger,rewardsDistributorLender 2>&1) || rc=$?
    if [ "$rc" = 0 ] && [ "$got" = "Hedger,RewardsDistributorLender|hedger rewardsDistributorLender" ]; then
      printf '  ok    accepted: --skip-external hedger,rewardsDistributorLender -> V2_SKIP_EXTERNALS=Hedger,RewardsDistributorLender (manifest names, the T-OP-140 spelling as landed)\n'; pass=$((pass + 1))
    else
      printf '  FAIL  a legal skip list: wanted "Hedger,RewardsDistributorLender|hedger rewardsDistributorLender", got (rc %s): %s\n' "$rc" "$(printf '%s' "$got" | tr '\n' ' ' | cut -c1-160)"; fail=$((fail + 1))
    fi
    # THE DEFAULT IS THE OWNER'S WINDOW (M-0446996d3fc44c3a): hedger OUT, lender and venue adapter pending.
    rc=0; got=$(skip_result "$shipped" "" 2>&1) || rc=$?
    if [ "$rc" = 0 ] && [ "$got" = "Hedger,RewardsDistributorLender,StockVenueAdapter|hedger rewardsDistributorLender stockVenueAdapter" ]; then
      printf '  ok    accepted: no --skip-external -> the owner window, V2_SKIP_EXTERNALS=Hedger,RewardsDistributorLender,StockVenueAdapter\n'; pass=$((pass + 1))
    else
      printf '  FAIL  the default skip list: wanted the owner window, got (rc %s): %s\n' "$rc" "$(printf '%s' "$got" | tr '\n' ' ' | cut -c1-160)"; fail=$((fail + 1))
    fi
    rc=0; got=$(skip_result "$shipped" none 2>&1) || rc=$?
    if [ "$rc" = 0 ] && [ "$got" = "<unset>|" ]; then
      printf '  ok    accepted: --skip-external none leaves V2_SKIP_EXTERNALS unset (never the empty string)\n'; pass=$((pass + 1))
    else
      printf '  FAIL  --skip-external none: wanted "<unset>|", got (rc %s): %s\n' "$rc" "$(printf '%s' "$got" | tr '\n' ' ' | cut -c1-160)"; fail=$((fail + 1))
    fi
  fi

  # --- T-OP-161: the register step is the DEPLOYER's, inside its window; an external ADMIN_PK is refused.
  # (1) refusal: ADMIN_PK in the environment dies at preflight, before any registry field is read. POSITIVE
  # CONTROL: the same invocation WITHOUT it gets past that line and dies on the next refusal (no recon file).
  printf '{"v2":{"contracts":{}},"shared":{}}' > "$tmp/reg-noadmin.json"
  # `refuses` prepends "$0" itself, so the environment is set around it in a subshell rather than through env(1).
  with_admin_pk() { ( export ADMIN_PK=$sentinel; "$0" --registry "$tmp/reg-noadmin.json" --rpc http://x ); }
  without_admin_pk() { ( unset ADMIN_PK; "$0" --registry "$tmp/reg-noadmin.json" --rpc http://x ); }
  fn_refuses "ADMIN_PK is set in the environment" with_admin_pk
  fn_refuses "v2-sources.json not found next to the registry" without_admin_pk
  # (1b) T-OP-161 (f): a deployer that is one of the registry's principals is refused by name, naming both;
  # POSITIVE CONTROL: a deployer that is none of them is accepted (the REAL function, on a fixture registry).
  printf '{"shared":{"guardian":"%s","safes":{"admin":"0x00000000000000000000000000000000000000a1"}},"v2":{"bots":{"cranker":"0x00000000000000000000000000000000000000b1"}}}' "$dep" > "$tmp/reg-guardian-is-deployer.json"
  principal_check() { ( STATE=$1; registry_env_refuse_deployer_is_principal "$2" ); }
  fn_refuses "IS the registry's shared.guardian" principal_check "$tmp/reg-guardian-is-deployer.json" "$dep"
  fn_refuses "IS the registry's v2.bots.cranker" principal_check "$tmp/reg-guardian-is-deployer.json" 0x00000000000000000000000000000000000000b1
  accepts "a deployer that is none of the registry's principals" principal_check "$tmp/reg-guardian-is-deployer.json" 0x00000000000000000000000000000000000000c4
  # (2) the register step's environment, against the stub forge: V2_ADMIN is the deployer, ADMIN_PK is the
  # DEPLOYER_PK value and nothing else, V2_SCHEDULE / V2_SCHEDULE_PHASE removed even when exported around it,
  # V2_TICKERS the one market. run_register_direct is the REAL step-3 function.
  register_saw() { # V2_SCHEDULE exported around the call? ($1 = yes|no)
    ( export PATH="$tmp/bin:$PATH" STUB_ARGV_LOG="$tmp/argv.log"
      export DEPLOYER_PK=$sentinel; unset ADMIN_PK
      if [ "$1" = yes ]; then export V2_SCHEDULE=true V2_SCHEDULE_PHASE=schedule; else unset V2_SCHEDULE V2_SCHEDULE_PHASE; fi
      CHAIN_ON_RPC=4663; RPC=http://stub; CHAIN_ID=""; DEPLOYER_ADDR=$dep
      run_register_direct "$tmp/register-stub.log" NVDA >/dev/null
      sed -n 's/^stub register saw //p' "$tmp/register-stub.log" )
  }
  want="V2_ADMIN=$dep ADMIN_PK=same-as-DEPLOYER_PK V2_SCHEDULE=<unset> V2_SCHEDULE_PHASE=<unset> V2_TICKERS=NVDA"
  for around in no yes; do
    rc=0; got=$(register_saw "$around" 2>&1) || rc=$?
    if [ "$rc" = 0 ] && [ "$got" = "$want" ]; then
      printf '  ok    register step (V2_SCHEDULE exported around it: %s): RegisterMarkets saw %s\n' "$around" "$want"; pass=$((pass + 1))
    else
      printf '  FAIL  register step (V2_SCHEDULE around: %s): wanted "%s", got (rc %s): %s\n' "$around" "$want" "$rc" "$(printf '%s' "$got" | tr '\n' ' ' | cut -c1-200)"; fail=$((fail + 1))
    fi
  done
  if ! grep -qF "$sentinel" "$tmp/argv.log"; then
    printf '  ok    no forge argv carried the register signer key\n'; pass=$((pass + 1))
  else
    printf '  FAIL  a forge argv carried the register signer key\n'; fail=$((fail + 1))
  fi
  # (3) the gate runs VerifyV8 WITHOUT the deployer (its group deferred until after HandBack); the read-back
  # run has it. run_verify is the REAL function in both modes.
  verify_mode_saw() { # deferred|readback
    ( export PATH="$tmp/bin:$PATH" STUB_ARGV_LOG="$tmp/argv.log"
      CHAIN_ON_RPC=4663; RPC=http://stub; CHAIN_ID=""; DEPLOYER_ADDR=$dep
      if [ "$1" = deferred ]; then run_verify "$tmp/verify-mode.log" deferred >/dev/null; else run_verify "$tmp/verify-mode.log" >/dev/null; fi
      sed -n 's/^stub forge saw //p' "$tmp/verify-mode.log" )
  }
  rc=0; got=$(verify_mode_saw deferred 2>&1) || rc=$?
  if [ "$rc" = 0 ] && [ "$got" = "V2_DEPLOYER=<unset>" ]; then printf '  ok    the gate (step 2) runs VerifyV8 with the deployer group deferred: V2_DEPLOYER unset\n'; pass=$((pass + 1))
  else printf '  FAIL  gate VerifyV8: wanted V2_DEPLOYER=<unset>, got (rc %s): %s\n' "$rc" "$got"; fail=$((fail + 1)); fi
  rc=0; got=$(verify_mode_saw readback 2>&1) || rc=$?
  if [ "$rc" = 0 ] && [ "$got" = "V2_DEPLOYER=$dep" ]; then printf '  ok    the read-back (step 5) runs VerifyV8 WITH the deployer: V2_DEPLOYER=%s\n' "$dep"; pass=$((pass + 1))
  else printf '  FAIL  read-back VerifyV8: wanted V2_DEPLOYER=%s, got (rc %s): %s\n' "$dep" "$rc" "$got"; fail=$((fail + 1)); fi

  # --- T-OP-194: step 3's write-back. (1) register_record, the REAL lib function, on a fixture registry: records a
  # null row; the same pair again is a NO-OP that leaves the file byte-identical; a different pair is refused;
  # an unknown ticker is refused. (2) record_register, the REAL step-3 function, refuses a register log that does
  # not vouch for the run BEFORE it reads any record or touches the chain (no RPC exists here).
  printf '{"v2":{"contracts":{"clearinghouse":"0x00000000000000000000000000000000000000c1"},"deployBlock":null},"markets":[{"ticker":"NVDA","asset":"0x00000000000000000000000000000000000000a1","v2":{"registeredAt":null,"registerTx":null}}]}' > "$tmp/reg-wb.json"
  tx1=0x1111111111111111111111111111111111111111111111111111111111111111
  rc=0; got=$(register_record "$tmp/reg-wb.json" NVDA 1790000000 "$tx1" 2>&1) || rc=$?
  rec=$(jq -r '.markets[0].v2 | "\(.registeredAt) \(.registerTx)"' "$tmp/reg-wb.json")
  if [ "$rc" = 0 ] && [ "$rec" = "1790000000 $tx1" ]; then printf '  ok    register_record wrote registeredAt/registerTx into a null row\n'; pass=$((pass + 1))
  else printf '  FAIL  register_record on a null row: rc %s, row now "%s": %s\n' "$rc" "$rec" "$got"; fail=$((fail + 1)); fi
  before=$(shasum "$tmp/reg-wb.json")
  rc=0; got=$(register_record "$tmp/reg-wb.json" NVDA 1790000000 "$tx1" 2>&1) || rc=$?
  if [ "$rc" = 0 ] && [ "$(shasum "$tmp/reg-wb.json")" = "$before" ] && [ "${got#already recorded}" != "$got" ]; then
    printf '  ok    register_record is idempotent: the same pair is a no-op and the file is byte-identical\n'; pass=$((pass + 1))
  else printf '  FAIL  register_record re-run: rc %s, file changed: %s, said: %s\n' "$rc" "$([ "$(shasum "$tmp/reg-wb.json")" = "$before" ] && echo no || echo YES)" "$got"; fail=$((fail + 1)); fi
  fn_refuses "refusing to overwrite a recorded registration" register_record "$tmp/reg-wb.json" NVDA 1790000001 "$tx1"
  fn_refuses "refusing to overwrite a recorded registration" register_record "$tmp/reg-wb.json" NVDA 1790000000 0x2222222222222222222222222222222222222222222222222222222222222222
  fn_refuses "no registry row for TSLA" register_record "$tmp/reg-wb.json" TSLA 1790000000 "$tx1"
  fn_refuses "is not an unsigned integer" register_record "$tmp/reg-wb.json" NVDA soon "$tx1"
  fn_refuses "is not a transaction hash" register_record "$tmp/reg-wb.json" NVDA 1790000000 deadbeef
  rec=$(jq -r '.markets[0].v2 | "\(.registeredAt) \(.registerTx)"' "$tmp/reg-wb.json")
  if [ "$rec" = "1790000000 $tx1" ]; then printf '  ok    the refusals left the recorded pair untouched\n'; pass=$((pass + 1))
  else printf '  FAIL  a refusal changed the row: %s\n' "$rec"; fail=$((fail + 1)); fi
  # (2) the step-3 function against logs that do not vouch for the run. RUN_DIR / REGISTRY / RPC are set in the
  # subshell; a log without REGISTER DONE and a log with a forge Error: line are both refused by name, and the
  # positive control is that a vouching log gets PAST those lines to the next refusal (no forge record, no chain).
  mkdir -p "$tmp/run194"
  record_with_log_missing() { ( RUN_DIR=$tmp/run194; REGISTRY=$tmp/reg-wb.json; RPC=http://127.0.0.1:1; CHAIN_EXPECT=4663; ROOT=$tmp; rm -f "$tmp/run194/register-SPCX.log"; record_register SPCX ); }
  record_with_log() { ( RUN_DIR=$tmp/run194; REGISTRY=$tmp/reg-wb.json; RPC=http://127.0.0.1:1; CHAIN_EXPECT=4663; ROOT=$tmp; printf '%s\n' "$2" > "$tmp/run194/register-$1.log"; record_register "$1" ); }
  fn_refuses "has no 'REGISTER DONE' line" record_with_log NVDA "  ok    preflight"
  fn_refuses "carries a forge 'Error:' line" record_with_log NVDA "$(printf 'REGISTER DONE: 1\nError: script failed: revert')"
  fn_refuses "no mined, successful registerMarket" record_with_log NVDA "REGISTER DONE: 1 market"
  fn_refuses "no register log at" record_with_log_missing
  rm -rf "$tmp/run194"

  printf '\nSELF-TEST %s: %s passed, %s failed\n' "$([ "$fail" = 0 ] && echo PASSED || echo FAILED)" "$pass" "$fail"
  [ "$fail" = 0 ]
}
# --self-test needs no registry, no rpc, no node and no key, so it is dispatched before the checks
# that require them. Its body is defined below, next to the refusals it exercises.
if [ "$SELF_TEST" = 1 ]; then
  for t in jq; do command -v "$t" >/dev/null || die "$t is not on PATH"; done
  self_test; exit $?
fi

[ -n "$REGISTRY" ] || die "--registry is required"
[ -f "$REGISTRY" ] || die "registry not found: $REGISTRY"
[ -n "$RPC" ] || die "--rpc is required"
case "$FROM" in deploy|verify|register) ;; *) die "--from must be deploy, verify or register, got '$FROM'" ;; esac
for t in forge cast jq shasum; do command -v "$t" >/dev/null || die "$t is not on PATH"; done

# ---------------------------------------------------------------- the two flags, and why both
# --execute alone would act against whatever chain the RPC happens to be. --chain-id alone is a
# statement of intent with nothing behind it. Requiring both means the operator has said WHAT they
# are doing and WHERE, and the two can be checked against each other before a transaction exists.
if [ "$EXECUTE" = 1 ] && [ -z "$CHAIN_ID" ]; then
  die "--execute requires --chain-id <n>. Acting without naming the chain is how a mainnet key signs a devnet plan, or the reverse"
fi
if [ "$EXECUTE" = 0 ] && [ -n "$CHAIN_ID" ]; then
  info "--chain-id given without --execute: this is still a DRY RUN and will send nothing"
fi

# UNDER ./broadcast, AND REFUSED ANYWHERE ELSE. foundry.toml's fs_permissions make ./broadcast the ONE path
# a forge script may write (T-OP-116 found this by reading the toml, not by running: every earlier dry run
# of this driver used a stub forge). Step 1 hands DeployV8 `V2_DEPLOY_OUT=$RUN_DIR/...` and the externals
# stage hands DeployLenderRewards `V2_LENDER_DEPLOY_OUT=$RUN_DIR/...`; with the old default
# (`.broadcast-v8/`) each `vm.writeFile` would have reverted inside the simulation, after a full compile,
# with a message naming the toml and not this flag. Refusing here names the flag.
RUN_DIR=${RUN_DIR:-"$ROOT/broadcast/v8-launch/$(date -u +%Y%m%dT%H%M%SZ)"}
case "$RUN_DIR" in
  "$ROOT"/broadcast/*|broadcast/*) ;;
  *) die "--run-dir $RUN_DIR is outside $ROOT/broadcast, the only path foundry.toml fs_permissions lets a forge script write; DeployV8 (V2_DEPLOY_OUT) and DeployLenderRewards (V2_LENDER_DEPLOY_OUT) write their records there. Use a directory under $ROOT/broadcast" ;;
esac
mkdir -p "$RUN_DIR"
RECEIPT="$RUN_DIR/verify-passed.json"

say "broadcast-v8  mode=$([ "$EXECUTE" = 1 ] && echo EXECUTE || echo 'DRY RUN (default)')  from=$FROM"
info "registry  $REGISTRY"
info "rpc       $(rpc_host_of "$RPC")   (host only; the URL may carry a key)"
info "run dir   $RUN_DIR"

# ---------------------------------------------------------------- 0. preflight
say "0. preflight"

# This driver asserts the property BroadcastV8.s.sol claims about itself, rather than trusting its
# comment. A fingerprint script that could broadcast is a fingerprint script that could change the
# thing it is measuring.
refuse_if_can_broadcast "$HERE/BroadcastV8.s.sol"

# T-OP-161: a second key on the box is refused before anything runs. The register step derives its signer
# from DEPLOYER_PK inside run_register_direct; an external ADMIN_PK is never needed on this path.
registry_env_refuse_admin_pk

# The deployer VerifyV8 will check, settled BEFORE anything is sent: --execute with no deployer is
# refused here, not after DeployV8 has broadcast. Every phase needs it now: `--from register` sends
# RegisterMarkets AS the deployer and runs HandBack and the read-back VerifyV8 after it (T-OP-161).
resolve_deployer "$EXECUTE"
if [ -n "$DEPLOYER_ADDR" ]; then
  info "deployer          $DEPLOYER_ADDR ($DEPLOYER_SRC)"
else
  info "deployer          NONE: neither V2_DEPLOYER nor DEPLOYER_PK is set, so VerifyV8 will report its deployer checks as NOT CHECKED and the register step cannot be simulated as the deployer. --execute refuses this"
fi

# ---------------------------------------------------------------- the environment (T-OP-113)
# Loaded BEFORE the first RPC call, so a registry the projection refuses (a null pool key, a null bot,
# a non-address) is refused by name in a second, with no node and no compile -- exactly what
# DeployV2Batch.sh does, because this IS DeployV2Batch.sh's projection. The caller-side facts the lib
# reads are set here from the same registry fields the wrapper derives them from:
#   MODE=broadcast     this driver never impersonates: bots must be recorded (no anvil stand-ins) and
#                      V2_UNLOCKED_ADMIN is never set. A dry run still loads under the same rule so
#                      that what it prints is what --execute would send.
#   ADMIN_ADDR         shared.safes.admin, falling back to shared.admin as DeployV2Batch.sh:222 does.
#   DEPLOYER_ADDR      from resolve_deployer above (empty on a dry run with neither variable: the lib
#                      then leaves V2_DEPLOYER unset, and with_deployer keeps VerifyV8's view honest).
#   CHAIN_EXPECT       --chain-id when given, else the id the RPC answers (set after `cast chain-id`,
#                      before the first forge step; the load below uses --chain-id or 0 as a placeholder
#                      and is re-exported once the chain has answered).
# The per-market values follow the selection through registry_env_market at each RegisterMarkets step.
SOURCES_FILE="$(dirname "$REGISTRY")/v2-sources.json"
[ -f "$SOURCES_FILE" ] || die "v2-sources.json not found next to the registry: $SOURCES_FILE. DeployV8 reads the VerifierProxy, the v4 pair, WETH and the v3 buyback pool from it (DeployV2Batch.sh reads the same file)"
MODE=broadcast
NO_SCHEDULE=0; ALLOW_RENT=0; REGISTER_ONLY=0; LIST_PASS=0; DEPLOY_ONLY=0; ALLOW_OFF_LAUNCH=0
REG_ADMIN=$(jq -r '.shared.safes.admin // .shared.admin // empty' "$REGISTRY")
REG_TREASURY=$(jq -r '.shared.safes.treasury // empty' "$REGISTRY")
is_addr "$REG_ADMIN" || die "registry shared.safes.admin/shared.admin '$REG_ADMIN' is not an address"
ADMIN_ADDR=$(checksum "$REG_ADMIN")
CHAIN_EXPECT=${CHAIN_ID:-0}
# Re-exports the whole shared set (and the recorded contracts) from the registry AS IT IS NOW. Called
# before every forge step because the registry changes between them: the write-back after DeployV8
# records the addresses VerifyV8 and RegisterMarkets need, and the fee recipient (below) exists only
# from then on.
load_env() {
  registry_env_load "$REGISTRY" "$SOURCES_FILE"
  LOADED=$(env | grep -c '^V2_' || true)
}
load_env
info "environment       $LOADED V2_* variables projected from $REGISTRY and $(basename "$SOURCES_FILE") by lib/registry-env.sh"
# T-OP-161 (f): the deployer against every principal the registry names, before step 1, in one second.
STATE=$REGISTRY registry_env_refuse_deployer_is_principal "$DEPLOYER_ADDR"
[ -z "$DEPLOYER_ADDR" ] || info "deployer          is none of the registry's principals (safes, guardian, ops wallet, bots)"
info "admin safe        $ADMIN_ADDR  guardian $GUARDIAN  bots cranker $CRANKER pricer $PRICER quoter $MM_QUOTER"
info "fee recipient     ${V2_FEE_RECIPIENT:-<unset: the FeeSplitter this run deploys; projected from v2.flywheel.feeSplitter once recorded>}"

# THE SELECTION, held to the launch set. --tickers, else the V2_TICKERS this process was started with,
# else the registry's own launchSet.markets. Every source passes the guard the wrapper applies
# (registry_env_launch_guard), with no opt-out flag in this driver; a registry without the block is
# refused there. Markets already registered are dropped from the selection exactly as DeployV2Batch.sh
# drops them (v2.registeredAt set), so a resumed run registers the remainder and nothing twice.
if [ -n "$TICKERS_ARG" ]; then TICKERS=$TICKERS_ARG; TICKERS_SRC="--tickers"
elif [ -n "$TICKERS_ENV_IN" ]; then TICKERS=$TICKERS_ENV_IN; TICKERS_SRC="V2_TICKERS (environment)"
else
  TICKERS=$(jq -r 'if (.launchSet.markets | type) == "array" then [.launchSet.markets[]] | join(",") else "" end' "$REGISTRY")
  TICKERS_SRC="registry launchSet.markets"
fi
[ -n "$TICKERS" ] || die "no market selected: --tickers is absent, V2_TICKERS is unset and the registry has no launchSet.markets block"
registry_env_launch_guard
SELECTED=""; SKIPPED=""
for T in $TICKERS; do
  reg=$(jq -r --arg t "$T" '.markets[] | select(.ticker == $t) | .v2.registeredAt // empty' "$REGISTRY")
  if [ -n "$reg" ]; then SKIPPED="${SKIPPED:+$SKIPPED }$T"; else SELECTED="${SELECTED:+$SELECTED }$T"; fi
done
info "launch set        [$LAUNCH_SET]  selection from $TICKERS_SRC: ${SELECTED:-<none>}${SKIPPED:+  (already registered, skipped: $SKIPPED)}"
# An empty selection is not a refusal any more (T-OP-161): `--from verify` / `--from register` on a registry that
# already records every launch market still runs the hand-back (idempotent) and the deployer read-back.
[ -n "$SELECTED" ] || info "every selected market is already registered (v2.registeredAt set): nothing to register; the hand-back and the deployer read-back still run"

CHAIN_ON_RPC=$(cast chain-id --rpc-url "$RPC") || die "no RPC at $(rpc_host_of "$RPC"). A FAILED step here looks like a hang or 'error sending request' — it is not a chain id of 0, and nothing below runs without it"
info "chain on rpc      $CHAIN_ON_RPC"
if [ -n "$CHAIN_ID" ]; then
  [ "$CHAIN_ON_RPC" = "$CHAIN_ID" ] \
    || die "CHAIN MISMATCH: --chain-id $CHAIN_ID, and $(rpc_host_of "$RPC") answers $CHAIN_ON_RPC. Aborting before any transaction exists"
  info "chain id matches  $CHAIN_ID"
fi
CHAIN_EXPECT=${CHAIN_ID:-$CHAIN_ON_RPC}

# ---------------------------------------------------------------- 0a. the inputs, statically
# T-OP-112. Every registry / v2-sources path DeployV2Batch.sh reads before its first forge step is
# checked HERE, before the fingerprint and before any forge process exists: non-null, EIP-55, and
# holding code on $RPC. The read list is derived from the wrapper at run time (check-deploy-inputs.sh
# lifts its jq calls), never copied. A fresh launch (`--from deploy`) must start from a registry with
# NO recorded set (`--recorded none`); a resumed run (`--from verify|register`) needs all of it.
# The recon file is read beside the registry, the same rule DeployV2Batch.sh applies.
INPUT_SOURCES="$(dirname "$REGISTRY")/v2-sources.json"
if [ "$FROM" = deploy ]; then INPUT_RECORDED=none; else INPUT_RECORDED=all; fi
bash "$HERE/check-deploy-inputs.sh" --registry "$REGISTRY" --sources "$INPUT_SOURCES" --mode broadcast \
  --recorded "$INPUT_RECORDED" --rpc "$RPC" \
  || die "check-deploy-inputs refused $REGISTRY / $INPUT_SOURCES (--recorded $INPUT_RECORDED). Every REJECT line above names a path the wrapper would have read before its first forge step; fix the registry, do not skip the check"
info "deploy inputs     every path DeployV2Batch.sh reads is present (check-deploy-inputs.sh, --recorded $INPUT_RECORDED)"

# The address set, read from the registry with the same key list DeployV2Batch.sh deploys and the
# same key -> path mapping it records with (registry_path_of, above).
read_contract_addrs "$REGISTRY"
info "contracts in registry  $COUNT"
# T-OP-112 finding #1 (folded here, T-OP-113). The count used to be required unconditionally, so
# `--from deploy` on a FRESH registry -- 0 of 16 by definition, nothing has been deployed -- died right
# here and the driver could only ever resume, never start. Before the deploy the count says nothing;
# it is required from the verify step on, where the fingerprint needs every address (require_contract_count
# is called there). A fresh registry with --from verify or --from register is still refused by it.
[ "$FROM" = "deploy" ] || require_contract_count "$REGISTRY"

REG_SHA=$(shasum -a 256 "$REGISTRY" | cut -d' ' -f1)
info "registry sha256   $REG_SHA"

fingerprint_now() {
  V8_FINGERPRINT_ADDRS="$ADDRS" V8_MIN_CONTRACTS="$MIN_CONTRACTS" \
    forge script "$HERE/BroadcastV8.s.sol:BroadcastV8" --rpc-url "$RPC" --no-storage-caching --non-interactive 2>&1 \
    | awk '/BROADCASTV8 FINGERPRINT /{print $3}' | tail -1
}

# ---------------------------------------------------------------- 1. deploy
if [ "$FROM" = "deploy" ]; then
  say "1. deploy and wire (DeployV8)"
  # Loaded again with the chain id the RPC answered, and with V2_TICKERS unset: DeployV8 registers
  # nothing. The two artifacts DeployV8 writes when named -- the address file and the write-back
  # record (T-472) -- land in the run dir so the write-back below has its inputs.
  load_env
  unset V2_TICKERS
  export V2_DEPLOY_OUT="$RUN_DIR/deploy-addresses.json" V2_DEPLOY_RECORD_OUT="$RUN_DIR/deploy-record.json"
  if [ "$EXECUTE" = 0 ]; then
    info "DRY RUN — simulating (no --broadcast), with the $LOADED-variable environment above and DEPLOYER_PK from the environment, never on the command line:"
    info "  V2_EXPECT_CHAIN_ID=$CHAIN_EXPECT V2_DEFER_HANDBACK=true forge script script/v2/DeployV8.s.sol --rpc-url <rpc> --no-storage-caching --non-interactive"
    set +e
    V2_EXPECT_CHAIN_ID="$CHAIN_EXPECT" V2_DEFER_HANDBACK=true \
      forge script "$HERE/DeployV8.s.sol:DeployV8" --rpc-url "$RPC" --no-storage-caching --non-interactive 2>&1 \
      | tee "$RUN_DIR/deploy-dryrun.log"
    DEPLOY_RC=${PIPESTATUS[0]}
    set -e
    [ "$DEPLOY_RC" = 0 ] || die "the DeployV8 SIMULATION failed (exit $DEPLOY_RC). Read $RUN_DIR/deploy-dryrun.log: an 'environment variable not found' there names a registry field the projection left unset; a preflight line names the input it refused. Nothing was sent"
  else
    info "sending. A FAILED step here leaves SOME contracts deployed and the registry not written back:"
    info "do not re-run from deploy — re-run with --from verify once the registry has the addresses, or the set is deployed twice"
    info "THE DEPLOYER KEEPS ADMIN after this step (V2_DEFER_HANDBACK=true): write back and resume --from verify AT ONCE; it registers the launch set as the deployer and HandBack runs after that (T-OP-161)"
    # T-OP-153: the hand-back is DEFERRED -- the deployer keeps ADMIN until HandBack.s.sol at the end of the
    # externals stage (step 1b, after the write-back). Do the write-back and resume `--from verify` at once.
    V2_EXPECT_CHAIN_ID="$CHAIN_EXPECT" V2_DEFER_HANDBACK=true \
      forge script "$HERE/DeployV8.s.sol:DeployV8" --rpc-url "$RPC" --broadcast --slow --no-storage-caching --non-interactive \
      | tee "$RUN_DIR/deploy.log"
  fi
  unset V2_DEPLOY_OUT V2_DEPLOY_RECORD_OUT
  # A deployment the registry does not yet carry cannot be verified: VerifyV8 and the fingerprint read
  # the addresses from the registry, not from the deploy log. The write-back is a separate, deliberate
  # step (DeployV2Batch.sh:1030-1046 says why this driver does not run callhouse's write-back-v8.mjs
  # for the operator), so the run stops here and says what to do next. On a registry that already
  # carries the set (a --from deploy re-run after the write-back), the gate below runs as before.
  if [ "$COUNT" -lt "$MIN_CONTRACTS" ]; then
    say "stop: the registry carries $COUNT of $MIN_CONTRACTS contract addresses, so nothing can be verified against it yet"
    if [ "$EXECUTE" = 1 ]; then
      info "record the deployment, then resume: node <callhouse>/ops/markets/write-back-v8.mjs --deployment $RUN_DIR/deploy-record.json --registry $REGISTRY"
      info "  (--check first to see the diff), then: $0 --registry $REGISTRY --rpc <rpc> --execute --chain-id $CHAIN_EXPECT --from verify"
      info "  AT ONCE: the deployer holds ADMIN until --from verify has registered the launch set and run HandBack.s.sol (T-OP-153 / T-OP-161)"
    else
      info "DRY RUN: the simulation above is the whole of what a fresh --execute would send; the write-back and --from verify follow it"
    fi
    say "done  mode=$([ "$EXECUTE" = 1 ] && echo EXECUTE || echo 'DRY RUN')  stopped before verify: registry not yet written back"
    exit 0
  fi
fi

# ---------------------------------------------------------------- 2. verify — the gate
if [ "$FROM" = "deploy" ] || [ "$FROM" = "verify" ]; then
  # ---------------------------------------------------------------- 1b. the externals (T-OP-116 / T-OP-153 / T-OP-161)
  # After the core write-back (the registry carries the sixteen) and before the gate: deploy what has a
  # script, record everything at v2.contracts.<key> + v2.externalDeployBlocks.<key>, MapExternals (the deployer
  # still holds ADMIN from step 1's V2_DEFER_HANDBACK=true). HandBack is NOT here: it runs at step 4, after the
  # launch set has been registered by the deployer (T-OP-161). The stage reads the same caller facts
  # DeployV2Batch.sh gives it. On a dry run it simulates the scripts (or prints them when no deployer is known)
  # and records nothing. A resumed `--from verify` finds every external recorded and MapExternals a no-op.
  say "1b. externals — deploy what has a script, record, MapExternals (deployer still ADMIN; hand-back at step 4)"
  require_contract_count "$REGISTRY"
  load_env
  STATE=$REGISTRY; SOURCES=$SOURCES_FILE; ROLES_JSON="$HERE/roles.v8.json"; LOGDIR=$RUN_DIR
  BROADCAST_DIR="$ROOT/broadcast"; EXT_DEPLOY_FLAGS=""
  registry_env_externals || die "the externals stage failed (exit $?): read the 'externals:' lines above and $RUN_DIR/externals-*.log. THE DEPLOYER STILL HOLDS ADMIN: fix the input and re-run --from verify. Nothing is verified"

  say "2. VerifyV8 — the gate. Registration is unreachable unless this passes."
  require_contract_count "$REGISTRY"
  # The registry carries the set now (and the externals the stage recorded): reload so V2_<CONTRACT> for
  # every recorded slot reaches VerifyV8, then the per-market expectations for every REGISTERED market,
  # exactly as DeployV2Batch.sh phase 3 builds them (V2_TICKERS = the registered set,
  # V2_UNREGISTERED_ASSETS = the rest, V2_EXPECT_FRESH). The reload scrubs V2_*; the skip list is re-exported
  # after it so VerifyV8 still sees which externals the operator declared skipped.
  load_env
  externals_parse_skip
  registered_sets
  for T in $(echo "$REG_T" | tr ',' ' '); do registry_env_market "$T"; done
  if [ -n "$REG_T" ]; then export V2_TICKERS=$REG_T; else unset V2_TICKERS; fi
  if [ -n "$UNREG" ]; then export V2_UNREGISTERED_ASSETS=$UNREG; else unset V2_UNREGISTERED_ASSETS; fi
  # T-OP-154 F6 / T-OP-161 (b). A run that just deployed the set verifies it FRESH: every launch parameter is
  # asserted equal to the registry value and the fresh-state sweep runs (no pause, no order, no exposure, no
  # bounty paid). With `false` VerifyV8 turns a parameter mismatch into an info line ("admin-tuned after
  # launch"), which is right for a re-verify weeks later and wrong on day zero. `--from verify` is the resume
  # of a fresh deploy (the operator's write-back sits between step 1 and it), so it is fresh too; only a
  # registry that already records a registered market is a live deployment.
  if [ "$FROM" = deploy ] || [ -z "$REG_T" ]; then export V2_EXPECT_FRESH=true; else export V2_EXPECT_FRESH=false; fi
  info "V2_EXPECT_FRESH           $V2_EXPECT_FRESH ($([ "$V2_EXPECT_FRESH" = true ] && echo 'launch values asserted, fresh-state sweep on' || echo 'live: ceilings asserted, launch values as info'))"
  info "V2_DEPLOYER for VerifyV8  DEFERRED at this gate (the deployer still holds ADMIN by design until step 4; its group is NOT CHECKED here and asserted at step 5)"
  info "V2_FEE_RECIPIENT          ${V2_FEE_RECIPIENT:-<unset: v2.flywheel.feeSplitter is not recorded, the feeRecipient checks will fail>}"
  info "registered markets        ${REG_T:-none}"
  info "externals                 deployed [${EXT_DEPLOYED:-none}] reused [${EXT_REUSED:-none}] skipped [${EXT_SKIP:-none}] unsupplied [${EXT_UNSUPPLIED:-none}]${V2_SKIP_EXTERNALS:+  (V2_SKIP_EXTERNALS=$V2_SKIP_EXTERNALS)}"
  set +e
  run_verify "$RUN_DIR/verify.log" deferred
  VERIFY_RC=$?
  set -e

  require_verify_passed "$VERIFY_RC" "$RUN_DIR/verify.log"

  FP=$(fingerprint_now)
  [ -n "$FP" ] || die "the deployment fingerprint could not be read after a passing verify. NOTHING IS REGISTERED — a pass that cannot be bound to a deployment gates nothing"
  case "$FP" in 0x[0-9a-fA-F]*) ;; *) die "fingerprint '$FP' is not a 32-byte hex value" ;; esac

  jq -n --arg fp "$FP" --arg chain "$CHAIN_ON_RPC" --arg sha "$REG_SHA" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{fingerprint:$fp, chainId:$chain, registrySha256:$sha, verifiedAt:$at, handBack:"pending"}' > "$RECEIPT"
  info "VERIFY PASSED, bound to fingerprint $FP"
  info "receipt  $RECEIPT"
fi

# ---------------------------------------------------------------- 3. register — refuses without the receipt
say "3. register markets — sent by the DEPLOYER, refuses unless THIS run verified THIS deployment"

# The gate lives in require_verify_receipt (defined above) so `--self-test` exercises the REAL
# function rather than a copy of its reasoning. A refusal test that re-implements what it is testing
# proves only that two copies agree.
require_verify_receipt "$RECEIPT" "$CHAIN_ON_RPC"
require_contract_count "$REGISTRY"

# RE-DERIVED FROM THE CHAIN, NOT RE-READ FROM THE RECEIPT. The receipt says what was verified; this
# asks the chain what is there NOW. Between verify and register an upgrade, a redeploy or a wrong
# --registry would leave the receipt perfectly valid and the deployment different.
V8_EXPECT_FINGERPRINT="$WANT_FP" V8_FINGERPRINT_ADDRS="$ADDRS" V8_MIN_CONTRACTS="$MIN_CONTRACTS" \
  forge script "$HERE/BroadcastV8.s.sol:BroadcastV8" --sig "assertFingerprint()" --rpc-url "$RPC" \
  --no-storage-caching --non-interactive 2>&1 | tee "$RUN_DIR/fingerprint.log" \
  || die "the deployment no longer matches the one VerifyV8 passed against. NOTHING IS REGISTERED. $RUN_DIR/fingerprint.log prints both values"
grep -q "BROADCASTV8 FINGERPRINT MATCHES" "$RUN_DIR/fingerprint.log" \
  || die "assertFingerprint printed no MATCHES line. Treat as a failure: a silent fingerprint check is the failure this driver exists to prevent"

info "gate satisfied: VerifyV8 passed in this run against fingerprint $WANT_FP"
# ONE MARKET PER forge RUN, as DeployV2Batch.sh registers them: V2_TICKERS names the one market and
# registry_env_market projects its V2_MARKET_<T>_* row. The environment is reloaded first because
# RegisterMarkets reads the recorded set (V2_CLEARINGHOUSE and the rest) that only the written-back
# registry carries. Each market's registeredAt/registerTx IS WRITTEN BACK HERE, right after its run
# (record_register, T-OP-194), which is why a re-run drops already-registered markets from the
# selection above rather than trusting this run's memory, and why step 5 sees them registered.
load_env
ROLES_JSON="$HERE/roles.v8.json"; LOGDIR=$RUN_DIR
# THE WINDOW MUST BE OPEN, and the chain says whether it is (T-OP-161): the deployer holds LISTING and
# CONFIG_ADMIN at delay 0 until HandBack. A closed window is a post-launch registration and belongs to the
# Safe's lanes through DeployV2Batch.sh --register-only; this driver refuses it rather than scheduling.
if [ -n "$SELECTED" ]; then
  registry_env_direct_register_ok "$DEPLOYER_ADDR"
  info "register signer   $DIRECT_REGISTER_WHY"
  if [ "$DIRECT_REGISTER" != 1 ]; then
    [ "$EXECUTE" = 1 ] && die "the deployer's window is closed (or unreadable) and $SELECTED still need registering. This driver registers the LAUNCH SET by the deployer directly (T-OP-161) and nothing else; a market registered after the hand-back is a post-launch listing: run DeployV2Batch.sh --register-only --tickers $(echo $SELECTED | tr ' ' ',') for the Admin Safe's LISTING / CONFIG_ADMIN lanes (rc=90 = scheduled, come back after readyAt)"
    info "DRY RUN: on a fresh deployment the window is open here; a closed window is refused under --execute (post-launch path: DeployV2Batch.sh --register-only)"
  fi
fi
for T in $SELECTED; do
  registry_env_market "$T"
  if [ "$EXECUTE" = 0 ]; then
    info "DRY RUN — would run for $T AS THE DEPLOYER (V2_ADMIN=$DEPLOYER_ADDR, ADMIN_PK from DEPLOYER_PK inside this process only, no V2_SCHEDULE):"
    info "  V2_EXPECT_CHAIN_ID=$CHAIN_EXPECT V2_TICKERS=$T V2_ADMIN=<deployer> forge script script/v2/RegisterMarkets.s.sol --rpc-url <rpc> --broadcast --slow --no-storage-caching --non-interactive"
    info "  then: markets[$T].v2.registeredAt / registerTx written back into $REGISTRY from the run's forge record (lib/register-tx.sh)"
  else
    info "sending $T as the deployer. A FAILED step here leaves SOME markets registered and THE DEPLOYER STILL HOLDING ADMIN: re-run with --from register (the selection drops what the registry records as registered; set V2_TICKERS or --tickers to narrow it); HandBack runs once every market is in"
    # a previous ticker's forge record must never be read as this one's (record_register reads it)
    rm -f "$ROOT/broadcast/RegisterMarkets.s.sol/$CHAIN_EXPECT/run-latest.json"
    set +e
    run_register_direct "$RUN_DIR/register-$T.log" "$T"
    REG_RC=$?
    set -e
    [ "$REG_RC" = 0 ] || die "$T: RegisterMarkets exited $REG_RC. Read $RUN_DIR/register-$T.log: 'ADMIN_PK is not V2_ADMIN's key' or 'does not hold LISTING' there means the window is not what step 3 assumed; 'scheduled' there means the script took the delayed path, which this step must never do. THE DEPLOYER STILL HOLDS ADMIN"
    grep -q "the signer holds LISTING and CONFIG_ADMIN on the accessManager" "$RUN_DIR/register-$T.log" \
      || die "$T: RegisterMarkets did not print 'the signer holds LISTING and CONFIG_ADMIN on the accessManager' (the _signerCanList preflight line for the deployer). It did not register as the deployer at delay 0. THE DEPLOYER STILL HOLDS ADMIN"
    grep -q "REGISTER DONE" "$RUN_DIR/register-$T.log" \
      || die "$T: RegisterMarkets exited 0 but printed no 'REGISTER DONE' line. That is NOT a registration -- a script that did not reach its summary registered nothing it can vouch for. THE DEPLOYER STILL HOLDS ADMIN"
    ! grep -qE "^\s+scheduled " "$RUN_DIR/register-$T.log" \
      || die "$T: RegisterMarkets printed a 'scheduled' line: the run took the delayed path instead of sending directly. The window must be open (LISTING and CONFIG_ADMIN at delay 0 for the deployer) and V2_SCHEDULE must be unset for this step. THE DEPLOYER STILL HOLDS ADMIN"
    record_register "$T"
  fi
done
[ -n "$SELECTED" ] || info "every selected market is already registered (v2.registeredAt set): nothing to register; proceeding to the hand-back"

# ---------------------------------------------------------------- 4. hand-back — the deferred DeployV8 step 9
say "4. hand-back — HandBack.s.sol (the deployer renounces), read back"
# Idempotent: a re-run after a hand-back that already happened sends nothing and reads back the same fact.
# This is the step that CLOSES the window; nothing sent by the deployer is legal after it.
STATE=$REGISTRY; SOURCES=$SOURCES_FILE; BROADCAST_DIR="$ROOT/broadcast"; EXT_DEPLOY_FLAGS=""
registry_env_handback

# ---------------------------------------------------------------- 5. verify — the deployer read-back
say "5. VerifyV8 with the deployer — the read-back that it shed every role"
# The same VerifyV8 as step 2, now WITH V2_DEPLOYER: the group deferred at the gate (the ADMIN hand-over,
# the 0..6 sweep, the exact-role sweep, the funding sweep) is asserted here. Market rows appear in this
# run because step 3 wrote registeredAt back per market (T-OP-194); a `--from verify` re-run finds the same
# registry (externals reused, map a no-op, register selection empty, hand-back idempotent) and verifies them again.
load_env
externals_parse_skip
registered_sets
for T in $(echo "$REG_T" | tr ',' ' '); do registry_env_market "$T"; done
if [ -n "$REG_T" ]; then export V2_TICKERS=$REG_T; else unset V2_TICKERS; fi
if [ -n "$UNREG" ]; then export V2_UNREGISTERED_ASSETS=$UNREG; else unset V2_UNREGISTERED_ASSETS; fi
# Same rule as the gate (F6): fresh until the registry records a registered market.
if [ -z "$REG_T" ]; then export V2_EXPECT_FRESH=true; else export V2_EXPECT_FRESH=false; fi
info "V2_DEPLOYER for VerifyV8  ${DEPLOYER_ADDR:-<unset>: the deployer checks will be reported NOT CHECKED}"
set +e
run_verify "$RUN_DIR/verify-handback.log"
VERIFY2_RC=$?
set -e
require_verify_passed "$VERIFY2_RC" "$RUN_DIR/verify-handback.log"
jq --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '. + {handBack: "done", deployerVerifiedAt: $at}' "$RECEIPT" > "$RECEIPT.tmp" && mv "$RECEIPT.tmp" "$RECEIPT"
info "VERIFY PASSED with the deployer: the window is closed and recorded in $RECEIPT"
[ "$EXECUTE" = 1 ] || info "nothing was sent."

say "done  mode=$([ "$EXECUTE" = 1 ] && echo EXECUTE || echo 'DRY RUN')  receipt=$RECEIPT"
