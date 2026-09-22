#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# post-launch-check.sh — T-OP-176. The READ-ONLY page the owner runs right after the v8 broadcast and
# again the next morning. It answers, from the written-back registry and an RPC, and nothing else:
#
#   1. CODE + IDENTITY   every recorded v2.contracts / v2.flywheel / sources address, every recorded
#                        external and every markets[].v2.houseVault has code AND answers the getters its
#                        manifest name implies (the same probe pairs VerifyV8._externalIdentities uses for
#                        the six externals, one distinguishing getter for each core target), and every
#                        Managed target's authority() IS the recorded AccessManager.
#   2. ROLES             AccessManager.hasRole(id, who) for EVERY known principal (adminSafe, treasurySafe,
#                        the four bot keys, the deployer) over EVERY manifest role id: membership equals
#                        what roles.v8.json .holders gives that principal, and each held role carries the
#                        manifest delay (delaysS). The deployer must hold NOTHING in 0..10. The same wide
#                        sweep VerifyV8 makes (T-436), read with cast instead of forge.
#   3. RECEIPT           --run-dir/verify-passed.json exists, names this chain, and its fingerprint equals
#                        what BroadcastV8.assertFingerprint() derives from the registry NOW -- the driver's
#                        own function, executed, never re-implemented here.
#   4. MARKETS           every launchSet.markets ticker is registered on the Clearinghouse (strikeTick != 0),
#                        enabled, not mint-paused, its oracle is the recorded SettlementOracle, and the
#                        registry row says registeredAt/registerTx set and v2.status == live.
#
#   script/v2/post-launch-check.sh --registry <written-back tier1.json> --rpc <url> \
#       --run-dir <broadcast/v8-launch/<stamp>> --deployer <address> [--out <file>] \
#       [--roles script/v2/roles.v8.json] [--skip-external a,b | none] [--no-checksum]
#
# WHAT NOT CHECKED MEANS HERE, AND WHAT IT NEVER MEANS. An external in the skip list (default: the owner's
# window -- hedger, rewardsDistributorLender, stockVenueAdapter -- exactly registry-env.sh's
# EXTERNAL_SKIP_DEFAULT) with NO recorded address is reported NOT CHECKED, by name, and counted on the last
# line. Everything else that cannot be read is a FAIL: an address with no code is a FAIL, a recorded
# external in the skip list is a FAIL (a skip is for a contract that is not there), a missing receipt is a
# FAIL, an unknown deployer is a FAIL. "Could not check" is never "passed".
#
# READ-ONLY, BY CONSTRUCTION. Every chain read is `cast call` / `cast code` / `cast chain-id`; the one forge
# process is `forge script BroadcastV8.s.sol --sig assertFingerprint()` with no --broadcast (the driver's
# guard `refuse_if_can_broadcast` is applied to it first, as broadcast-v8.sh does). No key is read, no
# transaction is built, the registry is never written. The report goes to stdout and, with --out, to a file.
#
# REUSED, NOT COPIED: CONTRACT_KEYS / EXTERNAL_KEYS / contract_of / external_target_of / env_name /
# EXTERNAL_SKIP_DEFAULT come from script/v2/lib/registry-env.sh (sourced), the fingerprint from
# script/v2/BroadcastV8.s.sol (executed), the role ids / delays / holders from script/v2/roles.v8.json.
#
# Exit status: 0 only when no check FAILED. 1 on any FAIL, with every failure named on its own line.
# -------------------------------------------------------------------------------------------------
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

die() { printf '\n!! %s\n' "$*" >&2; exit 2; }

