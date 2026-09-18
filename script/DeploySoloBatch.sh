#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# DeploySoloBatch.sh — one src/solo/ AccountFactory per market, from the registry:
#   DeploySolo.s.sol -> ConfigureSolo.s.sol -> VerifySolo.s.sol, then the addresses written back.
#
# The registry (`ops/markets/tier1.json` in stonkhousedotfun/callhouse, default ../callhouse/... from this
# repository's root) is the only source of the per-market inputs: asset, feed, depositCap, ticker,
# deployment.keeper, deployment.guardian, deployment.admin, deployment.feeRecipient. Nothing here hard-codes
# a market. NVDA (wave "live") is never selected by --wave and a row that already has deployment.factory is
# skipped (--force re-deploys it; refused for a live row on mainnet). A row whose verification.ok is false is
# refused: the builder found an issue with its token or feed, and the preflight would too. A row whose status is
# superseded-by-v2 (every planned row since 2026-09-16) is refused in every mode: v2 replaced the rollout.
#
#   --registry <path>            default ../callhouse/ops/markets/tier1.json. A relative --registry/--out
#                                resolves against the directory you run the script from, not the repo root.
#   --tickers A,B,C | --wave canary|wave1|wave2     which markets ("live" is refused)
#   --rpc <url>                  default $RH_RPC
#   --rehearse                   anvil mode. --rpc must be localhost/127.0.0.1 and the node must be anvil.
#                                DEPLOYER = ADMIN = anvil account #0 (its well-known key), or --deployer-pk.
#                                Write-back goes to --out <copy of the registry> (default: a fresh temp
#                                directory, printed at the end); the real registry is never written and
#                                its sha256 is checked unchanged at the end. forge's broadcast records go
#                                under the run's log directory, so a rehearsal never overwrites
#                                broadcast/DeploySolo.s.sol/4663/run-latest.json, the mainnet record.
#   --broadcast                  mainnet mode. --rpc must NOT be local; DEPLOYER_PK and ADMIN_PK come from
#                                the environment (never from a flag, never printed); ADMIN_PK's address must
#                                equal the row's deployment.admin. Prints the whole plan and waits for the
#                                literal word "deploy" on stdin before the first transaction. Adds
#                                --verify --verifier sourcify --chain 4663 to the deploy and writes the
#                                REAL registry after each market. Stops at the first failure.
#   --dry-run                    print the per-market environment and the commands, run nothing. With
#                                --broadcast, DEPLOYER_PK and ADMIN_PK must still be exported (the plan
#                                derives and checks the admin address).
#   --out <path>                 rehearse only: where the registry copy with the write-back goes.
#   --deployer-pk <hex>          rehearse only: a key other than anvil #0.
#   --force                      re-deploy a row that already has deployment.factory (not a live row).
#   --resume                     finish a row whose factory is deployed but whose Configure/Verify did not
#                                complete (deployment.factory set, deployment.configuredAt empty): skip
#                                DeploySolo, run ConfigureSolo and VerifySolo against the recorded factory.
#                                deployment.factory is written back right after the deploy transaction, so a
#                                failed batch never orphans a factory: re-run with --resume, not --force.
#
# Every forge call passes --no-storage-caching (a rehearsal mines blocks at real chain-4663 heights and
# forge's fork cache is keyed by chain id and block number: docs/DEPLOY.md) and --non-interactive.
# Output is logged to broadcast/solo-batch/<utc>/ (batch.log plus one deploy/configure/verify log and the
# forge run record per market).
#
# `set -o pipefail` is mandatory here: a piped `forge script` once hid a failure in this repository, and
# every forge call below is either unpiped with its exit code checked, or piped with pipefail on.
# -------------------------------------------------------------------------------------------------
set -euo pipefail

CALLER_PWD=$PWD   # relative --registry/--out below resolve against this, not the repo root
cd "$(dirname "$0")/.."
ROOT=$(pwd)
export PATH="$HOME/.foundry/bin:$PATH"

