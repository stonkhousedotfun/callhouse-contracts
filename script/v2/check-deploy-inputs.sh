#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# check-deploy-inputs.sh — every registry / v2-sources path the deploy wrapper reads, checked against
# the files it will read them from, BEFORE any forge step runs.
#
# WHY THIS FILE EXISTS. `script/v2/DeployV2Batch.sh` reads the registry (`ops/markets/tier1.json` in
# callhouse) and the recon file beside it (`v2-sources.json`) with `jq`, one path at a time, and refuses
# a null input by name -- but only when it reaches that line, and several of its reads come AFTER a
# `forge build`. Five inputs were null on the real registry at callhouse `e09af8aa` (shared.token.poolKey,
# shared.guardian, v2-sources contracts.weth / usdgWethV3Pool / verifierProxy), each an independent stop
# of the real broadcast, and the launch driver `broadcast-v8.sh` reads none of them itself, so the first
# thing to notice was a forge simulation dying with "environment variable not found" after a full solc
# compile (T-OP-081, T-OP-108, T-OP-112). The symmetric latent: the wrapper WRITES BACK keys after a
# deploy (`v2.contracts.*`, `v2.flywheel.*`, `v2.deployBlock`, `v2.bots.*`, `markets[].v2.*`), and the
# registry builder's `exactKeys` refuses a registry carrying a key its skeleton lacks -- so a write-back
# into a skeleton that lacks the key is refused AFTER the transactions were mined.
#
# THE READ LIST IS DERIVED FROM THE WRAPPER AT RUN TIME, NEVER COPIED. A list typed here would be green
# at the tip it was written against and blind to the next read the wrapper grows -- the false-green
# shape T-OP-022's check-env-names.sh was written to close. So this script lifts every `jqr '...'`,
# `jq -r '...'` and `jq -e '...'` path expression out of DeployV2Batch.sh AND OUT OF EVERY LIBRARY IT
# SOURCES by line pattern, notes which file each one reads (the registry `$STATE`/`$REGISTRY`, the recon
# `$SOURCES`, the role manifest `$ROLES_JSON`, a market row `<<<"$row"`, or something else), and
# classifies it by WHERE it occurs:
#
#   INPUT       read before the first `run_forge` invocation. Must be non-null; an address must be
#               EIP-55 canonical (`cast to-check-sum-address`, unless --no-checksum) and, with --rpc,
#               must hold code.
#   MARKET      read from a `markets[]` row (`<<<"$row"`). Evaluated for EVERY market in the registry;
#               the wrapper reads only the selected tickers, so a per-market failure names the ticker
#               and the operator decides whether that market is in the selection.
#   POST        read after the first forge step (write-back results re-read). Listed, not required.
#   OTHER       not a registry/sources read (build artifacts, receipts, logs). Listed, not evaluated.
#   WALLET      an INPUT/MARKET address that is a KEY by design -- the guardian, the ops wallet, the bot keys,
#               shared.admin -- derived from the principal list `registry_env_refuse_deployer_is_principal`
#               walks in the sourced library (every name there that is not under `shared.safes.`; the Safes
#               are contracts, DeployV8._principals requires their code). Still EIP-55 strict, still non-null
#               where the wrapper requires; `--rpc`'s has_code is NOT applied (T-OP-187: it rejected the
#               four EOA principals on the real registry and the launch driver died at step 0a). Every other
#               address keeps has_code, including the Safes and every `v2.contracts.*` slot.
#   WRITE-BACK  every path any scanned function writes into the registry (`write_back()` in the wrapper,
#               `registry_env_record_external()` in the library, ...), derived by shape -- see
#               derive_write_back. The key must EXIST in the registry (null is fine; absent is not), or
#               the post-deploy write-back is refused by the builder's exactKeys.
#
# THE WRAPPER AND ITS SOURCED LIBRARIES ARE SCANNED AS ONE UNIT (T-OP-137). T-OP-113 moved the registry
# -> V2_* projection -- CONTRACT_KEYS, EXTERNAL_KEYS, jqr() and about half of the jq reads, INCLUDING
# the input reads this check exists for -- out of the wrapper into a library the wrapper sources
# (`. "$ROOT/script/v2/lib/registry-env.sh"`). A scan of the wrapper alone then found none of the four
# anchors and died rc=2 (broadcast-v8.sh step 0a, rehearse-v2.sh step 0 and both CI steps dead at the
# tip); the plausible wrong fix -- point the anchors at the library and keep lifting reads from the
# wrapper -- goes green while blind to every read the library makes, which is the exact shape T-OP-112
# was written to catch. So:
#
#   * the library paths are DERIVED from the wrapper's own top-level source lines
#     (`. "$ROOT/<path>"` / `source "$ROOT/<path>"`), resolved against the wrapper's repository root the
#     way the wrapper resolves `$ROOT` (`cd "$(dirname "$0")/../.."`). Nothing here names a library file.
#     `--lib <rel>=<path>` substitutes a scratch copy for the library at `<rel>` and is accepted ONLY
#     inside --self-test (the parent exports CHECK_DEPLOY_INPUTS_SELFTEST=1 to its fixture runs).
#   * each anchor (`^CONTRACT_KEYS=`, `^EXTERNAL_KEYS=`, `^write_back()`, `^jqr()`) must match exactly
#     one line across the UNION of wrapper + libraries, and the file that carries it is named and used.
#   * reads are lifted from every file in the union. A read INSIDE A LIBRARY FUNCTION is classified by
#     the WRAPPER LINE at which that function is called, relative to the first forge step -- through
#     other library functions if need be (the wrapper calls `registry_env_read_contracts`, which calls
#     `contract_of`, whose reads therefore count from that wrapper line), and by the EARLIEST such call
#     when there are several (a read that happens before the compile is an input, whatever later call
#     re-reads it). A TOP-LEVEL library line runs when the wrapper sources the file, so its reads are
#     classified by the wrapper's source line (INPUT, since the wrapper sources before it compiles). A
#     library function the wrapper never calls, directly or transitively, has its reads listed as
#     `uncalled` by function name -- never silently dropped, never evaluated (the launch driver may be
#     its caller). Wrapper reads keep T-OP-112's rule: classified by their own line.
#   * every NULL_OK anchor and the EXTERNAL_KEYS anchor are looked up across the same union; a rule
#     whose anchor is in neither file fires `stale-condition`.
#   * write-back paths are lifted from EVERY function in the union whose node body writes `reg.v2.*` /
#     `m.v2.*`, and a variable key is resolved to the list its callers iterate -- through the node
#     arguments, the bash positional parameters and any number of bash call levels -- or rc=2 by name.
#
# CONDITIONAL READS ARE LISTED WITH THEIR CONDITION, NOT SKIPPED. Some inputs are null BY DESIGN at
# some phase (a fresh deploy has null `v2.contracts.*`; `shared.feeRecipient` is "whatever this run
# creates"; `v2.bots.*` may be null on a rehearsal, where anvil stand-ins are used). Each such rule
# below carries the WRAPPER-OR-LIBRARY LINE that makes null legal, as a literal anchor asserted at run
# time to match exactly one line across the union. If the anchor stops matching, the rule is DROPPED and
# reported as `stale-condition`, so an exception cannot outlive the code that justified it.
#
#   script/v2/check-deploy-inputs.sh --registry <tier1.json> [--sources <v2-sources.json>] \
#       [--mode broadcast|rehearse] [--recorded none|any|all] [--rpc <url>] [--no-checksum] \
#       [--wrapper <DeployV2Batch.sh>]
#
#   --recorded none   a FRESH launch: every recorded-set path (v2.contracts.*, v2.flywheel.*,
#                     v2.deployBlock) must still be null -- a value there means the wrapper will NOT
#                     deploy and will run a wiring check against whatever it names instead.
#   --recorded all    a resume/verify/register run: every recorded-set path must be non-null.
#   --recorded any    (default) either; the wrapper decides the phase.
#   script/v2/check-deploy-inputs.sh --self-test        # derived fixtures, then exit
#
# Exit 0 clean, 1 with every failure named (`REJECT <rule> <path>: ...`), 2 usage or a derivation that
# cannot run (a moved anchor is "cannot run", never "clean").
#
# WHAT THIS CANNOT SEE: a read the wrapper makes through a path that is not a `jq` literal on ONE line
# (a `jq` expression that spans lines, such as the pool fee/cardinality reads in market_row, is not
# lifted; `$1`-parameterised reads are expanded from their call sites, see expand_dynamic); a library
# sourced from inside a function or by a path that is not `"$ROOT/..."`; whether a non-null value is the
# RIGHT value (VerifyV8's job); the per-market override expressions that bind `--arg`/`--argjson`
# values (listed as derived, not evaluated).
#
# bash 3.2 compatible (macOS): no associative arrays; membership is grep over newline-delimited blobs.
# -------------------------------------------------------------------------------------------------
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
WRAPPER="$REPO/script/v2/DeployV2Batch.sh"
LIB_OVERRIDES=""   # newline-delimited `<rel>=<path>`, --self-test fixtures only
REGISTRY=""
SOURCES=""
ROLES="$REPO/script/v2/roles.v8.json"
MODE=broadcast
RPC=""
CHECKSUM=1
RECORDED=any
SELFTEST=0

die() { echo "check-deploy-inputs: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --registry) [ $# -ge 2 ] || die "--registry needs a path"; REGISTRY=$2; shift 2 ;;
    --registry=*) REGISTRY=${1#*=}; shift ;;
    --sources) [ $# -ge 2 ] || die "--sources needs a path"; SOURCES=$2; shift 2 ;;
    --sources=*) SOURCES=${1#*=}; shift ;;
    --roles) [ $# -ge 2 ] || die "--roles needs a path"; ROLES=$2; shift 2 ;;
    --wrapper) [ $# -ge 2 ] || die "--wrapper needs a path"; WRAPPER=$2; shift 2 ;;
    --wrapper=*) WRAPPER=${1#*=}; shift ;;
    --lib)
      # A scratch copy standing in for one sourced library, for the self-test's derived fixtures ONLY: on a
      # real run the library is whatever the wrapper sources, and an override would let the check scan a
      # file the deploy will not run.
      [ $# -ge 2 ] || die "--lib needs <rel>=<path>"
      [ "${CHECK_DEPLOY_INPUTS_SELFTEST:-0}" = 1 ] || die "--lib is accepted only for --self-test fixtures; a real run scans the library the wrapper sources"
      case "$2" in *=*) ;; *) die "--lib needs <rel>=<path> (the library's path as the wrapper sources it, then the scratch file)" ;; esac
      LIB_OVERRIDES="$LIB_OVERRIDES$2
"; shift 2 ;;
    --mode) [ $# -ge 2 ] || die "--mode needs broadcast|rehearse"; MODE=$2; shift 2 ;;
    --rpc) [ $# -ge 2 ] || die "--rpc needs a url"; RPC=$2; shift 2 ;;
    --no-checksum) CHECKSUM=0; shift ;;
    --recorded) [ $# -ge 2 ] || die "--recorded needs none|any|all"; RECORDED=$2; shift 2 ;;
    --self-test) SELFTEST=1; shift ;;
    -h | --help) sed -n '2,/^# ----/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
case "$MODE" in broadcast|rehearse) ;; *) die "--mode must be broadcast or rehearse, got '$MODE'" ;; esac
case "$RECORDED" in none|any|all) ;; *) die "--recorded must be none, any or all, got '$RECORDED'" ;; esac
command -v jq >/dev/null || die "jq is required"

FAIL=0
reject() { # <rule> <path> <message>
  echo "REJECT $1 $2: $3" >&2
  FAIL=1
}
is_addr() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }

# --- the wrapper side: the wrapper and every library it sources, as one unit ----------------------
# SCAN_FILES: one `<tag>|<path>|<wrapper line that sources it>` per line, the wrapper first (tag `w`,
# line 0), then each top-level `. "$ROOT/<rel>"` / `source "$ROOT/<rel>"` library in the order the
# wrapper sources them (tags `l1`, `l2`, ...). SCAN_RELS: `<tag>|<rel>` for the libraries. Both are
# derived from the wrapper's own source lines; no library is named in this file.
SCAN_FILES=""
SCAN_RELS=""
short() { # <path> -> the path relative to the repo, or the basename for a scratch file
  case "$1" in "$REPO"/*) printf '%s' "${1#"$REPO"/}" ;; *) printf '%s' "${1##*/}" ;; esac
}
file_of_tag() { printf '%s\n' "$SCAN_FILES" | awk -F'|' -v t="$1" '$1 == t {print $2; exit}'; }
rel_of_tag() { printf '%s\n' "$SCAN_RELS" | awk -F'|' -v t="$1" '$1 == t {print $2; exit}'; }
tag_of_file() { printf '%s\n' "$SCAN_FILES" | awk -F'|' -v f="$1" '$2 == f {print $1; exit}'; }

