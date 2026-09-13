#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# Deploy rehearsal on an anvil fork of chain 4663: real Safes, real scripts, real library linking.
#
#   anvil --fork-url https://rpc.mainnet.chain.robinhood.com --chain-id 4663 --port 8545
#   script/rehearse-deploy.sh            # from the repository root, in a second shell
#
# What it proves, in order (docs/DEPLOY.md is the runbook this rehearses):
#   1. Two real Safe 1.4.1 proxies (admin 2/3, fee 2/3) are created through the canonical
#      SafeProxyFactory that is deployed on 4663.
#   2. `forge script script/Deploy.s.sol --broadcast` deploys and links SeaportOrderLib and
#      ValoremLib, then the vault, passing the on-chain preflight against the live registry and feed.
#   3. Verify.s.sol passes on the unconfigured vault: the deployer holds NO role, the Safe does.
#   4. Configure.s.sol in production mode writes a Safe Transaction Builder batch and broadcasts
#      nothing (keeper still has no role).
#   5. The old flow — broadcasting the grants with a private key — is refused, because no key holds
#      the admin role.
#   6. Configure.s.sol in rehearsal mode executes the same calls through the admin Safe with two of
#      its three owners' signatures, supplied out of address order to exercise the sort.
#   7. Verify.s.sol passes on the configured vault, including the linked-library check.
#
# Keys are derived (keccak256("callhouse-rehearsal:<role>")), funded with anvil_setBalance and scrubbed
# of any EIP-7702 delegation code first. The script refuses any RPC that is not local.
# -------------------------------------------------------------------------------------------------
set -euo pipefail

RPC="${RPC:-http://127.0.0.1:8545}"
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

chain=$(cast chain-id --rpc-url "$RPC") || fail "no RPC at $RPC"
[ "$chain" = 4663 ] || fail "chain id $chain, expected an anvil fork of 4663"
for a in $FACTORY $SINGLETON $FALLBACK; do
  [ "$(cast codesize "$a" --rpc-url "$RPC")" -gt 0 ] || fail "no Safe contract at $a on this fork"
done
block=$(cast block-number --rpc-url "$RPC")

step "keys (derived, funded, delegation code scrubbed)"
# Plain variables rather than an associative array: macOS ships bash 3.2.
pk() { cast keccak "callhouse-rehearsal:$1"; }
addr() { cast wallet address --private-key "$(pk "$1")"; }
for role in deployer owner1 owner2 owner3 fee1 fee2 fee3 keeper guardian; do
  a=$(addr "$role")
  cast rpc anvil_setBalance "$a" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
  cast rpc anvil_setCode "$a" 0x --rpc-url "$RPC" >/dev/null
  printf '  %-9s %s\n' "$role" "$a"
done
OWNER1=$(addr owner1); OWNER2=$(addr owner2); OWNER3=$(addr owner3)
FEE1=$(addr fee1); FEE2=$(addr fee2); FEE3=$(addr fee3)

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
  [ "$(cast call "$predicted" "getThreshold()(uint256)" --rpc-url "$RPC")" = 2 ] || fail "threshold != 2"
  echo "$predicted"
}
SAFE_ADMIN=$(create_safe "$OWNER1" "$OWNER2" "$OWNER3" "$salt")
SAFE_FEE=$(create_safe "$FEE1" "$FEE2" "$FEE3" "$((salt + 1))")
echo "  admin Safe $SAFE_ADMIN"
echo "  fee Safe   $SAFE_FEE"

step "Deploy.s.sol --broadcast (libraries + vault, preflight against the live registry and feed)"
mkdir -p broadcast
DEPLOYER_PK=$(pk deployer) SAFE_ADMIN=$SAFE_ADMIN SAFE_FEE=$SAFE_FEE \
  forge script script/Deploy.s.sol --rpc-url "$RPC" --broadcast --slow 2>&1 | tee broadcast/rehearsal-deploy.log \
  | grep -E "preflight|feed|Vault |Error|error" || true
