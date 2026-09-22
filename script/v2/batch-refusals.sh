#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# batch-refusals.sh — the refusals of script/v2/DeployV2Batch.sh and script/DeploySoloBatch.sh that need no
# node, each run and checked for its exit code and message. Nothing is sent and the registry is only read
# (the cases that need a different registry use temp copies). The two T-OP-110 cases at the end are the
# exception: their subject is the code at the Admin Safe on a fork, so they run only with FORK_RPC set to an
# anvil fork of 4663 and are printed as skipped (uncounted) without it.
#
#   script/v2/batch-refusals.sh [--registry <path>]     default ../callhouse/ops/markets/tier1.json
#   FORK_RPC=http://127.0.0.1:8553 script/v2/batch-refusals.sh   also the two fork-only Safe cases
#
# Prints one line per case and "REFUSALS PASSED: N cases" or exits 1 at the first case that misbehaves.
# -------------------------------------------------------------------------------------------------
set -euo pipefail

CALLER_PWD=$PWD
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
export PATH="$HOME/.foundry/bin:$PATH"

REGISTRY="$ROOT/script/v2/fixtures/registry-v8.json"
[ "${1:-}" != --registry ] || { REGISTRY=$2; case "$REGISTRY" in /*) ;; *) REGISTRY="$CALLER_PWD/$REGISTRY" ;; esac; }
[ -f "$REGISTRY" ] || { echo "registry not found: $REGISTRY" >&2; exit 1; }
SOURCES="$(dirname "$REGISTRY")/v2-sources.json"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/batch-refusals.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
# anvil's public dev key #0 and its address (never a real key)
ANVIL0_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ANVIL0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
LOCAL=http://127.0.0.1:1          # nothing listens there: every case below must stop before touching a node
REMOTE=https://rpc.invalid.example

CASES=0
fail() { echo "REFUSALS FAILED: $*" >&2; exit 1; }
# expect_refusal <name> <message fragment> <command...>
expect_refusal() {
  local name=$1 want=$2 out rc=0; shift 2
  out=$("$@" 2>&1 </dev/null) || rc=$?
  [ "$rc" != 0 ] || { echo "$out" | tail -5; fail "$name: exited 0, expected a refusal"; }
  grep -qF -- "$want" <<<"$out" || { echo "$out" | tail -5; fail "$name: exit $rc without \"$want\""; }
  CASES=$((CASES + 1))
  printf '  ok    %-58s exit %s: %s\n' "$name" "$rc" "$want"
}
# expect_ok <name> <output fragment> <command...>
expect_ok() {
  local name=$1 want=$2 out rc=0; shift 2
  out=$("$@" 2>&1 </dev/null) || rc=$?
  [ "$rc" = 0 ] || { echo "$out" | tail -8; fail "$name: exit $rc, expected 0"; }
  grep -qF -- "$want" <<<"$out" || { echo "$out" | tail -8; fail "$name: no \"$want\" in the output"; }
  CASES=$((CASES + 1))
  printf '  ok    %-58s exit 0: %s\n' "$name" "$want"
}
# T-OP-109, INVERTING T-OP-038. THE POOL KEY IS IN THE BASE FIXTURE NOW, AND THE NULL IS DERIVED.
# script/v2/lib/registry-env.sh:114-143 (registry_env_read_shared; the reads T-OP-113 moved out of
# DeployV2Batch.sh:348-378) reads `shared.token.poolKey` for EVERY mode and refuses a null
# currency1/hooks/fee/tickSpacing before any market check. Under T-OP-038 the base fixture carried that
# key all null (the token pool was not in any landed registry), so every COPY the two helpers made was
# given the key (POOLKEY_FILL, five values typed from docs/V2-FLYWHEEL-ROUTE-SPIKE.md) and the one case
# whose subject is the ABSENCE drove from the base fixture itself. T-OP-108 read the real key from chain
# 4663 into callhouse ops/markets/tier1.json (349ef637724da5a32d85b5313c6cfc6520e8d2d5) and T-OP-109
# mirrored `shared.token` byte-for-byte into script/v2/fixtures/registry-v8.json, so the direction is
# inverted: a copy is the base fixture plus the case's own edit and nothing else; the resolve cases
# drive from $REGISTRY itself; and T-OP-005 case 1 (below) drives from the ONE copy that NULLS the key.
# Nothing in this file types a pool-key value any more -- the fixture is the single home, and a typed
# value here would be the drift T-OP-038's "VALUES COPIED, NOT TYPED" note was guarding against.
# Every case keeps its order and its expected string; only which file carries the null moved.
copy_with() { # jq filter -> path of a registry copy (v2-sources.json alongside)
  local dir; dir=$(mktemp -d "$TMP/reg.XXXXXX")
  jq "$1" "$REGISTRY" > "$dir/tier1.json"
  cp "$SOURCES" "$dir/v2-sources.json"
  echo "$dir/tier1.json"
}
copy_with_sources() { # jq filter over v2-sources.json -> path of an unedited registry copy beside the filtered recon
  local dir; dir=$(mktemp -d "$TMP/reg.XXXXXX")
  cp "$REGISTRY" "$dir/tier1.json"
  jq "$1" "$SOURCES" > "$dir/v2-sources.json"
  echo "$dir/tier1.json"
}
# T-OP-005 case 1's input: the base fixture with ONLY the pool key nulled, every field. The null-poolKey
# refusal below drives from this copy and nothing else does -- it is the one registry in this file whose
# pool key is deliberately absent, derived from the shipped fixture rather than being the shipped fixture.
POOLKEY_NULLED=$(copy_with '.shared.token.poolKey |= with_entries(.value = null)')

V1=script/DeploySoloBatch.sh
V2=script/v2/DeployV2Batch.sh

echo "DeploySoloBatch.sh (O2-01 follow-up: superseded-by-v2 rows are never v1 factories)"
SUPERSEDED=$(copy_with '(.markets[] | select(.ticker == "TSLA") | .status) = "superseded-by-v2"')
expect_refusal "superseded row by --tickers" "TSLA: status superseded-by-v2" \
  env -u DEPLOYER_PK -u ADMIN_PK $V1 --rehearse --rpc $LOCAL --registry "$SUPERSEDED" --tickers TSLA --dry-run
expect_refusal "superseded row by --wave canary" "status superseded-by-v2" \
  env -u DEPLOYER_PK -u ADMIN_PK $V1 --rehearse --rpc $LOCAL --registry "$SUPERSEDED" --wave canary --dry-run
expect_refusal "superseded row with --force" "TSLA: status superseded-by-v2" \
  env -u DEPLOYER_PK -u ADMIN_PK $V1 --rehearse --rpc $LOCAL --registry "$SUPERSEDED" --tickers TSLA --force --dry-run
PLANNED=$(copy_with '(.markets[] | select(.ticker == "TSLA") | .status) = "planned"')
expect_ok "a planned row still plans (the refusal is specific)" "TSLA   0x322F0929c4625eD5bAd873c95208D54E1c003b2d" \
  env -u DEPLOYER_PK -u ADMIN_PK $V1 --rehearse --rpc $LOCAL --registry "$PLANNED" --tickers TSLA --dry-run

echo "DeployV2Batch.sh"
expect_refusal "no mode" "one of --rehearse, --broadcast or --verify is required" $V2 --registry "$REGISTRY" --tickers NVDA
expect_refusal "two modes" "--rehearse and --broadcast are exclusive" $V2 --rehearse --broadcast
expect_refusal "unknown flag" "unknown flag --force" $V2 --rehearse --force
expect_refusal "--rehearse on a remote RPC" "--rehearse needs a local anvil RPC" \
  $V2 --rehearse --rpc $REMOTE --registry "$REGISTRY" --tickers NVDA
expect_refusal "--broadcast on a local RPC" "--broadcast needs a non-local --rpc" \
  $V2 --broadcast --rpc $LOCAL --registry "$REGISTRY" --tickers NVDA
expect_refusal "--broadcast without DEPLOYER_PK" "DEPLOYER_PK must be in the environment for --broadcast" \
  env -u DEPLOYER_PK -u ADMIN_PK $V2 --broadcast --rpc $REMOTE --registry "$REGISTRY" --tickers NVDA
expect_refusal "--broadcast with --out" "--out is for --rehearse only" \
  env DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$REGISTRY" --tickers NVDA --out "$TMP/x.json"
expect_refusal "--broadcast with --deployer-pk" "--deployer-pk is for --rehearse only" \
  $V2 --broadcast --rpc $REMOTE --registry "$REGISTRY" --tickers NVDA --deployer-pk $ANVIL0_PK
BROADCAST_DRY=$(copy_with ".shared.safes.admin = \"$ANVIL0\" | .shared.admin = \"$ANVIL0\" | .v2.bots.cranker = \"$ANVIL0\" | .v2.bots.pricer = \"$ANVIL0\" | .v2.bots.quoter = \"$ANVIL0\"")
# Dry-run cannot call the node; the live code-less-Safe refusal is the prove-by-breaking pair.
expect_ok "--broadcast dry-run no longer requires ADMIN_PK" "deployer" \
  env DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$BROADCAST_DRY" --tickers NVDA --dry-run
ADMIN_IS_ANVIL=$(copy_with ".shared.admin = \"$ANVIL0\" | .v2.bots.cranker = null | .v2.bots.pricer = null | .v2.bots.quoter = null")
expect_refusal "--broadcast with null v2.bots" "registry v2.bots.cranker is null" \
  env DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$ADMIN_IS_ANVIL" --tickers NVDA --dry-run

# T-585, closing T-LP-02's AC2. That row fixed `bot()` to read the v8 key `quoter` instead of the v7
# `mmQuoter`, and said out loud that the test which would have caught it could not be written, because
# THIS FILE was outside that row's fence: "the four cases exist only as an extracted harness outside
# the repository and are NOT in the suite." Its suspicion 2 is that if they are never added, the next
# person to touch `bot()` has nothing that fails. This file IS in T-585's fence, so here they are.
#
# THE CRANKER CASE ABOVE CANNOT CATCH IT. `bot cranker` is resolved first (DeployV2Batch.sh:432), so a
# registry with every bot null always refuses on cranker and never reaches quoter. These three null
# ONLY quoter, with cranker and pricer set, so quoter is the key under test.
#
# EXPECTED STRINGS PROVEN BY DIRECT INVOCATION, not guessed, at 98b7d329 -- DeployV2Batch.sh run
# against scratch copies with the missing fixture values supplied so it could reach `bot()`:
#   quoter null              -> "registry v2.bots.quoter is null or absent: run ops/v2/derive-bot-keys.sh (owner) before --broadcast"
#   only the v7 name set     -> the SAME refusal: a `mmQuoter` value does not satisfy the v8 lookup
#   quoter a non-address     -> "registry v2.bots.quoter 'not-an-address' is not an address"
#
# THEY RUN IN THIS SUITE NOW, and the history of why they could not is kept because each step was MEASURED:
# at 3905051f the suite aborted at the `--broadcast dry-run` case (13 reached) on "v2-sources
# contracts.v4PoolManager.address '' is not an address"; T-OP-038 closed the sources half (v4PoolManager,
# v4StateView, weth, usdgWethV3Pool copied into script/v2/fixtures/v2-sources.json, see its `_readme`) and the
# same case then aborted one read down, at the wrapper's pool-key read, with "V2_TOKEN_POOL_CURRENCY1 has no
# value: registry shared.token.poolKey.currency1 is absent or null", because the registry fixture's poolKey
# was all null (12 before, 12 after); T-OP-038 then put the key on every COPY (POOLKEY_FILL) and measured
# REFUSALS PASSED 117, which is when these three became suite-proven. T-OP-109 moved the key into the
# fixture itself (mirrored from callhouse tier1.json at 349ef637, see the copy_with note above) and measured
# 122 cases ok before the suite stops at the T-OP-113/T-OP-137 driver case (below), the same 122 the
# unmodified tip produced in a control run -- so nothing in this file is string-proven only any more.
QUOTER_NULL=$(copy_with ".shared.admin = \"$ANVIL0\" | .v2.bots.cranker = \"$ANVIL0\" | .v2.bots.pricer = \"$ANVIL0\" | .v2.bots.quoter = null")
expect_refusal "--broadcast with only v2.bots.quoter null" "registry v2.bots.quoter is null or absent" \
  env DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$QUOTER_NULL" --tickers NVDA --dry-run
QUOTER_V7_NAME_ONLY=$(copy_with ".shared.admin = \"$ANVIL0\" | .v2.bots.cranker = \"$ANVIL0\" | .v2.bots.pricer = \"$ANVIL0\" | .v2.bots.quoter = null | .v2.bots.mmQuoter = \"$ANVIL0\"")
expect_refusal "--broadcast with the v7 bot name instead of quoter" "registry v2.bots.quoter is null or absent" \
  env DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$QUOTER_V7_NAME_ONLY" --tickers NVDA --dry-run
# T-OP-005. THE POOL-KEY GUARD, and there were NO sibling cases for these reads before this one.
# DeployV2Batch.sh now reads the v4 pool key at `shared.token.poolKey` -- the only home the registry
# schema defines -- and refuses a PRESENT, NON-ZERO `currency0` itself rather than leaving it to
# DeployV8.s.sol:489, because the wrapper exists to refuse before solc runs. The v4 leg spends native
# ETH, so zero or absent is the only correct value.
#
# EXPECTED STRING PROVEN BY DIRECT INVOCATION at 3905051f, not guessed -- DeployV2Batch.sh run against
# a scratch registry with the pool key populated and currency0 set to WETH:
#   "V2_TOKEN_POOL_CURRENCY0 '0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73' is not the zero address
#    (registry shared.token.poolKey.currency0)"
#
# RE-PROVEN at 473ff89d by direct invocation, all four cases, because a string proven at one base is a
# claim about that base (T-OP-005 epoch 2). At that base the in-repo fixture could not reach these
# reads -- it aborted earlier on `v2-sources contracts.v4PoolManager.address '' is not an address`
# -- so a SCRATCH sources copy carrying v4PoolManager/v4StateView/weth/usdgWethV3Pool was supplied
# as test input. T-OP-038 wrote those four keys INTO script/v2/fixtures/v2-sources.json (values
# copied from callhouse ops/markets/v2-sources.json at c9628484 and docs/V2-FLYWHEEL-ROUTE-SPIKE.md,
# cross-checked against the fork suites' pinned constants), so the scratch sources copy is no longer
# needed for the sources half and the wrapper reads all six values from the fixture itself.
#   1. real tier1.json, poolKey all null  -> refused "registry shared.token.poolKey.currency1 is
#      absent or null"  -- the refusal names the NEW path, which is what proves the read was repointed
#      rather than the message reworded.
#   2. poolKey populated (currency1/hooks/fee 0/tickSpacing 200) -> the five reads RESOLVE and the run
#      proceeds past them to "--broadcast first requires a passed --rehearse".
#   3. currency0 present and NON-ZERO -> refused here, before solc, naming shared.token.poolKey.
#      currency0. Explicitly ZERO -> silent, as the native-ETH leg requires.
#   4. THE SHADOWING CASE: a registry carrying a FULLY POPULATED old `v2.flywheel.tokenPool` block while
#      `shared.token.poolKey` stays null is STILL REFUSED, naming the new path. The old path is gone,
#      not shadowed -- nothing reads it any more.
#
# REACHED IN THIS SUITE since T-OP-038's copy fill (117 pass) and driven from the real key since T-OP-109; the
# abort history is in the note above the quoter cases. The case below sets its own five values on purpose:
# its SUBJECT is a wrong currency0, so it must not inherit whatever the fixture carries, and the four other
# fields are the fixture's own (the same values, restated so the case is readable on its own line).
POOL_C0_NONZERO=$(copy_with ".shared.admin = \"$ANVIL0\" | .shared.token.poolKey.currency0 = \"0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73\" | .shared.token.poolKey.currency1 = \"0xc2525b7c68b6d66dE5AABFEDC7B13314F389D5C4\" | .shared.token.poolKey.hooks = \"0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044\" | .shared.token.poolKey.fee = 0 | .shared.token.poolKey.tickSpacing = 200")
expect_refusal "--broadcast with a non-zero shared.token.poolKey.currency0" "is not the zero address (registry shared.token.poolKey.currency0)" \
  env DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$POOL_C0_NONZERO" --tickers NVDA --dry-run
# T-OP-038 / T-OP-109. T-OP-005's case 1, IN THE SUITE: a registry whose poolKey is all null is refused
# by the NEW path's name. Under T-OP-038 this drove from $REGISTRY itself because the base fixture WAS
# that registry; since T-OP-109 the fixture carries the real key, so the absence is derived instead
# ($POOLKEY_NULLED: the base fixture with every poolKey field nulled) and this is the one case in the
# file that reads it. Expected string unchanged; the name now says which file is null. --rehearse, so
# it also shows the read is not a --broadcast-only guard.
expect_refusal "a nulled shared.token.poolKey is refused by name (every mode)" "registry shared.token.poolKey.currency1 is absent or null" \
  $V2 --rehearse --rpc $LOCAL --registry "$POOLKEY_NULLED" --tickers NVDA --dry-run
QUOTER_NOT_ADDR=$(copy_with ".shared.admin = \"$ANVIL0\" | .v2.bots.cranker = \"$ANVIL0\" | .v2.bots.pricer = \"$ANVIL0\" | .v2.bots.quoter = \"not-an-address\"")
expect_refusal "--broadcast with v2.bots.quoter not an address" "registry v2.bots.quoter 'not-an-address' is not an address" \
  env DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$QUOTER_NOT_ADDR" --tickers NVDA --dry-run
expect_refusal "--tickers and --wave" "--tickers and --wave are exclusive" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --tickers NVDA --wave canary --dry-run
expect_refusal "no market selection" "--tickers A,B, --wave <canary|wave1|wave2> or --deploy-only is required" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --dry-run
expect_refusal "unknown ticker" "ZZZZ is not in the registry" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --tickers ZZZZ --dry-run
expect_refusal "unknown wave" "unknown wave 'live'" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --wave live --dry-run
# T-OP-104. THE LAUNCH-SET GUARD. The registry's root `launchSet.markets` (owner ruling 2026-09-21: NVDA and
# SPCX; the fixture carries the block copied from callhouse ops/markets/tier1.json at e09af8aa) is the one line
# that bounds settlement risk at launch, and until this row nothing in the deploy path read it: `--wave wave1`
# selected all nineteen wave1 markets. The wrapper now refuses any selection outside the set, NAMING EVERY
# OFFENDER in sorted order, unless `--allow-off-launch` is passed -- and then the plan LOGS the opt-out and the
# offenders. A registry without the block is refused outright, selection or not (fail closed: a guard that
# cannot see its subject must not pass), which is why the deploy-only case below is refused too.
# EXPECTED STRINGS PROVEN BY DIRECT INVOCATION at 564d8d66 (the scratch run in the T-OP-104 ledger entry). The
# eighteen names are the fixture's wave1 minus SPCX, sorted: a change to either list reddens this by name.
expect_refusal "--wave wave1 is refused: eighteen of its nineteen markets are outside the launch set" \
  "excludes 18 selected market(s): AAPL,AMD,AMZN,CRWV,DELL,GOOGL,INTC,META,MSFT,MSTR,MU,ORCL,PLTR,QQQ,SNDK,SPY,TSLA,TSM" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --wave wave1 --dry-run
expect_refusal "--tickers NVDA,TSLA is refused naming TSLA" "excludes 1 selected market(s): TSLA" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --tickers NVDA,TSLA --dry-run
# THE CONTROL: the launch set itself plans as before, and the plan says the guard looked.
expect_ok "--tickers NVDA,SPCX (the launch set) plans" "launch set    [NVDA,SPCX]  every selected market is in it" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --tickers NVDA,SPCX --dry-run
expect_ok "--allow-off-launch lets NVDA,TSLA through and the plan records the opt-out" \
  "OFF-LAUNCH OPT-OUT (--allow-off-launch): registering 1 market(s) outside it: TSLA" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --tickers NVDA,TSLA --allow-off-launch --dry-run
expect_ok "--allow-off-launch on --wave wave1 records all eighteen" "registering 18 market(s) outside it: AAPL,AMD" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --wave wave1 --allow-off-launch --dry-run
NO_LAUNCH_SET=$(copy_with 'del(.launchSet)')
expect_refusal "a registry without a launchSet block is refused" "registry has no launchSet.markets block" \
  $V2 --rehearse --rpc $LOCAL --registry "$NO_LAUNCH_SET" --tickers NVDA --dry-run
expect_refusal "...even with --allow-off-launch: the flag opts out of the set, not of the guard" "registry has no launchSet.markets block" \
  $V2 --rehearse --rpc $LOCAL --registry "$NO_LAUNCH_SET" --tickers NVDA --allow-off-launch --dry-run
expect_refusal "...and even on --deploy-only, which selects nothing (fail closed)" "registry has no launchSet.markets block" \
  $V2 --rehearse --rpc $LOCAL --registry "$NO_LAUNCH_SET" --deploy-only --dry-run
UNRECORDED=$(copy_with '(.v2.contracts |= with_entries(if .key == "sources" then .value |= with_entries(.value = null) else .value = null end)) | .v2.deployBlock = null')
expect_refusal "--resume with nothing recorded" "--resume, but no v2 contract is recorded" \
  $V2 --rehearse --rpc $LOCAL --registry "$UNRECORDED" --tickers NVDA --resume --dry-run
expect_refusal "--verify with nothing recorded" "--verify needs all 16 v2.contracts and v2.deployBlock recorded" \
  $V2 --verify --rpc $LOCAL --registry "$UNRECORDED"
expect_refusal "--verify with --tickers" "it takes no --tickers/--wave" \
  $V2 --verify --rpc $LOCAL --registry "$REGISTRY" --tickers NVDA
OLD_IV=$(copy_with '.v2.interfaceVersion = 4')
expect_refusal "registry of another interface version (4, before v7)" "registry v2.interfaceVersion is 4; these scripts are INTERFACE_VERSION 8" \
  $V2 --rehearse --rpc $LOCAL --registry "$OLD_IV" --tickers NVDA --dry-run
V6_IV=$(copy_with '.v2.interfaceVersion = 6')
expect_refusal "a v6 registry against v7 scripts" "registry v2.interfaceVersion is 6; these scripts are INTERFACE_VERSION 8" \
  $V2 --rehearse --rpc $LOCAL --registry "$V6_IV" --tickers NVDA --dry-run
PARTIAL=$(copy_with "(.v2.contracts |= with_entries(if .key == \"sources\" then .value |= with_entries(.value = null) else .value = null end)) | .v2.deployBlock = 1 | .v2.contracts.expiryCalendar = \"$ANVIL0\"")
expect_refusal "a partly recorded set without --resume" "1 of 16 v2.contracts recorded" \
  $V2 --rehearse --rpc $LOCAL --registry "$PARTIAL" --tickers NVDA --dry-run
BAD_POOL=$(copy_with "(.markets[] | select(.ticker == \"NVDA\") | .v2.univ3Pool) = \"$ANVIL0\"")
expect_refusal "a pool the recon does not know" "NVDA: v2.univ3Pool $ANVIL0 is not a pool of NVDA" \
  $V2 --rehearse --rpc $LOCAL --registry "$BAD_POOL" --tickers NVDA --dry-run
NVDA_POOL=$(jq -r '.markets[] | select(.ticker == "NVDA") | .v2.univ3Pool' "$REGISTRY")
COSTLY=$(copy_with_sources "(.markets[] | select(.ticker == \"NVDA\") | .pools[] | select((.address | ascii_downcase) == (\"$NVDA_POOL\" | ascii_downcase)) | .fee) = 20000")
expect_refusal "a pool fee tier above 1 % (payouts would always go in kind)" "NVDA: v2.univ3Pool $NVDA_POOL has fee tier 20000" \
  $V2 --rehearse --rpc $LOCAL --registry "$COSTLY" --tickers NVDA --dry-run
NO_TICK=$(copy_with '(.markets[] | select(.ticker == "NVDA") | .v2.strikeTick) = null')
expect_refusal "a market without a strike tick" "NVDA: v2.strikeTick is not set" \
  $V2 --rehearse --rpc $LOCAL --registry "$NO_TICK" --tickers NVDA --dry-run

echo "DeployV2Batch.sh INTERFACE_VERSION 8 (rent inverted, premium 500 / resale 0, 16 contracts)"
SHALLOW=$(copy_with_sources "(.markets[] | select(.ticker == \"NVDA\") | .pools[] | select((.address | ascii_downcase) == (\"$NVDA_POOL\" | ascii_downcase)) | .cardinality) = 1801")
expect_refusal "a pool whose observation ring is below 2401 (owner sign-off c10)" "has observationCardinality 1801 in" \
  $V2 --rehearse --rpc $LOCAL --registry "$SHALLOW" --tickers NVDA --dry-run
expect_ok "the same market Chainlink-only is accepted" "NVDA   0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC" \
  $V2 --rehearse --rpc $LOCAL --registry "$(copy_with '(.markets[] | select(.ticker == "NVDA") | .v2) |= (del(.univ3Pool) | del(.univ3MinLiquidity) | del(.registeredAt) | del(.registerTx))')" --tickers NVDA --dry-run
HIGH_PPM=$(copy_with '(.markets[] | select(.ticker == "NVDA") | .v2.mintFeePpm) = 5001')
expect_refusal "a market rent rate above MINT_FEE_CEIL_PPM" "NVDA: v2.mintFeePpm 5001 is above MINT_FEE_CEIL_PPM (5000)" \
  $V2 --rehearse --rpc $LOCAL --registry "$HIGH_PPM" --tickers NVDA --dry-run
HIGH_SHARED_PPM=$(copy_with '.v2.fees.mintFeePpm = 9000')
expect_refusal "a shared rent rate above MINT_FEE_CEIL_PPM" "registry v2.fees.mintFeePpm 9000 is above MINT_FEE_CEIL_PPM (5000)" \
  $V2 --rehearse --rpc $LOCAL --registry "$HIGH_SHARED_PPM" --tickers NVDA --dry-run
PREMIUM_500=$(copy_with '.v2.fees.premiumFeeBps = 500 | .v2.fees.resaleFeeBps = 0')
expect_ok "premium 500 / resale 0 now PLANS (v8 launch fees, V8-DESIGN.md §4)" "premium 500 bps, resale 0 bps" \
  $V2 --rehearse --rpc $LOCAL --registry "$PREMIUM_500" --tickers NVDA --dry-run
# Recorded 72bae25 NVDA has v2.registeredAt; first-register dry-runs need a copy with it stripped or the
# wrapper skips NVDA (N=0) before the env checks below. PLAN is reused by later rehearsal/C3-102 cases.
PLAN=$(copy_with '(.markets[] | select(.ticker == "NVDA") | .v2.registeredAt) = null | (.markets[] | select(.ticker == "NVDA") | .v2.registerTx) = null')
expect_refusal "V2_VAULT_MAX_DAILY_OUTFLOW=0 (a vault deployed frozen)" "V2_VAULT_MAX_DAILY_OUTFLOW must be > 0" \
  env V2_VAULT_MAX_DAILY_OUTFLOW=0 $V2 --rehearse --rpc $LOCAL --registry "$PLAN" --tickers NVDA --dry-run
expect_refusal "V2_BOUNTY_CANCEL_STALE above MAX_BOUNTY" "V2_BOUNTY_CANCEL_STALE 1000001 is above MAX_BOUNTY (1000000)" \
  env V2_BOUNTY_CANCEL_STALE=1000001 $V2 --rehearse --rpc $LOCAL --registry "$PLAN" --tickers NVDA --dry-run
NONZERO_PPM=$(copy_with '(.markets[] | select(.ticker == "NVDA") | .v2.mintFeePpm) = 80 | (.markets[] | select(.ticker == "NVDA") | .v2.registeredAt) = null | (.markets[] | select(.ticker == "NVDA") | .v2.registerTx) = null')
expect_refusal "a non-zero per-market rent rate is refused at v8 launch" "NVDA: v2.mintFeePpm is 80 (non-zero)" \
  $V2 --rehearse --rpc $LOCAL --registry "$NONZERO_PPM" --tickers NVDA --dry-run

# INTERFACE_VERSION 8 inverted the rent refusals (V8-DESIGN.md §4.3): 0 is the launch value; a NON-ZERO
# rate is refused unless --allow-rent, which is --dry-run only and never with --broadcast. Absent still
# has no rate.
NO_RATE_AT_ALL=$(copy_with 'del(.v2.fees.mintFeePpm) | (.markets[] | select(.ticker == "NVDA") | .v2) |= (del(.mintFeePpm) | del(.registeredAt) | del(.registerTx))')
expect_refusal "an absent v2.fees rent block and no per-market rate" "NVDA: no collateral rent rate" \
  $V2 --rehearse --rpc $LOCAL --registry "$NO_RATE_AT_ALL" --tickers NVDA --dry-run
NULL_SHARED=$(copy_with '.v2.fees.mintFeePpm = null | (.markets[] | select(.ticker == "NVDA") | .v2) |= (del(.mintFeePpm) | del(.registeredAt) | del(.registerTx))')
expect_refusal "an absent per-market rate with a null shared fallback" "NVDA: no collateral rent rate" \
  $V2 --rehearse --rpc $LOCAL --registry "$NULL_SHARED" --tickers NVDA --dry-run
ZERO_PPM=$(copy_with '(.markets[] | select(.ticker == "NVDA") | .v2.mintFeePpm) = 0 | (.markets[] | select(.ticker == "NVDA") | .v2.registeredAt) = null | (.markets[] | select(.ticker == "NVDA") | .v2.registerTx) = null')
expect_ok "an explicit per-market rent rate of 0 PLANS" "PPM" \
  $V2 --rehearse --rpc $LOCAL --registry "$ZERO_PPM" --tickers NVDA --dry-run
ZERO_SHARED=$(copy_with '.v2.fees.mintFeePpm = 0 | (.markets[] | select(.ticker == "NVDA") | .v2) |= (del(.mintFeePpm) | del(.registeredAt) | del(.registerTx))')
expect_ok "an explicit shared rent rate of 0 with no per-market rate PLANS" "PPM" \
  $V2 --rehearse --rpc $LOCAL --registry "$ZERO_SHARED" --tickers NVDA --dry-run
expect_ok "--allow-rent lets a local fixture through at a NON-ZERO rate" "PPM" \
  $V2 --rehearse --rpc $LOCAL --registry "$NONZERO_PPM" --tickers NVDA --allow-rent --dry-run
expect_refusal "--allow-rent with --broadcast" "--allow-rent is refused with --broadcast" \
  env DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$NONZERO_PPM" --tickers NVDA --allow-rent --dry-run

# THE OPT-IN IS A TEST-ONLY CODE PATH (codex review, DECISIONS-2026-09-17 §11). The wrapper's --broadcast refusal was
# the whole guard, so a direct `forge script RegisterMarkets --rpc-url <live 4663> --broadcast` with
# V2_ALLOW_RENT exported still registered a market that charges its writers nothing, and a read-only VerifyV2 of
# live 4663 still accepted one. The scripts now honour the opt-in only under `forge test`, so the flag cannot ride
# into any run that reaches forge, and a hand-run forge script refuses whatever the environment says.
expect_refusal "--allow-rent without --dry-run (a rehearsal would reach forge)" "--allow-rent needs --dry-run" \
  $V2 --rehearse --rpc $LOCAL --registry "$ZERO_PPM" --tickers NVDA --allow-rent
expect_refusal "--allow-rent without --dry-run on --verify" "--allow-rent needs --dry-run" \
  $V2 --verify --rpc $LOCAL --registry "$ZERO_PPM" --allow-rent
# A hand-run forge script, the path the wrapper never covered. No node: RegisterMarkets.run() reads the environment
# first, so the rent refusal lands before the chain id is even checked.
#
# ADMIN_PK is anvil's public dev key #0, whose address is V2_ADMIN above, and it is here because
# RegisterMarkets.s.sol:170-178 (T-182 / F-SCRIPTS-11) refuses a run with no key and no V2_UNLOCKED_ADMIN:
# that run would broadcast by IMPERSONATING V2_ADMIN. Without it every case below stops at that refusal
# instead of the one it is named for. V2_UNLOCKED_ADMIN would also satisfy the guard, and is deliberately
# NOT used: the script's own comment says the batch sets it in --rehearse and only there, so a hand-run
# that set it would be testing the rehearsal path under a hand-run's name.
HAND_ENV=(
  ADMIN_PK=$ANVIL0_PK
  V2_ADMIN=$ANVIL0 V2_USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 V2_EXERCISE_FEE_BPS=25
  V2_TICKERS=NVDA V2_MARKET_NVDA_ASSET=0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC
  V2_MARKET_NVDA_FEED=0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15 V2_MARKET_NVDA_STRIKE_TICK=2500000
  V2_MARKET_NVDA_MAX_DEVIATION_BPS=150 V2_MARKET_NVDA_UNCORROBORATED_DELAY_S=21600
  V2_MARKET_NVDA_SPOT_MAX_AGE_S=3600
)
expect_refusal "a hand-run RegisterMarkets cannot opt in a NON-ZERO rent with V2_ALLOW_RENT" "collateral rent" \
  env "${HAND_ENV[@]}" V2_MINT_FEE_PPM=80 V2_ALLOW_RENT=true forge script script/v2/RegisterMarkets.s.sol
# RegisterMarkets treats an unset V2_MINT_FEE_PPM as 0 on the forge-script path (wrapper still refuses absent).
expect_refusal "an absent rate on a hand-run forge script reaches the chain check" "expected 4663" \
  env "${HAND_ENV[@]}" V2_ALLOW_RENT=true forge script script/v2/RegisterMarkets.s.sol
# Zero is the v8 launch rate: the same command gets past the rent refusal to the chain-id check.
expect_refusal "a hand-run at mintFeePpm 0 reaches the chain check (the refusal is not the rent one)" "expected 4663" \
  env "${HAND_ENV[@]}" V2_MINT_FEE_PPM=0 forge script script/v2/RegisterMarkets.s.sol
DONE=$(copy_with ".v2.contracts |= with_entries(if .key == \"sources\" then .value |= map_values(\"$ANVIL0\") else .value = \"$ANVIL0\" end) | .v2.flywheel.feeSplitter = \"$ANVIL0\" | .v2.flywheel.buybackExecutor = \"$ANVIL0\" | .v2.deployBlock = 1 | (.markets[] | select(.ticker == \"NVDA\") | .v2) += {registeredAt: 1789000000, registerTx: \"0x$(printf '%064d' 1)\"}")
expect_refusal "every selected market already registered" "nothing to do: the set is deployed and every selected market is registered" \
  $V2 --rehearse --rpc $LOCAL --registry "$DONE" --tickers NVDA --dry-run
# T-OP-104: the six cases below select a market outside the launch set (TSLA, AAPL, wave1) to test something
# ELSE -- the plan, a status, a payout route, the wave sources -- so each passes `--allow-off-launch`, the
# deliberate opt-out the guard exists to log. Their subjects are unchanged; the launch-set guard has its own
# cases above. Without the flag every one of them now refuses at the guard first (MEASURED: the first full
# scratch run at 564d8d66 stopped at "a rehearsal plan (dry run)" with the launch-set message).
expect_ok "a rehearsal plan (dry run)" "NVDA   0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC" \
  $V2 --rehearse --rpc $LOCAL --registry "$PLAN" --tickers NVDA,TSLA --allow-off-launch --dry-run
# v2.wave canary is NVDA; recorded 72bae25 has it registered, so strip registeredAt or N=0 before the stand-in note.
NOBOTS=$(copy_with '.v2.bots.cranker = null | .v2.bots.pricer = null | .v2.bots.quoter = null | (.markets[] | select(.ticker == "NVDA") | .v2.registeredAt) = null | (.markets[] | select(.ticker == "NVDA") | .v2.registerTx) = null')
# T-OP-038. ROTTED WHILE UNREACHABLE: this case expected the OLD note "... for null v2.bots". The
# wrapper's note is now derived from which resolved address IS the stand-in, not from which registry
# values are null (DeployV2Batch.sh:452-463, the quoter-name defect), and reads
# "rehearsal stand-ins (anvil #8/#9/#10) used for v2.bots: cranker,pricer,quoter". The wrapper is right
# and the expectation was stale -- exactly the rot T-438's suspicion 2 predicted for a truncated suite.
# The fragment now names all three stand-ins, so a lookup that silently misses one goes red here.
expect_ok "stand-in bots named in the plan" "rehearsal stand-ins (anvil #8/#9/#10) used for v2.bots: cranker,pricer,quoter" \
  $V2 --rehearse --rpc $LOCAL --registry "$NOBOTS" --wave canary --dry-run
FAKE_REG="$TMP/ops/markets/tier1.json"
mkdir -p "$(dirname "$FAKE_REG")"
cp "$REGISTRY" "$FAKE_REG"
expect_refusal "a rehearsal writing into a registry" "is a registry (ops/markets/tier1.json), not a copy" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --tickers NVDA --out "$FAKE_REG" --dry-run
expect_refusal "--resync with --deploy-only" "--resync needs --tickers or --wave" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --deploy-only --resync --dry-run
expect_refusal "--verify with --resync" "--verify takes no --deployer-pk, --out, --resume, --resync, --deploy-only or --register-only" \
  $V2 --verify --rpc $LOCAL --registry "$REGISTRY" --resync
expect_refusal "a registered market without --resync" "nothing to do: the set is deployed and every selected market is registered" \
  $V2 --rehearse --rpc $LOCAL --registry "$DONE" --tickers NVDA --dry-run
expect_ok "a registered market with --resync" "resync" \
  $V2 --rehearse --rpc $LOCAL --registry "$DONE" --tickers NVDA --resync --dry-run

echo "C3-102 staged listing (enabled = v2.status == live)"
expect_ok "planned TSLA plans as disabled" "false" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --tickers TSLA --allow-off-launch --dry-run
expect_ok "live NVDA plans as enabled" "90000  0     true" \
  $V2 --rehearse --rpc $LOCAL --registry "$PLAN" --tickers NVDA --dry-run
BADSTATUS=$(copy_with '(.markets[] | select(.ticker == "TSLA") | .v2.status) = "weird"')
expect_refusal "unknown v2.status" "v2.status 'weird' is not planned|live|paused" \
  $V2 --rehearse --rpc $LOCAL --registry "$BADSTATUS" --tickers TSLA --allow-off-launch --dry-run

echo "O8-10 registration-only / LISTING schedule / payoutRoute"
expect_refusal "--no-schedule is a raw EOA admin call" "registerMarket is a LISTING operation (1 h)" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --tickers NVDA --no-schedule --dry-run
expect_refusal "--register-only and --deploy-only" "--register-only and --deploy-only are exclusive" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --tickers NVDA --register-only --deploy-only --dry-run
expect_refusal "--register-only on a fresh set" "--register-only needs all 16 v2.contracts" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --tickers NVDA --register-only --dry-run
expect_refusal "--verify with --register-only" "--verify takes no --deployer-pk, --out, --resume, --resync, --deploy-only or --register-only" \
  $V2 --verify --rpc $LOCAL --registry "$REGISTRY" --register-only
expect_ok "--register-only live NVDA plans DISABLED" "ENABLED=false then LISTING" \
  $V2 --rehearse --rpc $LOCAL --registry "$DONE" --tickers NVDA --register-only --dry-run
expect_ok "null payoutRoute is reported, not skipped" "payoutRoute null: registered with no route, not skipped" \
  $V2 --rehearse --rpc $LOCAL --registry "$PLAN" --tickers AAPL --allow-off-launch --dry-run
# C3-102 fail-closed in RegisterMarkets (V2DeployBase.sol envOr ENABLED false). Cannot invert that
# file (outside scope); prove the default by a hand-run with ENABLED unset, and that ENABLED=true is honoured.
expect_refusal "missing V2_MARKET_<T>_ENABLED fail-closed disabled" "NVDA enabled=false" \
  env "${HAND_ENV[@]}" V2_MINT_FEE_PPM=0 forge script script/v2/RegisterMarkets.s.sol
expect_refusal "V2_MARKET_<T>_ENABLED=true is honoured" "NVDA enabled=true" \
  env "${HAND_ENV[@]}" V2_MINT_FEE_PPM=0 V2_MARKET_NVDA_ENABLED=true forge script script/v2/RegisterMarkets.s.sol
[ "$(jq -r '.targets.PayoutRouter["setRouteV4(address,uint24,int24)"]' script/v2/roles.v8.json)" = CONFIG_ADMIN ] \
  || fail "setRouteV4 is not CONFIG_ADMIN in roles.v8.json"
[ "$(jq -r '.targets.Clearinghouse["registerMarket(address,uint64,bool)"]' script/v2/roles.v8.json)" = LISTING ] \
  || fail "registerMarket is not LISTING in roles.v8.json"
[ "$(jq -r '.delaysS.LISTING' script/v2/roles.v8.json)" = 3600 ] \
  || fail "LISTING delay is not 3600"
[ "$(jq -r '.delaysS.CONFIG_ADMIN' script/v2/roles.v8.json)" = 86400 ] \
  || fail "CONFIG_ADMIN delay is not 86400"
CASES=$((CASES + 4)); printf '  ok    %-58s %s\n' "roles.v8.json LISTING/CONFIG_ADMIN pins" "registerMarket LISTING 3600 / setRouteV4 CONFIG_ADMIN 86400"
BAD_ROLES="$TMP/roles.v8.listing-route.json"
jq '.targets.PayoutRouter["setRouteV4(address,uint24,int24)"] = "LISTING"' script/v2/roles.v8.json > "$BAD_ROLES"
expect_refusal "setRouteV4 mapped to LISTING (wrong lane)" "LISTING-lane route is refused" \
  env ROLES_JSON="$BAD_ROLES" $V2 --rehearse --rpc $LOCAL --registry "$DONE" --tickers NVDA --register-only --dry-run
# prove-by-breaking the pin: restore is the real file, which the previous pin cases already greened.
# --no-schedule is refused for what the run would DO, not merely for existing: a run with markets
# registers or lists (delayed lanes), a deploy-only run predates the handover and accepts it.
expect_ok "--no-schedule on --deploy-only is accepted (nothing delayed yet)" "0 market(s) to register" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --deploy-only --no-schedule --dry-run
# The launch set has two sources in the registry schema (top-level waves, and markets[].v2.wave). The
# production file populates only the first and the v8 fixture only the second, so both are read; a
# file that populates both and disagrees is a registry with two answers for what launches.
WAVE_SPLIT=$(copy_with '.waves.wave1 = (.waves.wave1 - ["TSLA"])')
expect_refusal "the two wave sources disagree" "fix the registry, a launch set cannot have two answers" \
  $V2 --rehearse --rpc $LOCAL --registry "$WAVE_SPLIT" --wave wave1 --allow-off-launch --dry-run
expect_ok "the two wave sources agree" "TICKER" \
  $V2 --rehearse --rpc $LOCAL --registry "$PLAN" --wave wave1 --allow-off-launch --dry-run

echo "DeployV2Batch.sh write-back: the flywheel pair is recorded at v2.flywheel (T-430)"
# The mined step and the contracts write-back, LIFTED OUT OF THE WRAPPER AND RUN AS THEY ARE (a copy of their logic
# would prove only that two copies agree), against a copy of fixtures/registry-v8.json and a deploy-addresses file in
# DeployV8.s.sol toJson's shape: the registry's v2.contracts keys (sources nested) plus a top-level flywheel OBJECT.
# `cast` is a stub on PATH that answers codesize offline and, like the real one, rejects a non-address, so the old
# "[object Object]" death reproduces here. No node, rpc or key. The fixture is used whatever --registry says: the
# write-back needs a registry whose slots are still empty.
FW=$(mktemp -d "$TMP/flywheel.XXXXXX")
FIXTURE="$ROOT/script/v2/fixtures/registry-v8.json"
mkdir -p "$FW/bin"
cat > "$FW/bin/cast" <<'STUB'
#!/usr/bin/env bash
# cast codesize <address> --rpc-url <rpc>, offline: $DEAD_ADDRESS has no code, every other address has some.
[ "$1" = codesize ] || { echo "stub cast: only codesize" >&2; exit 2; }
[[ "$2" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "Error: invalid address \"$2\"" >&2; exit 1; }
if [ "$2" = "${DEAD_ADDRESS:-}" ]; then echo 0; else echo 42; fi
STUB
chmod +x "$FW/bin/cast"
# Every slot gets a DISTINCT address, so a pair written to the wrong place or swapped is visible.
jq 'def addr(i): "0x" + (("0000000000000000000000000000000000000000" + (i | tostring)) | .[-40:]);
    (.v2.contracts + {flywheel: (.v2.flywheel | del(.deployBlock))}) as $d
    | reduce ([$d | paths(type != "object")] | to_entries[]) as $e ($d; setpath($e.value; addr($e.key + 1)))' \
  "$FIXTURE" > "$FW/deploy-addresses.json"
FEE=$(jq -r '.flywheel.feeSplitter' "$FW/deploy-addresses.json")
BUY=$(jq -r '.flywheel.buybackExecutor' "$FW/deploy-addresses.json")
[ "$FEE" != null ] && [ "$BUY" != null ] || fail "the toJson-shaped fixture has no flywheel pair: $FIXTURE has no v2.flywheel block"
# T-OP-113: contract_of() and CONTRACT_KEYS moved into the shared projection, script/v2/lib/registry-env.sh
# (the wrapper sources it); mined_addresses and write_back stay in the wrapper.
LIB=script/v2/lib/registry-env.sh
eval "$(sed -n '/^mined_addresses() {/,/^}/p' "$V2")"
eval "$(sed -n '/^write_back() {/,/^}/p' "$V2")"
eval "$(sed -n '/^contract_of() {/,/^}/p' "$LIB")"
eval "$(grep '^CONTRACT_KEYS=' "$LIB")"
for f in mined_addresses write_back; do declare -F $f >/dev/null || fail "$f() not found in $V2"; done
declare -F contract_of >/dev/null || fail "contract_of() not found in $LIB"
[ -n "${CONTRACT_KEYS:-}" ] || fail "CONTRACT_KEYS not found in $LIB"
# Each runs in a subshell: PATH, DEAD_ADDRESS, WRITE_TARGET and the wrapper's die stay out of this script.
mined_offline() { ( export PATH="$FW/bin:$PATH" DEAD_ADDRESS="${DEAD:-}"; mined_addresses "$1" http://stub.invalid ); }
write_back_into() { ( WRITE_TARGET=$1; shift; die() { echo "BATCH FAILED: $*" >&2; exit 1; }; write_back "$@" ); }
fresh_registry() { local r; r=$(mktemp "$FW/tier1.XXXXXX"); jq "${1:-.}" "$FIXTURE" > "$r"; echo "$r"; }

# The mined step walks the flywheel object member by member instead of handing it to cast whole.
cp "$FW/deploy-addresses.json" "$FW/all-live.json"
out=$(mined_offline "$FW/all-live.json" 2>&1) || { echo "$out" | tail -5; fail "the mined step died on a toJson-shaped file: the flywheel object must be checked member by member"; }
[ "$(jq -r '.flywheel.feeSplitter + " " + .flywheel.buybackExecutor' "$FW/all-live.json.mined.json")" = "$FEE $BUY" ] \
  || fail "the mined step lost a live flywheel address: $(jq -c '.flywheel' "$FW/all-live.json.mined.json")"
CASES=$((CASES + 1)); printf '  ok    %-58s %s\n' "mined step, every address live" "flywheel pair kept"
# ...and nulls a dead member ON ITS OWN, the way it treats a source.
cp "$FW/deploy-addresses.json" "$FW/dead-buyback.json"
DEAD=$BUY mined_offline "$FW/dead-buyback.json" >/dev/null 2>&1 || fail "the mined step died with one dead flywheel address"
[ "$(jq -c '.flywheel' "$FW/dead-buyback.json.mined.json")" = "{\"feeSplitter\":\"$FEE\",\"buybackExecutor\":null}" ] \
  || fail "a dead buybackExecutor must be nulled alone: $(jq -c '.flywheel' "$FW/dead-buyback.json.mined.json")"
CASES=$((CASES + 1)); printf '  ok    %-58s %s\n' "mined step, buybackExecutor has no code" "nulled alone, feeSplitter kept"

# THE PROTECTED FACT: the write-back puts the pair at v2.flywheel, fills every v2.contracts slot, and writes nothing at
# v2.contracts.flywheel.
REG=$(fresh_registry)
out=$(write_back_into "$REG" contracts "$FW/all-live.json.mined.json" 123 2>&1) || { echo "$out" | tail -5; fail "the write-back refused a toJson-shaped record"; }
got=$(jq -r '"\(.v2.flywheel.feeSplitter) \(.v2.flywheel.buybackExecutor) \(.v2.contracts | has("flywheel")) \([.v2.contracts | paths(type == "null")] | length)"' "$REG")
[ "$got" = "$FEE $BUY false 0" ] \
  || fail "write-back: want v2.flywheel = $FEE $BUY, no v2.contracts.flywheel, no empty v2.contracts slot; got v2.flywheel $(jq -c '.v2.flywheel' "$REG"), v2.contracts.flywheel $(jq -c '.v2.contracts.flywheel' "$REG")"
CASES=$((CASES + 1)); printf '  ok    %-58s %s\n' "write-back of a toJson-shaped record" "pair at v2.flywheel, none at v2.contracts.flywheel"
# ...and the wrapper's own reader now finds the whole recorded set in what its writer wrote.
n=$( jqr() { jq -r "$1" "$REG"; }; c=0; for k in $CONTRACT_KEYS; do [ -z "$(contract_of "$k")" ] || c=$((c + 1)); done; echo $c )
[ "$n" = "$(printf '%s\n' $CONTRACT_KEYS | wc -l | tr -d ' ')" ] || fail "contract_of reads $n of the CONTRACT_KEYS set back from the write-back"
CASES=$((CASES + 1)); printf '  ok    %-58s %s\n' "contract_of reads the write-back" "$n of $n recorded"

# The refuse-to-overwrite rule applies inside v2.flywheel too, and names the path.
REG=$(fresh_registry '.v2.flywheel.feeSplitter = "0x00000000000000000000000000000000000000ff"')
expect_refusal "a different feeSplitter already recorded" "v2.flywheel.feeSplitter is 0x00000000000000000000000000000000000000ff in the registry" \
  write_back_into "$REG" contracts "$FW/all-live.json.mined.json" 123
# An object-valued key that is not a known group is refused by both steps, not filed under v2.contracts.
jq '. + {lending: {pool: "0x00000000000000000000000000000000000000ee"}}' "$FW/deploy-addresses.json" > "$FW/new-group.json"
expect_refusal "mined step, an unknown object key" "lending is neither an address nor a known group" \
  mined_offline "$FW/new-group.json"
expect_refusal "write-back, an unknown object key" "v2.contracts.lending: the run says" \
  write_back_into "$(fresh_registry)" contracts "$FW/new-group.json" 123

echo "DeployV2Batch.sh write-back record (T-472: V2_DEPLOY_RECORD_OUT is set, and a missing record is refused)"
# The record is the `--deployment <file>` of callhouse ops/markets/write-back-v8.mjs and the only source of
# v2.flywheel.deployBlock, safes, wallets and bots. Before T-472 the batch set V2_DEPLOY_OUT and nothing
# else, so DeployV8.s.sol wrote no record, the registry kept a null v2.flywheel.deployBlock and
# build-markets.mjs refused it -- after the deploy. The refusal below is what makes that a pre-deploy fact.
#
# THE STRUCTURAL FACT FIRST: that the deploy phase sets the variable at all. This is a source assertion, not
# a behavioural one, because the export only happens in a run that broadcasts; it is here because it is the
# exact thing that was missing, and a refusal that is never reached protects nothing.
grep -qE '^ *export V2_DEPLOY_RECORD_OUT="\$LOGDIR/deploy-record\.json"$' "$V2" \
  || fail "the deploy phase of $V2 does not export V2_DEPLOY_RECORD_OUT: DeployV8.s.sol writes no record without it"
grep -qF 'rm -f "$V2_DEPLOY_OUT" "$V2_DEPLOY_RECORD_OUT"' "$V2" \
  || fail "$V2 does not clear the record path before the run: a stale record from an earlier run would pass the check below"
grep -qF 'require_deploy_record "$LOGDIR/deploy-record.json"' "$V2" \
  || fail "$V2 never calls require_deploy_record: the record is written but never checked"
CASES=$((CASES + 1)); printf '  ok    %-58s %s\n' "the deploy phase sets, clears and checks the record" "V2_DEPLOY_RECORD_OUT"
# ...then the refusal itself, LIFTED OUT OF THE WRAPPER and run as it is (the same way the write-back cases
# above do it: a copy of its logic would prove only that two copies agree). No node, rpc or key -- the
# record is a file and the check is jq.
eval "$(sed -n '/^require_deploy_record() {/,/^}/p' "$V2")"
declare -F require_deploy_record >/dev/null || fail "require_deploy_record() not found in $V2"
REC=$(mktemp -d "$TMP/record.XXXXXX")
# Each runs in a subshell so the wrapper's `die` stays out of this script, as write_back_into does above.
record_case() { ( die() { echo "BATCH FAILED: $*" >&2; exit 1; }; require_deploy_record "$1" && echo "record accepted" ); }
expect_refusal "no write-back record file" "DeployV8 wrote no write-back record" record_case "$REC/absent.json"
jq -n '{clearinghouse: "0x00000000000000000000000000000000000000aa", safes: {admin: null}}' > "$REC/no-block.json"
expect_refusal "a record with no top-level deployBlock" "is not an object with a top-level deployBlock" \
  record_case "$REC/no-block.json"
printf 'not json at all\n' > "$REC/malformed.json"
expect_refusal "a malformed record" "is not an object with a top-level deployBlock" record_case "$REC/malformed.json"
printf '[]\n' > "$REC/array.json"
expect_refusal "a record that is a JSON array" "is not an object with a top-level deployBlock" record_case "$REC/array.json"
# THE POSITIVE CONTROL. A resumed run records a block it cannot vouch for as JSON null, which the write-back
# skips; the key being PRESENT is the whole check. Without this case a refusal that refused everything would
# pass the four above.
jq -n '{deployBlock: null, flywheel: {deployBlock: null}, safes: {admin: "0x00000000000000000000000000000000000000ab"}}' > "$REC/null-block.json"
expect_ok "a record whose deployBlock is null (a resumed run)" "record accepted" record_case "$REC/null-block.json"
jq -n '{deployBlock: 1234, flywheel: {deployBlock: 1230}}' > "$REC/full.json"
expect_ok "a record with a real deployBlock" "record accepted" record_case "$REC/full.json"

echo "DeployV2Batch.sh write-back: the registerMarket recorder (script/v2/lib/register-tx.sh)"
# The recorder matches raw calldata by selector, so a signature that drifts from the compiled ABI finds nothing
# and every registration silently falls through to scanning the Clearinghouse's logs. These cases need no node:
# `cast sig`, `cast abi-encode` and `cast calldata` are offline, and the forge record is synthetic.
# shellcheck source=script/v2/lib/register-tx.sh
. "$ROOT/script/v2/lib/register-tx.sh"
ART=out/Clearinghouse.sol/Clearinghouse.json
[ -f "$ART" ] || fail "no $ART: run forge build first"
ABI_SIG=$(register_abi_sig "$ART")
[ -n "$ABI_SIG" ] || fail "no registerMarket in $ART's ABI"
[ "$REGISTER_SIG" = "$ABI_SIG" ] \
  || fail "REGISTER_SIG is \"$REGISTER_SIG\", the compiled ABI is \"$ABI_SIG\": the write-back would never find a registration"
CASES=$((CASES + 1)); printf '  ok    %-58s %s\n' "REGISTER_SIG is the compiled signature" "$ABI_SIG"

CH=0x53d7A6d0489Daf3d67b9A314e0eAB2B78Acab9C6
ASSET=0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC   # NVDA
OTHER=0x322F0929c4625eD5bAd873c95208D54E1c003b2d   # TSLA
ORACLE=0xEb82c3D0F89d47453F94f0C2b2a2752e27a19d9b
HASH=0x1111111111111111111111111111111111111111111111111111111111111111
V6_SIG="registerMarket(address,(bool,bool,uint64,uint16,address,uint32))"
RECORDS=0
run_record() { # <calldata> <receipt status> -> the path of a synthetic forge run-latest.json in $TMP
  local file; RECORDS=$((RECORDS + 1)); file="$TMP/run-latest-$RECORDS.json"
  node -e '
    const [file, data, status, hash, to] = process.argv.slice(1);
    require("fs").writeFileSync(file, JSON.stringify({
      transactions: [
        // a wiring call to the same contract first: the lookup must pick the registerMarket one, not the first row
        { hash: "0x" + "9".repeat(64), transaction: { to, input: "0x2f2ff15d" + "0".repeat(128) } },
        { hash, transaction: { to, input: data } }
      ],
      receipts: [
        { transactionHash: "0x" + "9".repeat(64), status: "0x1", blockNumber: "0x3e7" },
        { transactionHash: hash, status, blockNumber: "0x4d2" }
      ]
    }, null, 2));
  ' "$file" "$1" "$2" "$HASH" "$CH"
  [ -s "$file" ] || fail "could not write the synthetic forge record $file"
  echo "$file"
}
V7_CALL=$(cast calldata "$REGISTER_SIG" "$ASSET" 2500000 true)
V6_CALL=$(cast calldata "$V6_SIG" "$ASSET" "(true,false,2500000,25,$ORACLE,80)")
OTHER_CALL=$(cast calldata "$REGISTER_SIG" "$OTHER" 2500000 true)
recorder_case() { # <name> <expected "hash block" or empty> <run file> <asset>
  local name=$1 want=$2 got
  got=$(register_tx "$3" "$CH" "$4")
  [ "$got" = "$want" ] || fail "$name: register_tx printed \"$got\", expected \"$want\""
  CASES=$((CASES + 1)); printf '  ok    %-58s %s\n' "$name" "${want:-<falls through to the logs>}"
}
recorder_case "the recorder finds the registration transaction" "$HASH 0x4d2" "$(run_record "$V7_CALL" 0x1)" "$ASSET"
recorder_case "the same record read for another market finds nothing" "" "$(run_record "$V7_CALL" 0x1)" "$OTHER"
recorder_case "a v7-shaped registerMarket is not this registration" "" "$(run_record "$V6_CALL" 0x1)" "$ASSET"
recorder_case "another market's registration is not this one" "" "$(run_record "$OTHER_CALL" 0x1)" "$ASSET"
recorder_case "a reverted registration is not recorded" "" "$(run_record "$V7_CALL" 0x0)" "$ASSET"
recorder_case "a record that does not exist falls through" "" "$TMP/no-such-run.json" "$ASSET"

echo "DeployV2Batch.sh --broadcast needs a passed rehearsal of the same run"
# Recorded 72bae25 has NVDA registered and all 13 contracts recorded. These cases need a first-register NVDA
# on a fresh set so --dry-run prints `forge script script/v2/DeployV8.s.sol --broadcast` (not the wiring-check line).
READY=$(copy_with ".shared.admin = \"$ANVIL0\" | .shared.safes.admin = \"$ANVIL0\" | .v2.bots = {cranker: \"0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f\", pricer: \"0xa0Ee7A142d267C1f36714E4a8F75612F20a79720\", quoter: \"0xBcd4042DE499D14e55001CcbB24a551F3b954096\"} | (.markets[] | select(.ticker == \"NVDA\") | .v2.registeredAt) = null | (.markets[] | select(.ticker == \"NVDA\") | .v2.registerTx) = null | (.v2.contracts |= with_entries(if .key == \"sources\" then .value |= with_entries(.value = null) else .value = null end)) | .v2.flywheel.feeSplitter = null | .v2.flywheel.buybackExecutor = null | .v2.deployBlock = null")
plan_without=$(env -u EXPLORER_API_KEY DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$READY" --tickers NVDA --dry-run) \
  || fail "broadcast dry-run without explorer credential failed"
deploy_without=$(grep '^forge script script/v2/DeployV8.s.sol ' <<<"$plan_without")
grep -qF 'source verify  skipped (EXPLORER_API_KEY unset' <<<"$plan_without" \
  && [[ "$deploy_without" != *' --verify '* ]] \
  || fail "unset EXPLORER_API_KEY must skip source verification in the deploy command"
CASES=$((CASES + 1)); printf '  ok    %-58s %s\n' "no explorer credential" "source publication skipped in plan and command"
plan_with=$(env EXPLORER_API_KEY=fixture-only DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$READY" --tickers NVDA --dry-run) \
  || fail "broadcast dry-run with explorer credential failed"
deploy_with=$(grep '^forge script script/v2/DeployV8.s.sol ' <<<"$plan_with")
grep -qF 'source verify  requested (check publication separately)' <<<"$plan_with" \
  && [[ "$deploy_with" == *' --verify --verifier sourcify --chain 4663 '* ]] \
  || fail "set EXPLORER_API_KEY must request Sourcify in the deploy command"
CASES=$((CASES + 1)); printf '  ok    %-58s %s\n' "explorer credential present" "Sourcify requested in plan and command"

# Exercise the wrapper's exact forge-exit exception with synthetic receipts; this is deliberately
# stricter than checking only forge's completion marker or its receipt count.
eval "$(sed -n '/^source_publication_only_failure() {/,/^}/p' "$V2")"
declare -F source_publication_only_failure >/dev/null || fail "source-publication classifier not found"
printf -v H1 '0x%064d' 1
printf -v H2 '0x%064d' 2
jq -n --arg h1 "$H1" --arg h2 "$H2" '{transactions:[{hash:$h1},{hash:$h2}],receipts:[{transactionHash:$h1,status:"0x1"},{transactionHash:$h2,status:"0x1"}]}' > "$TMP/source-run.json"
jq '.receipts[1].status = "0x0"' "$TMP/source-run.json" > "$TMP/failed-run.json"
jq 'del(.receipts[1])' "$TMP/source-run.json" > "$TMP/missing-run.json"
jq '.receipts[1].transactionHash = .receipts[0].transactionHash' "$TMP/source-run.json" > "$TMP/duplicate-run.json"
printf '%s\n' 'ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.' 'Error: Failed to verify contract: fixture' 'Error: Not all (0 / 2) contracts were verified!' > "$TMP/source-only.log"
printf '%s\n' 'Error: Failed to verify contract: fixture' > "$TMP/no-completion.log"
printf '%s\n' 'ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.' > "$TMP/no-source-error.log"
printf '%s\n' 'ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.' 'Error: Failed to verify contract: fixture' '  Error: unrelated execution failure' > "$TMP/mixed-error.log"
classification_case() { # name expected forge-rc flags log run
  local name=$1 expected=$2 forge_rc=$3 flags=$4 log=$5 run=$6 got=reject
  VERIFY_FLAGS=$flags
  source_publication_only_failure "$forge_rc" "$log" "$run" && got=accept
  [ "$got" = "$expected" ] || fail "$name: expected $expected, got $got"
  CASES=$((CASES + 1)); printf '  ok    %-58s %s\n' "$name" "$expected"
}
classification_case "source-only forge failure after mined receipts" accept 1 --verify "$TMP/source-only.log" "$TMP/source-run.json"
classification_case "no source verification requested" reject 1 '' "$TMP/source-only.log" "$TMP/source-run.json"
classification_case "forge itself exited successfully" reject 0 --verify "$TMP/source-only.log" "$TMP/source-run.json"
classification_case "missing on-chain completion marker" reject 1 --verify "$TMP/no-completion.log" "$TMP/source-run.json"
classification_case "no source-publication error" reject 1 --verify "$TMP/no-source-error.log" "$TMP/source-run.json"
classification_case "indented unrelated error mixed in" reject 1 --verify "$TMP/mixed-error.log" "$TMP/source-run.json"
classification_case "one mined receipt failed" reject 1 --verify "$TMP/source-only.log" "$TMP/failed-run.json"
classification_case "one mined receipt missing" reject 1 --verify "$TMP/source-only.log" "$TMP/missing-run.json"
classification_case "duplicate receipt masks missing transaction" reject 1 --verify "$TMP/source-only.log" "$TMP/duplicate-run.json"

out=$(env DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$READY" --tickers NVDA 2>&1 </dev/null) && fail "broadcast without a rehearsal exited 0"
grep -qF "no passed rehearsal of this exact run in the last 24 h" <<<"$out" || { echo "$out" | tail -5; fail "no rehearsal: wrong refusal"; }
CASES=$((CASES + 1)); printf '  ok    %-58s %s\n' "no rehearsal record" "refused before any node call"
SHA=$(sed -nE 's/.*registry sha256 ([0-9a-f]{64}), fingerprint ([0-9a-f]{64}).*/\1/p' <<<"$out")
FP=$(sed -nE 's/.*registry sha256 ([0-9a-f]{64}), fingerprint ([0-9a-f]{64}).*/\2/p' <<<"$out")
[ -n "$SHA" ] && [ -n "$FP" ] || fail "the refusal did not print the registry sha256 and the fingerprint"
FAKE="broadcast/v2-batch/00000000T000000Z-refusals-$$"
mkdir -p "$FAKE"
trap 'rm -rf "$TMP" "$ROOT/$FAKE"' EXIT
record() { # passedAt markets admin -> rehearsal-passed.json in the fake log directory
  node -e 'const [f, sha, fp, at, sel, admin] = process.argv.slice(1); require("fs").writeFileSync(f, JSON.stringify({kind: "stonkhouse-v2-rehearsal", passedAt: Number(at), registrySha256: sha, fingerprint: fp, markets: sel, deployPhase: "fresh", admin}))' \
    "$FAKE/rehearsal-passed.json" "$SHA" "$FP" "$1" "$2" "$3"
}
record "$(( $(date +%s) - 90000 ))" "NVDA:register" "$ANVIL0"
expect_refusal "a rehearsal older than 24 h" "no passed rehearsal of this exact run" \
  env DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$READY" --tickers NVDA
record "$(date +%s)" "NVDA:register,TSLA:register" "$ANVIL0"
expect_refusal "a rehearsal of other markets" "no passed rehearsal of this exact run" \
  env DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$READY" --tickers NVDA
record "$(date +%s)" "NVDA:register" "0x0000000000000000000000000000000000000001"
expect_refusal "a rehearsal sent from another admin" "no passed rehearsal of this exact run" \
  env DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$READY" --tickers NVDA
record "$(date +%s)" "NVDA:register" "$ANVIL0"
expect_refusal "a matching rehearsal clears the check (then: no node)" "no RPC at $REMOTE" \
  env DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$READY" --tickers NVDA
# C3-101: the pinned deployed runtimes (script/artifacts/v2-4663, what VerifyV2 compares the live set with) are in the
# fingerprint. One byte more in a pinned file and the same record no longer clears --broadcast; the file is restored
# right after the case (and by the EXIT trap if the case dies half way).
PIN_FILE=script/artifacts/v2-4663/manifest.json
cp "$PIN_FILE" "$TMP/pinned-manifest.bak"
trap 'cp "$TMP/pinned-manifest.bak" "$ROOT/$PIN_FILE"; rm -rf "$TMP" "$ROOT/$FAKE"' EXIT
printf '\n' >> "$PIN_FILE"
expect_refusal "a rehearsal from before a pinned runtime changed" "no passed rehearsal of this exact run" \
  env DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$READY" --tickers NVDA
cp "$TMP/pinned-manifest.bak" "$PIN_FILE"
trap 'rm -rf "$TMP" "$ROOT/$FAKE"' EXIT
expect_refusal "the pinned runtime restored: the record clears again" "no RPC at $REMOTE" \
  env DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$READY" --tickers NVDA
rm -rf "$FAKE"

# ---------------------------------------------------------------- T-OP-113: one projection, two callers
# The registry -> V2_* environment is ONE table in script/v2/lib/registry-env.sh, and the launch driver
# broadcast-v8.sh loads it before each forge step instead of exporting V2_EXPECT_CHAIN_ID alone (T-OP-095
# drift item 1). These cases run the REAL driver against stub `forge`/`cast` binaries on PATH: no node, no
# key, no transaction. The stub forge prints the variables its process was handed, so what is asserted is
# what DeployV8 / VerifyV8 / RegisterMarkets would have READ -- not what the driver says it exported.
echo "broadcast-v8.sh loads the registry environment (T-OP-113)"
DRV=script/v2/broadcast-v8.sh
STUB=$(mktemp -d "$TMP/stub.XXXXXX")
cat > "$STUB/cast" <<'CAST'
#!/usr/bin/env bash
# chain-id answers offline; the checksum is a pure function and goes to the real cast.
# T-OP-167: `code <addr> --rpc-url <url>` answers offline too, SELECTIVELY -- T-OP-137's check-deploy-inputs.sh
# runs has_code() on every INPUT address when the driver hands it --rpc (step 0a), so a stub that only knew
# chain-id died there ("cast code ... failed") before the driver's first forge step. It answers NON-EMPTY for an
# address the suite's own inputs name (the registry copy and the recon beside it, STUB_KNOWN, read at call time,
# nothing typed) and 0x for any other, so has_code CAN fail: an address that reaches the check from nowhere in
# the inputs is refused `no-code`, which is the refusal the real check makes for a code-less address.
case "$1" in
  chain-id) echo 4663 ;;
  to-check-sum-address) exec "$REAL_CAST" "$@" ;;
  code)
    a=$(printf '%s' "$2" | tr 'A-F' 'a-f')
    for f in ${STUB_KNOWN//:/ }; do
      if grep -qi "\"$a\"" "$f" 2>/dev/null; then echo 0x6080604052; exit 0; fi
    done
    echo 0x ;;
  *) echo "stub cast: $*" >&2; exit 2 ;;
