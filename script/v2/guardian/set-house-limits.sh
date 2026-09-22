#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# script/v2/guardian/set-house-limits.sh — day-one GUARDIAN action: HouseVault.setLimits for one launch ticker's
# vault, from a limits file, from the guardian wallet, current limits read back before and after (T-OP-174).
#
#   script/v2/guardian/set-house-limits.sh --registry <tier1.json> --rpc <url> --ticker NVDA \
#       --limits-file script/v2/fixtures/house-limits.v8.json          # DRY RUN (default): decodes the current
#                                                                       # struct, prints the cast command, sends nothing
#   ... --send              `cast send -i` prompts for the guardian key AT THE PROMPT (never argv, file or env)
#   ... --send --unlocked   anvil fork only: impersonate the guardian
#   --signer <address>      default: registry shared.guardian
#
# The vault is markets[<ticker>].v2.houseVault, falling back to v2.contracts.houseVault when the ticker is the
# first launch ticker (the single slot VerifyV8 walks). The selector is the manifest's:
# roles.v8.json .targets.HouseVault must map `setLimits((uint64,uint128,uint16,uint16,uint32,uint128))` to GUARDIAN
# (asserted, never typed). The file has the shape of script/v2/fixtures/house-limits.v8.json (T-OP-158): keyed by
# ticker, six fields in HouseVault.Limits order -- maxSeriesUnits (uint64), maxTotalNotional (uint128, USDG base
# units), askToleranceBps (uint16), maxBidBpsOfSpot (uint16), maxOrderLifetime (uint32), maxDailyOutflow (uint128).
# Refuses: a signer without GUARDIAN (hasRole), a vault with no code, a ticker the file lacks, a field missing or
# not an unsigned integer, bps above 10000. After --send the read-back must equal the file, field by field.
# -------------------------------------------------------------------------------------------------
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
ROLES="$ROOT/script/v2/roles.v8.json"
die() { printf '\n!! %s\n' "$*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }

REGISTRY=""; RPC=""; SEND=0; UNLOCKED=0; SIGNER=""; TICKER=""; FILE=""
# A raw key is 32 bytes = 64 hex; an ADDRESS is 40 hex and is a legal argument (--signer). Refuse the key shape only.
for a in "$@"; do
  case "$a" in --private-key|--mnemonic|--keystore) die "a key-carrying flag was passed on the command line. This script takes the guardian key at cast's prompt (--send) or impersonates on a fork (--send --unlocked); never argv, never a file" ;; esac
  [[ "$a" =~ ^0x[0-9a-fA-F]{64}$ ]] && die "a key-shaped argument (0x + 64 hex) was passed on the command line. This script takes the guardian key at cast's prompt (--send) or impersonates on a fork (--send --unlocked); never argv, never a file"
done
while [ $# -gt 0 ]; do
  case "$1" in
    --registry) REGISTRY=${2:?--registry needs a path}; shift 2 ;;
    --rpc) RPC=${2:?--rpc needs a url}; shift 2 ;;
    --ticker) TICKER=$(echo "${2:?--ticker needs a symbol}" | tr '[:lower:]' '[:upper:]'); shift 2 ;;
    --limits-file) FILE=${2:?--limits-file needs a path}; shift 2 ;;
    --send) SEND=1; shift ;;
    --unlocked) UNLOCKED=1; shift ;;
    --signer) SIGNER=${2:?--signer needs an address}; shift 2 ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$REGISTRY" ] && [ -f "$REGISTRY" ] || die "--registry <written-back tier1.json> is required and must exist"
[ -n "$RPC" ] || die "--rpc <url> is required"
[ -n "$TICKER" ] || die "--ticker <symbol> is required"
[ -n "$FILE" ] && [ -f "$FILE" ] || die "--limits-file <json> is required and must exist"
for t in cast jq; do command -v "$t" >/dev/null || die "$t is not on PATH"; done
is_addr() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
jqr() { jq -r "$1" "$REGISTRY"; }

# --- the selector, from the manifest, not typed
SEL='setLimits((uint64,uint128,uint16,uint16,uint32,uint128))'
ROLE=$(jq -r --arg s "$SEL" '.targets.HouseVault[$s] // empty' "$ROLES")
[ "$ROLE" = GUARDIAN ] || die "roles.v8.json maps HouseVault.$SEL to '${ROLE:-<absent>}', not GUARDIAN: this script sends only a guardian action"
GUARDIAN_ID=$(jq -r '.roles.GUARDIAN // empty' "$ROLES"); is_uint "$GUARDIAN_ID" || die "roles.v8.json has no .roles.GUARDIAN id"

