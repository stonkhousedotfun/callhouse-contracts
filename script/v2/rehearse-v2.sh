#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# rehearse-v2.sh — fork rehearsal of the v2 deploy: starts its own anvil fork of chain 4663, makes sure the
# registry's two Safes are GENUINE Safes on that fork (creating fork-only 2-of-3 Safes through the canonical
# SafeProxyFactory when they are not, step 0b, T-OP-110), runs script/v2/DeployV2Batch.sh --rehearse end to
# end (deploy + wire, register the markets, VerifyV8) with the write-back going to a copy of the registry,
# then VerifyV8 alone against that copy, then the drills:
#   1. a second batch run on the copy has nothing to do;
#   2. a lost pointer: VerifyV8 FAILs, the batch refuses without --resume (wiring check); --resume by the DEPLOYER
#      is REFUSED because the window is closed (it holds nothing after HandBack -- the property T-OP-161's direct
#      path must not break), the Safe repairs it through its CONFIG_ADMIN lane (schedule, 24 h, execute) and
#      VerifyV8 passes;
#   3. a lost write-back: a registered market's registeredAt/registerTx blanked in the copy is recovered from the
#      chain by re-running the batch for it, with the same values;
#   4. VerifyV8 has teeth: one byte of the Clearinghouse's runtime flipped with anvil_setCode FAILs the bytecode check.
# The real registry's sha256 is checked unchanged. Kills the anvil on exit, success or failure.
#
# THE DIRECT PATH (T-OP-161, amendment #4, owner decision 2026-09-22 05:50Z). Step 1's batch registers the launch
# set BY THE DEPLOYER, directly, inside its deferred-ADMIN window (it holds LISTING and CONFIG_ADMIN at delay 0
# until HandBack, which now runs AFTER the markets, phase 2c). So the launch set is registered with NO clock
# jump: the step-1 assertions below require every ticker's register line to say DIRECT, refuse any "node clock
# advanced" line in that log, and read back that the rehearsal deployer holds no ADMIN afterwards. A drill that
# warped the LISTING delay for the launch set would hide a regression of exactly this. The scheduled shape
# (run_forge_scheduled, rc=90, the fork's evm_increaseTime) is POST-LAUNCH only and is what REGISTER_ONLY=1
# rehearses: --deploy-only closes the window, then --register-only takes the Safe's lanes.
#
# THE EXTERNALS (T-OP-116 / T-OP-153, owner decision 2026-09-22 05:35Z). Step 1's batch runs DeployV8 with
# V2_DEFER_HANDBACK=true (it stops before its step 9; the deployer keeps ADMIN) and then the externals stage
# (script/v2/lib/registry-env.sh registry_env_externals) BEFORE the markets: houseVaultFactory + the launch
# tickers' houseVault through DeployHouseVault.s.sol (T-OP-141; pass A the factory, MapExternals, pass B
# createVault as the deployer under its transient LISTING), earnVault through DeployEarnVault.s.sol, each
# recorded at v2.contracts.<key> / v2.externalDeployBlocks.<key> in the COPY; then
# script/v2/MapExternals.s.sol maps every supplied external's selectors at delay 0, every mapping is read back,
# and script/v2/HandBack.s.sol is the deferred step 9, AFTER the markets (read back: the deployer holds no ADMIN). hedger,
# rewardsDistributorLender and stockVenueAdapter are SKIPPED by default (the owner's window) and printed as
# such. The three scripts are wired by exact name and are not at this base: the stage dies naming the missing
# file, which is the expected state until T-OP-141 / T-OP-153 land. SKIP_EXTERNAL=a,b (registry keys; `none`
# = skip nothing) passes --skip-external to every batch run.
#
#   script/v2/rehearse-v2.sh                               NVDA (two sources) + TSLA (Chainlink only) on port 8551
#   TICKERS=NVDA,AAPL,MSFT CHAINLINK_ONLY= PORT=8552 script/v2/rehearse-v2.sh
#   REGISTER_ONLY=1 script/v2/rehearse-v2.sh               deploy-only, then register the owner D5 19 DISABLED
#                                                         and list them through LISTING 1 h / CONFIG_ADMIN 24 h
#
# Environment: FORK_URL (default the public Robinhood Chain RPC), PORT (8551), TICKERS (NVDA,TSLA),
# SKIP_EXTERNAL (empty = the owner's window; `none` = skip nothing; a,b = that list; T-OP-116),
# SAFE_SALT_ADMIN / SAFE_SALT_TREASURY (the createProxyWithNonce salts of the fork-only Safes, default
# <UTC date>01 / <UTC date>02 as ops/runbooks/v8-safes.md §2 does it; only read when a Safe is created),
# CHAINLINK_ONLY (TSLA: tickers whose v2.univ3Pool is nulled in the rehearsal's INPUT copy, so the single-source
# settlement config and the no-route payout path are rehearsed too; empty = the registry as it is, which stops at
# the RegisterMarkets preflight for any pool whose observation ring holds fewer than 2,401 slots: TSLA's held 1,801 on
# 2026-09-17, sweep contracts-c10), REGISTRY
# (the batch's default), SOURCES (v2-sources.json next to it).
#
# TIME. The public RPC serves state only ~15 minutes behind its head and a fork reads unseen slots at the fork
# block (callhouse ops/devnet/up.sh), so everything runs inside that window: `forge build` first, then the anvil.
# `--code-size-limit 98304` is what chain 4663 enforces (docs/DEPLOY.md).
# -------------------------------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT=$(pwd)
export PATH="$HOME/.foundry/bin:$PATH"

