#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# DeployV2Batch.sh — the Stonkhouse v2 set from the registry: DeployV8.s.sol (deploy + wire), then
# RegisterMarkets.s.sol one market at a time, then VerifyV8.s.sol, with the registry written back after
# each phase. docs/DEPLOY-V2.md is the runbook.
#
# The registry (`ops/markets/tier1.json` in stonkhousedotfun/callhouse, default ../callhouse/... from this
# repository's root) and the F2-02 recon next to it (`v2-sources.json`) are the only inputs: bash + jq read
# them and pass values to forge through `V2_*` environment variables (script/v2/lib/V2DeployBase.sol lists
# them); Solidity never parses the registry. What is written back: `v2.contracts`, `v2.deployBlock`, and per
# market `v2.registeredAt` / `v2.registerTx` (plus, on a rehearsal copy only, stand-in `v2.bots`). Nothing
# else in the file moves: 2-space JSON + newline via <file>.tmp + rename, as the builder writes it.
#
# INTERFACE_VERSION 8. The registry must say `v2.interfaceVersion: 8` or this script refuses (`INTERFACE_VERSION=8`
# at :122, enforced at :201). What v8 requires of the registry shape: `v2.fees.premiumFeeBps` is the WRITER FEE ON
# FIRST SALE and launches at 500 — it is NOT 0, and v7's `premiumFeeBps <= resaleFeeBps` rule is DELETED. Collateral
# rent is a dial that launches at 0 instead: a shared `v2.fees.mintFeePpm` and an optional per-market
# `markets[i].v2.mintFeePpm` that overrides it (ceiling 5000, :338 shared and :473 per market). A NON-ZERO effective rate is refused
# by this wrapper unless `--allow-rent` (:476-479, the non-zero refusal at :478); rent is turned on later through `Clearinghouse.setMarketFees`
# in the 72 h MARKET_FEE_MANAGER lane, never from here (:209). The bounties, the vault limits and the vault's
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
#                            v2.registeredAt is set is skipped (unless --register-only, which still
#                            lists them). --deploy-only registers none.
#   --allow-off-launch       T-OP-104. The selection is held to the registry's root `launchSet.markets` (the
#                            owner's launch set, NVDA and SPCX; deliberately NOT derived from wave or status --
#                            the block's own note says why) and a run that selects a market outside it dies
#                            naming every offender. This flag is the deliberate, LOGGED opt-out for the
#                            post-launch waves; the plan prints the opt-out and the offenders. A registry with
#                            no launchSet block is refused outright, flag or no flag: the guard has nothing to
#                            hold the run to.
#   --skip-external a,b      T-OP-116. The six EXTERNAL_KEYS (houseVault, houseVaultFactory, hedger,
#                            rewardsDistributorLender, earnVault, stockVenueAdapter) are deployed by the
#                            externals stage (script/v2/lib/registry-env.sh registry_env_externals) right after
#                            DeployV8 -- which runs with V2_DEFER_HANDBACK=true and stops before its step 9 --
#                            each through its own script where one exists, then MapExternals.s.sol maps the
#                            supplied ones' selectors at delay 0 while the deployer still holds ADMIN, then
#                            HandBack.s.sol renounces (T-OP-153, owner decision 2026-09-22 05:35Z), then the
#                            markets and VerifyV8. This flag names externals the run must NOT deploy; the DEFAULT
#                            is the owner's window (hedger, rewardsDistributorLender, stockVenueAdapter), `none`
#                            skips nothing, a list replaces the default. Each skip is printed and
#                            V2_SKIP_EXTERNALS carries the V2_* env names to MapExternals and VerifyV8.
#                            Refused for a key whose address is already recorded or exported.
#   --register-only          no CREATE. Requires every CONTRACT_KEYS contract recorded. Registers the selection
#                            DISABLED (`IClearinghouse.registerMarket(asset, strikeTick, false)`),
#                            then `setMarketListing(asset, true, strikeTick)` as a LISTING (1 h)
#                            schedule → wait → execute from the Admin Safe, then payout routes as
#                            CONFIG_ADMIN (24 h) from `markets[].v2.payoutRoute` (`setRouteV4` when
#                            venue is v4). A null payoutRoute is reported, never skipped. Rehearsal
#                            only: V2_SCHEDULE=true warps the AccessManager delays. --no-schedule is
#                            refused: a raw EOA admin call is not this path.
#   --resync                 also run RegisterMarkets for selected markets that are already registered: their
#                            sources, oracle config and payout route are brought back to the registry (a changed
#                            pool or floor), and `enabled` is reconciled to (v2.status == live). strikeTick and
#                            mintFeePpm may change only while the market is currently disabled; exercise fee and
#                            oracle of a registered market are never changed here (preflight refuses).
#                            registeredAt/registerTx are left as recorded.
#   --rpc <url>              default $RH_RPC
#   --rehearse               anvil fork of 4663 only (--rpc 127.0.0.1/localhost, the node answers as anvil and
#                            accepts a 30,000 B contract). MANDATORY before --broadcast. By default every
#                            transaction is sent from the registry's shared.admin, impersonated on the fork
#                            (`--unlocked --sender`), so the rehearsal deploys exactly the roles mainnet will get;
#                            --deployer-pk <hex> sends from that key instead (it then stands in for the admin, and
#                            the rehearsal does not count for --broadcast). A null v2.bots entry gets an anvil dev
#                            account as stand-in (cranker #8, pricer #9, quoter #10 -- the v8 key name, :390), written into the COPY.
#                            Write-back goes to --out (default: a fresh temp directory, printed), never the real
#                            registry (an --out path ending in ops/markets/tier1.json is refused), whose sha256 is
#                            checked unchanged at the end. `--registry X --out X` continues a rehearsal on its own
#                            copy. A passed rehearsal from a registry (not a copy) leaves rehearsal-passed.json in
#                            its log directory: the fingerprint --broadcast looks for.
#   --broadcast              mainnet. --rpc must not be local or anvil. DEPLOYER_PK comes from the environment,
#                            never a flag, never printed, and is the ONLY key: :261 unsets ADMIN_PK, because
#                            under INTERFACE_VERSION 8 shared.admin IS the Admin Safe and a Safe never signs a
#                            deploy tx (:265). Do NOT export ADMIN_PK -- there is no key for that address, and
#                            :267-270 REFUSES a --broadcast whose shared.admin has no code, so a registry where
#                            admin were an EOA is the thing that fails, not the other way round. v2.bots must be set. Refuses unless a
#                            rehearsal of the SAME run passed in the last 24 h (same registry sha256, compiled
#                            bytecode, pinned deployed runtimes, scripts, overrides, markets and phase, sent from
#                            shared.admin). Prints the plan and waits for the literal word "deploy" on stdin.
#                            Requests source publication only when EXPLORER_API_KEY is set; source publication
#                            failure alone does not turn successfully mined transactions into a failed deploy.
#                            VerifyV8 still checks bytecode.
#                            Writes the REAL registry after each phase.
#   --allow-rent        --dry-run ONLY, and it relaxes the refusal in the OPPOSITE direction from what this help
#                            used to say. INTERFACE_VERSION 8 INVERTED the rent refusals (:474-479): the thing refused
#                            now is a NON-ZERO effective `v2.mintFeePpm`, and `--allow-rent` is what lets such a
#                            registry be PLANNED. An ABSENT rate is refused only WITHOUT the flag: that refusal
#                            (:477) sits INSIDE the same `if [ "$ALLOW_RENT" = 0 ]` block (:476-479)
#                            as the non-zero one, so the flag relaxes BOTH and :480 then defaults ppm to 0.
#                            That contradicts :452 ("absent stays empty here and is refused below")
#                            and :210's own "and nothing else". Raised as a behaviour bug, not fixed
#                            here (this row does not change behaviour). The flag is refused outright with
#                            `--broadcast` (:209) and requires `--dry-run` (:210).
#                            It reaches nothing: `V2_ALLOW_RENT` is never exported and is explicitly unset (:634) and the forge scripts
#                            honour the rent opt-in only under `forge test`, so no run of this wrapper -- and no
#                            hand-run `forge script` either -- can register or verify a market that charges rent.
#                            `premiumFeeBps` is 500 at launch, so the premium fee, not the rent, is what a writer
#                            pays on a first sale.
#   --verify                 read-only VerifyV8 against the registry's recorded set and registered markets; no key.
#                            --expect-fresh true|false (default false: tuned parameters are info lines);
#                            --admin <addr> for a rehearsal copy deployed with --deployer-pk.
#   --resume                 finish a set whose v2.contracts are partly recorded (a run that died mid-deploy) or
#                            whose wiring is incomplete: deploy only what is missing, send only the missing wiring
#                            (parameters only where still zero, so a tuned value is never overwritten).
#                            --deploy-block <n> supplies v2.deployBlock when the dead run left no receipt of it.
#   --dry-run                print the plan and the forge commands, run nothing (no node needed).
#
# Deploy phase decision (from the file written back to): all 16 contracts null -> deploy; all 16 set with a
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
# T-OP-113. THE REGISTRY -> V2_* PROJECTION lives in one library with two callers: this wrapper and the launch
# driver script/v2/broadcast-v8.sh. Sourced BEFORE any registry read; `die` above is what it refuses with.
. "$ROOT/script/v2/lib/registry-env.sh"