esac
CAST
cat > "$STUB/forge" <<'FORGE'
#!/usr/bin/env bash
# Each step prints the variables the REAL script reads with a no-default vm.env* first (V2DeployBase.sol).
case "$*" in
  *DeployV8.s.sol*) printf 'stub DeployV8 saw V2_EXPECT_CHAIN_ID=%s V2_ADMIN_SAFE=%s V2_USDG=%s V2_GUARDIAN=%s V2_TOKEN_POOL_CURRENCY1=%s V2_TICKERS=%s\n' \
      "${V2_EXPECT_CHAIN_ID-<unset>}" "${V2_ADMIN_SAFE-<unset>}" "${V2_USDG-<unset>}" "${V2_GUARDIAN-<unset>}" "${V2_TOKEN_POOL_CURRENCY1-<unset>}" "${V2_TICKERS-<unset>}" ;;
  *VerifyV8.s.sol*) printf 'stub VerifyV8 saw V2_FEE_RECIPIENT=%s V2_CLEARINGHOUSE=%s V2_TICKERS=%s V2_MARKET_NVDA_ASSET=%s\nVERIFY PASSED: 1 checks\n' \
      "${V2_FEE_RECIPIENT-<unset>}" "${V2_CLEARINGHOUSE-<unset>}" "${V2_TICKERS-<unset>}" "${V2_MARKET_NVDA_ASSET-<unset>}" ;;
  *assertFingerprint*) echo "BROADCASTV8 FINGERPRINT MATCHES" ;;
  *BroadcastV8.s.sol*) echo "BROADCASTV8 FINGERPRINT 0xabc123" ;;
  *) printf 'stub forge: %s\n' "$1" ;;