die() { echo "BATCH FAILED: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }
usage() { sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; }

CHAIN_EXPECT=4663
# anvil's account #0 (mnemonic "test test ... junk"), the rehearsal deployer and admin. A dev key, public.
ANVIL0_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

REGISTRY="$ROOT/../callhouse/ops/markets/tier1.json"
TICKERS=""; WAVE=""; RPC="${RH_RPC:-}"; MODE=""; OUT=""; DEPLOYER_PK_ARG=""; FORCE=0; DRY=0; RESUME=0
while [ $# -gt 0 ]; do
  case "$1" in
    --registry) REGISTRY=$2; shift 2 ;;
    --tickers) TICKERS=$2; shift 2 ;;
    --wave) WAVE=$2; shift 2 ;;
    --rpc) RPC=$2; shift 2 ;;
    --rehearse) MODE=rehearse; shift ;;
    --broadcast) MODE=broadcast; shift ;;
    --dry-run) DRY=1; shift ;;
    --out) OUT=$2; shift 2 ;;
    --deployer-pk) DEPLOYER_PK_ARG=$2; shift 2 ;;
    --force) FORCE=1; shift ;;
    --resume) RESUME=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown flag $1 (see --help)" ;;
  esac
done

# Absolutise caller-relative paths (the default registry is already absolute via $ROOT).
case "$REGISTRY" in /*) ;; *) REGISTRY="$CALLER_PWD/$REGISTRY" ;; esac
case "$OUT" in /*|"") ;; *) OUT="$CALLER_PWD/$OUT" ;; esac
[ "$FORCE" = 0 ] || [ "$RESUME" = 0 ] || die "--force and --resume are exclusive"

for tool in forge cast jq node; do command -v "$tool" >/dev/null || die "$tool not on PATH"; done
[ -f "$REGISTRY" ] || die "registry not found: $REGISTRY"
jq -e '.markets | length > 0' "$REGISTRY" >/dev/null || die "registry has no markets: $REGISTRY"
[ -n "$MODE" ] || die "one of --rehearse or --broadcast is required (add --dry-run to print the plan only)"

# ---------------------------------------------------------------- which markets
if [ -n "$WAVE" ] && [ -n "$TICKERS" ]; then die "--tickers and --wave are exclusive"; fi
if [ -n "$WAVE" ]; then
  case "$WAVE" in
    canary|wave1|wave2) TICKERS=$(jq -r --arg w "$WAVE" '[.markets[] | select(.wave==$w) | .ticker] | join(",")' "$REGISTRY") ;;
    live) die "--wave live is refused: the live market (NVDA) is never redeployed by this script" ;;
    *) die "unknown wave '$WAVE' (canary|wave1|wave2)" ;;
  esac
  [ -n "$TICKERS" ] || die "no market in wave $WAVE"
fi
[ -n "$TICKERS" ] || die "--tickers A,B,C or --wave <canary|wave1|wave2> is required"
TICKERS=$(echo "$TICKERS" | tr ',' ' ' | tr '[:lower:]' '[:upper:]')

# ---------------------------------------------------------------- mode
VERIFY_FLAGS=""
case "$MODE" in
  rehearse)
    case "$RPC" in
      http://127.0.0.1:*|http://localhost:*) ;;
      *) die "--rehearse needs a local anvil RPC (--rpc http://127.0.0.1:<port>), got '${RPC:-unset}'" ;;
    esac
    DEPLOYER_PK=${DEPLOYER_PK_ARG:-$ANVIL0_PK}
    ADMIN_PK=$DEPLOYER_PK
    WRITE_TARGET=${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/callhouse-solo-batch.XXXXXX")/tier1.rehearsal.json}
    ;;
  broadcast)
    case "$RPC" in
      ""|http://127.0.0.1:*|http://localhost:*) die "--broadcast needs a non-local --rpc (got '${RPC:-unset}'); use --rehearse against anvil" ;;
    esac
    [ -z "$DEPLOYER_PK_ARG" ] || die "--deployer-pk is for --rehearse only; --broadcast reads DEPLOYER_PK from the environment"
    [ -z "$OUT" ] || die "--out is for --rehearse only; --broadcast writes the real registry"
    [ -n "${DEPLOYER_PK:-}" ] || die "DEPLOYER_PK must be in the environment for --broadcast"
    [ -n "${ADMIN_PK:-}" ] || die "ADMIN_PK must be in the environment for --broadcast"
    VERIFY_FLAGS="--verify --verifier sourcify --chain $CHAIN_EXPECT"
    WRITE_TARGET=$REGISTRY
    ;;
esac
export DEPLOYER_PK ADMIN_PK
# Derive the deployer/admin addresses with a read-only forge script: `cast wallet address` only takes a
# key on argv, which would put it in the process table. Keys stay in the environment here, exactly as
# they do for the deploy itself.
addr_of() { # env var name -> its address
  local out
  out=$(KEY_ENV="$1" forge script script/lib/KeyAddress.s.sol --non-interactive 2>/dev/null \
    | grep -E '^[[:space:]]*0x[0-9a-fA-F]{40}[[:space:]]*$' | tail -1 | tr -d '[:space:]' || true)
  [ -n "$out" ] || die "$1 is not a valid key"
  echo "$out"
}
DEPLOYER=$(addr_of DEPLOYER_PK)
ADMIN_ADDR=$(addr_of ADMIN_PK)

# ---------------------------------------------------------------- shared contracts, env hygiene
# The forge subshells below inherit this whole environment. Pin the shared contracts from the registry
# and drop every other DeploySolo/ConfigureSolo/VerifySolo override, so a stale export in the
# operator's shell (a leftover CLEARINGHOUSE, SET_POLICY, PREFLIGHT_SKIP_CONDUIT_CONTROLLER, ...) can
# never reach a mainnet broadcast. USDG/CLEARINGHOUSE/SEAPORT absent from .shared fall back to
# DeploySolo's compiled-in defaults.
SHARED_USDG=$(jq -r '.shared.usdg // empty' "$REGISTRY")
SHARED_CLEARINGHOUSE=$(jq -r '.shared.clearinghouse // empty' "$REGISTRY")
SHARED_SEAPORT=$(jq -r '.shared.seaport // empty' "$REGISTRY")
unset SET_POLICY MIN_OTM_BPS MAX_OTM_BPS MIN_PREMIUM_BPS MAX_UTILIZATION_BPS PROTOCOL_FEE_BPS \
  MAX_CONTRACTS_CAP PREFLIGHT_SKIP_CONDUIT_CONTROLLER SAFE_ADMIN EXPECT_CHAIN_ID VALOREM_LIB \
  USDG CLEARINGHOUSE SEAPORT
[ -z "$SHARED_USDG" ] || export USDG=$SHARED_USDG
[ -z "$SHARED_CLEARINGHOUSE" ] || export CLEARINGHOUSE=$SHARED_CLEARINGHOUSE
[ -z "$SHARED_SEAPORT" ] || export SEAPORT=$SHARED_SEAPORT

# ---------------------------------------------------------------- the plan (read only)
# Plain indexed arrays: macOS ships bash 3.2, which has no associative arrays.
P_TICKER=(); P_ASSET=(); P_FEED=(); P_CAP=(); P_FEE=(); P_KEEPER=(); P_GUARDIAN=(); P_RESUME=()
for T in $TICKERS; do
  row=$(jq -c --arg t "$T" '.markets[] | select(.ticker==$t)' "$REGISTRY")
  [ -n "$row" ] || die "$T is not in the registry"
  ok=$(jq -r '.verification.ok' <<<"$row")
  [ "$ok" = true ] || die "$T: verification.ok is '$ok' (issues: $(jq -c '.verification.issues' <<<"$row")); rebuild the registry first"
  status=$(jq -r '.status' <<<"$row")
  # A superseded-by-v2 row is a v1 factory that will never exist (ADR-02: the per-market rollout was cancelled; every
  # market lists on the one v2 Clearinghouse through script/v2/DeployV2Batch.sh). Refused in every mode, --force too.
  [ "$status" != superseded-by-v2 ] || die "$T: status superseded-by-v2: the v1 factory rollout was cancelled for v2 (ADR-02); register it on v2 with script/v2/DeployV2Batch.sh, never as a v1 factory"
  existing=$(jq -r '.deployment.factory // empty' <<<"$row")
  configured=$(jq -r '.deployment.configuredAt // empty' <<<"$row")
  resume=0
  if [ -n "$existing" ] && [ "$FORCE" = 0 ]; then
    if [ -n "$configured" ]; then
      echo "skip $T: deployment.factory is already $existing (--force to redeploy)"
      continue
    fi
    # Factory deployed but Configure/Verify never completed (a previous batch died after the deploy
    # transaction). Redeploying would orphan that factory; finish the row instead.
    [ "$RESUME" = 1 ] || die "$T: deployment.factory is $existing but configuredAt is empty (--resume to finish Configure/Verify, --force to redeploy)"
    resume=1
  fi
  if [ "$MODE" = broadcast ] && [ "$status" = live ]; then die "$T is live (status live); it is never redeployed on mainnet"; fi
  asset=$(jq -r '.asset' <<<"$row"); feed=$(jq -r '.feed' <<<"$row"); cap=$(jq -r '.depositCap' <<<"$row")
  fee=$(jq -r '.deployment.feeRecipient' <<<"$row"); keeper=$(jq -r '.deployment.keeper' <<<"$row")
  guardian=$(jq -r '.deployment.guardian' <<<"$row"); admin_reg=$(jq -r '.deployment.admin' <<<"$row")
  for v in "$asset" "$feed" "$fee" "$keeper" "$guardian" "$admin_reg"; do
    case "$v" in 0x[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]*) [ ${#v} -eq 42 ] || die "$T: bad address '$v'" ;; *) die "$T: missing or bad address '$v' in the registry row" ;; esac
  done
  case "$cap" in ''|null|*[!0-9]*) die "$T: depositCap must be a decimal base-unit string, got '$cap'" ;; esac
  [ "$cap" != 0 ] || die "$T: depositCap is 0"
  if [ "$MODE" = broadcast ]; then
    [ "$admin_reg" = "$ADMIN_ADDR" ] || die "$T: registry deployment.admin $admin_reg is not the address of ADMIN_PK ($ADMIN_ADDR)"
  fi
  # The keeper is a hot key and must never be the admin or the guardian; ConfigureSolo refuses too.
  [ "$keeper" != "$guardian" ] && [ "$keeper" != "$ADMIN_ADDR" ] && [ "$guardian" != "$ADMIN_ADDR" ] \
    || die "$T: keeper, guardian and admin must be three different addresses"
  P_TICKER+=("$T"); P_ASSET+=("$asset"); P_FEED+=("$feed"); P_CAP+=("$cap"); P_FEE+=("$fee"); P_KEEPER+=("$keeper"); P_GUARDIAN+=("$guardian"); P_RESUME+=("$resume")
done
N=${#P_TICKER[@]}
[ "$N" -gt 0 ] || die "nothing to do: every selected market is deployed already"

step "plan: $MODE, $N market(s), rpc ${RPC:-<none>}"
printf '  %-6s %-42s %-42s %-24s %-42s %s\n' TICKER ASSET PRICE_FEED DEPOSIT_CAP KEEPER MODE
for ((i = 0; i < N; i++)); do
  pmode=deploy; [ "${P_RESUME[$i]}" = 1 ] && pmode=resume
  printf '  %-6s %-42s %-42s %-24s %-42s %s\n' "${P_TICKER[$i]}" "${P_ASSET[$i]}" "${P_FEED[$i]}" "${P_CAP[$i]}" "${P_KEEPER[$i]}" "$pmode"
done
echo "  usdg          ${USDG:-<DeploySolo default>}  (pinned from registry .shared)"
echo "  clearinghouse ${CLEARINGHOUSE:-<DeploySolo default>}  (pinned from registry .shared)"
echo "  seaport       ${SEAPORT:-<DeploySolo default>}  (pinned from registry .shared)"
echo "  deployer      $DEPLOYER"
echo "  admin         $ADMIN_ADDR  (DEFAULT_ADMIN_ROLE; bootstrap key, not a Safe)"
echo "  guardian      ${P_GUARDIAN[0]}"
echo "  fee recipient ${P_FEE[0]}"
echo "  write-back    $WRITE_TARGET"

if [ "$DRY" = 1 ]; then
  step "dry run: commands per market (nothing runs)"
  for ((i = 0; i < N; i++)); do
    T=${P_TICKER[$i]}
    cat <<EOF

# $T
export ASSET=${P_ASSET[$i]} PRICE_FEED=${P_FEED[$i]} DEPOSIT_CAP=${P_CAP[$i]} EXPECTED_TICKER=$T ADMIN=$ADMIN_ADDR SAFE_FEE=${P_FEE[$i]}
export KEEPER=${P_KEEPER[$i]} GUARDIAN=${P_GUARDIAN[$i]}   # DEPLOYER_PK and ADMIN_PK from the environment
forge script script/DeploySolo.s.sol --rpc-url $RPC --broadcast --slow --no-storage-caching --non-interactive $VERIFY_FLAGS
#   FACTORY, deployBlock, deployTx from broadcast/DeploySolo.s.sol/$CHAIN_EXPECT/run-latest.json; IMPL = cast call FACTORY implementation()
FACTORY=<from run-latest> forge script script/ConfigureSolo.s.sol --rpc-url $RPC --broadcast --slow --no-storage-caching
FACTORY=<...> FEE_RECIPIENT=${P_FEE[$i]} EXPECT_FRESH=true EXPECT_KEEPER_CONFIGURED=true forge script script/VerifySolo.s.sol --rpc-url $RPC --no-storage-caching
#   then node writes deployment.{factory,implementation,deployBlock,deployTx,sourcify,configuredAt} for $T into $WRITE_TARGET
EOF
  done
  exit 0
fi

# ---------------------------------------------------------------- the node
chain=$(cast chain-id --rpc-url "$RPC") || die "no RPC at $RPC"
[ "$chain" = "$CHAIN_EXPECT" ] || die "chain id $chain at $RPC, expected $CHAIN_EXPECT"
client=$(cast rpc web3_clientVersion --rpc-url "$RPC" 2>/dev/null || echo '""')
case "$MODE" in
  rehearse)
    case "$client" in '"anvil/'*) ;; *) die "--rehearse runs against anvil only; the node says $client" ;; esac
    # Chain 4663 allows 98,304 B of code, not EIP-170's 24,576 B; the anvil must be started with
    # --code-size-limit 98304 to behave like it. Probe: init code `PUSH2 0x7530 PUSH1 0 RETURN` returns a
    # 30,000 B runtime, which a default anvil refuses (rehearse-deploy.sh does the same probe).
    cast call --rpc-url "$RPC" --create 0x6175306000f3 >/dev/null 2>&1 \
      || die "this anvil refuses a 30,000 B contract: restart it with --code-size-limit 98304"
    for a in "$DEPLOYER"; do
      cast rpc anvil_setBalance "$a" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
    done
    ;;
  broadcast)
    case "$client" in '"anvil/'*) die "--broadcast against an anvil node; use --rehearse" ;; esac
    ;;
esac
FORK_BLOCK=$(cast block-number --rpc-url "$RPC")
bal=$(cast balance "$DEPLOYER" --rpc-url "$RPC")
[ "$bal" != 0 ] || die "deployer $DEPLOYER has no balance on $RPC"

# ---------------------------------------------------------------- logs, broadcast records, registry copy
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOGDIR=broadcast/solo-batch/$STAMP            # relative to the repo root: ConfigureSolo writes its batch here
mkdir -p "$LOGDIR"
exec > >(tee -a "$LOGDIR/batch.log") 2>&1
echo "log directory: $ROOT/$LOGDIR"
case "$MODE" in
  rehearse)
    # Keep the rehearsal's forge records out of broadcast/DeploySolo.s.sol/4663/, the mainnet record.
    export FOUNDRY_BROADCAST="$LOGDIR/broadcast"
    BROADCAST_DIR=$FOUNDRY_BROADCAST
    mkdir -p "$(dirname "$WRITE_TARGET")"
    cp "$REGISTRY" "$WRITE_TARGET"
    REAL_SHA_BEFORE=$(shasum -a 256 "$REGISTRY" | cut -d' ' -f1)
    echo "registry copy for write-back: $WRITE_TARGET (real registry sha256 $REAL_SHA_BEFORE)"
    ;;
  broadcast)
    BROADCAST_DIR=broadcast
    echo
    echo "MAINNET. $N market(s) will be deployed to chain $CHAIN_EXPECT at $RPC from $DEPLOYER, configured from"
    echo "$ADMIN_ADDR, verified, and written into $WRITE_TARGET."
    printf 'Type the word "deploy" to send the first transaction: '
    read -r answer
    [ "$answer" = deploy ] || die "aborted: no confirmation (nothing was sent)"
    ;;
esac

# ---------------------------------------------------------------- per market
R_FACTORY=(); R_IMPL=(); R_BLOCK=(); R_TX=(); R_GAS=(); R_CHECKS=()

# Atomic registry write-back: serialised exactly as the builder writes it (2-space JSON + newline) via
# <file>.tmp + rename, so a reader never sees a half-written registry and a crash cannot truncate it.
# Phase "deploy" records the mined factory immediately after the deploy transaction, so any later
# failure leaves a resumable row (deployment.factory set, configuredAt empty) instead of an orphan the
# skip rule would redeploy; phase "final" adds sourcify/configuredAt after Configure+Verify.
write_back() { # phase ticker factory impl block tx sourcify at
  node -e '
    const fs = require("fs");
    const [file, phase, t, factory, impl, block, tx, sourcify, at] = process.argv.slice(1);
    const reg = JSON.parse(fs.readFileSync(file, "utf8"));
    const m = reg.markets.find((x) => x.ticker === t);
    if (!m) throw new Error("no registry row for " + t);
    if (phase === "deploy") {
      m.deployment.factory = factory;
      m.deployment.implementation = impl;
      m.deployment.deployBlock = Number(block);
      m.deployment.deployTx = tx;
      m.deployment.sourcify = null;
      m.deployment.configuredAt = null;
    } else {
      if (sourcify !== "keep") m.deployment.sourcify = sourcify === "" ? null : sourcify;
      m.deployment.configuredAt = at;
    }
    const tmp = file + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(reg, null, 2) + "\n");
    fs.renameSync(tmp, file);
  ' "$WRITE_TARGET" "$@" || die "$2: write-back failed ($WRITE_TARGET)"
}

deploy_one() { # index
  local i=$1 T=${P_TICKER[$1]}
  local dlog="$LOGDIR/$T-deploy.log" clog="$LOGDIR/$T-configure.log" vlog="$LOGDIR/$T-verify.log"
  local factory tx block gas vl impl

  if [ "${P_RESUME[$i]}" = 1 ]; then
    step "$T: resume (factory already deployed; skipping DeploySolo)"
    local row
    row=$(jq -c --arg t "$T" '.markets[] | select(.ticker==$t)' "$WRITE_TARGET")
    factory=$(jq -r '.deployment.factory // empty' <<<"$row")
    impl=$(jq -r '.deployment.implementation // empty' <<<"$row")
    block=$(jq -r '.deployment.deployBlock // 0' <<<"$row")
    tx=$(jq -r '.deployment.deployTx // "-"' <<<"$row")
    [ -n "$factory" ] || die "$T: --resume but deployment.factory is empty in $WRITE_TARGET"
    gas=0; vl=""
    echo "  factory $factory  implementation ${impl:-<unrecorded>}  block $block  tx $tx  (from registry)"
  else
    step "$T: DeploySolo.s.sol"
    # Keys stay in the environment of a subshell: never on a command line, never in this log.
    (
      export ASSET=${P_ASSET[$i]} PRICE_FEED=${P_FEED[$i]} DEPOSIT_CAP=${P_CAP[$i]} EXPECTED_TICKER=$T
      export ADMIN=$ADMIN_ADDR SAFE_FEE=${P_FEE[$i]}
      # shellcheck disable=SC2086
      forge script script/DeploySolo.s.sol --rpc-url "$RPC" --broadcast --slow --no-storage-caching --non-interactive $VERIFY_FLAGS
    ) > "$dlog" 2>&1 || { tail -40 "$dlog"; die "$T: DeploySolo failed (log: $dlog)"; }
    grep -E "^\s+(ok|WARN) |preflight|^AccountFactory |^implementation |inputs \(chain|^\s+(EXPECTED_TICKER|ASSET|PRICE_FEED|USDG|CLEARINGHOUSE|SEAPORT|ADMIN|SAFE_FEE|DEPOSIT_CAP|MAX_PRICE_AGE|DEPLOYER) " "$dlog" | sed 's/^/    /' || true

    local run="$BROADCAST_DIR/DeploySolo.s.sol/$CHAIN_EXPECT/run-latest.json"
    local block_hex gas_hex status
    [ -f "$run" ] || die "$T: no broadcast record at $run — if the deploy transaction was mined, recover the factory from $dlog and write it into $WRITE_TARGET before re-running"
    factory=$(jq -r '[.transactions[] | select(.transactionType=="CREATE" and .contractName=="AccountFactory")][0].contractAddress // empty' "$run")
    [ -n "$factory" ] || die "$T: AccountFactory address not found in $run — if the deploy transaction was mined, recover the factory from $dlog and write it into $WRITE_TARGET before re-running"
    tx=$(jq -r --arg f "$factory" '[.transactions[] | select(.contractAddress==$f)][0].hash' "$run")
    block_hex=$(jq -r --arg h "$tx" '[.receipts[] | select(.transactionHash==$h)][0].blockNumber' "$run")
    gas_hex=$(jq -r --arg h "$tx" '[.receipts[] | select(.transactionHash==$h)][0].gasUsed' "$run")
    status=$(jq -r --arg h "$tx" '[.receipts[] | select(.transactionHash==$h)][0].status' "$run")
    [ "$status" = 0x1 ] || die "$T: deploy receipt status $status (factory candidate $factory in $run; do not re-run without recording it)"
    vl=$(jq -r '[(.libraries // [])[] | select(test("ValoremLib"))][0] // "" | if . == "" then "" else split(":")[2] end' "$run")
    factory=$(cast to-check-sum-address "$factory")
    block=$((block_hex)); gas=$((gas_hex))
    impl=$(cast call "$factory" "implementation()(address)" --rpc-url "$RPC") || die "$T: implementation() call failed (factory $factory IS deployed; record it in $WRITE_TARGET before re-running, or re-run with --resume after the write-back)"
    cp "$run" "$LOGDIR/$T-run-latest.json"
    echo "  factory $factory  implementation $impl  block $block  tx $tx  gas $gas  ValoremLib ${vl:-<from link site>}"

    # Record the mined factory NOW: a failure in Configure/Verify below leaves a resumable row, and a
    # re-run without --resume refuses instead of deploying a second factory for the same market.
    write_back deploy "$T" "$factory" "$impl" "$block" "$tx" "" ""
  fi

  step "$T: ConfigureSolo.s.sol (KEEPER_ROLE -> ${P_KEEPER[$i]}, GUARDIAN_ROLE -> ${P_GUARDIAN[$i]})"
  (
    export FACTORY=$factory KEEPER=${P_KEEPER[$i]} GUARDIAN=${P_GUARDIAN[$i]} DEPOSIT_CAP=${P_CAP[$i]}
    export SAFE_BATCH_OUT="$LOGDIR/$T-configure-safe-batch.json"
    forge script script/ConfigureSolo.s.sol --rpc-url "$RPC" --broadcast --slow --no-storage-caching --non-interactive
  ) > "$clog" 2>&1 || { tail -40 "$clog"; die "$T: ConfigureSolo failed (factory $factory is recorded in $WRITE_TARGET; fix and re-run with --resume; log: $clog)"; }
  grep -E "^\s+(call [0-9]|skip )|key admin executed|post-check|holds|depositCap" "$clog" | sed 's/^/    /' || true

  step "$T: VerifySolo.s.sol (fresh, configured)"
  (
    export FACTORY=$factory EXPECTED_TICKER=$T ASSET=${P_ASSET[$i]} PRICE_FEED=${P_FEED[$i]}
    export KEEPER=${P_KEEPER[$i]} GUARDIAN=${P_GUARDIAN[$i]} ADMIN=$ADMIN_ADDR FEE_RECIPIENT=${P_FEE[$i]}
    export DEPOSIT_CAP=${P_CAP[$i]} EXPECT_FRESH=true EXPECT_KEEPER_CONFIGURED=true
    [ -z "$vl" ] || export VALOREM_LIB=$vl
    forge script script/VerifySolo.s.sol --rpc-url "$RPC" --no-storage-caching --non-interactive
  ) > "$vlog" 2>&1 || { grep -E "^\s+(ok|FAIL|info)|VERIFY|Error" "$vlog" | sed 's/^/    /'; die "$T: VerifySolo failed (factory $factory is recorded in $WRITE_TARGET; fix and re-run with --resume; log: $vlog)"; }
  if grep -E "^\s+FAIL" "$vlog"; then die "$T: VerifySolo printed FAIL lines (factory $factory is recorded in $WRITE_TARGET; re-run with --resume; log: $vlog)"; fi
  local checks
  checks=$(grep -E "VERIFY PASSED" "$vlog" | sed -E 's/.*VERIFY PASSED: ([0-9]+) checks.*/\1/')
  [ -n "$checks" ] || die "$T: no VERIFY PASSED line (factory $factory is recorded in $WRITE_TARGET; re-run with --resume; log: $vlog)"
  echo "  VERIFY PASSED: $checks checks"

  step "$T: write-back -> $WRITE_TARGET"
  local sourcify="" at
  at=$(date -u +%Y-%m-%d)
  if [ "${P_RESUME[$i]}" = 1 ]; then
    sourcify=keep   # resume keeps whatever the original run recorded
  elif [ "$MODE" = broadcast ]; then
    if grep -qiE "successfully verified|already verified" "$dlog" 2>/dev/null; then sourcify="verified $(date -u +%FT%TZ)"
    elif grep -qi "sourcify" "$dlog" 2>/dev/null; then sourcify="submitted $(date -u +%FT%TZ): check $dlog"
    else sourcify="not run"; fi
  fi
  # Only deployment.{factory,implementation,deployBlock,deployTx,sourcify,configuredAt} ever change.
  write_back final "$T" "$factory" "$impl" "$block" "$tx" "$sourcify" "$at"
  jq -c --arg t "$T" '.markets[] | select(.ticker==$t) | .deployment | {factory, implementation, deployBlock, deployTx, sourcify, configuredAt}' "$WRITE_TARGET" | sed 's/^/  /'

  R_FACTORY+=("$factory"); R_IMPL+=("$impl"); R_BLOCK+=("$block"); R_TX+=("$tx"); R_GAS+=("$gas"); R_CHECKS+=("$checks")
}

