#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# scrub-run-dir.test.sh — the synthetic-fixture suite for script/v2/scrub-run-dir.sh (T-OP-201).
#
#   script/v2/scrub-run-dir.test.sh          (or: script/v2/scrub-run-dir.sh --self-test)
#
# EVERY FIXTURE VALUE IS SYNTHETIC: repeated letters, obviously fake hosts, the public anvil dev key #0. No real
# secret is written by this file, and the suite asserts that no fixture VALUE ever appears in the scanner's
# output -- the property that makes the scanner's own output safe to paste anywhere. One file per shape, a clean
# file full of the 64-hex words a run dir legitimately holds (tx hashes, op ids), the fork-host WARN both ways,
# then --redact: the copies carry <REDACTED:shape> and none of the values, and the re-scan is clean.
# Prints one line per case and "SCRUB SELF-TEST PASSED: N cases", or exits 1 at the first case that misbehaves.
# -------------------------------------------------------------------------------------------------
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SCRUB="$HERE/scrub-run-dir.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/scrub-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
CASES=0
fail() { echo "SCRUB SELF-TEST FAILED: $*" >&2; exit 1; }
ok() { CASES=$((CASES + 1)); printf '  ok    %s\n' "$*"; }

# A synthetic fork.env with an obviously fake host and key, so the WARN shape is exercised without the real file.
export SCRUB_FORK_ENV="$TMP/fork.env"
printf 'FORK_URL=https://example-archive.fake.invalid/v2/FAKEFAKEFAKEFAKEFAKE1234\n' > "$SCRUB_FORK_ENV"

RUN="$TMP/run"; mkdir -p "$RUN/sub"
# --- one file per shape; the VALUE of each is recorded so the suite can assert it never appears in the output ---
V_RPC="https://example-archive.fake.invalid/v2/FAKEFAKEFAKEFAKEFAKE1234"
V_RPC2="https://rpc.fake.invalid/?apikey=FAKEKEYFAKEKEYFAKE"
V_PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"   # anvil dev key #0: public, not a secret
V_GH="ghp_$(printf 'x%.0s' $(seq 1 36))"
V_PAT="github_pat_$(printf 'y%.0s' $(seq 1 30))"
V_BEARER="Bearer $(printf 'z%.0s' $(seq 1 32))"
V_AWS="AKIA$(printf 'A%.0s' $(seq 1 16))"
V_CF="cf$(printf 'q%.0s' $(seq 1 30))"
V_AL="al$(printf 'w%.0s' $(seq 1 30))"
printf 'anvil --fork-url %s --chain-id 4663\n' "$V_RPC" > "$RUN/1-rpc-key-url.log"
printf 'curl %s\n' "$V_RPC2" > "$RUN/1b-rpc-key-url-query.log"
printf 'DEPLOYER_PK=%s\nADMIN_PK=0xdeadbeef\nFORK_URL=%s\nALCHEMY_API_KEY=%s\nCLOUDFLARE_API_TOKEN=%s\nGITHUB_TOKEN=%s\n' "$V_PK" "$V_RPC" "$V_AL" "$V_CF" "$V_GH" > "$RUN/2-env-secret.env"
printf 'forge script X --private-key %s --broadcast\n' "$V_PK" > "$RUN/3-hex-private-key.log"
printf 'token: %s\nfine-grained: %s\n' "$V_GH" "$V_PAT" > "$RUN/4-github-token.txt"
printf 'Authorization: %s\n' "$V_BEARER" > "$RUN/sub/5-bearer-token.http"
printf 'aws_access_key_id = %s\naws_secret_access_key = SECRETSECRETSECRETSECRET\n' "$V_AWS" > "$RUN/6-aws-key.ini"
# --- the clean file: what a run dir legitimately holds ---
printf 'tx 0x%s block 69324879\nopId 0x%s readyAt 1790129110\nV2_HOUSE_VAULT 0xCc26232aEb1a043Dba58728b64c0c97F01266010\n' "$(printf '1%.0s' $(seq 1 64))" "$(printf 'e%.0s' $(seq 1 64))" > "$RUN/9-clean.log"
# --- the host alone: a WARN, never a hit ---
printf 'endpoint example-archive.fake.invalid, fork block 69398800\n' > "$RUN/8-host-only.log"