esac
FORGE
chmod +x "$STUB/cast" "$STUB/forge"
REAL_CAST=$(command -v cast) || fail "cast is not on PATH (the checksum helper needs it)"
export REAL_CAST
# STUB_KNOWN: the files whose addresses the stub cast treats as deployed (T-OP-167) -- set per case to the registry
# copy the case drives and the recon beside it, so the "deployed" set is the case's own inputs and nothing else.
stubbed() { env -u DEPLOYER_PK -u ADMIN_PK -u V2_DEPLOYER PATH="$STUB:$PATH" STUB_KNOWN="${STUB_KNOWN:-}" "$@"; }
known() { STUB_KNOWN="$1:$(dirname "$1")/v2-sources.json"; }
# A FRESH registry (every contract slot null, exactly the shipped fixture's state) with the pool key, the Safe
# and the bots filled -- what the launch registry looks like on the morning of the broadcast.
FRESH=$(copy_with ".shared.safes.admin = \"$ANVIL0\" | .shared.admin = \"$ANVIL0\" | .v2.bots.cranker = \"$ANVIL0\" | .v2.bots.pricer = \"$ANVIL0\" | .v2.bots.quoter = \"$ANVIL0\"")
known "$FRESH"
# T-OP-116 refuses a --run-dir outside ./broadcast (foundry's one read-write fs path), so the driver's run dir
# lives there, under a suite-owned name removed with the rest of the scratch at exit.
DRV_RUN="$ROOT/broadcast/batch-refusals/$$-drv-fresh"
trap 'rm -rf "$TMP" "$ROOT/broadcast/batch-refusals/$$-drv-fresh"' EXIT
# (1) THE CASE THE ROW EXISTS FOR: --from deploy on a fresh registry reaches the DeployV8 simulation with the
# projection loaded, instead of dying in vm.envAddress on the first unset variable (and, T-OP-112 #1, instead
# of dying at "0 of 16 contract addresses" before phase 1).
# RED AT 0124b58e, NOT BY THIS FILE'S SUBJECT (measured by T-OP-109, twice: the tip unmodified and with the
# T-OP-109 fixture, 122 ok then this). broadcast-v8.sh runs script/v2/check-deploy-inputs.sh before its first
# forge step (T-OP-112), and that script lifts `^CONTRACT_KEYS=` / `^EXTERNAL_KEYS=` / `^jqr()` from
# DeployV2Batch.sh by line pattern -- lines T-OP-113 moved into script/v2/lib/registry-env.sh -- so it dies
# "expected exactly one line matching ^CONTRACT_KEYS= in .../DeployV2Batch.sh, found 0" (rc 2) and the driver
# refuses. Fixing the lift is T-OP-137 (check-deploy-inputs.sh is outside this row's fence); until it lands the
# suite stops here and every case below is authored, not suite-proven, at this tip.
expect_ok "driver: --from deploy on a fresh registry reaches DeployV8 with the environment" \
  "stub DeployV8 saw V2_EXPECT_CHAIN_ID=4663 V2_ADMIN_SAFE=$ANVIL0" \
  stubbed $DRV --registry "$FRESH" --rpc http://stub.invalid --run-dir "$DRV_RUN"