REGISTRY=""; RPC=""; RUN_DIR=""; DEPLOYER=${V2_DEPLOYER:-}; OUT=""; ROLES_JSON="$HERE/roles.v8.json"
SKIP_EXTERNAL=""; NO_CHECKSUM=0
while [ $# -gt 0 ]; do
  case "$1" in
    --registry) REGISTRY=${2:?--registry needs a path}; shift 2 ;;
    --rpc) RPC=${2:?--rpc needs a url}; shift 2 ;;
    --run-dir) RUN_DIR=${2:?--run-dir needs a path}; shift 2 ;;
    --deployer) DEPLOYER=${2:?--deployer needs an address}; shift 2 ;;
    --out) OUT=${2:?--out needs a path}; shift 2 ;;
    --roles) ROLES_JSON=${2:?--roles needs a path}; shift 2 ;;
    --skip-external) SKIP_EXTERNAL=${2:?--skip-external needs a,b or none}; shift 2 ;;
    --no-checksum) NO_CHECKSUM=1; shift ;;
    -h|--help) sed -n '2,42p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$REGISTRY" ] || die "--registry is required (the written-back tier1.json)"
[ -f "$REGISTRY" ] || die "registry not found: $REGISTRY"
[ -n "$RPC" ] || die "--rpc is required"
[ -f "$ROLES_JSON" ] || die "roles manifest not found: $ROLES_JSON"
for tool in cast jq forge; do command -v "$tool" >/dev/null || die "$tool not on PATH"; done

# The lib's lists and resolvers. It reads the registry through STATE and refuses through the caller's die.
STATE=$REGISTRY
MODE=verify
# shellcheck source=lib/registry-env.sh
. "$HERE/lib/registry-env.sh"

