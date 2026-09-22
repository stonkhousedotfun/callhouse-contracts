#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# verify-house-vault.sh — a `cast` role-walk of ONE HouseVault instance against roles.v8.json.
#
#   script/v2/verify-house-vault.sh <vault> --registry <tier1.json> --ticker <T> [--rpc <url>]
#   script/v2/verify-house-vault.sh <vault> --manager 0x.. --asset 0x.. [--order-book 0x..] ... [--rpc <url>]
#   script/v2/verify-house-vault.sh --help
#
# WHY THIS FILE EXISTS (T-OP-178, owner ask 2026-09-22 06:51Z). The launch has TWO House vaults (NVDA and
# SPCX, owner ruling 05:45Z) and `VerifyV8.s.sol` walks ONE `HouseVault` manifest target -- the address in
# `v2.contracts.houseVault`, which is the FIRST launch ticker's vault (registry home option A). Until
# T-OP-171 gives VerifyV8 per-ticker vault subjects, nothing on the launch path reads the SECOND vault's
# role map after the Safe's `map-execute` batch. This script is the day-zero fallback for that vault, and
# it works on any vault: it asks the chain what the manager holds for every selector the manifest lists
# and refuses, by name, whatever differs.
#
# WHAT IT CHECKS, IN ORDER, AND WHERE EACH EXPECTATION COMES FROM:
#   1. the vault has code, and `authority()` is the manager                (--manager | registry v2.contracts.accessManager)
#   2. ROLE WALK: for every signature in `.targets.HouseVault` of the manifest,
#      `manager.getTargetFunctionRole(vault, selector)` == `.roles[<name>]`  (roles.v8.json; the list is DERIVED
#      from the manifest with jq, the same technique check-roles-targets.sh uses -- nothing is copied)
#      and every `.unrestricted.HouseVault` selector reads role 0 (never mapped to a lane)
#   3. IDENTITY: `underlying()` == the market's asset, `orderBook()` / `clearinghouse()` / `oracle()` /
#      `calendar()` / `splitter()` / `usdg()` == the registry's addresses, and `factory.vaultOf(underlying)`
#      == the vault; when --ticker is given, the registry's `markets[T].v2.houseVault` == the vault, and when
#      T is the first launch ticker, `v2.contracts.houseVault` == the vault too
#   4. LIMITS: `limits()` decoded and compared field by field with the limits file's entry for the ticker
#      (--limits, default script/v2/fixtures/house-limits.v8.json, the file DeployHouseVault created from)
#   5. `quotingPaused()` == --expect-paused (default false: a day-zero vault is not paused), and
#      `protocolAccountsConfirmed()` printed (INFO: armed or not; arming is the Safe's `arm` stage)
#
# EXIT CODES. 0 every check that ran passed; 1 at least one REJECT (each printed as `REJECT <check> <name>:
# <expected> != <actual>`); 2 usage or tooling error (no rpc, no code at the vault, jq/cast missing, a
# manifest without `.targets.HouseVault`).
#
# A CHECK WITH NO EXPECTATION IS SKIPPED BY NAME, NEVER PASSED. A registry before write-back carries null
# for the vault keys; the script prints `SKIP <check>: <why>` and counts it. The summary line carries the
# three counts, and a run with ZERO checks performed is a usage error (2), not a pass -- a walk that had
# nothing to compare must not print PASS.
#
# READ-ONLY. Every chain access is `cast call` / `cast code`. Nothing here signs or sends.
#
# bash 3.2 compatible (macOS), bash + jq + cast, no python -- the convention check-roles-targets.sh states.
# -------------------------------------------------------------------------------------------------
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
MANIFEST="$REPO/script/v2/roles.v8.json"
LIMITS_FILE="$REPO/script/v2/fixtures/house-limits.v8.json"
TARGET_NAME="HouseVault"

VAULT=""
REGISTRY=""
TICKER=""
RPC="${RH_RPC:-${ETH_RPC_URL:-}}"
EXPECT_MANAGER=""
EXPECT_ASSET=""
EXPECT_ORDER_BOOK=""
EXPECT_CLEARINGHOUSE=""
EXPECT_ORACLE=""
EXPECT_CALENDAR=""
EXPECT_SPLITTER=""
EXPECT_USDG=""
EXPECT_FACTORY=""
EXPECT_PAUSED="false"
NO_LIMITS=0

