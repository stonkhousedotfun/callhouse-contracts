#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# check-audit-response.sh — validates docs/audit-findings-v8.json, the v8 audit-response register.
#
# C8-14 turns an external audit report into fix commits, regression tests and owner-accepted
# rationales. The register is the machine-readable record of that: the auditor supplies ROWS, this
# repository supplies the COLUMNS. This checker is what stops a row from being half-filled — a
# `fixed` finding whose fix commit does not exist, a `accepted` one nobody signed, an interface
# change with no log entry.
#
#   script/v2/check-audit-response.sh                        # check docs/audit-findings-v8.json
#   script/v2/check-audit-response.sh --register <path>       # check another register
#   script/v2/check-audit-response.sh --final                 # additionally require reReviewed.date
#   script/v2/check-audit-response.sh --self-test             # run the fixture suite, then exit
#
# Exit 0 on a clean register and prints "<N> findings registered". Exit 1 on any rejection, one
# `REJECT <rule> <id>` line per problem so a self-test can assert WHICH rule fired, not just that
# something did. bash + jq only, no python; bash 3.2 compatible (macOS), the same rule
# script/v2/export-abis.sh states in its own header.
#
# THE jq NULL TRAP, which this checker exists in spite of: `jq -r '.findings[].fixCommit'` on a
# record that OMITS fixCommit prints the four-character string `null`, and `[ -n "null" ]` is TRUE.
# A checker written that way passes on exactly the incomplete record it exists to reject, and reports
# green. Every extraction here goes through `str()`, which is `// empty` plus an explicit `has()`
# test, so an absent key and a literal-null key both come back as the empty string. Fixtures
# `bad-fixcommit-absent.json` and `bad-fixcommit-null.json` are the two halves of that trap and the
# self-test asserts both are refused by name.
# -------------------------------------------------------------------------------------------------
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
REGISTER="$REPO/docs/audit-findings-v8.json"
FIXTURES="$REPO/test/v2/fixtures/audit-response"
FINAL=0
SELFTEST=0

die() {
  echo "check-audit-response: $*" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --register)
      [ $# -ge 2 ] || die "--register needs a path"
      REGISTER=$2
      shift 2
      ;;
    --register=*)
      REGISTER=${1#*=}
      shift
      ;;
    --final)
      FINAL=1
      shift
      ;;
    --self-test)
      SELFTEST=1
      shift
      ;;
    -h | --help)
      sed -n '2,/^# ----/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

FAIL=0
reject() { # <rule> <id> <message>
  echo "REJECT $1 $2: $3" >&2
  FAIL=1
}

# str <jq-path-expression> <record-json> -- the ONLY way this file reads a value.
#
# `// empty` collapses BOTH an absent key and a key whose value is literal JSON null to nothing, so
# the caller's `[ -n "$v" ]` means "present and non-empty" rather than "jq printed something".
# `-r` on a string prints it raw; on a number or boolean it prints its text, which is what the
# boolean and date fields want.
str() {
  printf '%s' "$2" | jq -r "($1) // empty"
}

# has_key <key> <record-json> -- presence, independent of value. Used only where the message should
# distinguish "you left it out" from "you left it blank"; the validity test is always str().
has_key() {
  printf '%s' "$2" | jq -e --arg k "$1" 'has($k)' >/dev/null 2>&1
}

