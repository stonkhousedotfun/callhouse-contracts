#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# script/v2/guardian/pause.sh — day-one GUARDIAN action: pause (or, with --unpause, unpause) every pause switch
# the guardian holds, from the guardian wallet, with the on-chain state read back before and after (T-OP-174).
#
#   script/v2/guardian/pause.sh   --registry <tier1.json> --rpc <url>                 # DRY RUN (default): prints
#   script/v2/guardian/unpause.sh --registry <tier1.json> --rpc <url>                 # the state and every cast
#                                                                                     # command; sends nothing
#   ... --send                      the real thing: `cast send -i` prompts for the guardian key AT THE PROMPT --
#                                   never on argv, never from a file, never from the environment
#   ... --send --unlocked           on an anvil fork only: impersonate the guardian (`--from`, `--unlocked`)
#   --signer <address>              the guardian address to check and send from (default: registry shared.guardian)
#   --only <Target.selector,...>    restrict to these manifest entries (e.g. OrderBook.setTradingPaused(bool))
#
# WHAT IS PAUSED, DERIVED, NEVER TYPED. script/v2/roles.v8.json `.targets` maps selectors to roles; this script
# takes every selector mapped to GUARDIAN whose shape is a pause switch -- `(bool)` or `(address,bool)` -- and
# nothing else (veto/unveto, clearRoute and setLimits are GUARDIAN too and are NOT pauses; set-house-limits.sh
# owns setLimits). Today that is: Clearinghouse.setCreatePaused(bool), Clearinghouse.setMintPaused(address,bool)
# per launch-set underlying, OrderBook.setTradingPaused(bool), FeeSplitter.setPaused(bool),
# HouseVault.setQuotingPaused(bool) per vault (v2.contracts.houseVault + markets[].v2.houseVault), Hedger.pause(bool)
# when a hedger is recorded. Adding a GUARDIAN pause switch to the manifest adds it here; removing one removes it.
#
# ADDRESSES come from --registry (the written-back tier1.json; on the drill the run-4 copy). The AccessManager is
# v2.contracts.accessManager. A target that is null in the registry is SKIPPED AND SAID; a target that has no code
# on --rpc is a REFUSAL; a signer that does not hold GUARDIAN (`hasRole(<GUARDIAN id>, signer)`, id from the
# manifest) is a REFUSAL, before anything is sent. The default is a dry run: nothing is sent without --send.
# -------------------------------------------------------------------------------------------------
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
ROLES="$ROOT/script/v2/roles.v8.json"
die() { printf '\n!! %s\n' "$*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }

REGISTRY=""; RPC=""; SEND=0; UNLOCKED=0; SIGNER=""; ONLY=""; MODE=pause
# A raw key is 32 bytes = 64 hex; an ADDRESS is 40 hex and is a legal argument (--signer). Refuse the key shape only.
for a in "$@"; do
  case "$a" in --private-key|--mnemonic|--keystore) die "a key-carrying flag was passed on the command line. This script takes the guardian key at cast's prompt (--send) or impersonates on a fork (--send --unlocked); never argv, never a file" ;; esac
  [[ "$a" =~ ^0x[0-9a-fA-F]{64}$ ]] && die "a key-shaped argument (0x + 64 hex) was passed on the command line. This script takes the guardian key at cast's prompt (--send) or impersonates on a fork (--send --unlocked); never argv, never a file"
done
while [ $# -gt 0 ]; do
  case "$1" in
    --registry) REGISTRY=${2:?--registry needs a path}; shift 2 ;;
    --rpc) RPC=${2:?--rpc needs a url}; shift 2 ;;
    --send) SEND=1; shift ;;
    --unlocked) UNLOCKED=1; shift ;;
    --unpause) MODE=unpause; shift ;;
    --signer) SIGNER=${2:?--signer needs an address}; shift 2 ;;
    --only) ONLY=${2:?--only needs Target.selector,...}; shift 2 ;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$REGISTRY" ] && [ -f "$REGISTRY" ] || die "--registry <written-back tier1.json> is required and must exist"