expect_ok "driver: the pool key, the guardian and USDG reached DeployV8 too" \
  "V2_USDG=$(jq -r .shared.usdg "$FRESH") V2_GUARDIAN=$(jq -r .shared.guardian "$FRESH") V2_TOKEN_POOL_CURRENCY1=0xc2525b7c68b6d66dE5AABFEDC7B13314F389D5C4 V2_TICKERS=<unset>" \
  stubbed $DRV --registry "$FRESH" --rpc http://stub.invalid --run-dir "$DRV_RUN"
expect_ok "driver: a fresh registry stops before verify, naming the write-back" "stopped before verify: registry not yet written back" \
  stubbed $DRV --registry "$FRESH" --rpc http://stub.invalid --run-dir "$DRV_RUN"
# (2) The count is still required where the fingerprint needs it: --from verify on the same fresh registry.
# RE-PINNED BY T-OP-203 (a pre-existing red at 92146d17, found by running this file): since T-OP-137 the driver runs
# check-deploy-inputs.sh --recorded all BEFORE its own count for --from verify, and that check refuses every null
# recorded slot by name ("REJECT null-input .v2.contracts.clearinghouse: is null but --recorded all was given ...")
# and stops the driver with the line below. Same refusal, earlier and by path; "0 of 16 contract addresses" is now
# unreachable from a fresh registry and was never printed.
expect_refusal "driver: --from verify on a fresh registry is refused before verify (check-deploy-inputs, --recorded all)" "check-deploy-inputs refused" \
  stubbed $DRV --registry "$FRESH" --rpc http://stub.invalid --run-dir "$DRV_RUN" --from verify