# ---------------------------------------------------------------- report plumbing
PASSES=0; FAILS=0; NOTCHECKED=0; FAILED_LINES=""
if [ -n "$OUT" ]; then mkdir -p "$(dirname "$OUT")"; : > "$OUT"; fi
emit() { if [ -n "$OUT" ]; then printf '%s\n' "$*" | tee -a "$OUT"; else printf '%s\n' "$*"; fi; }
group() { emit ""; emit "== $*"; }
ok() { PASSES=$((PASSES + 1)); emit "  ok    $*"; }
fail() { FAILS=$((FAILS + 1)); FAILED_LINES="${FAILED_LINES}  FAIL  $*
"; emit "  FAIL  $*"; }
notchecked() { NOTCHECKED=$((NOTCHECKED + 1)); emit "  NOT CHECKED  $*"; }
check() { if [ "$1" = 0 ]; then ok "$2"; else fail "$2${3:+ -- $3}"; fi; }
info() { emit "        $*"; }

# A staticcall that must ANSWER (non-empty return, no revert): the identity probe VerifyV8._identity makes.
answers() { # addr sig
  local r
  r=$(cast call "$1" "$2" --rpc-url "$RPC" 2>/dev/null) || return 1
  [ -n "$r" ] && [ "$r" != "0x" ]
}
call_addr() { cast call "$1" "$2" --rpc-url "$RPC" 2>/dev/null | head -1; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
same_addr() { [ "$(lower "$1")" = "$(lower "$2")" ]; }
has_code() { local c; c=$(cast code "$1" --rpc-url "$RPC" 2>/dev/null) || return 1; [ -n "$c" ] && [ "$c" != "0x" ]; }
checksum_ok() { [ "$NO_CHECKSUM" = 1 ] || [ "$(cast to-check-sum-address "$1" 2>/dev/null)" = "$1" ]; }

# ---------------------------------------------------------------- 0. inputs
CHAIN=$(cast chain-id --rpc-url "$RPC" 2>/dev/null) || die "no RPC at $RPC (cast chain-id failed)"
REG_SHA=$(shasum -a 256 "$REGISTRY" | cut -d' ' -f1)
emit "post-launch-check  registry $REGISTRY (sha256 $REG_SHA)"
emit "                   rpc chain $CHAIN   roles $ROLES_JSON   run-dir ${RUN_DIR:-<none>}   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
MGR=$(contract_of accessManager)
ADMIN_SAFE=$(jqr '.shared.safes.admin // .shared.admin // empty')
TREASURY_SAFE=$(jqr '.shared.safes.treasury // empty')
GUARDIAN=$(jqr '.v2.bots.guardian // empty'); PRICER=$(jqr '.v2.bots.pricer // empty')
QUOTER=$(jqr '.v2.bots.quoter // empty'); CRANKER=$(jqr '.v2.bots.cranker // empty')
[ -n "$MGR" ] || die "registry v2.contracts.accessManager is null: nothing below can be read without the manager"

# ---------------------------------------------------------------- 1. code + identity
# registry key -> manifest target name (the roles.v8.json spelling) for the recorded set; the six externals
# come from the lib's external_target_of. AccessManager is not a manifest target; it is probed by its own ABI.
core_target_of() {
  case "$1" in
    accessManager) echo AccessManager ;; flywheel.feeSplitter) echo FeeSplitter ;;
    flywheel.buybackExecutor) echo V4BuybackExecutor ;; expiryCalendar) echo ExpiryCalendar ;;
    sources.chainlink) echo ChainlinkFeedSource ;; sources.univ3) echo UniV3TwapSource ;;
    sources.dataStreams) echo DataStreamsSource ;; settlementOracle) echo SettlementOracle ;;
    keeperRewards) echo KeeperRewards ;; clearinghouse) echo Clearinghouse ;; orderBook) echo OrderBook ;;
    autoRoller) echo AutoRoller ;; payoutAdapter) echo PayoutRouter ;; makerRegistry) echo MakerRegistry ;;
    makerVault) echo MakerVault ;; rewardsDistributor) echo RewardsDistributor ;;
    *) external_target_of "$1" ;;
  esac
}
# manifest target -> the zero-argument getters that contract, and only a contract of that kind, answers. The
# six externals are the exact pairs VerifyV8._externalIdentities / DeployV8._assertSuppliedTargetsAreWhat-
# TheirNameClaims probe; the core targets get one or two getters read off their ABIs (out/<Name>.sol).
# MakerRegistry has no zero-argument getter beyond authority(); it is identified by authority() alone and
# said so.
identity_sigs() {
  case "$1" in
    AccessManager) echo "ADMIN_ROLE() minSetback()" ;;
    FeeSplitter) echo "burnBps() executor()" ;;
    V4BuybackExecutor) echo "splitter() poolId()" ;;
    ExpiryCalendar) echo "NEXT_EXPIRY_SEARCH()" ;;
    ChainlinkFeedSource) echo "DEFAULT_MAX_ROUND_JUMP_BPS() MAX_ROUND_READS()" ;;
    UniV3TwapSource) echo "DEFAULT_WINDOW() usdg()" ;;
    DataStreamsSource) echo "RING_SIZE() REPORT_BODY_LENGTH()" ;;
    SettlementOracle) echo "SETTLEMENT_WINDOW() clearinghouse()" ;;
    KeeperRewards) echo "dailyCap() treasury()" ;;
    Clearinghouse) echo "calendar() payoutAdapter()" ;;
    OrderBook) echo "clearinghouse() makerRegistry()" ;;
    AutoRoller) echo "ROLL_OPEN_GRACE() clearinghouse()" ;;
    PayoutRouter) echo "poolManager() v3Router()" ;;
    MakerRegistry) echo "" ;;
    MakerVault) echo "OUTFLOW_WINDOW() orderBook()" ;;
    RewardsDistributor) echo "treasury() usdg()" ;;
    HouseVault) echo "underlying() clearinghouse()" ;;
    HouseVaultFactory) echo "vaults()" ;;
    Hedger) echo "notional() loan()" ;;
    EarnVault) echo "queue() adapter()" ;;
    StockVenueAdapter) echo "venue() enabled()" ;;
    RewardsDistributorLender) echo "usdg()" ;;
  esac
}
# Managed targets answer authority(); AccessManager and V4BuybackExecutor (not Managed: the manifest's
# target entry for it is empty, the splitter calls it) do not.
managed() { case "$1" in AccessManager|V4BuybackExecutor) return 1 ;; *) return 0 ;; esac; }

