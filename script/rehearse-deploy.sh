#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# Deploy rehearsal on an anvil fork of chain 4663: real Safes, real scripts, real library linking.
#
#   anvil --fork-url https://rpc.mainnet.chain.robinhood.com --chain-id 4663 --port 8545 --code-size-limit 98304
#   script/rehearse-deploy.sh            # from the repository root, in a second shell
#
# `--code-size-limit 98304` is REQUIRED: chain 4663 enforces a 98,304 B contract code limit (verified with
# create probes; 98,305 B fails `max code size exceeded`), not EIP-170's 24,576 B. A default anvil would
# refuse the Vault at 24,577 B and make the rehearsal fail for a reason mainnet does not have.
#
# PATH A — the launch plan for now (docs/DEPLOY.md "bootstrap"): the deployer key is the admin.
#   A1  Deploy with ADMIN = deployer. Verify (bootstrap, unconfigured).
#   A2  Configure with the deployer key. Verify (bootstrap, configured).
#   A3  Verify has teeth: swapped library addresses must FAIL the bytecode/link checks.
#   A4  Handover: grant the admin Safe. Renounce is REFUSED until the Safe has executed a transaction.
#   A5  The Safe executes the smoke batch file (setMaxPriceAge to its current value), 2 of 3 owners.
#   A6  Renounce. Verify (safe phase: deployer holds no role). A key-signed configure is now refused.
#
# PATH B — Safe is admin from block one.
#   B1  Deploy with SAFE_ADMIN. Configure writes the batch and broadcasts nothing.
#   B2  The Safe executes that exact batch file. Verify (safe phase).
#   B3  The batch executor refuses a node that is not anvil (checked against the public RPC, read-only).
#   B4  Verify's bytecode comparison catches a single flipped byte of vault code (anvil_setCode).
#
# Every forge call passes --no-storage-caching. Forge caches fork state by chain id and block number, and
# anvil mines rehearsal blocks at real chain-4663 heights: without the flag, fake rehearsal state lands in
# ~/.foundry/cache/rpc/4663 under block numbers mainnet will reach, and state changed without a new block
# (anvil_setCode) is served stale.
#
# Keys are derived (keccak256("callhouse-rehearsal:<role>")), funded with anvil_setBalance and scrubbed
# of any EIP-7702 delegation code first. The script refuses any RPC that is not local.
# -------------------------------------------------------------------------------------------------
set -euo pipefail

RPC="${RPC:-http://127.0.0.1:8545}"
PUBLIC_RPC="${PUBLIC_RPC:-https://rpc.mainnet.chain.robinhood.com}"
case "$RPC" in
  http://127.0.0.1:*|http://localhost:*) ;;
  *) echo "refusing: RPC must be a local anvil fork, got $RPC" >&2; exit 1 ;;
esac

cd "$(dirname "$0")/.."

FACTORY=0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67        # SafeProxyFactory 1.4.1
SINGLETON=0x29fcB43b46531BcA003ddC8FCB67FFE91900C762      # SafeL2 1.4.1
FALLBACK=0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99       # CompatibilityFallbackHandler 1.4.1
ZERO=0x0000000000000000000000000000000000000000

step() { printf '\n== %s\n' "$*"; }
fail() { echo "REHEARSAL FAILED: $*" >&2; exit 1; }
verify() { # runs Verify.s.sol with the given env assignments; fails on any FAIL line
  local out
  out=$(env "$@" forge script --no-storage-caching script/Verify.s.sol --rpc-url "$RPC" 2>&1) || { echo "$out" | grep -E "^\s+(ok|FAIL|info)|VERIFY|Error" ; fail "verify failed: $*"; }
  if echo "$out" | grep -E "^\s+FAIL"; then fail "verify printed FAIL lines"; fi
  echo "$out" | grep -E "VERIFY PASSED"
}
has_role() { cast call "$1" "hasRole(bytes32,address)(bool)" "$2" "$3" --rpc-url "$RPC"; }

chain=$(cast chain-id --rpc-url "$RPC") || fail "no RPC at $RPC"
[ "$chain" = 4663 ] || fail "chain id $chain, expected an anvil fork of 4663"
# The anvil must have been started with --code-size-limit 98304, or the Vault (above EIP-170's 24,576 B)
# cannot be deployed here although mainnet 4663 accepts it. Probe with the same create eth_call the D17
# verification used: init code `PUSH2 0x7530 PUSH1 0 RETURN` returns 30,000 zero bytes as runtime.
if ! cast call --create 0x6175306000f3 --rpc-url "$RPC" >/dev/null 2>&1; then
  fail "this anvil refuses a 30,000 B contract: restart it with --code-size-limit 98304 (chain 4663 allows 98,304 B)"