# (3) THE SELECTION IS HELD TO THE LAUNCH SET by the wrapper's own guard, and this driver has no opt-out.
expect_refusal "driver: --tickers outside launchSet.markets is refused by name" "excludes 1 selected market(s): TSLA" \
  stubbed $DRV --registry "$FRESH" --rpc http://stub.invalid --run-dir "$DRV_RUN" --tickers TSLA
expect_ok "driver: the default selection is the registry's launch set" "selection from registry launchSet.markets: NVDA SPCX" \
  stubbed $DRV --registry "$FRESH" --rpc http://stub.invalid --run-dir "$DRV_RUN"
expect_ok "driver: V2_TICKERS in the environment is the selection when --tickers is absent" "selection from V2_TICKERS (environment): SPCX" \
  stubbed env V2_TICKERS=SPCX $DRV --registry "$FRESH" --rpc http://stub.invalid --run-dir "$DRV_RUN"
NO_LAUNCH=$(copy_with ".shared.safes.admin = \"$ANVIL0\" | .shared.admin = \"$ANVIL0\" | .v2.bots.cranker = \"$ANVIL0\" | .v2.bots.pricer = \"$ANVIL0\" | .v2.bots.quoter = \"$ANVIL0\" | del(.launchSet)")
expect_refusal "driver: a registry without launchSet.markets is refused (the guard has nothing to hold to)" "registry has no launchSet.markets block" \
  stubbed $DRV --registry "$NO_LAUNCH" --rpc http://stub.invalid --run-dir "$DRV_RUN"