probe_target() { # key addr target-name
  local key=$1 a=$2 name=$3 sig auth
  if ! is_addr "$a"; then fail "$name ($key) $a is not a 20-byte address"; return; fi
  if ! checksum_ok "$a"; then fail "$name ($key) $a is not EIP-55 checksummed in the registry"; fi
  if ! has_code "$a"; then fail "$name ($key) $a has NO CODE on chain $CHAIN"; return; fi
  ok "$name ($key) $a has code"
  for sig in $(identity_sigs "$name"); do
    if answers "$a" "$sig"; then ok "$name answers $sig: it is the contract its name claims"
    else fail "$name ($key) $a does not answer $sig: NOT the contract its name claims"; fi
  done
  [ -n "$(identity_sigs "$name")" ] || info "$name has no distinguishing zero-argument getter; identified by authority() only"
  if managed "$name"; then
    auth=$(call_addr "$a" "authority()(address)")
    if [ -n "$auth" ] && same_addr "$auth" "$MGR"; then ok "$name authority() == accessManager"
    else fail "$name ($key) authority() is '${auth:-<no answer>}', not the recorded AccessManager $MGR"; fi
  fi
}

group "1. code + identity: the recorded set ($(printf '%s\n' $CONTRACT_KEYS | wc -l | tr -d ' ') keys in deploy order)"
MISSING_CORE=""
for k in $CONTRACT_KEYS; do
  a=$(contract_of "$k")
  if [ -z "$a" ]; then fail "$(core_target_of "$k") ($k) is NOT RECORDED in the registry (null): the write-back did not happen"; MISSING_CORE="${MISSING_CORE:+$MISSING_CORE }$k"; continue; fi
  probe_target "$k" "$a" "$(core_target_of "$k")"
done

group "1b. code + identity: the six externals (skip list: ${SKIP_EXTERNAL:-owner window = $EXTERNAL_SKIP_DEFAULT})"
case "${SKIP_EXTERNAL:-}" in
  "") SKIP_LIST=$EXTERNAL_SKIP_DEFAULT ;; none) SKIP_LIST="" ;; *) SKIP_LIST=$(echo "$SKIP_EXTERNAL" | tr ',' ' ') ;;
esac
for k in $SKIP_LIST; do case " $EXTERNAL_KEYS " in *" $k "*) ;; *) die "--skip-external $k: not one of the six externals ($EXTERNAL_KEYS)" ;; esac; done
NOT_CHECKED_TARGETS=""
for k in $EXTERNAL_KEYS; do
  a=$(contract_of "$k"); name=$(external_target_of "$k")
  skipped=0; case " $SKIP_LIST " in *" $k "*) skipped=1 ;; esac
  if [ -n "$a" ]; then
    if [ "$skipped" = 1 ]; then fail "$name ($k) is in the skip list AND recorded at v2.contracts.$k ($a): a skip is for a contract that is not there"; fi
    probe_target "$k" "$a" "$name"
    b=$(jqr ".v2.externalDeployBlocks.$k // empty")
    if [ "$k" = houseVault ]; then
      # T-OP-211 (live step 21, the sixth false FAIL). Since T-OP-141/196 the vaults are factory-born and recorded
      # per ticker (markets[].v2.houseVault); v2.contracts.houseVault is the FIRST launch ticker's, and the indexer
      # discovers every vault from the factory's VaultCreated log, starting at v2.externalDeployBlocks.houseVaultFactory
      # (indexer/ponder.config.ts:347). So a null v2.externalDeployBlocks.houseVault is BY DESIGN; the block that must
      # exist is the factory's, and that is what is checked here.
      fb=$(jqr ".v2.externalDeployBlocks.houseVaultFactory // empty")
      if is_uint "$fb"; then
        ok "$name start block: the indexer's factory() source starts at v2.externalDeployBlocks.houseVaultFactory = $fb"
        if is_uint "$b"; then info "v2.externalDeployBlocks.houseVault = $b (recorded too; the factory block is the one the indexer uses)"
        else info "v2.externalDeployBlocks.houseVault is null by design: per-ticker vaults are discovered from the factory at block $fb"; fi
      else
        fail "$name ($k) is recorded but v2.externalDeployBlocks.houseVaultFactory is '${fb:-null}': the indexer discovers the vaults from the factory (ponder.config.ts:347) and has no block to start it from"
      fi
    elif is_uint "$b"; then ok "$name start block v2.externalDeployBlocks.$k = $b"; else fail "$name ($k) is recorded but v2.externalDeployBlocks.$k is '${b:-null}': the indexer has no block to start it from"; fi
  elif [ "$skipped" = 1 ]; then
    notchecked "$name ($k): in the skip list and not recorded -- not deployed by this launch"
    NOT_CHECKED_TARGETS="${NOT_CHECKED_TARGETS:+$NOT_CHECKED_TARGETS, }$name"
  else
    fail "$name ($k) is NOT RECORDED and not in the skip list: either the externals stage did not run or the key must be skipped by name"
  fi