derive_scan_files() { # <wrapper>
  local w=$1 root n=0 line rel path override
  [ -f "$w" ] || die "wrapper not found: $w"
  # The wrapper does `cd "$(dirname "$0")/../.."; ROOT=$(pwd)`, so `$ROOT/<rel>` is <rel> under the
  # wrapper's own grandparent directory. Resolve it the same way, from the wrapper's location.
  root=$(cd "$(dirname "$w")/../.." 2>/dev/null && pwd) || die "cannot resolve the wrapper's repository root from $w"
  SCAN_FILES="w|$w|0
"
  SCAN_RELS=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    rel=$(printf '%s' "$line" | sed -E 's/^[0-9]+:[[:space:]]*(\.|source)[[:space:]]+"\$ROOT\/([^"]+)".*$/\2/')
    [ -n "$rel" ] && [ "$rel" != "$line" ] || die "cannot parse the wrapper's source line: $line"
    path="$root/$rel"
    override=$(printf '%s\n' "$LIB_OVERRIDES" | awk -F= -v r="$rel" '$1 == r {sub(/^[^=]*=/, ""); print; exit}')
    [ -z "$override" ] || path=$override
    [ -f "$path" ] || die "the wrapper sources \$ROOT/$rel (${w##*/} line ${line%%:*}) but $path does not exist; for a scratch wrapper outside the repo pass --lib $rel=<path> (self-test only)"
    SCAN_FILES="${SCAN_FILES}l$n|$path|${line%%:*}
"
    SCAN_RELS="${SCAN_RELS}l$n|$rel
"
  done <<SRC
$(grep -n -E '^[[:space:]]*(\.|source)[[:space:]]+"\$ROOT/[^"]+"' "$w" || true)
SRC
  # An override that names a library the wrapper does not source is a typo in the fixture, not a no-op.
  while IFS= read -r override; do
    [ -n "$override" ] || continue
    rel=${override%%=*}
    printf '%s\n' "$SCAN_RELS" | awk -F'|' -v r="$rel" '$2 == r {found=1} END {exit !found}' || die "--lib $rel=...: the wrapper does not source \$ROOT/$rel"
  done <<OV
$LIB_OVERRIDES
OV
}

# Count the lines matching <pattern> across the union; prints `<total>|<carrier tag or ->|<carrier path>`.
# <kind> is `regex` (grep -E) or `literal` (grep -F).
count_in_union() { # <kind> <pattern>
  local kind=$1 pat=$2 tag path n total=0 carrier=- cpath=-
  while IFS='|' read -r tag path _; do
    [ -n "$tag" ] || continue
    case "$kind" in
      literal) n=$(grep -cF -- "$pat" "$path" || true) ;;
      *) n=$(grep -cE -- "$pat" "$path" || true) ;;
    esac
    if [ "$n" != 0 ]; then total=$((total + n)); carrier=$tag; cpath=$path; fi
  done <<SF
$SCAN_FILES
SF
  printf '%s|%s|%s\n' "$total" "$carrier" "$cpath"
}

# Lift CONTRACT_KEYS / EXTERNAL_KEYS by line pattern (the same technique check-env-names.sh uses) so the
# `$1`-parameterised reads can be expanded from the same lists the wrapper iterates. Each anchor must
# occur exactly once ACROSS the wrapper and its sourced libraries; the carrying file is recorded.
ANCHOR_FILE_CONTRACT_KEYS=""; ANCHOR_FILE_EXTERNAL_KEYS=""; ANCHOR_FILE_WRITE_BACK=""; ANCHOR_FILE_JQR=""
lift_wrapper() { # <wrapper>
  local w=$1 n r anchor
  derive_scan_files "$w"
  for anchor in '^CONTRACT_KEYS=' '^EXTERNAL_KEYS=' '^write_back\(\)' '^jqr\(\)'; do
    r=$(count_in_union regex "$anchor"); n=${r%%|*}
    [ "$n" = 1 ] || die "expected exactly one line matching $anchor across ${w##*/} and its sourced libraries [$(printf '%s\n' "$SCAN_RELS" | awk -F'|' '{print $2}' | paste -sd' ' -)], found $n; the read list cannot be derived"
    case "$anchor" in
      '^CONTRACT_KEYS=') ANCHOR_FILE_CONTRACT_KEYS=${r##*|} ;;
      '^EXTERNAL_KEYS=') ANCHOR_FILE_EXTERNAL_KEYS=${r##*|} ;;
      '^write_back\(\)') ANCHOR_FILE_WRITE_BACK=${r##*|} ;;
      '^jqr\(\)') ANCHOR_FILE_JQR=${r##*|} ;;
    esac
  done
  eval "$(grep '^CONTRACT_KEYS=' "$ANCHOR_FILE_CONTRACT_KEYS")"
  eval "$(grep '^EXTERNAL_KEYS=' "$ANCHOR_FILE_EXTERNAL_KEYS")"
  [ -n "${CONTRACT_KEYS:-}" ] || die "CONTRACT_KEYS is empty after lifting it from $ANCHOR_FILE_CONTRACT_KEYS"
  [ -n "${EXTERNAL_KEYS:-}" ] || die "EXTERNAL_KEYS is empty after lifting it from $ANCHOR_FILE_EXTERNAL_KEYS"
  # The first forge STEP: the first `run_forge` invocation that writes a run log. Everything read before
  # this line is an input the check can refuse without a compile. The wrapper's, never a library's.
  FIRST_FORGE=$(grep -n 'run_forge[_a-z]* "\$LOGDIR/' "$w" | head -1 | cut -d: -f1)
  [ -n "$FIRST_FORGE" ] || die "no 'run_forge \"\$LOGDIR/...' invocation in $w: the input/post boundary cannot be derived"
  fn_graph "$w"
  derive_wallet_paths
}