die() { echo "BATCH FAILED: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }
usage() { sed -n '3,/^# ----/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

CHAIN_EXPECT=4663
INTERFACE_VERSION=8
# MIN_POOL_CARDINALITY, the anvil stand-ins ANVIL8/9/10 and CONTRACT_KEYS (sixteen contracts IN DEPLOY ORDER) are
# defined by script/v2/lib/registry-env.sh, sourced above: ONE list, read by this wrapper and by broadcast-v8.sh.

# THE RECORDED-SET SIZE IS DERIVED, NEVER A LITERAL. `= 16` was hard-coded in six places against a list that v8
# had already changed once. Bumping the literal to match is the fix that hides the NEXT change instead of
# catching it: the literal and the list would agree again and nothing would compare them. This counts the list.
NKEYS=$(printf '%s\n' $CONTRACT_KEYS | wc -l | tr -d ' ')
[ "$NKEYS" -gt 0 ] || die "CONTRACT_KEYS is empty: the recorded-set size cannot be derived"

REGISTRY="$ROOT/../callhouse/ops/markets/tier1.json"
SOURCES=""; TICKERS=""; WAVE=""; RPC="${RH_RPC:-}"; MODE=""; OUT=""; DEPLOYER_PK_ARG=""; DRY=0; RESUME=0
DEPLOY_ONLY=0; DEPLOY_BLOCK_ARG=""; EXPECT_FRESH_ARG=""; ADMIN_ARG=""; RESYNC=0; ALLOW_RENT=0
REGISTER_ONLY=0; NO_SCHEDULE=0; LIST_PASS=0; ALLOW_OFF_LAUNCH=0; SKIP_EXTERNAL=""
ROLES_JSON=${ROLES_JSON:-$ROOT/script/v2/roles.v8.json}
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
    --allow-rent) ALLOW_RENT=1; shift ;;
    --deploy-only) DEPLOY_ONLY=1; shift ;;
    --register-only) REGISTER_ONLY=1; shift ;;
    --no-schedule) NO_SCHEDULE=1; shift ;;
    --allow-off-launch) ALLOW_OFF_LAUNCH=1; shift ;;
    --skip-external) need $# "$1"; SKIP_EXTERNAL=$2; shift 2 ;;
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

# is_addr, is_uint and checksum: script/v2/lib/registry-env.sh.

for tool in forge cast jq node; do command -v "$tool" >/dev/null || die "$tool not on PATH"; done
[ -n "$MODE" ] || die "one of --rehearse, --broadcast or --verify is required (add --dry-run to print the plan only)"
[ "$REGISTER_ONLY" = 0 ] || [ "$DEPLOY_ONLY" = 0 ] || die "--register-only and --deploy-only are exclusive"
[ -f "$ROLES_JSON" ] || die "roles.v8.json not found: $ROLES_JSON"
LISTING_ROLE=$(jq -r '.targets.Clearinghouse["registerMarket(address,uint64,bool)"]' "$ROLES_JSON")
LISTING_SET=$(jq -r '.targets.Clearinghouse["setMarketListing(address,bool,uint64)"]' "$ROLES_JSON")
ROUTE_ROLE=$(jq -r '.targets.PayoutRouter["setRouteV4(address,uint24,int24)"]' "$ROLES_JSON")
LISTING_DELAY=$(jq -r '.delaysS.LISTING' "$ROLES_JSON")
CONFIG_DELAY=$(jq -r '.delaysS.CONFIG_ADMIN' "$ROLES_JSON")
[ "$LISTING_ROLE" = LISTING ] || die "registerMarket is mapped to $LISTING_ROLE, not LISTING ($ROLES_JSON)"
[ "$LISTING_SET" = LISTING ] || die "setMarketListing is mapped to $LISTING_SET, not LISTING ($ROLES_JSON)"
[ "$ROUTE_ROLE" = CONFIG_ADMIN ] || die "setRouteV4 is mapped to $ROUTE_ROLE, not CONFIG_ADMIN (a LISTING-lane route is refused)"
[ "$LISTING_DELAY" = 3600 ] || die "LISTING delay is $LISTING_DELAY s, not 3600 (roles.v8.json delaysS.LISTING)"
[ "$CONFIG_DELAY" = 86400 ] || die "CONFIG_ADMIN delay is $CONFIG_DELAY s, not 86400 (roles.v8.json delaysS.CONFIG_ADMIN)"
[ -f "$REGISTRY" ] || die "registry not found: $REGISTRY"
[ -f "$SOURCES" ] || die "v2-sources.json not found: $SOURCES (--sources)"
jq -e '(.markets | length > 0) and (.shared | type == "object") and (.v2 | type == "object")' "$REGISTRY" >/dev/null \
  || die "registry has no markets, shared block or v2 block: $REGISTRY"
iv=$(jq -r '.v2.interfaceVersion' "$REGISTRY")
[ "$iv" = "$INTERFACE_VERSION" ] || die "registry v2.interfaceVersion is $iv; these scripts are INTERFACE_VERSION $INTERFACE_VERSION"
[ -z "$DEPLOY_BLOCK_ARG" ] || is_uint "$DEPLOY_BLOCK_ARG" || die "--deploy-block must be a block number"
case "$EXPECT_FRESH_ARG" in ""|true|false) ;; *) die "--expect-fresh must be true or false" ;; esac
[ -z "$ADMIN_ARG" ] || is_addr "$ADMIN_ARG" || die "--admin must be an address"
# T-OP-116: the skip list's NAMES are refused here, with the other flags, so a typo dies before the plan; the
# recorded/exported refusals need the registry and the scrubbed environment and run in externals_parse_skip.
for k in $(echo "$SKIP_EXTERNAL" | tr ',' ' '); do
  [ "$k" != none ] || continue
  case " $EXTERNAL_KEYS " in *" $k "*) ;; *) die "--skip-external $k: not one of the six externals ($EXTERNAL_KEYS), nor 'none'" ;; esac
done
# INTERFACE_VERSION 7 release blocker (DECISIONS-2026-09-17 §11). The rent at mint is the only writer fee while
# premiumFeeBps is 0, so a market with no rent must never reach mainnet. --broadcast is refused by name first, and
# every other mode that would actually invoke forge is refused after it: the flag now only relaxes the wrapper's own
# refusals so a plan can be printed, because the scripts themselves honour the opt-in under `forge test` alone.
[ "$ALLOW_RENT" = 0 ] || [ "$MODE" != broadcast ] || die "--allow-rent is refused with --broadcast: it lets a market deploy with a non-zero collateral rent from an immediate unreviewed script. Rent is turned on afterwards through Clearinghouse.setMarketFees in the 72 h MARKET_FEE_MANAGER lane (V8-DESIGN.md §4.3). The flag only relaxes this wrapper's plan with --dry-run"
[ "$ALLOW_RENT" = 0 ] || [ "$DRY" = 1 ] || die "--allow-rent needs --dry-run: it relaxes this wrapper's non-zero-rent refusals so a plan can be printed, and nothing else. The forge scripts honour V2_ALLOW_RENT only under 'forge test', so a run that reaches RegisterMarkets or VerifyV8 would be refused there instead"

# ---------------------------------------------------------------- mode
VERIFY_FLAGS=""; SENDER_FLAGS=""; DEPLOY_SENDER_FLAGS=""; KEYMODE=none; SOURCE_VERIFY_STATUS="not requested"
REG_ADMIN=$(jq -r '.shared.safes.admin // .shared.admin // empty' "$REGISTRY")
REG_TREASURY=$(jq -r '.shared.safes.treasury // empty' "$REGISTRY")
is_addr "$REG_ADMIN" || die "registry shared.safes.admin/shared.admin '$REG_ADMIN' is not an address"
addr_of() { # env var name -> its address (read-only forge script: keys never reach argv)
  local out
  out=$(KEY_ENV="$1" forge script script/lib/KeyAddress.s.sol --non-interactive 2>/dev/null \
    | grep -E '^[[:space:]]*0x[0-9a-fA-F]{40}[[:space:]]*$' | tail -1 | tr -d '[:space:]' || true)
  [ -n "$out" ] || die "$1 is not a valid key"
  echo "$out"
}
local_rpc=0; case "$RPC" in http://127.0.0.1:*|http://localhost:*) local_rpc=1 ;; esac
# T-OP-161: an ADMIN_PK supplied from OUTSIDE is refused in every mode, before anything runs. The register step
# is the deployer's; `--rehearse --deployer-pk` sets ADMIN_PK to that same key INTERNALLY below (the shape
# RegisterMarkets' single-run path accepts) and --broadcast derives it from DEPLOYER_PK at the register step.
registry_env_refuse_admin_pk
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
      ADMIN_ADDR=$(checksum "$REG_ADMIN")
      # INTERFACE_VERSION 8: THE DEPLOYER IS NOT THE ADMIN. It is the AccessManager's initial ADMIN --
      # it maps the selectors, grants the Safe its roles and then renounces everything (DeployV8.s.sol
      # :48-61) -- and `_principals` requires seven DISTINCT addresses. A rehearsal that sent the
      # deploy from the Safe could not preflight, so the deploy and the admin calls have separate
      # senders: anvil's key #0 deploys, the Safe signs nothing and is impersonated for admin calls.
      DEPLOYER_ADDR=$(checksum "${REHEARSAL_DEPLOYER:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}")
      [ "$DEPLOYER_ADDR" != "$ADMIN_ADDR" ] \
        || die "the rehearsal deployer $DEPLOYER_ADDR is shared.safes.admin: v8 needs seven distinct principals (set REHEARSAL_DEPLOYER)"
      SENDER_FLAGS="--unlocked --sender $ADMIN_ADDR"
      DEPLOY_SENDER_FLAGS="--unlocked --sender $DEPLOYER_ADDR"
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
    export DEPLOYER_PK
    unset ADMIN_PK
    KEYMODE=key
    DEPLOYER_ADDR=$(addr_of DEPLOYER_PK)
    ADMIN_ADDR=$(checksum "$REG_ADMIN")
    # INTERFACE_VERSION 8: the Admin Safe never signs a deploy tx. The deployer is the only key.
    # A non-local --broadcast refuses a code-less V2_ADMIN_SAFE (DeployV8 preflight).
    if [ "$DRY" = 0 ] && [ -n "$RPC" ] && [ "$local_rpc" = 0 ]; then
      acode=$(cast code "$ADMIN_ADDR" --rpc-url "$RPC" 2>/dev/null || true)
      if [ "$acode" = 0x ] || [ "$acode" = "0x" ]; then
        die "V2_ADMIN_SAFE $ADMIN_ADDR has no code on $RPC: INTERFACE_VERSION 8 admin is a Safe, not a key"
      fi
    fi
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
      && [ "$REGISTER_ONLY" = 0 ] \
      || die "--verify takes no --deployer-pk, --out, --resume, --resync, --deploy-only or --register-only"
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
# Every shared read and its refusal -- shared.*, v2.uniswapV3, the v2-sources contracts block, the STONKHOUSE pool
# key, holidays, v2.fees and the shared rent rate -- is registry_env_read_shared in script/v2/lib/registry-env.sh
# (T-OP-113). The comments explaining each value moved with the code.
registry_env_read_shared