done

group "1c. per-ticker House vaults (markets[].v2.houseVault, T-OP-156)"
LAUNCH=$(jqr 'if (.launchSet.markets | type) == "array" then .launchSet.markets | join(" ") else "" end')
[ -n "$LAUNCH" ] || fail "registry has no launchSet.markets block: the launch set cannot be read"
FIRST_LAUNCH=$(printf '%s\n' $LAUNCH | head -1)
HV_SINGLE=$(contract_of houseVault)
for T in $LAUNCH; do
  hv=$(jq -r --arg t "$T" '.markets[] | select(.ticker == $t) | .v2.houseVault // empty' "$STATE")
  if [ -z "$hv" ]; then fail "$T markets[].v2.houseVault is null: no House vault recorded for a launch ticker"; continue; fi
  probe_target "markets[$T].v2.houseVault" "$hv" HouseVault
  und=$(call_addr "$hv" "underlying()(address)")
  asset=$(jq -r --arg t "$T" '.markets[] | select(.ticker == $t) | .asset // empty' "$STATE")
  if [ -n "$und" ] && same_addr "$und" "$asset"; then ok "$T vault underlying() == the market's asset $asset"
  else fail "$T vault $hv underlying() is '${und:-<no answer>}', not the market's asset $asset"; fi
  if [ "$T" = "$FIRST_LAUNCH" ]; then
    if [ -n "$HV_SINGLE" ] && same_addr "$HV_SINGLE" "$hv"; then ok "v2.contracts.houseVault == $T's vault (the first launch ticker, the slot VerifyV8 walks)"
    else fail "v2.contracts.houseVault '${HV_SINGLE:-null}' is not the first launch ticker's ($T) vault $hv"; fi
  fi
  PER_TICKER_VAULTS=1
done
# T-OP-211: a recorded per-ticker vault needs the FACTORY's start block (the indexer walks VaultCreated from it,
# ponder.config.ts:347); its own slot in externalDeployBlocks is not what the indexer reads.
if [ "${PER_TICKER_VAULTS:-0}" = 1 ]; then
  fb=$(jqr ".v2.externalDeployBlocks.houseVaultFactory // empty")
  if is_uint "$fb"; then ok "per-ticker vaults are indexable: v2.externalDeployBlocks.houseVaultFactory = $fb"
  else fail "per-ticker vaults are recorded but v2.externalDeployBlocks.houseVaultFactory is '${fb:-null}': the indexer cannot discover them"; fi
fi

