#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# rehearse-lender-rewards.sh — fork rehearsal of the LENDER RewardsDistributor (P8-05): starts its own
# anvil fork of chain 4663, deploys the instance with script/v2/DeployLenderRewards.s.sol against the
# REAL $STONKHOUSE token, maps its three selectors and posts one epoch root through the manager's
# schedule -> wait -> execute path with the Admin Safe IMPERSONATED, funds it from a real token holder,
# claims one entry and asserts the delivery is exact. Writes a record file and kills the anvil on exit.
#
#   script/v2/rehearse-lender-rewards.sh
#   PORT=8553 EPOCH=2960 script/v2/rehearse-lender-rewards.sh
#
# Modelled on script/v2/rehearse-v2.sh, which it does NOT touch: that file is the v2 batch rehearsal and
# belongs to a different task.
#
# Environment: FORK_URL (default the public Robinhood Chain RPC), PORT (8553), EPOCH (2960),
# V2_STONKHOUSE_TOKEN, V2_ACCESS_MANAGER, V2_ADMIN_SAFE, V2_TREASURY_SAFE (all required — this script
# refuses to guess an address), V2_STONKHOUSE_HOLDER (a real holder to impersonate for the funding leg).
#
# IT REFUSES TO RUN ANYWHERE BUT A LOCAL FORK. Every step below SENDS TRANSACTIONS and impersonates the
# Admin Safe, so the RPC must be on 127.0.0.1 and must report chain id 4663. Pointing this at a real RPC
# would be an attempt to send live admin transactions; the guard is not a convenience.
#
# THE TOKEN ADDRESS IS RE-DERIVED. decimals() and symbol() are read off whatever address is supplied and
# anything that is not an 18-decimal STONKHOUSE is refused. A 6-decimal token here would rehearse a
# distributor that pays a millionth of every reward and report success while doing it.
# -------------------------------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT=$(pwd)
export PATH="$HOME/.foundry/bin:$PATH"

