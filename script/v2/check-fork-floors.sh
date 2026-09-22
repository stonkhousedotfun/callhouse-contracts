#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# check-fork-floors.sh — containment for the execution floor in test/v2/fork/*.t.sol.
#
# WHY THIS FILE EXISTS. Every fork suite guards its tests with `block.chainid != 4663 -> vm.skip(true)`.
# That is right on its own, but it means a run under `FOUNDRY_PROFILE=fork` that never reached a fork
# prints `0 failed`, exits 0, and is indistinguishable from a run that checked the chain. T-588 added
# `test/v2/fork/ForkFloor.sol` and a floor test to thirteen suites: a test with NO skip guard that
# calls `ForkFloor.requireExecutedAgainstRealFork(<witness>, "<Suite>")` and REVERTS, naming the suite,
# when a fork was intended and none is attached (or the fork serves no code at the witness).
#
# Nothing bound the floor to the directory. Within hours of T-588 landing, `EarnMorphoFork.t.sol` was
# added with the same skip-only shape and no floor (T-601's ledger entry), and three suites T-588 had
# deliberately excluded were never picked up. So four of sixteen suites could report green having run
# nothing, and the next new file would have done the same. This script is the sibling of
# `check-roles-targets.sh` and `export-abis.sh`'s manifest containment, and is deliberately the same
# shape: it enumerates the directory and refuses, BY NAME, every suite that lacks the floor.
#
#   script/v2/check-fork-floors.sh                 # check test/v2/fork
#   script/v2/check-fork-floors.sh --dir <d>       # check another directory of *.t.sol
#   script/v2/check-fork-floors.sh --self-test     # run the fixture suite, then exit
#
# THE TWO RULES, applied to every `*.t.sol` under the directory (`ForkFloor.sol` is a library, not a
# suite, and is not matched by that glob):
#
#   no-import   the file MUST import ForkFloor (`import {ForkFloor} from "./ForkFloor.sol";`).
#   no-floor    the file MUST contain a call to `ForkFloor.requireExecutedAgainstRealFork(`. The import
#               alone proves nothing; a suite can import the library and never state its floor.
#
# WHAT THIS CANNOT SEE — and it is worth knowing before a green line is trusted:
#   - WHETHER THE WITNESS IS HONEST. `requireExecutedAgainstRealFork(address(0), ...)` or `(address(this),
#     ...)` satisfies this grep and checks nothing. The witness must be an address the suite's own tests
#     read (ForkFloor.sol NatSpec). That is a reading judgement, recorded in each floor's comment.
#   - WHETHER THE FLOOR TEST CARRIES A SKIP GUARD. A floor called from inside `onlyFork` skips before it
#     can fire. This script does not parse modifiers; the floored-suite shape (a plain `public` test
#     named `test_fork_floor_*`) is the convention, and a reviewer reads it.
#   - A call reached through an alias or a wrapper function rather than the literal library call.
#   - `HouseVaultSettlement`'s placeholder floor (`requireFixtureFilledIn`) delegates to the ordinary
#     floor; that suite ALSO states the literal call, so this script reads it like every other.
#
# NEVER A LIST OF FILE NAMES. A copied list of the sixteen suites cannot see the seventeenth; the whole
# point is the file that has not been written yet. The directory is enumerated every run.
#
# SELF-TEST FIXTURES ARE DERIVED, NOT STORED. The live directory is the "good" case, so the self-test is
# red on a tree with an unfloored suite and green only once every suite has its floor. The failing
# shapes are minimal synthetic files written to a temporary directory: the check reads source text
# only, so a two-line fixture exercises exactly what a real suite would.
#
# bash 3.2 compatible (macOS); grep and find only, no jq, no python.
# -------------------------------------------------------------------------------------------------
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
DIR="$REPO/test/v2/fork"
SELFTEST=0

die() {
  echo "check-fork-floors: $*" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)
      [ $# -ge 2 ] || die "--dir needs a directory"
      DIR=$2; shift 2 ;;
    --dir=*) DIR=${1#*=}; shift ;;
    --self-test) SELFTEST=1; shift ;;
    -h | --help) sed -n '2,/^# ----/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

FAIL=0
reject() { # <rule> <file> <message>
  echo "REJECT $1 $2: $3" >&2
  FAIL=1
}

IMPORT_RE='^import[[:space:]]*{[[:space:]]*ForkFloor[[:space:]]*}[[:space:]]*from[[:space:]]*"\./ForkFloor\.sol"'
FLOOR_RE='ForkFloor\.requireExecutedAgainstRealFork[[:space:]]*\('

