#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# DeployV2Batch.sh — the Stonkhouse v2 set from the registry: DeployV2.s.sol (deploy + wire), then
# RegisterMarkets.s.sol one market at a time, then VerifyV2.s.sol, with the registry written back after
# each phase. docs/DEPLOY-V2.md is the runbook.
#
# The registry (`ops/markets/tier1.json` in stonkhousedotfun/callhouse, default ../callhouse/... from this
# repository's root) and the F2-02 recon next to it (`v2-sources.json`) are the only inputs: bash + jq read
# them and pass values to forge through `V2_*` environment variables (script/v2/lib/V2DeployBase.sol lists
# them); Solidity never parses the registry. What is written back: `v2.contracts`, `v2.deployBlock`, and per
# market `v2.registeredAt` / `v2.registerTx` (plus, on a rehearsal copy only, stand-in `v2.bots`). Nothing
# else in the file moves: 2-space JSON + newline via <file>.tmp + rename, as the builder writes it.
#
# INTERFACE_VERSION 7. The registry must say `v2.interfaceVersion: 7` or this script refuses. What v7 added to
# the registry shape: `v2.fees.premiumFeeBps` must be 0 (or at most `resaleFeeBps` — the writer fee is now
# collateral rent at mint, not a cut of the premium), a shared `v2.fees.mintFeePpm`, and an optional per-market
# `markets[i].v2.mintFeePpm` that overrides it (ceiling 5000). The bounties, the vault limits and the vault's
# `maxDailyOutflow` stay deploy-side: `V2_BOUNTY_CANCEL_STALE` (20000) and `V2_VAULT_MAX_DAILY_OUTFLOW`
# (2500000000) default from `script/v2/lib/V2DeployBase.sol` and can be overridden in the environment.
# Also from v7 (owner sign-off c10): a market may only carry a Uniswap v3 pool when the recon shows an
# observation ring of at least 2401; every launch pool but NVDA's and SPCX's is below it and its market must be
# registered Chainlink-only (no `v2.univ3Pool`, no `v2.univ3MinLiquidity`, so no payout route either).
#
#   --registry <path>        default ../callhouse/ops/markets/tier1.json. Relative --registry/--sources/--out
#                            resolve against the directory you run the script from, not the repo root.
#   --sources <path>         default v2-sources.json next to the registry (holidays, VerifierProxy, pool fees)
#   --tickers A,B | --wave canary|wave1|wave2    markets to register (registry v2.wave). A market whose
#                            v2.registeredAt is set is skipped. --deploy-only registers none.
#   --resync                 also run RegisterMarkets for selected markets that are already registered: their
#                            sources, oracle config and payout route are brought back to the registry (a changed
#                            pool or floor); registeredAt/registerTx are left as recorded. strikeTick, exercise fee
#                            and oracle of a registered market are never changed here (preflight refuses).
#   --rpc <url>              default $RH_RPC
#   --rehearse               anvil fork of 4663 only (--rpc 127.0.0.1/localhost, the node answers as anvil and
#                            accepts a 30,000 B contract). MANDATORY before --broadcast. By default every
#                            transaction is sent from the registry's shared.admin, impersonated on the fork
#                            (`--unlocked --sender`), so the rehearsal deploys exactly the roles mainnet will get;
#                            --deployer-pk <hex> sends from that key instead (it then stands in for the admin, and
#                            the rehearsal does not count for --broadcast). A null v2.bots entry gets an anvil dev
#                            account as stand-in (cranker #8, pricer #9, mmQuoter #10), written into the COPY.
#                            Write-back goes to --out (default: a fresh temp directory, printed), never the real
#                            registry (an --out path ending in ops/markets/tier1.json is refused), whose sha256 is
#                            checked unchanged at the end. `--registry X --out X` continues a rehearsal on its own
#                            copy. A passed rehearsal from a registry (not a copy) leaves rehearsal-passed.json in
#                            its log directory: the fingerprint --broadcast looks for.
#   --broadcast              mainnet. --rpc must not be local or anvil. DEPLOYER_PK (and ADMIN_PK, default
#                            DEPLOYER_PK) come from the environment, never a flag, never printed; ADMIN_PK's
#                            address must equal the registry's shared.admin; v2.bots must be set. Refuses unless a
#                            rehearsal of the SAME run passed in the last 24 h (same registry sha256, compiled
#                            bytecode, scripts, overrides, markets and phase, sent from shared.admin). Prints the
#                            plan and waits for the literal word "deploy" on stdin. Requests source publication
#                            only when EXPLORER_API_KEY is set; source publication failure alone does not turn
#                            successfully mined transactions into a failed deploy. VerifyV2 still checks bytecode.
#                            Writes the REAL registry after each phase.
#   --allow-zero-rent        --dry-run ONLY: relaxes the two rent refusals below so a registry that carries no
#                            collateral rent (an absent or 0 effective `v2.mintFeePpm`) can still be PLANNED and read.
#                            It reaches nothing: V2_ALLOW_ZERO_RENT is never exported, and the forge scripts honour the
#                            zero-rent opt-in only under `forge test` (DECISIONS-2026-09-17 §11, codex review), so no
#                            run of this wrapper -- and no hand-run `forge script` either -- can register or verify a
#                            market that charges its writers nothing. `premiumFeeBps` is 0 at launch, so the rent at
#                            mint is the only fee a writer ever pays.
#   --verify                 read-only VerifyV2 against the registry's recorded set and registered markets; no key.
#                            --expect-fresh true|false (default false: tuned parameters are info lines);
#                            --admin <addr> for a rehearsal copy deployed with --deployer-pk.
#   --resume                 finish a set whose v2.contracts are partly recorded (a run that died mid-deploy) or
#                            whose wiring is incomplete: deploy only what is missing, send only the missing wiring
#                            (parameters only where still zero, so a tuned value is never overwritten).
#                            --deploy-block <n> supplies v2.deployBlock when the dead run left no receipt of it.
#   --dry-run                print the plan and the forge commands, run nothing (no node needed).
#
# Deploy phase decision (from the file written back to): all 13 contracts null -> deploy; all 13 set with a
# deployBlock -> no deploy, but a read-only wiring check must pass (else: --resume); anything else -> --resume.
#
# Every forge call passes --no-storage-caching (a rehearsal mines blocks at real 4663 heights and forge's fork
# cache is keyed by block number: docs/DEPLOY.md) and --non-interactive. Logs, forge records and the address
# JSON go to broadcast/v2-batch/<utc>/. `set -o pipefail`: every forge call is unpiped with its exit code
# checked, or piped with pipefail on (a piped forge run once hid a failure in this repository).
# -------------------------------------------------------------------------------------------------
set -euo pipefail

CALLER_PWD=$PWD   # relative --registry/--sources/--out resolve against this, not the repo root
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
export PATH="$HOME/.foundry/bin:$PATH"

# The write-back's registerMarket lookup: REGISTER_SIG (pinned against the compiled ABI by batch-refusals.sh)
# and register_tx. In the fingerprint below, so a change to it invalidates a rehearsal.
# shellcheck source=script/v2/lib/register-tx.sh
. "$ROOT/script/v2/lib/register-tx.sh"

die() { echo "BATCH FAILED: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }
usage() { sed -n '3,/^# ----/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

CHAIN_EXPECT=4663
INTERFACE_VERSION=7
# V2Constants.MIN_POOL_OBSERVATION_CARDINALITY (SETTLEMENT_WINDOW + SNAPSHOT_GRACE + 1). Owner sign-off c10: a pool
# whose observation ring is shorter can be flooded past an expiry's window before the snapshot grace ends, so the
# market is registered CHAINLINK-ONLY instead. Every launch pool but NVDA's and SPCX's is below it.
MIN_POOL_CARDINALITY=2401
# anvil's public dev accounts ("test test ... junk"): rehearsal stand-ins for null registry bots.
ANVIL8=0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f
ANVIL9=0xa0Ee7A142d267C1f36714E4a8F75612F20a79720
ANVIL10=0xBcd4042DE499D14e55001CcbB24a551F3b954096
CONTRACT_KEYS="clearinghouse orderBook settlementOracle expiryCalendar keeperRewards autoRoller payoutAdapter makerVault makerRegistry rewardsDistributor sources.chainlink sources.univ3 sources.dataStreams"

REGISTRY="$ROOT/../callhouse/ops/markets/tier1.json"
SOURCES=""; TICKERS=""; WAVE=""; RPC="${RH_RPC:-}"; MODE=""; OUT=""; DEPLOYER_PK_ARG=""; DRY=0; RESUME=0
DEPLOY_ONLY=0; DEPLOY_BLOCK_ARG=""; EXPECT_FRESH_ARG=""; ADMIN_ARG=""; RESYNC=0; ALLOW_ZERO_RENT=0
set_mode() { [ -z "$MODE" ] || [ "$MODE" = "$1" ] || die "--$MODE and --$1 are exclusive"; MODE=$1; }
need() { [ "$1" -ge 2 ] || die "$2 needs a value"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --registry) need $# "$1"; REGISTRY=$2; shift 2 ;;
    --sources) need $# "$1"; SOURCES=$2; shift 2 ;;
    --tickers) need $# "$1"; TICKERS=$2; shift 2 ;;
    --wave) need $# "$1"; WAVE=$2; shift 2 ;;
    --rpc) need $# "$1"; RPC=$2; shift 2 ;;
    --rehearse) set_mode rehearse; shift ;;
    --broadcast) set_mode broadcast; shift ;;
    --verify) set_mode verify; shift ;;
    --dry-run) DRY=1; shift ;;
    --out) need $# "$1"; OUT=$2; shift 2 ;;
    --deployer-pk) need $# "$1"; DEPLOYER_PK_ARG=$2; shift 2 ;;
    --resume) RESUME=1; shift ;;
    --resync) RESYNC=1; shift ;;
    --allow-zero-rent) ALLOW_ZERO_RENT=1; shift ;;
    --deploy-only) DEPLOY_ONLY=1; shift ;;
    --deploy-block) need $# "$1"; DEPLOY_BLOCK_ARG=$2; shift 2 ;;
    --expect-fresh) need $# "$1"; EXPECT_FRESH_ARG=$2; shift 2 ;;
    --admin) need $# "$1"; ADMIN_ARG=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown flag $1 (see --help)" ;;
  esac