fi
for a in $FACTORY $SINGLETON $FALLBACK; do
  [ "$(cast codesize "$a" --rpc-url "$RPC")" -gt 0 ] || fail "no Safe contract at $a on this fork"
done
block=$(cast block-number --rpc-url "$RPC")
ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000
KEEPER_ROLE=$(cast keccak KEEPER_ROLE)

step "keys (derived, funded, delegation code scrubbed)"
# Plain variables rather than an associative array: macOS ships bash 3.2.
pk() { cast keccak "callhouse-rehearsal:$1"; }
addr() { cast wallet address --private-key "$(pk "$1")"; }
for role in deployer deployer2 owner1 owner2 owner3 fee1 fee2 fee3 keeper guardian; do
  a=$(addr "$role")
  cast rpc anvil_setBalance "$a" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
  cast rpc anvil_setCode "$a" 0x --rpc-url "$RPC" >/dev/null
  printf '  %-9s %s\n' "$role" "$a"
done
OWNER1=$(addr owner1); OWNER2=$(addr owner2); OWNER3=$(addr owner3)
FEE1=$(addr fee1); FEE2=$(addr fee2); FEE3=$(addr fee3)
KEEPER=$(addr keeper); GUARDIAN=$(addr guardian)
DEPLOYER=$(addr deployer); DEPLOYER2=$(addr deployer2)

step "create the admin Safe (2/3) and the fee Safe (2/3)"
salt=$(date +%s)
create_safe() { # owner1 owner2 owner3 saltNonce
  local setup predicted
  setup=$(cast calldata "setup(address[],uint256,address,bytes,address,address,uint256,address)" \
    "[$1,$2,$3]" 2 $ZERO 0x $FALLBACK $ZERO 0 $ZERO)
  predicted=$(cast call $FACTORY "createProxyWithNonce(address,bytes,uint256)(address)" \
    $SINGLETON "$setup" "$4" --from "$OWNER1" --rpc-url "$RPC")
  cast send $FACTORY "createProxyWithNonce(address,bytes,uint256)" $SINGLETON "$setup" "$4" \
    --private-key "$(pk owner1)" --rpc-url "$RPC" >/dev/null
  [ "$(cast codesize "$predicted" --rpc-url "$RPC")" -gt 0 ] || fail "Safe not created at $predicted"
  echo "$predicted"
}
SAFE_ADMIN=$(create_safe "$OWNER1" "$OWNER2" "$OWNER3" "$salt")
SAFE_FEE=$(create_safe "$FEE1" "$FEE2" "$FEE3" "$((salt + 1))")
echo "  admin Safe $SAFE_ADMIN"
echo "  fee Safe   $SAFE_FEE"
mkdir -p broadcast

deploy() { # env assignments...; sets VAULT SEAPORT_ORDER_LIB VALOREM_LIB
  env "$@" forge script --no-storage-caching script/Deploy.s.sol --rpc-url "$RPC" --broadcast --slow > broadcast/rehearsal-deploy.log 2>&1 \
    || { tail -30 broadcast/rehearsal-deploy.log; fail "deploy failed"; }
  grep -E "preflight|feed |WARNING" broadcast/rehearsal-deploy.log || true
  local run=broadcast/Deploy.s.sol/4663/run-latest.json
  VAULT=$(jq -r '[.transactions[] | select(.contractName=="Vault")][0].contractAddress' "$run")
  SEAPORT_ORDER_LIB=$(jq -r '.libraries[] | select(test("SeaportOrderLib")) | split(":")[2]' "$run")
  VALOREM_LIB=$(jq -r '.libraries[] | select(test("ValoremLib")) | split(":")[2]' "$run")
  [ -n "$VAULT" ] && [ "$VAULT" != null ] || fail "vault address not found"
  local gas=0; for g in $(jq -r '.receipts[].gasUsed' "$run"); do gas=$((gas + g)); done
  echo "  Vault $VAULT  SeaportOrderLib $SEAPORT_ORDER_LIB  ValoremLib $VALOREM_LIB  ($gas gas, $(jq '.receipts | length' "$run") txs)"
}
COMMON() { echo VAULT="$VAULT" SEAPORT_ORDER_LIB="$SEAPORT_ORDER_LIB" VALOREM_LIB="$VALOREM_LIB" SAFE_FEE="$SAFE_FEE" KEEPER="$KEEPER" GUARDIAN="$GUARDIAN"; }