# ---------------------------------------------------------------- contracts recorded
# contract_of, RECORDED and DEPLOY_BLOCK: registry_env_read_contracts in script/v2/lib/registry-env.sh (T-OP-113).
registry_env_read_contracts
if [ "$MODE" = verify ]; then
  [ "$RECORDED" = "$NKEYS" ] && [ -n "$DEPLOY_BLOCK" ] || die "--verify needs all $NKEYS v2.contracts and v2.deployBlock recorded ($RECORDED recorded, deployBlock '${DEPLOY_BLOCK:-null}')"
  DEPLOY_PHASE=none
elif [ "$RECORDED" = 0 ]; then
  [ "$RESUME" = 0 ] || die "--resume, but no v2 contract is recorded in $STATE: run without --resume to deploy"
  DEPLOY_PHASE=fresh
elif [ "$RECORDED" = "$NKEYS" ] && [ -n "$DEPLOY_BLOCK" ]; then
  DEPLOY_PHASE=check; [ "$RESUME" = 0 ] || DEPLOY_PHASE=resume
else
  [ "$RESUME" = 1 ] || die "$RECORDED of $NKEYS v2.contracts recorded (deployBlock '${DEPLOY_BLOCK:-null}'): a deploy died half way; re-run with --resume"
  DEPLOY_PHASE=resume
fi
if [ "$REGISTER_ONLY" = 1 ]; then
  [ "$RECORDED" = "$NKEYS" ] && [ -n "$DEPLOY_BLOCK" ] \
    || die "--register-only needs all $NKEYS v2.contracts and v2.deployBlock recorded ($RECORDED recorded, deployBlock '${DEPLOY_BLOCK:-null}')"
fi

# ---------------------------------------------------------------- bots
# bot() and the stand-in note: registry_env_read_bots in script/v2/lib/registry-env.sh (T-OP-113).
registry_env_read_bots

# ---------------------------------------------------------------- markets
if [ "$MODE" != verify ]; then
  if [ -n "$WAVE" ] && [ -n "$TICKERS" ]; then die "--tickers and --wave are exclusive"; fi
  if [ "$DEPLOY_ONLY" = 1 ]; then
    [ -z "$WAVE" ] && [ -z "$TICKERS" ] || die "--deploy-only registers no market; drop --tickers/--wave"
    [ "$RESYNC" = 0 ] || die "--resync needs --tickers or --wave"
    # --no-schedule is meaningful here: a deploy-only run predates the handover and sends nothing delayed.
  elif [ -n "$WAVE" ]; then
    case "$WAVE" in canary|wave1|wave2) ;; *) die "unknown wave '$WAVE' (canary|wave1|wave2)" ;; esac
    # TWO SOURCES, AND THEY MUST AGREE. The production registry carries the waves only in the
    # top-level `waves` map (every `markets[].v2.wave` there is null); the v8 fixture carries them
    # only per market. Reading one alone silently selected nothing against the other file, so read
    # both, refuse a disagreement, and accept whichever one is populated.
    W_TOP=$(jq -r --arg w "$WAVE" '[(.waves[$w] // [])[]] | sort | join(",")' "$STATE")
    W_ROW=$(jq -r --arg w "$WAVE" '[.markets[] | select(.v2.wave == $w) | .ticker] | sort | join(",")' "$STATE")
    if [ -n "$W_TOP" ] && [ -n "$W_ROW" ] && [ "$W_TOP" != "$W_ROW" ]; then
      die "wave '$WAVE' disagrees between the two sources: waves.$WAVE is [$W_TOP] but markets[].v2.wave says [$W_ROW]; fix the registry, a launch set cannot have two answers"
    fi
    TICKERS=${W_ROW:-$W_TOP}
    [ -n "$TICKERS" ] || die "no market is in wave $WAVE (neither waves.$WAVE nor any markets[].v2.wave)"
  else
    [ -n "$TICKERS" ] || die "--tickers A,B, --wave <canary|wave1|wave2> or --deploy-only is required"
  fi
  # A run with markets registers or lists, and both are LISTING operations behind a delay once the
  # manager holds the roles. Refusing here, rather than unconditionally at parse time, means the flag
  # is rejected for what the run would actually do: --deploy-only and --verify still accept it.
  if [ "$DEPLOY_ONLY" = 0 ]; then
    [ "$NO_SCHEDULE" = 0 ] || die "registerMarket is a LISTING operation (1 h); schedule it, do not send from a raw EOA"
  fi
  # Uppercases and space-separates TICKERS, then THE LAUNCH-SET GUARD (T-OP-104): registry_env_launch_guard in
  # script/v2/lib/registry-env.sh, shared with broadcast-v8.sh so the driver is held to the same launch set.
  registry_env_launch_guard
fi

# market_row T -> "asset feed pool floor fee tick dev delay age mintFeePpm enabled registeredAt" (validated):
# script/v2/lib/registry-env.sh (T-OP-113).

P_TICKER=(); P_ROW=(); P_REG=(); S_TICKER=(); S_ROW=()
if [ "$MODE" != verify ] && [ "$DEPLOY_ONLY" = 0 ]; then
  for T in $TICKERS; do
    row=$(market_row "$T")
    reg=${row##* }
    S_TICKER+=("$T"); S_ROW+=("$row")
    if [ "$reg" != "-" ]; then
      if [ "$RESYNC" = 0 ]; then echo "skip $T: v2.registeredAt is already $reg (--resync reconciles enabled and source config)"; continue; fi
      [ "$DEPLOY_PHASE" = check ] || [ "$DEPLOY_PHASE" = resume ] || die "$T has v2.registeredAt but the set is not recorded"
    fi
    P_TICKER+=("$T"); P_ROW+=("$row"); P_REG+=("$reg")
  done
fi
N=${#P_TICKER[@]}
if [ "$MODE" != verify ] && [ "$DEPLOY_ONLY" = 0 ] && [ "$N" = 0 ] && [ "$DEPLOY_PHASE" = check ] && [ "$REGISTER_ONLY" = 0 ]; then
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
echo "  feeRecipient  ${FEE_RECIPIENT:-<the FeeSplitter this run deploys>}"
echo "  bots          cranker $CRANKER  pricer $PRICER  quoter $MM_QUOTER"
[ -z "$BOT_NOTE" ] || echo "                $BOT_NOTE"
if [ "$MODE" != verify ]; then
  if [ -n "$OFF_LAUNCH" ]; then
    echo "  launch set    [$LAUNCH_SET]  OFF-LAUNCH OPT-OUT (--allow-off-launch): registering $(echo "$OFF_LAUNCH" | tr ',' '\n' | grep -c .) market(s) outside it: $OFF_LAUNCH"
  else
    echo "  launch set    [$LAUNCH_SET]  every selected market is in it$([ "$ALLOW_OFF_LAUNCH" = 1 ] && echo ' (--allow-off-launch passed, unused)')"
  fi
fi
echo "  usdg          $USDG"
echo "  uniswap v3    router $ROUTER  factory $FACTORY"
echo "  data streams  verifier $VERIFIER (DataStreamsSource deployed, never configured)"
echo "  fees          premium $PREMIUM_FEE bps, resale $RESALE_FEE bps, taker flat $TAKER_FLAT, taker cap $TAKER_CAP bps, maker rebate $MAKER_REBATE bps, exercise $EXERCISE_FEE bps"
echo "  writer rent   v2.fees.mintFeePpm ${MINT_FEE_PPM:-<unset>} shared (millionths of locked collateral per 7 days of remaining life; per-market v2.mintFeePpm overrides it, ceiling 5000)"
[ "$ALLOW_RENT" = 0 ] || echo "  writer rent   NON-ZERO RENT PLANNED (--allow-rent, --dry-run only): a selected market carries a non-zero collateral rent in the registry, which this wrapper refuses without the flag. This plan cannot be run: rent reaches a market only through Clearinghouse.setMarketFees in the 72 h MARKET_FEE_MANAGER lane, and the forge scripts honour the rent opt-in under 'forge test' alone"
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
echo "  contracts     $RECORDED of $NKEYS recorded, deployBlock ${DEPLOY_BLOCK:-null}"
# T-OP-116: the six externals, recorded or not, and what this run does about each (the stage itself runs
# after the markets, before VerifyV8; --verify only tells VerifyV8 which ones are skipped).
ext_plan=""
case "$SKIP_EXTERNAL" in "") SKIP_PLAN=$(echo "$EXTERNAL_SKIP_DEFAULT" | tr ' ' ',') ;; none) SKIP_PLAN="" ;; *) SKIP_PLAN=$SKIP_EXTERNAL ;; esac
for k in $EXTERNAL_DEPLOY_ORDER; do
  a=$(contract_of "$k")
  case ",$SKIP_PLAN," in *",$k,"*) ext_plan="$ext_plan $k:skip" ;; *)
    if [ -n "$a" ]; then ext_plan="$ext_plan $k:recorded"
    elif [ -n "$(external_script_of "$k")" ]; then ext_plan="$ext_plan $k:deploy"
    elif [ "$k" = stockVenueAdapter ]; then ext_plan="$ext_plan $k:with-earnVault-if-venue"
    elif [ "$k" = houseVault ]; then ext_plan="$ext_plan $k:with-houseVaultFactory"
    else ext_plan="$ext_plan $k:no-script"; fi ;;
  esac