done

abs() { case "$1" in /*|"") echo "$1" ;; *) echo "$CALLER_PWD/$1" ;; esac; }
REGISTRY=$(abs "$REGISTRY"); OUT=$(abs "$OUT"); SOURCES=$(abs "$SOURCES")
[ -n "$SOURCES" ] || SOURCES="$(dirname "$REGISTRY")/v2-sources.json"

is_addr() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
checksum() { cast to-check-sum-address "$1"; }

for tool in forge cast jq node; do command -v "$tool" >/dev/null || die "$tool not on PATH"; done
[ -n "$MODE" ] || die "one of --rehearse, --broadcast or --verify is required (add --dry-run to print the plan only)"
[ -f "$REGISTRY" ] || die "registry not found: $REGISTRY"
[ -f "$SOURCES" ] || die "v2-sources.json not found: $SOURCES (--sources)"
jq -e '(.markets | length > 0) and (.shared | type == "object") and (.v2 | type == "object")' "$REGISTRY" >/dev/null \
  || die "registry has no markets, shared block or v2 block: $REGISTRY"
iv=$(jq -r '.v2.interfaceVersion' "$REGISTRY")
[ "$iv" = "$INTERFACE_VERSION" ] || die "registry v2.interfaceVersion is $iv; these scripts are INTERFACE_VERSION $INTERFACE_VERSION"
[ -z "$DEPLOY_BLOCK_ARG" ] || is_uint "$DEPLOY_BLOCK_ARG" || die "--deploy-block must be a block number"
case "$EXPECT_FRESH_ARG" in ""|true|false) ;; *) die "--expect-fresh must be true or false" ;; esac
[ -z "$ADMIN_ARG" ] || is_addr "$ADMIN_ARG" || die "--admin must be an address"
# INTERFACE_VERSION 7 release blocker (DECISIONS-2026-09-17 §11). The rent at mint is the only writer fee while
# premiumFeeBps is 0, so a market with no rent must never reach mainnet. --broadcast is refused by name first, and
# every other mode that would actually invoke forge is refused after it: the flag now only relaxes the wrapper's own
# refusals so a plan can be printed, because the scripts themselves honour the opt-in under `forge test` alone.
[ "$ALLOW_ZERO_RENT" = 0 ] || [ "$MODE" != broadcast ] || die "--allow-zero-rent is refused with --broadcast: it lets a market deploy with no collateral rent at all, and premiumFeeBps is 0 at launch, so its writers would pay nothing. Set the registry's v2.fees.mintFeePpm or the market's v2.mintFeePpm (v7 design §5.1); the flag only relaxes this wrapper's plan with --dry-run"
[ "$ALLOW_ZERO_RENT" = 0 ] || [ "$DRY" = 1 ] || die "--allow-zero-rent needs --dry-run: it relaxes this wrapper's rent refusals so a plan can be printed, and nothing else. The forge scripts honour the zero-rent opt-in only under 'forge test' (DECISIONS-2026-09-17 §11), so a run that reaches RegisterMarkets or VerifyV2 would be refused there instead. Set the registry's v2.fees.mintFeePpm or the market's v2.mintFeePpm (v7 design §5.1)"

# ---------------------------------------------------------------- mode
VERIFY_FLAGS=""; SENDER_FLAGS=""; KEYMODE=none; SOURCE_VERIFY_STATUS="not requested"
REG_ADMIN=$(jq -r '.shared.admin // empty' "$REGISTRY")
is_addr "$REG_ADMIN" || die "registry shared.admin '$REG_ADMIN' is not an address"
addr_of() { # env var name -> its address (read-only forge script: keys never reach argv)
  local out
  out=$(KEY_ENV="$1" forge script script/lib/KeyAddress.s.sol --non-interactive 2>/dev/null \
    | grep -E '^[[:space:]]*0x[0-9a-fA-F]{40}[[:space:]]*$' | tail -1 | tr -d '[:space:]' || true)
  [ -n "$out" ] || die "$1 is not a valid key"
  echo "$out"
}
local_rpc=0; case "$RPC" in http://127.0.0.1:*|http://localhost:*) local_rpc=1 ;; esac
case "$MODE" in
  rehearse)
    [ "$local_rpc" = 1 ] || die "--rehearse needs a local anvil RPC (--rpc http://127.0.0.1:<port>), got '${RPC:-unset}'"
    [ -z "$ADMIN_ARG" ] && [ -z "$EXPECT_FRESH_ARG" ] || die "--admin and --expect-fresh are for --verify"
    if [ -n "$DEPLOYER_PK_ARG" ]; then
      export DEPLOYER_PK=$DEPLOYER_PK_ARG ADMIN_PK=$DEPLOYER_PK_ARG
      KEYMODE=key
      ADMIN_ADDR=$(addr_of ADMIN_PK); DEPLOYER_ADDR=$ADMIN_ADDR
    else
      unset DEPLOYER_PK ADMIN_PK
      KEYMODE=unlocked
      ADMIN_ADDR=$(checksum "$REG_ADMIN"); DEPLOYER_ADDR=$ADMIN_ADDR
      SENDER_FLAGS="--unlocked --sender $ADMIN_ADDR"
    fi
    WRITE_TARGET=$OUT   # empty: a fresh temp directory, made when the run starts (not on --dry-run)
    if [ -n "$OUT" ]; then
      real_out=$(node -e 'const fs=require("fs"),p=require("path");const f=process.argv[1];let r;try{r=fs.realpathSync(f)}catch{try{r=p.join(fs.realpathSync(p.dirname(f)),p.basename(f))}catch{r=f}}console.log(r)' "$OUT")
      case "$real_out" in */ops/markets/tier1.json) die "--out $OUT is a registry (ops/markets/tier1.json), not a copy: a rehearsal never writes a real registry" ;; esac
    fi
    ;;
  broadcast)
    [ "$local_rpc" = 0 ] && [ -n "$RPC" ] || die "--broadcast needs a non-local --rpc (got '${RPC:-unset}'); use --rehearse against anvil"
    [ -z "$DEPLOYER_PK_ARG" ] || die "--deployer-pk is for --rehearse only; --broadcast reads DEPLOYER_PK from the environment"
    [ -z "$OUT" ] || die "--out is for --rehearse only; --broadcast writes the real registry"
    [ -z "$ADMIN_ARG" ] && [ -z "$EXPECT_FRESH_ARG" ] || die "--admin and --expect-fresh are for --verify"
    [ -n "${DEPLOYER_PK:-}" ] || die "DEPLOYER_PK must be in the environment for --broadcast"
    export DEPLOYER_PK ADMIN_PK=${ADMIN_PK:-$DEPLOYER_PK}
    KEYMODE=key
    DEPLOYER_ADDR=$(addr_of DEPLOYER_PK); ADMIN_ADDR=$(addr_of ADMIN_PK)
    [ "$(echo "$ADMIN_ADDR" | tr 'A-F' 'a-f')" = "$(echo "$REG_ADMIN" | tr 'A-F' 'a-f')" ] \
      || die "ADMIN_PK's address $ADMIN_ADDR is not the registry's shared.admin $REG_ADMIN"
    # The explorer credential is intentionally read only from the environment. Forge can complete every
    # on-chain transaction and still exit 1 when its later source-publication step lacks this credential.
    if [ -n "${EXPLORER_API_KEY:-}" ]; then
      VERIFY_FLAGS="--verify --verifier sourcify --chain $CHAIN_EXPECT"
      SOURCE_VERIFY_STATUS="requested (check publication separately)"
    else
      SOURCE_VERIFY_STATUS="skipped (EXPLORER_API_KEY unset; publish source separately)"
    fi
    WRITE_TARGET=$REGISTRY
    ;;
  verify)
    [ -z "$DEPLOYER_PK_ARG" ] && [ -z "$OUT" ] && [ "$RESUME" = 0 ] && [ "$DEPLOY_ONLY" = 0 ] && [ "$RESYNC" = 0 ] \
      || die "--verify takes no --deployer-pk, --out, --resume, --resync or --deploy-only"
    [ -z "$TICKERS" ] && [ -z "$WAVE" ] || die "--verify checks every market with v2.registeredAt; it takes no --tickers/--wave"
    unset DEPLOYER_PK ADMIN_PK
    ADMIN_ADDR=$(checksum "${ADMIN_ARG:-$REG_ADMIN}"); DEPLOYER_ADDR=""
    WRITE_TARGET=$REGISTRY
    ;;
