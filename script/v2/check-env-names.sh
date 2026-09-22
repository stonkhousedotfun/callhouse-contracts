#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# check-env-names.sh — the registry-key -> V2_* env seam between DeployV2Batch.sh and V2DeployBase.sol.
#
# WHY THIS FILE EXISTS. `DeployV2Batch.sh` records every deployed contract in the registry under a key
# (`CONTRACT_KEYS`, plus the six operator-supplied `EXTERNAL_KEYS`), and `export_contracts` hands each
# one to the forge scripts as an environment variable whose name `env_name()` picks. On the other side
# `V2DeployBase.contractsFromEnv()` reads a fixed list of `vm.envOr("V2_...")` names. Nothing bound
# the two lists together. So when the v8 PayoutRouter got its own env name (`V2_PAYOUT_ROUTER`, because
# `V2_PAYOUT_ADAPTER` still names the v7 adapter on live 4663 and a resumed v7 set must not flow into a
# v8 run), the wrapper kept exporting the registry's `payoutAdapter` under the OLD name, which no forge
# script reads. Every wrapper-driven `--resume` or register step therefore saw `c.payoutRouter ==
# address(0)`: a resume would deploy a second router while the registry still named the first, and
# `RegisterMarkets` would refuse with `V2_PAYOUT_ROUTER is zero` (T-OP-022).
#
# An env name that occurs exactly once in the repository has no reader by definition. That is a family
# of defect, not a one-off, and a copied list of the 22 names cannot see it: it would have passed at the
# tip this was written against. So this check READS both sides from the files that define them and
# never carries a list of its own.
#
#   script/v2/check-env-names.sh                     # check the repo
#   script/v2/check-env-names.sh --wrapper <f> --base <f> [--lib <rel>=<f>]...
#   script/v2/check-env-names.sh --self-test         # run the fixture suite, then exit
#
# THE TWO RULES.
#
#   unread      every name `env_name()` emits for a `CONTRACT_KEYS` / `EXTERNAL_KEYS` key MUST be read
#               by a `vm.envOr("...")` inside `contractsFromEnv()` in V2DeployBase.sol. An exported
#               name nobody reads is an address that never reaches a forge step.
#
#   collision   the emitted names MUST be pairwise distinct. Two keys collapsing onto one name means the
#               second export silently overwrites the first and one contract is lost.
#
# A key with no `env_name()` case at all fails as `unmapped`: `export "=0x..."` is a bash error the
# wrapper would only meet on a live run.
#
# CONTAINMENT IS ONE-WAY, as in check-roles-targets.sh. Every emitted name must be read; a name that
# `contractsFromEnv()` reads need NOT be emitted by the wrapper (an operator may set it by hand, and
# `--deploy-only` runs start with all of them empty). If a reader disappears, the `unread` rule fires
# on the wrapper side for that key, which is the direction that matters.
#
# HOW THE TWO SIDES ARE READ. `CONTRACT_KEYS=`, `EXTERNAL_KEYS=` and the `env_name()` function body are
# lifted by line pattern and `eval`ed here — the same technique `batch-refusals.sh` uses for
# `CONTRACT_KEYS` — so this script never sources the wrapper (which would run it). THE WRAPPER AND THE
# LIB IT SOURCES ARE ONE UNION (T-OP-149): T-OP-113 moved all three anchors out of `DeployV2Batch.sh`
# into `script/v2/lib/registry-env.sh`, and a scan of the wrapper alone died `found 0` at its first
# anchor — in CI (`ci.yml`) and in `rehearse-v2.sh` — from the moment that landed. The libs are
# DERIVED from the wrapper's own `. "$ROOT/script/v2/lib/<lib>"` lines (all of them: the wrapper
# sources more than one, and naming the right one here would be the hardcode this row forbids), and
# each anchor must occur exactly once across wrapper + every sourced lib, whichever file carries it
# (the carrying file is named in the output). `--lib <rel>=<f>` substitutes a fixture for ONE sourced
# lib (`<rel>` as the wrapper writes it, e.g. `script/v2/lib/registry-env.sh`) and the rest of the union
# is still scanned; the same shape as `check-deploy-inputs.sh` (T-OP-137). It is never the default. The reader
# names are the `vm.envOr("V2_...")` literals between `function contractsFromEnv(` and the closing brace
# of that function, and nothing outside it: the role, external-dependency and parameter readers use
# other names on purpose and are not this seam.
#
# WHAT THIS CANNOT SEE:
#   - a wrapper that exports a name through some path other than `export_contracts` / `env_name()`;
#   - a key that is removed from CONTRACT_KEYS/EXTERNAL_KEYS altogether: containment is one-way, so its
#     reader simply becomes a reader nobody feeds. That is REPORTED (the `not emitted by any key` line
#     and the key count), never refused — an operator may set such a name by hand;
#   - a reader built with a non-literal name (there are none today; a build would be needed to see one);
#   - whether the forge script that READS a name also USES the field — that is a Solidity question and
#     lives in the preflight tests, not here.
#
# SELF-TEST FIXTURES ARE DERIVED, NOT STORED. Each fixture is a copy of the real wrapper or base with one
# `sed` edit whose anchor is asserted to match exactly once before the copy is checked, so the fixtures
# cannot drift away from the files they stand in for, and a fixture whose edit did not land is a loud
# failure rather than a second copy of the good file.
#
# bash 3.2 compatible (macOS): no associative arrays, membership is grep over newline-delimited blobs.
# -------------------------------------------------------------------------------------------------
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
WRAPPER="$REPO/script/v2/DeployV2Batch.sh"
BASE="$REPO/script/v2/lib/V2DeployBase.sol"
LIB_OVERRIDES=""   # `<rel>=<path>` lines; the libs themselves are derived from the wrapper's source lines
SELFTEST=0