# --- library functions -> the wrapper line that reaches them ---------------------------------------
# FN_EFF: one `<tag>|<function>|<effective wrapper line or uncalled>|<via>` per library function. The
# effective line is the EARLIEST wrapper line that calls the function, directly or through other
# library functions (fixpoint over the call graph of every scanned file); `via` names the route.
FN_EFF=""
fn_graph() { # <wrapper>
  local w=$1 tag path
  local files=()   # the libraries first, the wrapper last (paths quoted: an indexed array is bash 3.2)
  while IFS='|' read -r tag path _; do
    [ -n "$tag" ] && [ "$tag" != w ] && files+=("$path")
  done <<SF
$SCAN_FILES
SF
  FN_EFF=$(awk -v wrapper="$w" '
    function strip(s) { sub(/[[:space:]]+#.*$/, "", s); return s }   # a trailing comment is not a call
    function isdef(s) { return s ~ /^[a-z_][a-z_0-9]*\(\)[[:space:]]*\{/ }
    function oneliner(s) { return s ~ /^[a-z_][a-z_0-9]*\(\)[[:space:]]*\{.*\}[[:space:]]*$/ }
    function name(s) { sub(/\(\).*$/, "", s); return s }
    function word(fn) { return "(^|[^A-Za-z0-9_])" fn "([^A-Za-z0-9_]|$)" }
    # pass 1: library files (every file but the wrapper): function names, and which library functions each
    # function body references.
    FNR == 1 { infn = "" }
    FILENAME != wrapper {
      line = $0
      if (line ~ /^[[:space:]]*#/) next
      if (isdef(line)) { f = name(line); owner[f] = FILENAME; order[++nf] = f; if (!oneliner(line)) infn = f; body[f] = body[f] "\n" strip(line); next }
      if (line ~ /^\}/) { infn = ""; next }
      if (infn != "") body[infn] = body[infn] "\n" strip(line)
      next
    }
    # pass 2: the wrapper: the first non-comment code line referencing each library function.
    {
      line = strip($0)
      if (line ~ /^[[:space:]]*#/) next
      wl[FNR] = line
    }
    END {
      for (i = 1; i <= nf; i++) {
        f = order[i]
        for (n = 1; n <= FNR; n++) {
          if (!(n in wl)) continue
          if (isdef(wl[n]) && name(wl[n]) == f) continue
          if (wl[n] ~ word(f)) { eff[f] = n; via[f] = "called at wrapper:" n; break }
        }
      }
      # callers inside the libraries: G references F  ->  F is reached wherever G is.
      for (i = 1; i <= nf; i++) for (j = 1; j <= nf; j++) {
        g = order[i]; f = order[j]
        if (g == f) continue
        if (body[g] ~ word(f)) calls[g, f] = 1
      }
      do {
        changed = 0
        for (i = 1; i <= nf; i++) for (j = 1; j <= nf; j++) {
          g = order[i]; f = order[j]
          if (!((g, f) in calls) || !(g in eff)) continue
          if (!(f in eff) || eff[g] < eff[f]) { eff[f] = eff[g]; via[f] = "via " g " (" via[g] ")"; changed = 1 }
        }
      } while (changed)
      for (i = 1; i <= nf; i++) {
        f = order[i]
        if (f in eff) print owner[f] "|" f "|" eff[f] "|" via[f]
        else print owner[f] "|" f "|uncalled|no wrapper call site, directly or through another library function"
      }
    }' ${files[@]+"${files[@]}"} "$w")   # (the +-expansion keeps `set -u` quiet when no library is sourced)
  # owner is a path in the awk output; translate to the tag so lookups do not depend on path spelling.
  local out="" line
  while IFS='|' read -r path fn e v; do
    [ -n "$path" ] || continue
    tag=$(tag_of_file "$path")
    out="$out$tag|$fn|$e|$v
"
  done <<FE
$FN_EFF
FE
  FN_EFF=$out
}
fn_eff() { # <tag> <fn> -> "<eff>|<via>"
  printf '%s\n' "$FN_EFF" | awk -F'|' -v t="$1" -v f="$2" '$1 == t && $2 == f {print $3 "|" $4; exit}'
}
# The function enclosing <line> of <file>, or `-` for a top-level line (a definition line counts as its
# own function, so a one-line `jqr() { ... }` is "inside jqr").
fn_of() { # <file> <line>
  awk -v n="$2" '
    NR > n { exit }
    /^[a-z_][a-z_0-9]*\(\)[[:space:]]*\{/ { f = $0; sub(/\(\).*$/, "", f); infn = ($0 ~ /\}[[:space:]]*$/) ? "" : f; if (NR == n) { print f; exit }; next }
    /^\}/ { infn = "" }
    NR == n { print (infn != "" ? infn : "-") }' "$1"
}

# --- wallet paths: the registry addresses that are keys by design ------------------------------------
# Derived from the ONE place the projection names its principals: `registry_env_refuse_deployer_is_principal`
# (`for name in <paths>; do`, T-OP-161 (f)) in whichever scanned file defines it. Every name there is a
# principal the deployer must not be; the ones under `shared.safes.` are the two Safes (contracts) and keep
# has_code; the rest are keys. A missing function or an empty list is rc=2: the class cannot be derived, and
# a check that silently applied has_code to the guardian again is the launch-day stop this exists to remove.
WALLET_PATHS=""
derive_wallet_paths() {
  local tag path body names
  while IFS='|' read -r tag path _; do
    [ -n "$tag" ] || continue
    grep -q '^registry_env_refuse_deployer_is_principal()' "$path" || continue
    body=$(awk '/^registry_env_refuse_deployer_is_principal\(\)/{p=1} p{print} p&&/^\}/{exit}' "$path")
    # the list may span lines with a trailing backslash: join, then take the words between `for name in` and `; do`
    names=$(printf '%s\n' "$body" | sed -e ':a' -e '/\\$/N; s/\\\n//; ta' | grep -o 'for name in [^;]*; do' | head -1 | sed 's/^for name in //; s/; do$//')
    [ -n "$names" ] || die "registry_env_refuse_deployer_is_principal in $(short "$path") has no 'for name in <paths>; do' list; the wallet class cannot be derived"
    WALLET_PATHS=$(printf '%s\n' $names | grep -v '^shared\.safes\.' | sed 's/^/./')
    [ -n "$WALLET_PATHS" ] || die "the principal list in $(short "$path") names only Safes; the wallet class cannot be derived"
    return 0
  done <<SF
$SCAN_FILES
SF
  die "no scanned file defines registry_env_refuse_deployer_is_principal(); the wallet class (which registry addresses are keys by design) cannot be derived"
}
is_wallet_path() { printf '%s\n' "$WALLET_PATHS" | grep -qx -- "$1"; }

# Registry key -> the path the wrapper records it at (mirrors contract_of / write_back's two groups).
path_of_key() { # <key>
  case "$1" in
    flywheel.*) printf '.v2.flywheel.%s' "${1#flywheel.}" ;;
    sources.*) printf '.v2.contracts.sources.%s' "${1#sources.}" ;;
    *) printf '.v2.contracts.%s' "$1" ;;
  esac
}

# Every jq read in ONE file, one per line: <line>|<file-class>|<expr>
#   file-class: registry (jqr, "$STATE", "$REGISTRY"), sources ("$SOURCES"), roles ("$ROLES_JSON"),
#   row (<<<"$row"), other (anything else).
reads_of() { # <file>
  local w=$1
  # comments and the usage() text are not reads; strip leading-# lines first.
  grep -n '' "$w" | grep -v '^[0-9]*:[[:space:]]*#' | awk -F: '
    {
      n=$1; line=substr($0, length(n)+2)
      # every jqr '"'"'...'"'"' / jqr "..." / jq -r|-e|-c [--arg[json] k "v" ...] '"'"'...'"'"' occurrence on the line
      s=line
      while (match(s, /jqr [\x27"]|jq -(r|e|c) (--arg(json)? [^ ]+ "[^"]*" )*[\x27"]/)) {
        rest=substr(s, RSTART); q=substr(rest, RLENGTH, 1)
        body=substr(rest, RLENGTH+1)
        e=index(body, q); if (e==0) break
        expr=substr(body, 1, e-1); after=substr(body, e+1)
        if (expr == "$1") { s=after; continue }   # the jqr() definition itself, not a read
        cls="other"
        if (rest ~ /^jqr /) cls="registry"
        else if (after ~ /^ *"\$(STATE|REGISTRY)"/) cls="registry"
        else if (after ~ /^ *"\$SOURCES"/) cls="sources"
        else if (after ~ /^ *"\$ROLES_JSON"/) cls="roles"
        else if (after ~ /^ *<<<"\$row"/) cls="row"
        print n "|" cls "|" expr
        s=after
      }
      # the per-market reads that bind --argjson defaults: the OUTER expression is the last quoted
      # string before <<<"$row", and the scan above consumed the inner "$STATE" read first.
      if (line ~ /--argjson/ && match(line, /\x27[^\x27]*\x27 *<<<"\$row"/)) {
        e=substr(line, RSTART+1); sub(/\x27 *<<<"\$row".*/, "", e)
        print n "|row|" e
      }
    }'
}

# Every jq read across the union, one per line, with the line that CLASSIFIES it:
#   <tag>|<line>|<eff>|<cls>|<where>|<expr>      (expr last: a jq expression carries `|` itself)
# For a wrapper read, eff = its own line. For a library read inside a function, eff = the wrapper line
# that reaches that function (fn_graph), or `uncalled`. For a top-level library read, eff = the wrapper
# line that sources the library. <where> is the human form used in messages.
all_reads() {
  local tag path src fn e v r
  while IFS='|' read -r tag path src; do
    [ -n "$tag" ] || continue
    while IFS='|' read -r n cls expr; do
      [ -n "$n" ] || continue
      if [ "$tag" = w ]; then
        printf '%s|%s|%s|%s|%s|%s\n' "$tag" "$n" "$n" "$cls" "$(short "$path"):$n" "$expr"
        continue
      fi
      fn=$(fn_of "$path" "$n")
      if [ "$fn" = - ]; then
        printf '%s|%s|%s|%s|%s|%s\n' "$tag" "$n" "$src" "$cls" "$(short "$path"):$n (top level, sourced at wrapper:$src)" "$expr"
        continue
      fi
      r=$(fn_eff "$tag" "$fn"); e=${r%%|*}; v=${r#*|}
      [ -n "$e" ] || die "library function $fn (${path##*/}:$n) is missing from the call graph; fn_graph is broken, not the tree"
      printf '%s|%s|%s|%s|%s|%s\n' "$tag" "$n" "$e" "$cls" "$(short "$path"):$n ($fn, $v)" "$expr"
    done <<RD
$(reads_of "$path")
RD
  done <<SF
$SCAN_FILES
SF
}

# `$1`-parameterised reads (contract_of, bot): expand from the function'"'"'s call sites, which are the
# wrapper'"'"'s own loops over CONTRACT_KEYS/EXTERNAL_KEYS and the `bot <name>` calls wherever they live.
expand_dynamic() { # <file> <line> <expr>  -> prints one expr per expansion
  local w=$1 n=$2 expr=$3 fn k
  fn=$(fn_of "$w" "$n")
  case "$fn" in
    contract_of)
      for k in $CONTRACT_KEYS $EXTERNAL_KEYS; do
        case "$k" in flywheel.*) continue ;; esac   # the flywheel pair has its own literal cases
        printf '%s\n' "${expr//\$1/$k}"
      done ;;
    bot)
      # every `bot <name> ...` call site outside the definition, in any scanned file
      printf '%s\n' "$SCAN_FILES" | awk -F'|' 'NF {print $2}' | while IFS= read -r f; do grep -o '\$(bot [a-z]*' "$f" || true; done \
        | sed 's/^\$(bot //' | LC_ALL=C sort -u | while read -r k; do
        [ -n "$k" ] && printf '%s\n' "${expr//\$1/$k}"
      done ;;
    *) die "line $n of $(short "$w") reads a \$1-parameterised path inside '$fn', which this check does not know how to expand; teach expand_dynamic or make the read literal" ;;
  esac
}

# --- null-by-design rules --------------------------------------------------------------------------
# <path-regex>@@<mode: any|rehearse>@@<anchor: a LITERAL substring that must occur on exactly one line of the wrapper OR a sourced library; \x27 = a single quote>@@<why>
NULL_OK='
^\.shared\.feeRecipient@@any@@null|"") FEE_RECIPIENT="" ;;@@null = "whatever this run creates": shared.feeRecipient IS the FeeSplitter
^\.shared\.token\.poolKey\.currency0@@any@@if [ -n "$TOKEN_POOL_CURRENCY0" ] && [ "$TOKEN_POOL_CURRENCY0" != "0x0000000000000000000000000000000000000000" ]; then@@absent/zero = native ETH, the intended value; a non-zero currency0 is refused
^\.v2\.bots\.@@rehearse@@[ "$MODE" = rehearse ] || die "registry v2.bots.$1 is null or absent@@null on a rehearsal = anvil stand-in (#8/#9/#10); refused on --broadcast
^\.v2\.fees\.mintFeePpm@@any@@MINT_FEE_PPM=$(jq -r \x27.v2.fees.mintFeePpm // empty@@absent shared rate = every market must carry its own v2.mintFeePpm, refused per market by market_row
^\.v2\.registeredAt@@any@@reg=$(jq -r \x27.v2.registeredAt // ""\x27@@null = not registered yet; a registered market is skipped, not refused
^\.v2\.univ3Pool@@any@@pool=$(jq -r \x27.v2.univ3Pool // ""\x27@@null = Chainlink-only market (no pool, no payout route), by owner sign-off c10
^\.v2\.univ3MinLiquidity@@any@@pool=$(jq -r \x27.v2.univ3Pool // ""\x27@@null with a null pool = Chainlink-only; with a pool the wrapper refuses a missing floor by name
^\.v2\.status@@any@@status=$(jq -r \x27.v2.status // empty\x27@@enabled derives from (status == live); a planned market registers disabled
'
# EXTERNAL_KEYS: read for export, absent by design ("reach DeployV8 by environment").
EXT_ANCHOR='EXTERNAL_KEYS="'

null_ok_reason() { # <path> -> prints the reason if a live rule excuses null in this MODE, else nothing
  local p=$1 rule re m anchor why n
  printf '%s\n' "$NULL_OK" | while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    re=${rule%%@@*}; rule=${rule#*@@}; m=${rule%%@@*}; rule=${rule#*@@}; anchor=${rule%%@@*}; why=${rule#*@@}
    printf '%s' "$p" | grep -Eq "$re" || continue
    [ "$m" = any ] || [ "$m" = "$MODE" ] || continue
    anchor=$(printf '%s' "$anchor" | sed "s/\\\\x27/'/g")
    n=$(count_in_union literal "$anchor"); n=${n%%|*}
    if [ "$n" != 1 ]; then echo "STALE|$re|$anchor|$n"; continue; fi
    echo "OK|$why"; break
  done
}

# --- evaluation ------------------------------------------------------------------------------------
eval_path() { # <file> <expr> -> value ("" for null/empty/absent)
  jq -r "$2" "$1" 2>/dev/null || echo "__JQ_ERROR__"
}

checksum_ok() { # <addr> -> 0 if EIP-55 canonical (or checksum disabled)
  [ "$CHECKSUM" = 1 ] || return 0
  local want
  want=$(cast to-check-sum-address "$1" 2>/dev/null) || die "cast to-check-sum-address failed for $1; install foundry or pass --no-checksum (and say so in your evidence)"
  [ "$want" = "$1" ]
}

# THE RPC URL IS A SECRET-SHAPED STRING (T-OP-182, T-OP-199). The archive endpoint carries its API key in the
# PATH (`https://<host>/v2/<key>`), and the launch driver tees this script's every line into a run-dir log
# that outlives the shell. So no line here prints $RPC: it prints `rpc_host_of "$RPC"` -- scheme + host[:port]
# only, path, query, fragment and user:pass@ stripped -- mirrored from broadcast-v8.sh:108, whose --self-test
# proves the same function; --self-test here proves this copy on a keyed URL. The `--rpc-url` ARGUMENT to
# `cast` is the one place the raw URL is still handed on (ps can see it for the call's duration; accepted).
rpc_host_of() {
  local url=$1 scheme="" rest hostport
  case "$url" in *://*) scheme=${url%%://*}; rest=${url#*://} ;; *) rest=$url ;; esac
  hostport=${rest%%/*}; hostport=${hostport%%\?*}; hostport=${hostport%%\#*}; hostport=${hostport##*@}
  if [ -n "$scheme" ]; then printf '%s://%s\n' "$scheme" "$hostport"; else printf '%s\n' "$hostport"; fi
}
RPC_HOST=$(rpc_host_of "$RPC")

has_code() { # <addr> -> 0 if code present
  local code
  code=$(cast code "$1" --rpc-url "$RPC" 2>/dev/null) || die "cast code $1 failed against $RPC_HOST"
  [ -n "$code" ] && [ "$code" != "0x" ]
}

# A recorded address (v2.contracts.*, v2.flywheel.*) that is present is a contract the run will WIRE AGAINST or
# resume from: EIP-55 and, with --rpc, code -- the same rules as any other contract address (T-OP-187: the
# recorded set used to be printed "ok (recorded)" unchecked).
recorded_addr_ok() { # <class> <path> <value>
  local cls=$1 path=$2 v=$3
  if is_addr "$v"; then
    if ! checksum_ok "$v"; then reject checksum "$path" "'$v' is not EIP-55 canonical (recorded); write the checksummed form so a typo is visible"; return; fi
    if [ -n "$RPC" ] && ! has_code "$v"; then reject no-code "$path" "'$v' holds no code on $RPC_HOST (recorded: the wrapper would wire against or resume from nothing)"; return; fi
  fi
  printf '%-10s ok       %s = %s (recorded)\n' "$cls" "$path" "$v"
}

check_input() { # <class> <file> <expr> <label-path> [<ticker>]
  local cls=$1 file=$2 expr=$3 path=$4 tk=${5:-} v r
  v=$(eval_path "$file" "$expr")
  if [ "$v" = "__JQ_ERROR__" ]; then reject jq-error "$path" "jq could not evaluate '$expr' against ${file##*/}${tk:+ ($tk)}"; return; fi
  # The recorded set (what the wrapper writes back) is read before the first forge step to DECIDE the
  # phase; whether null is right depends on the run, which --recorded states.
  if printf '%s\n' "$WB_ADDR_PATHS" | grep -qx "$path"; then
    case "$RECORDED" in
      none) if [ -n "$v" ] && [ "$v" != null ]; then reject stale-writeback "$path" "is '$v' but --recorded none was given: a fresh launch must start from a registry with no recorded set, or the wrapper will not deploy (DEPLOY_PHASE=check/resume) and will wire against whatever this names"; else printf '%-10s null-ok  %s  (recorded set, --recorded none: null = fresh deploy)\n' "$cls" "$path"; fi ;;
      all) if [ -z "$v" ] || [ "$v" = null ]; then reject null-input "$path" "is null but --recorded all was given: a resume/verify/register run needs every recorded address (read at ${LINE_OF:-?})"; else recorded_addr_ok "$cls" "$path" "$v"; fi ;;
      any) if [ -z "$v" ] || [ "$v" = null ]; then printf '%-10s null-ok  %s  (recorded set, --recorded any: null = fresh deploy, the wrapper decides the phase)\n' "$cls" "$path"; else recorded_addr_ok "$cls" "$path" "$v"; fi ;;
    esac
    return
  fi
  if [ -z "$v" ] || [ "$v" = null ]; then
    r=$(null_ok_reason "$path")
    case "$r" in
      OK\|*) printf '%-10s null-ok  %s%s  (%s)\n' "$cls" "$path" "${tk:+ [$tk]}" "${r#OK|}" ;;
      STALE\|*) reject stale-condition "$path" "null, and the rule that excused it points at a wrapper-or-library line that no longer matches exactly once across the scanned files (${r#STALE|}); re-derive the condition" ;;
      *) reject null-input "$path" "is null or absent in ${file##*/}${tk:+ for $tk}, and the wrapper reads it before any forge step (read at ${LINE_OF:-?})" ;;
    esac
    return
  fi
  if is_addr "$v"; then
    if ! checksum_ok "$v"; then reject checksum "$path" "'$v' is not EIP-55 canonical${tk:+ ($tk)}; write the checksummed form so a typo is visible"; return; fi
    if is_wallet_path "$path"; then
      # a key by design (T-OP-187): EIP-55 and non-null were just checked; code is NOT expected, so has_code
      # is not asked. Said in the line, so a reader sees which class excused it.
      printf '%-10s ok       %s%s = %s  (WALLET: a key by design, no code expected)\n' "$cls" "$path" "${tk:+ [$tk]}" "$v"
      return
    fi
    if [ -n "$RPC" ] && [ "$v" != "0x0000000000000000000000000000000000000000" ] && ! has_code "$v"; then reject no-code "$path" "'$v' holds no code on $RPC_HOST${tk:+ ($tk)}"; return; fi
  fi
  printf '%-10s ok       %s%s = %s\n' "$cls" "$path" "${tk:+ [$tk]}" "$(printf '%s' "$v" | tr '\n' ' ' | cut -c1-72)"
}

