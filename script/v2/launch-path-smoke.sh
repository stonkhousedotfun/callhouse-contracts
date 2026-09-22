#!/usr/bin/env bash
# launch-path-smoke.sh -- static smoke test of the v8 launch path. NO CHAIN, NO COMPILE.
#
# WHY THIS EXISTS (T-LP-10). Four defects -- T-LP-01, 02, 03 and 05 -- were all found on 2026-09-21
# by one operator manually walking the v8 launch path for the first time. Every one was statically
# detectable and nothing in this repository ran that path. This script is that path, run cheaply.
#
# WHAT IT CHECKS
#   1 ENV COVERAGE   every environment variable a forge script the wrapper INVOKES reads with a
#                    no-default vm.env* must be exported by script/v2/DeployV2Batch.sh.
#   2 REGISTRY PATHS every registry field the wrapper reads must resolve against the v8 fixture.
#   3 STRICT V8      check 2 again against a registry with the v7 aliases REMOVED, so a v7 key name
#                    cannot be satisfied by a fixture that carries both spellings.
#   4 RESOLUTION     every exported variable whose value comes from a registry/recon lookup must
#                    RESOLVE to something. An export is not a value.
#
# T-572, AND THIS ONE WAS MY OWN FALSE GREEN. Check 1 asked whether the wrapper EXPORTS a name and
# never whether the exported value resolves. `DeployV2Batch.sh:624` exports V2_V4_POOL_MANAGER and
# V2_V4_STATE_VIEW from `.contracts.v4PoolManager.address // empty` (:312-313) against a
# v2-sources.json that has NO such key, so both export as the EMPTY STRING and check 1 passed them
# from the moment T-LP-01 added the exports. This harness certified the exact gap it was built to
# catch. Missing and empty are DIFFERENT failures and are reported separately below: a missing
# export is a wrapper that forgot, an empty one is data that was never recorded.
#
# TWO TRAPS THIS SCRIPT IS BUILT AROUND, because the obvious implementation of each check is blind
# to exactly the defect it exists to catch -- the dominant failure class on this build:
#   * DeployV8.s.sol barely reads the environment itself; the real reads are in
#     script/v2/lib/V2DeployBase.sol, which is a .sol and NOT a .s.sol. Grepping only *.s.sol
#     reports a clean bill of health and misses T-LP-01. So the libs are scanned too.
#   * The wrapper reads bots through a DYNAMIC template, jqr ".v2.bots.$1". Static path extraction
#     sees a variable and resolves nothing, so the literal bot() callsite arguments are extracted
#     instead. Without that, check 3 cannot see T-LP-02.
#
# EXIT 0 clean, 1 discrepancies found, 2 bad usage or a missing input.
set -euo pipefail

