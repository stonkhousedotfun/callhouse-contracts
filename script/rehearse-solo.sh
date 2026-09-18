#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# Fork rehearsal of the Tier 1 solo-factory batch: starts its own anvil fork of chain 4663, runs
# script/DeploySoloBatch.sh --rehearse for a few markets, proves the real registry did not change, and
# runs the negative check (one byte of a factory's code flipped with anvil_setCode must FAIL VerifySolo).
# Kills the anvil on exit, success or failure.
#
#   script/rehearse-solo.sh                       # TSLA,GME,SPY on port 8546
#   TICKERS=AAPL,MSFT PORT=8547 script/rehearse-solo.sh
#
# Environment: FORK_URL (default the public Robinhood Chain RPC), PORT (8546), TICKERS (TSLA,GME,SPY: one
# volatile name, one cheap one, one ETF), REGISTRY (the batch script's default).
# `--code-size-limit 98304` on the anvil is what chain 4663 enforces (rehearse-deploy.sh explains).
# -------------------------------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

FORK_URL=${FORK_URL:-https://rpc.mainnet.chain.robinhood.com}
PORT=${PORT:-8546}
TICKERS=${TICKERS:-TSLA,GME,SPY}
REGISTRY=${REGISTRY:-../callhouse/ops/markets/tier1.json}
RPC="http://127.0.0.1:$PORT"

die() { echo "REHEARSAL FAILED: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOG=broadcast/solo-rehearsal/$STAMP
mkdir -p "$LOG"
echo "rehearsal logs: $(pwd)/$LOG"

if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then die "something already answers on $RPC; pick another PORT"; fi
anvil --fork-url "$FORK_URL" --chain-id 4663 --port "$PORT" --code-size-limit 98304 > "$LOG/anvil.log" 2>&1 &
ANVIL_PID=$!
trap 'kill "$ANVIL_PID" 2>/dev/null || true; echo "anvil (pid $ANVIL_PID) stopped"' EXIT

for _ in $(seq 1 120); do
  if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then break; fi
  kill -0 "$ANVIL_PID" 2>/dev/null || { tail -20 "$LOG/anvil.log"; die "anvil exited"; }
  sleep 1
done
cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 || { tail -20 "$LOG/anvil.log"; die "anvil did not come up on $RPC"; }
FORK_BLOCK=$(cast block-number --rpc-url "$RPC")
echo "anvil fork of $FORK_URL at block $FORK_BLOCK on $RPC (pid $ANVIL_PID)"

SHA_BEFORE=$(shasum -a 256 "$REGISTRY" | cut -d' ' -f1)
COPY="$(pwd)/$LOG/tier1.rehearsal.json"

step "DeploySoloBatch.sh --rehearse --tickers $TICKERS"
script/DeploySoloBatch.sh --rehearse --rpc "$RPC" --registry "$REGISTRY" --tickers "$TICKERS" --out "$COPY"

step "the real registry is byte-identical; the copy has the addresses"
SHA_AFTER=$(shasum -a 256 "$REGISTRY" | cut -d' ' -f1)
[ "$SHA_BEFORE" = "$SHA_AFTER" ] || die "real registry changed: $SHA_BEFORE -> $SHA_AFTER"
echo "  real registry sha256 $SHA_AFTER (unchanged)"
for T in $(echo "$TICKERS" | tr ',' ' '); do
  f=$(jq -r --arg t "$T" '.markets[] | select(.ticker==$t) | .deployment.factory' "$COPY")
  case "$f" in 0x*) ;; *) die "$T has no factory in the copy" ;; esac
  [ "$(cast codesize "$f" --rpc-url "$RPC")" -gt 0 ] || die "$T: no code at $f"
  echo "  $T factory $f ($(cast codesize "$f" --rpc-url "$RPC") B)"
done
[ "$(jq -r '.markets[] | select(.ticker=="NVDA") | .deployment.factory' "$COPY")" = "0xc4A5Cd0DE91CaB7F5Ebe2114bc63Fbb43E642BBb" ] \
  || die "the copy's NVDA row moved"

step "VerifySolo has teeth: flip one byte of the first factory's code (anvil_setCode), it must FAIL"
T=$(echo "$TICKERS" | cut -d, -f1)
row=$(jq -c --arg t "$T" '.markets[] | select(.ticker==$t)' "$COPY")
FACTORY=$(jq -r '.deployment.factory' <<<"$row")
code=$(cast code "$FACTORY" --rpc-url "$RPC")
pos=$((2 + 2 * 100))                                  # byte 100: logic, outside every immutable slot
orig=${code:$pos:2}
flip=$(printf '%02x' $(( (16#$orig) ^ 0x01 )))
cast rpc anvil_setCode "$FACTORY" "${code:0:$pos}${flip}${code:$((pos + 2))}" --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
[ "$(cast code "$FACTORY" --rpc-url "$RPC" | cut -c$((pos + 1))-$((pos + 2)))" = "$flip" ] || die "tamper did not apply"
if (
  export FACTORY EXPECTED_TICKER=$T
  export ASSET=$(jq -r .asset <<<"$row") PRICE_FEED=$(jq -r .feed <<<"$row") DEPOSIT_CAP=$(jq -r .depositCap <<<"$row")
  export KEEPER=$(jq -r .deployment.keeper <<<"$row") GUARDIAN=$(jq -r .deployment.guardian <<<"$row")
  export ADMIN=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 FEE_RECIPIENT=$(jq -r .deployment.feeRecipient <<<"$row")
  forge script script/VerifySolo.s.sol --rpc-url "$RPC" --no-storage-caching --non-interactive
) > "$LOG/tamper-verify.log" 2>&1; then
  die "VerifySolo passed against tampered factory bytecode"
fi
grep -E "^\s+FAIL" "$LOG/tamper-verify.log"
grep -q "FAIL  factory: runtime == compiled AccountFactory" "$LOG/tamper-verify.log" || die "tamper not caught by the bytecode check"
echo "  byte 100 flipped 0x$orig -> 0x$flip on $T's factory: caught"

printf '\nREHEARSAL PASSED on fork block %s (%s); registry copy %s; logs %s\n' "$FORK_BLOCK" "$TICKERS" "$COPY" "$(pwd)/$LOG"