done
echo "  externals    $ext_plan  (skip list: ${SKIP_PLAN:-none}$([ -z "$SKIP_EXTERNAL" ] && echo ', the owner window' || true); then MapExternals + HandBack, T-OP-153)"
[ "$MODE" != verify ] || [ -z "$SKIP_EXTERNAL" ] || echo "                --skip-external on --verify only tells VerifyV8 (V2_SKIP_EXTERNALS)"
[ "$REGISTER_ONLY" = 0 ] || echo "  register-only  ENABLED=false then LISTING setMarketListing (${LISTING_DELAY}s) / routes CONFIG_ADMIN (${CONFIG_DELAY}s)"
[ "$MODE" != broadcast ] || echo "  source verify  $SOURCE_VERIFY_STATUS"
if [ "$N" -gt 0 ]; then
  printf '  %-6s %-42s %-42s %-42s %-5s %-8s %-4s %-6s %-6s %-5s %-5s %s\n' TICKER ASSET FEED POOL FEE TICK DEV DELAY AGE PPM EN ACTION
  for ((i = 0; i < N; i++)); do
    read -r asset feed pool floor fee tick dev delay age ppm enabled _ <<<"${P_ROW[$i]}"
    action=register; [ "${P_REG[$i]}" = "-" ] || action=resync
    printf '  %-6s %-42s %-42s %-42s %-5s %-8s %-4s %-6s %-6s %-5s %-5s %s\n' "${P_TICKER[$i]}" "$asset" "$feed" "$pool" "$fee" "$tick" "$dev" "$delay" "$age" "$ppm" "$enabled" "$action"
  done
  echo "  PPM = v2.mintFeePpm, the collateral rent per MINT_FEE_PERIOD (7 days) pinned into every series created after"
  echo "        registration, in millionths of the locked collateral; ceiling 5000 (INTERFACE_VERSION 7, c05)"
  echo "  EN  = enabled on register/resync: true iff registry v2.status == live (C3-102 staged listing)"
  [ "$REGISTER_ONLY" = 0 ] || echo "  EN  = forced false on --register-only (listing is a later LISTING-lane setMarketListing)"
  PAY_N=$N
  [ "$REGISTER_ONLY" = 0 ] || PAY_N=${#S_TICKER[@]}
  for ((i = 0; i < PAY_N; i++)); do
    if [ "$REGISTER_ONLY" = 1 ]; then T=${S_TICKER[$i]}; else T=${P_TICKER[$i]}; fi
    venue=$(jq -r --arg t "$T" '.markets[] | select(.ticker == $t) | .v2.payoutRoute.venue // empty' "$STATE")
    if [ -z "$venue" ] || [ "$venue" = "null" ]; then
      echo "  $T payoutRoute null: registered with no route, not skipped"
    else
      jq -r --arg t "$T" '.markets[] | select(.ticker == $t) | "  \(.ticker) payoutRoute venue \(.v2.payoutRoute.venue) fee \(.v2.payoutRoute.fee) tickSpacing \(.v2.payoutRoute.tickSpacing) (CONFIG_ADMIN \($d)s setRouteV4)"' --arg d "$CONFIG_DELAY" "$STATE"
    fi
  done
fi

# ---------------------------------------------------------------- environment for forge
# The scrub of every stale V2_* export (the tunable overrides the plan printed excepted), the RESUME_PHASE capture
# (T-182 / F-DCON-06) and the shared exports are registry_env_export_shared in script/v2/lib/registry-env.sh -- the
# wrapper's own code, moved verbatim (T-OP-113) so the launch driver exports the same set from the same table.
registry_env_export_shared

# env_name, EXTERNAL_KEYS, export_contracts and export_market live in script/v2/lib/registry-env.sh (T-OP-113):
# the registry -> environment projection is ONE table with two callers, this wrapper and broadcast-v8.sh.

if [ "$DRY" = 1 ]; then
  step "dry run: commands (nothing runs)"
  cat <<EOF
# the V2_* environment above is exported by this script; keys (DEPLOYER_PK, ADMIN_PK) only ever from the environment
EOF
  [ "$DEPLOY_PHASE" = none ] || [ "$DEPLOY_PHASE" = check ] || echo "forge script script/v2/DeployV8.s.sol --rpc-url $RPC --broadcast --slow --no-storage-caching --non-interactive $VERIFY_FLAGS $SENDER_FLAGS"
  [ "$DEPLOY_PHASE" != check ] || echo "V2_WIRING_CHECK=true forge script script/v2/DeployV8.s.sol --rpc-url $RPC --no-storage-caching --non-interactive   # read-only"
  [ "$REGISTER_ONLY" = 0 ] || echo "# --register-only: ENABLED=false registerMarket (LISTING ${LISTING_DELAY}s schedule→wait→execute), then setMarketListing enabled=true, routes CONFIG_ADMIN ${CONFIG_DELAY}s from payoutRoute"
  for ((i = 0; i < N; i++)); do
    if [ "$REGISTER_ONLY" = 1 ]; then
      echo "V2_TICKERS=${P_TICKER[$i]} V2_MARKET_${P_TICKER[$i]}_ENABLED=false forge script script/v2/RegisterMarkets.s.sol --rpc-url $RPC --broadcast --slow --no-storage-caching --non-interactive $SENDER_FLAGS"
    else
      echo "V2_TICKERS=${P_TICKER[$i]} forge script script/v2/RegisterMarkets.s.sol --rpc-url $RPC --broadcast --slow --no-storage-caching --non-interactive $SENDER_FLAGS"
    fi
    echo "#   then node writes markets[${P_TICKER[$i]}].v2.{registeredAt, registerTx} into $WRITE_TARGET"
  done
  if [ "$REGISTER_ONLY" = 1 ]; then
    for ((i = 0; i < ${#S_TICKER[@]}; i++)); do
      echo "V2_TICKERS=${S_TICKER[$i]} V2_RESYNC=true V2_MARKET_${S_TICKER[$i]}_ENABLED=true forge script script/v2/RegisterMarkets.s.sol --rpc-url $RPC --broadcast --slow --no-storage-caching --non-interactive $SENDER_FLAGS  # LISTING setMarketListing"
    done
  fi
  if [ "$MODE" != verify ]; then
    for k in houseVaultFactory earnVault rewardsDistributorLender; do
      case ",$SKIP_PLAN," in *",$k,"*) echo "# externals: $k skipped (${SKIP_EXTERNAL:-owner window})"; continue ;; esac
      [ -z "$(contract_of "$k")" ] || { echo "# externals: $k already recorded, reused"; continue; }
      echo "forge script $(external_script_of "$k") --rpc-url $RPC --broadcast --slow --no-storage-caching --non-interactive ${DEPLOY_SENDER_FLAGS:-$SENDER_FLAGS}   # externals stage: $k$([ "$k" = houseVaultFactory ] && echo ' (+ houseVault; T-OP-141)' || true)"
    done
    echo "forge script $EXTERNAL_MAP_SCRIPT --rpc-url $RPC --broadcast --slow --no-storage-caching --non-interactive ${DEPLOY_SENDER_FLAGS:-$SENDER_FLAGS}   # maps the supplied externals' selectors at delay 0 (deployer still ADMIN; T-OP-153)"
    echo "forge script $EXTERNAL_HANDBACK_SCRIPT --rpc-url $RPC --broadcast --slow --no-storage-caching --non-interactive ${DEPLOY_SENDER_FLAGS:-$SENDER_FLAGS}   # the deferred DeployV8 step 9 (T-OP-153)"
    case ",$SKIP_PLAN," in *",hedger,"*) ;; *) echo "# externals: hedger has no production deploy script (docs/DEPLOY-V2.md, T-225): unsupplied, VerifyV8 FAILs on it" ;; esac
  fi
  echo "forge script script/v2/VerifyV8.s.sol:VerifyV8 --rpc-url $RPC --no-storage-caching --non-interactive   # read-only; VERIFY PASSED required"
  [ "$MODE" != broadcast ] || echo "# --broadcast first requires a passed --rehearse of this exact run (rehearsal-passed.json, 24 h)"
  exit 0
fi

# ---------------------------------------------------------------- the run's fingerprint, the rehearsal record
# A rehearsal proves one exact run: this registry file, the bytecode in out/, the pinned deployed runtimes VerifyV8
# compares the live set with, these scripts, the recon file, the tunable overrides, these markets and this deploy
# phase, sent from shared.admin. A passed rehearsal records that (rehearsal-passed.json in its log directory) and
# --broadcast refuses unless one matches from the last 24 h.
# PINNED_DIR (C3-101): the runtimes of the set live on 4663, built from the commit that deployed it and proven against
# the chain by script/v2/pin-deployed.sh; VerifyV8 compares a live address with them instead of out/ (V2DeployBase
# PINNED_MANIFEST). Every file of the directory, path and sha256, is in the fingerprint.
PINNED_DIR=script/artifacts/v2-4663
[ -f "$PINNED_DIR/manifest.json" ] || die "$PINNED_DIR/manifest.json is missing: VerifyV8 compares the live set with the pinned deployed runtimes (script/v2/pin-deployed.sh)"
ARTIFACTS="AccessManager ExpiryCalendar ChainlinkFeedSource UniV3TwapSource DataStreamsSource SettlementOracle Clearinghouse OrderBook KeeperRewards AutoRoller PayoutRouter MakerRegistry MakerVault RewardsDistributor FeeSplitter V4BuybackExecutor"
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
      cat script/v2/DeployV2Batch.sh script/v2/DeployV8.s.sol script/v2/RegisterMarkets.s.sol script/v2/VerifyV8.s.sol \
        script/v2/lib/V2DeployBase.sol script/v2/lib/PinDryRun.sol script/v2/lib/register-tx.sh script/v2/lib/registry-env.sh \
        script/v2/DeployEarnVault.s.sol script/v2/DeployLenderRewards.s.sol \
        script/v2/batch-refusals.sh script/v2/rehearse-v2.sh "$SOURCES"
      find "$PINNED_DIR" -type f | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s %s\n' "$f" "$(shasum -a 256 < "$f" | cut -d' ' -f1)"
      done
      for v in $KEEP_OVERRIDES; do echo "$v=${!v:-}"; done
      echo "ALLOW_RENT=$ALLOW_RENT"   # a rehearsal run with the flag never clears a run without it
      echo "SKIP_EXTERNAL=$SKIP_EXTERNAL"   # T-OP-116: a rehearsal that skipped an external never clears a run that deploys it
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
    if [ -n "$DEPLOYER_ADDR" ] && [ "$DEPLOYER_ADDR" != "$ADMIN_ADDR" ]; then
      cast rpc anvil_setBalance "$DEPLOYER_ADDR" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
      [ "$KEYMODE" != unlocked ] || cast rpc anvil_impersonateAccount "$DEPLOYER_ADDR" --rpc-url "$RPC" >/dev/null
    fi
    # A SAFE IS A CONTRACT, AND DeployV8 CHECKS THAT IT IS A SAFE. On chain 4663 `_principals` requires
    # both Safes to have code, because an ADMIN that is a bare key is the whole thing v8 exists to
    # remove, and `_assertAdminSafeIsARealSafe` (DeployV8.s.sol:1619-1718, T-426 F-05-01) then probes the
    # Admin Safe's singleton slot, threshold, owners, modules, guard and fallback handler before the
    # irreversible renounce. A fork of 4663 IS chain 4663, so every one of those probes is live here.
    # THIS WRAPPER USED TO PLANT `0x60008080fd` (PUSH1 0 DUP1 REVERT) AT A CODE-LESS SAFE so the address
    # would count as a contract. T-426 refuses exactly that shape ("has code but its singleton slot holds
    # 0x0…"), so the stand-in could never reach the renounce again and T-OP-081 run 2A stopped on it. It is
    # REMOVED, not flag-gated (T-OP-110): a flag whose only outcome is a guaranteed refusal ninety seconds
    # later, inside forge, is not an option but a trap; and the only stand-in that WOULD pass is one that
    # fakes the singleton slot, which is the false-green shape T-426 exists to kill. A rehearsal Safe is a
    # GENUINE Safe proxy created on the fork through the canonical SafeProxyFactory -- rehearse-v2.sh does
    # that (step 0b) and writes it into its input copy -- and a code-less one is refused here, by name,
    # before any forge step.
    for sfx in ADMIN TREASURY; do
      eval "safe=\${V2_${sfx}_SAFE:-}"
      [ -n "$safe" ] || continue
      code=$(cast code "$safe" --rpc-url "$RPC")
      if [ "$code" = 0x ] || [ -z "$code" ]; then
        die "V2_${sfx}_SAFE $safe has no code on the fork: a rehearsal needs a genuine Safe there (rehearse-v2.sh step 0b creates fork-only 2-of-3 Safes through the canonical SafeProxyFactory, T-OP-110); this wrapper no longer plants stand-in code, because DeployV8 refuses anything that is not a canonical Safe build"
      fi
      [ "$KEYMODE" != unlocked ] || cast rpc anvil_impersonateAccount "$safe" --rpc-url "$RPC" >/dev/null
    done
    # On 4663 the anvil dev accounts carry EIP-7702 delegation code (F2-04); stand-ins and a dev-key admin are made
    # plain EOAs on the fork so a later rehearsal step can send them tokens.
    # INTERFACE_VERSION 8: Admin and Treasury Safes are real contracts — fund and impersonate, never
    # code-clear. The 0xef0100 stand-in loop covers the four bot keys only.
    for a in "$CRANKER" "$PRICER" "$MM_QUOTER" "$GUARDIAN"; do
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

# ADDRESS GROUPS. DeployV8.s.sol toJson writes one address per key, except two keys whose value is an OBJECT of
# addresses: `sources` (recorded at v2.contracts.sources.*) and `flywheel` (recorded at v2.flywheel.*, where
# contract_of above, V2DeployBase.sol and the indexer read it). The mined step and the write-back walk each group
# member by member. The first version knew only `sources`: it handed the flywheel object to `cast codesize` as
# "[object Object]" and died, and past that its write-back would have filed the pair at v2.contracts.flywheel, where no
# reader looks, leaving contract_of at 14 of 16. Any OTHER object-valued key is refused by both, not guessed at.

# Record only addresses that hold code now: the JSON is written while forge simulates, before it broadcasts.
# mined_addresses <deploy-addresses.json> <rpc> -> <deploy-addresses.json>.mined.json, a dead address nulled on its own.
mined_addresses() {
  node -e '
    const fs = require("fs"); const { execFileSync } = require("child_process");
    const [file, rpc] = process.argv.slice(1);
    const j = JSON.parse(fs.readFileSync(file, "utf8"));
    const GROUPS = ["sources", "flywheel"];
    const live = (a) => a && execFileSync("cast", ["codesize", a, "--rpc-url", rpc]).toString().trim() !== "0";
    for (const k of Object.keys(j)) {
      if (GROUPS.includes(k)) {
        for (const m of Object.keys(j[k] || {})) if (!live(j[k][m])) j[k][m] = null;
      } else if (j[k] !== null && typeof j[k] !== "string") {
        throw new Error(`${k} is neither an address nor a known group (${GROUPS.join(", ")}): refusing to guess where it is recorded`);
      } else if (!live(j[k])) j[k] = null;
    }
    fs.writeFileSync(file + ".mined.json", JSON.stringify(j, null, 2) + "\n");
  ' "$1" "$2"
}

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
      const put = (obj, key, v, at) => {
        if (v === null || v === undefined) return;
        if (typeof v !== "string") throw new Error(`${at}: the run says ${JSON.stringify(v)}, which is not an address: refusing to record it`);
        if (obj[key] && obj[key].toLowerCase() !== v.toLowerCase()) throw new Error(`${at} is ${obj[key]} in the registry, the run says ${v}: refusing to overwrite`);
        obj[key] = v;
      };
      // The two ADDRESS GROUPS (see mined_addresses): sources.* nest inside v2.contracts, flywheel.* sit BESIDE it at
      // v2.flywheel. Nothing is ever written at v2.contracts.flywheel: no reader looks there.
      for (const k of Object.keys(got)) if (k !== "sources" && k !== "flywheel") put(c, k, got[k], `v2.contracts.${k}`);
      for (const k of Object.keys(got.sources || {})) put(c.sources, k, got.sources[k], `v2.contracts.sources.${k}`);
      if (got.flywheel) {
        if (!reg.v2.flywheel) throw new Error("the registry has no v2.flywheel block to record the flywheel pair in");
        for (const k of Object.keys(got.flywheel)) put(reg.v2.flywheel, k, got.flywheel[k], `v2.flywheel.${k}`);
      }
      if (block !== "" && reg.v2.deployBlock === null) reg.v2.deployBlock = Number(block);
    } else if (kind === "bots") {
      // v8 key names (V2_BOT_NAMES): the third is quoter, not the v7 name mmQuoter. Writing the v7
      // name added a key the v8 registry does not use and left quoter null in the rehearsal copy.
      // NO APOSTROPHES IN THIS BLOCK: it is inside node -e '...', a single-quoted shell string, so one
      // apostrophe ends the quote and bash then parses the JS as shell. Caught by bash -n.
      const [cranker, pricer, quoter] = a;
      for (const [k, v] of Object.entries({ cranker, pricer, quoter })) if (reg.v2.bots[k] === null) reg.v2.bots[k] = v;
    } else if (kind === "market") {
      const [t, at, tx] = a;
      const m = reg.markets.find((x) => x.ticker === t);
      if (!m) throw new Error("no registry row for " + t);
      m.v2.registeredAt = Number(at);
      m.v2.registerTx = tx;
    } else if (kind === "listed") {
      // A listing IS the market going live. Recording it keeps the registry the single source of
      // truth for "enabled": phase 3 re-derives every expectation from v2.status, so a market listed
      // on chain but still "planned" in the registry would fail VerifyV8 for being enabled.
      const [t] = a;
      const m = reg.markets.find((x) => x.ticker === t);
      if (!m) throw new Error("no registry row for " + t);
      if (m.v2.status !== "planned") throw new Error(`${t}: v2.status is "${m.v2.status}", only a planned market is listed by this pass`);
      m.v2.status = "live";
    } else throw new Error("unknown write-back " + kind);
    const tmp = file + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(reg, null, 2) + "\n");
    fs.renameSync(tmp, file);
  ' "$WRITE_TARGET" "$@" || die "write-back ($1) failed: $WRITE_TARGET"
}