run=broadcast/Deploy.s.sol/4663/run-latest.json
[ -f "$run" ] || fail "no broadcast record at $run"
VAULT=$(jq -r '[.transactions[] | select(.contractName=="Vault")][0].contractAddress' "$run")
SEAPORT_ORDER_LIB=$(jq -r '.libraries[] | select(test("SeaportOrderLib")) | split(":")[2]' "$run")
VALOREM_LIB=$(jq -r '.libraries[] | select(test("ValoremLib")) | split(":")[2]' "$run")
[ "$VAULT" != null ] && [ -n "$VAULT" ] || fail "vault address not found in $run"
echo "  Vault           $VAULT"
echo "  SeaportOrderLib $SEAPORT_ORDER_LIB"
echo "  ValoremLib      $VALOREM_LIB"
gas=0; for g in $(jq -r '.receipts[].gasUsed' "$run"); do gas=$((gas + g)); done
echo "  gas used        $gas across $(jq '.receipts | length' "$run") txs (library, library, vault)"

export VAULT SAFE_ADMIN SAFE_FEE SEAPORT_ORDER_LIB VALOREM_LIB
export KEEPER=$(addr keeper) GUARDIAN=$(addr guardian) DEPLOYER=$(addr deployer)

step "Verify.s.sol before configuration (deployer holds no role; keeper/guardian not yet granted)"
EXPECT_KEEPER_CONFIGURED=false forge script script/Verify.s.sol --rpc-url "$RPC" 2>&1 \
  | grep -E "^\s+(ok|FAIL|skip)|VERIFY" || fail "verify (unconfigured) did not run"
EXPECT_KEEPER_CONFIGURED=false forge script script/Verify.s.sol --rpc-url "$RPC" >/dev/null 2>&1 \
  || fail "verify (unconfigured) failed"

step "Configure.s.sol, production mode: writes the Safe batch, broadcasts nothing"
forge script script/Configure.s.sol --rpc-url "$RPC" 2>&1 | grep -E "safe batch|NOTHING BROADCAST" || fail "configure (batch) did not run"
batch=broadcast/configure-safe-batch.json
jq -e --arg v "$VAULT" '.transactions | length == 2 and all(.to | ascii_downcase == ($v | ascii_downcase))' "$batch" >/dev/null \
  || fail "batch file malformed"
[ "$(cast call "$VAULT" "hasRole(bytes32,address)(bool)" "$(cast keccak KEEPER_ROLE)" "$KEEPER" --rpc-url "$RPC")" = false ] \
  || fail "production mode granted a role"
echo "  batch ok: 2 calls to the vault; keeper still has no role"

step "the old flow — grants signed by a private key — is refused (no key holds admin)"
if out=$(ADMIN_PK=$(pk deployer) forge script script/Configure.s.sol --rpc-url "$RPC" --broadcast 2>&1); then
  fail "a private key was able to configure the vault"
fi
echo "$out" | grep -q "ADMIN_PK does not hold DEFAULT_ADMIN_ROLE" || { echo "$out" | tail -20; fail "refused, but for the wrong reason"; }
echo "  refused: ADMIN_PK does not hold DEFAULT_ADMIN_ROLE"

step "Configure.s.sol, rehearsal mode: same calls executed through the admin Safe, 2 of 3 owners"
REHEARSAL=true SAFE_OWNER_PKS="$(pk owner3),$(pk owner1)" \
  forge script script/Configure.s.sol --rpc-url "$RPC" --broadcast --slow 2>&1 | grep -E "REHEARSAL|signers|Error|error" || true
[ "$(cast call "$VAULT" "hasRole(bytes32,address)(bool)" "$(cast keccak KEEPER_ROLE)" "$KEEPER" --rpc-url "$RPC")" = true ] \
  || fail "keeper role not granted through the Safe"

step "Verify.s.sol after configuration"
forge script script/Verify.s.sol --rpc-url "$RPC" 2>&1 | grep -E "^\s+(ok|FAIL|skip)|VERIFY"
forge script script/Verify.s.sol --rpc-url "$RPC" >/dev/null 2>&1 || fail "verify (configured) failed"

printf '\nREHEARSAL PASSED on fork block %s\n' "$block"
printf 'vault %s  admin Safe %s  fee Safe %s\n' "$VAULT" "$SAFE_ADMIN" "$SAFE_FEE"
