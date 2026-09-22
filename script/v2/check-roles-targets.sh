#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# check-roles-targets.sh — containment for script/v2/roles.v8.json `.targets`.
#
# WHY THIS FILE EXISTS. `AccessMatrix.t.sol` and `VerifyV8`'s check group 4 — the guards whose whole
# job is to catch a `restricted` selector nobody mapped — only walk the contracts `.targets` NAMES. A
# contract absent from that list is not checked; it is not even looked at. So a money-moving function
# with no modifier on an unlisted contract is invisible to the one test designed to find exactly that,
# which is how `F-CP-01` (T-170-SEC-EARN-ADAPTER-AUTH) survived review on `Erc4626VenueAdapter`.
#
# `.targets` was hand-maintained with nothing binding it to the source tree. `script/v2/abi-manifest.txt`
# had the same hole one file over until T-159-C8-ABI-MANIFEST-PERIPHERY added a containment check to
# `export-abis.sh`; this is that check's sibling, and it is deliberately the same shape.
#
#   script/v2/check-roles-targets.sh                 # check the repo
#   script/v2/check-roles-targets.sh --manifest <f>  # check another roles manifest
#   script/v2/check-roles-targets.sh --self-test     # run the fixture suite, then exit
#
# THE TWO RULES, and the second is the one that makes this more than a one-day fix.
#
#   TARGETS   a non-abstract contract under src/v2 (mocks excluded) that declares or inherits a
#             `restricted` external/public state-changing function MUST appear in `.targets`.
#             It has selectors the manager gates, so the manager must know about it.
#
#   DECIDED   such a contract that is NOT in `.targets` must be named in `.unmanagedTargets` with a
#             non-empty reason. A contract that is neither a target nor a written-down exclusion FAILS
#             BY NAME. Adding four names today fixes today; this is what stops the SEVENTH contract
#             drifting in silently, which is the failure this task is actually about.
#
# `.unmanagedTargets` is modelled on the `.unrestricted` section already in that file, down to the
# `_comment`: the repo already records exclusion-as-a-written-decision at the SELECTOR level, and this
# is the same idea one level up, at the CONTRACT level.
#
# CONTAINMENT IS ONE-WAY, exactly as `export-abis.sh`'s is. Every qualifying contract must be listed;
# a `.targets` row need NOT be a src/v2 contract. `RewardsDistributorLender` is a second DEPLOYMENT of
# `RewardsDistributor`, not a contract, and a set-equality check would fire on it on a clean tree.
#
# THE OTHER DIRECTION IS NOT HERE, AND IT IS NO LONGER NOWHERE. This script asks whether a contract that
# HAS a `restricted` selector is listed. It never asks whether a signature that IS listed still matches
# the contract. That second question needs the compiled ABI, which this script deliberately does not
# depend on -- it reads source only, so it runs on a tree that has never been built. So it lives in
# `test/v2/unit/ManifestResolvers.t.sol::test_everyListedSignatureIsStillOnTheCompiledAbi`, next to the
# resolver assertions that already read `out/`. If you are here because a `.targets` row drifted, that
# test is the one that fails; this one will not, and that is by design rather than by omission.
#
# WHAT THIS CANNOT SEE — an undocumented blind spot is how the defect it guards was born:
#   - a declaration whose `contract` keyword is not the first token on its line (`export-abis.sh`'s
#     containment check shares this limit and says so in its own comment);
#   - a `restricted` modifier reached through an alias, or applied by a base's `override` rather than
#     written at the declaration site;
#   - a contract gated by something OTHER than the manager — `onlyVault`, `onlyOwner`, `onlyRole` —
#     which is correct to leave out of `.targets` but which this check cannot distinguish from an
#     ungated one. That judgement is what `.unmanagedTargets` reasons are for, and why they are prose.
#
# bash + jq + awk, no python; bash 3.2 compatible (macOS), the convention export-abis.sh states.
# -------------------------------------------------------------------------------------------------
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
MANIFEST="$REPO/script/v2/roles.v8.json"
SCANNER="$REPO/script/v2/scan-v2-contracts.awk"
FIXTURES="$REPO/test/v2/fixtures/roles-targets"
SRC_V2="$REPO/src/v2"
# The fixture sources under test/v2/fixtures/roles-targets/src are named *.sol.fixture ON PURPOSE.
# foundry.toml compiles src/, script/ AND test/, and the pre-commit `forge fmt --check` hook matches
# ^(src/v2|script/v2|test/v2)/.*\.sol$ -- so a .sol fixture under test/ would be compiled and
# format-checked as if it were production Solidity. These files are parser input, not contracts.
SRC_GLOB='*.sol'
SELFTEST=0