# THE WRITE-BACK RECORD (T-472). T-456 split the deploy output in two. `V2_DEPLOY_OUT` carries ADDRESSES
# only -- `mined_addresses` above refuses any top-level key that is not an address or a known group -- and
# `V2_DEPLOY_RECORD_OUT` carries the four blocks that are not addresses: `deployBlock`,
# `flywheel.deployBlock`, `safes`, `wallets` and `bots`. That record is the `--deployment <file>` argument
# of callhouse `ops/markets/write-back-v8.mjs`, and nothing else in this run produces it.
#
# WHY A MISSING RECORD IS A REFUSAL AND NOT A WARNING. `write_back contracts` above records
# `v2.flywheel.feeSplitter` and `v2.flywheel.buybackExecutor`; it has no flywheel start block to record,
# because the splitter is deployed BEFORE the core and `v2.deployBlock` is a different block (inventing one
# from the other is the wrong fix this row names). `ops/markets/build-markets.mjs` then refuses the whole
# registry -- "v2.flywheel.feeSplitter is set but v2.flywheel.deployBlock is null: the indexer has no block
# to start the flywheel from". Discovering that AFTER the deploy, on launch night, is the failure. The run
# knows one phase earlier, so it says so one phase earlier.
# require_deploy_record <file> -> 0, or dies naming what is wrong with it.
require_deploy_record() { # file
  [ -f "$1" ] || die "DeployV8 wrote no write-back record at $1: v2.flywheel.deployBlock, safes, wallets and bots have no source, and ops/markets/build-markets.mjs will refuse the registry after this deploy. This script sets V2_DEPLOY_RECORD_OUT for the deploy phase; an empty value, or a path forge may not write (foundry.toml allows ./broadcast), is what turns the record off"
  jq -e 'type == "object" and has("deployBlock")' "$1" >/dev/null 2>&1 \
    || die "the write-back record $1 is not an object with a top-level deployBlock: ops/markets/write-back-v8.mjs reads record.deployBlock and refuses a record that lacks it. A block this run cannot vouch for is JSON null, which is allowed and is skipped by the write-back; a MISSING key is not"
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

# The longer of the two lanes a registration run uses; the jump below has to clear both.
MAX_LANE_DELAY=$LISTING_DELAY
[ "$CONFIG_DELAY" -le "$MAX_LANE_DELAY" ] || MAX_LANE_DELAY=$CONFIG_DELAY

# THE WAIT IS THE NODE'S, NOT THE SCRIPT'S. A forge cheatcode (vm.warp) moves the script's own EVM and
# nothing else, so under --broadcast the transactions replayed on the node afterwards still meet an
# unexpired AccessManager delay. On a rehearsal fork the wait is evm_increaseTime + evm_mine; on a real
# chain there is no jump at all and the operator comes back when readyAt has passed.
jump_node_clock() { # seconds
  cast rpc evm_increaseTime "$1" --rpc-url "$RPC" >/dev/null
  cast rpc evm_mine --rpc-url "$RPC" >/dev/null
  echo "  node clock advanced $1 s (evm_increaseTime + evm_mine)"
}

# THE DIRECT PATH (T-OP-161, amendment #4, owner decision 2026-09-22 05:50Z). While the deployer holds LISTING
# and CONFIG_ADMIN at delay 0 -- from DeployV8 step 4 until HandBack -- RegisterMarkets is sent by the DEPLOYER
# in ONE run: no schedule, no Safe, no clock jump, no rc=90. The register step's environment is set here and
# only for this process: V2_ADMIN is the deployer's address (RegisterMarkets requires admin.addr == V2_ADMIN),
# ADMIN_PK is the DEPLOYER_PK value when there is one (--broadcast; --rehearse --deployer-pk already set the
# same key), else unset and the node impersonates the deployer (--rehearse unlocked: V2_UNLOCKED_ADMIN=true is
# already exported for rehearsals and DEPLOY_SENDER_FLAGS names the deployer); V2_SCHEDULE / V2_SCHEDULE_PHASE
# removed (V2_RESYNC is the caller's, set per market above the call). The signer's preflight line is REQUIRED
# in the log, and a 'scheduled' line is a refusal: this step must never take the delayed path.
# run_forge_scheduled below is kept for POST-LAUNCH registrations and listings, after the window has closed.
# shellcheck disable=SC2086
run_forge_direct() { # log script [flags...]
  local log=$1; shift
  local rc=0
  if [ -n "${DEPLOYER_PK:-}" ]; then
    V2_ADMIN="$DEPLOYER_ADDR" ADMIN_PK="$DEPLOYER_PK" env -u V2_SCHEDULE -u V2_SCHEDULE_PHASE \
      forge script "$@" --rpc-url "$RPC" --no-storage-caching --non-interactive > "$log" 2>&1 || rc=$?
  else
    V2_ADMIN="$DEPLOYER_ADDR" env -u ADMIN_PK -u V2_SCHEDULE -u V2_SCHEDULE_PHASE \
      forge script "$@" --rpc-url "$RPC" --no-storage-caching --non-interactive > "$log" 2>&1 || rc=$?
  fi
  [ "$rc" = 0 ] || return "$rc"
  grep -q "the signer holds LISTING and CONFIG_ADMIN on the accessManager" "$log" \
    || { echo "  direct path: RegisterMarkets did not print the deployer's _signerCanList line (log: $log)"; return 1; }
  ! grep -qE "^\s+scheduled " "$log" \
    || { echo "  direct path: RegisterMarkets printed a 'scheduled' line -- it took the delayed path; the window is not open or V2_SCHEDULE leaked in (log: $log)"; return 1; }
  return 0
}

# run_forge for a script whose admin calls may sit behind a delay: schedule, wait, execute. Writes
# <logbase>-schedule.log and <logbase>-execute.log and copies the executing one to <logbase>, which is
# what every caller greps. Returns 90 when the run scheduled but cannot execute yet (real chain).
# shellcheck disable=SC2086
run_forge_scheduled() { # logbase script [flags...]
  local logbase=$1; shift
  local rc=0
  # T-182 / F-DCON-06. The resume leg. `RESUME_PHASE` is the operator's `V2_SCHEDULE_PHASE=execute`, captured
  # before the V2_* scrub. Taking it here skips the schedule leg for THIS call and executes what an earlier run
  # already scheduled -- which is exactly what the rc=90 message asks for.
  #
  # A STEP THAT WAS NEVER SCHEDULED FAILS LOUDLY HERE, and that is the intended behaviour, not a gap: the
  # execute leg finds no pending operation and the run dies naming the log. The operator re-runs without
  # V2_SCHEDULE_PHASE to schedule it. Both halves are followable; neither is silent.
  if [ "$RESUME_PHASE" = execute ]; then
    export V2_SCHEDULE_PHASE=execute
    run_forge "${logbase%.log}-execute.log" "$@" || rc=$?
    unset V2_SCHEDULE_PHASE
    cp "${logbase%.log}-execute.log" "$logbase"
    return "$rc"
  fi
  export V2_SCHEDULE_PHASE=schedule
  run_forge "${logbase%.log}-schedule.log" "$@" || rc=$?
  if [ "$rc" != 0 ]; then unset V2_SCHEDULE_PHASE; cp "${logbase%.log}-schedule.log" "$logbase"; return "$rc"; fi
  grep -E "^\s+(scheduled|opId|nonce|delayS|readyAt)" "${logbase%.log}-schedule.log" | sed 's/^/    /' || true
  if [ "$MODE" != rehearse ]; then
    unset V2_SCHEDULE_PHASE
    cp "${logbase%.log}-schedule.log" "$logbase"
    echo "  scheduled only: the operations above are not ready for ${MAX_LANE_DELAY}s. Once every readyAt"
    echo "  above has passed, re-run this exact command with V2_SCHEDULE_PHASE=execute in the environment:"
    echo "    V2_SCHEDULE_PHASE=execute $0 <the same flags>"
    echo "  That skips the schedule leg and executes what this run queued. Steps already completed are"
    echo "  skipped as usual; a step this run never scheduled fails there and is re-run without the variable."
    return 90
  fi
  jump_node_clock $((MAX_LANE_DELAY + 60))
  export V2_SCHEDULE_PHASE=execute
  run_forge "${logbase%.log}-execute.log" "$@" || rc=$?
  unset V2_SCHEDULE_PHASE
  cp "${logbase%.log}-execute.log" "$logbase"
  return "$rc"
}

# Forge's source-publication phase can fail after a fully successful broadcast. This exception is
# intentionally narrow: verification must have been requested, the log must report complete on-chain
# execution and at least one verification error (and no other Error:), and every sent transaction must
# have a successful receipt. A generic nonzero exit, missing receipt, or mixed error still fails.
# T-549, at contracts 6a57af5377326fcc91e762f444bc3f88a91ed556: THIS BRANCH HAS NOW BEEN EXECUTED.
# The C8-DEPLOYPATH ledger entry recorded the doubt in its author's own words -- "DeployV2Batch.sh was
# never run; I demonstrated the grep/set -e mechanism in isolation and reasoned the rest. If the check
# branch has another way to exit non-zero I have not found it."
#
# It was driven with the function body lifted verbatim out of this file (sed on the function, sourced
# into a harness) against constructed logs and run-latest.json files. No chain, no deploy. Seven cases:
#   canonical source-publication-only        -> ACCEPTED (0)
#   a mixed `Error:` line present            -> refused (1)
#   no ONCHAIN EXECUTION COMPLETE line       -> refused (1)
#   an INDENTED `Error:` line                -> refused (1)   <- the case the comment above guards
#   rc = 0                                   -> refused (1)
#   run-latest.json missing                  -> refused (1)
#   VERIFY_FLAGS empty (no --verify)         -> refused (1)
# Every non-canonical shape exits non-zero, which is the safe direction and matches this function's
# stated preference for a false negative over masking an unrelated forge error.
#
# NOT ESTABLISHED: this exercised the FUNCTION, not the SCRIPT. A body sourced into a harness does not
# reproduce the caller's `set -e` context, and part of the original doubt was about exactly that.
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

# T-OP-161 (f): the deployer against every principal the registry names, before step 1.
[ -z "${DEPLOYER_ADDR:-}" ] || registry_env_refuse_deployer_is_principal "$DEPLOYER_ADDR"

# ---------------------------------------------------------------- phase 1: deploy and wire
FRESH=false
# Set by the deploy phase to the write-back record DeployV8 wrote, and read by the summary. Empty in any
# phase that did not deploy (`check` sets neither artifact), so the summary prints the next step only for a
# run that produced a record.
DEPLOY_RECORD=""
case "$DEPLOY_PHASE" in
  fresh|resume)
    step "DeployV8.s.sol ($DEPLOY_PHASE)"
    export_contracts
    export V2_DEPLOY_OUT="$LOGDIR/deploy-addresses.json"
    # T-472. The SECOND artifact, beside the address file and never inside it: DeployV8.s.sol writes it only
    # when this names a path, and before this line no run of this script ever set it.
    export V2_DEPLOY_RECORD_OUT="$LOGDIR/deploy-record.json"
    rm -f "$V2_DEPLOY_OUT" "$V2_DEPLOY_RECORD_OUT" "$BROADCAST_DIR/DeployV8.s.sol/$CHAIN_EXPECT/run-latest.json"
    rc=0
    # T-OP-116 / T-OP-153 (owner decision 2026-09-22 05:35Z): the hand-back (step 9) is DEFERRED so the
    # deployer still holds ADMIN when the externals stage below maps the externals' selectors; HandBack.s.sol
    # renounces at the end of that stage, in this same run. The accepted hot-key window is DeployV8 -> HandBack.
    # shellcheck disable=SC2086
    V2_DEFER_HANDBACK=true run_forge "$LOGDIR/deploy.log" script/v2/DeployV8.s.sol --broadcast --slow $VERIFY_FLAGS ${DEPLOY_SENDER_FLAGS:-$SENDER_FLAGS} || rc=$?
    unset V2_DEPLOY_OUT V2_DEPLOY_RECORD_OUT
    grep -E "^\s+(ok|WARN|skip|call) |preflight|DEPLOY DONE|V2_ADDRESS|WARNING|post-check" "$LOGDIR/deploy.log" | sed 's/^/    /' || true
    run="$BROADCAST_DIR/DeployV8.s.sol/$CHAIN_EXPECT/run-latest.json"
    [ ! -f "$run" ] || cp "$run" "$LOGDIR/deploy-run-latest.json"
    if [ -f "$LOGDIR/deploy-addresses.json" ]; then
      mined_addresses "$LOGDIR/deploy-addresses.json" "$RPC" || die "could not check the deployed addresses (log: $LOGDIR/deploy.log)"
      block=""
      if [ -f "$LOGDIR/deploy-run-latest.json" ]; then
        block=$(jq -r '[.receipts[] | select(.contractAddress != null and .status == "0x1") | .blockNumber] | map(tonumber? // (ltrimstr("0x") | explode | reduce .[] as $c (0; . * 16 + (if $c >= 97 then $c - 87 elif $c >= 65 then $c - 55 else $c - 48 end)))) | min // empty' "$LOGDIR/deploy-run-latest.json")
      fi
      [ -n "$block" ] || block=$DEPLOY_BLOCK_ARG
      write_back contracts "$LOGDIR/deploy-addresses.json.mined.json" "$block"
      echo "  recorded in $WRITE_TARGET: $(jq -c '.v2.contracts' "$WRITE_TARGET")  flywheel $(jq -c '.v2.flywheel' "$WRITE_TARGET")  deployBlock $(jq -r '.v2.deployBlock' "$WRITE_TARGET")"
    fi
    if source_publication_only_failure "$rc" "$LOGDIR/deploy.log" "$LOGDIR/deploy-run-latest.json"; then
      echo "  WARNING: on-chain deploy completed with successful receipts, but source publication failed."
      echo "           VerifyV8 still runs below; publish source separately and confirm it on the explorer."
      SOURCE_VERIFY_STATUS="failed (on-chain receipts succeeded; publication still required)"
      rc=0
    fi
    if [ "$rc" != 0 ]; then
      tail -40 "$LOGDIR/deploy.log"
      die "DeployV2 failed (exit $rc); mined addresses were recorded in $WRITE_TARGET. Diagnose the log and current registry before re-running: use --resume only for missing contracts or wiring, otherwise use a plain re-run (log: $LOGDIR/deploy.log)"
    fi
    [ -f "$LOGDIR/deploy-addresses.json" ] || die "DeployV2 wrote no address JSON (log: $LOGDIR/deploy.log)"
    # After the deploy error paths above, so a failed run reports its own failure first and this never masks it.
    require_deploy_record "$LOGDIR/deploy-record.json"
    DEPLOY_RECORD=$LOGDIR/deploy-record.json
    STATE=$WRITE_TARGET
    got=0; for k in $CONTRACT_KEYS; do [ -z "$(contract_of "$k")" ] || got=$((got + 1)); done
    [ "$got" = "$NKEYS" ] || die "only $got of $NKEYS contracts recorded after a successful DeployV8 (log: $LOGDIR/deploy.log)"
    [ -n "$(jqr '.v2.deployBlock // empty')" ] || die "v2.deployBlock unknown: no CREATE receipt in this run; re-run with --resume --deploy-block <block of the first contract>"
    [ "$DEPLOY_PHASE" != fresh ] || FRESH=true
    ;;
  check)
    step "DeployV8.s.sol wiring check (read-only: the set is recorded; --resume sends missing wiring)"
    export_contracts
    V2_WIRING_CHECK=true run_forge "$LOGDIR/wiring-check.log" script/v2/DeployV8.s.sol \
      || { grep -E "^\s+PENDING|^Error: script failed|has no code|is not" "$LOGDIR/wiring-check.log" | sed 's/^/    /'; die "the recorded set's wiring is incomplete or unreadable: re-run with --resume (log: $LOGDIR/wiring-check.log)"; }
    # THE BANNER IS "HAND-OVER COMPLETE", NOT "WIRING COMPLETE", and `|| true` is not optional here.
    # This grep looked for a string NOTHING IN THE TREE EMITS (DeployV8.s.sol:143 prints "HAND-OVER COMPLETE:
    # nothing to send"), so it matched nothing, exited 1, and under `set -euo pipefail` killed the batch with no
    # message -- immediately after the wiring check above had PASSED. O8-10 made this branch the routine path for
    # every --register-only and every resumed run, so the green path died and the failure looked like the deploy.
    # Its two sibling display greps (:878, :932, :998) all carry `|| true`; this one was the odd man out.
    grep -E "HAND-OVER COMPLETE|^\s+PENDING" "$LOGDIR/wiring-check.log" | sed 's/^/    /' || true
    ;;
