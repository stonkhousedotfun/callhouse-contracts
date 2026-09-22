#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# export-abis.sh — publishes the v2 ABIs and the series-id test vectors to the callhouse monorepo.
#
# For every name in script/v2/abi-manifest.txt it writes jq '.abi' of out/<Name>.sol/<Name>.json to
# <callhouse>/ops/abis/v2/<Name>.json (jq's 2-space pretty print, trailing newline), copies
# test/v2/fixtures/series-ids.json to <callhouse>/ops/fixtures/v2/series-ids.json, and — from INTERFACE_VERSION 8 —
# copies script/v2/roles.v8.json to <callhouse>/ops/abis/v2/roles.json. roles.json is exempt from the staleness
# sweep (it is not a manifest entry and has no artifact). ops/abis/v2 is the one
# place the indexer, web and keeper generators read v2 ABIs from, so no package
# ever carries a hand-copied ABI, and the TypeScript seriesId.ts mirrors are tested against vectors that
# Solidity computed (script/v2/EmitSeriesIds.s.sol).
#
#   script/v2/export-abis.sh                                  # forge build, export to ../callhouse
#   script/v2/export-abis.sh --callhouse ../callhouse-v2-X    # a worktree: the default does not resolve
#   script/v2/export-abis.sh --check                          # forge build, compare, exit 1 on any drift
#   script/v2/export-abis.sh --prune                          # ...and delete published ABIs the manifest dropped
#
#   --callhouse <dir>  the callhouse checkout. Default $CALLHOUSE_DIR, else <this repo>/../callhouse. A
#                      relative path resolves against the directory you run the script from.
#   --skip-build       use out/ as it is (the caller has just built).
#   --prune            permit the export to DELETE published ABIs the manifest no longer lists. Without it an
#                      export that would remove one refuses and writes nothing.
#   --check            render everything into a temp directory and compare with the targets; writes nothing.
#                      Exit 1 on a target that differs or is missing, on a *.json in ops/abis/v2 that the manifest
#                      does not list (stale), or on a non-abstract contract declared under src/v2 that the manifest
#                      does not list (unlisted: it compiles, it is deployable, and nothing can ever publish its ABI).
#                      Exit 0 prints "export-abis --check: N ABIs + roles + series-ids match".
#
# Export mode renders into a temp directory first and copies only when every artifact was found, so a missing
# artifact never leaves ops/abis/v2 half updated. A published ops/abis/v2/*.json the manifest no longer lists --
# the same staleness --check refuses -- REFUSES THE WHOLE EXPORT unless --prune says the removal is intended; an
# accidental manifest deletion is otherwise permanent and silent from the next export onward (F-WIRE01-02).
# bash + jq only, no python; bash 3.2 compatible (macOS).
# -------------------------------------------------------------------------------------------------
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
MANIFEST="$REPO/script/v2/abi-manifest.txt"
VECTORS="$REPO/test/v2/fixtures/series-ids.json"
# INTERFACE_VERSION 8: the role manifest travels with the ABIs. script/v2/roles.v8.json is the source of truth;
# DeployV8, VerifyV8, the access-matrix test, the indexer and the monitor all read the published copy.
ROLES="$REPO/script/v2/roles.v8.json"
ROLES_NAME="roles"
export PATH="$HOME/.foundry/bin:$PATH"

die() {
  echo "export-abis: $*" >&2
  exit 1
}

CALLHOUSE=${CALLHOUSE_DIR:-}
BUILD=1
CHECK=0
PRUNE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --callhouse)
      [ $# -ge 2 ] || die "--callhouse needs a directory"
      CALLHOUSE=$2
      shift 2
      ;;
    --callhouse=*)
      CALLHOUSE=${1#*=}
      shift
      ;;
    --skip-build)
      BUILD=0
      shift
      ;;
    --check)
      CHECK=1
      shift
      ;;
    --prune)
      PRUNE=1
      shift
      ;;
    -h | --help)
      sed -n '2,/^# ----/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[ -n "$CALLHOUSE" ] || CALLHOUSE="$REPO/../callhouse"