die() {
  echo "verify-house-vault: $*" >&2
  exit 2
}

usage() { sed -n '2,/^# ----/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --registry) [ $# -ge 2 ] || die "--registry needs a path"; REGISTRY=$2; shift 2 ;;
    --registry=*) REGISTRY=${1#*=}; shift ;;
    --ticker) [ $# -ge 2 ] || die "--ticker needs a symbol"; TICKER=$2; shift 2 ;;
    --ticker=*) TICKER=${1#*=}; shift ;;
    --rpc | --rpc-url) [ $# -ge 2 ] || die "--rpc needs a url"; RPC=$2; shift 2 ;;
    --rpc=*) RPC=${1#*=}; shift ;;
    --manifest) [ $# -ge 2 ] || die "--manifest needs a path"; MANIFEST=$2; shift 2 ;;
    --manifest=*) MANIFEST=${1#*=}; shift ;;
    --limits) [ $# -ge 2 ] || die "--limits needs a path"; LIMITS_FILE=$2; shift 2 ;;
    --limits=*) LIMITS_FILE=${1#*=}; shift ;;
    --no-limits) NO_LIMITS=1; shift ;;
    --manager) [ $# -ge 2 ] || die "--manager needs an address"; EXPECT_MANAGER=$2; shift 2 ;;
    --asset) [ $# -ge 2 ] || die "--asset needs an address"; EXPECT_ASSET=$2; shift 2 ;;
    --order-book) [ $# -ge 2 ] || die "--order-book needs an address"; EXPECT_ORDER_BOOK=$2; shift 2 ;;
    --clearinghouse) [ $# -ge 2 ] || die "--clearinghouse needs an address"; EXPECT_CLEARINGHOUSE=$2; shift 2 ;;
    --oracle) [ $# -ge 2 ] || die "--oracle needs an address"; EXPECT_ORACLE=$2; shift 2 ;;
    --calendar) [ $# -ge 2 ] || die "--calendar needs an address"; EXPECT_CALENDAR=$2; shift 2 ;;
    --splitter) [ $# -ge 2 ] || die "--splitter needs an address"; EXPECT_SPLITTER=$2; shift 2 ;;
    --usdg) [ $# -ge 2 ] || die "--usdg needs an address"; EXPECT_USDG=$2; shift 2 ;;
    --factory) [ $# -ge 2 ] || die "--factory needs an address"; EXPECT_FACTORY=$2; shift 2 ;;
    --expect-paused) [ $# -ge 2 ] || die "--expect-paused needs true|false"; EXPECT_PAUSED=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    -*) die "unknown argument: $1 (see --help)" ;;
    *)
      [ -z "$VAULT" ] || die "one vault address only (got '$VAULT' and '$1')"
      VAULT=$1; shift ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
command -v cast >/dev/null 2>&1 || die "cast not found on PATH"
[ -n "$VAULT" ] || { usage >&2; die "a vault address is required"; }
[ -n "$RPC" ] || die "no rpc: pass --rpc <url> or export RH_RPC / ETH_RPC_URL"
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
jq -e . "$MANIFEST" >/dev/null 2>&1 || die "$MANIFEST is not valid JSON"
jq -e --arg t "$TARGET_NAME" '.targets[$t] | type == "object"' "$MANIFEST" >/dev/null 2>&1 ||
  die "$MANIFEST has no .targets.$TARGET_NAME object: this is not a v8 role manifest"
case "$EXPECT_PAUSED" in true | false) ;; *) die "--expect-paused must be true or false" ;; esac

# --- helpers ---------------------------------------------------------------------------------------
CHECKED=0
SKIPPED=0
REJECTED=0

# Every address is compared in ONE spelling. `cast to-check-sum-address` refuses a malformed input, so a
# typo in an expectation dies here (exit 2) instead of becoming a REJECT that reads like a chain fact.
checksum() { # <addr>
  local out
  out=$(cast to-check-sum-address "$1" 2>/dev/null) || die "not an address: '$1'"
  printf '%s' "$out"
}