esac
STATE=$WRITE_TARGET
export_contracts
DEPLOY_BLOCK=$(jqr '.v2.deployBlock // empty')

# ---------------------------------------------------------------- phase 1b: the externals (T-OP-116)
# RIGHT AFTER DeployV8 and BEFORE the markets, because DeployV8 ran with V2_DEFER_HANDBACK=true (owner decision
# 2026-09-22 05:35Z, M-0446996d3fc44c3a; T-OP-153): the deployer holds ADMIN from that step until HandBack.s.sol
# at the end of this stage, and nothing else belongs inside that window. Every fact the stage reads is set
# here from this wrapper's own variables (script/v2/lib/registry-env.sh lists them at the function). In
# --verify mode nothing runs; the skip list is still parsed so VerifyV8 is told what the operator declared skipped.
if [ "$MODE" != verify ]; then
  step "externals: deploy what has a script, record at v2.contracts.<key>, MapExternals (deployer still ADMIN; hand-back after the markets)"
  EXECUTE=1; EXT_DEPLOY_FLAGS=${DEPLOY_SENDER_FLAGS:-$SENDER_FLAGS}
  # T-OP-210: this stage now runs after HandBack too (every post-launch --register-only / --resync / recovery run
  # enters it), so the old "STILL HOLDS ADMIN" assertion here was false half the time. The stage's own last lines say
  # which state it stopped in.
  registry_env_externals || die "externals stage failed (exit $?); see the lines above and $LOGDIR/externals-*.log. If the stage's lines say the window is OPEN the deployer STILL HOLDS ADMIN -- re-run this command; if they say CLOSED, follow the Safe path they name"
  # The registry now carries the externals this run deployed: re-project so RegisterMarkets and VerifyV8 read
  # them from the same table everything else comes from (the stage exported them too; this is the one source).
  export_contracts