die() {
  echo "check-env-names: $*" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --wrapper)
      [ $# -ge 2 ] || die "--wrapper needs a path"
      WRAPPER=$2; shift 2 ;;
    --wrapper=*) WRAPPER=${1#*=}; shift ;;
    --base)
      [ $# -ge 2 ] || die "--base needs a path"
      BASE=$2; shift 2 ;;
    --base=*) BASE=${1#*=}; shift ;;
    --lib)
      [ $# -ge 2 ] || die "--lib needs <rel>=<path>"
      case "$2" in *=*) ;; *) die "--lib needs <rel>=<path>, got '$2'" ;; esac
      LIB_OVERRIDES="$LIB_OVERRIDES$2
"; shift 2 ;;
    --self-test) SELFTEST=1; shift ;;
    -h | --help) sed -n '2,/^# ----/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

FAIL=0
reject() { # <rule> <name> <message>
  echo "REJECT $1 $2: $3" >&2
  FAIL=1
}

# --- the wrapper side ------------------------------------------------------------------------------
# The libs the wrapper sources, derived from the wrapper's own `. "$ROOT/script/v2/lib/<lib>"` lines
# — every one of them, one per line. `$ROOT` in the wrapper is the repository root
# (`cd "$(dirname "$0")/../.."`), so each path is resolved against the wrapper's own repo when it has
# the file there, else against this repo — a fixture copy of the wrapper in a temp directory still
# finds the live libs. At least one such line, or nothing can be derived.
SOURCE_LINE='^[[:space:]]*(\.|source)[[:space:]]+"\$ROOT/[^"]+"'
libs_of() { # <wrapper path> -> the sourced lib paths on stdout, one per line, in source order
  local w=$1 n rel wroot path override
  n=$(grep -cE "$SOURCE_LINE" "$w" || true)
  [ "$n" -ge 1 ] || die "no '. \"\$ROOT/<lib>\"' source line in $w: the libs it reads CONTRACT_KEYS/EXTERNAL_KEYS/env_name() from cannot be derived"
  wroot=$(cd "$(dirname "$w")/../.." 2>/dev/null && pwd || true)
  grep -E "$SOURCE_LINE" "$w" | sed -E 's|^[[:space:]]*(\.\|source)[[:space:]]+"\$ROOT/([^"]+)".*$|\2|' | while IFS= read -r rel; do
    override=$(printf '%s\n' "$LIB_OVERRIDES" | awk -F= -v r="$rel" '$1 == r {sub(/^[^=]*=/, ""); print; exit}')
    if [ -n "$override" ]; then path=$override
    elif [ -n "$wroot" ] && [ -f "$wroot/$rel" ]; then path="$wroot/$rel"
    else path="$REPO/$rel"; fi
    echo "$path"
  done
  # An override naming a lib the wrapper does not source is a typo in a fixture, not a no-op.
  printf '%s\n' "$LIB_OVERRIDES" | while IFS= read -r override; do
    [ -n "$override" ] || continue
    grep -E "$SOURCE_LINE" "$w" | grep -qF -- "\$ROOT/${override%%=*}\"" || die "--lib ${override%%=*}=...: the wrapper does not source \$ROOT/${override%%=*}"
  done
}

