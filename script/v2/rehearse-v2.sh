#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# rehearse-v2.sh — fork rehearsal of the v2 deploy: starts its own anvil fork of chain 4663, runs
# script/v2/DeployV2Batch.sh --rehearse end to end (deploy + wire, register the markets, VerifyV2) with the
# write-back going to a copy of the registry, then VerifyV2 alone against that copy, then the drills:
#   1. a second batch run on the copy has nothing to do;
#   2. a lost pointer: VerifyV2 FAILs, the batch refuses without --resume (wiring check), --resume sends the one
#      missing call and VerifyV2 passes;
#   3. a lost write-back: a registered market's registeredAt/registerTx blanked in the copy is recovered from the
#      chain by re-running the batch for it, with the same values;
#   4. VerifyV2 has teeth: one byte of the Clearinghouse's runtime flipped with anvil_setCode FAILs the bytecode check.
# The real registry's sha256 is checked unchanged. Kills the anvil on exit, success or failure.
#
#   script/v2/rehearse-v2.sh                               NVDA (two sources) + TSLA (Chainlink only) on port 8551
#   TICKERS=NVDA,AAPL,MSFT CHAINLINK_ONLY= PORT=8552 script/v2/rehearse-v2.sh
#
# Environment: FORK_URL (default the public Robinhood Chain RPC), PORT (8551), TICKERS (NVDA,TSLA),
# CHAINLINK_ONLY (TSLA: tickers whose v2.univ3Pool is nulled in the rehearsal's INPUT copy, so the single-source
# settlement config and the no-route payout path are rehearsed too; empty = the registry as it is, which stops at
# the RegisterMarkets preflight for any pool whose observation ring holds fewer than 2,401 slots: TSLA's held 1,801 on
# 2026-09-17, sweep contracts-c10), REGISTRY
# (the batch's default), SOURCES (v2-sources.json next to it).
#
# TIME. The public RPC serves state only ~15 minutes behind its head and a fork reads unseen slots at the fork
# block (callhouse ops/devnet/up.sh), so everything runs inside that window: `forge build` first, then the anvil.
# `--code-size-limit 98304` is what chain 4663 enforces (docs/DEPLOY.md).
# -------------------------------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT=$(pwd)
export PATH="$HOME/.foundry/bin:$PATH"