# ---------------------------------------------------------------- 2. roles
group "2. roles on the AccessManager $MGR against $ROLES_JSON"
ROLE_NAMES=$(jq -r '.roles | keys[]' "$ROLES_JSON")
role_id() { jq -r --arg r "$1" '.roles[$r]' "$ROLES_JSON"; }
role_delay() { jq -r --arg r "$1" '.delaysS[$r] // 0' "$ROLES_JSON"; }
holder_has() { jq -e --arg h "$1" --arg r "$2" '.holders[$h] // [] | index($r) != null' "$ROLES_JSON" >/dev/null 2>&1; }
principal_addr() { # manifest holder name -> address from the registry
  case "$1" in
    adminSafe) echo "$ADMIN_SAFE" ;; treasurySafe) echo "$TREASURY_SAFE" ;; guardianKey) echo "$GUARDIAN" ;;
    pricerKey) echo "$PRICER" ;; quoterKey) echo "$QUOTER" ;; crankerKey) echo "$CRANKER" ;; deployer) echo "$DEPLOYER" ;;
  esac
}
PRINCIPALS="adminSafe treasurySafe guardianKey pricerKey quoterKey crankerKey deployer"
if [ -z "$DEPLOYER" ]; then
  fail "deployer unknown: pass --deployer <address> (or export V2_DEPLOYER). The one principal that held every role during the deploy cannot be swept without it"
elif ! is_addr "$DEPLOYER"; then
  fail "--deployer '$DEPLOYER' is not a 20-byte address"
fi
for h in $PRINCIPALS; do
  who=$(principal_addr "$h")
  [ -n "$who" ] && is_addr "$who" || { [ "$h" = deployer ] || fail "$h has no address in the registry"; continue; }
  # DeployV8._principals: the seven must be distinct. A principal that is another principal is one key with two hats.
  for h2 in $PRINCIPALS; do
    [ "$h2" \> "$h" ] || continue
    who2=$(principal_addr "$h2"); [ -n "$who2" ] || continue
    if same_addr "$who" "$who2"; then fail "$h and $h2 are the same address $who: DeployV8 requires seven distinct principals"; fi
  done
  for r in $ROLE_NAMES; do
    id=$(role_id "$r")
    read -r member delay <<<"$(cast call "$MGR" "hasRole(uint64,address)(bool,uint32)" "$id" "$who" --rpc-url "$RPC" 2>/dev/null | tr '\n' ' ')"
    # T-OP-211 (live step 21, five false FAILs). cast annotates a uint >= 1e5 as `172800 [1.728e5]`, and `read` hands
    # the whole remainder of the joined line to the LAST name, so `delay` carried the annotation into the compare.
    # The bare integer is the first word; the same sink rehearse-v2.sh:314 got in T-OP-206.
    delay=${delay%% *}
    if [ -z "$member" ]; then fail "$h $who: hasRole($r=$id) could not be read"; continue; fi
    if holder_has "$h" "$r"; then
      want=$(role_delay "$r")
      if [ "$member" = true ] && [ "$delay" = "$want" ]; then ok "$h holds $r ($id) at delay ${delay}s"
      elif [ "$member" = true ]; then fail "$h holds $r ($id) at delay ${delay}s, manifest says ${want}s"
      else fail "$h $who does NOT hold $r ($id), which roles.v8.json gives it"; fi
    else
      if [ "$member" = true ]; then fail "$h $who HOLDS $r ($id) (delay ${delay}s), which roles.v8.json does not give it$([ "$h" = deployer ] && echo ' -- THE DEPLOYER STILL HOLDS A ROLE: the hand-back is incomplete')"
      else ok "$h holds no $r ($id)"; fi
    fi
  done
  # Delayed roles (0..6) belong to contracts, never to a plain key (DeployV8._principals, VerifyV8._principals c).
  if holder_has "$h" ADMIN || holder_has "$h" CONFIG_ADMIN || holder_has "$h" LISTING; then
    if has_code "$who"; then ok "$h $who is a contract (holds a delayed role)"; else fail "$h $who holds a delayed role and is a PLAIN KEY (no code)"; fi
  fi