# Lift the two key lists and the env_name() body by line pattern from WHICHEVER of the wrapper and its
# sourced libs carries each anchor. Each must be found exactly once across the union; an anchor that
# moved out of all of them, or that two of them carry, is a check that cannot run, not a clean tree.
CARRIER_KEYS=""; CARRIER_EXT=""; CARRIER_FN=""
carrier_of() { # <pattern> <label> <file>... -> the one file carrying the anchor on stdout
  local pat=$1 label=$2 f n total=0 carrier="" where=""
  shift 2
  for f in "$@"; do
    n=$(grep -c -- "$pat" "$f" || true)
    total=$((total + n))
    where="$where${where:+, }${f#"$REPO"/} ($n)"
    [ "$n" = 0 ] || carrier=$f
  done
  [ "$total" = 1 ] || die "expected exactly one $label line across $where, found $total"
  echo "$carrier"
}
lift_wrapper() { # <wrapper path>  (the union: the wrapper and every lib it sources, --lib overrides applied)
  local w=$1 l keys ext fn libs
  [ -f "$w" ] || die "wrapper not found: $w"
  libs=$(libs_of "$w")
  for l in $libs; do [ -f "$l" ] || die "a lib $w sources is not a file: $l"; done
  # shellcheck disable=SC2086
  CARRIER_KEYS=$(carrier_of '^CONTRACT_KEYS=' '^CONTRACT_KEYS=' "$w" $libs)
  # shellcheck disable=SC2086
  CARRIER_EXT=$(carrier_of '^EXTERNAL_KEYS=' '^EXTERNAL_KEYS=' "$w" $libs)
  # shellcheck disable=SC2086
  CARRIER_FN=$(carrier_of '^env_name()' '^env_name() definition' "$w" $libs)
  keys=$(grep '^CONTRACT_KEYS=' "$CARRIER_KEYS")
  ext=$(grep '^EXTERNAL_KEYS=' "$CARRIER_EXT")
  fn=$(awk '/^env_name\(\)/{p=1} p{print} p&&/^}/{exit}' "$CARRIER_FN")
  printf '%s\n' "$fn" | grep -q '^}' || die "env_name() in $CARRIER_FN has no closing brace on its own line"
  # The lifted text is three shell fragments: two string assignments and one function whose body is a
  # single `case`. Nothing else from the wrapper or the lib is evaluated.
  eval "$keys"
  eval "$ext"
  eval "$fn"
  [ -n "${CONTRACT_KEYS:-}" ] || die "CONTRACT_KEYS is empty after lifting it from $CARRIER_KEYS"
  [ -n "${EXTERNAL_KEYS:-}" ] || die "EXTERNAL_KEYS is empty after lifting it from $CARRIER_EXT"
}

# --- the reader side -------------------------------------------------------------------------------
# Every vm.envOr("V2_...") literal inside contractsFromEnv(), one per line.
readers_of() { # <base path>
  local b=$1 body n
  [ -f "$b" ] || die "V2DeployBase not found: $b"
  n=$(grep -c 'function contractsFromEnv(' "$b" || true)
  [ "$n" = 1 ] || die "expected exactly one 'function contractsFromEnv(' in $b, found $n"
  body=$(awk '/function contractsFromEnv\(/{p=1} p{print} p&&/^    }/{exit}' "$b")
  printf '%s\n' "$body" | grep -q '^    }' || die "contractsFromEnv() in $b has no closing brace at 4-space indent"
  printf '%s\n' "$body" | grep -o 'vm\.envOr("V2_[A-Z0-9_]*"' | sed 's/^vm\.envOr("//; s/"$//' | LC_ALL=C sort -u
}