is_addr() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }

# `cast call` against the vault; the first line of the decoded output is the value.
# NOTE: `cast call` may append a bracketed scientific form to big integers (`25000000000 [2.5e10]`);
# {first_token} strips it wherever a number is compared.
vcall() { # <to> <sig> [args...]
  local to=$1; shift
  cast call --rpc-url "$RPC" "$to" "$@" 2>/dev/null
}
first_token() { awk '{print $1; exit}'; }

pass() { # <check> <name> <value>
  CHECKED=$((CHECKED + 1))
  echo "ok     $1 $2: $3"
}
reject() { # <check> <name> <expected> <actual>
  CHECKED=$((CHECKED + 1))
  REJECTED=$((REJECTED + 1))
  echo "REJECT $1 $2: expected $3, chain says $4" >&2
}
skip() { # <check> <name> <why>
  SKIPPED=$((SKIPPED + 1))
  echo "SKIP   $1 $2: $3"
}

# Compare an address getter on the vault with an expectation; empty expectation -> SKIP by name.
check_addr() { # <check> <name> <expected|""> <actual> <why-if-skipped>
  local check=$1 name=$2 expected=$3 actual=$4 why=$5
  if [ -z "$expected" ]; then
    skip "$check" "$name" "$why"
    return 0
  fi
  expected=$(checksum "$expected")
  actual=$(checksum "$actual")
  if [ "$expected" = "$actual" ]; then pass "$check" "$name" "$actual"; else reject "$check" "$name" "$expected" "$actual"; fi
}

# --- the registry projection (optional) --------------------------------------------------------------
# The expectations come from the SAME keys registry-env.sh projects to V2_* (T-OP-113): v2.contracts.*,
# shared.usdg, v2.flywheel.feeSplitter, markets[T].asset, markets[T].v2.houseVault, launchSet.markets.
# A null key is an empty expectation (SKIP), never a zero address. A command-line override wins.
reg() { # <jq path>
  [ -n "$REGISTRY" ] || { printf ''; return 0; }
  jq -r "$1 // empty" "$REGISTRY"
}
if [ -n "$REGISTRY" ]; then
  [ -f "$REGISTRY" ] || die "registry not found: $REGISTRY"
  jq -e '.v2.contracts | type == "object"' "$REGISTRY" >/dev/null 2>&1 || die "$REGISTRY has no v2.contracts block"
  [ -n "$EXPECT_MANAGER" ] || EXPECT_MANAGER=$(reg '.v2.contracts.accessManager')
  [ -n "$EXPECT_ORDER_BOOK" ] || EXPECT_ORDER_BOOK=$(reg '.v2.contracts.orderBook')
  [ -n "$EXPECT_CLEARINGHOUSE" ] || EXPECT_CLEARINGHOUSE=$(reg '.v2.contracts.clearinghouse')
  [ -n "$EXPECT_ORACLE" ] || EXPECT_ORACLE=$(reg '.v2.contracts.settlementOracle')
  [ -n "$EXPECT_CALENDAR" ] || EXPECT_CALENDAR=$(reg '.v2.contracts.expiryCalendar')
  [ -n "$EXPECT_SPLITTER" ] || EXPECT_SPLITTER=$(reg '.v2.flywheel.feeSplitter')
  [ -n "$EXPECT_USDG" ] || EXPECT_USDG=$(reg '.shared.usdg')
  [ -n "$EXPECT_FACTORY" ] || EXPECT_FACTORY=$(reg '.v2.contracts.houseVaultFactory')
  if [ -n "$TICKER" ]; then
    [[ "$TICKER" =~ ^[A-Z0-9]+$ ]] || die "ticker '$TICKER' is not A-Z0-9"
    jq -e --arg t "$TICKER" '.markets[] | select(.ticker == $t)' "$REGISTRY" >/dev/null 2>&1 ||
      die "$TICKER is not in the registry $REGISTRY"
    [ -n "$EXPECT_ASSET" ] || EXPECT_ASSET=$(jq -r --arg t "$TICKER" '.markets[] | select(.ticker == $t) | .asset // empty' "$REGISTRY")
  fi