done

# ---------------------------------------------------------------- 3. receipt + fingerprint
group "3. the VerifyV8 receipt and the deployment fingerprint (BroadcastV8.assertFingerprint, the driver's function)"
if [ -z "$RUN_DIR" ]; then
  fail "--run-dir not given: the receipt broadcast-v8.sh wrote (verify-passed.json) cannot be checked against the chain"
elif [ ! -f "$RUN_DIR/verify-passed.json" ]; then
  fail "no receipt at $RUN_DIR/verify-passed.json: VerifyV8 did not pass in that run, or this is the wrong run dir"
else
  RECEIPT="$RUN_DIR/verify-passed.json"
  WANT_FP=$(jq -r '.fingerprint // empty' "$RECEIPT"); WANT_CHAIN=$(jq -r '.chainId // empty' "$RECEIPT")
  WANT_SHA=$(jq -r '.registrySha256 // empty' "$RECEIPT"); AT=$(jq -r '.verifiedAt // empty' "$RECEIPT")
  info "receipt $RECEIPT: fingerprint ${WANT_FP:-<none>} chain ${WANT_CHAIN:-<none>} verifiedAt ${AT:-<none>}"
  if [ -z "$WANT_FP" ]; then fail "receipt has no fingerprint field: it binds the pass to nothing"; fi
  if [ "$WANT_CHAIN" = "$CHAIN" ]; then ok "receipt chainId $WANT_CHAIN == chain on rpc"; else fail "receipt verified chain '${WANT_CHAIN:-<none>}', this rpc answers $CHAIN"; fi
  if [ -n "$WANT_SHA" ] && [ "$WANT_SHA" != "$REG_SHA" ]; then
    info "receipt registrySha256 $WANT_SHA != this registry's $REG_SHA: expected after the post-verify write-backs (registeredAt, status); the fingerprint below is what binds, not the sha (T-OP-154 F8)"
  fi
  if [ -n "$WANT_FP" ] && [ -z "$MISSING_CORE" ]; then
    # The address list in CONTRACT_KEYS order: order is part of the fingerprint (broadcast-v8.sh read_contract_addrs).
    ADDRS=""; for k in $CONTRACT_KEYS; do ADDRS="${ADDRS:+$ADDRS,}$(contract_of "$k")"; done
    MIN=$(printf '%s\n' $CONTRACT_KEYS | wc -l | tr -d ' ')
    FP_SCRIPT="$HERE/BroadcastV8.s.sol"
    if grep -vE '^[[:space:]]*(///|//|\*|/\*)' "$FP_SCRIPT" | grep -q "startBroadcast"; then
      fail "$FP_SCRIPT contains startBroadcast in code: not fit to fingerprint a deployment (the driver's refuse_if_can_broadcast rule)"
    else
      FP_LOG=$(mktemp)
      if (cd "$ROOT" && V8_EXPECT_FINGERPRINT="$WANT_FP" V8_FINGERPRINT_ADDRS="$ADDRS" V8_MIN_CONTRACTS="$MIN" \
            forge script "$FP_SCRIPT:BroadcastV8" --sig "assertFingerprint()" --rpc-url "$RPC" --no-storage-caching --non-interactive) > "$FP_LOG" 2>&1 \
         && grep -q "BROADCASTV8 FINGERPRINT MATCHES" "$FP_LOG"; then
        ok "BroadcastV8.assertFingerprint(): the $MIN recorded addresses + code hashes on chain $CHAIN match the receipt ($WANT_FP)"
      else
        fail "BroadcastV8.assertFingerprint() did not print MATCHES: the deployment on chain is not the one VerifyV8 passed against$(grep -E 'BROADCASTV8 (EXPECTED|ACTUAL)|revert|Error' "$FP_LOG" | head -3 | tr '\n' ' ' | sed 's/^/ -- /')"
      fi
      rm -f "$FP_LOG"
    fi
  elif [ -n "$MISSING_CORE" ]; then
    fail "fingerprint not derivable: the registry is missing $MISSING_CORE"
  fi