# The dotted path a jq expression reads (first path segment chain), for labels and rule matching.
label_of() { printf '%s' "$1" | sed -E 's/^ *//; s/ *\/\/.*$//; s/ *\| .*$//; s/ *$//' | cut -c1-80; }

# --- write-back paths, derived from every registry writer in the scanned files ---------------------
# Every path the wrapper OR a sourced library writes into the registry, one per line, derived by SHAPE
# from the `node -e` bodies of every function in the union (T-OP-112 lifted write_back() alone; T-OP-137
# generalised it because T-OP-116 records the six externals from a LIBRARY function,
# registry_env_record_external(), and a writer this check does not scan is a key the skeleton may lack):
#   reg.v2.<path> = ...                        a literal path                     -> .v2.<path>
#   m.v2.<leaf> = ...                          a per-market path                  -> markets[].v2.<leaf>
#   reg.v2.<group>[<jsvar>] = ...              a variable-keyed group; the key SET is derived from the
#   put(<obj>, <jsvar>, ..., `v2.<group>.${<jsvar>}`)   function (and `kind === "..."` branch) that writes it:
#     * `Object.entries({ a, b, c })` in the branch      -> those names (the bots);
#     * the deploy JSON (`Object.keys(got...)`)          -> CONTRACT_KEYS in its two groups (the recorded
#                                                           set; mined_addresses walks the same JSON);
#     * <jsvar> destructured from the node arguments
#       (`const [.., <jsvar>, ..] = a` after write_back's
#       `[file, kind, ...a]`, or `= process.argv.slice(1)`) -> the bash token at that position of the
#                                                           `node -e '...' <args>` call; a `$<name>` there is
#                                                           the nearest enclosing `for <name> in $<LIST>`
#                                                           loop, and a positional `$<n>` is followed to
#                                                           every caller of the function (through any
#                                                           number of bash functions) until a loop is
#                                                           found. <LIST> must be assigned exactly once
#                                                           at column 0 in a scanned file as a plain word
#                                                           list (CONTRACT_KEYS, EXTERNAL_KEYS,
#                                                           EXTERNAL_DEPLOY_ORDER, ...), lifted by name.
# A write whose key set cannot be derived by one of those routes is rc=2 BY NAME -- a write-back path
# this check cannot see is the post-broadcast latent it exists to refuse, so it refuses to run rather
# than report "every write-back key homed" over a key it never checked.

# The non-comment code lines of <file>, numbered, that call <fn> (word-boundary; not its definition).
call_sites_of() { # <fn> -> <file>|<line>|<text> per call site, across the union
  local fn=$1 f
  printf '%s\n' "$SCAN_FILES" | awk -F'|' 'NF {print $2}' | while IFS= read -r f; do
    grep -n -E "(^|[^A-Za-z0-9_])$fn([^A-Za-z0-9_]|$)" "$f" | grep -v -E '^[0-9]+:[[:space:]]*#' | grep -v -E "^[0-9]+:$fn\(\)" \
      | sed -E 's/[[:space:]]+#.*$//' | awk -v f="$f" -F: '{ n=$1; sub(/^[0-9]+:/, ""); print f "|" n "|" $0 }'
  done
}
# The <pos>-th shell word after `<fn>` on <text> (quotes stripped): `$k`, `$1`, a literal, or nothing.
arg_at() { # <fn> <pos> <text>
  printf '%s\n' "$3" | sed -E "s/.*(^|[^A-Za-z0-9_])$1[[:space:]]+//" | awk -v i="$2" '{gsub(/"/, ""); print $i}'
}
# The value of `^<LIST>=` lifted from the union: exactly one column-0 assignment of a plain word list.
lift_list() { # <LIST> -> its words
  local r n f v
  r=$(count_in_union regex "^$1="); n=${r%%|*}; f=${r##*|}
  [ "$n" = 1 ] || die "expected exactly one column-0 assignment of $1 across the scanned files, found $n; the key set it feeds cannot be derived"
  v=$(grep -E "^$1=" "$f" | head -1 | sed -E "s/^$1=//; s/^\"//; s/\"[[:space:]]*(#.*)?$//")
  case "$v" in *'$'*|*'`'*|*'('*) die "$1 in $(short "$f") is not a plain word list ($v); the key set it feeds cannot be derived" ;; esac
  [ -n "$v" ] || die "$1 in $(short "$f") is empty"
  printf '%s\n' $v
}
# Resolve argument <pos> of bash function <fn> (defined in <file>) to the list its callers iterate: prints
# one LIST name per call site. A `$<name>` argument must sit under a `for <name> in $<LIST>` loop in the
# caller's file; a positional `$<n>` is resolved through the caller's own callers. <depth> bounds recursion.
resolve_arg() { # <file> <fn> <pos> <depth> -> LIST names
  local file=$1 fn=$2 pos=$3 depth=$4 sites site cf ln text tok var cfn list
  [ "$depth" -le 8 ] || die "resolving argument $pos of $fn: more than 8 call levels; the key set cannot be derived"
  sites=$(call_sites_of "$fn")
  [ -n "$sites" ] || die "$fn (defined in $(short "$file")) is called from no scanned file, so argument $pos -- a registry write-back key -- cannot be derived"
  while IFS='|' read -r cf ln text; do
    [ -n "$cf" ] || continue
    tok=$(arg_at "$fn" "$pos" "$text")
    # a bare identifier at the call site IS a key (`externals_landed houseVaultFactory "$addr" ...`, T-OP-116)
    if [[ "$tok" =~ ^[A-Za-z_][A-Za-z_0-9.]*$ ]]; then printf 'LITERAL:%s\n' "$tok"; continue; fi
    var=$(printf '%s' "$tok" | sed -E 's/^\$\{?([A-Za-z_0-9]+)\}?$/\1/')
    [ -n "$var" ] && [ "$var" != "$tok" ] || die "$(short "$cf"):$ln calls $fn with argument $pos '$tok', which is neither a \$variable nor a bare key; the key set it carries cannot be derived"
    if [[ "$var" =~ ^[0-9]+$ ]]; then
      cfn=$(fn_of "$cf" "$ln")
      [ "$cfn" != - ] || die "$(short "$cf"):$ln passes \$$var to $fn outside any function; the key set cannot be derived"
      resolve_arg "$cf" "$cfn" "$var" $((depth + 1))
    else
      list=$(loop_list_above "$cf" "$ln" "$var")
      [ -n "$list" ] || die "$(short "$cf"):$ln calls $fn \"\$$var\" outside a 'for $var in \$<LIST>' loop in the same function; the key set it carries cannot be derived"
      printf '%s\n' "$list"
    fi
  done <<SITES
$sites
SITES
}
# The nearest `for <var> in $<LIST>` above line <line> of <file> INSIDE the same function (or, at top level,
# anywhere above); prints LIST or nothing.
loop_list_above() { # <file> <line> <var>
  local fn start=1
  fn=$(fn_of "$1" "$2")
  [ "$fn" = - ] || start=$(awk -v f="$fn" '$0 ~ ("^" f "\\(\\)[[:space:]]*\\{") { print NR; exit }' "$1")
  awk -v n="$2" -v s="$start" -v v="$3" 'NR >= s && NR < n && $0 ~ ("for +" v " +in +\\$[A-Z_]+") { m = $0; sub(".*for +" v " +in +\\$", "", m); sub(/[^A-Z_].*$/, "", m); last = m } END { print last }' "$1"
}

# `LIST` names and `LITERAL:key` markers (resolve_arg's output) -> the key words, each list lifted by name.
keys_of_lists() { # <lines>
  local l words
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    case "$l" in LITERAL:*) printf '%s\n' "${l#LITERAL:}" ;; *) words=$(lift_list "$l") || exit $?; printf '%s\n' "$words" ;; esac
  done <<LL
$1
LL
}

derive_write_back() { # -> every write-back path, one per line
  local tag file fn body targets kind type path jsvar names domain idx list lists k pk argtok pos tokens branch destr
  while IFS='|' read -r tag file _; do
    [ -n "$tag" ] || continue
    # every function in the file, with its body (definition line to the closing brace at column 0)
    for fn in $(awk '/^[a-z_][a-z_0-9]*\(\)[[:space:]]*\{/ { f = $0; sub(/\(\).*$/, "", f); print f }' "$file"); do
      body=$(awk -v f="$fn" '$0 ~ ("^" f "\\(\\)[[:space:]]*\\{") { p = 1 } p { print } p && /^\}/ { exit }' "$file")
      printf '%s\n' "$body" | grep -q 'reg\.v2\.\|m\.v2\.\|`v2\.' || continue
      # every write target, tagged with the `kind === "..."` branch it sits in: <kind>|<type>|<path>|<jsvar>
      targets=$(printf '%s\n' "$body" | awk '
        { line = $0; sub(/^[[:space:]]*\/\/.*$/, "", line) }
        match(line, /kind === "[a-z]+"/) { kind = substr(line, RSTART + 10, RLENGTH - 11) }
        {
          s = line
          while (match(s, /reg\.v2\.[A-Za-z_][A-Za-z_.]*(\[[A-Za-z_]+\])? *=[^=]/)) {
            t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
            sub(/ *=[^=]$/, "", t); sub(/^reg\.v2\./, "", t)
            if (t ~ /\[/) { v = t; sub(/^.*\[/, "", v); sub(/\]$/, "", v); sub(/\[.*$/, "", t); print (kind ? kind : "-") "|var|" t "|" v }
            else print (kind ? kind : "-") "|literal|" t "|-"
          }
          s = line
          while (match(s, /`v2\.[A-Za-z_][A-Za-z_.]*\.\$\{[A-Za-z_]+\}`/)) {
            t = substr(s, RSTART + 4, RLENGTH - 5); s = substr(s, RSTART + RLENGTH)
            v = t; sub(/^.*\.\$\{/, "", v); sub(/\}$/, "", v); sub(/\.\$\{.*$/, "", t)
            print (kind ? kind : "-") "|var|" t "|" v
          }
          s = line
          while (match(s, /m\.v2\.[A-Za-z_]+ *=[^=]/)) {
            t = substr(s, RSTART + 5, RLENGTH - 5); s = substr(s, RSTART + RLENGTH)
            sub(/ *=[^=]$/, "", t); print (kind ? kind : "-") "|market|" t "|-"
          }
        }' | LC_ALL=C sort -u)
      [ -n "$targets" ] || continue
      # a literal path whose parent is created inline (`if (!reg.v2.x) reg.v2.x = {}`) is not a key the
      # skeleton must carry: drop `<group>` when the same function writes `<group>[...]` or `<group>.<leaf>`
      while IFS='|' read -r kind type path jsvar; do
        [ -n "$kind" ] || continue
        case "$type" in
          literal)
            # `if (!reg.v2.x) reg.v2.x = {}` beside `reg.v2.x[key] = ...` creates the group inline: the group's
            # KEYS are what the skeleton must carry (derived below), not the group object itself.
            if printf '%s\n' "$targets" | grep -q -F "|var|$path|"; then continue; fi
            printf '.v2.%s\n' "$path" ;;
          market) printf 'markets[].v2.%s\n' "$path" ;;
          var)
            branch=$(printf '%s\n' "$body" | awk -v k="$kind" '
              match($0, /kind === "[a-z]+"/) { cur = substr($0, RSTART + 10, RLENGTH - 11) }
              k == "-" || cur == k { print }')
            names=$(printf '%s\n' "$branch" | grep -o 'Object\.entries({ [a-z, ]* })' | head -1 | sed 's/Object\.entries({ //; s/ })//; s/,//g')
            if [ -n "$names" ]; then
              domain=$names
            elif printf '%s\n' "$branch" | grep -q 'Object\.keys(got'; then
              domain=""
              for k in $CONTRACT_KEYS; do
                pk=$(path_of_key "$k"); [ "${pk%.*}" = ".v2.$path" ] && domain="$domain ${k##*.}"
              done
              [ -n "$domain" ] || die "$fn ($kind) records v2.$path.\${$jsvar} from the deploy JSON, but no CONTRACT_KEYS entry is recorded under v2.$path (path_of_key); the key set cannot be derived"
            else
              # <jsvar> from the node arguments: its position in the destructure, then the bash token there
              destr=$(printf '%s\n' "$branch" | grep -o -E 'const \[[a-zA-Z_, ]*\] = a' | head -1)
              [ -n "$destr" ] || destr=$(printf '%s\n' "$body" | grep -o -E 'const \[[a-zA-Z_., ]*\] = process\.argv\.slice\(1\)' | head -1)
              idx=$(printf '%s\n' "$destr" | sed -E 's/const \[//; s/\] = .*//' | tr ',' '\n' | sed 's/^ *//; s/ *$//; s/^\.\.\.//' | grep -n -x "$jsvar" | cut -d: -f1)
              [ -n "$idx" ] || die "$fn ($kind) writes v2.$path[$jsvar] but $jsvar is neither an Object.entries name, a deploy-JSON key nor a node argument; the key set cannot be derived"
              # the shell words after the closing quote of `node -e '...'`
              tokens=$(printf '%s\n' "$body" | grep -E "^[[:space:]]*' " | head -1 | sed -E "s/^[[:space:]]*' //; s/ *(\|\||&&|>|2>).*$//")
              [ -n "$tokens" ] || die "$fn: cannot find the shell arguments after its node -e '...' body (expected a line starting with a closing quote); the key set for v2.$path cannot be derived"
              case "$destr" in
                *'= a')
                  # write_back's shape: `[file, kind, ...a] = process.argv.slice(1)` and `'... "$WRITE_TARGET" "$@"`:
                  # a[idx-1] is positional idx+1 of the bash function, and the branch's kind is positional 1.
                  printf '%s' "$tokens" | grep -q '"\$@"' || die "$fn destructures from a but its node call does not pass \"\$@\"; the key set for v2.$path cannot be derived"
                  pos=$((idx + 1))
                  lists=$(resolve_arg_kind "$file" "$fn" "$pos" "$kind") || exit $?
                  domain=$(keys_of_lists "$lists") || exit $? ;;
                *)
                  argtok=$(printf '%s\n' "$tokens" | awk -v i="$idx" '{gsub(/"/, ""); print $i}')
                  case "$argtok" in
                    '$'[0-9]*) pos=${argtok#\$}; lists=$(resolve_arg "$file" "$fn" "$pos" 1) || exit $?; domain=$(keys_of_lists "$lists") || exit $? ;;
                    '$'*) list=$(printf '%s\n' "$body" | awk -v v="${argtok#\$}" '$0 ~ ("for +" v " +in +\\$[A-Z_]+") { m = $0; sub(".*for +" v " +in +\\$", "", m); sub(/[^A-Z_].*$/, "", m); last = m } END { print last }')
                          [ -n "$list" ] || die "$fn passes $argtok to node for v2.$path[$jsvar] but no 'for ${argtok#\$} in \$<LIST>' loop in the function feeds it; the key set cannot be derived"
                          domain=$(lift_list "$list") || exit $? ;;
                    *) die "$fn passes '$argtok' to node at position $idx for v2.$path[$jsvar], which is not a \$variable; the key set cannot be derived" ;;
                  esac ;;
              esac
            fi
            for k in $domain; do
              case "$k" in flywheel.*|sources.*) printf '.v2.%s.%s\n' "$path" "${k##*.}" ;; *) printf '.v2.%s.%s\n' "$path" "$k" ;; esac
            done ;;
        esac
      done <<TG