# (4) THE PROJECTION REFUSES BEFORE ANY RPC CALL, by name, from the driver on the shipped fixture. RE-PINNED BY
# T-OP-203 (pre-existing red at 92146d17): the fixture's pool key is FILLED since T-OP-109 (this file's own header
# says so), so the first null the projection meets in the shipped fixture is v2.bots.cranker; the null-poolKey
# refusal itself is proven above from POOLKEY_NULLED. The property held here is unchanged: the refusal names a
# registry path and fires before any RPC call.
expect_refusal "driver: the projection's own refusal fires before the first RPC call" "registry v2.bots.cranker is null or absent" \
  stubbed $DRV --registry "$REGISTRY" --rpc http://stub.invalid --run-dir "$DRV_RUN"
# (5) T-OP-081 #3a. A WRITTEN-BACK registry: every slot recorded, NVDA registered, shared.feeRecipient null. The
# fee recipient reaching VerifyV8 must be the recorded v2.flywheel.feeSplitter, and the registered market's row
# and the recorded Clearinghouse must reach it too; SPCX (unregistered) is what step 3 would register.
WRITTEN=$(copy_with ".shared.safes.admin = \"$ANVIL0\" | .shared.admin = \"$ANVIL0\" | .v2.bots.cranker = \"$ANVIL0\" | .v2.bots.pricer = \"$ANVIL0\" | .v2.bots.quoter = \"$ANVIL0\"
  | def addr(i): \"0x\" + ((\"0000000000000000000000000000000000000000\" + (i | tostring)) | .[-40:]);
    reduce ([(.v2.contracts | paths(type != \"object\") | [\"v2\", \"contracts\"] + .), [\"v2\",\"flywheel\",\"feeSplitter\"], [\"v2\",\"flywheel\",\"buybackExecutor\"]] | to_entries[]) as \$e (.; setpath(\$e.value; addr(\$e.key + 1)))
  | .v2.deployBlock = 68000000 | (.markets[] | select(.ticker == \"NVDA\") | .v2.registeredAt) = 1790000000
  | .v2.contracts.hedger = null | .v2.contracts.rewardsDistributorLender = null | .v2.contracts.stockVenueAdapter = null")
# ^ T-OP-203 (pre-existing red at 92146d17): the three externals in the lib's EXTERNAL_SKIP_DEFAULT stay NULL here.
#   Since T-OP-116 the externals stage refuses a default skip whose address is already recorded ("--skip-external
#   hedger: refused, its address is already recorded at v2.contracts.hedger"), so a copy that records all sixteen
#   plus every external never reached VerifyV8 and the two cases below were red. A launch registry never carries
#   them either: nothing on the launch path deploys them (registry-env.sh EXTERNAL_SKIP_DEFAULT).
SPLITTER=$(jq -r '.v2.flywheel.feeSplitter' "$WRITTEN")
[ "$(jq -r '.shared.feeRecipient' "$WRITTEN")" = null ] || fail "the written-back copy must keep shared.feeRecipient null for this case"
known "$WRITTEN"
DRV_RUN_W="$ROOT/broadcast/batch-refusals/$$-drv-written"
trap 'rm -rf "$TMP" "$ROOT/broadcast/batch-refusals/$$-drv-fresh" "$ROOT/broadcast/batch-refusals/$$-drv-written"' EXIT
expect_ok "driver: V2_FEE_RECIPIENT reaches VerifyV8 from v2.flywheel.feeSplitter when shared.feeRecipient is null" \
  "stub VerifyV8 saw V2_FEE_RECIPIENT=$($REAL_CAST to-check-sum-address "$SPLITTER") V2_CLEARINGHOUSE=$(jq -r .v2.contracts.clearinghouse "$WRITTEN") V2_TICKERS=NVDA V2_MARKET_NVDA_ASSET=$(jq -r '.markets[] | select(.ticker == "NVDA") | .asset' "$WRITTEN")" \
  stubbed $DRV --registry "$WRITTEN" --rpc http://stub.invalid --run-dir "$DRV_RUN_W" --from verify
# RE-PINNED BY T-OP-203: T-OP-161 sends the register step AS THE DEPLOYER and the printed line carries V2_ADMIN=<deployer>.
expect_ok "driver: after the gate, the unregistered launch market is what step 3 registers" "V2_TICKERS=SPCX V2_ADMIN=<deployer> forge script script/v2/RegisterMarkets.s.sol" \
  stubbed $DRV --registry "$WRITTEN" --rpc http://stub.invalid --run-dir "$DRV_RUN_W" --from verify
# The lib function alone, for the wrapper's phase 3 (the wrapper's dry run exits before phase 3, so the hook there
# is proved through the function it calls): a non-null shared.feeRecipient wins; neither known -> unset.
fee_from() { ( STATE=$1; die() { echo "BATCH FAILED: $*" >&2; exit 1; }; . "$LIB"; registry_env_fee_recipient_from_splitter; echo "V2_FEE_RECIPIENT=${V2_FEE_RECIPIENT-<unset>}" ); }
expect_ok "registry_env_fee_recipient_from_splitter: the recorded splitter when shared.feeRecipient is null" \
  "V2_FEE_RECIPIENT=$($REAL_CAST to-check-sum-address "$SPLITTER")" fee_from "$WRITTEN"
PINNED_FEE=$(copy_with ".shared.feeRecipient = \"$ANVIL0\" | .v2.flywheel.feeSplitter = \"$SPLITTER\"")
expect_ok "registry_env_fee_recipient_from_splitter: a non-null shared.feeRecipient wins over the splitter" \
  "V2_FEE_RECIPIENT=$ANVIL0" fee_from "$PINNED_FEE"
expect_ok "registry_env_fee_recipient_from_splitter: neither known leaves it unset (a fresh registry before deploy)" \
  "V2_FEE_RECIPIENT=<unset>" fee_from "$FRESH"
# (6) ONE TABLE. No caller exports a shared V2_* value itself: every `export V2_ADMIN_SAFE=` (the first line of the
# shared set) lives in the lib. A second copy of the table in either caller is the drift this row removed.
# `|| true` because a grep that (correctly) matches nothing exits 1, and under pipefail that would end the suite
# silently right here instead of counting zero -- the F-SCRIPTS-04 shape, on the green path.
n=$({ grep -l 'export V2_ADMIN_SAFE=' script/v2/DeployV2Batch.sh script/v2/broadcast-v8.sh 2>/dev/null || true; } | wc -l | tr -d ' ')
[ "$n" = 0 ] || fail "a caller exports the shared set itself ($n file(s) carry 'export V2_ADMIN_SAFE='): the projection must stay in $LIB alone"
grep -q 'export V2_ADMIN_SAFE=' "$LIB" || fail "$LIB does not export V2_ADMIN_SAFE: the shared set is not where the callers load it from"
for f in $V2 $DRV; do grep -q 'lib/registry-env.sh' "$f" || fail "$f does not source $LIB"; done
CASES=$((CASES + 1)); printf '  ok    %-58s %s\n' "one projection: both callers source the lib, neither exports the set" "lib=$LIB"

# ---------------------------------------------------------------- T-OP-203: tonight's four launch-day fixes, pinned
# Four fixes landed on the night of 2026-09-22 with no case in this file, so each could regress silently. Each
# gets a positive control and a negative control against the OBSERVABLE (the forge process's environment, the
# check's exit code and printed line, the exported variable, the refusal text), never against the lib's internals.
# The lib functions are called through the same subshell shape fee_from() uses above: `die` supplied by the
# caller, STATE the case's own registry copy, the lib sourced fresh.
echo "T-OP-203: externals env scrub (T-OP-181/188), the wallet class (T-OP-187), the vault re-export (T-OP-198), the principal rule (T-OP-188)"
# (a) externals_forge runs forge WITHOUT V2_SCHEDULE / V2_SCHEDULE_PHASE / V2_UNLOCKED_ADMIN, whatever the caller's
#     environment carries (T-OP-181/188: a rehearsal's schedule-phase variables leaked into pass A/B and the externals
#     took the Safe path). The stub forge here DIES if any of the three reaches it and prints what it saw either way,
#     so the positive control cannot pass by printing nothing. The negative control runs the same stub without the
#     lib in between: the three leak, the stub dies by name -- proof the stub can fail.
SCRUB=$(mktemp -d "$TMP/scrub.XXXXXX")
cat > "$SCRUB/forge" <<'FORGE'
#!/usr/bin/env bash
for v in V2_SCHEDULE V2_SCHEDULE_PHASE V2_UNLOCKED_ADMIN; do
  eval "x=\${$v-<unset>}"
  [ "$x" = "<unset>" ] || { echo "stub forge: $v=$x leaked into the externals forge environment"; exit 3; }
done
printf 'stub forge saw V2_SCHEDULE=<unset> V2_SCHEDULE_PHASE=<unset> V2_UNLOCKED_ADMIN=<unset> V2_EXPECT_CHAIN_ID=%s\n' "${V2_EXPECT_CHAIN_ID-<unset>}"
FORGE
chmod +x "$SCRUB/forge"
# externals_forge through the lib: EXECUTE=0 with a deployer known takes the simulate branch (env -u ... forge script);
# the log it writes is the observable. The three variables are SET in this caller's environment on purpose.
# The lib is sourced BEFORE the three are exported: it validates V2_SCHEDULE_PHASE at source time ("is not a resume
# phase this script accepts") and would refuse the case's own setup. The driver sets them later, per step, which is
# the leak this case pins; so does the case.
ext_forge_scrubbed() { ( EXECUTE=0 V2_DEPLOYER=$ANVIL0 CHAIN_EXPECT=4663 RPC=http://stub.invalid EXT_DEPLOY_FLAGS=""
  die() { echo "BATCH FAILED: $*" >&2; exit 1; }; . "$LIB"
  export V2_SCHEDULE=1 V2_SCHEDULE_PHASE=schedule V2_UNLOCKED_ADMIN=true PATH="$SCRUB:$PATH"
  externals_forge "$TMP/scrub.log" script/v2/DeployHouseVault.s.sol; cat "$TMP/scrub.log" ) }
expect_ok "externals_forge: V2_SCHEDULE/PHASE/UNLOCKED_ADMIN never reach forge (T-OP-181/188)" \
  "stub forge saw V2_SCHEDULE=<unset> V2_SCHEDULE_PHASE=<unset> V2_UNLOCKED_ADMIN=<unset> V2_EXPECT_CHAIN_ID=4663" ext_forge_scrubbed
expect_refusal "externals_forge negative control: the same stub without the scrub dies by name" \
  "stub forge: V2_SCHEDULE=1 leaked into the externals forge environment" \
  env V2_SCHEDULE=1 V2_SCHEDULE_PHASE=schedule V2_UNLOCKED_ADMIN=true PATH="$SCRUB:$PATH" forge script script/v2/DeployHouseVault.s.sol
# (b) check-deploy-inputs --rpc: an address that is a KEY BY DESIGN (shared.guardian, the bots) is accepted with no
#     code -- printed as the WALLET class -- while a code-less CONTRACT path is still refused no-code (T-OP-187: the
#     real guardian is an EOA and step 0a died on it). The suite's stub cast answers `code` from STUB_KNOWN, so the
#     "deployed" set is a case-local address LIST: every address the written-back copy and its recon carry, MINUS
#     the guardian (positive), or minus the recorded clearinghouse (negative). Nothing typed: both lists are derived.
CDI=script/v2/check-deploy-inputs.sh
KNOWN_ALL="$TMP/known-all.json"
jq -c '[.. | strings | select(test("^0x[0-9a-fA-F]{40}$"))]' "$WRITTEN" "$(dirname "$WRITTEN")/v2-sources.json" | jq -sc 'add | unique' > "$KNOWN_ALL"
W_GUARDIAN=$(jq -r '.shared.guardian' "$WRITTEN"); W_CH=$(jq -r '.v2.contracts.clearinghouse' "$WRITTEN")
jq -c --arg g "$W_GUARDIAN" '[.[] | select(ascii_downcase != ($g | ascii_downcase))]' "$KNOWN_ALL" > "$TMP/known-no-guardian.json"
jq -c --arg c "$W_CH" '[.[] | select(ascii_downcase != ($c | ascii_downcase))]' "$KNOWN_ALL" > "$TMP/known-no-clearinghouse.json"
[ "$(jq length "$TMP/known-no-guardian.json")" = "$(( $(jq length "$KNOWN_ALL") - 1 ))" ] || fail "the guardian $W_GUARDIAN is not in the written-back copy's address set: the wallet case has no subject"
expect_ok "check-deploy-inputs --rpc: a code-less guardian passes as WALLET (T-OP-187)" \
  "INPUT      ok       .shared.guardian = $W_GUARDIAN  (WALLET: a key by design, no code expected)" \
  stubbed env STUB_KNOWN="$TMP/known-no-guardian.json" $CDI --registry "$WRITTEN" --sources "$(dirname "$WRITTEN")/v2-sources.json" --mode rehearse --recorded any --rpc http://stub.invalid
expect_refusal "check-deploy-inputs --rpc: a code-less recorded contract is still refused no-code" \
  "REJECT no-code .v2.contracts.clearinghouse: '$W_CH' holds no code on http://stub.invalid" \
  stubbed env STUB_KNOWN="$TMP/known-no-clearinghouse.json" $CDI --registry "$WRITTEN" --sources "$(dirname "$WRITTEN")/v2-sources.json" --mode rehearse --recorded any --rpc http://stub.invalid
# (c) after the per-ticker write-back, externals_reexport_house_vaults exports V2_MARKET_<T>_HOUSE_VAULT for every
#     launch ticker FROM STATE (T-OP-198: the final MapExternals pass inherited the pre-pass-B environment and SPCX's
#     vault stayed unmapped). Positive: both vaults recorded -> both exported, EIP-55, from the file. Negative: SPCX
#     still null AND a STALE value pre-exported in the caller's environment -> the re-export UNSETS it and says
#     pending; a re-export that merely added would leave the stale value in place, which is the run-4c shape.
HV_NVDA=0x00000000000000000000000000000000000000A1; HV_SPCX=0x00000000000000000000000000000000000000B2
BOTH_VAULTS=$(copy_with "(.markets[] | select(.ticker == \"NVDA\") | .v2.houseVault) = \"$HV_NVDA\" | (.markets[] | select(.ticker == \"SPCX\") | .v2.houseVault) = \"$HV_SPCX\"")
ONE_VAULT=$(copy_with "(.markets[] | select(.ticker == \"NVDA\") | .v2.houseVault) = \"$HV_NVDA\" | (.markets[] | select(.ticker == \"SPCX\") | .v2.houseVault) = null")
reexport_from() { ( STATE=$1; export V2_TICKERS=NVDA,SPCX; [ -z "${2:-}" ] || export "V2_MARKET_SPCX_HOUSE_VAULT=$2"
  die() { echo "BATCH FAILED: $*" >&2; exit 1; }; . "$LIB"
  externals_reexport_house_vaults
  echo "NVDA=${V2_MARKET_NVDA_HOUSE_VAULT-<unset>} SPCX=${V2_MARKET_SPCX_HOUSE_VAULT-<unset>}" ) }
expect_ok "externals_reexport_house_vaults: every launch ticker's vault is exported from STATE (T-OP-198)" \
  "NVDA=$($REAL_CAST to-check-sum-address $HV_NVDA) SPCX=$($REAL_CAST to-check-sum-address $HV_SPCX)" reexport_from "$BOTH_VAULTS"
expect_ok "externals_reexport_house_vaults: a stale pre-exported value is UNSET when the vault is still null" \
  "NVDA=$($REAL_CAST to-check-sum-address $HV_NVDA) SPCX=<unset>" reexport_from "$ONE_VAULT" "$HV_SPCX"
# (d) the deployer-principal rule ignores shared.admin (the fixture's shared.admin is anvil #0, the rehearsal deployer;
#     T-OP-181/T-OP-174) but still refuses shared.safes.admin (T-OP-188). Positive: deployer == shared.admin, Safe
#     elsewhere -> accepted. Negative: deployer == shared.safes.admin -> refused naming both sides.
PH_SAFE=$(jq -r '.shared.safes.admin' "$REGISTRY")
ADMIN_ONLY=$(copy_with ".shared.admin = \"$ANVIL0\" | .shared.safes.admin = \"$PH_SAFE\"")
SAFE_IS_DEPLOYER=$(copy_with ".shared.admin = \"$PH_SAFE\" | .shared.safes.admin = \"$ANVIL0\"")
principal_check() { ( STATE=$1; die() { echo "BATCH FAILED: $*" >&2; exit 1; }; . "$LIB"
  registry_env_refuse_deployer_is_principal "$ANVIL0" && echo "deployer $ANVIL0 accepted against $STATE" ) }
expect_ok "deployer-principal rule: a deployer equal to shared.admin is accepted (T-OP-181/188)" \
  "deployer $ANVIL0 accepted against" principal_check "$ADMIN_ONLY"
expect_refusal "deployer-principal rule: a deployer equal to shared.safes.admin is still refused by name" \
  "the deployer $ANVIL0 IS the registry's shared.safes.admin" principal_check "$SAFE_IS_DEPLOYER"

# ---------------------------------------------------------------- T-OP-110: the Safe on the fork must be a Safe
# The two cases below are the only ones in this file whose subject IS a node: what the wrapper and DeployV8 do
# with the code at shared.safes.admin on a fork of 4663. They run only when FORK_RPC names an anvil fork of 4663
#     FORK_RPC=http://127.0.0.1:8553 script/v2/batch-refusals.sh
# and are printed as SKIPPED and left uncounted otherwise: a case that cannot run says so; it never reads green.
# Both strings were proven by invocation on a fork before they were pinned here (T-OP-110's ledger entry names
# the endpoint and the fork block). THE FORK IS MUTATED at the fixture's two placeholder Safe addresses, which
# must be code-less on it: inert code is planted for the second case and cleared again after it. Nothing else
# on the fork is touched -- the wrapper refuses before forge in the first case, and in the second DeployV8
# refuses inside forge's SIMULATION, so no transaction is sent (T-OP-081 run 2A: "0 transactions sent").
if [ -z "${FORK_RPC:-}" ]; then
  printf '  skip  %-58s %s\n' "code-less Safe on the fork: the wrapper refuses, plants nothing" "(FORK_RPC unset: needs an anvil fork of 4663)"
  printf '  skip  %-58s %s\n' "non-Safe contract at shared.safes.admin: DeployV8 probe refuses" "(FORK_RPC unset: needs an anvil fork of 4663)"
else
  cid=$(cast chain-id --rpc-url "$FORK_RPC" 2>/dev/null || true)
  [ "$cid" = 4663 ] || fail "FORK_RPC $FORK_RPC does not answer as chain 4663 (got '$cid')"
  case "$(cast rpc web3_clientVersion --rpc-url "$FORK_RPC" 2>/dev/null || echo '""')" in '"anvil/'*) ;; *) fail "FORK_RPC $FORK_RPC is not anvil" ;; esac
  # The placeholder Safes come from the fixture, not from --registry: a caller pointing this file at a registry
  # whose Safes are REAL must not have inert code planted over them.
  FIXTURE_REG="$ROOT/script/v2/fixtures/registry-v8.json"
  PH_ADMIN=$(jq -r '.shared.safes.admin' "$FIXTURE_REG"); PH_TREASURY=$(jq -r '.shared.safes.treasury' "$FIXTURE_REG")
  for a in "$PH_ADMIN" "$PH_TREASURY"; do
    [ "$(cast code "$a" --rpc-url "$FORK_RPC")" = 0x ] || fail "placeholder Safe $a already has code on $FORK_RPC; these cases need it code-less (a previous run left it planted?)"
  done
  # The fixture's own bots are null (anvil stand-ins #8/#9/#10 fill them in --rehearse); shared.admin is anvil #0,
  # which is also the rehearsal deployer, so the wrapper's seven-principal rule needs safes.admin to be the Safe.
  PLACEHOLDER_SAFES=$(copy_with ".shared.safes.admin = \"$PH_ADMIN\" | .shared.safes.treasury = \"$PH_TREASURY\"")
  # (1) the wrapper: a code-less Safe is refused BEFORE any forge step, and no stand-in code is planted.
  expect_refusal "code-less Safe on the fork: the wrapper refuses, plants nothing" \
    "V2_ADMIN_SAFE $PH_ADMIN has no code on the fork: a rehearsal needs a genuine Safe there" \
    env -u DEPLOYER_PK -u ADMIN_PK $V2 --rehearse --rpc "$FORK_RPC" --registry "$PLACEHOLDER_SAFES" --sources "$(dirname "$PLACEHOLDER_SAFES")/v2-sources.json" --deploy-only --out "$TMP/fork-1.json"
  [ "$(cast code "$PH_ADMIN" --rpc-url "$FORK_RPC")" = 0x ] || fail "the wrapper planted code at $PH_ADMIN: the stand-in path is back"
  # (2) DeployV8's probe: a NON-SAFE CONTRACT at shared.safes.admin (the inert 0x60008080fd the wrapper used to
  # plant, PUSH1 0 DUP1 REVERT) passes the wrapper's code check and is refused by _assertAdminSafeIsARealSafe
  # in simulation, naming the empty singleton slot. Planted at both placeholders so the treasury's code check
  # (DeployV8 _principals) is not what stops the run.
  for a in "$PH_ADMIN" "$PH_TREASURY"; do cast rpc anvil_setCode "$a" 0x60008080fd --rpc-url "$FORK_RPC" >/dev/null; done
  expect_refusal "non-Safe contract at shared.safes.admin: DeployV8 probe refuses" \
    "REFUSING TO RENOUNCE ADMIN: the Admin Safe $PH_ADMIN has code but its singleton slot holds 0x0000000000000000000000000000000000000000, which is not a canonical Safe 1.4.1 / 1.3.0 build" \
    env -u DEPLOYER_PK -u ADMIN_PK $V2 --rehearse --rpc "$FORK_RPC" --registry "$PLACEHOLDER_SAFES" --sources "$(dirname "$PLACEHOLDER_SAFES")/v2-sources.json" --deploy-only --out "$TMP/fork-2.json"
  for a in "$PH_ADMIN" "$PH_TREASURY"; do cast rpc anvil_setCode "$a" 0x --rpc-url "$FORK_RPC" >/dev/null; done
fi

printf '\nREFUSALS PASSED: %s cases\n' "$CASES"