FORK_URL=${FORK_URL:-https://rpc.mainnet.chain.robinhood.com}
PORT=${PORT:-8553}
EPOCH=${EPOCH:-2960}
RPC="http://127.0.0.1:$PORT"

die() { echo "REHEARSAL FAILED: $*" >&2; exit 1; }
step() { printf '\n== %s  (+%ss)\n' "$*" "$(( $(date +%s) - T0 ))"; }
T0=$(date +%s)

for tool in anvil forge cast jq python3; do command -v "$tool" >/dev/null || die "$tool not on PATH"; done
for v in V2_STONKHOUSE_TOKEN V2_ACCESS_MANAGER V2_ADMIN_SAFE V2_TREASURY_SAFE V2_STONKHOUSE_HOLDER; do
  [ -n "${!v:-}" ] || die "$v is not set; this script does not guess addresses"
done

# 18-decimal amounts do not fit in bash arithmetic. $((...)) is 64-bit SIGNED (max ~9.22e18) and 1,000
# tokens at 18 dp is 1e21, so a bare $((after - before)) WRAPS and the assertion built on it would pass
# on a wrong number. Everything below goes through python3, which has arbitrary-precision integers.
bigsub() { python3 -c 'import sys;print(int(sys.argv[1])-int(sys.argv[2]))' "$1" "$2"; }
bigge()  { python3 -c 'import sys;sys.exit(0 if int(sys.argv[1])>=int(sys.argv[2]) else 1)' "$1" "$2"; }

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOG=broadcast/lender-rewards-rehearsal/$STAMP
mkdir -p "$LOG"
echo "rehearsal logs: $ROOT/$LOG"

step "forge build (before the fork clock starts)"
forge build > "$LOG/build.log" 2>&1 || { tail -30 "$LOG/build.log"; die "forge build failed"; }

if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then die "something already answers on $RPC; pick another PORT"; fi
step "anvil fork of $FORK_URL on $RPC"
anvil --fork-url "$FORK_URL" --chain-id 4663 --port "$PORT" --code-size-limit 98304 \
  --retries 12 --fork-retry-backoff 1000 --timeout 60000 > "$LOG/anvil.log" 2>&1 &
ANVIL_PID=$!
trap 'kill "$ANVIL_PID" 2>/dev/null || true; echo "anvil (pid $ANVIL_PID) stopped"' EXIT
for _ in $(seq 1 120); do
  if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then break; fi
  kill -0 "$ANVIL_PID" 2>/dev/null || { tail -20 "$LOG/anvil.log"; die "anvil exited"; }
  sleep 1
done

# The guard. Both halves matter: the chain id says "this is 4663", the host says "and it is ours".
case "$RPC" in http://127.0.0.1:*) ;; *) die "refusing to run against $RPC: this script only drives a local fork";; esac
[ "$(cast chain-id --rpc-url "$RPC")" = "4663" ] || die "the fork does not report chain id 4663"
FORK_BLOCK=$(cast block-number --rpc-url "$RPC")
echo "fork block: $FORK_BLOCK"

step "the token is an 18-decimal STONKHOUSE (re-derived, not trusted)"
TOKEN_CODE=$(cast code "$V2_STONKHOUSE_TOKEN" --rpc-url "$RPC")
[ "$TOKEN_CODE" != "0x" ] || die "V2_STONKHOUSE_TOKEN $V2_STONKHOUSE_TOKEN has no code on this fork"
DECIMALS=$(cast call "$V2_STONKHOUSE_TOKEN" "decimals()(uint8)" --rpc-url "$RPC")
SYMBOL=$(cast call "$V2_STONKHOUSE_TOKEN" "symbol()(string)" --rpc-url "$RPC" | tr -d '"')
[ "$DECIMALS" = "18" ] || die "the token reports $DECIMALS decimals, not 18"
[ "$SYMBOL" = "STONKHOUSE" ] || die "the token is $SYMBOL, not STONKHOUSE"
echo "token ok: $SYMBOL, $DECIMALS decimals"

# anvil's first unlocked account pays for the deploy and for the pushed claim. It holds no role.
DEPLOYER=$(cast rpc eth_accounts --rpc-url "$RPC" | jq -r '.[0]')
export V2_DEPLOYER=$DEPLOYER
cast rpc anvil_setBalance "$DEPLOYER" 0x56BC75E2D63100000 --rpc-url "$RPC" > /dev/null

step "deploy the lender instance"
forge script script/v2/DeployLenderRewards.s.sol --rpc-url "$RPC" --broadcast --unlocked --sender "$DEPLOYER" \
  > "$LOG/deploy.log" 2>&1 || { tail -40 "$LOG/deploy.log"; die "DeployLenderRewards failed"; }
LENDER=$(grep -o '"lenderRewardsDistributor": *"0x[0-9a-fA-F]\{40\}"' "$LOG/deploy.log" | tail -1 | grep -o '0x[0-9a-fA-F]\{40\}')
[ -n "$LENDER" ] || { tail -40 "$LOG/deploy.log"; die "could not read the deployed address out of the deploy log"; }
echo "lender: $LENDER"

# The Admin Safe is impersonated from here on. Nothing below is sent from a plain admin key: that is the
# whole point of rehearsing the v8 path rather than a shortcut.
cast rpc anvil_impersonateAccount "$V2_ADMIN_SAFE" --rpc-url "$RPC" > /dev/null
cast rpc anvil_setBalance "$V2_ADMIN_SAFE" 0x56BC75E2D63100000 --rpc-url "$RPC" > /dev/null

# schedule -> wait -> execute against the manager. `schedule(target, data, 0)` means "at the earliest the
# caller's execution delay allows"; the manager itself is the target for its own admin functions.
schedule_and_execute() {
  local target=$1 data=$2 delay=$3 what=$4
  cast send "$V2_ACCESS_MANAGER" "schedule(address,bytes,uint48)" "$target" "$data" 0 \
    --from "$V2_ADMIN_SAFE" --unlocked --rpc-url "$RPC" > "$LOG/schedule-$what.log" 2>&1 \
    || { tail -20 "$LOG/schedule-$what.log"; die "schedule($what) reverted"; }
  cast rpc evm_increaseTime "$((delay + 1))" --rpc-url "$RPC" > /dev/null
  cast rpc evm_mine --rpc-url "$RPC" > /dev/null
  cast send "$V2_ACCESS_MANAGER" "execute(address,bytes)" "$target" "$data" \
    --from "$V2_ADMIN_SAFE" --unlocked --rpc-url "$RPC" > "$LOG/execute-$what.log" 2>&1 \
    || { tail -20 "$LOG/execute-$what.log"; die "execute($what) reverted"; }
  echo "  $what: scheduled, waited ${delay}s, executed"
}

ADMIN_DELAY=$(jq -r '.delaysS.ADMIN' script/v2/roles.v8.json)
TREASURY_DELAY=$(jq -r '.delaysS.TREASURY_ADMIN' script/v2/roles.v8.json)
TREASURY_ROLE=$(jq -r '.roles.TREASURY_ADMIN' script/v2/roles.v8.json)

step "map the lender's three selectors (ADMIN, ${ADMIN_DELAY}s)"
# The signatures and their role come from the manifest; nothing here types a selector.
# NOT `jq ... | while read`: a piped loop runs in a subshell, where `die` would kill only the subshell
# and leave the run going with the selectors unmapped. The signatures are read into the parent shell.
SIGS=()
while IFS= read -r sig; do SIGS+=("$sig"); done < <(jq -r '.targets.RewardsDistributorLender | keys[]' script/v2/roles.v8.json)
[ ${#SIGS[@]} -ne 0 ] || die "roles.v8.json lists no selectors under .targets.RewardsDistributorLender"
for sig in "${SIGS[@]}"; do
  SEL=$(cast sig "$sig")
  DATA=$(cast calldata "setTargetFunctionRole(address,bytes4[],uint64)" "$LENDER" "[$SEL]" "$TREASURY_ROLE")
  schedule_and_execute "$V2_ACCESS_MANAGER" "$DATA" "$ADMIN_DELAY" "map-$SEL"
done

step "fund the instance from the impersonated holder $V2_STONKHOUSE_HOLDER"
TOTAL=${TOTAL:-1000000000000000000000}   # 1,000 tokens, 18 dp
HOLDER_BAL=$(cast call "$V2_STONKHOUSE_TOKEN" "balanceOf(address)(uint256)" "$V2_STONKHOUSE_HOLDER" --rpc-url "$RPC" | awk '{print $1}')
bigge "$HOLDER_BAL" "$TOTAL" || die "V2_STONKHOUSE_HOLDER holds $HOLDER_BAL, less than the $TOTAL this rehearsal funds"
cast rpc anvil_impersonateAccount "$V2_STONKHOUSE_HOLDER" --rpc-url "$RPC" > /dev/null
cast rpc anvil_setBalance "$V2_STONKHOUSE_HOLDER" 0x56BC75E2D63100000 --rpc-url "$RPC" > /dev/null
cast send "$V2_STONKHOUSE_TOKEN" "approve(address,uint256)" "$LENDER" "$TOTAL" \
  --from "$V2_STONKHOUSE_HOLDER" --unlocked --rpc-url "$RPC" > "$LOG/approve.log" 2>&1 || die "approve reverted"
LENDER_BEFORE=$(cast call "$V2_STONKHOUSE_TOKEN" "balanceOf(address)(uint256)" "$LENDER" --rpc-url "$RPC" | awk '{print $1}')
cast send "$LENDER" "fund(uint256)" "$TOTAL" \
  --from "$V2_STONKHOUSE_HOLDER" --unlocked --rpc-url "$RPC" > "$LOG/fund.log" 2>&1 || die "fund reverted"
LENDER_AFTER=$(cast call "$V2_STONKHOUSE_TOKEN" "balanceOf(address)(uint256)" "$LENDER" --rpc-url "$RPC" | awk '{print $1}')
FUNDED=$(bigsub "$LENDER_AFTER" "$LENDER_BEFORE")
[ "$FUNDED" = "$TOTAL" ] || die "fund delivered $FUNDED, not $TOTAL (a fee-on-transfer token would show up exactly here)"
echo "  funded exactly $FUNDED"

step "post one root (TREASURY_ADMIN, ${TREASURY_DELAY}s)"
# A one-entry epoch: the account is the deployer, the amount is the whole total, so the single leaf IS the
# root and the proof is empty. The leaf formula mirrors src/v2/mm/RewardsDistributor.sol:201.
INNER=$(cast keccak "$(cast abi-encode "f(uint256,uint256,address,uint256)" "$EPOCH" 0 "$DEPLOYER" "$TOTAL")")
ROOT=$(cast keccak "$INNER")
DATA=$(cast calldata "setRoot(uint256,bytes32,uint256)" "$EPOCH" "$ROOT" "$TOTAL")
schedule_and_execute "$LENDER" "$DATA" "$TREASURY_DELAY" "setRoot"
ONCHAIN_ROOT=$(cast call "$LENDER" "root(uint256)(bytes32)" "$EPOCH" --rpc-url "$RPC")
[ "$ONCHAIN_ROOT" = "$ROOT" ] || die "the posted root is $ONCHAIN_ROOT, not $ROOT"

step "claim, and assert the delivery is exact"
CLAIMER_BEFORE=$(cast call "$V2_STONKHOUSE_TOKEN" "balanceOf(address)(uint256)" "$DEPLOYER" --rpc-url "$RPC" | awk '{print $1}')
cast send "$LENDER" "claim(uint256,uint256,address,uint256,bytes32[])" "$EPOCH" 0 "$DEPLOYER" "$TOTAL" "[]" \
  --from "$DEPLOYER" --unlocked --rpc-url "$RPC" > "$LOG/claim.log" 2>&1 || { tail -20 "$LOG/claim.log"; die "claim reverted"; }
CLAIMER_AFTER=$(cast call "$V2_STONKHOUSE_TOKEN" "balanceOf(address)(uint256)" "$DEPLOYER" --rpc-url "$RPC" | awk '{print $1}')
PAID=$(bigsub "$CLAIMER_AFTER" "$CLAIMER_BEFORE")
[ "$PAID" = "$TOTAL" ] || die "the claim paid $PAID, not $TOTAL"
CLAIMED=$(cast call "$LENDER" "isClaimed(uint256,uint256)(bool)" "$EPOCH" 0 --rpc-url "$RPC")
[ "$CLAIMED" = "true" ] || die "the entry is not marked claimed"
echo "  paid exactly $PAID"

step "verify the instance"
V2_LENDER_REWARDS=$LENDER V2_LENDER_EPOCH=$((EPOCH + 1)) \
  forge script script/v2/VerifyLenderRewards.s.sol --rpc-url "$RPC" > "$LOG/verify.log" 2>&1 \
  || { tail -40 "$LOG/verify.log"; die "VerifyLenderRewards failed"; }
grep -q "VERIFY PASSED" "$LOG/verify.log" || { tail -40 "$LOG/verify.log"; die "VerifyLenderRewards did not print VERIFY PASSED"; }
grep -c "  ok    " "$LOG/verify.log" | xargs -I{} echo "  VerifyLenderRewards: {} checks ok"

step "record"
jq -n \
  --arg stamp "$STAMP" --arg forkUrl "$FORK_URL" --argjson forkBlock "$FORK_BLOCK" \
  --arg token "$V2_STONKHOUSE_TOKEN" --arg symbol "$SYMBOL" --argjson decimals "$DECIMALS" \
  --arg manager "$V2_ACCESS_MANAGER" --arg adminSafe "$V2_ADMIN_SAFE" --arg treasury "$V2_TREASURY_SAFE" \
  --arg lender "$LENDER" --arg holder "$V2_STONKHOUSE_HOLDER" \
  --argjson epoch "$EPOCH" --arg root "$ROOT" --arg total "$TOTAL" --arg funded "$FUNDED" --arg paid "$PAID" \
  --argjson adminDelay "$ADMIN_DELAY" --argjson treasuryDelay "$TREASURY_DELAY" \
  '{stamp:$stamp, forkUrl:$forkUrl, forkBlock:$forkBlock,
    token:{address:$token, symbol:$symbol, decimals:$decimals},
    accessManager:$manager, adminSafe:$adminSafe, treasury:$treasury,
    lenderRewardsDistributor:$lender, fundedFrom:$holder,
    epoch:$epoch, root:$root, total:$total, funded:$funded, paid:$paid,
    delaysS:{ADMIN:$adminDelay, TREASURY_ADMIN:$treasuryDelay},
    assertions:["fund delivered the exact total","the posted root is the computed root","the claim paid the exact amount","the entry is marked claimed","VerifyLenderRewards printed VERIFY PASSED"]}' \
  > "$LOG/rehearsal-passed.json"
cat "$LOG/rehearsal-passed.json"

printf '\nLENDER REWARDS REHEARSAL PASSED (+%ss)\n' "$(( $(date +%s) - T0 ))"