die() {
  echo "check-roles-targets: $*" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)
      [ $# -ge 2 ] || die "--manifest needs a path"
      MANIFEST=$2; shift 2 ;;
    --manifest=*) MANIFEST=${1#*=}; shift ;;
    --src)
      [ $# -ge 2 ] || die "--src needs a directory"
      SRC_V2=$2; shift 2 ;;
    --src=*) SRC_V2=${1#*=}; shift ;;
    --ext)
      [ $# -ge 2 ] || die "--ext needs a glob"
      SRC_GLOB=$2; shift 2 ;;
    --ext=*) SRC_GLOB=${1#*=}; shift ;;
    --self-test) SELFTEST=1; shift ;;
    -h | --help) sed -n '2,/^# ----/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
[ -f "$SCANNER" ] || die "scanner not found: $SCANNER"

FAIL=0
reject() { # <rule> <name> <message>
  echo "REJECT $1 $2: $3" >&2
  FAIL=1
}

# --- the scan -------------------------------------------------------------------------------------
# Returns the D/M/R/S record stream for every .sol under src/v2 outside mocks/, and dies if the number
# of scan receipts does not match the number of files offered. A partial scan must never be mistaken
# for a clean tree.
scan_tree() { # <src dir>
  local src=$1 list count records scanned
  [ -d "$src" ] || die "src/v2 not found at $src: the containment check cannot run"
  list=$(find "$src" -name "$SRC_GLOB" -type f ! -path "$src/mocks/*" | LC_ALL=C sort)
  count=$(printf '%s\n' "$list" | grep -c '[^[:space:]]' || true)
  [ "$count" -gt 0 ] || die "no $SRC_GLOB file found under $src: the scan is broken, not the tree"
  records=$(
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      awk -v rel="${f#"$REPO"/}" -f "$SCANNER" "$f"
    done <<SCANLIST
$list
SCANLIST
  )
  scanned=$(printf '%s\n' "$records" | grep -c '^S|' || true)
  [ "$scanned" = "$count" ] ||
    die "scanned only $scanned of $count $SRC_GLOB files under $src: a partial scan is not a clean tree"
  printf '%s\n' "$records"
}

# --- inheritance ----------------------------------------------------------------------------------
# bash 3.2 has no associative arrays, so membership is grep over newline-delimited blobs, the same
# technique export-abis.sh uses. Depth is bounded by the visited list, so a cyclic `is` clause (which
# solc would reject anyway) cannot spin here.
RECORDS=""
has_restricted() { # <contract name> ; walks bases transitively
  local name=$1 visited=$2 bases b
  case "$visited" in *"|$name|"*) return 1 ;; esac
  visited="$visited|$name|"
  if printf '%s\n' "$RECORDS" | grep -q "^R|$name|"; then return 0; fi
  bases=$(printf '%s\n' "$RECORDS" | awk -F'|' -v n="$name" '$1=="D" && $2==n {print $6; exit}')
  for b in $bases; do
    if has_restricted "$b" "$visited"; then return 0; fi
  done
  return 1
}

check_manifest() { # <manifest> <src dir>
  local manifest=$1 src=$2
  FAIL=0
  [ -f "$manifest" ] || die "manifest not found: $manifest"
  jq -e . "$manifest" >/dev/null 2>&1 || die "$manifest is not valid JSON"
  jq -e '.targets | type == "object"' "$manifest" >/dev/null 2>&1 ||
    die "$manifest has no .targets object: this is not a v8 role manifest"

  RECORDS=$(scan_tree "$src")

  local targets excluded name loc
  targets=$(jq -r '.targets | keys[]' "$manifest")
  # `.unmanagedTargets` is optional so this check can run against an older manifest and say what is
  # missing rather than dying; a manifest without it simply has no written exclusions.
  excluded=$(jq -r 'if has("unmanagedTargets") then (.unmanagedTargets | keys[]) else empty end' "$manifest" |
    grep -v '^_' || true)

  # --- every non-abstract src/v2 contract ---------------------------------------------------------
  local decls
  decls=$(printf '%s\n' "$RECORDS" | awk -F'|' '$1=="D" && $3=="0" && $4=="contract" {print $2 "|" $5}')
  while IFS='|' read -r name loc; do
    [ -n "$name" ] || continue
    local in_targets=1 in_excluded=1 restricted=1 reason
    printf '%s\n' "$targets" | grep -qx "$name" && in_targets=0
    printf '%s\n' "$excluded" | grep -qx "$name" && in_excluded=0
    has_restricted "$name" "" && restricted=0

    if [ "$in_targets" = 0 ] && [ "$in_excluded" = 0 ]; then
      reject contradiction "$name" \
        "is in BOTH .targets and .unmanagedTargets; an exclusion and a mapping cannot both be true"
      continue
    fi

    if [ "$restricted" = 0 ]; then
      # THE HARD RULE. Has selectors the manager gates, so the manager must know about it.
      if [ "$in_targets" != 0 ]; then
        reject unlisted-restricted "$name" \
          "$loc declares or inherits a restricted selector but .targets does not list it, so AccessMatrix and VerifyV8 check group 4 never look at it"
      fi
      if [ "$in_excluded" = 0 ]; then
        reject excluded-but-restricted "$name" \
          "is written off in .unmanagedTargets but DOES have a restricted selector; the exclusion is no longer true"
      fi
    else
      # THE LEDGER RULE. No restricted selector is a legitimate reason to be absent -- but it has to
      # be a decision somebody wrote down, not a silence.
      if [ "$in_targets" != 0 ] && [ "$in_excluded" != 0 ]; then
        reject undecided "$name" \
          "$loc is in neither .targets nor .unmanagedTargets; if it is deliberately not manager-gated, say so there with a reason"
      fi
      if [ "$in_excluded" = 0 ]; then
        reason=$(jq -r --arg n "$name" '.unmanagedTargets[$n] // empty' "$manifest")
        case "$reason" in
          "" | null) reject exclusion-unreasoned "$name" "is in .unmanagedTargets with no reason written" ;;
        esac
      fi
    fi
  done <<DECLS