[ -d "$CALLHOUSE" ] || die "callhouse checkout not found at $CALLHOUSE (pass --callhouse <dir> or set CALLHOUSE_DIR)"
CALLHOUSE=$(cd "$CALLHOUSE" && pwd)
[ -d "$CALLHOUSE/ops" ] || die "$CALLHOUSE has no ops/ directory; is it a callhouse checkout?"
# F-WIRE01-01. ops/ ALONE DOES NOT IDENTIFY A v2 TREE. The default target is "$REPO/../callhouse", which on a
# development machine is a checkout on whatever branch was last used -- and a v1-era branch has ops/ and ops/abis
# (Policy.json, Vault.json, AccountFactory.json) with no ops/abis/v2 at all. The guard above passes there, and then
# the two modes fail in opposite, equally wrong ways: --check prints a MISSING line for every manifest entry, which
# reads as "the v2 ABI set is broken" when the truth is "you are pointed at the wrong tree", and export CREATES
# ops/abis/v2 on a branch that must not have one. The correct diagnosis and the alarming one are indistinguishable,
# which is why the author of WIRE-01 kept this at P3: they fell into it themselves while auditing it.
#
# So require the v2 directory to EXIST, and say which of the two mistakes it probably is. A first-ever export into a
# genuinely new checkout is the one case this refuses, and `mkdir -p <callhouse>/ops/abis/v2` is the whole remedy --
# a deliberate one-line act, which is the point: creating that directory should never be a side effect of a run
# whose target was wrong.
[ -d "$CALLHOUSE/ops/abis/v2" ] ||
  die "$CALLHOUSE has ops/ but no ops/abis/v2: this is not a v2 callhouse tree (wrong branch, or wrong checkout).
       Pass --callhouse <dir> or set CALLHOUSE_DIR. If this really is a new checkout that should carry the v2 ABIs,
       create the directory first: mkdir -p $CALLHOUSE/ops/abis/v2"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
ABI_DIR="$CALLHOUSE/ops/abis/v2"
FIX_DIR="$CALLHOUSE/ops/fixtures/v2"

# --- manifest: '#' starts a comment, blank lines skipped, each name a Solidity identifier listed once ---------
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
NAMES=()
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  line=${line%%#*}
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -n "$line" ] || continue
  [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "abi-manifest.txt:$lineno: '$line' is not a contract name"
  case " ${NAMES[*]:-} " in
    *" $line "*) die "abi-manifest.txt:$lineno: $line is listed twice" ;;
  esac
  NAMES+=("$line")