for ((i = 0; i < N; i++)); do deploy_one "$i"; done

# ---------------------------------------------------------------- summary
step "BATCH PASSED ($MODE): $N market(s) on chain $CHAIN_EXPECT, starting block $FORK_BLOCK"
printf '  %-6s %-42s %-42s %-10s %-9s %s\n' TICKER FACTORY IMPLEMENTATION BLOCK GAS CHECKS
for ((i = 0; i < N; i++)); do
  printf '  %-6s %-42s %-42s %-10s %-9s %s\n' "${P_TICKER[$i]}" "${R_FACTORY[$i]}" "${R_IMPL[$i]}" "${R_BLOCK[$i]}" "${R_GAS[$i]}" "${R_CHECKS[$i]}"
done
echo "  logs      $ROOT/$LOGDIR"
echo "  registry  $WRITE_TARGET"
if [ "$MODE" = rehearse ]; then
  REAL_SHA_AFTER=$(shasum -a 256 "$REGISTRY" | cut -d' ' -f1)
  [ "$REAL_SHA_AFTER" = "$REAL_SHA_BEFORE" ] || die "the REAL registry changed during a rehearsal ($REAL_SHA_BEFORE -> $REAL_SHA_AFTER)"
  echo "  real registry untouched (sha256 $REAL_SHA_AFTER)"
fi
