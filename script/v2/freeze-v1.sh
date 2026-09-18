#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# freeze-v1.sh — freeze every v1 solo market in the registry (ADR-10) with script/v2/FreezeV1.s.sol:
# guardian setWritesHalted(true) and admin setDepositCap(0) on each AccountFactory, then the post-check.
#
# The registry (`ops/markets/tier1.json` in stonkhousedotfun/callhouse, default ../callhouse/... from this
# repository's root) names the v1 factories: every row whose deployment.factory is not null. bash + jq read
# them and pass them to forge as V1_FACTORIES; Solidity never parses the registry. docs/V1-RUNOFF.md is the
# runbook this script belongs to.
#
#   --registry <path>   default ../callhouse/ops/markets/tier1.json. A relative path resolves against the
#                       directory you run the script from, not the repo root.
#   --rpc <url>         default $RH_RPC
#   --check             read-only, any node. No key reaches forge (GUARDIAN_PK/ADMIN_PK are unset for it).
#                       Prints each factory's state, writes the Safe batches for whatever is not frozen yet,
#                       and runs the post-check when nothing is left. Exit 0 = every factory frozen and
#                       post-checked; exit 3 = not frozen yet (the batches are in the log directory).
#   --rehearse          anvil fork of 4663 only (--rpc 127.0.0.1/localhost, the node answers as anvil).
#                       Writes the batches, sends every batch transaction from the row's deployment.guardian /
#                       deployment.admin with anvil_impersonateAccount (hasRole checked on the fork first),
#                       then two key-less runs: the first must pass the post-check, the second must skip
#                       every call.
#   --broadcast         mainnet. --rpc must not be local or anvil. GUARDIAN_PK and/or ADMIN_PK come from the
#                       environment (never a flag, never printed); a role without a key is left to its Safe
#                       batch. Prints the plan, waits for the literal word "freeze" on stdin, runs FreezeV1
#                       with --broadcast (forge simulates the whole script first, so a key without its role is
#                       refused before anything is sent), then the key-less check against the chain.
#   --dry-run           print the factories and the commands; run nothing, no node needed.
#
# Logs, batches and forge output go to broadcast/freeze-v1/<utc>/ (freeze.log, one log per forge run,
# guardian-safe-batch.json, admin-safe-batch.json). Every forge call passes --no-storage-caching: a
# rehearsal mines blocks at real 4663 heights and forge's fork cache is keyed by block number
# (docs/DEPLOY.md). `set -o pipefail` because a piped forge run once hid a failure in this repository.
# -------------------------------------------------------------------------------------------------
set -euo pipefail

CALLER_PWD=$PWD   # a relative --registry resolves against this, not the repo root
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
export PATH="$HOME/.foundry/bin:$PATH"

die() { echo "FREEZE FAILED: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }
usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; }

CHAIN_EXPECT=4663
DEFAULT_ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000
REGISTRY="$ROOT/../callhouse/ops/markets/tier1.json"
RPC="${RH_RPC:-}"; MODE=""; DRY=0
set_mode() { [ -z "$MODE" ] || [ "$MODE" = "$1" ] || die "--$MODE and --$1 are exclusive"; MODE=$1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --registry) [ $# -ge 2 ] || die "--registry needs a path"; REGISTRY=$2; shift 2 ;;
    --rpc) [ $# -ge 2 ] || die "--rpc needs a url"; RPC=$2; shift 2 ;;
    --check) set_mode check; shift ;;
    --rehearse) set_mode rehearse; shift ;;
    --broadcast) set_mode broadcast; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown flag $1 (see --help)" ;;
  esac