else
  externals_parse_skip
fi

# ---------------------------------------------------------------- phase 2: markets, one at a time
# WHICH PATH, decided once by reading the manager (T-OP-161): the deployer's window open = every market in this
# run is registered by the deployer directly; closed (a post-launch wave, --resync after launch, --register-only
# after the hand-back) = the Admin Safe's lanes through run_forge_scheduled, rc=90 and the fork's clock jump.
DIRECT_REGISTER=0; DIRECT_REGISTER_WHY="no markets to register"
if [ "$N" -gt 0 ] || [ "${#S_TICKER[@]}" -gt 0 ]; then
  registry_env_direct_register_ok "${DEPLOYER_ADDR:-}"
  echo "  register path: $DIRECT_REGISTER_WHY"
fi
R_TX=(); R_AT=()
for ((i = 0; i < N; i++)); do
  T=${P_TICKER[$i]}
  step "$T: RegisterMarkets.s.sol ($([ "$DIRECT_REGISTER" = 1 ] && echo 'DIRECT, sent by the deployer' || echo 'scheduled: Safe lanes, post-launch'))"
  export V2_TICKERS=$T
  export_market "$T" "${P_ROW[$i]}"
  if [ "${P_REG[$i]}" != "-" ]; then export V2_RESYNC=true; else unset V2_RESYNC; fi
  asset_var="V2_MARKET_${T}_ASSET"; asset=${!asset_var}
  run="$BROADCAST_DIR/RegisterMarkets.s.sol/$CHAIN_EXPECT/run-latest.json"
  rm -f "$run"   # a previous ticker's record must never be read as this one's
  rc=0
  if [ "$DIRECT_REGISTER" = 1 ] && [ "${P_REG[$i]}" = "-" ]; then
    # shellcheck disable=SC2086
    run_forge_direct "$LOGDIR/$T-register.log" script/v2/RegisterMarkets.s.sol --broadcast --slow ${DEPLOY_SENDER_FLAGS:-$SENDER_FLAGS} || rc=$?
  else
    # A --resync of an already registered market, or any registration after the hand-back: the Safe's lanes.
    # shellcheck disable=SC2086
    run_forge_scheduled "$LOGDIR/$T-register.log" script/v2/RegisterMarkets.s.sol --broadcast --slow $SENDER_FLAGS || rc=$?
    [ "$rc" != 90 ] || die "$T: registration scheduled but not executed; see the readyAt values above (log: $LOGDIR/$T-register-schedule.log)"
  fi
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