esac
# The state (what is deployed and registered) is read from the file the write-back goes to. On a rehearsal
# that file is created from --registry below unless it IS --registry (continuing a rehearsal on its copy).
same_file() { node -e 'const fs=require("fs"),p=require("path");const r=(f)=>{try{return fs.realpathSync(f)}catch{return p.join(fs.realpathSync(p.dirname(f)),p.basename(f))}};process.exit(r(process.argv[1])===r(process.argv[2])?0:1)' "$1" "$2" 2>/dev/null; }
CONTINUE_COPY=0
if [ "$MODE" = rehearse ] && [ -f "$WRITE_TARGET" ] && same_file "$REGISTRY" "$WRITE_TARGET"; then CONTINUE_COPY=1; fi
STATE=$REGISTRY

# ---------------------------------------------------------------- shared values
jqr() { jq -r "$1" "$STATE"; }
USDG=$(jqr '.shared.usdg'); GUARDIAN=$(jqr '.shared.guardian'); FEE_RECIPIENT=$(jqr '.shared.feeRecipient')
ROUTER=$(jqr '.v2.uniswapV3.swapRouter02'); FACTORY=$(jqr '.v2.uniswapV3.factory')
VERIFIER=$(jq -r '.contracts.verifierProxy.address // empty' "$SOURCES")
for pair in "shared.usdg:$USDG" "shared.guardian:$GUARDIAN" "shared.feeRecipient:$FEE_RECIPIENT" "v2.uniswapV3.swapRouter02:$ROUTER" "v2.uniswapV3.factory:$FACTORY" "v2-sources contracts.verifierProxy.address:$VERIFIER"; do
  is_addr "${pair#*:}" || die "${pair%%:*} '${pair#*:}' is not an address"
done
HOLIDAYS=$(jq -r '[.nyseHolidays[].fullDays[].dayIndex] | sort | map(tostring) | join(",")' "$SOURCES")
[ -n "$HOLIDAYS" ] || die "no nyseHolidays fullDays in $SOURCES"
FEES=$(jq -r '.v2.fees | [.premiumFeeBps, .resaleFeeBps, .takerFeeFlat, .takerFeeCapBps, .makerRebateBps, .exerciseFeeBps] | map(tostring) | join(" ")' "$STATE")
read -r PREMIUM_FEE RESALE_FEE TAKER_FLAT TAKER_CAP MAKER_REBATE EXERCISE_FEE <<<"$FEES"
for v in "$PREMIUM_FEE" "$RESALE_FEE" "$TAKER_FLAT" "$TAKER_CAP" "$MAKER_REBATE" "$EXERCISE_FEE"; do is_uint "$v" || die "registry v2.fees has a non-integer value ($FEES)"; done
# INTERFACE_VERSION 7 (c05): a premium fee above the resale fee is the dodge it replaces -- write into a one-tick bid
# of a second address of your own, resell the long, pay the smaller of the two. DeployV2 and VerifyV2 refuse it too.
[ "$PREMIUM_FEE" -le "$RESALE_FEE" ] || die "registry v2.fees.premiumFeeBps $PREMIUM_FEE is above v2.fees.resaleFeeBps $RESALE_FEE: from INTERFACE_VERSION 7 the writer fee is collateral rent at mint (v2.fees.mintFeePpm) and premiumFeeBps is 0 at launch; a premium fee above the resale fee is avoidable by writing into your own bid and reselling"
# The shared rent rate; a market's own v2.mintFeePpm overrides it. RegisterMarkets reads V2_MINT_FEE_PPM as the
# fallback for every ticker without a V2_MARKET_<T>_MINT_FEE_PPM. ABSENT IS NOT 0 (DECISIONS-2026-09-17 §11): an
# absent block leaves every market without its own rate with no rate at all, which market_row refuses by name.
MINT_FEE_PPM=$(jq -r '.v2.fees.mintFeePpm // empty | tostring' "$STATE")
if [ -n "$MINT_FEE_PPM" ]; then
  is_uint "$MINT_FEE_PPM" || die "registry v2.fees.mintFeePpm '$MINT_FEE_PPM' is not an integer"
  [ "$MINT_FEE_PPM" -le 5000 ] || die "registry v2.fees.mintFeePpm $MINT_FEE_PPM is above MINT_FEE_CEIL_PPM (5000)"
fi
# The tail of both rent refusals, so market_row says it once.
WHY_RENT="INTERFACE_VERSION 7 charges the writer collateral rent at mint and v2.fees.premiumFeeBps is 0 at launch, so this market would charge its writers nothing. Set the rate (v7 design §5.1), or pass --allow-zero-rent for a local fixture or a devnet (never with --broadcast)"

# ---------------------------------------------------------------- contracts recorded
contract_of() { jqr ".v2.contracts.$1 // empty"; }
RECORDED=0
for k in $CONTRACT_KEYS; do
  a=$(contract_of "$k")
  if [ -n "$a" ]; then is_addr "$a" || die "registry v2.contracts.$k '$a' is not an address"; RECORDED=$((RECORDED + 1)); fi
done
DEPLOY_BLOCK=$(jqr '.v2.deployBlock // empty')
[ -z "$DEPLOY_BLOCK" ] || is_uint "$DEPLOY_BLOCK" || die "registry v2.deployBlock '$DEPLOY_BLOCK' is not a block number"
if [ "$MODE" = verify ]; then
  [ "$RECORDED" = 13 ] && [ -n "$DEPLOY_BLOCK" ] || die "--verify needs all 13 v2.contracts and v2.deployBlock recorded ($RECORDED recorded, deployBlock '${DEPLOY_BLOCK:-null}')"
  DEPLOY_PHASE=none
elif [ "$RECORDED" = 0 ]; then
  [ "$RESUME" = 0 ] || die "--resume, but no v2 contract is recorded in $STATE: run without --resume to deploy"
  DEPLOY_PHASE=fresh
elif [ "$RECORDED" = 13 ] && [ -n "$DEPLOY_BLOCK" ]; then
  DEPLOY_PHASE=check; [ "$RESUME" = 0 ] || DEPLOY_PHASE=resume
else
  [ "$RESUME" = 1 ] || die "$RECORDED of 13 v2.contracts recorded (deployBlock '${DEPLOY_BLOCK:-null}'): a deploy died half way; re-run with --resume"
  DEPLOY_PHASE=resume
fi

# ---------------------------------------------------------------- bots
BOT_NOTE=""
bot() { # name anvil-stand-in
  local v; v=$(jqr ".v2.bots.$1 // empty")
  if [ -n "$v" ]; then is_addr "$v" || die "registry v2.bots.$1 '$v' is not an address"; echo "$v"; return; fi
  [ "$MODE" = rehearse ] || die "registry v2.bots.$1 is null: run ops/v2/derive-bot-keys.sh (owner) before --$MODE"
  echo "$2"
}
CRANKER=$(bot cranker "$ANVIL8"); PRICER=$(bot pricer "$ANVIL9"); MM_QUOTER=$(bot mmQuoter "$ANVIL10")
STANDIN_BOTS=$(jqr '[.v2.bots | to_entries[] | select(.value == null) | .key] | join(",")')
[ -z "$STANDIN_BOTS" ] || BOT_NOTE="rehearsal stand-ins (anvil #8/#9/#10) for null v2.bots: $STANDIN_BOTS"

# ---------------------------------------------------------------- markets
if [ "$MODE" != verify ]; then
  if [ -n "$WAVE" ] && [ -n "$TICKERS" ]; then die "--tickers and --wave are exclusive"; fi
  if [ "$DEPLOY_ONLY" = 1 ]; then
    [ -z "$WAVE" ] && [ -z "$TICKERS" ] || die "--deploy-only registers no market; drop --tickers/--wave"
    [ "$RESYNC" = 0 ] || die "--resync needs --tickers or --wave"
  elif [ -n "$WAVE" ]; then
    case "$WAVE" in canary|wave1|wave2) ;; *) die "unknown wave '$WAVE' (canary|wave1|wave2)" ;; esac
    TICKERS=$(jq -r --arg w "$WAVE" '[.markets[] | select(.v2.wave == $w) | .ticker] | join(",")' "$STATE")
    [ -n "$TICKERS" ] || die "no market has v2.wave $WAVE"
  else
    [ -n "$TICKERS" ] || die "--tickers A,B, --wave <canary|wave1|wave2> or --deploy-only is required"
  fi
  TICKERS=$(echo "$TICKERS" | tr ',' ' ' | tr '[:lower:]' '[:upper:]')
fi