# 1. the scan HITS, exit 1, and names every shape by file:line:shape
set +e; out=$("$SCRUB" "$RUN" 2>&1); rc=$?; set -e
[ "$rc" = 1 ] || fail "scan of the fixture dir exited $rc, expected 1"
ok "scan exits 1 on the fixture dir"
want() { grep -qF -- "$1" <<<"$out" || fail "missing line: $1"; }
want "$RUN/1-rpc-key-url.log:1:rpc-key-url"
want "$RUN/1b-rpc-key-url-query.log:1:rpc-key-url"
want "$RUN/2-env-secret.env:1:env-secret"
want "$RUN/2-env-secret.env:2:env-secret"
want "$RUN/2-env-secret.env:3:env-secret"
want "$RUN/2-env-secret.env:4:env-secret"
want "$RUN/2-env-secret.env:5:env-secret"
want "$RUN/2-env-secret.env:6:env-secret"
want "$RUN/3-hex-private-key.log:1:hex-private-key"
want "$RUN/4-github-token.txt:1:github-token"
want "$RUN/4-github-token.txt:2:github-token"
want "$RUN/sub/5-bearer-token.http:1:bearer-token"
want "$RUN/6-aws-key.ini:1:aws-key"
want "$RUN/6-aws-key.ini:2:aws-key"
want "$RUN/2-env-secret.env:4:alchemy-key"
want "$RUN/2-env-secret.env:5:cloudflare-token"
want "$RUN/1-rpc-key-url.log:1:rpc-key-url"
ok "every shape is reported as file:line:shape"
# 2. the clean file is clean: 64-hex tx hashes and op ids are NOT hits
grep -q "9-clean.log" <<<"$out" && fail "the clean file (tx hashes, op ids) was flagged"
ok "64-hex tx hashes and op ids in a clean file are not hits"
# 3. the host alone is a WARN, not a hit; the host with /v2/<key> is a hit (above)
want "$RUN/8-host-only.log:1:WARN:fork-host"
grep -qE "8-host-only.log:1:(rpc-key-url|env-secret)" <<<"$out" && fail "the bare host was counted as a hit"
ok "fork host alone is a WARN; host + /v2/<key> is a hit"
# 4. NO VALUE IN THE OUTPUT -- the property everything else depends on
for v in "$V_RPC" "$V_RPC2" "$V_PK" "$V_GH" "$V_PAT" "$V_BEARER" "$V_AWS" "$V_CF" "$V_AL" "FAKEFAKEFAKE" "SECRETSECRET" "0xdeadbeef"; do
  grep -qF -- "$v" <<<"$out" && fail "a fixture VALUE leaked into the scanner's output: shape of '$(echo "$v" | cut -c1-6)...'"
done
ok "no fixture value appears in the scan output"

# 5. --redact: copies exist, carry <REDACTED:shape>, carry no value, and re-scan clean (the tool checks itself)
set +e; rout=$("$SCRUB" "$RUN" --redact --out "$TMP/scrubbed" 2>&1); rrc=$?; set -e
[ "$rrc" = 0 ] || { echo "$rout"; fail "--redact exited $rrc"; }
grep -qF "re-scan of $TMP/scrubbed: clean" <<<"$rout" || fail "--redact did not report a clean re-scan"
for v in "$V_RPC" "$V_RPC2" "$V_PK" "$V_GH" "$V_PAT" "$V_BEARER" "$V_AWS" "$V_CF" "$V_AL" "SECRETSECRET" "0xdeadbeef"; do
  grep -rqF -- "$v" "$TMP/scrubbed" && fail "a fixture value survived --redact"
done
grep -q "<REDACTED:rpc-key-url>" "$TMP/scrubbed/1-rpc-key-url.log" || fail "rpc-key-url not redacted by shape"
grep -q "<REDACTED:env-secret>" "$TMP/scrubbed/2-env-secret.env" || fail "env-secret not redacted by shape"
grep -q "<REDACTED:hex-private-key>" "$TMP/scrubbed/3-hex-private-key.log" || fail "hex-private-key not redacted by shape"
grep -q "<REDACTED:bearer-token>" "$TMP/scrubbed/sub/5-bearer-token.http" || fail "bearer-token not redacted (subdir kept)"
grep -q "block 69324879" "$TMP/scrubbed/9-clean.log" || fail "the clean file was altered by --redact"
cmp -s "$RUN/9-clean.log" "$TMP/scrubbed/9-clean.log" || fail "the clean file is not byte-identical after --redact"
set +e; "$SCRUB" "$TMP/scrubbed" > /dev/null 2>&1; src=$?; set -e
[ "$src" = 0 ] || fail "independent re-scan of the scrubbed dir exited $src"
ok "--redact: value-free copies by shape, clean file untouched, re-scan clean"

# 6. explicit files beside the dir are scanned too; a clean-only dir exits 0
printf 'ghp_%s\n' "$(printf 'k%.0s' $(seq 1 40))" > "$TMP/extra.txt"
mkdir -p "$TMP/cleanrun"; cp "$RUN/9-clean.log" "$TMP/cleanrun/"
set +e; "$SCRUB" "$TMP/cleanrun" > /dev/null 2>&1; c1=$?; "$SCRUB" "$TMP/cleanrun" "$TMP/extra.txt" > /dev/null 2>&1; c2=$?; set -e
[ "$c1" = 0 ] || fail "a clean-only dir exited $c1"
[ "$c2" = 1 ] || fail "an extra file with a token did not make the scan exit 1 (got $c2)"
ok "clean-only dir exits 0; an explicit extra file with a token exits 1"

# 7. PROVE-BY-BREAKING, built in: a scanner with one shape removed must MISS that fixture (so this suite is not
#    passing for the wrong reason). A scratch copy with 'github-token' deleted from SHAPES scans the token file clean.
sed 's/ github-token / /' "$SCRUB" > "$TMP/scrub-broken.sh"; chmod +x "$TMP/scrub-broken.sh"
mkdir -p "$TMP/onlygh"; cp "$RUN/4-github-token.txt" "$TMP/onlygh/"
set +e; "$TMP/scrub-broken.sh" "$TMP/onlygh" > /dev/null 2>&1; brc=$?; set -e
[ "$brc" = 0 ] || fail "the deliberately broken scanner still caught the github token (exit $brc): the control is not a control"
ok "negative control: a scanner missing the github-token shape scans that fixture clean (exit 0)"

echo "SCRUB SELF-TEST PASSED: $CASES cases"