$targets
TG
    done
  done <<SF
$SCAN_FILES
SF
}
# write_back's kind-dispatched shape: only the call sites whose first argument is the branch's kind literal
# carry this branch's keys. Prints LIST names like resolve_arg.
resolve_arg_kind() { # <file> <fn> <pos> <kind>
  local file=$1 fn=$2 pos=$3 kind=$4 sites cf ln text tok var cfn
  sites=$(call_sites_of "$fn" | awk -F'|' -v fn="$fn" -v k="$kind" '{ t = $3; sub(".*" fn "[[:space:]]+", "", t); split(t, w, " "); if (w[1] == k) print }')
  [ -n "$sites" ] || die "$fn ($kind) writes a variable-keyed path from its arguments, but no scanned file calls $fn $kind; the key set cannot be derived"
  while IFS='|' read -r cf ln text; do
    [ -n "$cf" ] || continue
    tok=$(arg_at "$fn" "$pos" "$text")
    if [[ "$tok" =~ ^[A-Za-z_][A-Za-z_0-9.]*$ ]]; then printf 'LITERAL:%s\n' "$tok"; continue; fi
    var=$(printf '%s' "$tok" | sed -E 's/^\$\{?([A-Za-z_0-9]+)\}?$/\1/')
    [ -n "$var" ] && [ "$var" != "$tok" ] || die "$(short "$cf"):$ln calls $fn $kind with argument $((pos - 1)) '$tok', which is neither a \$variable nor a bare key; the key set it carries cannot be derived"
    if [[ "$var" =~ ^[0-9]+$ ]]; then
      cfn=$(fn_of "$cf" "$ln"); [ "$cfn" != - ] || die "$(short "$cf"):$ln passes \$$var to $fn outside any function; the key set cannot be derived"
      resolve_arg "$cf" "$cfn" "$var" 2
    else
      list=$(loop_list_above "$cf" "$ln" "$var")
      [ -n "$list" ] || die "$(short "$cf"):$ln calls $fn $kind \"\$$var\" outside a 'for $var in \$<LIST>' loop in the same function; the key set it carries cannot be derived"
      printf '%s\n' "$list"
    fi
  done <<SITES
$sites
SITES
}

run_check() {
  local w=$WRAPPER reads tag n eff cls expr where path k ex v st tks tk missing libs
  lift_wrapper "$w"
  WB_ADDR_PATHS=""
  for k in $CONTRACT_KEYS; do WB_ADDR_PATHS="$WB_ADDR_PATHS$(path_of_key "$k")
"; done
  WB_ADDR_PATHS="$WB_ADDR_PATHS.v2.deployBlock"
  [ -n "$REGISTRY" ] || die "--registry is required"
  [ -f "$REGISTRY" ] || die "registry not found: $REGISTRY"
  [ -n "$SOURCES" ] || SOURCES="$(dirname "$REGISTRY")/v2-sources.json"
  [ -f "$SOURCES" ] || die "v2-sources.json not found: $SOURCES (the wrapper reads it beside the registry, or via --sources)"
  [ -f "$ROLES" ] || die "role manifest not found: $ROLES"
  jq -e . "$REGISTRY" >/dev/null 2>&1 || die "$REGISTRY is not JSON"
  jq -e . "$SOURCES" >/dev/null 2>&1 || die "$SOURCES is not JSON"
  libs=$(printf '%s\n' "$SCAN_FILES" | awk -F'|' -v repo="$REPO/" '$1 != "w" && $1 != "" {p=$2; sub("^" repo, "", p); printf "%s%s (sourced at wrapper:%s)", (n++ ? ", " : ""), p, $3}')
  echo "check-deploy-inputs: wrapper $(short "$w") (first forge step at line $FIRST_FORGE) + sourced ${libs:-no library}; anchors: CONTRACT_KEYS in $(short "$ANCHOR_FILE_CONTRACT_KEYS"), EXTERNAL_KEYS in $(short "$ANCHOR_FILE_EXTERNAL_KEYS"), write_back() in $(short "$ANCHOR_FILE_WRITE_BACK"), jqr() in $(short "$ANCHOR_FILE_JQR"); registry $REGISTRY, sources $SOURCES, mode $MODE${RPC:+, code checks against $RPC_HOST}${CHECKSUM:+}$([ "$CHECKSUM" = 1 ] || printf ', EIP-55 NOT checked')"
  echo "check-deploy-inputs: wallet paths (keys by design, has_code not applied): $(printf '%s\n' "$WALLET_PATHS" | paste -sd' ' -)"
  # Every library function the wrapper never reaches, by name, whether or not it reads anything: said once.
  printf '%s\n' "$FN_EFF" | awk -F'|' '$3 == "uncalled" {print $1 "|" $2}' | while IFS='|' read -r tag k; do
    [ -n "$tag" ] || continue
    printf '%-10s %s in %s: no wrapper call site, directly or through another library function (its reads are listed as uncalled, not evaluated)\n' UNCALLED "$k" "$(short "$(file_of_tag "$tag")")"
  done

  reads=$(all_reads) || exit $?
  [ -n "$reads" ] || die "no jq read was found in $w or its sourced libraries: the read scan is broken, not the tree"
  local n_in=0 n_row=0 n_post=0 n_other=0 n_lib=0 n_uncalled=0
  tks=$(jq -r '.markets[].ticker' "$REGISTRY")

  while IFS='|' read -r tag n eff cls where expr; do
    [ -n "$tag" ] || continue
    LINE_OF=$where
    [ "$tag" = w ] || n_lib=$((n_lib + 1))
    if [ "$eff" = uncalled ]; then
      n_uncalled=$((n_uncalled + 1)); printf '%-10s listed   %s: %s\n' UNCALLED "$where" "$(printf '%s' "$expr" | cut -c1-70)"; continue
    fi
    case "$cls" in
      other)
        n_other=$((n_other + 1)); printf '%-10s listed   %s: %s\n' OTHER "$where" "$(printf '%s' "$expr" | cut -c1-70)"; continue ;;
      roles)
        if [ "$eff" -ge "$FIRST_FORGE" ]; then n_post=$((n_post + 1)); printf '%-10s listed   %s (roles): %s\n' POST "$where" "$(printf '%s' "$expr" | cut -c1-70)"; continue; fi
        case "$expr" in *'$'*) printf '%-10s derived  %s: %s  (binds --arg values; listed, not evaluated)\n' ROLES "$where" "$(printf '%s' "$expr" | cut -c1-60)"; continue ;; esac
        v=$(eval_path "$ROLES" "$expr"); path=$(label_of "$expr")
        if [ -z "$v" ] || [ "$v" = null ] || [ "$v" = "__JQ_ERROR__" ]; then reject null-input "$path" "is null or absent in ${ROLES##*/} ($where reads the role manifest before any forge step)"; else printf '%-10s ok       %s = %s\n' ROLES "$path" "$v"; fi
        continue ;;
    esac
    if [ "$eff" -ge "$FIRST_FORGE" ]; then
      n_post=$((n_post + 1)); printf '%-10s listed   %s (%s): %s\n' POST "$where" "$cls" "$(printf '%s' "$expr" | cut -c1-70)"; continue
    fi
    case "$cls" in
      row)
        n_row=$((n_row + 1))
        case "$expr" in
          *'$'*) printf '%-10s derived  %s: %s  (binds --arg/--argjson values; listed, not evaluated)\n' MARKET "$where" "$(printf '%s' "$expr" | cut -c1-60)"; continue ;;
        esac
        path=$(label_of "$expr")
        for tk in $tks; do
          jq -c --arg t "$tk" '.markets[] | select(.ticker == $t)' "$REGISTRY" > "$TMPROW"
          check_input MARKET "$TMPROW" "$expr" "$path" "$tk"
        done ;;
      registry|sources)
        n_in=$((n_in + 1))
        [ "$cls" = registry ] && file=$REGISTRY || file=$SOURCES
        case "$expr" in
          *'$1'*)
            # NOT a pipe into `while`: that runs check_input in a subshell and loses FAIL, which is a
            # refusal printed and then ignored -- the exact false green this file exists to refuse.
            local expansions; expansions=$(expand_dynamic "$(file_of_tag "$tag")" "$n" "$expr") || exit $?
            while IFS= read -r ex; do
              [ -n "$ex" ] || continue
              path=$(label_of "$ex")
              # EXTERNAL_KEYS reads: absent by design, and the skeleton has no key for them.
              k=${path#.v2.contracts.}
              if printf '%s\n' $EXTERNAL_KEYS | grep -qx "$k"; then
                r=$(count_in_union literal "$EXT_ANCHOR")
                if [ "${r%%|*}" = 1 ]; then
                  if jq -e ".v2.contracts | has(\"$k\")" "$file" >/dev/null 2>&1; then
                    printf '%-10s null-ok  %s  (EXTERNAL_KEYS: deployed by its own task, reaches DeployV8 by environment; absent = "not supplied")\n' INPUT "$path"
                  else
                    # Absent by design AND unhomed: the skeleton has no key, so a value can never be supplied
                    # through the registry -- only through the environment. Said, not failed.
                    printf '%-10s unhomed  %s  (EXTERNAL_KEYS, absent = "not supplied" -- and the registry skeleton has NO such key, so this contract can only ever reach DeployV8 through the environment, never the registry)\n' INPUT "$path"
                  fi
                else reject stale-condition "$path" "EXTERNAL_KEYS anchor no longer matches exactly once across the wrapper and its sourced libraries (found ${r%%|*})"; fi
                continue
              fi
              check_input INPUT "$file" "$ex" "$path"
            done <<EXPANSIONS
$expansions
EXPANSIONS
            ;;
          *'$'*) printf '%-10s derived  %s: %s  (shell-parameterised; listed, not evaluated)\n' INPUT "$where" "$(printf '%s' "$expr" | cut -c1-60)" ;;
          *)
            case "$expr" in
              '('*) # jq -e shape assertions: must hold
                if jq -e "$expr" "$file" >/dev/null 2>&1; then printf '%-10s ok       shape: %s\n' INPUT "$(printf '%s' "$expr" | cut -c1-70)"; else reject shape "$(printf '%s' "$expr" | cut -c1-60)" "does not hold for ${file##*/} ($where)"; fi ;;
              *) check_input INPUT "$file" "$expr" "$(label_of "$expr")" ;;
            esac ;;
        esac ;;
    esac
  done <<READS