# LAUNCH_SMOKE_ROOT lets a caller point the checks at another checkout without copying this file
# into it -- used to exercise the script itself, and by CI against a candidate tree.
ROOT=${LAUNCH_SMOKE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
WRAPPER=$ROOT/script/v2/DeployV2Batch.sh
FIXTURE=${LAUNCH_SMOKE_REGISTRY:-$ROOT/script/v2/fixtures/registry-v8.json}
# The four bot key names INTERFACE_VERSION 8 defines (callhouse ops/markets/build-markets.mjs
# V2_BOT_NAMES). A key outside this set in a v8 registry is a v7 leftover.
#
# WHICH SUBJECT THIS LIST POLICES, because it is NOT the one it looks like, and a previous reading of
# mine got it wrong (T-585 Part C). This list is the REGISTRY BOT VOCABULARY, mirrored from the
# generator -- it is NOT the set of keys DeployV2Batch.sh reads. Those are two different subjects and
# check 3 below polices them in two separate loops on purpose:
#   * the bot() callsite loop asks whether every key the WRAPPER READS exists in a v8-only registry;
#   * the extra-key loop after it asks whether the FIXTURE carries a key the VOCABULARY does not define.
# THE LINE THAT DECIDES IT is callhouse `ops/markets/build-markets.mjs:825`,
# `exactKeys(v2.bots, V2_BOT_NAMES, "v2.bots", issues)`, whose implementation at :778-781 enforces
# BOTH directions: :779 pushes an issue for any V2_BOT_NAMES entry MISSING from the object, and :780
# for any object key NOT in V2_BOT_NAMES. `V2_BOT_NAMES` is defined at :252 as exactly
# ["cranker","pricer","quoter","guardian"], and :471 EMITS `v2.bots` as exactly those four keys, null.
# SO `guardian` BELONGS HERE AND MUST NOT BE REMOVED, even though the wrapper never reads
# `.v2.bots.guardian` -- it reads guardian from `.shared.guardian` (DeployV2Batch.sh:302, validated at
# :314) and has only three bot() callsites (:432). Deleting `guardian` from this list to match the
# wrapper would make the extra-key rule REJECT a registry the generator mandates: a false red on every
# correct v8 registry. The apparent mismatch between this list and the wrapper's reads is not a defect.
#
# READING THE CITATION ABOVE: `V2_BOT_NAMES` is on the callhouse **v8** ref. Both local callhouse and
# callhouse-contracts checkouts sit on `tier1-multimarket`, where it does not exist, so a grep of the
# default checkout reports the citation as dangling when it is correct. Use `git -C callhouse grep
# V2_BOT_NAMES v8`.
# Held as a JSON literal, NOT a space-separated string fed through word splitting: zsh does not
# word-split unquoted expansions the way bash does, so `printf '%s\n' $V8_BOT_NAMES | jq -s .`
# silently produced a ONE-element array and every bot lookup failed against an empty strict
# registry -- a checker that reported `cranker` as not a v8 key. Build the array in jq instead.
V8_BOT_NAMES_JSON='["cranker","pricer","quoter","guardian"]'
V8_BOT_NAMES=$(printf '%s' "$V8_BOT_NAMES_JSON" | jq -r 'join(" ")')

for f in "$WRAPPER" "$FIXTURE"; do
  [ -r "$f" ] || { echo "launch-path-smoke: cannot read $f" >&2; exit 2; }
done
command -v jq >/dev/null || { echo "launch-path-smoke: jq is required" >&2; exit 2; }

FAILED=0
FAIL_N=0
OK_N=0
fail() { FAILED=1; FAIL_N=$((FAIL_N + 1)); printf 'FAIL  %s\n' "$*"; }
ok()   { OK_N=$((OK_N + 1)); printf 'ok    %s\n' "$*"; }

# ---------------------------------------------------------------- 1 env coverage
# Only the scripts the wrapper actually invokes, plus the libs they inherit. DeployEarnVault,
# DeployLenderRewards and VerifyLenderRewards read another ten V2_* names the wrapper never
# exports, and that is CORRECT -- the wrapper does not run them. Flagging those would make this
# script noise, and a noisy check gets muted and then watches nothing.
# NOTE: bash 3.2 (the macOS system bash, and what the operator runs) has no `mapfile` and no
# associative arrays. Everything here is newline-delimited text for that reason -- an earlier
# draft used mapfile and died with "command not found" on the first real run.
INVOKED=$(grep -oE 'script/v2/[A-Za-z0-9_]+\.s\.sol' "$WRAPPER" | sort -u)
LIBS=$(find "$ROOT/script/v2/lib" -name '*.sol' 2>/dev/null | sort)

# vm.envAddress/envUint/envInt/envBool/envString/envBytes32 REVERT when unset. vm.envOr and
# vm.envExists do not. Conflating them produces false positives -- it gave 16 on the first pass.
required_names() {
  local f
  for f in "$@"; do
    [ -r "$f" ] || continue
    grep -oE 'vm\.env(Address|Uint|Int|Bool|String|Bytes32)\("[A-Z0-9_]+"' "$f" \
      | grep -oE '"[A-Z0-9_]+"' | tr -d '"'
  done
}
optional_names() {
  local f
  for f in "$@"; do
    [ -r "$f" ] || continue
    grep -oE 'vm\.env(Or|Exists)\("[A-Z0-9_]+"' "$f" | grep -oE '"[A-Z0-9_]+"' | tr -d '"'
  done
}

PATHS=""
for s in $INVOKED; do PATHS="$PATHS $ROOT/$s"; done
for s in $LIBS;    do PATHS="$PATHS $s"; done

REQUIRED=$(required_names $PATHS | sort -u)
OPTIONAL=$(optional_names $PATHS | sort -u)
# An `export A=1 B=2` line sets both names, so split on whitespace rather than matching one per line.
# An export can sit mid-line behind a conditional (`if is_addr ...; then export V2_TREASURY_SAFE=...`),
# so match `export` ANYWHERE, not just at the start of a line. Anchoring here produced a false
# positive for V2_TREASURY_SAFE on the first real run.
EXPORTED=$(grep -oE 'export[[:space:]]+([A-Z0-9_]+=[^;]*)' "$WRAPPER" \
  | sed -E 's/^export[[:space:]]+//' | tr ' ' '\n' \
  | grep -oE '^[A-Z0-9_]+=' | tr -d '=' | sort -u)

for n in $REQUIRED; do
  grep -qx "$n" <<<"$EXPORTED" && continue
  grep -qx "$n" <<<"$OPTIONAL" && continue   # also read with a default somewhere: not fatal
  where=$(grep -nE "vm\.env[A-Za-z]+\(\"$n\"" $PATHS 2>/dev/null | head -1 | cut -d: -f1,2 | sed "s|$ROOT/||")
  fail "env $n is read with a no-default vm.env* at ${where:-unknown} but $(basename "$WRAPPER") never exports it: the deploy dies here, after a full compile"
done
if [ "$FAILED" = 0 ]; then ok "env coverage: every required vm.env* name is exported by the wrapper"; fi

# ---------------------------------------------------------------- 2 and 3 registry paths
# Literal jqr paths, then the dynamic bot() callsites, resolved against the fixture and then
# against a v8-only copy.
STRICT=$(jq --argjson keep "$V8_BOT_NAMES_JSON" \
  '.v2.bots |= with_entries(select(.key as $k | $keep | index($k)))' "$FIXTURE")

resolve() { # path json -> 0 when the path has a non-null value
  jq -e "$1 != null" >/dev/null 2>&1 <<<"$2"
}

# KEY EXISTENCE, not value. A bot key with a null value is the LEGITIMATE pre-derivation state --
# ops/v2/derive-bot-keys.sh fills it later and bot() has a rehearse fallback for exactly that. What
# this row is about is a key that is not there AT ALL under its v8 name. Testing `!= null` here
# reported cranker, pricer and quoter as missing from a registry that defines all three.
has_key() { # dotted-path json -> 0 when the key exists, whatever its value
  jq -e "$1 | has(\"$2\")" >/dev/null 2>&1 <<<"$3"
}

# A path read as `jqr '.x.y // empty'` tolerates absence BY DESIGN -- the wrapper has its own
# handling for it. Only paths read WITHOUT a `//` default are required to resolve. Ignoring this
# flagged six paths on the first run that the wrapper handles perfectly well.
REQ_PATHS=$(grep -oE "jqr '\.[A-Za-z0-9_.]+'" "$WRAPPER" | sed -E "s/jqr '//; s/'$//" | sort -u)
FIXTURE_JSON=$(cat "$FIXTURE")
# ABSENT is a defect; PRESENT-AND-NULL is not, and conflating them cost a correct file a wrong edit.
# T-LP-13: this check used `!= null` and reported `.shared.feeRecipient` as "absent from
# registry-v8.json". It is NOT absent -- the key is there with a deliberate JSON null, exactly as the
# live registry carries it, because that field IS the FeeSplitter the deploy creates and a registry
# describing an undeployed set cannot know it (DeployV2Batch.sh:359-361). The wrapper reads it bare
# at :302 and then handles null EXPLICITLY at :362-364, exporting it only `if is_addr` at :663.
# Every layer was correct and this harness said otherwise; the operator changed the field to a real
# EOA on the strength of that line and DeployV8 would have refused the result. A false positive in a
# gate does not merely waste attention -- it manufactures a defect in a file that was right.
#
# So: report a key that is MISSING, say nothing about a key that is present and null, and do not
# infer "must resolve" from the absence of a `// empty` in the jq expression -- the caller may handle
# the value two lines later, and here it does.
for p in $REQ_PATHS; do
  parent=$(printf '%s' "$p" | sed -E 's/\.[A-Za-z0-9_]+$//')
  leaf=$(printf '%s' "$p" | sed -E 's/^.*\.([A-Za-z0-9_]+)$/\1/')
  [ -n "$parent" ] || parent="."
  if ! jq -e --arg k "$leaf" "($parent) | has(\$k)" >/dev/null 2>&1 <<<"$FIXTURE_JSON"; then
    fail "registry path $p is read by the wrapper and the KEY IS MISSING from $(basename "$FIXTURE"). (A key present with a null value is NOT reported: null is how this registry says 'whatever this run creates'.)"
  fi
done

# THE CHECK THAT CATCHES T-LP-02. `bot <name> "$ANVILn" [alias]` -- resolve <name>, not the template.
while read -r name alias; do
  [ -n "$name" ] || continue
  if has_key ".v2.bots" "$name" "$STRICT"; then
    ok "bot $name resolves against a v8-only registry"
  elif [ -n "$alias" ] && has_key ".v2.bots" "$alias" "$STRICT"; then
    fail "bot $name resolves only through its alias $alias: the primary key is not a v8 name"
  else
    fail "bot $name is not a v8 registry key (v8 defines: $V8_BOT_NAMES) -- on a correct v8 registry this lookup finds null, and in rehearse mode it silently substitutes a PUBLIC anvil key"
  fi
# awk on fixed fields, NOT sed: BSD sed has no \b, and an earlier draft reported the literal
# word "bot" as the key name three times -- a checker printing nonsense is a checker nobody reads.
done < <(grep -oE 'bot [a-zA-Z0-9_]+ "\$ANVIL[0-9]+"( [a-zA-Z0-9_]+)?' "$WRAPPER" \
         | awk '{ gsub(/"/,"",$3); print $2, $4 }')

# The inverse: a key the fixture carries that v8 does not define is a v7 leftover, and it is what
# lets a v7 read pass -- a fixture holding both spellings satisfies whichever one the code uses.
for k in $(jq -r '.v2.bots | keys[]' "$FIXTURE"); do
  printf '%s' "$V8_BOT_NAMES_JSON" | jq -e --arg k "$k" 'index($k)' >/dev/null || fail "registry fixture carries v2.bots.$k, which INTERFACE_VERSION 8 does not define: a v7 leftover that makes a v7 key name look valid"
done

# ---------------------------------------------------------------- 4 exported values resolve
# T-572. An export is NOT a value. For every V2_* the wrapper exports from a shell variable, find
# where that variable was assigned from a jq lookup and re-run the lookup: if it resolves to
# nothing, the deploy gets an empty string and dies in vm.envAddress no matter how correct the
# export line looks. Reported SEPARATELY from a missing export, because they are different
# failures with different owners -- a missing export is a wrapper that forgot, an empty one is
# DATA that was never recorded.
# COVERAGE LIMIT, stated because an undocumented blind spot is how this check came to be needed:
# only assignments of the form `VAR=$(jq -r '<path>' "$SOURCES"|"$STATE"|"$REGISTRY")` are traced.
# A value read through the wrapper's `jqr` helper, computed, or passed in from the environment is
# NOT resolved here and will not be reported. `ROUTER`, `FACTORY` and the other `jqr` reads are in
# that gap today. Widening it is a row, not a silent edit -- but do not read a clean resolution
# section as "every exported value resolves".
# THE GAP IS LIVE, NOT THEORETICAL, and here are its first named instances (T-585). The wrapper reads
#   TOKEN_POOL_CURRENCY1=$(jqr '.v2.flywheel.tokenPool.currency1 // empty')   DeployV2Batch.sh:339
#   TOKEN_POOL_HOOKS=$(jqr '.v2.flywheel.tokenPool.hooks // empty')           DeployV2Batch.sh:340
# through `jqr`, so this section cannot see either -- and BOTH resolve to empty against every valid
# registry, because `v2.flywheel` is exactKeys-validated against {feeSplitter, buybackExecutor,
# deployBlock} (callhouse v8 ops/markets/build-markets.mjs:482, :887). The pool key lives at
# `shared.token.poolKey` (:137, :145, :1026). So the wrapper reads a path the schema FORBIDS, the
# deploy dies `V2_TOKEN_POOL_CURRENCY1 has no value`, and this harness says nothing. Raised as its own
# row against DeployV2Batch.sh, which is outside T-585's fence; NOT fixed here, and NOT papered over by
# widening this loop, because the defect is the wrapper's path and not this check's reach.
SOURCES_FILE=${LAUNCH_SMOKE_SOURCES:-$ROOT/script/v2/fixtures/v2-sources.json}
EMPTY_FOUND=0
# ALL pairs on the line, not just the first: `export V2_V4_POOL_MANAGER=$A V2_V4_STATE_VIEW=$B`
# is ONE export statement with TWO assignments, and matching `export NAME=$VAR` saw only
# V2_V4_POOL_MANAGER. My own check was blind to the second half of its own subject.
# T-585 WIDENING, deliberate and evidenced, not a silent edit. `export V2_WETH=$(checksum "$WETH")`
# does NOT match `NAME=$VAR`, so every export that passes its value through a helper was invisible to
# this check -- six of them, of which `WETH` and `USDG_WETH_V3_POOL` are jq-sourced from `$SOURCES` and
# therefore checkable. THE MISS WAS LIVE, not theoretical: invoking the wrapper directly against a
# fixture patched with the two v4 addresses got past the v4 gap and then died
#   BATCH FAILED: V2_WETH has no value: v2-sources contracts.weth.address is absent or null
# while this harness reported only the two v4 names. A checker blind to part of its own subject is the
# defect this file exists to catch, and it is the THIRD time this file has had it (T-572 was the first).
# The `jqr` gap named above is NOT closed by this and is still a row.
for pair in $( { grep -E '(^|[[:space:]])export ' "$WRAPPER" | grep -oE '[A-Z0-9_]+=\$[A-Z0-9_]+' | sed -E 's/([A-Z0-9_]+)=\$([A-Z0-9_]+)/\1:\2/'
                 grep -E '(^|[[:space:]])export ' "$WRAPPER" | grep -oE '[A-Z0-9_]+=\$\([a-z_]+ "\$[A-Z0-9_]+"\)' | sed -E 's/([A-Z0-9_]+)=\$\([a-z_]+ "\$([A-Z0-9_]+)"\)/\1:\2/'
               } | sort -u); do
  ename=${pair%%:*}
  vname=${pair#*:}
  # where did $vname come from? only file-sourced lookups are checkable.
  # `|| true` is LOAD-BEARING: with `set -o pipefail` a grep that matches nothing makes the whole
  # substitution exit 1, and `set -e` then kills the script silently mid-loop, with no message.
  # Second time that pair bit this file in one sitting; the other was `[ x ] && y` as a statement.
  aline=$(grep -E "^${vname}=\\\$\\(jq -r " "$WRAPPER" | head -1 || true)
  [ -n "$aline" ] || continue
  jqpath=$(printf '%s' "$aline" | sed -E "s/^[A-Z0-9_]+=\\\$\\(jq -r '([^']*)'.*/\\1/" | sed -E 's# *// *empty##')
  case "$aline" in
    *'"$SOURCES"'*) f=$SOURCES_FILE ;;
    *'"$STATE"'*|*'"$REGISTRY"'*) f=$FIXTURE ;;
    *) continue ;;
  esac
  # A name the wrapper itself UNSETS on some path tolerates absence by design -- V2_TICKERS is
  # empty until a market is registered, and saying so is not a defect. A harness that cries wolf
  # gets ignored, which is how this file got into trouble in the first place.
  if grep -qE "unset[[:space:]]+([A-Z0-9_]+[[:space:]]+)*${ename}([[:space:];]|$)" "$WRAPPER"; then continue; fi   # `;` matters: the real line is `unset V2_TICKERS; fi`
  [ -r "$f" ] || continue
  val=$(jq -r "${jqpath} // empty" "$f" 2>/dev/null || true)
  if [ -z "$val" ]; then
    EMPTY_FOUND=1
    fail "export $ename is PRESENT but RESOLVES TO EMPTY: $vname reads '$jqpath' from $(basename "$f"), which has no such value. forge receives an empty string and dies in vm.envAddress. This is NOT a missing export -- the wrapper did its part and the DATA is absent."
  fi