fi
[ -n "$RPC" ] || die "no rpc"

# --- 1. code and authority ---------------------------------------------------------------------------
is_addr "$VAULT" || die "vault '$VAULT' is not an address"
VAULT=$(checksum "$VAULT")
code=$(cast code --rpc-url "$RPC" "$VAULT" 2>/dev/null || true)
[ -n "$code" ] && [ "$code" != "0x" ] || die "no code at $VAULT on $RPC: not a deployed vault (or the wrong rpc)"

authority=$(vcall "$VAULT" "authority()(address)" | first_token) || die "$VAULT does not answer authority(): not a Managed v8 target"
is_addr "$authority" || die "authority() returned '$authority'"
if [ -z "$EXPECT_MANAGER" ]; then
  # The walk below still runs against authority() -- that IS the manager gating this vault -- but the
  # identity of that manager is unverified, and the summary says so.
  skip authority manager "no expected manager (pass --manager or --registry with v2.contracts.accessManager); walking authority() $authority unverified"
  MANAGER=$(checksum "$authority")
else
  check_addr authority manager "$EXPECT_MANAGER" "$authority" ""
  MANAGER=$(checksum "$EXPECT_MANAGER")
  # A vault bound to a different manager than expected must be walked against ITS manager, or every
  # role read below is a question to the wrong contract. The REJECT above already fired; walk the real one.
  if [ "$(checksum "$authority")" != "$MANAGER" ]; then MANAGER=$(checksum "$authority"); fi
fi

# --- 2. the role walk ----------------------------------------------------------------------------------
# Derived from the manifest: every key of .targets.HouseVault with its role NAME, and the role id from
# .roles. `cast sig` computes the selector from the signature string -- no selector is typed here.
sigs=$(jq -r --arg t "$TARGET_NAME" '.targets[$t] | keys[]' "$MANIFEST")
nsigs=$(printf '%s\n' "$sigs" | grep -c '[^[:space:]]' || true)
[ "$nsigs" -gt 0 ] || die "$MANIFEST maps no selector for $TARGET_NAME: the walk has no subject"

role_name_of_id() { # <id> -> name or "role#<id>"; never fails (it runs inside a $(...) in a REJECT line)
  local n=""
  n=$(jq -r --argjson i "$1" '.roles | to_entries[] | select(.value == $i) | .key' "$MANIFEST" 2>/dev/null | head -n 1) || true
  if [ -n "$n" ]; then printf '%s' "$n"; else printf 'role#%s' "$1"; fi
}

while IFS= read -r sig; do
  [ -n "$sig" ] || continue
  role_name=$(jq -r --arg t "$TARGET_NAME" --arg s "$sig" '.targets[$t][$s]' "$MANIFEST")
  expected_id=$(jq -r --arg r "$role_name" '.roles[$r] // empty' "$MANIFEST")
  [ -n "$expected_id" ] || die "$MANIFEST maps $TARGET_NAME.$sig to '$role_name', which .roles does not define"
  selector=$(cast sig "$sig" 2>/dev/null) || die "cast sig failed on '$sig'"
  actual_id=$(vcall "$MANAGER" "getTargetFunctionRole(address,bytes4)(uint64)" "$VAULT" "$selector" | first_token) ||
    die "getTargetFunctionRole($VAULT, $selector) failed on manager $MANAGER"
  [[ "$actual_id" =~ ^[0-9]+$ ]] || die "getTargetFunctionRole($VAULT, $selector) answered '$actual_id', not a role id"
  if [ "$actual_id" = "$expected_id" ]; then
    pass role "$sig" "$role_name ($expected_id) $selector"
  else
    reject role "$sig" "$role_name ($expected_id)" "$(role_name_of_id "$actual_id") ($actual_id)"
  fi
done <<SIGS
$sigs
SIGS