fi

# ---------------------------------------------------------------- 4. markets
group "4. launch-set markets on the Clearinghouse $(contract_of clearinghouse)"
CH=$(contract_of clearinghouse); ORACLE=$(contract_of settlementOracle)
for T in $LAUNCH; do
  row=$(jq -c --arg t "$T" '.markets[] | select(.ticker == $t) | {asset, status: .v2.status, registeredAt: .v2.registeredAt, registerTx: .v2.registerTx, strikeTick: .v2.strikeTick}' "$STATE")
  [ -n "$row" ] || { fail "$T is in launchSet.markets but has no registry row"; continue; }
  asset=$(printf '%s' "$row" | jq -r .asset); status=$(printf '%s' "$row" | jq -r '.status // "null"')
  regAt=$(printf '%s' "$row" | jq -r '.registeredAt // empty'); regTx=$(printf '%s' "$row" | jq -r '.registerTx // empty')
  if [ -n "$regAt" ] && [ -n "$regTx" ]; then ok "$T registry: registeredAt $regAt registerTx $regTx"; else fail "$T registry row has registeredAt '${regAt:-null}' / registerTx '${regTx:-null}': the register write-back did not happen"; fi
  if [ "$status" = live ]; then ok "$T registry v2.status == live"; else fail "$T registry v2.status is '$status', not live"; fi
  if [ -z "$CH" ]; then fail "$T cannot be read on chain: clearinghouse not recorded"; continue; fi
  cfg=$(cast call "$CH" "market(address)((bool,bool,uint64,uint16,address,uint32))" "$asset" --rpc-url "$RPC" 2>/dev/null | tr -d '() ' )
  if [ -z "$cfg" ]; then fail "$T Clearinghouse.market($asset) could not be read"; continue; fi
  enabled=$(printf '%s' "$cfg" | cut -d, -f1); paused=$(printf '%s' "$cfg" | cut -d, -f2)
  tick=$(printf '%s' "$cfg" | cut -d, -f3); tick=${tick%%\[*}; orc=$(printf '%s' "$cfg" | cut -d, -f5)   # T-OP-211: `2500000[2.5e6]` -> 2500000 (the compare is != 0, so cosmetic)
  if [ "$tick" != 0 ]; then ok "$T registered on the Clearinghouse (strikeTick $tick)"; else fail "$T is NOT registered on the Clearinghouse (strikeTick 0)"; fi
  if [ "$enabled" = true ]; then ok "$T enabled"; else fail "$T market is not enabled"; fi
  if [ "$paused" = false ]; then ok "$T mint not paused"; else fail "$T mint is PAUSED"; fi
  if same_addr "$orc" "$ORACLE"; then ok "$T oracle == settlementOracle"; else fail "$T oracle is $orc, not the recorded SettlementOracle $ORACLE"; fi
done

# ---------------------------------------------------------------- summary
TOTAL=$((PASSES + FAILS))
emit ""
NC=""; [ "$NOTCHECKED" = 0 ] || NC=" with $NOTCHECKED NOT CHECKED"
if [ "$FAILS" = 0 ]; then
  emit "POST-LAUNCH CHECK PASSED: $PASSES checks$NC"
else
  emit "POST-LAUNCH CHECK FAILED: $FAILS check(s) failed of $TOTAL$NC"
  emit "$FAILED_LINES"
fi
[ -z "$NOT_CHECKED_TARGETS" ] || emit "NOT CHECKED targets: $NOT_CHECKED_TARGETS (skip list; not deployed by this launch)"
[ -z "$OUT" ] || emit "report written to $OUT"
[ "$FAILS" = 0 ]