$reads
READS

  # --- write-back keys must exist in the skeleton ---------------------------------------------------
  # Derived from every registry writer in the scanned files, by shape: see derive_write_back.
  # (a die inside a command substitution exits only the subshell: every derivation is captured with its
  #  exit code and propagated, or a refusal would be printed and then ignored -- the false green this
  #  file exists to refuse)
  local wb
  wb=$(derive_write_back) || exit $?
  wb=$(printf '%s\n' "$wb" | LC_ALL=C sort -u)
  [ -n "$wb" ] || die "no registry write-back path was derived from any scanned file; the write-back scan is broken, not the tree"
  local n_wb=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    n_wb=$((n_wb + 1))
    case "$path" in
      'markets[].v2.'*)
        k=${path#markets[].v2.}
        missing=$(jq -r --arg k "$k" '[.markets[] | select((.v2 | has($k)) | not) | .ticker] | join(",")' "$REGISTRY")
        if [ -n "$missing" ]; then reject missing-writeback-key "$path" "the registry rows for $missing have no '$k' key; the post-register write-back adds one and the builder's exactKeys refuses it"; else printf '%-10s ok       %s (every market row has the key)\n' WRITE-BACK "$path"; fi ;;
      *)
        # parent must be an object that HAS the leaf key (null is fine)
        local parent leaf
        leaf=${path##*.}; parent=${path%.*}
        if jq -e "$parent | type == \"object\" and has(\"$leaf\")" "$REGISTRY" >/dev/null 2>&1; then
          printf '%-10s ok       %s (key present, %s)\n' WRITE-BACK "$path" "$(jq -r "$path // \"null\"" "$REGISTRY" | cut -c1-42)"
        else
          reject missing-writeback-key "$path" "the registry skeleton has no such key; the wrapper writes it back after the deploy and the builder's exactKeys then refuses the registry (post-broadcast latent)"
        fi ;;
    esac
  done <<WB
$wb
WB

  # The derived counts are printed on BOTH outcomes: a refusal that hides how much was scanned would
  # hide the one number that says whether the scan saw the library at all.
  local counts="$n_in input read(s), $n_row market-row read(s) x $(printf '%s\n' "$tks" | grep -c .) market(s), $n_post post-deploy read(s), $n_other other read(s), $n_uncalled uncalled read(s), $n_wb write-back path(s); $n_lib of the reads lifted from sourced libraries"
  if [ "$FAIL" != 0 ]; then
    echo "check-deploy-inputs: $counts"
    echo "check-deploy-inputs: ${REGISTRY##*/} / ${SOURCES##*/} cannot drive $(short "$w") to its first forge step ($MODE mode)" >&2
    return 1
  fi
  echo "check-deploy-inputs: $counts: every input present, every write-back key homed ($MODE mode)"
}

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/check-deploy-inputs.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT
TMPROW="$TMPD/row.json"