check_register() { # <register path>
  local reg=$1
  FAIL=0

  [ -f "$reg" ] || die "register not found: $reg"
  jq -e . "$reg" >/dev/null 2>&1 || die "$reg is not valid JSON"

  # --- envelope ---------------------------------------------------------------------------------
  jq -e '.interfaceVersion == 8' "$reg" >/dev/null 2>&1 ||
    reject envelope-interfaceversion "-" "interfaceVersion must be 8"
  jq -e '.findings | type == "array"' "$reg" >/dev/null 2>&1 ||
    reject envelope-findings "-" "findings must be an array"
  jq -e 'has("auditor")' "$reg" >/dev/null 2>&1 ||
    reject envelope-auditor "-" "auditor key must be present (null until the engagement is named)"
  jq -e '.packetShas | type == "object"' "$reg" >/dev/null 2>&1 ||
    reject envelope-packetshas "-" "packetShas must be an object"
  local repo_key
  for repo_key in contracts app site docs; do
    jq -e --arg k "$repo_key" '.packetShas | has($k)' "$reg" >/dev/null 2>&1 ||
      reject envelope-packetshas "-" "packetShas.$repo_key key must be present (null until the packet is cut)"
  done

  # A malformed envelope makes the per-record walk meaningless, so stop here rather than emit noise.
  if [ "$FAIL" != 0 ]; then
    echo "check-audit-response: $reg is not a v8 audit-response register" >&2
    return 1
  fi

  local count
  count=$(jq -r '.findings | length' "$reg")

  # --- records ----------------------------------------------------------------------------------
  # One record per line as compact JSON. `jq -c` never emits a newline inside a value, so a while-read
  # loop is safe here, and the loop body runs in THIS shell (not a subshell) because the redirection
  # is a here-document rather than a pipe -- otherwise every `FAIL=1` would be discarded and the
  # checker would report green with rejections on screen. That is the failure this whole file guards
  # against, so it must not be the shape of the file itself.
  local records
  records=$(jq -c '.findings[]' "$reg")

  local seen_ids=""
  local rec id sev title status scope_n fix_commit reg_test rationale owner_date iface iface_entry rereviewed
  local test_file test_name
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue

    id=$(str '.id' "$rec")
    if [ -z "$id" ]; then
      reject id-missing "?" "every record needs a non-empty id"
      id="?"
    else
      case " $seen_ids " in
        *" $id "*) reject id-duplicate "$id" "id is used by more than one record" ;;
      esac
      seen_ids="$seen_ids $id"
    fi

    sev=$(str '.severity' "$rec")
    case "$sev" in
      critical | high | medium | low | informational) ;;
      *) reject severity-invalid "$id" "severity must be critical|high|medium|low|informational, got '${sev:-<unset>}'" ;;
    esac

    title=$(str '.title' "$rec")
    [ -n "$title" ] || reject title-empty "$id" "title must be a non-empty string"

    scope_n=$(printf '%s' "$rec" | jq -r '[.scope // empty | if type == "array" then .[] else empty end] | length')
    if [ "$scope_n" = 0 ]; then
      reject scope-empty "$id" "scope must list at least one repo-relative path"
    else
      local p
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$p" in
          src/v2/* | script/v2/*) ;;
          *) reject scope-outside "$id" "scope path '$p' is not under src/v2 or script/v2" ;;
        esac
      done <<SCOPE_EOF
$(printf '%s' "$rec" | jq -r '[.scope // empty | if type == "array" then .[] else empty end] | .[] | select(type == "string")')
SCOPE_EOF
    fi

    # --- status: the rule that makes every rule below reachable ---------------------------------
    # A record with no status, or one still `open`, is not a response -- it is the finding restated.
    status=$(str '.status' "$rec")
    case "$status" in
      fixed | accepted | disputed | out-of-scope) ;;
      open) reject status-open "$id" "status is still 'open'; a registered finding must be fixed, accepted, disputed or out-of-scope" ;;
      "") reject status-unset "$id" "status is unset" ;;
      *) reject status-invalid "$id" "status must be fixed|accepted|disputed|out-of-scope, got '$status'" ;;
    esac

    if [ "$status" = fixed ]; then
      fix_commit=$(str '.fixCommit' "$rec")
      if [ -z "$fix_commit" ]; then
        if has_key fixCommit "$rec"; then
          reject fixcommit-missing "$id" "status is 'fixed' but fixCommit is null or empty"
        else
          reject fixcommit-missing "$id" "status is 'fixed' but there is no fixCommit key"
        fi
      elif ! git -C "$REPO" cat-file -e "${fix_commit}^{commit}" 2>/dev/null; then
        reject fixcommit-unresolvable "$id" "fixCommit '$fix_commit' does not resolve to a commit in this repository"
      fi

      reg_test=$(str '.regressionTest' "$rec")
      if [ -z "$reg_test" ]; then
        reject regressiontest-missing "$id" "status is 'fixed' but regressionTest is unset"
      else
        case "$reg_test" in
          test/v2/*.t.sol::*)
            test_file=${reg_test%%::*}
            test_name=${reg_test##*::}
            if [ -z "$test_name" ]; then
              reject regressiontest-malformed "$id" "regressionTest '$reg_test' names no test function after '::'"
            elif [ ! -f "$REPO/$test_file" ]; then
              reject regressiontest-file-missing "$id" "regressionTest names $test_file, which does not exist"
            elif ! grep -q "function $test_name" "$REPO/$test_file"; then
              reject regressiontest-function-missing "$id" "$test_file contains no 'function $test_name'"
            fi
            ;;
          *) reject regressiontest-malformed "$id" "regressionTest must read test/v2/<file>.t.sol::<testName>, got '$reg_test'" ;;
        esac
      fi
    fi

    if [ "$status" = accepted ]; then
      rationale=$(str '.rationale' "$rec")
      [ -n "$rationale" ] || reject rationale-empty "$id" "status is 'accepted' but rationale is empty"
      owner_date=$(str '.ownerAccepted.date' "$rec")
      [ -n "$owner_date" ] || reject owneraccepted-date-missing "$id" "status is 'accepted' but ownerAccepted.date is unset"
    fi

    # --- interface impact -------------------------------------------------------------------------
    # `true` here means a selector, event or constant moved, which every consumer regenerates against.
    # The log entry is the only durable record of that, so an unlogged move is refused.
    iface=$(str '.interfaceImpact' "$rec")
    if [ "$iface" = true ]; then
      iface_entry=$(str '.interfaceLogEntry' "$rec")
      [ -n "$iface_entry" ] ||
        reject interfacelogentry-missing "$id" "interfaceImpact is true but interfaceLogEntry is empty"
    fi

    if [ "$FINAL" = 1 ]; then
      rereviewed=$(str '.reReviewed.date' "$rec")
      [ -n "$rereviewed" ] ||
        reject rereviewed-date-missing "$id" "--final requires reReviewed.date; the auditor has not re-reviewed this fix"
    fi
  done <<RECORDS_EOF
$records
RECORDS_EOF

  if [ "$FAIL" != 0 ]; then
    echo "check-audit-response: $reg is incomplete" >&2
    return 1
  fi
  echo "$count findings registered"
  return 0
}

# --- self-test ------------------------------------------------------------------------------------
# Each bad fixture is asserted to be refused BY ITS RULE NAME. Asserting only the exit code cannot
# tell you which rule fired, so a checker whose rules had all collapsed into one would still pass.
if [ "$SELFTEST" = 1 ]; then
  [ -d "$FIXTURES" ] || die "fixture directory not found: $FIXTURES"
  st_pass=0
  st_fail=0

  expect_ok() { # <fixture> [extra flags]
    local name=$1
    local f="$FIXTURES/$name"
    shift
    local out
    if out=$("$0" --register "$f" ${@+"$@"} 2>&1); then
      echo "  ok    $name accepted: $out"
      st_pass=$((st_pass + 1))
    else
      echo "  FAIL  $name should be accepted but was refused:" >&2
      printf '%s\n' "$out" >&2
      st_fail=$((st_fail + 1))
    fi
  }

  expect_reject() { # <fixture> <rule> [extra flags]
    local name=$1
    local rule=$2
    local f="$FIXTURES/$name"
    shift 2
    local out rc
    set +e
    out=$("$0" --register "$f" ${@+"$@"} 2>&1)
    rc=$?
    set -e
    if [ "$rc" = 0 ]; then
      echo "  FAIL  $name was ACCEPTED; expected rule '$rule' to refuse it" >&2
      st_fail=$((st_fail + 1))
    elif printf '%s' "$out" | grep -q "REJECT $rule "; then
      echo "  ok    $name refused by $rule"
      st_pass=$((st_pass + 1))
    else
      echo "  FAIL  $name was refused but NOT by '$rule':" >&2
      printf '%s\n' "$out" >&2
      st_fail=$((st_fail + 1))
    fi
  }

  echo "check-audit-response --self-test: fixtures in test/v2/fixtures/audit-response"
  expect_ok valid-empty.json
  expect_ok valid-populated.json
  expect_ok valid-final.json --final

  expect_reject bad-status-unset.json status-unset
  expect_reject bad-status-open.json status-open
  expect_reject bad-status-invalid.json status-invalid
  # The two halves of the jq null trap: the key omitted, and the key present as literal null.
  expect_reject bad-fixcommit-absent.json fixcommit-missing
  expect_reject bad-fixcommit-null.json fixcommit-missing
  expect_reject bad-fixcommit-unresolvable.json fixcommit-unresolvable
  expect_reject bad-regressiontest-missing.json regressiontest-missing
  expect_reject bad-regressiontest-malformed.json regressiontest-malformed
  expect_reject bad-regressiontest-file.json regressiontest-file-missing
  expect_reject bad-regressiontest-function.json regressiontest-function-missing
  expect_reject bad-accepted-rationale.json rationale-empty
  expect_reject bad-accepted-ownerdate.json owneraccepted-date-missing
  expect_reject bad-interface-logentry.json interfacelogentry-missing
  expect_reject bad-severity.json severity-invalid
  expect_reject bad-id-duplicate.json id-duplicate
  expect_reject bad-id-missing.json id-missing
  expect_reject bad-title-empty.json title-empty
  expect_reject bad-scope-empty.json scope-empty
  expect_reject bad-scope-outside.json scope-outside
  expect_reject bad-envelope-version.json envelope-interfaceversion
  expect_reject bad-envelope-packetshas.json envelope-packetshas
  # Same file, two verdicts: valid without --final, refused with it.
  expect_reject valid-populated.json rereviewed-date-missing --final

  echo "check-audit-response --self-test: $st_pass passed, $st_fail failed"
  [ "$st_fail" = 0 ] || exit 1
  exit 0
fi

check_register "$REGISTER"