# `.unrestricted.HouseVault` are the permissionless entry points (requestDeposit, rollEpoch, claim ...):
# a row there that the manager maps to a lane means somebody gated a user path. Role 0 is ADMIN_ROLE and
# is also what the manager answers for a pair it was never told about, so 0 is the only acceptable read.
usigs=$(jq -r --arg t "$TARGET_NAME" 'if (.unrestricted[$t] | type) == "object" then (.unrestricted[$t] | keys[]) else empty end' "$MANIFEST")
while IFS= read -r sig; do
  [ -n "$sig" ] || continue
  selector=$(cast sig "$sig" 2>/dev/null) || die "cast sig failed on '$sig'"
  actual_id=$(vcall "$MANAGER" "getTargetFunctionRole(address,bytes4)(uint64)" "$VAULT" "$selector" | first_token) ||
    die "getTargetFunctionRole($VAULT, $selector) failed on manager $MANAGER"
  [[ "$actual_id" =~ ^[0-9]+$ ]] || die "getTargetFunctionRole($VAULT, $selector) answered '$actual_id', not a role id"
  if [ "$actual_id" = "0" ]; then
    pass unrestricted "$sig" "not mapped (0) $selector"
  else
    reject unrestricted "$sig" "not mapped (0)" "$(role_name_of_id "$actual_id") ($actual_id)"
  fi
done <<USIGS
$usigs
USIGS

# --- 3. identity ------------------------------------------------------------------------------------------
underlying=$(vcall "$VAULT" "underlying()(address)" | first_token) || die "underlying() failed"
check_addr identity underlying "$EXPECT_ASSET" "$underlying" "no expected asset (pass --asset, or --registry with --ticker)"
check_addr identity orderBook "$EXPECT_ORDER_BOOK" "$(vcall "$VAULT" "orderBook()(address)" | first_token)" "registry v2.contracts.orderBook is null or no --order-book"
check_addr identity clearinghouse "$EXPECT_CLEARINGHOUSE" "$(vcall "$VAULT" "clearinghouse()(address)" | first_token)" "registry v2.contracts.clearinghouse is null or no --clearinghouse"
check_addr identity oracle "$EXPECT_ORACLE" "$(vcall "$VAULT" "oracle()(address)" | first_token)" "registry v2.contracts.settlementOracle is null or no --oracle"
check_addr identity calendar "$EXPECT_CALENDAR" "$(vcall "$VAULT" "calendar()(address)" | first_token)" "registry v2.contracts.expiryCalendar is null or no --calendar"
check_addr identity splitter "$EXPECT_SPLITTER" "$(vcall "$VAULT" "splitter()(address)" | first_token)" "registry v2.flywheel.feeSplitter is null or no --splitter"
check_addr identity usdg "$EXPECT_USDG" "$(vcall "$VAULT" "usdg()(address)" | first_token)" "registry shared.usdg is null or no --usdg"

if [ -n "$EXPECT_FACTORY" ]; then
  factory=$(checksum "$EXPECT_FACTORY")
  fcode=$(cast code --rpc-url "$RPC" "$factory" 2>/dev/null || true)
  if [ -z "$fcode" ] || [ "$fcode" = "0x" ]; then
    reject identity "factory.vaultOf(underlying)" "a factory with code at $factory" "no code at $factory"
  else
    vof=$(vcall "$factory" "vaultOf(address)(address)" "$underlying" | first_token) || die "vaultOf($underlying) failed on factory $factory"
    check_addr identity "factory.vaultOf(underlying)" "$VAULT" "$vof" ""
  fi
else
  skip identity "factory.vaultOf(underlying)" "registry v2.contracts.houseVaultFactory is null or no --factory"
fi

if [ -n "$REGISTRY" ] && [ -n "$TICKER" ]; then
  reg_vault=$(jq -r --arg t "$TICKER" '.markets[] | select(.ticker == $t) | .v2.houseVault // empty' "$REGISTRY")
  check_addr registry "markets[$TICKER].v2.houseVault" "$reg_vault" "$VAULT" "markets[$TICKER].v2.houseVault is null (registry not written back yet)"
  first_launch=$(jq -r '.launchSet.markets[0] // empty' "$REGISTRY")
  if [ -n "$first_launch" ] && [ "$first_launch" = "$TICKER" ]; then
    check_addr registry "v2.contracts.houseVault (first launch ticker $TICKER)" "$(reg '.v2.contracts.houseVault')" "$VAULT" "v2.contracts.houseVault is null (registry not written back yet)"
  fi
fi