# ============================== PATH A: bootstrap (deployer is admin) ==============================

step "A1  Deploy.s.sol with ADMIN = deployer; Verify (bootstrap, unconfigured)"
deploy DEPLOYER_PK="$(pk deployer)" ADMIN="$DEPLOYER" SAFE_FEE="$SAFE_FEE"
[ "$(has_role "$VAULT" $ADMIN_ROLE "$DEPLOYER")" = true ] || fail "deployer is not admin"
verify $(COMMON) DEPLOYER="$DEPLOYER" ADMIN_PHASE=bootstrap EXPECT_KEEPER_CONFIGURED=false

step "A2  Configure.s.sol with the deployer key; Verify (bootstrap, configured)"
env $(COMMON) ADMIN_PK="$(pk deployer)" forge script --no-storage-caching script/Configure.s.sol --rpc-url "$RPC" --broadcast --slow 2>&1 \
  | grep -E "key admin executed|Error|error" || fail "configure (key) did not run"
verify $(COMMON) DEPLOYER="$DEPLOYER" ADMIN_PHASE=bootstrap SAFE_ADMIN="$SAFE_ADMIN"

step "A3  Verify has teeth: swapped library addresses must fail"
if env $(COMMON) SEAPORT_ORDER_LIB="$VALOREM_LIB" VALOREM_LIB="$SEAPORT_ORDER_LIB" DEPLOYER="$DEPLOYER" ADMIN_PHASE=bootstrap \
  forge script --no-storage-caching script/Verify.s.sol --rpc-url "$RPC" > broadcast/rehearsal-negative.log 2>&1; then
  fail "Verify passed with swapped libraries"
fi
grep -E "^\s+FAIL" broadcast/rehearsal-negative.log

step "A4  HandoverAdmin grant; renounce refused before the Safe has executed anything"
grant_out=$(env VAULT="$VAULT" SAFE_ADMIN="$SAFE_ADMIN" ADMIN_PK="$(pk deployer)" STEP=grant \
  forge script --no-storage-caching script/HandoverAdmin.s.sol --rpc-url "$RPC" --broadcast --slow 2>&1) || { echo "$grant_out" | tail -20; fail "grant failed"; }
GRANT_NONCE=$(echo "$grant_out" | grep "GRANT_NONCE" | awk '{print $NF}')
echo "  granted; GRANT_NONCE=$GRANT_NONCE"
[ "$(has_role "$VAULT" $ADMIN_ROLE "$SAFE_ADMIN")" = true ] || fail "Safe not admin after grant"
if out=$(env VAULT="$VAULT" SAFE_ADMIN="$SAFE_ADMIN" ADMIN_PK="$(pk deployer)" STEP=renounce GRANT_NONCE="$GRANT_NONCE" \
  forge script --no-storage-caching script/HandoverAdmin.s.sol --rpc-url "$RPC" --broadcast 2>&1); then
  fail "renounce ran before the Safe had executed a transaction"
fi
echo "$out" | grep -q "has not executed a transaction since the grant" || { echo "$out" | tail -20; fail "renounce refused for the wrong reason"; }
echo "  renounce refused: the Safe has not executed a transaction since the grant"

step "A5  the admin Safe executes the smoke batch file, 2 of 3 owners (supplied out of address order)"
env BATCH=broadcast/handover-safe-smoke-batch.json SAFE="$SAFE_ADMIN" SAFE_OWNER_PKS="$(pk owner3),$(pk owner1)" \
  forge script --no-storage-caching script/rehearsal/ExecuteSafeBatch.s.sol --rpc-url "$RPC" --broadcast --slow 2>&1 \
  | grep -E "REHEARSAL|signers|Error|error" || fail "smoke batch did not run"

step "A6  HandoverAdmin renounce; Verify (safe phase); a key-signed configure is now refused"
env VAULT="$VAULT" SAFE_ADMIN="$SAFE_ADMIN" ADMIN_PK="$(pk deployer)" STEP=renounce GRANT_NONCE="$GRANT_NONCE" \
  forge script --no-storage-caching script/HandoverAdmin.s.sol --rpc-url "$RPC" --broadcast --slow 2>&1 | grep -E "renounced|Error|error" \
  || fail "renounce did not run"
[ "$(has_role "$VAULT" $ADMIN_ROLE "$DEPLOYER")" = false ] || fail "deployer still admin"
verify $(COMMON) DEPLOYER="$DEPLOYER" ADMIN_PHASE=safe SAFE_ADMIN="$SAFE_ADMIN" \
  EXPECT_SAFE_OWNER_SET="$OWNER1,$OWNER2,$OWNER3"