$decls
DECLS

  # --- stale exclusions ---------------------------------------------------------------------------
  # An exclusion for a contract that no longer exists is a decision about nothing, and it is exactly
  # the kind of row that makes the next reader trust the list less.
  local names
  names=$(printf '%s\n' "$RECORDS" | awk -F'|' '$1=="D" && $3=="0" && $4=="contract" {print $2}')
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf '%s\n' "$names" | grep -qx "$name" ||
      reject exclusion-stale "$name" "is named in .unmanagedTargets but no non-abstract contract under src/v2 declares it"
  done <<EXCL
$excluded
EXCL

  if [ "$FAIL" != 0 ]; then
    echo "check-roles-targets: $manifest does not contain src/v2" >&2
    return 1
  fi
  local nt ne
  nt=$(printf '%s\n' "$targets" | grep -c '[^[:space:]]' || true)
  ne=$(printf '%s\n' "$excluded" | grep -c '[^[:space:]]' || true)
  echo "check-roles-targets: $nt targets + $ne written exclusions cover every non-abstract src/v2 contract"
  return 0
}

# --- self-test --------------------------------------------------------------------------------------
if [ "$SELFTEST" = 1 ]; then
  [ -d "$FIXTURES" ] || die "fixture directory not found: $FIXTURES"
  st_pass=0; st_fail=0

  expect_ok() { # <manifest fixture> <src fixture dir>
    local name=$1 srcdir=$2 out
    if out=$("$0" --manifest "$FIXTURES/$name" --src "$FIXTURES/$srcdir" --ext '*.sol.fixture' 2>&1); then
      echo "  ok    $name accepted: $out"; st_pass=$((st_pass + 1))
    else
      echo "  FAIL  $name should be accepted but was refused:" >&2; printf '%s\n' "$out" >&2
      st_fail=$((st_fail + 1))
    fi
  }

  expect_reject() { # <manifest fixture> <src fixture dir> <rule>
    local name=$1 srcdir=$2 rule=$3 out rc
    set +e
    out=$("$0" --manifest "$FIXTURES/$name" --src "$FIXTURES/$srcdir" --ext '*.sol.fixture' 2>&1); rc=$?
    set -e
    if [ "$rc" = 0 ]; then
      echo "  FAIL  $name was ACCEPTED; expected rule '$rule' to refuse it" >&2; st_fail=$((st_fail + 1))
    elif printf '%s' "$out" | grep -q "REJECT $rule "; then
      echo "  ok    $name refused by $rule"; st_pass=$((st_pass + 1))
    else
      echo "  FAIL  $name was refused but NOT by '$rule':" >&2; printf '%s\n' "$out" >&2
      st_fail=$((st_fail + 1))
    fi
  }

  echo "check-roles-targets --self-test: fixtures in test/v2/fixtures/roles-targets"
  expect_ok      good.json          src
  expect_reject  unlisted.json      src  unlisted-restricted
  expect_reject  undecided.json     src  undecided
  expect_reject  unreasoned.json    src  exclusion-unreasoned
  expect_reject  contradiction.json src  contradiction
  expect_reject  lying.json         src  excluded-but-restricted
  expect_reject  stale.json         src  exclusion-stale
  echo "check-roles-targets --self-test: $st_pass passed, $st_fail failed"
  [ "$st_fail" = 0 ] || exit 1
  exit 0
fi

check_manifest "$MANIFEST" "$SRC_V2"