# --- 4. limits ------------------------------------------------------------------------------------------------
# `limits()` returns the six-field tuple in declaration order (HouseVault.sol `Limits`); the file keys are the
# struct's own field names, uint64/uint128 as decimal strings and uint16/uint32 as numbers (T-OP-158).
if [ "$NO_LIMITS" = 1 ]; then
  skip limits "$TICKER" "--no-limits"
elif [ -z "$TICKER" ]; then
  skip limits "(no ticker)" "pass --ticker <T> to compare limits() with $LIMITS_FILE"
elif [ ! -f "$LIMITS_FILE" ]; then
  die "limits file not found: $LIMITS_FILE (pass --limits or --no-limits)"
elif ! jq -e --arg t "$TICKER" '.[$t] | type == "object"' "$LIMITS_FILE" >/dev/null 2>&1; then
  reject limits "$TICKER" "an entry for $TICKER in $LIMITS_FILE" "none (a launch ticker the limits file lacks)"
else
  raw=$(vcall "$VAULT" "limits()((uint64,uint128,uint16,uint16,uint32,uint128))") || die "limits() failed"
  # "(500, 25000000000 [2.5e10], 25, 300, 1800, 625000000 [6.25e8])" -> six plain decimals, one per line
  fields=$(printf '%s' "$raw" | tr -d '()' | tr ',' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]].*$//')
  nfields=$(printf '%s\n' "$fields" | grep -c '[^[:space:]]' || true)
  [ "$nfields" = 6 ] || die "limits() decoded to $nfields fields, expected 6: '$raw'"
  i=0
  for name in maxSeriesUnits maxTotalNotional askToleranceBps maxBidBpsOfSpot maxOrderLifetime maxDailyOutflow; do
    i=$((i + 1))
    actual=$(printf '%s\n' "$fields" | sed -n "${i}p")
    expected=$(jq -r --arg t "$TICKER" --arg f "$name" '.[$t][$f] // empty | tostring' "$LIMITS_FILE")
    if [ -z "$expected" ]; then
      reject limits "$TICKER.$name" "a value in $LIMITS_FILE" "file has none (chain: $actual)"
      continue
    fi
    # decimal string compare after stripping leading zeros; both sides are non-negative integers
    e=$(printf '%s' "$expected" | sed -E 's/^0+([0-9])/\1/'); a=$(printf '%s' "$actual" | sed -E 's/^0+([0-9])/\1/')
    [[ "$e" =~ ^[0-9]+$ ]] || die "$LIMITS_FILE $TICKER.$name is '$expected', not an unsigned integer"
    [[ "$a" =~ ^[0-9]+$ ]] || die "limits().$name decoded to '$actual', not an unsigned integer"
    if [ "$e" = "$a" ]; then pass limits "$TICKER.$name" "$a"; else reject limits "$TICKER.$name" "$e" "$a"; fi
  done
fi

# --- 5. flags -----------------------------------------------------------------------------------------------
paused=$(vcall "$VAULT" "quotingPaused()(bool)" | first_token) || die "quotingPaused() failed"
if [ "$paused" = "$EXPECT_PAUSED" ]; then pass flag quotingPaused "$paused"; else reject flag quotingPaused "$EXPECT_PAUSED" "$paused"; fi
armed=$(vcall "$VAULT" "protocolAccountsConfirmed()(bool)" | first_token) || die "protocolAccountsConfirmed() failed"
echo "info   flag protocolAccountsConfirmed: $armed$([ "$armed" = true ] || printf ' (take is unarmed until the Safe'"'"'s arm stage executes)')"

# --- summary ------------------------------------------------------------------------------------------------
[ "$CHECKED" -gt 0 ] || die "no check ran against $VAULT: nothing to compare (this is not a pass)"
if [ "$REJECTED" -gt 0 ]; then
  echo "verify-house-vault: $VAULT on manager $MANAGER: $REJECTED REJECT, $((CHECKED - REJECTED)) ok, $SKIPPED skipped" >&2
  exit 1
fi
echo "verify-house-vault: $VAULT on manager $MANAGER: PASS ($CHECKED ok, $SKIPPED skipped, $nsigs manifest selectors walked)"