if out=$(env $(COMMON) ADMIN_PK="$(pk deployer)" forge script --no-storage-caching script/Configure.s.sol --rpc-url "$RPC" --broadcast 2>&1); then
  fail "the renounced key could still configure"
fi
echo "$out" | grep -q "ADMIN_PK does not hold DEFAULT_ADMIN_ROLE" || fail "refused for the wrong reason"
echo "  refused: ADMIN_PK does not hold DEFAULT_ADMIN_ROLE"
VAULT_A=$VAULT

# ================================ PATH B: Safe is admin from block one =============================

step "B1  Deploy.s.sol with SAFE_ADMIN; Configure writes the batch and broadcasts nothing"
deploy DEPLOYER_PK="$(pk deployer2)" SAFE_ADMIN="$SAFE_ADMIN" SAFE_FEE="$SAFE_FEE"
env $(COMMON) SAFE_ADMIN="$SAFE_ADMIN" forge script --no-storage-caching script/Configure.s.sol --rpc-url "$RPC" 2>&1 \
  | grep -E "safe batch written|NOTHING BROADCAST" || fail "configure (batch) did not run"
[ "$(has_role "$VAULT" "$KEEPER_ROLE" "$KEEPER")" = false ] || fail "batch mode granted a role"
for d in $(jq -r '.transactions[].data' broadcast/configure-safe-batch.json); do
  cast calldata-decode "grantRole(bytes32,address)" "$d" | tr '\n' ' '; echo
done

step "B2  the admin Safe executes that exact batch file; Verify (safe phase)"
env BATCH=broadcast/configure-safe-batch.json SAFE="$SAFE_ADMIN" SAFE_OWNER_PKS="$(pk owner2),$(pk owner3)" \
  forge script --no-storage-caching script/rehearsal/ExecuteSafeBatch.s.sol --rpc-url "$RPC" --broadcast --slow 2>&1 \
  | grep -E "REHEARSAL|Error|error" || fail "configure batch did not run"
verify $(COMMON) DEPLOYER="$DEPLOYER2" ADMIN_PHASE=safe SAFE_ADMIN="$SAFE_ADMIN"

step "B3  the batch executor refuses a node that is not anvil (public RPC, simulation only, nothing sent)"
if out=$(env BATCH=broadcast/configure-safe-batch.json SAFE="$SAFE_ADMIN" SAFE_OWNER_PKS="$(pk owner2),$(pk owner3)" \
  forge script --no-storage-caching script/rehearsal/ExecuteSafeBatch.s.sol --rpc-url "$PUBLIC_RPC" 2>&1); then
  fail "the executor ran against a non-anvil node"
fi
echo "$out" | grep -q "runs on an anvil node only" || { echo "$out" | tail -15; fail "refused for the wrong reason"; }
echo "  refused: ExecuteSafeBatch runs on an anvil node only"

step "B4  Verify's bytecode check has teeth: flip one byte of the path-B vault's code (anvil_setCode) and it must fail"
code=$(cast code "$VAULT" --rpc-url "$RPC")
pos=$((2 + 2 * 100))                                  # byte 100: logic, outside every link and immutable slot
orig=${code:$pos:2}
flip=$(printf '%02x' $(( (16#$orig) ^ 0x01 )))
cast rpc anvil_setCode "$VAULT" "${code:0:$pos}${flip}${code:$((pos + 2))}" --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
[ "$(cast code "$VAULT" --rpc-url "$RPC" | cut -c$((pos + 1))-$((pos + 2)))" = "$flip" ] || fail "tamper did not apply"
if env $(COMMON) DEPLOYER="$DEPLOYER2" ADMIN_PHASE=safe SAFE_ADMIN="$SAFE_ADMIN" \
  forge script --no-storage-caching script/Verify.s.sol --rpc-url "$RPC" > broadcast/rehearsal-tamper.log 2>&1; then
  fail "Verify passed against tampered vault bytecode"
fi
grep -E "^\s+FAIL" broadcast/rehearsal-tamper.log
grep -q "FAIL  vault: runtime == compiled Vault" broadcast/rehearsal-tamper.log || fail "tamper not caught by the bytecode check"
echo "  byte 100 flipped 0x$orig -> 0x$flip: caught"

printf '\nREHEARSAL PASSED on fork block %s\n' "$block"
printf 'path A vault %s (bootstrap -> handed over)\npath B vault %s (Safe from block one)\nadmin Safe %s  fee Safe %s\n' \
  "$VAULT_A" "$VAULT" "$SAFE_ADMIN" "$SAFE_FEE"