done
# NOTE: `[ x ] && y` would return non-zero when the test is false, and `set -e` would kill the
# script right here before the summary ever printed. Use if/fi.
if [ "$EMPTY_FOUND" = 0 ]; then ok "every exported file-sourced value resolves to something"; fi

# ---------------------------------------------------------------- vendored content pins
# T-574. A vendoring header is an assertion about the day the file landed and cannot see later
# edits, so an audit-scope exclusion resting on "it is vendored" has every subsequent commit as its
# blind spot. script/v2/check-vendored-pins.sh makes that assertion mechanical; this section runs it
# here because lanes actually run this harness, and reports one line per pinned file.
PINS=$ROOT/script/v2/check-vendored-pins.sh
if [ ! -x "$PINS" ]; then
  fail "vendored pins: $PINS is missing or not executable, so nothing is checking that a file whose header claims it is verbatim still is"
else
  # Capture the REAL exit status of the checker, not of the pipeline that formats it: a `| while`
  # would report the status of the loop and a killed checker would read exactly like a clean one.
  # `pins_out=$(...); pins_rc=$?` is WRONG here and I shipped it for one iteration before the
  # prove-by-breaking run caught it: under `set -e` a substitution assignment that returns non-zero
  # kills the script on the spot, so the mismatch case printed NOTHING AT ALL -- no fail line, no
  # summary -- while the healthy case looked perfect. `if x=$(...)` is exempt from `set -e`.
  if pins_out=$("$PINS" 2>&1); then pins_rc=0; else pins_rc=$?; fi
  if [ "$pins_rc" = 2 ]; then
    fail "vendored pins: the checker could not run ($pins_out). A check that cannot run is not a check that passed"
  else
    while IFS= read -r line; do
      case "$line" in
        "PIN-OK "*)       ok   "vendored pin matches: ${line#PIN-OK }" ;;
        "PIN-MISMATCH "*) fail "VENDORED FILE EDITED SINCE IT WAS PINNED: ${line#PIN-MISMATCH }. Its header still claims the body is unchanged, so anything excluding it from audit scope on that basis is now wrong. Either revert the edit, or update its sha256 in script/v2/vendored-pins.json in the same commit and say why the body moved" ;;
        "PIN-MISSING "*)  fail "vendored pin names a file that is not there: ${line#PIN-MISSING }" ;;
      esac
    done <<EOF
$pins_out
EOF
  fi
fi

# ---------------------------------------------------------------- summary
SHA=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")
printf '\n%s: %s FAIL, %s ok, at %s\n' "launch-path-smoke" "$FAIL_N" "$OK_N" "$SHA"
if [ "$FAILED" = 0 ]; then printf 'RESULT: PASS\n'; else printf 'RESULT: FAIL\n'; fi

exit $FAILED