check_seam() { # <wrapper> <base>
  local w=$1 b=$2 readers emitted k name nkeys nread dup unfed
  FAIL=0
  lift_wrapper "$w"
  echo "check-env-names: CONTRACT_KEYS from ${CARRIER_KEYS#"$REPO"/}, EXTERNAL_KEYS from ${CARRIER_EXT#"$REPO"/}, env_name() from ${CARRIER_FN#"$REPO"/}"
  readers=$(readers_of "$b")
  nread=$(printf '%s\n' "$readers" | grep -c '[^[:space:]]' || true)
  [ "$nread" -gt 0 ] || die "contractsFromEnv() in $b reads no vm.envOr(\"V2_...\") name: the reader scan is broken, not the tree"

  emitted=""
  nkeys=0
  for k in $CONTRACT_KEYS $EXTERNAL_KEYS; do
    nkeys=$((nkeys + 1))
    name=$(env_name "$k")
    if [ -z "$name" ]; then
      reject unmapped "$k" "is in CONTRACT_KEYS/EXTERNAL_KEYS but env_name() has no case for it; export_contracts would run 'export \"=<addr>\"'"
      continue
    fi
    emitted="$emitted$k=$name
"
    # THE RULE THIS FILE EXISTS FOR. An exported name nobody reads never reaches a forge step.
    printf '%s\n' "$readers" | grep -qx "$name" ||
      reject unread "$name" "is what env_name() emits for registry key '$k', but contractsFromEnv() in ${b#"$REPO"/} never reads it, so every wrapper-driven forge step sees address(0) for that contract"
  done

  # Pairwise distinct: two keys on one name means the later export overwrites the earlier one.
  dup=$(printf '%s' "$emitted" | awk -F= 'NF==2 {print $2}' | LC_ALL=C sort | uniq -d || true)
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    local ks
    ks=$(printf '%s' "$emitted" | awk -F= -v n="$name" 'NF==2 && $2==n {print $1}' | tr '\n' ' ')
    reject collision "$name" "is emitted by more than one registry key (${ks% }); the later export overwrites the earlier one"
  done <<DUPS
$dup
DUPS

  if [ "$FAIL" != 0 ]; then
    echo "check-env-names: ${w#"$REPO"/} and ${b#"$REPO"/} disagree on the V2_* seam" >&2
    return 1
  fi
  # Readers no key feeds. Containment is one-way by design, so this is a REPORT, not a rejection — but
  # it is how a key that quietly left CONTRACT_KEYS/EXTERNAL_KEYS shows up: its name moves onto this
  # line and the key count above drops by one.
  unfed=$(printf '%s\n' "$readers" | while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf '%s' "$emitted" | awk -F= -v n="$name" 'NF==2 && $2==n {found=1} END {exit !found}' || echo "$name"
  done | tr '\n' ' ')
  echo "check-env-names: $nkeys registry keys emit $nkeys distinct V2_* names, every one read by contractsFromEnv() ($nread readers)"
  [ -z "${unfed% }" ] || echo "check-env-names: $(printf '%s\n' "${unfed% }" | wc -w | tr -d ' ') reader(s) not emitted by any key: ${unfed% }"
  return 0
}

