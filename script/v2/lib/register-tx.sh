#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# register-tx.sh — how script/v2/DeployV2Batch.sh finds the `registerMarket` transaction of a market it
# just registered, so that `v2.registeredAt` / `v2.registerTx` can be written back.
#
# Sourced (never executed) by DeployV2Batch.sh and exercised by script/v2/batch-refusals.sh, which is why it
# is a file of its own: the lookup matches raw calldata by selector, so a signature that drifts from the
# compiled ABI silently finds nothing and every run falls through to scanning the Clearinghouse's logs.
# INTERFACE_VERSION 8 deleted the one-tuple overload. Clearinghouse.registerMarket is now
# `registerMarket(address underlying, uint64 strikeTick, bool enabled)` only (src/v2/Clearinghouse.sol).
# The selector is re-derived with `cast sig` and pinned by batch-refusals.sh against
# out/Clearinghouse.sol/Clearinghouse.json. v6 was `0x45baaccb`, v7 `0xfb2a821f`, v8 `0x9ae621ee`
# (`docs/DEPLOY-V2.md` and InterfaceIds.t.sol). Do not copy a selector from a plan document.
#
# Needs `cast` and `jq` on PATH. No node call: `cast sig` and `cast abi-encode` are offline.
# -------------------------------------------------------------------------------------------------

# The signature the recorder matches. `batch-refusals.sh` pins it against out/Clearinghouse.sol/Clearinghouse.json,
# so it can never drift from the compiled ABI again.
REGISTER_SIG="registerMarket(address,uint64,bool)"

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

# ---- T-OP-194: the two halves of a registration's write-back that broadcast-v8.sh shares with the wrapper.
# DeployV2Batch.sh registers a market, derives its registerMarket transaction with register_tx above, falls
# back to the Clearinghouse's MarketRegistered logs, and writes v2.registeredAt / v2.registerTx into the
# registry (its `write_back market`). broadcast-v8.sh step 3 used to do the first of those and NONE of the rest,
# leaving the write-back to the operator between steps -- so a correct run reached step 5 with registeredAt
# still null, registered_sets told VerifyV8 the launch markets were unregistered, and VerifyV8 FAILED a correct
# deployment (T-OP-175 #2, T-OP-154 F7). The two functions below are the log fallback and the record, as
# functions of their arguments only (no caller variable is read), so both drivers can call them. The wrapper's
# own inline copies are NOT replaced here: DeployV2Batch.sh is outside T-OP-194's fence; moving it onto these is
# a later row. Until then this file holds the one derivation and the wrapper the one write-back it always had.

# The MarketRegistered topic the fallback scans for. The tuple is V2Types.MarketConfig as of INTERFACE_VERSION 7
# (mintFeePpm appended). Asserted against out/Clearinghouse.sol/Clearinghouse.json before T-OP-194 published it:
#   keccak = 0x9ffefa3e10b786e4dc202bedcdb98708c0feff476372922f9343e2f0c6010100
REGISTERED_EVENT_SIG="MarketRegistered(address,(bool,bool,uint64,uint16,address,uint32))"

# register_tx_logs <rpc> <clearinghouse> <asset> [<from-block>]
#   Prints "<transactionHash> <blockNumber>" of the LAST MarketRegistered(asset, ...) log the Clearinghouse
#   emitted since <from-block> (default 0), or nothing (exit 0) when there is none. The fallback for a market
#   registered by an earlier run whose write-back never happened: forge's run-latest.json is that run's, not
#   this one's, so the chain is asked instead.
register_tx_logs() {
  local rpc=$1 ch=$2 asset=$3 from=${4:-0} topic0 topic1 logs
  topic0=$(cast keccak "$REGISTERED_EVENT_SIG")
  topic1=$(cast abi-encode "f(address)" "$asset")
  logs=$(cast logs --from-block "$from" --to-block latest --address "$ch" "$topic0" "$topic1" --rpc-url "$rpc" --json 2>/dev/null || echo '[]')
  local tx blk
  tx=$(jq -r '.[-1].transactionHash // empty' <<<"$logs")
  blk=$(jq -r '.[-1].blockNumber // empty' <<<"$logs")
  [ -n "$tx" ] && [ -n "$blk" ] || return 0
  echo "$tx $blk"
}

# register_record <registry> <ticker> <registeredAt> <registerTx>
#   Writes markets[<ticker>].v2.registeredAt / .v2.registerTx into <registry> (tmp file + rename, jq only: no
#   node). IDEMPOTENT: a row that already records exactly these values is left alone and the file is not
#   rewritten; a row that records DIFFERENT non-null values is REFUSED (a registration is recorded once and never
#   overwritten by a later run's memory -- the same rule as the wrapper's write_back contracts). Prints one line
#   `recorded` / `already recorded` on stdout; a refusal prints on stderr and returns 1. The caller dies on it.
register_record() {
  local reg=$1 t=$2 at=$3 tx=$4 have_at have_tx
  [ -f "$reg" ] || { echo "register_record: registry not found: $reg" >&2; return 1; }
  case "$at" in ''|*[!0-9]*) echo "register_record: $t: registeredAt '$at' is not an unsigned integer" >&2; return 1 ;; esac
  case "$tx" in 0x[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]*) ;; *) echo "register_record: $t: registerTx '$tx' is not a transaction hash" >&2; return 1 ;; esac
  jq -e --arg t "$t" '[.markets[] | select(.ticker == $t)] | length == 1' "$reg" >/dev/null 2>&1 \
    || { echo "register_record: no registry row for $t in $reg" >&2; return 1; }
  have_at=$(jq -r --arg t "$t" '.markets[] | select(.ticker == $t) | .v2.registeredAt // empty' "$reg")
  have_tx=$(jq -r --arg t "$t" '.markets[] | select(.ticker == $t) | .v2.registerTx // empty' "$reg")
  if [ -n "$have_at" ] || [ -n "$have_tx" ]; then
    if [ "$have_at" = "$at" ] && [ "$(echo "$have_tx" | tr 'A-F' 'a-f')" = "$(echo "$tx" | tr 'A-F' 'a-f')" ]; then
      echo "already recorded: $t v2.registeredAt $at registerTx $tx (unchanged)"; return 0
    fi
    echo "register_record: $t already records registeredAt ${have_at:-null} registerTx ${have_tx:-null}; this run says $at $tx: refusing to overwrite a recorded registration" >&2
    return 1
  fi
  jq --arg t "$t" --argjson at "$at" --arg tx "$tx" \
    '(.markets[] | select(.ticker == $t) | .v2) |= (.registeredAt = $at | .registerTx = $tx)' "$reg" > "$reg.tmp" \
    || { rm -f "$reg.tmp"; echo "register_record: jq failed writing $t into $reg" >&2; return 1; }
  mv "$reg.tmp" "$reg"
  echo "recorded: $t v2.registeredAt $at registerTx $tx"
}