# market_row T -> "asset feed pool floor fee tick dev delay age mintFeePpm registeredAt" (validated)
market_row() {
  local T=$1 row asset feed pool floor fee tick dev delay age reg ppm card
  [[ "$T" =~ ^[A-Z0-9]+$ ]] || die "ticker '$T' is not A-Z0-9"
  row=$(jq -c --arg t "$T" '.markets[] | select(.ticker == $t)' "$STATE")
  [ -n "$row" ] || die "$T is not in the registry"
  [ "$(jq -r '.verification.ok' <<<"$row")" = true ] || die "$T: verification.ok is not true (issues: $(jq -c '.verification.issues' <<<"$row")); rebuild the registry first"
  jq -e '.v2 | type == "object"' <<<"$row" >/dev/null || die "$T: no v2 block"
  asset=$(jq -r '.asset' <<<"$row"); feed=$(jq -r '.feed' <<<"$row")
  pool=$(jq -r '.v2.univ3Pool // ""' <<<"$row"); floor=$(jq -r '.v2.univ3MinLiquidity // "0"' <<<"$row")
  tick=$(jq -r '.v2.strikeTick // ""' <<<"$row")
  # v2.defaults merged with the market's v2.overrides (registry README "v2 blocks")
  dev=$(jq -r --argjson d "$(jq -c '.v2.defaults' "$STATE")" '(.v2.overrides.maxDeviationBps // $d.maxDeviationBps) | tostring' <<<"$row")
  delay=$(jq -r --argjson d "$(jq -c '.v2.defaults' "$STATE")" '(.v2.overrides.uncorroboratedDelayS // $d.uncorroboratedDelayS) | tostring' <<<"$row")
  age=$(jq -r --argjson d "$(jq -c '.v2.defaults' "$STATE")" '(.v2.overrides.spotMaxAgeS // $d.spotMaxAgeS) | tostring' <<<"$row")
  reg=$(jq -r '.v2.registeredAt // ""' <<<"$row")
  # INTERFACE_VERSION 7 (c05): the collateral-rent rate, market override over the shared v2.fees.mintFeePpm. There is
  # no fallback to 0 (DECISIONS §11): absent stays empty here and is refused below.
  ppm=$(jq -r --argjson f "$(jq -c '.v2.fees' "$STATE")" '(.v2.mintFeePpm // .v2.overrides.mintFeePpm // $f.mintFeePpm // empty) | tostring' <<<"$row")
  is_addr "$asset" || die "$T: asset '$asset' is not an address"
  is_addr "$feed" || die "$T: feed '$feed' is not an address"
  [ -n "$tick" ] && [ "$tick" != 0 ] || die "$T: v2.strikeTick is not set"
  # The two release-blocker refusals (DECISIONS §11), before the plan is even printed. RegisterMarkets' preflight and
  # VerifyV2 refuse the same market, so a hand-run forge script cannot slip past this either.
  if [ "$ALLOW_ZERO_RENT" = 0 ]; then
    [ -n "$ppm" ] || die "$T: no collateral rent rate: neither markets[].v2.mintFeePpm nor v2.fees.mintFeePpm is set. $WHY_RENT"
    [ "$ppm" != 0 ] || die "$T: v2.mintFeePpm is 0. $WHY_RENT"
  fi
  [ -n "$ppm" ] || ppm=0
  for v in "$floor" "$tick" "$dev" "$delay" "$age" "$ppm"; do is_uint "$v" || die "$T: non-integer registry value '$v'"; done
  # V2Constants.MINT_FEE_CEIL_PPM; RegisterMarkets' preflight refuses the same, before anything is broadcast.
  [ "$ppm" -le 5000 ] || die "$T: v2.mintFeePpm $ppm is above MINT_FEE_CEIL_PPM (5000): the Clearinghouse's _checkConfig reverts CeilingExceeded"
  fee=0
  if [ -n "$pool" ]; then
    is_addr "$pool" || die "$T: v2.univ3Pool '$pool' is not an address"
    [ "$floor" != 0 ] || die "$T: v2.univ3Pool without v2.univ3MinLiquidity"
    fee=$(jq -r --arg t "$T" --arg p "$(echo "$pool" | tr 'A-F' 'a-f')" \
      '[.markets[] | select(.ticker == $t) | .pools[]? | select((.address | ascii_downcase) == $p) | .fee][0] // empty' "$SOURCES")
    is_uint "$fee" || die "$T: v2.univ3Pool $pool is not a pool of $T in $SOURCES (re-run the recon)"
    # The pool is also the market's payout route. The Clearinghouse counts at most MAX_ROUTE_FEE_BPS (100 bps) of a
    # route's fee, so a costlier tier would pay every conversion in kind; UniV3PayoutAdapter.setRoute refuses it.
    [ "$fee" -le 10000 ] || die "$T: v2.univ3Pool $pool has fee tier $fee in $SOURCES, above 10000 (1 %): the Clearinghouse counts at most MAX_ROUTE_FEE_BPS (100 bps) of a payout route's fee, so every conversion through it would pay in kind, and UniV3PayoutAdapter.setRoute refuses it (CeilingExceeded); choose a pool of 10000 or less, or none"
    # Owner sign-off c10 (DECISIONS-2026-09-17 §7). The recon already measured the ring, so this refuses before any
    # RPC call; RegisterMarkets' preflight re-reads slot0() on chain and UniV3TwapSource.setPool refuses it too.
    card=$(jq -r --arg t "$T" --arg p "$(echo "$pool" | tr 'A-F' 'a-f')" \
      '[.markets[] | select(.ticker == $t) | .pools[]? | select((.address | ascii_downcase) == $p) | .cardinality][0] // empty' "$SOURCES")
    is_uint "$card" || die "$T: v2.univ3Pool $pool has no observation cardinality in $SOURCES (re-run the recon)"
    [ "$card" -ge "$MIN_POOL_CARDINALITY" ] || die "$T: v2.univ3Pool $pool has observationCardinality $card in $SOURCES, below MIN_POOL_OBSERVATION_CARDINALITY ($MIN_POOL_CARDINALITY = SETTLEMENT_WINDOW + SNAPSHOT_GRACE + 1): one dust mint or burn per second could overwrite the expiry's window before the snapshot grace ends, and UniV3TwapSource.setPool refuses the pool (UnsupportedAsset). Register $T CHAINLINK-ONLY (drop v2.univ3Pool and v2.univ3MinLiquidity from the registry row, which also drops its payout route), or call increaseObservationCardinalityNext($MIN_POOL_CARDINALITY) on the pool, wait until slot0().observationCardinality reaches it and re-run the recon"
  else
    pool=0x0000000000000000000000000000000000000000
    [ "$floor" = 0 ] || die "$T: v2.univ3MinLiquidity without v2.univ3Pool"
  fi
  echo "$asset $feed $pool $floor $fee $tick $dev $delay $age $ppm ${reg:--}"
}