# --- self-test ---------------------------------------------------------------------------------------
# Fixtures are copies of the REAL wrapper and base, each with one asserted single-anchor edit, made in a
# temporary directory and removed afterwards. The good case is the live pair itself, so the self-test is
# red on a tree where the seam is broken and green only once it is fixed.
if [ "$SELFTEST" = 1 ]; then
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/check-env-names.XXXXXX")
  trap 'rm -rf "$TMP"' EXIT
  st_pass=0; st_fail=0

  mutate() { # <src> <dst> <sed script> <anchor regex> ; the anchor must match exactly once, and the edit must land
    local src=$1 dst=$2 script=$3 anchor=$4 n
    n=$(grep -c -- "$anchor" "$src" || true)
    [ "$n" = 1 ] || die "self-test: anchor '$anchor' matched $n lines in $src, expected exactly 1; fixture cannot be built"
    sed -e "$script" "$src" > "$dst"
    cmp -s "$src" "$dst" && die "self-test: edit '$script' did not change $src; the fixture would be a copy of the good file"
    return 0
  }

  expect_ok() { # <label> <wrapper> <base> [<lib override rel=path>] [<required output fragment>]
    local label=$1 want=${5:-} out
    if out=$("$0" --wrapper "$2" --base "$3" ${4:+--lib "$4"} 2>&1); then
      if [ -n "$want" ] && ! printf '%s\n' "$out" | grep -qF -- "$want"; then
        echo "  FAIL  $label accepted but did not say \"$want\":" >&2; printf '%s\n' "$out" >&2; st_fail=$((st_fail + 1))
      else
        echo "  ok    $label accepted: $(printf '%s\n' "$out" | tail -1)"; st_pass=$((st_pass + 1))
      fi
    else
      echo "  FAIL  $label should be accepted but was refused:" >&2; printf '%s\n' "$out" >&2
      st_fail=$((st_fail + 1))
    fi
  }

  expect_die() { # <label> <wrapper> <base> <lib or ""> <message fragment> ; exit 2 (cannot run), not a REJECT
    local label=$1 want=$5 out rc
    set +e
    out=$("$0" --wrapper "$2" --base "$3" ${4:+--lib "$4"} 2>&1); rc=$?
    set -e
    if [ "$rc" = 2 ] && printf '%s' "$out" | grep -qF -- "$want"; then
      echo "  ok    $label died as it must: $(printf '%s\n' "$out" | grep -F -- "$want" | head -1)"; st_pass=$((st_pass + 1))
    else
      echo "  FAIL  $label: expected exit 2 with \"$want\", got exit $rc:" >&2; printf '%s\n' "$out" >&2; st_fail=$((st_fail + 1))
    fi
  }

  expect_reject() { # <label> <wrapper> <base> <rule> <name> [<lib>]
    local label=$1 rule=$4 name=$5 out rc
    set +e
    out=$("$0" --wrapper "$2" --base "$3" ${6:+--lib "$6"} 2>&1); rc=$?
    set -e
    if [ "$rc" = 0 ]; then
      echo "  FAIL  $label was ACCEPTED; expected '$rule $name' to refuse it" >&2; st_fail=$((st_fail + 1))
    elif printf '%s' "$out" | grep -q "^REJECT $rule $name:"; then
      echo "  ok    $label refused by $rule naming $name"; st_pass=$((st_pass + 1))
    else
      echo "  FAIL  $label was refused but NOT by '$rule $name':" >&2; printf '%s\n' "$out" >&2
      st_fail=$((st_fail + 1))
    fi
  }

  # The fixtures edit WHICHEVER file carries each anchor today (the lib since T-OP-113), found the same
  # way the check itself finds it, so a future move of an anchor back into the wrapper does not turn
  # these into copies of the good files.
  lift_wrapper "$WRAPPER"
  FN_FILE=$CARRIER_FN; KEYS_FILE=$CARRIER_KEYS
  # The override key for a fixture that stands in for the carrying file: its path as the wrapper
  # sources it (relative to the wrapper's root). The wrapper itself cannot be overridden this way; if an
  # anchor ever moves back into the wrapper, the fixtures that edit it use --wrapper instead.
  rel_of() { # <path under the wrapper's root> -> <rel>
    local root; root=$(cd "$(dirname "$WRAPPER")/../.." && pwd); printf '%s' "${1#"$root"/}"
  }
  FN_REL=$(rel_of "$FN_FILE"); KEYS_REL=$(rel_of "$KEYS_FILE")
  echo "check-env-names --self-test: fixtures derived from ${WRAPPER#"$REPO"/}, ${KEYS_FILE#"$REPO"/} and ${BASE#"$REPO"/} in $TMP"
  # 1. the live triple: green only when the seam is whole, and the carrying files are named.
  expect_ok "live wrapper + derived lib + live base" "$WRAPPER" "$BASE" "" "env_name() from ${FN_FILE#"$REPO"/}"

  # 2. the T-OP-022 defect put back: payoutAdapter exported under the v7 name nobody reads.
  mutate "$FN_FILE" "$TMP/fn-payout-adapter.sh" \
    's/payoutAdapter) echo V2_PAYOUT_ROUTER ;;/payoutAdapter) echo V2_PAYOUT_ADAPTER ;;/' \
    'payoutAdapter) echo V2_PAYOUT_ROUTER ;;'
  expect_reject "env_name() emits V2_PAYOUT_ADAPTER for payoutAdapter" "$WRAPPER" "$BASE" unread V2_PAYOUT_ADAPTER "$FN_REL=$TMP/fn-payout-adapter.sh"

  # 3. two keys on one name: makerVault collapsed onto makerRegistry's name.
  mutate "$FN_FILE" "$TMP/fn-collision.sh" \
    's/makerVault) echo V2_MAKER_VAULT ;;/makerVault) echo V2_MAKER_REGISTRY ;;/' \
    'makerVault) echo V2_MAKER_VAULT ;;'
  expect_reject "makerVault and makerRegistry both emit V2_MAKER_REGISTRY" "$WRAPPER" "$BASE" collision V2_MAKER_REGISTRY "$FN_REL=$TMP/fn-collision.sh"

  # 4. a key added to CONTRACT_KEYS with no env_name() case.
  mutate "$KEYS_FILE" "$TMP/keys-unmapped.sh" \
    's/^CONTRACT_KEYS="/CONTRACT_KEYS="newThing /' \
    '^CONTRACT_KEYS="'
  expect_reject "CONTRACT_KEYS gains newThing with no env_name case" "$WRAPPER" "$BASE" unmapped newThing "$KEYS_REL=$TMP/keys-unmapped.sh"

  # 5. the reader side loses V2_PAYOUT_ROUTER: the same defect from the other end.
  mutate "$BASE" "$TMP/b-no-router.sol" \
    '/c\.payoutRouter = vm\.envOr("V2_PAYOUT_ROUTER", address(0));/d' \
    'c\.payoutRouter = vm\.envOr("V2_PAYOUT_ROUTER", address(0));'
  expect_reject "V2DeployBase stops reading V2_PAYOUT_ROUTER" "$WRAPPER" "$TMP/b-no-router.sol" unread V2_PAYOUT_ROUTER

  # 6. T-OP-149 prove-by-breaking (a): a WRAPPER-ONLY scan. The lib is replaced by an empty file, so the
  #    union carries no anchor at all -- exactly what a scan of the wrapper alone saw after T-OP-113 --
  #    and the check must DIE at the first anchor step (exit 2), never reach a verdict.
  : > "$TMP/lib-empty.sh"
  expect_die "wrapper-only scan (empty lib) dies at the anchor step" "$WRAPPER" "$BASE" "$KEYS_REL=$TMP/lib-empty.sh" \
    "expected exactly one ^CONTRACT_KEYS= line across"

  # 7. T-OP-149 prove-by-breaking (b): one key hidden in a scratch lib. payoutAdapter leaves
  #    CONTRACT_KEYS; the derived name set shrinks by one and the script SAYS so -- the key count drops
  #    and V2_PAYOUT_ROUTER is reported as a reader no key feeds. Counts are derived from the live set.
  live_n=$(printf '%s\n' $CONTRACT_KEYS $EXTERNAL_KEYS | grep -c .)
  mutate "$KEYS_FILE" "$TMP/keys-hidden.sh" \
    's/^\(CONTRACT_KEYS="[^"]*\) payoutAdapter\( [^"]*"\)/\1\2/' \
    '^CONTRACT_KEYS="[^"]* payoutAdapter [^"]*"$'
  expect_ok "one key hidden in a scratch lib: the set shrinks and is reported" "$WRAPPER" "$BASE" "$KEYS_REL=$TMP/keys-hidden.sh" \
    "$((live_n - 1)) registry keys emit $((live_n - 1)) distinct V2_* names"
  expect_ok "one key hidden in a scratch lib: its reader is named as unfed" "$WRAPPER" "$BASE" "$KEYS_REL=$TMP/keys-hidden.sh" \
    "reader(s) not emitted by any key: V2_PAYOUT_ROUTER"
  # the same fixture through the anchor counter: both files carrying CONTRACT_KEYS is ALSO a dead check.
  cp "$KEYS_FILE" "$TMP/lib-dup.sh"; printf 'CONTRACT_KEYS="dup"\n' >> "$TMP/lib-dup.sh"
  expect_die "an anchor carried twice across the union dies at the anchor step" "$WRAPPER" "$BASE" "$KEYS_REL=$TMP/lib-dup.sh" \
    "^CONTRACT_KEYS= line across"

  echo "check-env-names --self-test: $st_pass passed, $st_fail failed"
  [ "$st_fail" = 0 ] || exit 1
  exit 0
fi

check_seam "$WRAPPER" "$BASE"
