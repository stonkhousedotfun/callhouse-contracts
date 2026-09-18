#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# register-tx.sh — how script/v2/DeployV2Batch.sh finds the `registerMarket` transaction of a market it
# just registered, so that `v2.registeredAt` / `v2.registerTx` can be written back.
#
# Sourced (never executed) by DeployV2Batch.sh and exercised by script/v2/batch-refusals.sh, which is why it
# is a file of its own: the lookup matches raw calldata by selector, so a signature that drifts from the
# compiled ABI silently finds nothing and every run falls through to scanning the Clearinghouse's logs.
# INTERFACE_VERSION 7 appended `uint32 mintFeePpm` to `MarketConfig` (v7 design §4.1, DECISIONS §12), which
# moved the selector `0x45baaccb` -> `0xfb2a821f`.
#
# Needs `cast` and `jq` on PATH. No node call: `cast sig` and `cast abi-encode` are offline.
# -------------------------------------------------------------------------------------------------

# The signature the recorder matches. `batch-refusals.sh` pins it against out/Clearinghouse.sol/Clearinghouse.json,
# so it can never drift from the compiled ABI again.
REGISTER_SIG="registerMarket(address,(bool,bool,uint64,uint16,address,uint32))"

# register_tx <forge run-latest.json> <clearinghouse> <asset>
#   Prints "<transactionHash> <blockNumber>" of the MINED, SUCCESSFUL registerMarket(asset, ...) call to
#   <clearinghouse> in that forge broadcast record, or nothing at all (exit 0) when the record does not hold one:
#   a missing file, another asset, another contract, a v6-shaped call or a reverted receipt all print nothing, and
#   the caller then falls back to the Clearinghouse's MarketRegistered logs.
register_tx() {
  local run=$1 ch asset want tx st blk
  [ -f "$run" ] || return 0
  ch=$(echo "$2" | tr 'A-F' 'a-f')
  asset=$3
  # selector + the first argument, which is the asset: the one registerMarket call this market's run made
  want="$(cast sig "$REGISTER_SIG")$(cast abi-encode "f(address)" "$asset" | sed "s/^0x//" | tr "A-F" "a-f")"
  tx=$(jq -r --arg ch "$ch" --arg want "$want" '[.transactions[] | select(((.transaction.to // "") | ascii_downcase) == $ch and ((.transaction.input // .transaction.data // "") | ascii_downcase | startswith($want))) | .hash][0] // empty' "$run")
  [ -n "$tx" ] || return 0
  st=$(jq -r --arg h "$tx" '[.receipts[] | select(.transactionHash == $h) | .status][0] // empty' "$run")
  blk=$(jq -r --arg h "$tx" '[.receipts[] | select(.transactionHash == $h) | .blockNumber][0] // empty' "$run")
  [ "$st" = 0x1 ] && [ -n "$blk" ] || return 0
  echo "$tx $blk"
}

# register_abi_sig <path to out/Clearinghouse.sol/Clearinghouse.json>
#   Prints the compiled `registerMarket` signature, tuple flattened, the way `cast sig` wants it.
register_abi_sig() {
  jq -r '
    def t: if (.type | startswith("tuple")) then "(" + ([.components[] | t] | join(",")) + ")" + (.type | ltrimstr("tuple"))
           else .type end;
    [.abi[] | select(.type == "function" and .name == "registerMarket")
      | "registerMarket(" + ([.inputs[] | t] | join(",")) + ")"][0] // empty
  ' "$1"
}