[ -n "$RPC" ] || die "--rpc <url> is required"
[ -f "$ROLES" ] || die "manifest not found: $ROLES"
for t in cast jq; do command -v "$t" >/dev/null || die "$t is not on PATH"; done
is_addr() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
jqr() { jq -r "$1" "$REGISTRY"; }

# --- the signer and its role, read off the manager BEFORE anything else
MGR=$(jqr '.v2.contracts.accessManager // empty'); is_addr "$MGR" || die "registry v2.contracts.accessManager is null or not an address: this registry is not written back"
[ -n "$SIGNER" ] || SIGNER=$(jqr '.shared.guardian // empty')
is_addr "$SIGNER" || die "signer '$SIGNER' is not an address (from --signer, else registry shared.guardian)"
SIGNER=$(cast to-check-sum-address "$SIGNER")
GUARDIAN_ID=$(jq -r '.roles.GUARDIAN // empty' "$ROLES"); [[ "$GUARDIAN_ID" =~ ^[0-9]+$ ]] || die "roles.v8.json has no .roles.GUARDIAN id"
CHAIN=$(cast chain-id --rpc-url "$RPC") || die "no RPC at $RPC"
MCODE=$(cast code "$MGR" --rpc-url "$RPC"); [ "$MCODE" != "0x" ] || die "accessManager $MGR has no code on $RPC (chain $CHAIN)"
read -r IS_MEMBER DELAY <<<"$(cast call "$MGR" "hasRole(uint64,address)(bool,uint32)" "$GUARDIAN_ID" "$SIGNER" --rpc-url "$RPC" | tr '\n' ' ')"
say "guardian $MODE  mode=$([ "$SEND" = 1 ] && echo "SEND$([ "$UNLOCKED" = 1 ] && echo ' (fork, impersonated)' || echo ' (key at the prompt)')" || echo 'DRY RUN (default)')  chain $CHAIN"
info "signer         $SIGNER  GUARDIAN(id $GUARDIAN_ID) member=$IS_MEMBER executionDelay=$DELAY"
[ "$IS_MEMBER" = true ] || die "signer $SIGNER does NOT hold GUARDIAN (role $GUARDIAN_ID) on $MGR: refusing before anything is sent. The registry's shared.guardian is $(jqr '.shared.guardian // "null"')"
[ "$DELAY" = 0 ] || die "signer $SIGNER holds GUARDIAN at execution delay $DELAY s: a pause is an instant action and this script does not schedule"

# --- the pause set, derived from the manifest: GUARDIAN selectors shaped (bool) or (address,bool)
target_addr() { # manifest target name -> registry address(es), space-separated, empty when null
  case "$1" in
    Clearinghouse) jqr '.v2.contracts.clearinghouse // empty' ;;
    OrderBook) jqr '.v2.contracts.orderBook // empty' ;;
    SettlementOracle) jqr '.v2.contracts.settlementOracle // empty' ;;
    PayoutRouter) jqr '.v2.contracts.payoutAdapter // empty' ;;
    FeeSplitter) jqr '.v2.flywheel.feeSplitter // empty' ;;
    HouseVault) { jqr '.v2.contracts.houseVault // empty'; jqr '.markets[].v2.houseVault // empty'; } | awk 'NF' | tr 'A-F' 'a-f' | sort -u | tr '\n' ' ' ;;
    Hedger) jqr '.v2.contracts.hedger // empty' ;;
    EarnVault) jqr '.v2.contracts.earnVault // empty' ;;
    *) echo "" ;;
  esac
}
# the read-back view for each pause selector (the contract's public flag), by signature
view_of() { # target selector -> "viewSig" or "" (the per-underlying one takes the asset)
  case "$1.$2" in
    Clearinghouse.setCreatePaused\(bool\)) echo "createPaused()(bool)" ;;
    Clearinghouse.setMintPaused\(address,bool\)) echo "MARKET" ;;
    OrderBook.setTradingPaused\(bool\)) echo "tradingPaused()(bool)" ;;
    FeeSplitter.setPaused\(bool\)) echo "paused()(bool)" ;;
    HouseVault.setQuotingPaused\(bool\)) echo "quotingPaused()(bool)" ;;
    Hedger.pause\(bool\)) echo "paused()(bool)" ;;
    *) echo "" ;;
  esac
}
WANT=$([ "$MODE" = pause ] && echo true || echo false)
LAUNCH_ASSETS=$(jqr 'if (.launchSet.markets | type) == "array" then [.launchSet.markets[] as $t | .markets[] | select(.ticker == $t) | .asset] | join(" ") else "" end')
[ -n "$LAUNCH_ASSETS" ] || die "registry has no launchSet.markets (or the tickers have no asset): the per-underlying mint pause has no subject"