check_dir() { # <dir>
  local dir=$1 list count f rel n_ok
  FAIL=0
  [ -d "$dir" ] || die "fork directory not found: $dir"
  list=$(find "$dir" -maxdepth 1 -name '*.t.sol' -type f | LC_ALL=C sort)
  count=$(printf '%s\n' "$list" | grep -c '[^[:space:]]' || true)
  # Zero suites is a broken scan (wrong directory, wrong glob), never a clean tree.
  [ "$count" -gt 0 ] || die "no *.t.sol under $dir: the scan is broken, not the tree"
  n_ok=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel=${f#"$REPO"/}
    local has_import=1 has_floor=1
    grep -Eq "$IMPORT_RE" "$f" && has_import=0
    grep -Eq "$FLOOR_RE" "$f" && has_floor=0
    if [ "$has_import" != 0 ]; then
      reject no-import "$rel" "does not import ForkFloor, so it cannot state the execution floor; under FOUNDRY_PROFILE=fork with no fork attached it reports 0 failed having run nothing"
    fi
    if [ "$has_floor" != 0 ]; then
      reject no-floor "$rel" "never calls ForkFloor.requireExecutedAgainstRealFork; a run that skipped every test in it is indistinguishable from a run that checked the chain"
    fi
    [ "$has_import" = 0 ] && [ "$has_floor" = 0 ] && n_ok=$((n_ok + 1))
  done <<LIST
$list
LIST
  if [ "$FAIL" != 0 ]; then
    echo "check-fork-floors: $((count - n_ok)) of $count fork suites under ${dir#"$REPO"/} can report green having run nothing" >&2
    return 1
  fi
  echo "check-fork-floors: every one of the $count fork suites under ${dir#"$REPO"/} imports ForkFloor and states its floor"
  return 0
}

# --- self-test ---------------------------------------------------------------------------------------
if [ "$SELFTEST" = 1 ]; then
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/check-fork-floors.XXXXXX")
  trap 'rm -rf "$TMP"' EXIT
  st_pass=0; st_fail=0

  expect_ok() { # <label> <dir>
    local label=$1 out
    if out=$("$0" --dir "$2" 2>&1); then
      echo "  ok    $label accepted: $out"; st_pass=$((st_pass + 1))
    else
      echo "  FAIL  $label should be accepted but was refused:" >&2; printf '%s\n' "$out" >&2
      st_fail=$((st_fail + 1))
    fi
  }

  expect_reject() { # <label> <dir> <rule> <file basename>
    local label=$1 rule=$3 name=$4 out rc
    set +e
    out=$("$0" --dir "$2" 2>&1); rc=$?
    set -e
    if [ "$rc" = 0 ]; then
      echo "  FAIL  $label was ACCEPTED; expected '$rule' to refuse $name" >&2; st_fail=$((st_fail + 1))
    elif printf '%s' "$out" | grep -Eq "^REJECT $rule [^ ]*$name:"; then
      echo "  ok    $label refused by $rule naming $name"; st_pass=$((st_pass + 1))
    else
      echo "  FAIL  $label was refused but NOT by '$rule $name':" >&2; printf '%s\n' "$out" >&2
      st_fail=$((st_fail + 1))
    fi
  }

  # A minimal floored suite: the import and the literal call, nothing else. The check reads text only.
  write_floored() { # <path>
    cat > "$1" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ForkFloor} from "./ForkFloor.sol";

contract FixtureForkTest is Test {
    address internal constant WITNESS = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    function test_fork_floor_fixtureExecutedAgainstARealFork() public {
        ForkFloor.requireExecutedAgainstRealFork(WITNESS, "Fixture");
    }
}
SOL
  }

  echo "check-fork-floors --self-test: live directory ${DIR#"$REPO"/} plus derived fixtures in $TMP"

  # 1. the live directory: green only when every suite is floored.
  expect_ok "live test/v2/fork" "$DIR"

  # 2. a floored suite on its own passes.
  mkdir -p "$TMP/good"; write_floored "$TMP/good/GoodFork.t.sol"
  expect_ok "floored fixture suite" "$TMP/good"

  # 3. the import without the call: the T-OP-031 shape one step short.
  mkdir -p "$TMP/nofloor"; write_floored "$TMP/floored.tmp"
  grep -v 'ForkFloor.requireExecutedAgainstRealFork' "$TMP/floored.tmp" > "$TMP/nofloor/NoFloorFork.t.sol"
  grep -q 'import {ForkFloor}' "$TMP/nofloor/NoFloorFork.t.sol" || die "self-test: fixture lost its import"
  ! grep -q 'requireExecutedAgainstRealFork' "$TMP/nofloor/NoFloorFork.t.sol" || die "self-test: fixture kept the call"
  expect_reject "import but no floor call" "$TMP/nofloor" no-floor NoFloorFork.t.sol

  # 4. neither: the shape every unfloored suite had.
  mkdir -p "$TMP/neither"
  grep -v 'ForkFloor' "$TMP/floored.tmp" > "$TMP/neither/BareFork.t.sol"
  ! grep -q 'ForkFloor' "$TMP/neither/BareFork.t.sol" || die "self-test: fixture still mentions ForkFloor"
  expect_reject "neither import nor call" "$TMP/neither" no-import BareFork.t.sol
  expect_reject "neither import nor call (second rule)" "$TMP/neither" no-floor BareFork.t.sol

  # 5. one bad file among good ones is still named, and ForkFloor.sol itself is not a suite.
  mkdir -p "$TMP/mixed"; write_floored "$TMP/mixed/AFork.t.sol"; write_floored "$TMP/mixed/BFork.t.sol"
  cp "$TMP/neither/BareFork.t.sol" "$TMP/mixed/BareFork.t.sol"
  printf 'library ForkFloor {}\n' > "$TMP/mixed/ForkFloor.sol"
  expect_reject "one unfloored suite among floored ones" "$TMP/mixed" no-floor BareFork.t.sol

  # 6. an empty directory is a broken scan, not a clean tree.
  mkdir -p "$TMP/empty"
  set +e; out=$("$0" --dir "$TMP/empty" 2>&1); rc=$?; set -e
  if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q 'scan is broken'; then
    echo "  ok    empty directory dies as a broken scan"; st_pass=$((st_pass + 1))
  else
    echo "  FAIL  empty directory should die (exit 2) but got exit $rc: $out" >&2; st_fail=$((st_fail + 1))
  fi

  echo "check-fork-floors --self-test: $st_pass passed, $st_fail failed"
  [ "$st_fail" = 0 ] || exit 1
  exit 0
fi

check_dir "$DIR"