FORK_URL=${FORK_URL:-https://rpc.mainnet.chain.robinhood.com}
PORT=${PORT:-8551}
TICKERS=${TICKERS:-NVDA,TSLA}
CHAINLINK_ONLY=${CHAINLINK_ONLY-TSLA}
REGISTRY=${REGISTRY:-$ROOT/../callhouse/ops/markets/tier1.json}
SOURCES=${SOURCES:-$(dirname "$REGISTRY")/v2-sources.json}
RPC="http://127.0.0.1:$PORT"
BATCH=script/v2/DeployV2Batch.sh

die() { echo "REHEARSAL FAILED: $*" >&2; exit 1; }
step() { printf '\n== %s  (+%ss)\n' "$*" "$(( $(date +%s) - T0 ))"; }
T0=$(date +%s)
for tool in anvil forge cast jq node; do command -v "$tool" >/dev/null || die "$tool not on PATH"; done
[ -f "$REGISTRY" ] || die "registry not found: $REGISTRY"
[ -f "$SOURCES" ] || die "v2-sources.json not found: $SOURCES"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOG=broadcast/v2-rehearsal/$STAMP
mkdir -p "$LOG"
echo "rehearsal logs: $ROOT/$LOG"

step "forge build (before the fork clock starts)"
forge build > "$LOG/build.log" 2>&1 || { tail -30 "$LOG/build.log"; die "forge build failed"; }

if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then die "something already answers on $RPC; pick another PORT"; fi
step "anvil fork of $FORK_URL on $RPC"
# --retries/--fork-retry-backoff/--timeout: the public RPC drops a fork's storage reads now and then ("connection
# reset"), which forge reports as an EVM database error half way through a registration.
anvil --fork-url "$FORK_URL" --chain-id 4663 --port "$PORT" --code-size-limit 98304 \
  --retries 12 --fork-retry-backoff 1000 --timeout 60000 > "$LOG/anvil.log" 2>&1 &
ANVIL_PID=$!
trap 'kill "$ANVIL_PID" 2>/dev/null || true; echo "anvil (pid $ANVIL_PID) stopped"' EXIT
for _ in $(seq 1 120); do
  if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then break; fi
  kill -0 "$ANVIL_PID" 2>/dev/null || { tail -20 "$LOG/anvil.log"; die "anvil exited"; }
  sleep 1
done
cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 || { tail -20 "$LOG/anvil.log"; die "anvil did not come up on $RPC"; }
FORK_BLOCK=$(cast block-number --rpc-url "$RPC")
echo "  fork block $FORK_BLOCK (pid $ANVIL_PID)"

SHA_BEFORE=$(shasum -a 256 "$REGISTRY" | cut -d' ' -f1)
COPY="$ROOT/$LOG/tier1.rehearsal.json"
if [ -n "$CHAINLINK_ONLY" ]; then
  INPUT="$ROOT/$LOG/tier1.input.json"
  only=$(echo "$CHAINLINK_ONLY" | tr ',' '\n' | jq -R . | jq -sc 'map(select(length > 0))')
  jq --argjson only "$only" '(.markets[] | select(.ticker as $t | $only | index($t)) | .v2) |= (.univ3Pool = null | .univ3MinLiquidity = null)' "$REGISTRY" > "$INPUT"
  echo "  input copy $INPUT (Chainlink only on the fork: $CHAINLINK_ONLY)"
else
  # A byte-for-byte exact-registry rehearsal must use the real input path: even an identity jq
  # rewrite changes its sha256 and produces a record that cannot gate a later broadcast.
  INPUT=$REGISTRY
  echo "  input registry $INPUT (byte-for-byte unchanged; no Chainlink-only override)"
fi

step "1. DeployV2Batch.sh --rehearse --tickers $TICKERS"
"$BATCH" --rehearse --rpc "$RPC" --registry "$INPUT" --sources "$SOURCES" --tickers "$TICKERS" --out "$COPY" \
  2>&1 | tee "$LOG/1-batch.log"
grep -q "BATCH PASSED (rehearse)" "$LOG/1-batch.log" || die "the batch did not pass (log: $LOG/1-batch.log)"
grep -q "rehearsal record .*rehearsal-passed.json" "$LOG/1-batch.log" || die "the passed rehearsal left no rehearsal-passed.json"
[ "$(shasum -a 256 "$REGISTRY" | cut -d' ' -f1)" = "$SHA_BEFORE" ] || die "the real registry changed"
echo "  real registry unchanged (sha256 $SHA_BEFORE)"
for T in $(echo "$TICKERS" | tr ',' ' '); do
  jq -e --arg t "$T" '.markets[] | select(.ticker == $t) | .v2.registeredAt != null and .v2.registerTx != null' "$COPY" >/dev/null \
    || die "$T: no registeredAt/registerTx in the copy"
done
CH=$(jq -r '.v2.contracts.clearinghouse' "$COPY")

step "2. VerifyV2 against the copy (DeployV2Batch.sh --verify --expect-fresh true)"
"$BATCH" --verify --rpc "$RPC" --registry "$COPY" --sources "$SOURCES" --expect-fresh true 2>&1 | tee "$LOG/2-verify.log"
grep -q "VERIFY PASSED" "$LOG/2-verify.log" || die "VerifyV2 did not pass against the copy"

step "3. a second run on the copy has nothing to do"
if "$BATCH" --rehearse --rpc "$RPC" --registry "$COPY" --out "$COPY" --sources "$SOURCES" --tickers "$TICKERS" > "$LOG/3-again.log" 2>&1; then
  die "a second run on a complete copy did not refuse"
fi
grep -q "nothing to do" "$LOG/3-again.log" || { tail -5 "$LOG/3-again.log"; die "unexpected refusal"; }
echo "  refused: $(grep -o 'nothing to do.*' "$LOG/3-again.log")"

step "4. a lost pointer: VerifyV2 FAILs, the batch wants --resume, --resume repairs it"
ADMIN=$(jq -r '.shared.admin' "$COPY")
ORACLE=$(jq -r '.v2.contracts.settlementOracle' "$COPY")
cast rpc anvil_impersonateAccount "$ADMIN" --rpc-url "$RPC" >/dev/null
cast send "$ORACLE" "setKeeperRewards(address)" 0x0000000000000000000000000000000000000000 --from "$ADMIN" --unlocked --rpc-url "$RPC" > "$LOG/4-break.log" 2>&1 \
  || { tail -5 "$LOG/4-break.log"; die "could not break the pointer"; }
if "$BATCH" --verify --rpc "$RPC" --registry "$COPY" --sources "$SOURCES" > "$LOG/4-verify-broken.log" 2>&1; then die "VerifyV2 passed with a lost pointer"; fi
grep -q "FAIL  settlementOracle.keeperRewards == keeperRewards" "$LOG/4-verify-broken.log" || die "the lost pointer was not the failure"
echo "  VerifyV2: FAIL settlementOracle.keeperRewards == keeperRewards"
if "$BATCH" --rehearse --rpc "$RPC" --registry "$COPY" --out "$COPY" --sources "$SOURCES" --deploy-only > "$LOG/4-check.log" 2>&1; then die "the batch registered on a half-wired set"; fi
grep -q "re-run with --resume" "$LOG/4-check.log" || { tail -5 "$LOG/4-check.log"; die "the wiring check did not ask for --resume"; }
grep -E "^\s+PENDING" "$LOG/4-check.log" | sed 's/^ */  /'
"$BATCH" --rehearse --rpc "$RPC" --registry "$COPY" --out "$COPY" --sources "$SOURCES" --deploy-only --resume > "$LOG/4-resume.log" 2>&1 \
  || { tail -30 "$LOG/4-resume.log"; die "--resume failed"; }
grep -q "DEPLOY DONE: 0 contract(s) created, 1 admin call(s) sent" "$LOG/4-resume.log" || { grep -E "DEPLOY DONE|call " "$LOG/4-resume.log"; die "--resume did not send exactly the one call"; }
grep -q "BATCH PASSED" "$LOG/4-resume.log" || die "--resume did not end in VERIFY PASSED"
echo "  --resume: $(grep -o 'DEPLOY DONE.*' "$LOG/4-resume.log"); $(grep -o 'VERIFY PASSED: [0-9]* checks' "$LOG/4-resume.log")"

step "5. a lost write-back is recovered from the chain"
LAST=$(echo "$TICKERS" | tr ',' '\n' | tail -1)
WANT_AT=$(jq -r --arg t "$LAST" '.markets[] | select(.ticker == $t) | .v2.registeredAt' "$COPY")
WANT_TX=$(jq -r --arg t "$LAST" '.markets[] | select(.ticker == $t) | .v2.registerTx' "$COPY")
node -e '
  const fs = require("fs"); const [f, t] = process.argv.slice(1);
  const r = JSON.parse(fs.readFileSync(f, "utf8"));
  const m = r.markets.find((x) => x.ticker === t); m.v2.registeredAt = null; m.v2.registerTx = null;
  fs.writeFileSync(f, JSON.stringify(r, null, 2) + "\n");' "$COPY" "$LAST"
"$BATCH" --rehearse --rpc "$RPC" --registry "$COPY" --out "$COPY" --sources "$SOURCES" --tickers "$LAST" > "$LOG/5-recover.log" 2>&1 \
  || { tail -30 "$LOG/5-recover.log"; die "recovery run failed"; }
GOT_AT=$(jq -r --arg t "$LAST" '.markets[] | select(.ticker == $t) | .v2.registeredAt' "$COPY")
GOT_TX=$(jq -r --arg t "$LAST" '.markets[] | select(.ticker == $t) | .v2.registerTx' "$COPY")
[ "$GOT_AT" = "$WANT_AT" ] && [ "$GOT_TX" = "$WANT_TX" ] || die "$LAST recovered as $GOT_AT/$GOT_TX, was $WANT_AT/$WANT_TX"
grep -q "REGISTER DONE: 1 market(s), 0 registerMarket call(s), 0 admin call(s) sent" "$LOG/5-recover.log" || die "the recovery run sent transactions"
echo "  $LAST registeredAt $GOT_AT registerTx $GOT_TX recovered from the MarketRegistered log, nothing sent"

step "6. VerifyV2 has teeth: one byte of the Clearinghouse runtime flipped"
code=$(cast code "$CH" --rpc-url "$RPC")
# The second-to-last byte: the length word of solc's trailing CBOR, never executed, so every other read of the
# Clearinghouse still works and the bytecode comparison is the only check that can see the change.
pos=$((${#code} - 4))
orig=${code:$pos:2}
flip=$(printf '%02x' $(( (16#$orig) ^ 0x01 )))
cast rpc anvil_setCode "$CH" "${code:0:$pos}${flip}${code:$((pos + 2))}" --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
if "$BATCH" --verify --rpc "$RPC" --registry "$COPY" --sources "$SOURCES" > "$LOG/6-tamper.log" 2>&1; then die "VerifyV2 passed against tampered bytecode"; fi
grep -q "FAIL  clearinghouse: runtime == compiled artifact, outside immutable slots" "$LOG/6-tamper.log" || { grep -E "FAIL|Error" "$LOG/6-tamper.log" | head; die "the tamper was not caught by the bytecode check"; }
echo "  byte $(( (pos - 2) / 2 )) of the Clearinghouse flipped 0x$orig -> 0x$flip: FAIL clearinghouse runtime, and nothing else"
[ "$(grep -cE "^\s+FAIL" "$LOG/6-tamper.log")" = 1 ] || die "the tamper failed more than the bytecode check"
cast rpc anvil_setCode "$CH" "$code" --rpc-url "$RPC" >/dev/null

step "summary"
jq -r '.v2.contracts | to_entries[] | if .key == "sources" then (.value | to_entries[] | "  sources.\(.key) \(.value)") else "  \(.key) \(.value)" end' "$COPY"
echo "  deployBlock $(jq -r '.v2.deployBlock' "$COPY")  bots $(jq -c '.v2.bots' "$COPY")"
for T in $(echo "$TICKERS" | tr ',' ' '); do
  jq -r --arg t "$T" '.markets[] | select(.ticker == $t) | "  \(.ticker) registeredAt \(.v2.registeredAt) registerTx \(.v2.registerTx) pool \(.v2.univ3Pool)"' "$COPY"
done
printf '\nREHEARSAL PASSED on fork block %s (%s; Chainlink only: %s) in %ss; copy %s; logs %s\n' \
  "$FORK_BLOCK" "$TICKERS" "${CHAINLINK_ONLY:-none}" "$(( $(date +%s) - T0 ))" "$COPY" "$ROOT/$LOG"
