#!/usr/bin/env bash
# Prints the v4 payout-route pins out of the committed registry fixture as KEY=VALUE lines, so the pin
# assertion in test/v2/unit/PayoutRoutePin.t.sol reads the SAME source production reads.
# DeployV2Batch.sh:605-618 exports V2_MARKET_<T>_PAYOUT_{VENUE,FEE,TICK_SPACING,POOL_ID} out of
# markets[].v2.payoutRoute for RegisterMarkets, and RegisterMarkets._requirePinnedPool takes the pin from
# the environment rather than from the file. This is the read-only slice of that export.
#
# It exists because foundry.toml's fs_permissions grants no read access to script/v2/fixtures/, and the one
# thing the pin must NOT do is carry the pinned poolIds as literals in its own source -- a pin asserted
# against a copy of itself proves nothing.
#
#   bash script/v2/lib/route-pins.sh -- forge test --match-path test/v2/unit/PayoutRoutePin.t.sol
#
# Prefer that form over `env $(bash route-pins.sh) forge test ...`: command substitution DISCARDS this
# script's exit status, so a fixture that lost a pin would hand forge a partial environment and let it run.
# With `--` the command is exec'd from here and a failed export means it never starts at all.
#
# Prints, never exports: sourcing it would depend on the caller's shell word-splitting rules (zsh does not
# split unquoted parameter expansions, so a `for T in $TICKERS` loop silently produced one bogus ticker).
set -euo pipefail
REG=${REG:-$(cd "$(dirname "$0")/../../.." && pwd)/script/v2/fixtures/registry-v8.json}
command -v jq >/dev/null || { echo "route-pins.sh: jq not on PATH" >&2; exit 1; }
[ -r "$REG" ] || { echo "route-pins.sh: cannot read registry fixture: $REG" >&2; exit 1; }

PINS=()
emit() { # emit <VAR> <jq filter> -- empty or null is a hard error, never a silently absent pin
  local v; v=$(jq -er "$2" "$REG") || { echo "route-pins.sh: $REG has no $2" >&2; exit 1; }
  [ -n "$v" ] && [ "$v" != "null" ] || { echo "route-pins.sh: $2 is empty in $REG" >&2; exit 1; }
  PINS+=("$1=$v")
}

emit V2_USDG '.shared.usdg'
for T in ${TICKERS:-NVDA TSLA}; do
  emit "V2_MARKET_${T}_ASSET"               ".markets[]|select(.ticker==\"$T\")|.asset"
  emit "V2_MARKET_${T}_PAYOUT_FEE"          ".markets[]|select(.ticker==\"$T\")|.v2.payoutRoute.fee"
  emit "V2_MARKET_${T}_PAYOUT_TICK_SPACING" ".markets[]|select(.ticker==\"$T\")|.v2.payoutRoute.tickSpacing"
  emit "V2_MARKET_${T}_PAYOUT_POOL_ID"      ".markets[]|select(.ticker==\"$T\")|.v2.payoutRoute.poolId"
done

# Every pin resolved before anything is printed or run: a partial export is never observable.
if [ "${1:-}" = "--" ]; then
  shift
  [ $# -gt 0 ] || { echo "route-pins.sh: -- needs a command" >&2; exit 1; }
  exec env "${PINS[@]}" "$@"
fi
printf '%s\n' "${PINS[@]}"