N=0; SENT=0; SKIPPED=""
while IFS=$'\t' read -r target sel; do
  [ -n "$target" ] || continue
  case "$sel" in *"(bool)"|*"(address,bool)") ;; *) continue ;; esac     # pause switches only
  if [ -n "$ONLY" ]; then case ",$ONLY," in *",$target.$sel,"*) ;; *) continue ;; esac; fi
  view=$(view_of "$target" "$sel")
  [ -n "$view" ] || die "manifest maps $target.$sel to GUARDIAN with a pause shape this script has no read-back for: add its view here (never send a switch you cannot read back)"
  addrs=$(target_addr "$target")
  if [ -z "$addrs" ]; then SKIPPED="${SKIPPED:+$SKIPPED, }$target ($sel): null in the registry"; continue; fi
  for addr in $addrs; do
    addr=$(cast to-check-sum-address "$addr")
    code=$(cast code "$addr" --rpc-url "$RPC"); [ "$code" != "0x" ] || die "$target $addr has no code on $RPC: refusing. The registry names a contract the chain does not have"
    subjects="-"; [ "$view" = MARKET ] && subjects=$LAUNCH_ASSETS
    for subj in $subjects; do
      N=$((N + 1))
      if [ "$view" = MARKET ]; then
        before=$(cast call "$addr" "market(address)((bool,bool,uint64,uint16,address,uint32))" "$subj" --rpc-url "$RPC" | sed -E 's/^\(([a-z]+), ([a-z]+),.*/\2/')
        args="$subj $WANT"; label="$target.$sel underlying $subj"
      else
        before=$(cast call "$addr" "$view" --rpc-url "$RPC")
        args="$WANT"; label="$target.$sel"
      fi
      say "$label @ $addr"
      info "before   paused=$before"
      # shellcheck disable=SC2086
      info "command  cast send $addr \"$sel\" $args --rpc-url <rpc> --from $SIGNER $([ "$UNLOCKED" = 1 ] && echo --unlocked || echo -i)"
      if [ "$before" = "$WANT" ]; then info "already  paused=$WANT: nothing to send"; continue; fi
      if [ "$SEND" = 1 ]; then
        if [ "$UNLOCKED" = 1 ]; then
          # shellcheck disable=SC2086
          cast send "$addr" "$sel" $args --rpc-url "$RPC" --from "$SIGNER" --unlocked >/dev/null || die "$label: send failed"
        else
          # shellcheck disable=SC2086
          cast send "$addr" "$sel" $args --rpc-url "$RPC" --from "$SIGNER" -i >/dev/null || die "$label: send failed"
        fi
        SENT=$((SENT + 1))
        if [ "$view" = MARKET ]; then
          after=$(cast call "$addr" "market(address)((bool,bool,uint64,uint16,address,uint32))" "$subj" --rpc-url "$RPC" | sed -E 's/^\(([a-z]+), ([a-z]+),.*/\2/')
        else
          after=$(cast call "$addr" "$view" --rpc-url "$RPC")
        fi
        info "after    paused=$after"
        [ "$after" = "$WANT" ] || die "$label: read back paused=$after, wanted $WANT -- the transaction did not do what it said"
      else
        info "DRY RUN: not sent (add --send)"
      fi
    done
  done
done < <(jq -r '.targets | to_entries[] | .key as $t | .value | to_entries[] | select(.value == "GUARDIAN") | [$t, .key] | @tsv' "$ROLES")

say "done  $MODE: $N switch(es) considered, $SENT sent$([ "$SEND" = 1 ] || echo ' (DRY RUN)')"
[ -z "$SKIPPED" ] || info "skipped (null in the registry, said not sent): $SKIPPED"