P_TICKER=(); P_ROW=(); P_REG=()
if [ "$MODE" != verify ] && [ "$DEPLOY_ONLY" = 0 ]; then
  for T in $TICKERS; do
    row=$(market_row "$T")
    reg=${row##* }
    if [ "$reg" != "-" ]; then
      if [ "$RESYNC" = 0 ]; then echo "skip $T: v2.registeredAt is already $reg (--resync re-applies its source config)"; continue; fi
      [ "$DEPLOY_PHASE" = check ] || [ "$DEPLOY_PHASE" = resume ] || die "$T has v2.registeredAt but the set is not recorded"
    fi
    P_TICKER+=("$T"); P_ROW+=("$row"); P_REG+=("$reg")
  done
fi
N=${#P_TICKER[@]}
if [ "$MODE" != verify ] && [ "$DEPLOY_ONLY" = 0 ] && [ "$N" = 0 ] && [ "$DEPLOY_PHASE" = check ]; then
  die "nothing to do: the set is deployed and every selected market is registered"
fi

# ---------------------------------------------------------------- the plan
step "plan: $MODE, deploy phase '$DEPLOY_PHASE', $N market(s) to register, rpc ${RPC:-<none>}"
echo "  registry      $REGISTRY"
echo "  sources       $SOURCES"
echo "  write-back    ${WRITE_TARGET:-<a fresh temp directory>/tier1.rehearsal.json}$([ "$CONTINUE_COPY" = 1 ] && echo '  (continuing this rehearsal copy)')"
echo "  admin         $ADMIN_ADDR  (DEFAULT_ADMIN_ROLE on every contract; registry shared.admin $REG_ADMIN)"
echo "  deployer      ${DEPLOYER_ADDR:-<none>}  ($KEYMODE)"
echo "  guardian      $GUARDIAN"
echo "  feeRecipient  $FEE_RECIPIENT"
echo "  bots          cranker $CRANKER  pricer $PRICER  mmQuoter $MM_QUOTER"
[ -z "$BOT_NOTE" ] || echo "                $BOT_NOTE"
echo "  usdg          $USDG"
echo "  uniswap v3    router $ROUTER  factory $FACTORY"
echo "  data streams  verifier $VERIFIER (DataStreamsSource deployed, never configured)"
echo "  fees          premium $PREMIUM_FEE bps, resale $RESALE_FEE bps, taker flat $TAKER_FLAT, taker cap $TAKER_CAP bps, maker rebate $MAKER_REBATE bps, exercise $EXERCISE_FEE bps"
echo "  writer rent   v2.fees.mintFeePpm ${MINT_FEE_PPM:-<unset>} shared (millionths of locked collateral per 7 days of remaining life; per-market v2.mintFeePpm overrides it, ceiling 5000)"
[ "$ALLOW_ZERO_RENT" = 0 ] || echo "  writer rent   ZERO RENT PLANNED (--allow-zero-rent, --dry-run only): a selected market carries no rent in the registry. This plan cannot be run: RegisterMarkets and VerifyV2 honour the zero-rent opt-in under 'forge test' alone (DECISIONS-2026-09-17 §11)"
echo "  holidays      $(echo "$HOLIDAYS" | tr ',' '\n' | wc -l | tr -d ' ') NYSE full-day closures"
for v in V2_PAYOUT_SLIPPAGE_BPS V2_BOUNTY_SNAPSHOT V2_BOUNTY_FINALIZE V2_BOUNTY_SETTLE V2_BOUNTY_REDEEM V2_BOUNTY_ROLL \
  V2_BOUNTY_CANCEL_STALE V2_KEEPER_DAILY_CAP V2_VAULT_MAX_SERIES_UNITS V2_VAULT_MAX_TOTAL_NOTIONAL V2_VAULT_ASK_TOLERANCE_BPS \
  V2_VAULT_MAX_BID_BPS_OF_SPOT V2_VAULT_MAX_ORDER_LIFETIME_S V2_VAULT_MAX_DAILY_OUTFLOW V2_BASE_URI V2_MAX_FEED_AGE_S; do
  if [ -n "${!v:-}" ]; then echo "  override      $v=${!v}"; fi
done
# INTERFACE_VERSION 7: the two new overrides are refused here rather than inside forge, so a bad value stops before
# any node call. DeployV2's preflight repeats both.
if [ -n "${V2_VAULT_MAX_DAILY_OUTFLOW:-}" ]; then
  is_uint "$V2_VAULT_MAX_DAILY_OUTFLOW" || die "V2_VAULT_MAX_DAILY_OUTFLOW '$V2_VAULT_MAX_DAILY_OUTFLOW' is not an integer"
  [ "$V2_VAULT_MAX_DAILY_OUTFLOW" != 0 ] || die "V2_VAULT_MAX_DAILY_OUTFLOW must be > 0 (0 deploys the MakerVault frozen: the quoter could cancel, close and place asks but never bid, take or replace upwards). Use setLimits for a spend freeze after launch, not the deploy"
fi
if [ -n "${V2_BOUNTY_CANCEL_STALE:-}" ]; then
  is_uint "$V2_BOUNTY_CANCEL_STALE" || die "V2_BOUNTY_CANCEL_STALE '$V2_BOUNTY_CANCEL_STALE' is not an integer"
  [ "$V2_BOUNTY_CANCEL_STALE" -le 1000000 ] || die "V2_BOUNTY_CANCEL_STALE $V2_BOUNTY_CANCEL_STALE is above MAX_BOUNTY (1000000)"
fi
echo "  contracts     $RECORDED of 13 recorded, deployBlock ${DEPLOY_BLOCK:-null}"
[ "$MODE" != broadcast ] || echo "  source verify  $SOURCE_VERIFY_STATUS"
if [ "$N" -gt 0 ]; then
  printf '  %-6s %-42s %-42s %-42s %-5s %-8s %-4s %-6s %-6s %-5s %s\n' TICKER ASSET FEED POOL FEE TICK DEV DELAY AGE PPM ACTION
  for ((i = 0; i < N; i++)); do
    read -r asset feed pool floor fee tick dev delay age ppm _ <<<"${P_ROW[$i]}"
    action=register; [ "${P_REG[$i]}" = "-" ] || action=resync
    printf '  %-6s %-42s %-42s %-42s %-5s %-8s %-4s %-6s %-6s %-5s %s\n' "${P_TICKER[$i]}" "$asset" "$feed" "$pool" "$fee" "$tick" "$dev" "$delay" "$age" "$ppm" "$action"
  done
  echo "  PPM = v2.mintFeePpm, the collateral rent per MINT_FEE_PERIOD (7 days) pinned into every series created after"
  echo "        registration, in millionths of the locked collateral; ceiling 5000 (INTERFACE_VERSION 7, c05)"
fi

# ---------------------------------------------------------------- environment for forge
# Drop every stale V2_* export (an env file of a v2 service sets several) except the tunable overrides the plan
# printed, then export exactly what this run means.
KEEP_OVERRIDES="V2_PAYOUT_SLIPPAGE_BPS V2_BOUNTY_SNAPSHOT V2_BOUNTY_FINALIZE V2_BOUNTY_SETTLE V2_BOUNTY_REDEEM V2_BOUNTY_ROLL V2_BOUNTY_CANCEL_STALE V2_KEEPER_DAILY_CAP V2_VAULT_MAX_SERIES_UNITS V2_VAULT_MAX_TOTAL_NOTIONAL V2_VAULT_ASK_TOLERANCE_BPS V2_VAULT_MAX_BID_BPS_OF_SPOT V2_VAULT_MAX_ORDER_LIFETIME_S V2_VAULT_MAX_DAILY_OUTFLOW V2_BASE_URI V2_MAX_FEED_AGE_S"
for v in $(compgen -v | grep '^V2_' || true); do
  case " $KEEP_OVERRIDES " in *" $v "*) ;; *) unset "$v" ;; esac
done
unset TICKERS_ENV KEY_ENV
export V2_EXPECT_CHAIN_ID=$CHAIN_EXPECT
export V2_ADMIN=$ADMIN_ADDR V2_GUARDIAN=$GUARDIAN V2_FEE_RECIPIENT=$FEE_RECIPIENT
export V2_CRANKER=$CRANKER V2_PRICER=$PRICER V2_MM_QUOTER=$MM_QUOTER
export V2_USDG=$USDG V2_SWAP_ROUTER02=$ROUTER V2_UNIV3_FACTORY=$FACTORY V2_DATA_STREAMS_VERIFIER=$VERIFIER
export V2_HOLIDAYS=$HOLIDAYS
export V2_PREMIUM_FEE_BPS=$PREMIUM_FEE V2_RESALE_FEE_BPS=$RESALE_FEE V2_TAKER_FEE_FLAT=$TAKER_FLAT
export V2_TAKER_FEE_CAP_BPS=$TAKER_CAP V2_MAKER_REBATE_BPS=$MAKER_REBATE V2_EXERCISE_FEE_BPS=$EXERCISE_FEE
# INTERFACE_VERSION 7 (c05); V2_MARKET_<T>_MINT_FEE_PPM overrides it per market. An absent shared rate is exported as
# nothing at all, never as 0: V2DeployBase refuses a market whose rate is set nowhere (DECISIONS §11).
if [ -n "$MINT_FEE_PPM" ]; then export V2_MINT_FEE_PPM=$MINT_FEE_PPM; else unset V2_MINT_FEE_PPM; fi
# The zero-rent opt-in is NEVER exported (DECISIONS-2026-09-17 §11, codex review): the forge scripts honour it under
# `forge test` alone, so exporting it would only make a stale operator variable look meaningful. Clearing it here also
# drops one an operator's shell carries in.
unset V2_ALLOW_ZERO_RENT
[ -z "$DEPLOYER_ADDR" ] || export V2_DEPLOYER=$DEPLOYER_ADDR

env_name() { # registry contract key -> V2_* name
  case "$1" in
    clearinghouse) echo V2_CLEARINGHOUSE ;; orderBook) echo V2_ORDER_BOOK ;; settlementOracle) echo V2_SETTLEMENT_ORACLE ;;
    expiryCalendar) echo V2_EXPIRY_CALENDAR ;; keeperRewards) echo V2_KEEPER_REWARDS ;; autoRoller) echo V2_AUTO_ROLLER ;;
    payoutAdapter) echo V2_PAYOUT_ADAPTER ;; makerVault) echo V2_MAKER_VAULT ;; makerRegistry) echo V2_MAKER_REGISTRY ;;
    rewardsDistributor) echo V2_REWARDS_DISTRIBUTOR ;; sources.chainlink) echo V2_SOURCE_CHAINLINK ;;
    sources.univ3) echo V2_SOURCE_UNIV3 ;; sources.dataStreams) echo V2_SOURCE_DATA_STREAMS ;;
  esac
}
export_contracts() { # from STATE
  local k a
  for k in $CONTRACT_KEYS; do
    a=$(contract_of "$k")
    if [ -n "$a" ]; then export "$(env_name "$k")=$a"; else unset "$(env_name "$k")"; fi
  done
}
export_market() { # ticker "row"
  local T=$1 asset feed pool floor fee tick dev delay age ppm
  read -r asset feed pool floor fee tick dev delay age ppm _ <<<"$2"
  export "V2_MARKET_${T}_ASSET=$asset" "V2_MARKET_${T}_FEED=$feed" "V2_MARKET_${T}_POOL=$pool"
  export "V2_MARKET_${T}_MIN_LIQUIDITY=$floor" "V2_MARKET_${T}_POOL_FEE=$fee" "V2_MARKET_${T}_STRIKE_TICK=$tick"
  export "V2_MARKET_${T}_MAX_DEVIATION_BPS=$dev" "V2_MARKET_${T}_UNCORROBORATED_DELAY_S=$delay" "V2_MARKET_${T}_SPOT_MAX_AGE_S=$age"
  # INTERFACE_VERSION 7 (c05): RegisterMarkets reads this over the shared V2_MINT_FEE_PPM, and VerifyV2 compares it
  # with the live MarketConfig.mintFeePpm.
  export "V2_MARKET_${T}_MINT_FEE_PPM=$ppm"
}