# --- self-test ---------------------------------------------------------------------------------------
# Fixtures are DERIVED from the repo's own script/v2/fixtures pair with one asserted edit each, so they
# cannot drift from the files they stand in for. The clean case is the fixture registry with the fields
# that are null there BY DESIGN of the fixture filled with stand-in values (the fixture is the rehearsal
# registry; T-OP-108 / T-OP-111 fill the real one), plus the two per-market write-back keys
# (`registeredAt`, `registerTx`) that the fixture rows lack today -- which the plain run on the fixture
# reports, correctly, as missing-writeback-key. The wrapper-side fixtures (a moved anchor, a hidden
# library read, an uncalled library function) are scratch copies of WHICHEVER scanned file carries the
# line in question, found by content at run time, and are passed with --lib <rel>=<copy>.
if [ "$SELFTEST" = 1 ]; then
  FX="$REPO/script/v2/fixtures/registry-v8.json"; FS="$REPO/script/v2/fixtures/v2-sources.json"
  [ -f "$FX" ] && [ -f "$FS" ] || die "self-test needs script/v2/fixtures/registry-v8.json and v2-sources.json"
  export CHECK_DEPLOY_INPUTS_SELFTEST=1   # unlocks --lib for the fixture runs below, and only for them
  st_pass=0; st_fail=0
  clean="$TMPD/clean.json"
  jq '.shared.token.poolKey = {"currency0": null, "currency1": "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73", "fee": 0, "tickSpacing": 60, "hooks": "0x0000000000000000000000000000000000000000"}
      | .shared.safes = {"admin": "0x5afE00000000000000000000000000000000a1a1", "treasury": "0x5aFe00000000000000000000000000000000B2b2"}
      | .markets[].v2 |= (if has("registeredAt") then . else . + {"registeredAt": null, "registerTx": null} end)' "$FX" > "$clean"
  cp "$FS" "$TMPD/v2-sources.json"
  run_case() { # <label> <expect: ok|reject> <rule> <path> <registry> [extra args...]
    local label=$1 want=$2 rule=$3 path=$4 reg=$5; shift 5
    local out rc=0
    set +e; out=$("$0" --registry "$reg" --sources "$TMPD/v2-sources.json" --wrapper "$WRAPPER" --mode rehearse --recorded none --no-checksum "$@" 2>&1); rc=$?; set -e
    if [ "$want" = ok ]; then
      if [ "$rc" = 0 ]; then echo "  ok    $label accepted: $(printf '%s' "$out" | tail -1)"; st_pass=$((st_pass + 1))
      else echo "  FAIL  $label should be accepted (rc=$rc):" >&2; printf '%s\n' "$out" | grep -E '^REJECT|^check-deploy-inputs:' >&2; st_fail=$((st_fail + 1)); fi
    else
      if [ "$rc" = 0 ]; then echo "  FAIL  $label was ACCEPTED; expected '$rule $path'" >&2; st_fail=$((st_fail + 1))
      elif printf '%s' "$out" | grep -q "^REJECT $rule $path:"; then echo "  ok    $label refused by $rule naming $path"; st_pass=$((st_pass + 1))
      else echo "  FAIL  $label refused but NOT by '$rule $path' (rc=$rc):" >&2; printf '%s\n' "$out" | grep -E '^REJECT|^check-deploy-inputs:' >&2; st_fail=$((st_fail + 1)); fi
    fi
  }
  # The file among wrapper + sourced libraries that carries <literal> exactly once, as `--lib <rel>=`
  # prefix material: prints `<tag>|<path>|<rel>` (rel is `-` for the wrapper itself).
  carrier_of() { # <literal>
    local r tag path rel
    r=$(count_in_union literal "$1")
    [ "${r%%|*}" = 1 ] || die "self-test: '$1' must occur on exactly one line across the wrapper and its libraries, found ${r%%|*}"
    tag=$(printf '%s' "$r" | cut -d'|' -f2); path=${r##*|}
    rel=$(rel_of_tag "$tag"); [ -n "$rel" ] || rel=-
    printf '%s|%s|%s\n' "$tag" "$path" "$rel"
  }
  # Run the check with <path>'s scratch copy <copy> standing in (the wrapper itself via --wrapper, a
  # library via --lib rel=copy). Prints the check's output; rc in $?.
  run_with_copy() { # <rel-or--> <copy> <registry> [extra args...]
    local rel=$1 copy=$2 reg=$3; shift 3
    if [ "$rel" = - ]; then "$0" --registry "$reg" --sources "$TMPD/v2-sources.json" --wrapper "$copy" "$@"
    else "$0" --registry "$reg" --sources "$TMPD/v2-sources.json" --wrapper "$WRAPPER" --lib "$rel=$copy" "$@"; fi
  }
  lift_wrapper "$WRAPPER"   # SCAN_FILES / SCAN_RELS / FN_EFF for the fixtures below
  echo "check-deploy-inputs --self-test: fixtures derived from ${FX#"$REPO"/} in $TMPD; scanning $(printf '%s\n' "$SCAN_FILES" | grep -c .) file(s): $(printf '%s\n' "$SCAN_FILES" | awk -F'|' 'NF {p=$2; sub(".*/", "", p); printf "%s%s", (n++ ? " + " : ""), p}')"
  # 1. positive control: a registry with every input present is accepted.
  run_case "clean registry (fixture + pool key + safes)" ok - - "$clean"
  # 2. a null input: the wrapper's first shared read.
  jq '.shared.usdg = null' "$clean" > "$TMPD/null-usdg.json"
  run_case "shared.usdg nulled" reject null-input '\.shared\.usdg' "$TMPD/null-usdg.json"
  # 3. the T-OP-108 shape: the pool key hooks nulled (a `// empty` read the wrapper refuses by name).
  jq '.shared.token.poolKey.hooks = null' "$clean" > "$TMPD/null-hooks.json"
  run_case "shared.token.poolKey.hooks nulled" reject null-input '\.shared\.token\.poolKey\.hooks' "$TMPD/null-hooks.json"
  # 4. a null recon input (v2-sources): weth.
  jq '.contracts.weth.address = null' "$FS" > "$TMPD/v2-sources-noweth.json"
  cp "$TMPD/v2-sources.json" "$TMPD/v2-sources.keep"; cp "$TMPD/v2-sources-noweth.json" "$TMPD/v2-sources.json"
  run_case "v2-sources contracts.weth.address nulled" reject null-input '\.contracts\.weth\.address' "$clean"
  cp "$TMPD/v2-sources.keep" "$TMPD/v2-sources.json"
  # 5. a missing write-back key: the skeleton loses v2.contracts.accessManager.
  jq 'del(.v2.contracts.accessManager)' "$clean" > "$TMPD/no-am.json"
  run_case "v2.contracts.accessManager key deleted" reject missing-writeback-key '\.v2\.contracts\.accessManager' "$TMPD/no-am.json"
  # 6. a missing per-market write-back key.
  jq '.markets[0].v2 |= del(.registeredAt)' "$clean" > "$TMPD/no-regat.json"
  run_case "markets[0].v2.registeredAt key deleted" reject missing-writeback-key 'markets\[\]\.v2\.registeredAt' "$TMPD/no-regat.json"
  # 7. null bots are legal on a rehearsal (the fixture has them null) but refused for a broadcast.
  set +e; out=$("$0" --registry "$clean" --sources "$TMPD/v2-sources.json" --wrapper "$WRAPPER" --mode broadcast --no-checksum 2>&1); rc=$?; set -e
  if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q '^REJECT null-input \.v2\.bots\.cranker:'; then echo "  ok    null v2.bots refused in broadcast mode"; st_pass=$((st_pass + 1)); else echo "  FAIL  null v2.bots should be refused in broadcast mode (rc=$rc)" >&2; st_fail=$((st_fail + 1)); fi
  # 8. a condition whose anchor moved is a loud stale-condition, not a quiet excuse. The edit lands in
  #    WHICHEVER scanned file carries the feeRecipient anchor (the wrapper at T-OP-112, a library since
  #    T-OP-113), found by content, never by name.
  IFS='|' read -r _ apath arel <<<"$(carrier_of '  null|"") FEE_RECIPIENT="" ;;')"
  sed 's/^  null|"") FEE_RECIPIENT="" ;;/  null|"") FEE_RECIPIENT="";;/' "$apath" > "$TMPD/anchor-moved.sh"
  cmp -s "$apath" "$TMPD/anchor-moved.sh" && die "self-test: the feeRecipient anchor edit did not land in ${apath##*/}; fixture would be a copy of it"
  set +e; out=$(run_with_copy "$arel" "$TMPD/anchor-moved.sh" "$clean" --mode rehearse --no-checksum 2>&1); rc=$?; set -e
  if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q '^REJECT stale-condition \.shared\.feeRecipient:'; then echo "  ok    moved null-ok anchor (in ${apath##*/}) reported as stale-condition"; st_pass=$((st_pass + 1)); else echo "  FAIL  a moved anchor should be stale-condition (rc=$rc)" >&2; printf '%s\n' "$out" | grep -E '^REJECT|^check-deploy-inputs:' >&2; st_fail=$((st_fail + 1)); fi
  # 9. --recorded none refuses a registry that already names a contract (the wrapper would not deploy).
  jq '.v2.contracts.clearinghouse = "0x53d7A6d0489Daf3d67b9A314e0eAB2B78Acab9C6"' "$clean" > "$TMPD/recorded.json"
  run_case "v2.contracts.clearinghouse recorded, --recorded none" reject stale-writeback '\.v2\.contracts\.clearinghouse' "$TMPD/recorded.json"
  # 10. --recorded all refuses a fresh registry (a resume needs every address).
  set +e; out=$("$0" --registry "$clean" --sources "$TMPD/v2-sources.json" --wrapper "$WRAPPER" --mode rehearse --recorded all --no-checksum 2>&1); rc=$?; set -e
  if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q '^REJECT null-input \.v2\.contracts\.accessManager:'; then echo "  ok    fresh registry refused under --recorded all"; st_pass=$((st_pass + 1)); else echo "  FAIL  a fresh registry should be refused under --recorded all (rc=$rc)" >&2; st_fail=$((st_fail + 1)); fi
  # 11. THE UNION IS SCANNED, NOT COPIED (T-OP-137). Hide one INPUT read -- the pool key's currency1, the
  #     T-OP-108 null -- in a scratch copy of whichever scanned file carries it. Three things must follow:
  #     the derived read list loses exactly that read and nothing else; a registry with the value null is
  #     REFUSED by name through the real files (the read is seen where it lives); and the same registry is
  #     ACCEPTED through the scratch copy, which is what "derived" means -- a list typed into this file
  #     would not have moved. A wrapper-only scan (the plausible wrong fix) fails the first two: the
  #     read is in the library.
  IFS='|' read -r htag hpath hrel <<<"$(carrier_of "$(printf '%s' '.shared.token.poolKey.currency1 // empty')")"
  grep -vF '.shared.token.poolKey.currency1 // empty' "$hpath" > "$TMPD/hidden-read.sh"
  cmp -s "$hpath" "$TMPD/hidden-read.sh" && die "self-test: the currency1 read was not removed from ${hpath##*/}"
  before=$(all_reads | wc -l | tr -d ' ')
  SAVED_SCAN=$SCAN_FILES
  SCAN_FILES=$(printf '%s\n' "$SAVED_SCAN" | awk -F'|' -v t="$htag" -v c="$TMPD/hidden-read.sh" 'NF {if ($1 == t) $2 = c; print $1 "|" $2 "|" $3}')
  after=$(all_reads | wc -l | tr -d ' ')
  # (diff exits 1 when the lists differ, which is the expected case; under pipefail that must not be a death)
  gone=$({ diff <(SCAN_FILES=$SAVED_SCAN; all_reads | cut -d'|' -f4,6- | LC_ALL=C sort) <(all_reads | cut -d'|' -f4,6- | LC_ALL=C sort) || true; } | { grep '^<' || true; } | sed 's/^< //')
  SCAN_FILES=$SAVED_SCAN
  if [ "$after" = $((before - 1)) ] && [ "$gone" = 'registry|.shared.token.poolKey.currency1 // empty' ]; then echo "  ok    hidden library read: derived reads $before -> $after, the missing one is $gone (from ${hpath##*/})"; st_pass=$((st_pass + 1))
  else echo "  FAIL  hiding the currency1 read in ${hpath##*/} should drop the derived count by exactly one ($before -> $after) and name it (got '$gone')" >&2; st_fail=$((st_fail + 1)); fi
  jq '.shared.token.poolKey.currency1 = null' "$clean" > "$TMPD/null-currency1.json"
  run_case "shared.token.poolKey.currency1 nulled, real files" reject null-input '\.shared\.token\.poolKey\.currency1' "$TMPD/null-currency1.json"
  set +e; out=$(run_with_copy "$hrel" "$TMPD/hidden-read.sh" "$TMPD/null-currency1.json" --mode rehearse --recorded none --no-checksum 2>&1); rc=$?; set -e
  if [ "$rc" = 0 ]; then echo "  ok    the same null passes through the scratch copy that lacks the read: the list is derived from the files, not typed here"; st_pass=$((st_pass + 1))
  else echo "  FAIL  with the read hidden the check should not be able to see the null (rc=$rc); a copied list is the only way it could" >&2; printf '%s\n' "$out" | grep -E '^REJECT|^check-deploy-inputs:' >&2; st_fail=$((st_fail + 1)); fi
  # 12. a library function the wrapper never calls is REPORTED by name, its reads listed as uncalled and
  #     not evaluated (an orphan read of a path the clean registry lacks must not refuse the run).
  printf '\norphan_never_called() { jqr %s; }\n' "'.shared.orphanOnlyTheDriverReads'" | cat "$hpath" - > "$TMPD/orphan.sh"
  set +e; out=$(run_with_copy "$hrel" "$TMPD/orphan.sh" "$clean" --mode rehearse --recorded none --no-checksum 2>&1); rc=$?; set -e
  if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^UNCALLED   orphan_never_called in ' && printf '%s' "$out" | grep -q '^UNCALLED   listed   .*orphan_never_called.*\.shared\.orphanOnlyTheDriverReads'; then echo "  ok    uncalled library function reported by name, its read listed and not evaluated"; st_pass=$((st_pass + 1))
  else echo "  FAIL  an uncalled library function should be reported by name with its read listed, and the clean registry still accepted (rc=$rc)" >&2; printf '%s\n' "$out" | grep -E '^REJECT|^UNCALLED|^check-deploy-inputs:' >&2; st_fail=$((st_fail + 1)); fi
  # 13. --lib outside the self-test is refused: a real run scans the library the wrapper sources.
  set +e; out=$(env -u CHECK_DEPLOY_INPUTS_SELFTEST "$0" --registry "$clean" --sources "$TMPD/v2-sources.json" --lib "x=$TMPD/orphan.sh" --mode rehearse --no-checksum 2>&1); rc=$?; set -e
  if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q -- '--lib is accepted only for --self-test'; then echo "  ok    --lib refused outside --self-test"; st_pass=$((st_pass + 1)); else echo "  FAIL  --lib should be refused outside --self-test (rc=$rc)" >&2; st_fail=$((st_fail + 1)); fi
  # 14. WRITE-BACK PATHS ARE DERIVED BY SHAPE (coordinator addition to T-OP-137, for T-OP-116's
  #     `v2.externalDeployBlocks.<key>`): a scratch WRAPPER gains a write_back kind that records
  #     `reg.v2.externalDeployBlocks[key]` from its call arguments, called from `for k in $EXTERNAL_KEYS`.
  #     The six keys must be demanded of the skeleton without any list typed here: the clean registry
  #     (no such block) is refused naming the first external, and a registry carrying the block passes.
  #     The copy lives outside the repo, so its sourced libraries are supplied with --lib <rel>=<real>.
  libargs=""
  while IFS='|' read -r tag rel; do [ -n "$tag" ] && libargs="$libargs --lib $rel=$(file_of_tag "$tag")"; done <<SR
$SCAN_RELS
SR
  awk '
    /} else throw new Error\("unknown write-back " \+ kind\);/ {
      print "    } else if (kind === \"externals\") {"
      print "      const [key, addr, block] = a;"
      print "      reg.v2.externalDeployBlocks[key] = Number(block);"
    }
    { print }
    END {
      print "for k in $EXTERNAL_KEYS; do"
      print "  write_back externals \"$k\" \"0x0000000000000000000000000000000000000001\" \"1\""
      print "done"
    }' "$WRAPPER" > "$TMPD/wb-externals.sh"
  grep -q 'kind === "externals"' "$TMPD/wb-externals.sh" || die "self-test: the externals write-back branch did not land in the scratch wrapper (the unknown-kind throw line moved?)"
  first_ext=${EXTERNAL_KEYS%% *}
  # (the fixture carries v2.externalDeployBlocks since T-OP-167; the case needs a skeleton WITHOUT it)
  jq 'del(.v2.externalDeployBlocks)' "$clean" > "$TMPD/clean-no-ext-blocks.json"
  set +e; out=$("$0" --registry "$TMPD/clean-no-ext-blocks.json" --sources "$TMPD/v2-sources.json" --wrapper "$TMPD/wb-externals.sh" $libargs --mode rehearse --recorded none --no-checksum 2>&1); rc=$?; set -e
  n_ext=$(printf '%s\n' "$out" | grep -c "^REJECT missing-writeback-key \.v2\.externalDeployBlocks\." || true)
  if [ "$rc" = 1 ] && [ "$n_ext" = "$(printf '%s\n' $EXTERNAL_KEYS | grep -c .)" ] && printf '%s' "$out" | grep -q "^REJECT missing-writeback-key \.v2\.externalDeployBlocks\.$first_ext:"; then echo "  ok    a new arg-keyed write-back group (externalDeployBlocks over \$EXTERNAL_KEYS) is derived from write_back() and its call site: all $n_ext keys demanded, none typed here"; st_pass=$((st_pass + 1))
  else echo "  FAIL  the externalDeployBlocks group should be demanded for every EXTERNAL_KEYS entry (rc=$rc, $n_ext named)" >&2; printf '%s\n' "$out" | grep -E '^REJECT|^check-deploy-inputs:' >&2; st_fail=$((st_fail + 1)); fi
  jq --arg keys "$EXTERNAL_KEYS" '.v2.externalDeployBlocks = ($keys | split(" ") | map({key: ., value: null}) | from_entries)' "$clean" > "$TMPD/with-ext-blocks.json"
  set +e; out=$("$0" --registry "$TMPD/with-ext-blocks.json" --sources "$TMPD/v2-sources.json" --wrapper "$TMPD/wb-externals.sh" $libargs --mode rehearse --recorded none --no-checksum 2>&1); rc=$?; set -e
  if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "^WRITE-BACK ok       \.v2\.externalDeployBlocks\.$first_ext "; then echo "  ok    the same wrapper accepts a skeleton that carries the block: $(printf '%s' "$out" | tail -1 | sed 's/.*, \([0-9]* write-back path(s)\).*/\1/')"; st_pass=$((st_pass + 1))
  else echo "  FAIL  a skeleton carrying v2.externalDeployBlocks.* should be accepted (rc=$rc)" >&2; printf '%s\n' "$out" | grep -E '^REJECT|^check-deploy-inputs:' >&2; st_fail=$((st_fail + 1)); fi
  # 15. A write this check cannot derive the key set for is rc=2 BY NAME, never a quiet omission: the
  #     same branch keyed by a name typed inside the JS (no Object.entries, not the deploy JSON, not an
  #     argument).
  sed 's/const \[key, addr, block\] = a;/const key = "houseVault"; const block = a[0];/' "$TMPD/wb-externals.sh" > "$TMPD/wb-underivable.sh"
  cmp -s "$TMPD/wb-externals.sh" "$TMPD/wb-underivable.sh" && die "self-test: the underivable-key edit did not land"
  set +e; out=$("$0" --registry "$clean" --sources "$TMPD/v2-sources.json" --wrapper "$TMPD/wb-underivable.sh" $libargs --mode rehearse --recorded none --no-checksum 2>&1); rc=$?; set -e
  if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q 'writes v2\.externalDeployBlocks\[key\] but key is neither'; then echo "  ok    a write-back keyed by a name typed inside write_back() refuses to run (rc=2) naming the write"; st_pass=$((st_pass + 1))
  else echo "  FAIL  an underivable write-back key set should be rc=2 naming the write (rc=$rc)" >&2; printf '%s\n' "$out" | tail -3 >&2; st_fail=$((st_fail + 1)); fi
  # 16. T-OP-116's ACTUAL shape (claude-625632, M-b71f686e47ca4aa0): the externals are recorded by a LIBRARY
  #     function whose node body destructures process.argv, called through two bash functions with
  #     positional arguments; the key at the outermost call site is either a loop variable over a column-0
  #     list in the library (`for k in $SELFTEST_EXTERNAL_ORDER` here; the landed shape uses EXTERNAL_DEPLOY_ORDER,
  #     which the base library now defines itself) or a BARE LITERAL (the landed shape at
  #     7c2b0dcb: `externals_landed houseVaultFactory "$addr" DeployHouseVault.s.sol`). The scratch library
  #     carries three keys each way; the check must demand every v2.contracts.<external> and
  #     v2.externalDeployBlocks.<external> key -- resolved through the argument chain, the lifted list
  #     and the literals, nothing typed here -- and refuse the clean fixture (no externalDeployBlocks).
  {
    cat "$hpath"
    printf '\n%s\n' "# --- self-test fixture: T-OP-116's shape, appended by check-deploy-inputs.sh --self-test ---"
    printf '%s\n' 'registry_env_record_external() { # key addr block' \
      "  node -e '" \
      '    const fs = require("fs");' \
      '    const [file, key, addr, block] = process.argv.slice(1);' \
      '    const reg = JSON.parse(fs.readFileSync(file, "utf8"));' \
      '    reg.v2.contracts[key] = addr;' \
      '    if (!reg.v2.externalDeployBlocks) reg.v2.externalDeployBlocks = {};' \
      '    reg.v2.externalDeployBlocks[key] = Number(block);' \
      '    fs.writeFileSync(file, JSON.stringify(reg, null, 2) + "\n");' \
      "  ' \"\$STATE\" \"\$1\" \"\$2\" \"\$3\"" \
      '}' \
      'externals_landed() { # key addr' \
      '  local blk=1' \
      '  registry_env_record_external "$1" "$2" "$blk"' \
      '}' \
      "SELFTEST_EXTERNAL_ORDER=\"$(printf '%s' "$EXTERNAL_KEYS" | awk '{print $2, $1, $6}')\"" \
      'selftest_registry_env_externals() {' \
      '  local k' \
      '  for k in $SELFTEST_EXTERNAL_ORDER; do' \
      '    externals_landed "$k" "0x0000000000000000000000000000000000000001"' \
      '  done' \
      "  externals_landed $(printf '%s' "$EXTERNAL_KEYS" | awk '{print $3}') \"0x0000000000000000000000000000000000000002\"" \
      "  externals_landed $(printf '%s' "$EXTERNAL_KEYS" | awk '{print $4}') \"0x0000000000000000000000000000000000000003\"" \
      "  externals_landed $(printf '%s' "$EXTERNAL_KEYS" | awk '{print $5}') \"0x0000000000000000000000000000000000000004\"" \
      '}'
  } > "$TMPD/lib-116.sh"
  bash -n "$TMPD/lib-116.sh" || die "self-test: the T-OP-116-shaped fixture library does not parse"
  set +e; out=$(run_with_copy "$hrel" "$TMPD/lib-116.sh" "$TMPD/clean-no-ext-blocks.json" --mode rehearse --recorded none --no-checksum 2>&1); rc=$?; set -e
  # (the fixture homes v2.contracts.<external> since T-OP-109, so those six are DEMANDED and found -- counted
  #  as WRITE-BACK lines either way; the externalDeployBlocks six are absent there and must be refused)
  n_c=$(printf '%s\n' "$out" | grep -c -E "^(WRITE-BACK ok       |REJECT missing-writeback-key )\.v2\.contracts\.(houseVault|houseVaultFactory|hedger|rewardsDistributorLender|earnVault|stockVenueAdapter)[ :]" || true)
  n_b=$(printf '%s\n' "$out" | grep -c "^REJECT missing-writeback-key \.v2\.externalDeployBlocks\." || true)
  n_ext=$(printf '%s\n' $EXTERNAL_KEYS | grep -c .)
  if [ "$rc" = 1 ] && [ "$n_b" = "$n_ext" ] && [ "$n_c" = "$n_ext" ]; then echo "  ok    T-OP-116's library shape (process.argv, two bash hops, 3 keys via a column-0 list + 3 bare literals): $n_ext v2.contracts.* and $n_ext v2.externalDeployBlocks.* keys demanded, resolved through the call chain"; st_pass=$((st_pass + 1))
  else echo "  FAIL  the T-OP-116-shaped library should demand $n_ext v2.contracts.* (found or refused) and refuse $n_ext v2.externalDeployBlocks.* keys (rc=$rc, contracts $n_c, blocks $n_b)" >&2; printf '%s\n' "$out" | grep -E '^REJECT|^check-deploy-inputs:' >&2; st_fail=$((st_fail + 1)); fi
  jq --arg keys "$EXTERNAL_KEYS" '.v2.externalDeployBlocks = ($keys | split(" ") | map({key: ., value: null}) | from_entries) | .v2.contracts += ($keys | split(" ") | map({key: ., value: null}) | from_entries)' "$clean" > "$TMPD/with-externals.json"
  set +e; out=$(run_with_copy "$hrel" "$TMPD/lib-116.sh" "$TMPD/with-externals.json" --mode rehearse --recorded none --no-checksum 2>&1); rc=$?; set -e
  if [ "$rc" = 0 ]; then echo "  ok    a skeleton carrying both blocks passes the same library: $(printf '%s' "$out" | tail -1 | sed 's/.*, \([0-9]* write-back path(s)\).*/\1/')"; st_pass=$((st_pass + 1))
  else echo "  FAIL  a skeleton carrying v2.contracts.<external> and v2.externalDeployBlocks.<external> should be accepted (rc=$rc)" >&2; printf '%s\n' "$out" | grep -E '^REJECT|^check-deploy-inputs:' >&2; st_fail=$((st_fail + 1)); fi
  # 17. A refusal raised DEEP in the derivation (inside resolve_arg, two command substitutions down) must
  #     reach the exit code. This is the false-green shape of a `die` inside `$(...)`: it exits only the
  #     subshell, the parent carries on with an empty key set, and the run prints "every write-back key
  #     homed" over keys it never derived. MEASURED against the landed library before this guard: the
  #     message printed and the run continued. The fixture calls externals_landed with an argument that
  #     is neither a $variable nor a bare key.
  sed 's/^  externals_landed \([a-zA-Z]*\) "0x0000000000000000000000000000000000000002"$/  externals_landed "not-a-key" "0x0000000000000000000000000000000000000002"/' "$TMPD/lib-116.sh" > "$TMPD/lib-116-bad.sh"
  cmp -s "$TMPD/lib-116.sh" "$TMPD/lib-116-bad.sh" && die "self-test: the not-a-key edit did not land"
  set +e; out=$(run_with_copy "$hrel" "$TMPD/lib-116-bad.sh" "$TMPD/with-externals.json" --mode rehearse --recorded none --no-checksum 2>&1); rc=$?; set -e
  if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q "calls externals_landed with argument 1 'not-a-key', which is neither" && ! printf '%s' "$out" | grep -q 'every write-back key homed'; then echo "  ok    a refusal raised inside the derivation's nested command substitutions reaches the exit code (rc=2, no 'homed' line)"; st_pass=$((st_pass + 1))
  else echo "  FAIL  an underivable call-site argument deep in resolve_arg should be rc=2 and never print a homed line (rc=$rc)" >&2; printf '%s\n' "$out" | grep -E 'cannot be derived|every write-back|^check-deploy-inputs:' >&2; st_fail=$((st_fail + 1)); fi
  # 18-21. THE WALLET CLASS (T-OP-187). A stub `cast` on PATH answers `code` from a list of addresses that
  #     "have code" (everything in the clean registry + recon except what a case removes) and delegates
  #     `to-check-sum-address` to the real cast, so `--rpc http://stub.invalid` exercises has_code offline.
  STUBC="$TMPD/stubcast"; mkdir -p "$STUBC"
  cat > "$STUBC/cast" <<'CAST'