done <"$MANIFEST"
[ ${#NAMES[@]} -gt 0 ] || die "abi-manifest.txt lists no names"

listed() {
  local n
  for n in "${NAMES[@]}"; do
    [ "$n" = "$1" ] && return 0
  done
  return 1
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/export-abis.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# --- build ------------------------------------------------------------------------------------------------------
# The log is kept out of the terminal on success: this repository's build prints hundreds of forge-lint notes.
if [ "$BUILD" = 1 ]; then
  if ! (cd "$REPO" && forge build) >"$TMP/forge-build.log" 2>&1; then
    cat "$TMP/forge-build.log" >&2
    die "forge build failed"
  fi
  echo "export-abis: forge build ok"
fi

# --- render -----------------------------------------------------------------------------------------------------
mkdir -p "$TMP/abis" "$TMP/fixtures"
for name in "${NAMES[@]}"; do
  artifact="out/$name.sol/$name.json"
  [ -f "$REPO/$artifact" ] ||
    die "missing artifact $artifact for manifest entry $name (not built, or declared in a file of another name)"
  jq -e '.abi | type == "array"' "$REPO/$artifact" >/dev/null || die "$artifact has no .abi array"
  jq '.abi' "$REPO/$artifact" >"$TMP/abis/$name.json"
done
[ -f "$VECTORS" ] || die "missing test/v2/fixtures/series-ids.json (run: forge script script/v2/EmitSeriesIds.s.sol)"
jq -e '.vectors | type == "array" and length > 0' "$VECTORS" >/dev/null || die "series-ids.json has no vectors"
cp "$VECTORS" "$TMP/fixtures/series-ids.json"
[ -f "$ROLES" ] || die "missing script/v2/roles.v8.json (the INTERFACE_VERSION 8 role manifest)"
jq -e '.interfaceVersion == 8 and (.roles | type == "object") and (.targets | type == "object")' "$ROLES" >/dev/null ||
  die "roles.v8.json is not an interface-8 role manifest"
jq '.' "$ROLES" >"$TMP/abis/$ROLES_NAME.json"

# --- check ------------------------------------------------------------------------------------------------------
if [ "$CHECK" = 1 ]; then
  fail=0
  compare() { # <rendered> <target> <label>
    if [ ! -f "$2" ]; then
      echo "MISSING  $3" >&2
      fail=1
    elif ! cmp -s "$1" "$2"; then
      echo "DIFFERS  $3" >&2
      diff -u "$2" "$1" | head -n 20 >&2 || true
      fail=1
    fi
  }
  for name in "${NAMES[@]}"; do
    compare "$TMP/abis/$name.json" "$ABI_DIR/$name.json" "ops/abis/v2/$name.json"
  done
  compare "$TMP/abis/$ROLES_NAME.json" "$ABI_DIR/$ROLES_NAME.json" "ops/abis/v2/$ROLES_NAME.json"
  compare "$TMP/fixtures/series-ids.json" "$FIX_DIR/series-ids.json" "ops/fixtures/v2/series-ids.json"
  for f in "$ABI_DIR"/*.json; do
    [ -e "$f" ] || continue
    base=$(basename "$f" .json)
    [ "$base" = "$ROLES_NAME" ] && continue
    if ! listed "$base"; then
      echo "STALE    ops/abis/v2/$base.json is not in script/v2/abi-manifest.txt" >&2
      fail=1
    fi
  done
  # --- unlisted src/v2 contracts: the third staleness direction -----------------------------------------------
  # Both loops above enumerate the PUBLISHED set ("$ABI_DIR"/*.json), and out/ is only ever indexed BY MANIFEST
  # NAME by the render step, so until now nothing in this script ever looked at the source tree. A contract that
  # exists under src/v2, compiles, and was simply never listed here is invisible to every code path -- which is
  # how FeeSplitter, PayoutRouter and V4BuybackExecutor stayed unpublishable from F8-02 until T-78. The export-mode
  # rm sweep below is what makes it unworkaroundable: a hand-copied ABI is deleted by the next export.
  #
  # Scope, and every half of it is load-bearing:
  #   source     non-abstract `contract` declarations under src/v2 only. NOT src/, which adds the v1 concretes
  #              (Vault, WriterAccount, AccountFactory and five mocks), none of which is part of the v2 ABI
  #              surface; and NOT out/, which is a build tree of whatever branch happens to be checked out.
  #   excluded   src/v2/mocks/** by PATH; `abstract contract`, `interface` and `library` by KEYWORD.
  #   direction  ONE-WAY containment. Every such contract must be listed; the reverse is false by design, because
  #              most of this manifest is interfaces, OpenZeppelin's AccessManager (declared in lib/ and pulled in
  #              only by the src/v2/access/V8AccessManagerArtifact.sol import shim) and the V2Errors library. A
  #              set-equality check here would fire on all of those on a clean tree.
  #
  # It reads the DECLARATION, never the file name. out/<basename>.sol/<basename>.json is not where a contract whose
  # name differs from its file lands -- the same failure the render step names in its own error text. Fourteen
  # THE SCAN'S BLIND SPOT, MEASURED AND WRITTEN DOWN (T-547). The matcher requires `contract` to be the
# first token on its line once comments are stripped, so a declaration the scan cannot see is one with
# real CODE before the keyword on the same line -- `} contract Foo is Base {` -- or one split across
# lines with the name on the next. Both were run against the awk below rather than reasoned about:
# `contract First {}` is seen, `} contract AfterClosingBrace is Base {}` and a `contract` whose name
# sits on the following line are not. What is NOT a blind spot, despite being the obvious guess: a
# leading comment. Comments are stripped BEFORE the match, so `/* … */ contract Foo` IS seen. And an
# `abstract contract` is missed BY DESIGN, not by accident -- this check is about concretes.
# Nothing in src/v2 is written either of the invisible ways today; this is here so the next reader
# knows the shape of what the check cannot see, which is the point of a blind spot being in a header.
# declarations under src/v2 already carry a name that is not their file's basename: twelve interfaces across
  # BuybackDeps.sol, PayoutDeps.sol, DataStreamsDeps.sol and OracleDeps.sol, the V4Currency library in V4Types.sol,
  # and IStonkhouseBurn beside the matching V4BuybackExecutor in V4BuybackExecutor.sol. Every one of them is an
  # interface or a library today, so a filename-keyed check is green for the wrong reason and would stay green the
  # first time one of those files declares a contract. (V8AccessManagerArtifact.sol is a different shape again: it
  # declares nothing at all, being a bare import that exists only to make out/AccessManager.sol/AccessManager.json
  # appear, which is why the manifest's AccessManager row has no src/v2 declaration behind it.) Comments are
  # stripped before matching, so a commented-out declaration cannot make the export impossible to run.
  SRC_V2="$REPO/src/v2"
  [ -d "$SRC_V2" ] || die "src/v2 not found under $REPO: the unlisted-contract check cannot run"
  SRC_LIST=$(find "$SRC_V2" -name '*.sol' -type f ! -path "$SRC_V2/mocks/*" | LC_ALL=C sort)
  SRC_COUNT=$(printf '%s\n' "$SRC_LIST" | grep -c '[^[:space:]]' || true)
  [ "$SRC_COUNT" -gt 0 ] ||
    die "the unlisted-contract check found no .sol file under src/v2: the scan is broken, not the tree"
  # Each awk run ends with a "scanned" receipt. awk does NOT run its END block on a file it cannot open (it prints
  # "can't open file" and exits 2), and that exit status is invisible here: the loop body's failure does not abort
  # the enclosing command substitution, so without a receipt a file that silently fails to open just shrinks the
  # result and the check reports a clean tree. A partial scan is the one outcome a check like this must never
  # confuse with a clean one, so the receipts are counted below and a shortfall is fatal.
  DECLS=$(
    while IFS= read -r src; do
      [ -n "$src" ] || continue
      rel=${src#"$REPO"/}
      awk -v rel="$rel" '
        {
          line = $0; out = ""; i = 1; n = length(line)
          while (i <= n) {
            two = substr(line, i, 2)
            if (blk) { if (two == "*/") { blk = 0; i += 2 } else { i++ } }
            else if (two == "//") { break }
            else if (two == "/*") { blk = 1; i += 2 }
            else { out = out substr(line, i, 1); i++ }
          }
          if (out ~ /^[[:space:]]*contract[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/) {
            name = out
            sub(/^[[:space:]]*contract[[:space:]]+/, "", name)
            sub(/[^A-Za-z0-9_].*$/, "", name)
            print name "|" rel ":" NR
          }
        }
        END { print "=scanned=|" rel }
      ' "$src"
    done <<SRCLIST
$SRC_LIST
SRCLIST
  )
  SCANNED=$(printf '%s\n' "$DECLS" | grep -c '^=scanned=|' || true)
  [ "$SCANNED" = "$SRC_COUNT" ] ||
    die "the unlisted-contract check read only $SCANNED of $SRC_COUNT .sol files under src/v2: a partial scan is not a clean tree"
  while IFS='|' read -r decl where; do
    [ -n "$decl" ] || continue
    if [ "$decl" = "=scanned=" ]; then continue; fi
    if ! listed "$decl"; then
      echo "UNLISTED $where declares contract $decl, which script/v2/abi-manifest.txt does not list" >&2
      fail=1
    fi
  done <<EOF
$DECLS
EOF
  [ "$fail" = 0 ] ||
    die "--check failed against $CALLHOUSE: re-run script/v2/export-abis.sh, commit ops/abis/v2 + ops/fixtures/v2"
  echo "export-abis --check: ${#NAMES[@]} ABIs + roles + series-ids match"
  exit 0
fi

# --- export -----------------------------------------------------------------------------------------------------
mkdir -p "$ABI_DIR" "$FIX_DIR"
# F-WIRE01-02, the half of it that survived re-derivation (T-279). The sweep at the end of this file DELETES every
# ops/abis/v2/*.json the manifest no longer lists. --check refuses that same state loudly (the STALE loop above), so
# a manifest row deleted by accident IS caught -- until someone runs an export, at which point the sweep removes the
# published ABI, prints one line among forty, and every later --check is green on the smaller set. The deletion is
# then invisible and permanent: the name simply stops being exported and the next consumer regeneration loses it.
#
# So a removal now has to be ASKED FOR. Detected here, before the first publish, because the rest of this script is
# deliberately all-or-nothing (a missing artifact never leaves ops/abis/v2 half updated) and a refusal after the
# copies would leave exactly the half-updated tree that promise exists to prevent.
#
# --prune is the acknowledgement. Dropping a name from the manifest is a real and legitimate act; doing it by
# accident and finding out months later is not.
REMOVALS=""
for f in "$ABI_DIR"/*.json; do
  [ -e "$f" ] || continue
  base=$(basename "$f" .json)
  [ "$base" = "$ROLES_NAME" ] && continue
  listed "$base" || REMOVALS="$REMOVALS  ops/abis/v2/$base.json
"
done
if [ -n "$REMOVALS" ] && [ "$PRUNE" = 0 ]; then
  printf '%s' "$REMOVALS" >&2
  die "the manifest no longer lists the published ABI(s) above, and an export would DELETE them.
       If that is intended, re-run with --prune. If it is not, a manifest row has been lost: restore it in
       script/v2/abi-manifest.txt. Nothing has been written."
fi
publish() { # <rendered> <target> <label>
  if [ -f "$2" ] && cmp -s "$1" "$2"; then
    echo "  unchanged  $3"
  else
    cp "$1" "$2"
    echo "  wrote      $3"
  fi
}
for name in "${NAMES[@]}"; do
  publish "$TMP/abis/$name.json" "$ABI_DIR/$name.json" "ops/abis/v2/$name.json"
done
publish "$TMP/abis/$ROLES_NAME.json" "$ABI_DIR/$ROLES_NAME.json" "ops/abis/v2/$ROLES_NAME.json"
publish "$TMP/fixtures/series-ids.json" "$FIX_DIR/series-ids.json" "ops/fixtures/v2/series-ids.json"
if [ "$PRUNE" = 1 ]; then
  for f in "$ABI_DIR"/*.json; do
    [ -e "$f" ] || continue
    base=$(basename "$f" .json)
    [ "$base" = "$ROLES_NAME" ] && continue
    if ! listed "$base"; then
      rm "$f"
      echo "  removed    ops/abis/v2/$base.json (--prune: not in the manifest)"
    fi
  done
fi
echo "export-abis: ${#NAMES[@]} ABIs + roles + series-ids exported to $CALLHOUSE/ops"