if [ "$DRY" = 1 ]; then
  step "dry run: commands (nothing runs)"
  cat <<EOF
# the V2_* environment above is exported by this script; keys (DEPLOYER_PK, ADMIN_PK) only ever from the environment
EOF
  [ "$DEPLOY_PHASE" = none ] || [ "$DEPLOY_PHASE" = check ] || echo "forge script script/v2/DeployV2.s.sol --rpc-url $RPC --broadcast --slow --no-storage-caching --non-interactive $VERIFY_FLAGS $SENDER_FLAGS"
  [ "$DEPLOY_PHASE" != check ] || echo "V2_WIRING_CHECK=true forge script script/v2/DeployV2.s.sol --rpc-url $RPC --no-storage-caching --non-interactive   # read-only"
  for ((i = 0; i < N; i++)); do
    echo "V2_TICKERS=${P_TICKER[$i]} forge script script/v2/RegisterMarkets.s.sol --rpc-url $RPC --broadcast --slow --no-storage-caching --non-interactive $SENDER_FLAGS"
    echo "#   then node writes markets[${P_TICKER[$i]}].v2.{registeredAt, registerTx} into $WRITE_TARGET"
  done
  echo "forge script script/v2/VerifyV2.s.sol --rpc-url $RPC --no-storage-caching --non-interactive   # read-only; VERIFY PASSED required"
  [ "$MODE" != broadcast ] || echo "# --broadcast first requires a passed --rehearse of this exact run (rehearsal-passed.json, 24 h)"
  exit 0
fi

# ---------------------------------------------------------------- the run's fingerprint, the rehearsal record
# A rehearsal proves one exact run: this registry file, the bytecode in out/, these scripts, the recon file, the
# tunable overrides, these markets and this deploy phase, sent from shared.admin. A passed rehearsal records that
# (rehearsal-passed.json in its log directory) and --broadcast refuses unless one matches from the last 24 h.
ARTIFACTS="ExpiryCalendar ChainlinkFeedSource UniV3TwapSource DataStreamsSource SettlementOracle Clearinghouse OrderBook KeeperRewards AutoRoller UniV3PayoutAdapter MakerRegistry MakerVault RewardsDistributor"
SELECTION=""
for ((i = 0; i < N; i++)); do
  a=register; [ "${P_REG[$i]}" = "-" ] || a=resync
  SELECTION="$SELECTION${SELECTION:+,}${P_TICKER[$i]}:$a"
done
REGISTRY_SHA=$(shasum -a 256 "$REGISTRY" | cut -d' ' -f1)
FINGERPRINT=""
if [ "$MODE" != verify ]; then
  build_log=$(mktemp "${TMPDIR:-/tmp}/v2-batch-build.XXXXXX")
  forge build > "$build_log" 2>&1 || { tail -30 "$build_log"; die "forge build failed"; }
  rm -f "$build_log"
  for a in $ARTIFACTS; do
    code=$(jq -r '.bytecode.object // ""' "out/$a.sol/$a.json" 2>/dev/null || true)
    [ "${#code}" -gt 2 ] || die "out/$a.sol/$a.json has no bytecode (forge lint writes ABI-only artifacts): delete it and run forge build"
  done
  FINGERPRINT=$(
    {
      for a in $ARTIFACTS; do printf '%s ' "$a"; jq -r '.bytecode.object' "out/$a.sol/$a.json"; done
      cat script/v2/DeployV2Batch.sh script/v2/DeployV2.s.sol script/v2/RegisterMarkets.s.sol script/v2/VerifyV2.s.sol \
        script/v2/lib/V2DeployBase.sol script/v2/lib/PinDryRun.sol script/v2/lib/register-tx.sh "$SOURCES"
      for v in $KEEP_OVERRIDES; do echo "$v=${!v:-}"; done
      echo "ALLOW_ZERO_RENT=$ALLOW_ZERO_RENT"   # a rehearsal run with the flag never clears a run without it
    } | shasum -a 256 | cut -d' ' -f1
  )
fi
find_rehearsal() { # prints the newest matching rehearsal-passed.json, or nothing
  node -e '
    const fs = require("fs"), p = require("path");
    const [dir, sha, fp, sel, phase, admin, now] = process.argv.slice(1);
    let hit = "";
    let entries = [];
    try { entries = fs.readdirSync(dir).sort(); } catch {}
    for (const e of entries) {
      const f = p.join(dir, e, "rehearsal-passed.json");
      let r;
      try { r = JSON.parse(fs.readFileSync(f, "utf8")); } catch { continue; }
      if (r.registrySha256 === sha && r.fingerprint === fp && r.markets === sel && r.deployPhase === phase
        && String(r.admin).toLowerCase() === admin.toLowerCase() && Number(now) - Number(r.passedAt) <= 86400) hit = f;
    }
    console.log(hit);
  ' broadcast/v2-batch "$REGISTRY_SHA" "$FINGERPRINT" "$SELECTION" "$DEPLOY_PHASE" "$REG_ADMIN" "$(date +%s)"
}
if [ "$MODE" = broadcast ]; then
  REHEARSAL=$(find_rehearsal)
  [ -n "$REHEARSAL" ] || die "no passed rehearsal of this exact run in the last 24 h (registry sha256 $REGISTRY_SHA, fingerprint $FINGERPRINT, markets '${SELECTION:-none}', phase $DEPLOY_PHASE): run the same selection with --rehearse against an anvil fork first (docs/DEPLOY-V2.md)"
  echo "  rehearsal     $REHEARSAL"
fi

# ---------------------------------------------------------------- the node
[ -n "$RPC" ] || die "--rpc <url> or RH_RPC is required"
chain=$(cast chain-id --rpc-url "$RPC") || die "no RPC at $RPC"
[ "$chain" = "$CHAIN_EXPECT" ] || die "chain id $chain at $RPC, expected $CHAIN_EXPECT"
client=$(cast rpc web3_clientVersion --rpc-url "$RPC" 2>/dev/null || echo '""')
case "$MODE" in
  rehearse)
    case "$client" in '"anvil/'*) ;; *) die "--rehearse runs against anvil only; the node says $client" ;; esac
    # Chain 4663 allows 98,304 B of code; the anvil must run with --code-size-limit 98304 (a 30,000 B runtime probe).
    cast call --rpc-url "$RPC" --create 0x6175306000f3 >/dev/null 2>&1 \
      || die "this anvil refuses a 30,000 B contract: restart it with --code-size-limit 98304"
    cast rpc anvil_setBalance "$ADMIN_ADDR" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
    [ "$KEYMODE" != unlocked ] || cast rpc anvil_impersonateAccount "$ADMIN_ADDR" --rpc-url "$RPC" >/dev/null
    # On 4663 the anvil dev accounts carry EIP-7702 delegation code (F2-04); stand-ins and a dev-key admin are made
    # plain EOAs on the fork so a later rehearsal step can send them tokens.
    for a in "$ADMIN_ADDR" "$CRANKER" "$PRICER" "$MM_QUOTER"; do
      code=$(cast code "$a" --rpc-url "$RPC")
      case "$code" in 0xef0100*) cast rpc anvil_setCode "$a" 0x --rpc-url "$RPC" >/dev/null; echo "  cleared EIP-7702 delegation code of $a (fork only)" ;; esac
    done
    ;;
  broadcast)
    case "$client" in '"anvil/'*) die "--broadcast against an anvil node; use --rehearse" ;; esac
    ;;
esac
HEAD_BLOCK=$(cast block-number --rpc-url "$RPC")
if [ "$MODE" != verify ]; then
  bal=$(cast balance "$DEPLOYER_ADDR" --rpc-url "$RPC")
  [ "$bal" != 0 ] || die "deployer $DEPLOYER_ADDR has no balance on $RPC"
  if [ "$ADMIN_ADDR" != "$DEPLOYER_ADDR" ]; then
    bal=$(cast balance "$ADMIN_ADDR" --rpc-url "$RPC")
    [ "$bal" != 0 ] || die "admin $ADMIN_ADDR has no balance on $RPC"
  fi
fi

# ---------------------------------------------------------------- logs, records, registry copy
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOGDIR=broadcast/v2-batch/$STAMP        # relative to the repo root: foundry.toml allows script writes under ./broadcast
mkdir -p "$LOGDIR"
exec > >(tee -a "$LOGDIR/batch.log") 2>&1
echo "log directory: $ROOT/$LOGDIR (head block $HEAD_BLOCK)"
BROADCAST_DIR=broadcast
case "$MODE" in
  rehearse)
    # Keep the rehearsal's forge records out of broadcast/<Script>/4663/, the mainnet record.
    export FOUNDRY_BROADCAST="$LOGDIR/broadcast"
    BROADCAST_DIR=$FOUNDRY_BROADCAST
    REAL_SHA_BEFORE=$(shasum -a 256 "$REGISTRY" | cut -d' ' -f1)
    [ -n "$WRITE_TARGET" ] || WRITE_TARGET=$(mktemp -d "${TMPDIR:-/tmp}/stonkhouse-v2-batch.XXXXXX")/tier1.rehearsal.json
    if [ "$CONTINUE_COPY" = 0 ]; then
      mkdir -p "$(dirname "$WRITE_TARGET")"
      cp "$REGISTRY" "$WRITE_TARGET"
      echo "registry copy for write-back: $WRITE_TARGET (source registry sha256 $REAL_SHA_BEFORE)"
    fi
    STATE=$WRITE_TARGET
    ;;
  broadcast)
    echo
    echo "MAINNET. Deploy phase '$DEPLOY_PHASE' and $N market registration(s) on chain $CHAIN_EXPECT at $RPC from"
    echo "deployer $DEPLOYER_ADDR and admin $ADMIN_ADDR, written into $WRITE_TARGET after each phase."
    printf 'Type the word "deploy" to send the first transaction: '
    read -r answer
    [ "$answer" = deploy ] || die "aborted: no confirmation (nothing was sent)"
    ;;
