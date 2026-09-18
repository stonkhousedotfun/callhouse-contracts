#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# export-abis.sh — publishes the v2 ABIs and the series-id test vectors to the callhouse monorepo.
#
# For every name in script/v2/abi-manifest.txt it writes jq '.abi' of out/<Name>.sol/<Name>.json to
# <callhouse>/ops/abis/v2/<Name>.json (jq's 2-space pretty print, trailing newline), and copies
# test/v2/fixtures/series-ids.json to <callhouse>/ops/fixtures/v2/series-ids.json. ops/abis/v2 is the one
# place the indexer, web and keeper generators read v2 ABIs from, so no package
# ever carries a hand-copied ABI, and the TypeScript seriesId.ts mirrors are tested against vectors that
# Solidity computed (script/v2/EmitSeriesIds.s.sol).
#
#   script/v2/export-abis.sh                                  # forge build, export to ../callhouse
#   script/v2/export-abis.sh --callhouse ../callhouse-v2-X    # a worktree: the default does not resolve
#   script/v2/export-abis.sh --check                          # forge build, compare, exit 1 on any drift
#
#   --callhouse <dir>  the callhouse checkout. Default $CALLHOUSE_DIR, else <this repo>/../callhouse. A
#                      relative path resolves against the directory you run the script from.
#   --skip-build       use out/ as it is (the caller has just built).
#   --check            render everything into a temp directory and compare with the targets; writes nothing.
#                      Exit 1 on a target that differs or is missing, or on a *.json in ops/abis/v2 that the
#                      manifest does not list (stale). Exit 0 prints "export-abis --check: N ABIs + series-ids match".
#
# Export mode renders into a temp directory first and copies only when every artifact was found, so a missing
# artifact never leaves ops/abis/v2 half updated. It also deletes ops/abis/v2/*.json files the manifest no
# longer lists, the same staleness --check refuses. bash + jq only, no python; bash 3.2 compatible (macOS).
# -------------------------------------------------------------------------------------------------
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
MANIFEST="$REPO/script/v2/abi-manifest.txt"
VECTORS="$REPO/test/v2/fixtures/series-ids.json"
export PATH="$HOME/.foundry/bin:$PATH"

die() {
  echo "export-abis: $*" >&2
  exit 1
}

CALLHOUSE=${CALLHOUSE_DIR:-}
BUILD=1
CHECK=0
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
  compare "$TMP/fixtures/series-ids.json" "$FIX_DIR/series-ids.json" "ops/fixtures/v2/series-ids.json"
  for f in "$ABI_DIR"/*.json; do
    [ -e "$f" ] || continue
    base=$(basename "$f" .json)
    if ! listed "$base"; then
      echo "STALE    ops/abis/v2/$base.json is not in script/v2/abi-manifest.txt" >&2
      fail=1
    fi
  done
  [ "$fail" = 0 ] ||
    die "--check failed against $CALLHOUSE: re-run script/v2/export-abis.sh, commit ops/abis/v2 + ops/fixtures/v2"
  echo "export-abis --check: ${#NAMES[@]} ABIs + series-ids match"
  exit 0
fi

# --- export -----------------------------------------------------------------------------------------------------
mkdir -p "$ABI_DIR" "$FIX_DIR"
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
publish "$TMP/fixtures/series-ids.json" "$FIX_DIR/series-ids.json" "ops/fixtures/v2/series-ids.json"
for f in "$ABI_DIR"/*.json; do
  [ -e "$f" ] || continue
  base=$(basename "$f" .json)
  if ! listed "$base"; then
    rm "$f"
    echo "  removed    ops/abis/v2/$base.json (not in the manifest)"
  fi
done
echo "export-abis: ${#NAMES[@]} ABIs + series-ids exported to $CALLHOUSE/ops"