FORK_URL=${FORK_URL:-https://rpc.mainnet.chain.robinhood.com}
PORT=${PORT:-8551}
# Owner D5 additions (NVDA is already live / canary and is not in this list). DERIVED, never typed:
# a ticker literal here would be a third copy of the launch set, and the two that already exist in the
# registry disagreed with each other until this task fixed them.
REGISTER_ONLY=${REGISTER_ONLY:-}
# T-OP-173 (F1): no Chainlink-only override by default -- the launch set is dual-source and the guard refuses a
# ticker outside it; CHAINLINK_ONLY=<T> still nulls that ticker's pool in the INPUT copy when asked.
CHAINLINK_ONLY=${CHAINLINK_ONLY-}
REGISTRY=${REGISTRY:-$ROOT/script/v2/fixtures/registry-v8.json}
SOURCES=${SOURCES:-$(dirname "$REGISTRY")/v2-sources.json}
RPC="http://127.0.0.1:$PORT"
BATCH=script/v2/DeployV2Batch.sh
# T-OP-116: the same skip list on EVERY batch run of this rehearsal. A skip that applied to the deploy
# run and not to the re-runs would make drill 3/4/5 refuse a key the first run left unsupplied.
SKIP_EXTERNAL=${SKIP_EXTERNAL:-}
# `${SKIP_FLAG[@]+"${SKIP_FLAG[@]}"}` at every use: an EMPTY array expanded as "${SKIP_FLAG[@]}" is an
# "unbound variable" under `set -u` in bash 3.2 (macOS /bin/bash), which this file may run under.
SKIP_FLAG=()
[ -z "$SKIP_EXTERNAL" ] || SKIP_FLAG=(--skip-external "$SKIP_EXTERNAL")

die() { echo "REHEARSAL FAILED: $*" >&2; exit 1; }
step() { printf '\n== %s  (+%ss)\n' "$*" "$(( $(date +%s) - T0 ))"; }
# T-OP-152. A VerifyV8 log is a VERDICT only if it ends in the summary line VerifyV8.run prints last --
# `VERIFY PASSED: N checks` or `VERIFY FAILED: N check(s) failed of M`. A log with neither is a VerifyV8
# that STOPPED: `forge script` aborts the whole script on certain faults (measured: an external self-call,
# "Usage of `address(this)` detected in script contract"), and the log of an aborted run looks normal up
# to the group it died in. Every drill below that reads FAIL lines out of a verify log asks this first,
# so "the tamper failed exactly one check" can never be said of a run whose later groups never ran.
require_verify_summary() {
  local log=$1 what=$2
  [ -s "$log" ] || die "$what: VerifyV8 printed nothing (log: $log)"
  grep -qE "^\s*VERIFY (PASSED|FAILED):" "$log" \
    || die "$what: VerifyV8 FAILED-INCOMPLETE -- $log ends without a 'VERIFY PASSED:' or 'VERIFY FAILED:' summary line, so VerifyV8 STOPPED before its last group ran (a forge abort, not a verdict; the $(grep -cE '^\s+FAIL' "$log" || true) FAIL line(s) it carries are not a count). Read the tail of $log for forge's error"
}
T0=$(date +%s)
for tool in anvil forge cast jq node; do command -v "$tool" >/dev/null || die "$tool not on PATH"; done
[ -f "$REGISTRY" ] || die "registry not found: $REGISTRY"
if [ -n "$REGISTER_ONLY" ]; then
  # Derived from the registry the run actually uses, after it is known to exist.
  NINETEEN=${NINETEEN:-$(jq -r '[.markets[] | select(.v2.wave == "wave1") | .ticker] | join(",")' "$REGISTRY")}
  [ -n "$NINETEEN" ] || die "no market is in wave1 in $REGISTRY"
  TICKERS=${TICKERS:-$NINETEEN}
else
  # T-OP-173 (F1): the default selection IS the registry's launch set, derived with the same expression
  # registry_env_launch_guard uses (never typed): NVDA,TSLA was refused by that guard on every default run.
  TICKERS=${TICKERS:-$(jq -r 'if (.launchSet.markets | type) == "array" then [.launchSet.markets[] | ascii_upcase] | join(",") else "" end' "$REGISTRY")}
  [ -n "$TICKERS" ] || die "no TICKERS given and $REGISTRY has no launchSet.markets block to derive the default from"
fi
[ -f "$SOURCES" ] || die "v2-sources.json not found: $SOURCES"

# T-OP-112: every registry / v2-sources path the batch reads, checked statically before the build and
# the fork clock (bash + jq only; no node, no forge). The rehearsal registry must be FRESH (no recorded
# set) and, being a rehearsal, may carry null v2.bots (anvil stand-ins). EIP-55 is checked with cast,
# which the tool loop above already requires.
step "0. check-deploy-inputs (static: every path DeployV2Batch.sh reads, before any forge step)"
bash script/v2/check-deploy-inputs.sh --registry "$REGISTRY" --sources "$SOURCES" --mode rehearse --recorded none \
  || die "check-deploy-inputs refused $REGISTRY / $SOURCES: every REJECT line above is a read the batch would have made before its first forge step"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOG=broadcast/v2-rehearsal/$STAMP
mkdir -p "$LOG"
echo "rehearsal logs: $ROOT/$LOG"

step "forge build (before the fork clock starts)"
forge build > "$LOG/build.log" 2>&1 || { tail -30 "$LOG/build.log"; die "forge build failed"; }

if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then die "something already answers on $RPC; pick another PORT"; fi
step "anvil fork of $FORK_URL on $RPC"
# --retries/--fork-retry-backoff/--timeout: the public RPC drops a fork's storage reads now and then ("connection
# reset"), which forge reports as an EVM database error half way through a registration.
anvil --fork-url "$FORK_URL" --chain-id 4663 --port "$PORT" --code-size-limit 98304 \
  --retries 12 --fork-retry-backoff 1000 --timeout 60000 > "$LOG/anvil.log" 2>&1 &
ANVIL_PID=$!
trap 'kill "$ANVIL_PID" 2>/dev/null || true; echo "anvil (pid $ANVIL_PID) stopped"' EXIT
for _ in $(seq 1 120); do
  if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then break; fi
  kill -0 "$ANVIL_PID" 2>/dev/null || { tail -20 "$LOG/anvil.log"; die "anvil exited"; }
  sleep 1
done
cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 || { tail -20 "$LOG/anvil.log"; die "anvil did not come up on $RPC"; }
FORK_BLOCK=$(cast block-number --rpc-url "$RPC")
echo "  fork block $FORK_BLOCK (pid $ANVIL_PID)"

SHA_BEFORE=$(shasum -a 256 "$REGISTRY" | cut -d' ' -f1)
COPY="$ROOT/$LOG/tier1.rehearsal.json"

# ---------------------------------------------------------------- 0b. the two Safes must be Safes (T-OP-110)
# DeployV8._assertAdminSafeIsARealSafe (script/v2/DeployV8.s.sol:1619-1718, T-426 F-05-01) probes the Admin
# Safe's singleton slot, threshold, owners, modules, guard and fallback handler before the irreversible
# renounce, and `_principals` requires both Safes to have code. A fork of 4663 IS chain 4663, so every probe
# is live here, and the inert `0x60008080fd` stand-in DeployV2Batch.sh used to plant at a code-less Safe is
# exactly what the probe refuses ("has code but its singleton slot holds 0x0…") -- T-OP-081 run 2A stopped
# there. So the rehearsal makes GENUINE Safes: when the registry's Safe is already a canonical Safe on the
# fork (the real registry's are, run 3) it is kept; otherwise a fork-only 2-of-3 Safe proxy is created
# through the canonical SafeProxyFactory and written into the rehearsal's INPUT COPY, never the registry.
#
# The four addresses below are MIRRORED from DeployV8.s.sol:1587-1590 (the singletons the probe accepts
# and the fallback handler it accepts) and ops/runbooks/v8-safes.md §2 / callhouse ops/v8/safes-bootstrap.sh
# (the factory the real Safes were created through; run 2B and the real Safes both used it). They are
# candidates until the code check below proves them on this fork -- the run dies naming the first one
# that has no code rather than creating a proxy that points at nothing.
SAFE_SINGLETON=0x29fcB43b46531BcA003ddC8FCB67FFE91900C762   # SafeL2 1.4.1  (DeployV8 SAFE_L2_141)
SAFE_141=0x41675C099F32341bf84BFc5382aF534df5C7461a         # Safe   1.4.1  (DeployV8 SAFE_141)
SAFE_L2_130=0x3E5c63644E683549055b9Be8653de26E0B4CD36E      # SafeL2 1.3.0  (DeployV8 SAFE_L2_130)
SAFE_FACTORY=0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67     # SafeProxyFactory 1.4.1
SAFE_FALLBACK=0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99    # CompatibilityFallbackHandler 1.4.1 (DeployV8 SAFE_FALLBACK_141)
SAFE_GUARD_SLOT=0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8      # DeployV8.s.sol:1592
SAFE_FALLBACK_SLOT=0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5   # DeployV8.s.sol:1593
# Owners: anvil dev accounts #5, #6, #7, DERIVED from anvil's public mnemonic, never typed. Not the
# deployer (#0), not the fixture's guardian (#1), not the bots (#8/#9/#10): Safe owners are outside the
# wrapper's seven-principal rule, but keeping them disjoint keeps the run readable. FORK ONLY: these keys
# are public, so a Safe they own is a Safe anybody owns; nothing created here may ever be written into a
# registry that broadcasts (the wrapper refuses `--out ops/markets/tier1.json` already).
ANVIL_MNEMONIC="test test test test test test test test test test test junk"
anvil_addr() { cast wallet address --mnemonic "$ANVIL_MNEMONIC" --mnemonic-index "$1"; }
SAFE_OWNERS="[$(anvil_addr 5),$(anvil_addr 6),$(anvil_addr 7)]"
SAFE_DEPLOYER=$(anvil_addr 0)   # anvil funds it on a fork; --unlocked, so no key is on any command line
SAFE_SETUP_SIG="setup(address[],uint256,address,bytes,address,address,uint256,address)"
SAFE_CREATE_SIG="createProxyWithNonce(address,bytes,uint256)"
ZERO=0x0000000000000000000000000000000000000000
lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }
slot_addr() { # <addr> <slot> -> the address in the low 20 bytes of that storage slot, lower-case
  local w; w=$(cast storage "$1" "$2" --rpc-url "$RPC"); lower "0x${w: -40}"
}
safe_is_canonical() { # <addr> -> 0 when the address has code AND its singleton slot is one of the three builds
  local code slot
  code=$(cast code "$1" --rpc-url "$RPC" 2>/dev/null || echo 0x)
  [ "$code" != 0x ] && [ -n "$code" ] || return 1
  slot=$(slot_addr "$1" 0)
  [ "$slot" = "$(lower "$SAFE_SINGLETON")" ] || [ "$slot" = "$(lower "$SAFE_141")" ] || [ "$slot" = "$(lower "$SAFE_L2_130")" ]
}
create_fork_safe() { # <label> <salt> -> the new Safe's address on stdout; every mismatch dies by name
  local label=$1 salt=$2 init predicted created log threshold owners modules guard fb
  log="$LOG/0b-safe-$label.log"
  init=$(cast calldata "$SAFE_SETUP_SIG" "$SAFE_OWNERS" 2 "$ZERO" 0x "$SAFE_FALLBACK" "$ZERO" 0 "$ZERO")
  # ops/runbooks/v8-safes.md §2: simulate the exact call first, then send those same arguments.
  predicted=$(cast call "$SAFE_FACTORY" "$SAFE_CREATE_SIG(address)" "$SAFE_SINGLETON" "$init" "$salt" \
    --from "$SAFE_DEPLOYER" --rpc-url "$RPC" 2>"$log.err") \
    || { cat "$log.err"; die "$label Safe: createProxyWithNonce simulation failed (salt $salt)"; }
  [ "$(cast code "$predicted" --rpc-url "$RPC")" = 0x ] \
    || die "$label Safe: the predicted address $predicted already has code on this fork (salt $salt): set SAFE_SALT_$(tr '[:lower:]' '[:upper:]' <<<"$label") to another integer"
  cast send "$SAFE_FACTORY" "$SAFE_CREATE_SIG" "$SAFE_SINGLETON" "$init" "$salt" \
    --from "$SAFE_DEPLOYER" --unlocked --rpc-url "$RPC" --json > "$log" 2>"$log.err" \
    || { cat "$log.err"; die "$label Safe: createProxyWithNonce failed"; }
  # The factory's ProxyCreation(address indexed proxy, address singleton) log is the creation of record;
  # the simulated address is only a prediction until the receipt agrees with it.
  created=$(jq -r --arg f "$(lower "$SAFE_FACTORY")" \
    '[.logs[] | select((.address | ascii_downcase) == $f) | .topics[1]] | first // empty' "$log")
  [ -n "$created" ] || die "$label Safe: no ProxyCreation log from the factory in the receipt (log $log)"
  created=$(lower "0x${created: -40}")
  [ "$created" = "$(lower "$predicted")" ] || die "$label Safe: created $created but the simulation predicted $predicted"
  # Exactly what DeployV8._assertAdminSafeIsARealSafe will probe, checked here so a wrong Safe dies now,
  # by name, and not ninety seconds later inside forge's simulation.
  safe_is_canonical "$predicted" || die "$label Safe $predicted: singleton slot is not a canonical Safe build"
  # T-OP-206: first field only. cast annotates every decoded uint >= 10000 as `N [x.xe4]` (measured on cast 1.3.5:
  # 9999 bare, 10000 -> `10000 [1e4]`), and a bare `$(cast call ...)` keeps the annotation. A threshold can never
  # reach 10000 with three owners, so this compare was safe by value; it is made safe by shape like :318.
  threshold=$(cast call "$predicted" "getThreshold()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
  [ "$threshold" = 2 ] || die "$label Safe $predicted: getThreshold() is $threshold, expected 2"
  owners=$(cast call "$predicted" "getOwners()(address[])" --rpc-url "$RPC")
  [ "$(tr -cd ',' <<<"$owners" | wc -c | tr -d ' ')" = 2 ] || die "$label Safe $predicted: getOwners() is $owners, expected 3 owners"
  modules=$(cast call "$predicted" "getModulesPaginated(address,uint256)(address[],address)" 0x0000000000000000000000000000000000000001 10 --rpc-url "$RPC" | head -1)
  [ "$modules" = "[]" ] || die "$label Safe $predicted: has enabled module(s): $modules"
  guard=$(cast storage "$predicted" "$SAFE_GUARD_SLOT" --rpc-url "$RPC")
  [ "$guard" = 0x0000000000000000000000000000000000000000000000000000000000000000 ] || die "$label Safe $predicted: has a transaction guard"
  fb=$(slot_addr "$predicted" "$SAFE_FALLBACK_SLOT")
  [ "$fb" = "$(lower "$SAFE_FALLBACK")" ] || die "$label Safe $predicted: fallback handler $fb is not the canonical 1.4.1 handler"
  echo "$predicted"
}

step "0b. the registry's Safes on the fork: kept when genuine, else fork-only 2-of-3 Safes are created (T-OP-110)"
SAFE_FILTER='.'
NEED_SAFES=0
for label in admin treasury; do
  have=$(jq -r --arg k "$label" '.shared.safes[$k] // empty' "$REGISTRY")
  if [ -n "$have" ] && safe_is_canonical "$have"; then
    echo "  $label Safe $have: canonical Safe build at singleton slot $(slot_addr "$have" 0), threshold $(cast call "$have" "getThreshold()(uint256)" --rpc-url "$RPC"); kept"
    continue
  fi
  if [ "$NEED_SAFES" = 0 ]; then
    for c in "SafeL2 1.4.1 singleton:$SAFE_SINGLETON" "SafeProxyFactory 1.4.1:$SAFE_FACTORY" "CompatibilityFallbackHandler 1.4.1:$SAFE_FALLBACK"; do
      [ "$(cast code "${c#*:}" --rpc-url "$RPC")" != 0x ] || die "${c%%:*} ${c#*:} has no code on this fork of 4663; a genuine Safe cannot be created here"
    done
    echo "  singleton, factory and fallback handler have code on the fork"
  fi
  NEED_SAFES=1
  case "$label" in
    admin)    salt=${SAFE_SALT_ADMIN:-${STAMP:0:8}01} ;;
    treasury) salt=${SAFE_SALT_TREASURY:-${STAMP:0:8}02} ;;
  esac
  made=$(create_fork_safe "$label" "$salt")
  echo "  $label Safe: ${have:-null} in the registry is not a Safe on the fork -> created $made [fork-only] (2-of-3, owners anvil #5/#6/#7, salt $salt, $(cast to-dec "$(jq -r .gasUsed "$LOG/0b-safe-$label.log")") gas)"
  SAFE_FILTER="$SAFE_FILTER | .shared.safes.$label = \"$made\""
done

if [ -n "$CHAINLINK_ONLY" ] || [ "$NEED_SAFES" = 1 ]; then
  INPUT="$ROOT/$LOG/tier1.input.json"
  only=$(echo "${CHAINLINK_ONLY:-}" | tr ',' '\n' | jq -R . | jq -sc 'map(select(length > 0))')
  jq --argjson only "$only" "(.markets[] | select(.ticker as \$t | \$only | index(\$t)) | .v2) |= (.univ3Pool = null | .univ3MinLiquidity = null) | $SAFE_FILTER" "$REGISTRY" > "$INPUT"
  echo "  input copy $INPUT (Chainlink only on the fork: ${CHAINLINK_ONLY:-none}; fork-only Safes written: $NEED_SAFES)"
  if [ "$NEED_SAFES" = 1 ]; then
    # Loud on purpose. A registry whose Safes are not real Safes cannot broadcast (DeployV2Batch.sh refuses
    # a code-less V2_ADMIN_SAFE and DeployV8 refuses a non-Safe one), so no record of this run gates anything;
    # the real 2-of-3 Safes are the owner's (T-OP-111) and are written into the registry by hand, never here.
    echo "  NOTE: this rehearsal runs on FORK-ONLY Safes; its rehearsal-passed.json cannot gate a broadcast of $REGISTRY"
  fi
else
  # A byte-for-byte exact-registry rehearsal must use the real input path: even an identity jq
  # rewrite changes its sha256 and produces a record that cannot gate a later broadcast.
  INPUT=$REGISTRY
  echo "  input registry $INPUT (byte-for-byte unchanged; no Chainlink-only override; both Safes genuine)"
fi

if [ -n "$REGISTER_ONLY" ]; then
  step "1a. DeployV2Batch.sh --rehearse --deploy-only (already-deployed set for register-only)"
  "$BATCH" --rehearse --rpc "$RPC" --registry "$INPUT" --sources "$SOURCES" --deploy-only --out "$COPY" ${SKIP_FLAG[@]+"${SKIP_FLAG[@]}"} \
    2>&1 | tee "$LOG/1-deploy.log"
  grep -q "BATCH PASSED (rehearse)" "$LOG/1-deploy.log" || die "deploy-only did not pass (log: $LOG/1-deploy.log)"
  step "1b. DeployV2Batch.sh --rehearse --register-only --tickers $TICKERS"
  "$BATCH" --rehearse --rpc "$RPC" --registry "$COPY" --sources "$SOURCES" --tickers "$TICKERS" --register-only --out "$COPY" ${SKIP_FLAG[@]+"${SKIP_FLAG[@]}"} \
    2>&1 | tee "$LOG/1-batch.log"
else
  step "1. DeployV2Batch.sh --rehearse --tickers $TICKERS"
  "$BATCH" --rehearse --rpc "$RPC" --registry "$INPUT" --sources "$SOURCES" --tickers "$TICKERS" --out "$COPY" ${SKIP_FLAG[@]+"${SKIP_FLAG[@]}"} \
    2>&1 | tee "$LOG/1-batch.log"
fi
grep -q "BATCH PASSED (rehearse)" "$LOG/1-batch.log" || die "the batch did not pass (log: $LOG/1-batch.log)"
if [ -z "$REGISTER_ONLY" ]; then
  grep -q "rehearsal record .*rehearsal-passed.json" "$LOG/1-batch.log" || die "the passed rehearsal left no rehearsal-passed.json"
else
  grep -q "rehearsal record .*rehearsal-passed.json" "$LOG/1-batch.log" \
    || grep -q "rehearsal record .*rehearsal-passed.json" "$LOG/1-deploy.log" \
    || die "the passed rehearsal left no rehearsal-passed.json"
fi
[ "$(shasum -a 256 "$REGISTRY" | cut -d' ' -f1)" = "$SHA_BEFORE" ] || die "the real registry changed"
echo "  real registry unchanged (sha256 $SHA_BEFORE)"
# T-OP-116: the externals record -- order, addresses, gas and the mapping -- straight from the stage's own
# lines (every one is prefixed `externals:`), then the six slots as the copy records them.
grep -hE "^\s+externals: " "$LOG/1-batch.log" "$LOG/1-deploy.log" 2>/dev/null | sed 's/^/  /' || true
for k in rewardsDistributorLender earnVault stockVenueAdapter houseVaultFactory houseVault hedger; do
  jq -r --arg k "$k" '"  external \($k) \(.v2.contracts[$k] // "<unsupplied>")  start block \(.v2.externalDeployBlocks[$k] // "null")"' "$COPY"
done
for T in $(echo "$TICKERS" | tr ',' ' '); do
  jq -e --arg t "$T" '.markets[] | select(.ticker == $t) | .v2.registeredAt != null and .v2.registerTx != null' "$COPY" >/dev/null \
    || die "$T: no registeredAt/registerTx in the copy"
done
CH=$(jq -r '.v2.contracts.clearinghouse' "$COPY")
MGR=$(jq -r '.v2.contracts.accessManager' "$COPY")
ADMIN=$(jq -r '.shared.safes.admin // .shared.admin' "$COPY")
# AC: after deploy, the Admin Safe holds ADMIN (role 0) with delay 172800; the ephemeral deployer does not.
# AccessManager.hasRole(uint64,address) returns (bool isMember, uint32 executionDelay).
read -r ADMIN_IS_MEMBER ADMIN_DELAY <<<"$(cast call "$MGR" "hasRole(uint64,address)(bool,uint32)" 0 "$ADMIN" --rpc-url "$RPC" | tr '\n' ' ')"
# cast 1.3.5 prints a decoded uint as `172800 [1.728e5]`, and `read -r a b` keeps everything after the first space
# in `b`, so ADMIN_DELAY arrived as `172800 [1.728e5]` and the test below died one line after BATCH PASSED (T-OP-165
# run 8; T-OP-135 F7). Keep the number, drop the annotation.
ADMIN_DELAY=${ADMIN_DELAY%% *}
[ "$ADMIN_IS_MEMBER" = true ] || die "Admin Safe $ADMIN is not an ADMIN member after deploy"
[ "$ADMIN_DELAY" = 172800 ] || die "Admin Safe ADMIN delay is $ADMIN_DELAY, expected 172800"
echo "  handover: Admin Safe $ADMIN holds ADMIN at delay $ADMIN_DELAY s"
# T-OP-161: the launch set went DIRECT, by the deployer, with no clock jump; and the window is CLOSED afterwards.
# REGISTER_ONLY=1 is the post-launch rehearsal (window closed by --deploy-only, then the Safe's lanes), so the
# direct-path assertions apply to the full run only.
REHEARSAL_DEPLOYER_ADDR=$(cast to-check-sum-address "${REHEARSAL_DEPLOYER:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}")
if [ -z "$REGISTER_ONLY" ]; then
  WANT=$(echo "$TICKERS" | tr ',' '\n' | grep -c .)
  DIRECT_N=$(grep -cE "RegisterMarkets.s.sol \(DIRECT, sent by the deployer\)" "$LOG/1-batch.log" || true)
  [ "$DIRECT_N" = "$WANT" ] || die "T-OP-161: $DIRECT_N of $WANT tickers registered DIRECT by the deployer (log: $LOG/1-batch.log); the launch set must never take the scheduled path"
  ! grep -q "node clock advanced" "$LOG/1-batch.log" \
    || die "T-OP-161: the batch advanced the fork clock during the launch run (log: $LOG/1-batch.log). The launch set is registered directly at delay 0; a warp here would hide a regression of the direct path"
  grep -q "the signer holds LISTING and CONFIG_ADMIN on the accessManager" "$LOG/1-batch.log" \
    || die "T-OP-161: no RegisterMarkets run printed the deployer's _signerCanList line (log: $LOG/1-batch.log)"
  echo "  direct path: $DIRECT_N/$WANT tickers registered by the deployer at delay 0, no clock jump"
fi
read -r DEP_IS_ADMIN _ <<<"$(cast call "$MGR" "hasRole(uint64,address)(bool,uint32)" 0 "$REHEARSAL_DEPLOYER_ADDR" --rpc-url "$RPC" | tr '\n' ' ')"
[ "$DEP_IS_ADMIN" = false ] || die "T-OP-161: the rehearsal deployer $REHEARSAL_DEPLOYER_ADDR still holds ADMIN after the batch: HandBack did not close the window"
echo "  window closed: deployer $REHEARSAL_DEPLOYER_ADDR holds no ADMIN (read back)"

step "2. VerifyV8 against the copy (DeployV2Batch.sh --verify --expect-fresh true)"
"$BATCH" --verify --rpc "$RPC" --registry "$COPY" --sources "$SOURCES" --expect-fresh true ${SKIP_FLAG[@]+"${SKIP_FLAG[@]}"} 2>&1 | tee "$LOG/2-verify.log"
require_verify_summary "$LOG/2-verify.log" "step 2"
grep -q "VERIFY PASSED" "$LOG/2-verify.log" || die "VerifyV8 did not pass against the copy"

step "3. a second run on the copy has nothing to do"
if [ -n "$REGISTER_ONLY" ]; then
  "$BATCH" --rehearse --rpc "$RPC" --registry "$COPY" --out "$COPY" --sources "$SOURCES" --tickers "$TICKERS" --register-only ${SKIP_FLAG[@]+"${SKIP_FLAG[@]}"} > "$LOG/3-again.log" 2>&1 \
    || { tail -20 "$LOG/3-again.log"; die "second register-only run failed"; }
  # A drill that accepts "REGISTER DONE or skip" accepts every outcome, because REGISTER DONE prints
  # on any successful registration. Idempotence means BOTH passes do nothing for EVERY ticker and no
  # admin call is executed at all: assert the counts, not the presence of a word.
  WANT=$(echo "$TICKERS" | tr ',' '\n' | grep -c .)
  SKIP_REG=$(grep -cE "^skip [A-Z0-9.]+: v2.registeredAt is already" "$LOG/3-again.log" || true)
  SKIP_LIST=$(grep -cE "^  skip [A-Z0-9.]+: v2.status is 'live', not 'planned'" "$LOG/3-again.log" || true)
  EXECUTED=$(grep -cE "^\s+executed " "$LOG/3-again.log" || true)
  [ "$SKIP_REG" = "$WANT" ] || { tail -20 "$LOG/3-again.log"; die "second register-only run: $SKIP_REG of $WANT tickers skipped registration"; }
  [ "$SKIP_LIST" = "$WANT" ] || { tail -20 "$LOG/3-again.log"; die "second register-only run: $SKIP_LIST of $WANT tickers skipped listing"; }
  [ "$EXECUTED" = 0 ] || { tail -20 "$LOG/3-again.log"; die "second register-only run executed $EXECUTED admin call(s); idempotent means zero"; }
  echo "  second register-only: $WANT registered-skips, $WANT listing-skips, 0 admin calls executed"
else
  if "$BATCH" --rehearse --rpc "$RPC" --registry "$COPY" --out "$COPY" --sources "$SOURCES" --tickers "$TICKERS" ${SKIP_FLAG[@]+"${SKIP_FLAG[@]}"} > "$LOG/3-again.log" 2>&1; then
    die "a second run on a complete copy did not refuse"
  fi
  grep -q "nothing to do" "$LOG/3-again.log" || { tail -5 "$LOG/3-again.log"; die "unexpected refusal"; }
  echo "  refused: $(grep -o 'nothing to do.*' "$LOG/3-again.log")"
fi

step "4. a lost pointer: VerifyV8 FAILs, the batch wants --resume; the deployer cannot (window closed), the Safe repairs it"
ADMIN=$(jq -r '.shared.safes.admin // .shared.admin' "$COPY")
MGR=$(jq -r '.v2.contracts.accessManager' "$COPY")
ORACLE=$(jq -r '.v2.contracts.settlementOracle' "$COPY")
cast rpc anvil_impersonateAccount "$ADMIN" --rpc-url "$RPC" >/dev/null
# CONFIG_ADMIN, 24 h delay (roles.v8.json). Schedule, warp, then call the TARGET from the Safe
# (06-QUIRKS.md §D.2: manager.execute would make the target see msg.sender == manager).
BREAK_DATA=$(cast calldata "setKeeperRewards(address)" 0x0000000000000000000000000000000000000000)
cast send "$MGR" "schedule(address,bytes,uint48)" "$ORACLE" "$BREAK_DATA" 0 --from "$ADMIN" --unlocked --rpc-url "$RPC" > "$LOG/4-schedule.log" 2>&1 \
  || { tail -8 "$LOG/4-schedule.log"; die "could not schedule the pointer break"; }
cast rpc evm_increaseTime 86400 --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
cast send "$ORACLE" "setKeeperRewards(address)" 0x0000000000000000000000000000000000000000 --from "$ADMIN" --unlocked --rpc-url "$RPC" > "$LOG/4-break.log" 2>&1 \
  || { tail -5 "$LOG/4-break.log"; die "could not break the pointer"; }
if "$BATCH" --verify --rpc "$RPC" --registry "$COPY" --sources "$SOURCES" ${SKIP_FLAG[@]+"${SKIP_FLAG[@]}"} > "$LOG/4-verify-broken.log" 2>&1; then die "VerifyV8 passed with a lost pointer"; fi
require_verify_summary "$LOG/4-verify-broken.log" "step 4"
grep -q "FAIL  settlementOracle.keeperRewards == keeperRewards" "$LOG/4-verify-broken.log" || die "the lost pointer was not the failure"
echo "  VerifyV8: FAIL settlementOracle.keeperRewards == keeperRewards"
if "$BATCH" --rehearse --rpc "$RPC" --registry "$COPY" --out "$COPY" --sources "$SOURCES" --deploy-only ${SKIP_FLAG[@]+"${SKIP_FLAG[@]}"} > "$LOG/4-check.log" 2>&1; then die "the batch registered on a half-wired set"; fi
grep -q "re-run with --resume" "$LOG/4-check.log" || { tail -5 "$LOG/4-check.log"; die "the wiring check did not ask for --resume"; }
grep -E "^\s+PENDING" "$LOG/4-check.log" | sed 's/^ */  /'
# T-OP-161 RE-CUT. The deployer's window is CLOSED (HandBack ran after the markets in step 1), so a --resume by
# the deployer cannot re-wire anything: DeployV8 re-plans the pointer, and the manager refuses the deployer that
# holds nothing. That refusal is the drill now -- it is the property the direct path must leave intact. The
# repair belongs to the Safe's CONFIG_ADMIN lane (24 h), the same lane the break above used; a warp here is the
# post-launch shape, not the launch set's.
if "$BATCH" --rehearse --rpc "$RPC" --registry "$COPY" --out "$COPY" --sources "$SOURCES" --deploy-only --resume ${SKIP_FLAG[@]+"${SKIP_FLAG[@]}"} > "$LOG/4-resume.log" 2>&1; then
  die "T-OP-161: --resume by the deployer re-wired a set after HandBack -- the deployer still holds a role, the window is not closed (log: $LOG/4-resume.log)"
fi
grep -qE "AccessManagerUnauthorizedAccount|holds nothing|not authorized|Unauthorized" "$LOG/4-resume.log" \
  || { tail -15 "$LOG/4-resume.log"; die "T-OP-161: --resume refused for a reason other than the deployer holding nothing (log: $LOG/4-resume.log)"; }
echo "  --resume by the deployer: refused (holds nothing after HandBack) -- the window is closed"
REPAIR_DATA=$(cast calldata "setKeeperRewards(address)" "$(jq -r '.v2.contracts.keeperRewards' "$COPY")")
cast send "$MGR" "schedule(address,bytes,uint48)" "$ORACLE" "$REPAIR_DATA" 0 --from "$ADMIN" --unlocked --rpc-url "$RPC" > "$LOG/4-repair-schedule.log" 2>&1 \
  || { tail -8 "$LOG/4-repair-schedule.log"; die "could not schedule the pointer repair from the Safe"; }
cast rpc evm_increaseTime 86400 --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
cast send "$ORACLE" "setKeeperRewards(address)" "$(jq -r '.v2.contracts.keeperRewards' "$COPY")" --from "$ADMIN" --unlocked --rpc-url "$RPC" > "$LOG/4-repair.log" 2>&1 \
  || { tail -5 "$LOG/4-repair.log"; die "could not repair the pointer from the Safe"; }
"$BATCH" --verify --rpc "$RPC" --registry "$COPY" --sources "$SOURCES" ${SKIP_FLAG[@]+"${SKIP_FLAG[@]}"} > "$LOG/4-verify-repaired.log" 2>&1 \
  || { tail -20 "$LOG/4-verify-repaired.log"; die "VerifyV8 did not pass after the Safe repaired the pointer"; }
require_verify_summary "$LOG/4-verify-repaired.log" "step 4 Safe repair"
grep -q "VERIFY PASSED" "$LOG/4-verify-repaired.log" || die "no VERIFY PASSED after the Safe repair (log: $LOG/4-verify-repaired.log)"
echo "  Safe repair (CONFIG_ADMIN lane, 24 h): $(grep -o 'VERIFY PASSED: [0-9]* checks' "$LOG/4-verify-repaired.log")"

step "5. a lost write-back is recovered from the chain"
LAST=$(echo "$TICKERS" | tr ',' '\n' | tail -1)
WANT_AT=$(jq -r --arg t "$LAST" '.markets[] | select(.ticker == $t) | .v2.registeredAt' "$COPY")
WANT_TX=$(jq -r --arg t "$LAST" '.markets[] | select(.ticker == $t) | .v2.registerTx' "$COPY")
node -e '
  const fs = require("fs"); const [f, t] = process.argv.slice(1);
  const r = JSON.parse(fs.readFileSync(f, "utf8"));
  const m = r.markets.find((x) => x.ticker === t); m.v2.registeredAt = null; m.v2.registerTx = null;
  fs.writeFileSync(f, JSON.stringify(r, null, 2) + "\n");' "$COPY" "$LAST"
if [ -n "$REGISTER_ONLY" ]; then
  "$BATCH" --rehearse --rpc "$RPC" --registry "$COPY" --out "$COPY" --sources "$SOURCES" --tickers "$LAST" --register-only ${SKIP_FLAG[@]+"${SKIP_FLAG[@]}"} > "$LOG/5-recover.log" 2>&1 \
    || { tail -30 "$LOG/5-recover.log"; die "recovery run failed"; }
else
  "$BATCH" --rehearse --rpc "$RPC" --registry "$COPY" --out "$COPY" --sources "$SOURCES" --tickers "$LAST" ${SKIP_FLAG[@]+"${SKIP_FLAG[@]}"} > "$LOG/5-recover.log" 2>&1 \
    || { tail -30 "$LOG/5-recover.log"; die "recovery run failed"; }
fi
GOT_AT=$(jq -r --arg t "$LAST" '.markets[] | select(.ticker == $t) | .v2.registeredAt' "$COPY")
GOT_TX=$(jq -r --arg t "$LAST" '.markets[] | select(.ticker == $t) | .v2.registerTx' "$COPY")
[ "$GOT_AT" = "$WANT_AT" ] && [ "$GOT_TX" = "$WANT_TX" ] || die "$LAST recovered as $GOT_AT/$GOT_TX, was $WANT_AT/$WANT_TX"
grep -q "REGISTER DONE: 1 market(s), 0 registerMarket call(s), 0 admin call(s) sent" "$LOG/5-recover.log" || die "the recovery run sent transactions"
echo "  $LAST registeredAt $GOT_AT registerTx $GOT_TX recovered from the MarketRegistered log, nothing sent"

step "6. VerifyV8 has teeth: one byte of the Clearinghouse runtime flipped"
code=$(cast code "$CH" --rpc-url "$RPC")
# The second-to-last byte: the length word of solc's trailing CBOR, never executed, so every other read of the
# Clearinghouse still works and the bytecode comparison is the only check that can see the change.
pos=$((${#code} - 4))
orig=${code:$pos:2}
flip=$(printf '%02x' $(( (16#$orig) ^ 0x01 )))
cast rpc anvil_setCode "$CH" "${code:0:$pos}${flip}${code:$((pos + 2))}" --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
if "$BATCH" --verify --rpc "$RPC" --registry "$COPY" --sources "$SOURCES" ${SKIP_FLAG[@]+"${SKIP_FLAG[@]}"} > "$LOG/6-tamper.log" 2>&1; then die "VerifyV8 passed against tampered bytecode"; fi
require_verify_summary "$LOG/6-tamper.log" "step 6"
grep -q "FAIL  clearinghouse: runtime == compiled artifact, outside immutable slots" "$LOG/6-tamper.log" || { grep -E "FAIL|Error" "$LOG/6-tamper.log" | head; die "the tamper was not caught by the bytecode check"; }
echo "  byte $(( (pos - 2) / 2 )) of the Clearinghouse flipped 0x$orig -> 0x$flip: FAIL clearinghouse runtime, and nothing else"
[ "$(grep -cE "^\s+FAIL" "$LOG/6-tamper.log")" = 1 ] || die "the tamper failed more than the bytecode check"
cast rpc anvil_setCode "$CH" "$code" --rpc-url "$RPC" >/dev/null

step "summary"
jq -r '.v2.contracts | to_entries[] | if .key == "sources" then (.value | to_entries[] | "  sources.\(.key) \(.value)") else "  \(.key) \(.value)" end' "$COPY"
echo "  deployBlock $(jq -r '.v2.deployBlock' "$COPY")  bots $(jq -c '.v2.bots' "$COPY")"
echo "  externals $(jq -c '.v2.contracts | {rewardsDistributorLender, earnVault, stockVenueAdapter, houseVaultFactory, houseVault, hedger}' "$COPY")  start blocks $(jq -c '.v2.externalDeployBlocks // null' "$COPY")"
for T in $(echo "$TICKERS" | tr ',' ' '); do
  jq -r --arg t "$T" '.markets[] | select(.ticker == $t) | "  \(.ticker) registeredAt \(.v2.registeredAt) registerTx \(.v2.registerTx) pool \(.v2.univ3Pool)"' "$COPY"
done
printf '\nREHEARSAL PASSED on fork block %s (%s; Chainlink only: %s) in %ss; copy %s; logs %s\n' \
  "$FORK_BLOCK" "$TICKERS" "${CHAINLINK_ONLY:-none}" "$(( $(date +%s) - T0 ))" "$COPY" "$ROOT/$LOG"