#!/usr/bin/env bash
case "$1" in
  code) if grep -qi -- "$2" "$STUB_CODE_LIST"; then echo 0x6000; else echo 0x; fi ;;
  to-check-sum-address) exec "$REAL_CAST" "$@" ;;
  *) echo "stub cast: $*" >&2; exit 2 ;;
esac
CAST
  chmod +x "$STUBC/cast"
  REAL_CAST=$(command -v cast) || die "self-test: cast is not on PATH (the WALLET cases need it for the checksum)"
  export REAL_CAST
  # every address the clean pair carries, one per line, lower-case
  { jq -r '.. | strings | select(test("^0x[0-9a-fA-F]{40}$"))' "$clean" "$TMPD/v2-sources.json"; } | tr 'A-F' 'a-f' | LC_ALL=C sort -u > "$TMPD/code-all.txt"
  guardian=$(jq -r '.shared.guardian' "$clean"); admin_safe=$(jq -r '.shared.safes.admin' "$clean")
  # 18. the EOA principals (guardian + the fixture's stand-in bots are null) have NO code, everything else has:
  #     the clean registry is accepted and the guardian line names the class.
  grep -vi -- "$guardian" "$TMPD/code-all.txt" > "$TMPD/code-no-eoa.txt"
  set +e; out=$(STUB_CODE_LIST="$TMPD/code-no-eoa.txt" PATH="$STUBC:$PATH" "$0" --registry "$clean" --sources "$TMPD/v2-sources.json" --wrapper "$WRAPPER" --mode rehearse --recorded none --rpc http://stub.invalid 2>&1); rc=$?; set -e
  if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "^INPUT      ok       \.shared\.guardian = .* (WALLET: a key by design, no code expected)"; then echo "  ok    an EOA guardian passes with --rpc (WALLET class printed); every contract address still probed for code"; st_pass=$((st_pass + 1))
  else echo "  FAIL  an EOA guardian should pass with --rpc as WALLET (rc=$rc)" >&2; printf '%s\n' "$out" | grep -E '^REJECT|^check-deploy-inputs:' >&2; st_fail=$((st_fail + 1)); fi
  # 19. an EOA in v2.contracts.* is still refused no-code (--recorded any so the recorded slot is evaluated).
  jq --arg g "$guardian" '.v2.contracts.clearinghouse = $g' "$clean" > "$TMPD/eoa-contract.json"
  set +e; out=$(STUB_CODE_LIST="$TMPD/code-no-eoa.txt" PATH="$STUBC:$PATH" "$0" --registry "$TMPD/eoa-contract.json" --sources "$TMPD/v2-sources.json" --wrapper "$WRAPPER" --mode rehearse --recorded any --rpc http://stub.invalid 2>&1); rc=$?; set -e
  if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "^REJECT no-code \.v2\.contracts\.clearinghouse:"; then echo "  ok    an EOA recorded at v2.contracts.clearinghouse is still refused no-code"; st_pass=$((st_pass + 1))
  else echo "  FAIL  an EOA in v2.contracts.* should be refused no-code (rc=$rc)" >&2; printf '%s\n' "$out" | grep -E '^REJECT|^check-deploy-inputs:' >&2; st_fail=$((st_fail + 1)); fi
  # 20. a code-less Safe is still refused no-code (the Safes are contracts; shared.safes.* is not WALLET).
  grep -vi -- "$admin_safe" "$TMPD/code-no-eoa.txt" > "$TMPD/code-no-safe.txt"
  set +e; out=$(STUB_CODE_LIST="$TMPD/code-no-safe.txt" PATH="$STUBC:$PATH" "$0" --registry "$clean" --sources "$TMPD/v2-sources.json" --wrapper "$WRAPPER" --mode rehearse --recorded none --rpc http://stub.invalid 2>&1); rc=$?; set -e
  if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "^REJECT no-code \.shared\.safes\.admin:"; then echo "  ok    a code-less Admin Safe is still refused no-code"; st_pass=$((st_pass + 1))
  else echo "  FAIL  a code-less Safe should be refused no-code (rc=$rc)" >&2; printf '%s\n' "$out" | grep -E '^REJECT|^check-deploy-inputs:' >&2; st_fail=$((st_fail + 1)); fi
  # 21. THE CLASS IS DERIVED, NOT TYPED: a scratch library whose principal list no longer names shared.guardian
  #     drops the guardian from the wallet class, and the same EOA guardian is then refused no-code.
  IFS='|' read -r _ ppath prel <<<"$(carrier_of 'registry_env_refuse_deployer_is_principal() {')"
  sed 's/ shared\.guardian / /' "$ppath" > "$TMPD/lib-no-guardian.sh"
  cmp -s "$ppath" "$TMPD/lib-no-guardian.sh" && die "self-test: removing shared.guardian from the principal list did not land in ${ppath##*/}"
  set +e; out=$(STUB_CODE_LIST="$TMPD/code-no-eoa.txt" PATH="$STUBC:$PATH" run_with_copy "$prel" "$TMPD/lib-no-guardian.sh" "$clean" --mode rehearse --recorded none --rpc http://stub.invalid 2>&1); rc=$?; set -e
  if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "^REJECT no-code \.shared\.guardian:" && ! printf '%s' "$out" | grep -q "wallet paths.*\.shared\.guardian"; then echo "  ok    the wallet class follows the library's principal list: with shared.guardian removed there, the EOA guardian is refused no-code"; st_pass=$((st_pass + 1))
  else echo "  FAIL  the wallet class should be derived from the library's principal list (rc=$rc)" >&2; printf '%s\n' "$out" | grep -E '^REJECT|wallet paths|^check-deploy-inputs:' >&2; st_fail=$((st_fail + 1)); fi
  # 22. NO LINE PRINTS THE RAW RPC URL (T-OP-199). rpc_host_of strips a key-shaped path, query, fragment and
  #     userinfo; then the real reject path is driven with a keyed --rpc and the whole output is searched for
  #     the key. The positive control is the search itself: the key IS in $RPC, so a leak would be found.
  fake='https://user:pw@rpc.example.test:8545/v2/K3yK3yK3y?token=T0k3n#frag'
  got=$(rpc_host_of "$fake")
  if [ "$got" = "https://rpc.example.test:8545" ]; then echo "  ok    rpc_host_of strips path, query, fragment and userinfo: $got"; st_pass=$((st_pass + 1))
  else echo "  FAIL  rpc_host_of printed '$(printf '%s' "$got" | sed -e 's/K3yK3yK3y/<key>/g' -e 's/T0k3n/<token>/g')' for a keyed URL" >&2; st_fail=$((st_fail + 1)); fi
  set +e; out=$(STUB_CODE_LIST="$TMPD/code-no-eoa.txt" PATH="$STUBC:$PATH" run_with_copy "$prel" "$TMPD/lib-no-guardian.sh" "$clean" --mode rehearse --recorded none --rpc "$fake" 2>&1); rc=$?; set -e
  if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "^REJECT no-code .*holds no code on https://rpc.example.test:8545" && ! printf '%s' "$out" | grep -qE 'K3yK3y|T0k3n|pw@'; then echo "  ok    a keyed --rpc reaches the reject and info lines as scheme://host only"; st_pass=$((st_pass + 1))
  else echo "  FAIL  the keyed --rpc leaked, or the no-code reject did not fire (rc=$rc)" >&2; printf '%s\n' "$out" | grep -E '^REJECT|^check-deploy-inputs:' | sed -e 's/K3yK3yK3y/<key>/g' -e 's/T0k3n/<token>/g' >&2; st_fail=$((st_fail + 1)); fi
  echo "check-deploy-inputs --self-test: $st_pass passed, $st_fail failed"
  [ "$st_fail" = 0 ] || exit 1
  exit 0
fi

run_check