# --- the file: six fields, in Limits order, unsigned, bps within range
FIELDS="maxSeriesUnits maxTotalNotional askToleranceBps maxBidBpsOfSpot maxOrderLifetime maxDailyOutflow"
jq -e --arg t "$TICKER" 'has($t)' "$FILE" >/dev/null || die "$FILE has no entry for $TICKER (keys: $(jq -r 'keys | map(select(startswith("_") | not)) | join(",")' "$FILE"))"
VALS=""
for f in $FIELDS; do
  v=$(jq -r --arg t "$TICKER" --arg f "$f" '.[$t][$f] // empty | tostring' "$FILE")
  is_uint "$v" || die "$FILE: $TICKER.$f is '${v:-<absent>}', not an unsigned integer"
  case "$f" in *Bps) [ "$v" -le 10000 ] || die "$FILE: $TICKER.$f is $v, above 10000 bps" ;; esac
  VALS="${VALS:+$VALS,}$v"
done
TUPLE="($VALS)"

# --- the vault, from the registry
VAULT=$(jq -r --arg t "$TICKER" '.markets[] | select(.ticker == $t) | .v2.houseVault // empty' "$REGISTRY")
if [ -z "$VAULT" ]; then
  FIRST=$(jqr 'if (.launchSet.markets | type) == "array" then .launchSet.markets[0] else "" end')
  if [ "$FIRST" = "$TICKER" ]; then VAULT=$(jqr '.v2.contracts.houseVault // empty'); fi
fi
is_addr "$VAULT" || die "$TICKER: no HouseVault recorded (markets[].v2.houseVault null, and v2.contracts.houseVault is only the first launch ticker's): nothing to set limits on"
VAULT=$(cast to-check-sum-address "$VAULT")
MGR=$(jqr '.v2.contracts.accessManager // empty'); is_addr "$MGR" || die "registry v2.contracts.accessManager is null: not written back"
[ -n "$SIGNER" ] || SIGNER=$(jqr '.shared.guardian // empty'); is_addr "$SIGNER" || die "signer '$SIGNER' is not an address"; SIGNER=$(cast to-check-sum-address "$SIGNER")

# --- the chain: code, role, current limits
CHAIN=$(cast chain-id --rpc-url "$RPC") || die "no RPC at $RPC"
[ "$(cast code "$VAULT" --rpc-url "$RPC")" != "0x" ] || die "HouseVault $VAULT ($TICKER) has no code on $RPC: refusing"
[ "$(cast code "$MGR" --rpc-url "$RPC")" != "0x" ] || die "accessManager $MGR has no code on $RPC"
read -r IS_MEMBER DELAY <<<"$(cast call "$MGR" "hasRole(uint64,address)(bool,uint32)" "$GUARDIAN_ID" "$SIGNER" --rpc-url "$RPC" | tr '\n' ' ')"
say "set-house-limits $TICKER  mode=$([ "$SEND" = 1 ] && echo "SEND$([ "$UNLOCKED" = 1 ] && echo ' (fork, impersonated)' || echo ' (key at the prompt)')" || echo 'DRY RUN (default)')  chain $CHAIN"
info "vault    $VAULT"
info "signer   $SIGNER  GUARDIAN(id $GUARDIAN_ID) member=$IS_MEMBER executionDelay=$DELAY"
[ "$IS_MEMBER" = true ] || die "signer $SIGNER does NOT hold GUARDIAN (role $GUARDIAN_ID) on $MGR: refusing before anything is sent"
[ "$DELAY" = 0 ] || die "signer $SIGNER holds GUARDIAN at delay $DELAY s: setLimits is instant for the guardian; this script does not schedule"
# cast annotates any integer of five or more digits with its scientific form -- `25000000000 [2.5e10]` -- so a tuple
# read straight off `cast call` never equals the file's plain integers, the "already equal" short-circuit never
# fires, and a CORRECT send is reported as "did not set what the file says" (T-OP-200 drill on run 4's vault set;
# the same shape as T-OP-135's F7 on rehearse-v2.sh's delay read-back). The annotations are stripped BEFORE the
# comparison; the numbers themselves are untouched.
decode() { cast call "$VAULT" "limits()((uint64,uint128,uint16,uint16,uint32,uint128))" --rpc-url "$RPC" | sed -E 's/ *\[[^]]*\]//g' | tr -d '() ' ; }
BEFORE=$(decode)
info "before   $BEFORE  ($FIELDS)"
info "file     $VALS"
info "command  cast send $VAULT \"$SEL\" \"$TUPLE\" --rpc-url <rpc> --from $SIGNER $([ "$UNLOCKED" = 1 ] && echo --unlocked || echo -i)"
if [ "$BEFORE" = "$VALS" ]; then info "already  equal to the file: nothing to send"; exit 0; fi
if [ "$SEND" = 1 ]; then
  if [ "$UNLOCKED" = 1 ]; then
    cast send "$VAULT" "$SEL" "$TUPLE" --rpc-url "$RPC" --from "$SIGNER" --unlocked >/dev/null || die "setLimits send failed"
  else
    cast send "$VAULT" "$SEL" "$TUPLE" --rpc-url "$RPC" --from "$SIGNER" -i >/dev/null || die "setLimits send failed"
  fi
  AFTER=$(decode)
  info "after    $AFTER"
  [ "$AFTER" = "$VALS" ] || die "read back $AFTER, wanted $VALS: the transaction did not set what the file says"
  say "done  $TICKER limits == $FILE (read back)"
else
  info "DRY RUN: not sent (add --send)"
fi