esac

# Atomic write-back (<file>.tmp + rename, 2-space JSON + newline, as the registry builder writes it).
write_back() { # kind args...
  node -e '
    const fs = require("fs");
    const [file, kind, ...a] = process.argv.slice(1);
    const reg = JSON.parse(fs.readFileSync(file, "utf8"));
    if (kind === "contracts") {
      const [json, block] = a;
      const got = JSON.parse(fs.readFileSync(json, "utf8"));
      const c = reg.v2.contracts;
      const put = (obj, key, v) => {
        if (v === null || v === undefined) return;
        if (obj[key] && obj[key].toLowerCase() !== v.toLowerCase()) throw new Error(`v2.contracts ${key} is ${obj[key]} in the registry, the run says ${v}: refusing to overwrite`);
        obj[key] = v;
      };
      for (const k of Object.keys(got)) if (k !== "sources") put(c, k, got[k]);
      for (const k of Object.keys(got.sources || {})) put(c.sources, k, got.sources[k]);
      if (block !== "" && reg.v2.deployBlock === null) reg.v2.deployBlock = Number(block);
    } else if (kind === "bots") {
      const [cranker, pricer, mmQuoter] = a;
      for (const [k, v] of Object.entries({ cranker, pricer, mmQuoter })) if (reg.v2.bots[k] === null) reg.v2.bots[k] = v;
    } else if (kind === "market") {
      const [t, at, tx] = a;
      const m = reg.markets.find((x) => x.ticker === t);
      if (!m) throw new Error("no registry row for " + t);
      m.v2.registeredAt = Number(at);
      m.v2.registerTx = tx;
    } else throw new Error("unknown write-back " + kind);
    const tmp = file + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(reg, null, 2) + "\n");
    fs.renameSync(tmp, file);
  ' "$WRITE_TARGET" "$@" || die "write-back ($1) failed: $WRITE_TARGET"
}

if [ "$MODE" = rehearse ] && [ -n "$STANDIN_BOTS" ]; then
  write_back bots "$(checksum "$CRANKER")" "$(checksum "$PRICER")" "$(checksum "$MM_QUOTER")"
  echo "rehearsal copy: v2.bots $STANDIN_BOTS set to the anvil stand-ins"
fi

# shellcheck disable=SC2086
run_forge() { # log script [flags...]
  local log=$1; shift
  forge script "$@" --rpc-url "$RPC" --no-storage-caching --non-interactive > "$log" 2>&1
}

# Forge's source-publication phase can fail after a fully successful broadcast. This exception is
# intentionally narrow: verification must have been requested, the log must report complete on-chain
# execution and at least one verification error (and no other Error:), and every sent transaction must
# have a successful receipt. A generic nonzero exit, missing receipt, or mixed error still fails.
source_publication_only_failure() { # forge exit code, deploy log, copied run-latest.json
  local rc=$1 log=$2 run=$3 other
  [ "$rc" != 0 ] && [ -n "$VERIFY_FLAGS" ] && [ -f "$run" ] || return 1
  grep -qFx 'ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.' "$log" || return 1
  grep -qE '^Error: (Failed to verify contract:|Not all \([0-9]+ / [0-9]+\) contracts were verified!)' "$log" || return 1
  # Any non-canonical Error: line (including indentation or an ANSI prefix) is a mixed failure, not a
  # source-publication-only failure. Prefer a false negative over masking an unrelated forge error.
  other=$(grep 'Error:' "$log" | grep -Ev '^Error: (Failed to verify contract:|Not all \([0-9]+ / [0-9]+\) contracts were verified!)' || true)
  [ -z "$other" ] || return 1
  # Counts and status alone can accept duplicated receipts while one sent transaction is missing.
  jq -e '
    [.transactions[].hash] as $tx |
    [.receipts[].transactionHash] as $rx |
    ($tx | length) > 0 and
    ($tx | length) == ($rx | length) and
    all($tx[]; type == "string" and test("^0x[0-9a-fA-F]{64}$")) and
    ($tx | unique | length) == ($tx | length) and
    ($tx | sort) == ($rx | sort) and
    all(.receipts[]; .status == "0x1")
  ' "$run" >/dev/null 2>&1
}

# ---------------------------------------------------------------- phase 1: deploy and wire
FRESH=false
case "$DEPLOY_PHASE" in
  fresh|resume)
    step "DeployV2.s.sol ($DEPLOY_PHASE)"
    export_contracts
    export V2_DEPLOY_OUT="$LOGDIR/deploy-addresses.json"
    rm -f "$V2_DEPLOY_OUT" "$BROADCAST_DIR/DeployV2.s.sol/$CHAIN_EXPECT/run-latest.json"
    rc=0
    # shellcheck disable=SC2086
    run_forge "$LOGDIR/deploy.log" script/v2/DeployV2.s.sol --broadcast --slow $VERIFY_FLAGS $SENDER_FLAGS || rc=$?
    unset V2_DEPLOY_OUT
    grep -E "^\s+(ok|WARN|skip|call) |preflight|DEPLOY DONE|V2_ADDRESS|WARNING|post-check" "$LOGDIR/deploy.log" | sed 's/^/    /' || true
    run="$BROADCAST_DIR/DeployV2.s.sol/$CHAIN_EXPECT/run-latest.json"
    [ ! -f "$run" ] || cp "$run" "$LOGDIR/deploy-run-latest.json"
    if [ -f "$LOGDIR/deploy-addresses.json" ]; then
      # Record only addresses that hold code now: the JSON is written while forge simulates, before it broadcasts.
      node -e '
        const fs = require("fs"); const { execFileSync } = require("child_process");
        const [file, rpc] = process.argv.slice(1);
        const j = JSON.parse(fs.readFileSync(file, "utf8"));
        const live = (a) => a && execFileSync("cast", ["codesize", a, "--rpc-url", rpc]).toString().trim() !== "0";
        for (const k of Object.keys(j)) if (k !== "sources" && !live(j[k])) j[k] = null;
        for (const k of Object.keys(j.sources)) if (!live(j.sources[k])) j.sources[k] = null;
        fs.writeFileSync(file + ".mined.json", JSON.stringify(j, null, 2) + "\n");
      ' "$LOGDIR/deploy-addresses.json" "$RPC" || die "could not check the deployed addresses (log: $LOGDIR/deploy.log)"
      block=""
      if [ -f "$LOGDIR/deploy-run-latest.json" ]; then
        block=$(jq -r '[.receipts[] | select(.contractAddress != null and .status == "0x1") | .blockNumber] | map(tonumber? // (ltrimstr("0x") | explode | reduce .[] as $c (0; . * 16 + (if $c >= 97 then $c - 87 elif $c >= 65 then $c - 55 else $c - 48 end)))) | min // empty' "$LOGDIR/deploy-run-latest.json")
      fi
      [ -n "$block" ] || block=$DEPLOY_BLOCK_ARG
      write_back contracts "$LOGDIR/deploy-addresses.json.mined.json" "$block"
      echo "  recorded in $WRITE_TARGET: $(jq -c '.v2.contracts' "$WRITE_TARGET")  deployBlock $(jq -r '.v2.deployBlock' "$WRITE_TARGET")"
    fi
    if source_publication_only_failure "$rc" "$LOGDIR/deploy.log" "$LOGDIR/deploy-run-latest.json"; then
      echo "  WARNING: on-chain deploy completed with successful receipts, but source publication failed."
      echo "           VerifyV2 still runs below; publish source separately and confirm it on the explorer."
      SOURCE_VERIFY_STATUS="failed (on-chain receipts succeeded; publication still required)"
      rc=0
    fi
    if [ "$rc" != 0 ]; then
      tail -40 "$LOGDIR/deploy.log"
      die "DeployV2 failed (exit $rc); mined addresses were recorded in $WRITE_TARGET. Diagnose the log and current registry before re-running: use --resume only for missing contracts or wiring, otherwise use a plain re-run (log: $LOGDIR/deploy.log)"
    fi
    [ -f "$LOGDIR/deploy-addresses.json" ] || die "DeployV2 wrote no address JSON (log: $LOGDIR/deploy.log)"
    STATE=$WRITE_TARGET
    got=0; for k in $CONTRACT_KEYS; do [ -z "$(contract_of "$k")" ] || got=$((got + 1)); done
    [ "$got" = 13 ] || die "only $got of 13 contracts recorded after a successful DeployV2 (log: $LOGDIR/deploy.log)"
    [ -n "$(jqr '.v2.deployBlock // empty')" ] || die "v2.deployBlock unknown: no CREATE receipt in this run; re-run with --resume --deploy-block <block of the first contract>"
    [ "$DEPLOY_PHASE" != fresh ] || FRESH=true
    ;;
  check)
    step "DeployV2.s.sol wiring check (read-only: the set is recorded; --resume sends missing wiring)"
    export_contracts
    V2_WIRING_CHECK=true run_forge "$LOGDIR/wiring-check.log" script/v2/DeployV2.s.sol \
      || { grep -E "^\s+PENDING|^Error: script failed|has no code|is not" "$LOGDIR/wiring-check.log" | sed 's/^/    /'; die "the recorded set's wiring is incomplete or unreadable: re-run with --resume (log: $LOGDIR/wiring-check.log)"; }
    grep -E "WIRING COMPLETE" "$LOGDIR/wiring-check.log" | sed 's/^/    /'
    ;;