SN=${#S_TICKER[@]}
if [ "$REGISTER_ONLY" = 1 ] && [ "${SN:-0}" -gt 0 ]; then
  step "LISTING: setMarketListing(enabled=true) as LISTING ${LISTING_DELAY}s schedule → wait → execute (Safe impersonated)"
  LIST_PASS=1
  for ((i = 0; i < SN; i++)); do
    T=${S_TICKER[$i]}
    st=$(jq -r --arg t "$T" '.markets[] | select(.ticker == $t) | .v2.status' "$STATE")
    if [ "$st" != planned ]; then
      # "paused" is a deliberate not-listed state and "live" is already listed: neither is this
      # pass's business, and forcing either to enabled=true is how the staged-listing invariant dies.
      echo "  skip $T: v2.status is '$st', not 'planned' (this pass lists planned markets only)"
      continue
    fi
    row=$(market_row "$T")
    step "$T: setMarketListing enabled=true ($([ "$DIRECT_REGISTER" = 1 ] && echo 'DIRECT, sent by the deployer' || echo 'LISTING lane, scheduled'))"
    export V2_TICKERS=$T
    export_market "$T" "$row"
    export V2_RESYNC=true
    rc=0
    if [ "$DIRECT_REGISTER" = 1 ]; then
      # The listing is a LISTING-lane call the deployer holds at delay 0 inside its window: direct. V2_RESYNC=true
      # (exported above) rides through run_forge_direct untouched.
      # shellcheck disable=SC2086
      run_forge_direct "$LOGDIR/$T-list.log" script/v2/RegisterMarkets.s.sol --broadcast --slow ${DEPLOY_SENDER_FLAGS:-$SENDER_FLAGS} || rc=$?
    else
      # shellcheck disable=SC2086
      run_forge_scheduled "$LOGDIR/$T-list.log" script/v2/RegisterMarkets.s.sol --broadcast --slow $SENDER_FLAGS || rc=$?
      [ "$rc" != 90 ] || die "$T: listing scheduled but not executed; see the readyAt values above (log: $LOGDIR/$T-list-schedule.log)"
    fi
    grep -E "^\s+(ok|WARN|info|call|scheduled|executed) |preflight|REGISTER DONE|post-check" "$LOGDIR/$T-list.log" | sed 's/^/    /' || true
    [ "$rc" = 0 ] || { tail -40 "$LOGDIR/$T-list.log"; die "$T: setMarketListing failed (exit $rc) (log: $LOGDIR/$T-list.log)"; }
    # T-182 / F-DCON-05. THE WRITE-BACK IS HERE, AFTER BOTH rc CHECKS, and that position is the whole fix.
    # It used to run BEFORE `run_forge_scheduled`, so v2.status became "live" in the REAL registry and only then
    # did the run try to list the market. rc=90 -- "scheduled, not yet executable" -- is the NORMAL outcome of a
    # LISTING-lane call, not the unlikely one, so the usual path recorded a market as live that was not, and the
    # re-run that would have finished it printed "skip: v2.status is 'live'" and walked past it for ever.
    # Recoverable only by hand surgery on the production registry.
    #
    # LATE IS THE SAFE SIDE, and it is the side the registration step above already takes. Dying between the
    # executed call and this line leaves the chain listed and the registry "planned", which the next run simply
    # lists again -- `RegisterMarkets` is re-entrant here and V2_RESYNC is exported for exactly that. The
    # opposite order has no re-run that fixes it, because the `st != planned` guard skips the row permanently.
    #
    # NOT "the same write with extra steps": every path that reaches this line has already proved the listing
    # transaction executed. `run_forge_scheduled` returns 90 when it could only schedule, and any non-zero rc is
    # fatal above.
    write_back listed "$T"
    echo "  listed: $T enabled=true (LISTING lane, ${LISTING_DELAY}s)"
  done
  unset V2_RESYNC
  LIST_PASS=0
fi

# ---------------------------------------------------------------- phase 2c: hand-back (T-OP-161)
# The deferred DeployV8 step 9, AFTER the launch set is registered and listed by the deployer. Idempotent, so a
# re-run after a completed hand-back sends nothing; skipped only in --verify, which owns no window. Runs whether
# or not this run registered anything: a --deploy-only run, or a resumed run with every market already
# recorded, still has to close the window it (or its earlier half) opened.
if [ "$MODE" != verify ]; then
  step "hand-back: HandBack.s.sol (the deployer renounces), read back hasRole(ADMIN, deployer) == false"
  EXECUTE=1
  registry_env_handback
fi

# ---------------------------------------------------------------- phase 3: verify
step "VerifyV8.s.sol (read-only against $RPC)"
# T-OP-081 finding #3a / T-OP-113 criterion 3. `shared.feeRecipient` is null in a registry that describes a set
# not yet deployed -- it IS the FeeSplitter this run creates -- so V2_FEE_RECIPIENT was correctly left UNSET for
# DeployV8 above. VerifyV8 reads the same variable (VerifyV8.s.sol:525,554) and compared the live splitter with
# address(0), so a CORRECT deploy failed its own gate. The splitter is recorded by `write_back contracts` before
# this line, so it is projected from there now; a non-null shared.feeRecipient still wins. The registry field
# itself is NOT written: null there means "the splitter" by definition (owner ruling via the coordinator,
# 2026-09-22), and the address the projection needs is already recorded at v2.flywheel.feeSplitter.
registry_env_fee_recipient_from_splitter
REG_T=$(jq -r '[.markets[] | select(.v2.registeredAt != null) | .ticker] | join(",")' "$STATE")
UNREG=$(jq -r '[.markets[] | select(.v2.registeredAt == null) | .asset] | join(",")' "$STATE")
for T in $(echo "$REG_T" | tr ',' ' '); do row=$(market_row "$T"); export_market "$T" "$row"; done
if [ -n "$REG_T" ]; then export V2_TICKERS=$REG_T; else unset V2_TICKERS; fi
if [ -n "$UNREG" ]; then export V2_UNREGISTERED_ASSETS=$UNREG; fi
if [ "$MODE" = verify ]; then export V2_EXPECT_FRESH=${EXPECT_FRESH_ARG:-false}; else export V2_EXPECT_FRESH=$FRESH; fi
vrc=0
(unset DEPLOYER_PK ADMIN_PK; run_forge "$LOGDIR/verify.log" script/v2/VerifyV8.s.sol:VerifyV8) || vrc=$?
# T-OP-161 (e) / T-OP-152. A VerifyV8 that never reached its summary is FAILED-INCOMPLETE, by name: it did not
# fail N checks, it stopped (an abort inside a group, a compile error, a dead RPC). Counting its FAIL lines and
# calling the result "VerifyV8 failed" made an aborted run read as "2 FAIL" (M-bf78ceccbc5549d3). Both summary
# shapes are VerifyV8.s.sol run()'s own text; anything else is incomplete.
if ! grep -qE "VERIFY (PASSED|FAILED):" "$LOGDIR/verify.log"; then
  grep -E "^\s+(FAIL|info)|Error|revert|panic" "$LOGDIR/verify.log" | tail -12 | sed 's/^/    /' || true
  die "VerifyV8 FAILED-INCOMPLETE: exit $vrc and NO 'VERIFY PASSED:' / 'VERIFY FAILED:' summary line in $LOGDIR/verify.log. The run stopped before its last group; the FAIL lines above (if any) are the checks it reached, not its verdict. This is not a pass and it is not 'N checks failed'"
fi
if [ "$vrc" != 0 ] || grep -qE "^\s+FAIL" "$LOGDIR/verify.log"; then
  # `|| true` matters MORE on the failure path than on a display grep. Under `set -e` a grep that matches
  # nothing exits 1 and kills the script HERE, before `die` below ever runs -- so the operator gets a silent
  # non-zero exit instead of "VerifyV8 failed (log: ...)". That is reachable exactly when it hurts most: a
  # verify that died early enough to write no FAIL, info, VERIFY or Error line at all. Found while auditing
  # the sibling greps for F-SCRIPTS-04; same defect, error path instead of the green path.
  grep -E "^\s+(FAIL|info)|VERIFY|Error" "$LOGDIR/verify.log" | sed 's/^/    /' || true
  die "VerifyV8 failed (log: $LOGDIR/verify.log)"
fi
CHECKS=$(grep -E "VERIFY PASSED" "$LOGDIR/verify.log" | sed -E 's/.*VERIFY PASSED: ([0-9]+) checks.*/\1/')
[ -n "$CHECKS" ] || die "no VERIFY PASSED line (log: $LOGDIR/verify.log)"
grep -E "^\s+info" "$LOGDIR/verify.log" | sed 's/^/    /' || true
echo "  VERIFY PASSED: $CHECKS checks (expect fresh: $V2_EXPECT_FRESH; markets: ${REG_T:-none})"

# ---------------------------------------------------------------- summary
step "BATCH PASSED ($MODE): deploy phase '$DEPLOY_PHASE', $N market(s) registered, chain $CHAIN_EXPECT"
jq -r '.v2.contracts | to_entries[] | if .key == "sources" then (.value | to_entries[] | "  sources.\(.key) \(.value)") else "  \(.key) \(.value)" end' "$STATE"
echo "  deployBlock   $(jq -r '.v2.deployBlock' "$STATE")"
for k in $EXTERNAL_DEPLOY_ORDER; do
  a=$(contract_of "$k")
  case " ${EXT_SKIP:-} " in *" $k "*) echo "  external      $k SKIPPED (${EXT_SKIP_SRC:-})" ;; *) echo "  external      $k ${a:-<unsupplied>}" ;; esac
done
printf '  %-6s %-12s %s\n' TICKER REGISTERED_AT REGISTER_TX
for ((i = 0; i < N; i++)); do printf '  %-6s %-12s %s\n' "${P_TICKER[$i]}" "${R_AT[$i]}" "${R_TX[$i]}"; done
echo "  verify        $CHECKS checks passed"
[ "$MODE" != broadcast ] || echo "  source verify  $SOURCE_VERIFY_STATUS"
echo "  logs          $ROOT/$LOGDIR"
echo "  registry      $WRITE_TARGET"
if [ -n "$DEPLOY_RECORD" ]; then
  # PRINTED, NOT RUN, and that is a decision rather than an omission (T-472). Three reasons:
  #   1. `write-back-v8.mjs` lives in ANOTHER repository (callhouse) at a checkout this run does not pin.
  #      `--registry` may point anywhere, so this script cannot know a write-back script sits beside the
  #      registry it was handed, nor that its version matches the record shape DeployV8 just wrote.
  #   2. It would be a SECOND writer into $WRITE_TARGET during the same run, beside `write_back` above,
  #      with different rules: `write_back` refuses to overwrite a differing non-null slot, the mjs tool
  #      refuses conflicts unless `--force` and validates completeness. Running it here would decide the
  #      operator's `--check`/`--force` answer for them, inside a script that has just spent real money.
  #   3. On `--rehearse`, $WRITE_TARGET is a temp copy of the registry, so an automatic write-back would
  #      teach a rehearsal to exercise a path the real run does not take.
  # The refusal that protects the registry stays exactly where it was (build-markets.mjs, loud). What this
  # row fixes is that the record now EXISTS and the command that consumes it is printed with real paths.
  echo "  write-back record $ROOT/$DEPLOY_RECORD"
  echo "  NEXT STEP, MANDATORY, NOT RUN BY THIS SCRIPT: record deployBlock, flywheel.deployBlock, safes,"
  echo "  wallets and bots, or ops/markets/build-markets.mjs refuses this registry:"
  echo "    node $(dirname "$REGISTRY")/write-back-v8.mjs --deployment $ROOT/$DEPLOY_RECORD --registry $WRITE_TARGET"
  echo "    (add --check first to see the diff and write nothing)"
fi
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