done
case "$REGISTRY" in /*) ;; *) REGISTRY="$CALLER_PWD/$REGISTRY" ;; esac

for tool in forge cast jq; do command -v "$tool" >/dev/null || die "$tool not on PATH"; done
[ -n "$MODE" ] || die "one of --check, --rehearse or --broadcast is required (add --dry-run to print the plan only)"
[ -f "$REGISTRY" ] || die "registry not found: $REGISTRY"

# ---------------------------------------------------------------- the v1 factories
# Plain indexed arrays: macOS ships bash 3.2, which has no associative arrays.
P_TICKER=(); P_FACTORY=(); P_GUARDIAN=(); P_ADMIN=()
while IFS=$'\t' read -r t f g a; do
  [[ "$f" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "$t: deployment.factory '$f' is not an address"
  P_TICKER+=("$t"); P_FACTORY+=("$f"); P_GUARDIAN+=("$g"); P_ADMIN+=("$a")
done < <(jq -r '.markets[] | select(.deployment.factory != null and .deployment.factory != "")
  | [.ticker, .deployment.factory, (.deployment.guardian // ""), (.deployment.admin // "")] | @tsv' "$REGISTRY")
N=${#P_FACTORY[@]}
[ "$N" -gt 0 ] || die "no row in $REGISTRY has deployment.factory: nothing to freeze"
dup=$(printf '%s\n' "${P_FACTORY[@]}" | tr 'A-F' 'a-f' | sort | uniq -d)
[ -z "$dup" ] || die "deployment.factory $dup appears in more than one registry row"
V1_FACTORIES=$(IFS=,; echo "${P_FACTORY[*]}")
FACTORIES="$N v1 factor$([ "$N" = 1 ] && echo y || echo ies)"

step "plan: $MODE, $FACTORIES from $REGISTRY"
for ((i = 0; i < N; i++)); do
  printf '  %-6s %s  guardian %s  admin %s\n' "${P_TICKER[$i]}" "${P_FACTORY[$i]}" "${P_GUARDIAN[$i]:-<none>}" "${P_ADMIN[$i]:-<none>}"
done

if [ "$DRY" = 1 ]; then
  step "dry run: commands (nothing runs)"
  cat <<EOF
export V1_FACTORIES=$V1_FACTORIES
# check / batches only (no key reaches forge):
env -u GUARDIAN_PK -u ADMIN_PK forge script script/v2/FreezeV1.s.sol --rpc-url ${RPC:-<rpc>} --no-storage-caching --non-interactive
# broadcast (GUARDIAN_PK and/or ADMIN_PK exported beforehand, never typed here):
forge script script/v2/FreezeV1.s.sol --rpc-url ${RPC:-<rpc>} --broadcast --slow --no-storage-caching --non-interactive
EOF
  exit 0
fi

# ---------------------------------------------------------------- the node
[ -n "$RPC" ] || die "--rpc <url> or RH_RPC is required"
chain=$(cast chain-id --rpc-url "$RPC") || die "no RPC at $RPC"
[ "$chain" = "$CHAIN_EXPECT" ] || die "chain id $chain at $RPC, expected $CHAIN_EXPECT"
client=$(cast rpc web3_clientVersion --rpc-url "$RPC" 2>/dev/null || echo '""')
local_rpc=0; case "$RPC" in http://127.0.0.1:*|http://localhost:*) local_rpc=1 ;; esac
case "$MODE" in
  rehearse)
    [ "$local_rpc" = 1 ] || die "--rehearse needs a local anvil RPC (--rpc http://127.0.0.1:<port>), got '$RPC'"
    case "$client" in '"anvil/'*) ;; *) die "--rehearse runs against anvil only; the node says $client" ;; esac
    ;;
  broadcast)
    [ "$local_rpc" = 0 ] || die "--broadcast needs a non-local --rpc (got '$RPC'); use --rehearse against anvil"
    case "$client" in '"anvil/'*) die "--broadcast against an anvil node; use --rehearse" ;; esac
    [ -n "${GUARDIAN_PK:-}" ] || [ -n "${ADMIN_PK:-}" ] || die "--broadcast needs GUARDIAN_PK and/or ADMIN_PK in the environment"
    ;;
esac

# Key addresses through a read-only forge script: `cast wallet address` only takes a key on argv, which
# would put it in the process table (script/lib/KeyAddress.s.sol explains).
addr_of() { # env var name -> its address
  local out
  out=$(KEY_ENV="$1" forge script script/lib/KeyAddress.s.sol --non-interactive 2>/dev/null \
    | grep -E '^[[:space:]]*0x[0-9a-fA-F]{40}[[:space:]]*$' | tail -1 | tr -d '[:space:]' || true)
  [ -n "$out" ] || die "$1 is not a valid key"
  echo "$out"
}
GUARDIAN_KEY_ADDR=""; ADMIN_KEY_ADDR=""
if [ "$MODE" = broadcast ]; then
  [ -z "${GUARDIAN_PK:-}" ] || GUARDIAN_KEY_ADDR=$(addr_of GUARDIAN_PK)
  [ -z "${ADMIN_PK:-}" ] || ADMIN_KEY_ADDR=$(addr_of ADMIN_PK)
fi
GUARDIAN_ROLE=$(cast keccak GUARDIAN_ROLE)

has_role() { cast call "$1" "hasRole(bytes32,address)(bool)" "$2" "$3" --rpc-url "$RPC"; }
first_word() { awk '{print $1}'; }
print_state() {
  printf '  %-6s %-42s %-7s %-14s %-5s %-7s %s\n' TICKER FACTORY HALTED DEPOSIT_CAP LIVE PENDING ROLES
  for ((i = 0; i < N; i++)); do
    local f=${P_FACTORY[$i]} halted cap live pending roles=""
    halted=$(cast call "$f" "writesHalted()(bool)" --rpc-url "$RPC")
    cap=$(cast call "$f" "depositCap()(uint256)" --rpc-url "$RPC" | first_word)
    [ ${#cap} -le 14 ] || cap="${cap:0:6}..(${#cap} d)"
    live=$(cast call "$f" "liveCount()(uint256)" --rpc-url "$RPC" | first_word)
    pending=$(cast call "$f" "pendingCount()(uint256)" --rpc-url "$RPC" | first_word)
    [ -z "${P_GUARDIAN[$i]}" ] || roles="registry guardian $(has_role "$f" "$GUARDIAN_ROLE" "${P_GUARDIAN[$i]}")"
    [ -z "${P_ADMIN[$i]}" ] || roles="$roles, registry admin $(has_role "$f" "$DEFAULT_ADMIN_ROLE" "${P_ADMIN[$i]}")"
    [ -z "$GUARDIAN_KEY_ADDR" ] || roles="$roles, GUARDIAN_PK $(has_role "$f" "$GUARDIAN_ROLE" "$GUARDIAN_KEY_ADDR")"
    [ -z "$ADMIN_KEY_ADDR" ] || roles="$roles, ADMIN_PK $(has_role "$f" "$DEFAULT_ADMIN_ROLE" "$ADMIN_KEY_ADDR")"
    printf '  %-6s %-42s %-7s %-14s %-5s %-7s %s\n' "${P_TICKER[$i]}" "$f" "$halted" "$cap" "$live" "$pending" "$roles"
  done
}

# ---------------------------------------------------------------- logs
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOGDIR=broadcast/freeze-v1/$STAMP   # under broadcast/: foundry.toml's fs_permissions let forge write only there
mkdir -p "$LOGDIR"
exec > >(tee -a "$LOGDIR/freeze.log") 2>&1
echo "log directory: $ROOT/$LOGDIR"
export V1_FACTORIES GUARDIAN_BATCH_OUT="$LOGDIR/guardian-safe-batch.json" ADMIN_BATCH_OUT="$LOGDIR/admin-safe-batch.json"

step "state on chain $chain at block $(cast block-number --rpc-url "$RPC")"
[ -z "$GUARDIAN_KEY_ADDR" ] || echo "  GUARDIAN_PK address $GUARDIAN_KEY_ADDR"
[ -z "$ADMIN_KEY_ADDR" ] || echo "  ADMIN_PK address    $ADMIN_KEY_ADDR"
print_state

# One FreezeV1 run. Keys reach forge only for the run labelled "broadcast"; every other run is key-less.
run_freeze() { # label [extra forge args...]
  local label=$1 log="$LOGDIR/$1.log"; shift
  (
    if [ "$label" != broadcast ]; then unset GUARDIAN_PK ADMIN_PK; fi
    forge script script/v2/FreezeV1.s.sol --rpc-url "$RPC" --no-storage-caching --non-interactive "$@"
  ) > "$log" 2>&1 || { tail -40 "$log"; die "FreezeV1 ($label) failed (log: $log)"; }
  awk '/^== Logs ==/ {on = 1; next} /^(##|== |SIMULATION|ONCHAIN|Transactions saved|Sensitive values)/ {on = 0} on' "$log" \
    | sed 's/^/  /'
}
passed() { grep -q "post-check PASSED" "$LOGDIR/$1.log"; }

case "$MODE" in
  check)
    step "FreezeV1, key-less"
    run_freeze check
    if passed check; then
      step "FROZEN: $FACTORIES: all halted with a zero deposit cap, post-check passed"
      exit 0
    fi
    step "NOT FROZEN YET: batches for the missing calls are in $ROOT/$LOGDIR (decode them: docs/V1-RUNOFF.md)"
    exit 3
    ;;

  rehearse)
    step "FreezeV1, key-less: write the batches"
    run_freeze rehearse-batch
    for role in guardian admin; do
      batch="$LOGDIR/$role-safe-batch.json"
      [ -f "$batch" ] || { echo "  no $role batch: nothing for the $role to send"; continue; }
      step "send the $role batch from the registry's $role (anvil_impersonateAccount)"
      n=$(jq '.transactions | length' "$batch")
      for ((k = 0; k < n; k++)); do
        to=$(jq -r ".transactions[$k].to" "$batch"); data=$(jq -r ".transactions[$k].data" "$batch")
        sender=""; lto=$(tr 'A-F' 'a-f' <<<"$to")
        for ((i = 0; i < N; i++)); do
          if [ "$(tr 'A-F' 'a-f' <<<"${P_FACTORY[$i]}")" = "$lto" ]; then
            if [ "$role" = guardian ]; then sender=${P_GUARDIAN[$i]}; else sender=${P_ADMIN[$i]}; fi
          fi
        done
        [ -n "$sender" ] || die "batch call to $to: no registry $role for that factory"
        if [ "$role" = guardian ]; then r=$GUARDIAN_ROLE; else r=$DEFAULT_ADMIN_ROLE; fi
        [ "$(has_role "$to" "$r" "$sender")" = true ] || die "the registry's $role $sender does not hold its role on $to on this fork"
        cast rpc anvil_impersonateAccount "$sender" --rpc-url "$RPC" >/dev/null
        cast rpc anvil_setBalance "$sender" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
        status=$(cast send "$to" "$data" --from "$sender" --unlocked --rpc-url "$RPC" --json | jq -r .status)
        cast rpc anvil_stopImpersonatingAccount "$sender" --rpc-url "$RPC" >/dev/null
        [ "$status" = 0x1 ] || die "$role batch call $k to $to from $sender: receipt status $status"
        echo "  $role call $k: $to <- $sender  $(cast 4byte-calldata "$data" 2>/dev/null | tr '\n' ' ')ok"
      done
    done
    step "FreezeV1, key-less: must post-check"
    run_freeze rehearse-check
    passed rehearse-check || die "post-check did not pass after the batches were sent"
    step "FreezeV1, key-less again: must skip every call"
    run_freeze rehearse-idempotent
    passed rehearse-idempotent || die "post-check did not pass on the second run"
    grep -q "nothing to do" "$LOGDIR/rehearse-idempotent.log" || die "the second run built calls: not idempotent"
    step "state after"
    print_state
    step "REHEARSAL PASSED: $FACTORIES frozen on the fork, post-check passed, second run sent nothing"
    ;;

  broadcast)
    echo
    echo "MAINNET. Freezing $FACTORIES on chain $CHAIN_EXPECT at $RPC:"
    echo "  halts from ${GUARDIAN_KEY_ADDR:-<no GUARDIAN_PK: guardian Safe batch>}"
    echo "  caps  from ${ADMIN_KEY_ADDR:-<no ADMIN_PK: admin Safe batch>}"
    printf 'Type the word "freeze" to send the transactions: '
    read -r answer
    [ "$answer" = freeze ] || die "aborted: no confirmation (nothing was sent)"
    step "FreezeV1 --broadcast"
    run_freeze broadcast --broadcast --slow
    [ ! -f "broadcast/FreezeV1.s.sol/$CHAIN_EXPECT/run-latest.json" ] \
      || cp "broadcast/FreezeV1.s.sol/$CHAIN_EXPECT/run-latest.json" "$LOGDIR/run-latest.json"
    step "FreezeV1, key-less, against the chain"
    run_freeze broadcast-check
    print_state
    if passed broadcast-check; then
      step "FROZEN: $FACTORIES: all halted with a zero deposit cap, post-check passed against the chain"
    else
      step "NOT FROZEN YET: a role had no key; its batch is in $ROOT/$LOGDIR. Execute it, then --check"
      exit 3
    fi
    ;;
esac