esac
STATE=$WRITE_TARGET
export_contracts
DEPLOY_BLOCK=$(jqr '.v2.deployBlock // empty')

# ---------------------------------------------------------------- phase 2: markets, one at a time
R_TX=(); R_AT=()
for ((i = 0; i < N; i++)); do
  T=${P_TICKER[$i]}
  step "$T: RegisterMarkets.s.sol"
  export V2_TICKERS=$T
  export_market "$T" "${P_ROW[$i]}"
  asset_var="V2_MARKET_${T}_ASSET"; asset=${!asset_var}
  run="$BROADCAST_DIR/RegisterMarkets.s.sol/$CHAIN_EXPECT/run-latest.json"
  rm -f "$run"   # a previous ticker's record must never be read as this one's
  rc=0
  # shellcheck disable=SC2086
  run_forge "$LOGDIR/$T-register.log" script/v2/RegisterMarkets.s.sol --broadcast --slow $SENDER_FLAGS || rc=$?
  grep -E "^\s+(ok|WARN|info|call) |preflight|REGISTER DONE|post-check" "$LOGDIR/$T-register.log" | sed 's/^/    /' || true
  if [ "${P_REG[$i]}" != "-" ]; then
    # --resync of a market registered earlier: its registry row keeps the recorded registeredAt/registerTx.
    [ "$rc" = 0 ] || { tail -40 "$LOGDIR/$T-register.log"; die "$T: RegisterMarkets (resync) failed (exit $rc); re-run --resync to finish (log: $LOGDIR/$T-register.log)"; }
    echo "  resynced: $T (registeredAt ${P_REG[$i]} kept)"
    R_TX+=("resync"); R_AT+=("${P_REG[$i]}")
    continue
  fi
  tx=""; blk=""
  if [ -f "$run" ]; then
    cp "$run" "$LOGDIR/$T-run-latest.json"
    # the registerMarket call to this Clearinghouse whose first argument is this asset (script/v2/lib/register-tx.sh)
    read -r tx blk <<<"$(register_tx "$run" "$V2_CLEARINGHOUSE" "$asset")"
  fi
  if [ -z "$tx" ]; then
    # Registered by an earlier run whose write-back did not happen: find the MarketRegistered log for this asset.
    topic0=$(cast keccak "MarketRegistered(address,(bool,bool,uint64,uint16,address,uint32))")
    topic1=$(cast abi-encode "f(address)" "$asset")
    logs=$(cast logs --from-block "${DEPLOY_BLOCK:-0}" --to-block latest --address "$V2_CLEARINGHOUSE" "$topic0" "$topic1" \
      --rpc-url "$RPC" --json 2>/dev/null || echo '[]')
    tx=$(jq -r '.[-1].transactionHash // empty' <<<"$logs")
    blk=$(jq -r '.[-1].blockNumber // empty' <<<"$logs")
  fi
  if [ "$rc" != 0 ] && [ -z "$tx" ]; then
    tail -40 "$LOGDIR/$T-register.log"
    die "$T: RegisterMarkets failed (exit $rc) before registerMarket; nothing to record. Fix and re-run: completed steps are skipped (log: $LOGDIR/$T-register.log)"
  fi
  [ -n "$tx" ] && [ -n "$blk" ] || die "$T: registerMarket transaction not found in $run or the Clearinghouse's logs (log: $LOGDIR/$T-register.log)"
  at=$(cast block "$((blk))" --field timestamp --rpc-url "$RPC")
  write_back market "$T" "$at" "$tx"
  echo "  recorded: $T v2.registeredAt $at registerTx $tx (block $((blk)))"
  R_TX+=("$tx"); R_AT+=("$at")
  [ "$rc" = 0 ] || die "$T: RegisterMarkets exited $rc after registerMarket was mined (recorded); re-run to finish (log: $LOGDIR/$T-register.log)"
done

# ---------------------------------------------------------------- phase 3: verify
step "VerifyV2.s.sol (read-only against $RPC)"
REG_T=$(jq -r '[.markets[] | select(.v2.registeredAt != null) | .ticker] | join(",")' "$STATE")
UNREG=$(jq -r '[.markets[] | select(.v2.registeredAt == null) | .asset] | join(",")' "$STATE")
for T in $(echo "$REG_T" | tr ',' ' '); do row=$(market_row "$T"); export_market "$T" "$row"; done
if [ -n "$REG_T" ]; then export V2_TICKERS=$REG_T; else unset V2_TICKERS; fi
if [ -n "$UNREG" ]; then export V2_UNREGISTERED_ASSETS=$UNREG; fi
if [ "$MODE" = verify ]; then export V2_EXPECT_FRESH=${EXPECT_FRESH_ARG:-false}; else export V2_EXPECT_FRESH=$FRESH; fi
vrc=0
(unset DEPLOYER_PK ADMIN_PK; run_forge "$LOGDIR/verify.log" script/v2/VerifyV2.s.sol) || vrc=$?
if [ "$vrc" != 0 ] || grep -qE "^\s+FAIL" "$LOGDIR/verify.log"; then
  grep -E "^\s+(FAIL|info)|VERIFY|Error" "$LOGDIR/verify.log" | sed 's/^/    /'
  die "VerifyV2 failed (log: $LOGDIR/verify.log)"
fi
CHECKS=$(grep -E "VERIFY PASSED" "$LOGDIR/verify.log" | sed -E 's/.*VERIFY PASSED: ([0-9]+) checks.*/\1/')
[ -n "$CHECKS" ] || die "no VERIFY PASSED line (log: $LOGDIR/verify.log)"
grep -E "^\s+info" "$LOGDIR/verify.log" | sed 's/^/    /' || true
echo "  VERIFY PASSED: $CHECKS checks (expect fresh: $V2_EXPECT_FRESH; markets: ${REG_T:-none})"

# ---------------------------------------------------------------- summary
step "BATCH PASSED ($MODE): deploy phase '$DEPLOY_PHASE', $N market(s) registered, chain $CHAIN_EXPECT"
jq -r '.v2.contracts | to_entries[] | if .key == "sources" then (.value | to_entries[] | "  sources.\(.key) \(.value)") else "  \(.key) \(.value)" end' "$STATE"
echo "  deployBlock   $(jq -r '.v2.deployBlock' "$STATE")"
printf '  %-6s %-12s %s\n' TICKER REGISTERED_AT REGISTER_TX
for ((i = 0; i < N; i++)); do printf '  %-6s %-12s %s\n' "${P_TICKER[$i]}" "${R_AT[$i]}" "${R_TX[$i]}"; done
echo "  verify        $CHECKS checks passed"
[ "$MODE" != broadcast ] || echo "  source verify  $SOURCE_VERIFY_STATUS"
echo "  logs          $ROOT/$LOGDIR"
echo "  registry      $WRITE_TARGET"
if [ "$MODE" = rehearse ] && [ "$CONTINUE_COPY" = 0 ]; then
  REAL_SHA_AFTER=$(shasum -a 256 "$REGISTRY" | cut -d' ' -f1)
  [ "$REAL_SHA_AFTER" = "$REAL_SHA_BEFORE" ] || die "the source registry changed during a rehearsal ($REAL_SHA_BEFORE -> $REAL_SHA_AFTER)"
  echo "  source registry untouched (sha256 $REAL_SHA_AFTER)"
  if [ "$KEYMODE" = unlocked ]; then
    node -e '
      const fs = require("fs");
      const [file, sha, fp, sel, phase, admin, block, registry, copy, checks] = process.argv.slice(1);
      const r = { kind: "stonkhouse-v2-rehearsal", passedAt: Math.floor(Date.now() / 1000), registry, registrySha256: sha,
        fingerprint: fp, markets: sel, deployPhase: phase, admin, forkHeadBlock: Number(block), copy, verifyChecks: Number(checks) };
      fs.writeFileSync(file, JSON.stringify(r, null, 2) + "\n");
    ' "$LOGDIR/rehearsal-passed.json" "$REAL_SHA_BEFORE" "$FINGERPRINT" "$SELECTION" "$DEPLOY_PHASE" "$ADMIN_ADDR" \
      "$HEAD_BLOCK" "$REGISTRY" "$WRITE_TARGET" "$CHECKS" || die "could not write the rehearsal record"
    echo "  rehearsal record $ROOT/$LOGDIR/rehearsal-passed.json (--broadcast of this exact run is allowed for 24 h)"
  else
    echo "  no rehearsal record: --deployer-pk stood in for shared.admin, so this rehearsal does not clear --broadcast"
  fi
fi
