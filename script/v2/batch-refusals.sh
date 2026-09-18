#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# batch-refusals.sh — the refusals of script/v2/DeployV2Batch.sh and script/DeploySoloBatch.sh that need no
# node, each run and checked for its exit code and message. Nothing is sent and the registry is only read
# (the cases that need a different registry use temp copies).
#
#   script/v2/batch-refusals.sh [--registry <path>]     default ../callhouse/ops/markets/tier1.json
#
# Prints one line per case and "REFUSALS PASSED: N cases" or exits 1 at the first case that misbehaves.
# -------------------------------------------------------------------------------------------------
set -euo pipefail

CALLER_PWD=$PWD
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
export PATH="$HOME/.foundry/bin:$PATH"

REGISTRY="$ROOT/../callhouse/ops/markets/tier1.json"
[ "${1:-}" != --registry ] || { REGISTRY=$2; case "$REGISTRY" in /*) ;; *) REGISTRY="$CALLER_PWD/$REGISTRY" ;; esac; }
[ -f "$REGISTRY" ] || { echo "registry not found: $REGISTRY" >&2; exit 1; }
SOURCES="$(dirname "$REGISTRY")/v2-sources.json"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/batch-refusals.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
# anvil's public dev key #0 and its address (never a real key)
ANVIL0_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ANVIL0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
LOCAL=http://127.0.0.1:1          # nothing listens there: every case below must stop before touching a node
REMOTE=https://rpc.invalid.example

CASES=0
fail() { echo "REFUSALS FAILED: $*" >&2; exit 1; }
# expect_refusal <name> <message fragment> <command...>
expect_refusal() {
  local name=$1 want=$2 out rc=0; shift 2
  out=$("$@" 2>&1 </dev/null) || rc=$?
  [ "$rc" != 0 ] || { echo "$out" | tail -5; fail "$name: exited 0, expected a refusal"; }
  grep -qF -- "$want" <<<"$out" || { echo "$out" | tail -5; fail "$name: exit $rc without \"$want\""; }
  CASES=$((CASES + 1))
  printf '  ok    %-58s exit %s: %s\n' "$name" "$rc" "$want"
}
# expect_ok <name> <output fragment> <command...>
expect_ok() {
  local name=$1 want=$2 out rc=0; shift 2
  out=$("$@" 2>&1 </dev/null) || rc=$?
  [ "$rc" = 0 ] || { echo "$out" | tail -8; fail "$name: exit $rc, expected 0"; }
  grep -qF -- "$want" <<<"$out" || { echo "$out" | tail -8; fail "$name: no \"$want\" in the output"; }
  CASES=$((CASES + 1))
  printf '  ok    %-58s exit 0: %s\n' "$name" "$want"
}
copy_with() { # jq filter -> path of a registry copy (v2-sources.json alongside)
  local dir; dir=$(mktemp -d "$TMP/reg.XXXXXX")
  jq "$1" "$REGISTRY" > "$dir/tier1.json"
  cp "$SOURCES" "$dir/v2-sources.json"
  echo "$dir/tier1.json"
}
copy_with_sources() { # jq filter over v2-sources.json -> path of an unchanged registry copy beside the filtered recon
  local dir; dir=$(mktemp -d "$TMP/reg.XXXXXX")
  cp "$REGISTRY" "$dir/tier1.json"
  jq "$1" "$SOURCES" > "$dir/v2-sources.json"
  echo "$dir/tier1.json"
}

V1=script/DeploySoloBatch.sh
V2=script/v2/DeployV2Batch.sh

echo "DeploySoloBatch.sh (O2-01 follow-up: superseded-by-v2 rows are never v1 factories)"
expect_refusal "superseded row by --tickers" "TSLA: status superseded-by-v2" \
  env -u DEPLOYER_PK -u ADMIN_PK $V1 --rehearse --rpc $LOCAL --registry "$REGISTRY" --tickers TSLA --dry-run
expect_refusal "superseded row by --wave canary" "status superseded-by-v2" \
  env -u DEPLOYER_PK -u ADMIN_PK $V1 --rehearse --rpc $LOCAL --registry "$REGISTRY" --wave canary --dry-run
expect_refusal "superseded row with --force" "TSLA: status superseded-by-v2" \
  env -u DEPLOYER_PK -u ADMIN_PK $V1 --rehearse --rpc $LOCAL --registry "$REGISTRY" --tickers TSLA --force --dry-run
PLANNED=$(copy_with '(.markets[] | select(.ticker == "TSLA") | .status) = "planned"')
expect_ok "a planned row still plans (the refusal is specific)" "TSLA   0x322F0929c4625eD5bAd873c95208D54E1c003b2d" \
  env -u DEPLOYER_PK -u ADMIN_PK $V1 --rehearse --rpc $LOCAL --registry "$PLANNED" --tickers TSLA --dry-run

echo "DeployV2Batch.sh"
expect_refusal "no mode" "one of --rehearse, --broadcast or --verify is required" $V2 --registry "$REGISTRY" --tickers NVDA
expect_refusal "two modes" "--rehearse and --broadcast are exclusive" $V2 --rehearse --broadcast
expect_refusal "unknown flag" "unknown flag --force" $V2 --rehearse --force
expect_refusal "--rehearse on a remote RPC" "--rehearse needs a local anvil RPC" \
  $V2 --rehearse --rpc $REMOTE --registry "$REGISTRY" --tickers NVDA
expect_refusal "--broadcast on a local RPC" "--broadcast needs a non-local --rpc" \
  $V2 --broadcast --rpc $LOCAL --registry "$REGISTRY" --tickers NVDA
expect_refusal "--broadcast without DEPLOYER_PK" "DEPLOYER_PK must be in the environment for --broadcast" \
  env -u DEPLOYER_PK -u ADMIN_PK $V2 --broadcast --rpc $REMOTE --registry "$REGISTRY" --tickers NVDA
expect_refusal "--broadcast with --out" "--out is for --rehearse only" \
  env DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$REGISTRY" --tickers NVDA --out "$TMP/x.json"
expect_refusal "--broadcast with --deployer-pk" "--deployer-pk is for --rehearse only" \
  $V2 --broadcast --rpc $REMOTE --registry "$REGISTRY" --tickers NVDA --deployer-pk $ANVIL0_PK
expect_refusal "--broadcast with a key that is not shared.admin" "is not the registry's shared.admin" \
  env DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$REGISTRY" --tickers NVDA --dry-run
ADMIN_IS_ANVIL=$(copy_with ".shared.admin = \"$ANVIL0\"")
expect_refusal "--broadcast with null v2.bots" "registry v2.bots.cranker is null" \
  env DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$ADMIN_IS_ANVIL" --tickers NVDA --dry-run
expect_refusal "--tickers and --wave" "--tickers and --wave are exclusive" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --tickers NVDA --wave canary --dry-run
expect_refusal "no market selection" "--tickers A,B, --wave <canary|wave1|wave2> or --deploy-only is required" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --dry-run
expect_refusal "unknown ticker" "ZZZZ is not in the registry" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --tickers ZZZZ --dry-run
expect_refusal "unknown wave" "unknown wave 'live'" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --wave live --dry-run
expect_refusal "--resume with nothing recorded" "--resume, but no v2 contract is recorded" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --tickers NVDA --resume --dry-run
expect_refusal "--verify with nothing recorded" "--verify needs all 13 v2.contracts and v2.deployBlock recorded" \
  $V2 --verify --rpc $LOCAL --registry "$REGISTRY"
expect_refusal "--verify with --tickers" "it takes no --tickers/--wave" \
  $V2 --verify --rpc $LOCAL --registry "$REGISTRY" --tickers NVDA
OLD_IV=$(copy_with '.v2.interfaceVersion = 4')
expect_refusal "registry of another interface version (4, before v7)" "registry v2.interfaceVersion is 4; these scripts are INTERFACE_VERSION 7" \
  $V2 --rehearse --rpc $LOCAL --registry "$OLD_IV" --tickers NVDA --dry-run
V6_IV=$(copy_with '.v2.interfaceVersion = 6')
expect_refusal "a v6 registry against v7 scripts" "registry v2.interfaceVersion is 6; these scripts are INTERFACE_VERSION 7" \
  $V2 --rehearse --rpc $LOCAL --registry "$V6_IV" --tickers NVDA --dry-run
PARTIAL=$(copy_with ".v2.contracts.expiryCalendar = \"$ANVIL0\" | .v2.deployBlock = 1")
expect_refusal "a partly recorded set without --resume" "1 of 13 v2.contracts recorded" \
  $V2 --rehearse --rpc $LOCAL --registry "$PARTIAL" --tickers NVDA --dry-run
BAD_POOL=$(copy_with "(.markets[] | select(.ticker == \"NVDA\") | .v2.univ3Pool) = \"$ANVIL0\"")
expect_refusal "a pool the recon does not know" "NVDA: v2.univ3Pool $ANVIL0 is not a pool of NVDA" \
  $V2 --rehearse --rpc $LOCAL --registry "$BAD_POOL" --tickers NVDA --dry-run
NVDA_POOL=$(jq -r '.markets[] | select(.ticker == "NVDA") | .v2.univ3Pool' "$REGISTRY")
COSTLY=$(copy_with_sources "(.markets[] | select(.ticker == \"NVDA\") | .pools[] | select((.address | ascii_downcase) == (\"$NVDA_POOL\" | ascii_downcase)) | .fee) = 20000")
expect_refusal "a pool fee tier above 1 % (payouts would always go in kind)" "NVDA: v2.univ3Pool $NVDA_POOL has fee tier 20000" \
  $V2 --rehearse --rpc $LOCAL --registry "$COSTLY" --tickers NVDA --dry-run
NO_TICK=$(copy_with '(.markets[] | select(.ticker == "NVDA") | .v2.strikeTick) = null')
expect_refusal "a market without a strike tick" "NVDA: v2.strikeTick is not set" \
  $V2 --rehearse --rpc $LOCAL --registry "$NO_TICK" --tickers NVDA --dry-run

echo "DeployV2Batch.sh INTERFACE_VERSION 7 (c05 rent, c21 outflow cap, c16 bounty, c10 pool ring)"
SHALLOW=$(copy_with_sources "(.markets[] | select(.ticker == \"NVDA\") | .pools[] | select((.address | ascii_downcase) == (\"$NVDA_POOL\" | ascii_downcase)) | .cardinality) = 1801")
expect_refusal "a pool whose observation ring is below 2401 (owner sign-off c10)" "has observationCardinality 1801 in" \
  $V2 --rehearse --rpc $LOCAL --registry "$SHALLOW" --tickers NVDA --dry-run
expect_ok "the same market Chainlink-only is accepted" "NVDA   0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC" \
  $V2 --rehearse --rpc $LOCAL --registry "$(copy_with '(.markets[] | select(.ticker == "NVDA") | .v2) |= (del(.univ3Pool) | del(.univ3MinLiquidity))')" --tickers NVDA --dry-run
HIGH_PPM=$(copy_with '(.markets[] | select(.ticker == "NVDA") | .v2.mintFeePpm) = 5001')
expect_refusal "a market rent rate above MINT_FEE_CEIL_PPM" "NVDA: v2.mintFeePpm 5001 is above MINT_FEE_CEIL_PPM (5000)" \
  $V2 --rehearse --rpc $LOCAL --registry "$HIGH_PPM" --tickers NVDA --dry-run
HIGH_SHARED_PPM=$(copy_with '.v2.fees.mintFeePpm = 9000')
expect_refusal "a shared rent rate above MINT_FEE_CEIL_PPM" "registry v2.fees.mintFeePpm 9000 is above MINT_FEE_CEIL_PPM (5000)" \
  $V2 --rehearse --rpc $LOCAL --registry "$HIGH_SHARED_PPM" --tickers NVDA --dry-run
PREMIUM_OVER_RESALE=$(copy_with '.v2.fees.premiumFeeBps = 500 | .v2.fees.resaleFeeBps = 0')
expect_refusal "a premium fee above the resale fee (the c05 dodge)" "is above v2.fees.resaleFeeBps 0" \
  $V2 --rehearse --rpc $LOCAL --registry "$PREMIUM_OVER_RESALE" --tickers NVDA --dry-run
expect_refusal "V2_VAULT_MAX_DAILY_OUTFLOW=0 (a vault deployed frozen)" "V2_VAULT_MAX_DAILY_OUTFLOW must be > 0" \
  env V2_VAULT_MAX_DAILY_OUTFLOW=0 $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --tickers NVDA --dry-run
expect_refusal "V2_BOUNTY_CANCEL_STALE above MAX_BOUNTY" "V2_BOUNTY_CANCEL_STALE 1000001 is above MAX_BOUNTY (1000000)" \
  env V2_BOUNTY_CANCEL_STALE=1000001 $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --tickers NVDA --dry-run
expect_ok "the launch rent rate reaches the plan" "PPM" \
  $V2 --rehearse --rpc $LOCAL --registry "$(copy_with '(.markets[] | select(.ticker == "NVDA") | .v2.mintFeePpm) = 80')" --tickers NVDA --dry-run

# Release blocker, DECISIONS-2026-09-17 §11: premiumFeeBps is 0 at launch, so the rent at mint is the ONLY fee a
# writer pays. A market whose effective rate is absent or 0 must never be selected for a deploy; zero stays reachable
# only behind --allow-zero-rent, which is refused together with --broadcast.
NO_RATE_AT_ALL=$(copy_with 'del(.v2.fees.mintFeePpm) | (.markets[] | select(.ticker == "NVDA") | .v2) |= del(.mintFeePpm)')
expect_refusal "an absent v2.fees rent block and no per-market rate" "NVDA: no collateral rent rate" \
  $V2 --rehearse --rpc $LOCAL --registry "$NO_RATE_AT_ALL" --tickers NVDA --dry-run
NULL_SHARED=$(copy_with '.v2.fees.mintFeePpm = null | (.markets[] | select(.ticker == "NVDA") | .v2) |= del(.mintFeePpm)')
expect_refusal "an absent per-market rate with a null shared fallback" "NVDA: no collateral rent rate" \
  $V2 --rehearse --rpc $LOCAL --registry "$NULL_SHARED" --tickers NVDA --dry-run
ZERO_PPM=$(copy_with '(.markets[] | select(.ticker == "NVDA") | .v2.mintFeePpm) = 0')
expect_refusal "an explicit per-market rent rate of 0" "NVDA: v2.mintFeePpm is 0" \
  $V2 --rehearse --rpc $LOCAL --registry "$ZERO_PPM" --tickers NVDA --dry-run
ZERO_SHARED=$(copy_with '.v2.fees.mintFeePpm = 0 | (.markets[] | select(.ticker == "NVDA") | .v2) |= del(.mintFeePpm)')
expect_refusal "an explicit shared rent rate of 0 with no per-market rate" "NVDA: v2.mintFeePpm is 0" \
  $V2 --rehearse --rpc $LOCAL --registry "$ZERO_SHARED" --tickers NVDA --dry-run
expect_ok "--allow-zero-rent lets a local fixture through at 0" "PPM" \
  $V2 --rehearse --rpc $LOCAL --registry "$ZERO_PPM" --tickers NVDA --allow-zero-rent --dry-run
expect_ok "and says so in the plan" "writer rent   ZERO RENT PLANNED" \
  $V2 --rehearse --rpc $LOCAL --registry "$ZERO_PPM" --tickers NVDA --allow-zero-rent --dry-run
expect_ok "an absent rate reads as 0 under the flag, never by default" "PPM" \
  $V2 --rehearse --rpc $LOCAL --registry "$NO_RATE_AT_ALL" --tickers NVDA --allow-zero-rent --dry-run
expect_refusal "--allow-zero-rent with --broadcast" "--allow-zero-rent is refused with --broadcast" \
  env DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$ZERO_PPM" --tickers NVDA --allow-zero-rent --dry-run

# THE OPT-IN IS A TEST-ONLY CODE PATH (codex review, DECISIONS-2026-09-17 §11). The wrapper's --broadcast refusal was
# the whole guard, so a direct `forge script RegisterMarkets --rpc-url <live 4663> --broadcast` with
# V2_ALLOW_ZERO_RENT exported still registered a market that charges its writers nothing, and a read-only VerifyV2 of
# live 4663 still accepted one. The scripts now honour the opt-in only under `forge test`, so the flag cannot ride
# into any run that reaches forge, and a hand-run forge script refuses whatever the environment says.
expect_refusal "--allow-zero-rent without --dry-run (a rehearsal would reach forge)" "--allow-zero-rent needs --dry-run" \
  $V2 --rehearse --rpc $LOCAL --registry "$ZERO_PPM" --tickers NVDA --allow-zero-rent
expect_refusal "--allow-zero-rent without --dry-run on --verify" "--allow-zero-rent needs --dry-run" \
  $V2 --verify --rpc $LOCAL --registry "$ZERO_PPM" --allow-zero-rent
# A hand-run forge script, the path the wrapper never covered. No node: RegisterMarkets.run() reads the environment
# first, so the rent refusal lands before the chain id is even checked.
HAND_ENV=(
  V2_ADMIN=$ANVIL0 V2_USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 V2_EXERCISE_FEE_BPS=25
  V2_TICKERS=NVDA V2_MARKET_NVDA_ASSET=0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC
  V2_MARKET_NVDA_FEED=0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15 V2_MARKET_NVDA_STRIKE_TICK=2500000
  V2_MARKET_NVDA_MAX_DEVIATION_BPS=150 V2_MARKET_NVDA_UNCORROBORATED_DELAY_S=21600
  V2_MARKET_NVDA_SPOT_MAX_AGE_S=3600
)
expect_refusal "a hand-run RegisterMarkets cannot opt in with V2_ALLOW_ZERO_RENT" "NVDA: collateral rent rate is 0" \
  env "${HAND_ENV[@]}" V2_MINT_FEE_PPM=0 V2_ALLOW_ZERO_RENT=true forge script script/v2/RegisterMarkets.s.sol
expect_refusal "and is told the opt-in was ignored, not silently dropped" "V2_ALLOW_ZERO_RENT IGNORED" \
  env "${HAND_ENV[@]}" V2_MINT_FEE_PPM=0 V2_ALLOW_ZERO_RENT=true forge script script/v2/RegisterMarkets.s.sol
expect_refusal "an absent rate is refused the same way, opt-in or not" "NVDA: no collateral rent rate" \
  env "${HAND_ENV[@]}" V2_ALLOW_ZERO_RENT=true forge script script/v2/RegisterMarkets.s.sol
# The same command with a rate gets past the rent refusal, so the refusal above is the rent one and not a stuck script.
expect_refusal "the same run with a rate reaches the chain check (the refusal is the rent one)" "expected 4663" \
  env "${HAND_ENV[@]}" V2_MINT_FEE_PPM=80 V2_ALLOW_ZERO_RENT=true forge script script/v2/RegisterMarkets.s.sol
DONE=$(copy_with ".v2.contracts |= with_entries(if .key == \"sources\" then .value |= map_values(\"$ANVIL0\") else .value = \"$ANVIL0\" end) | .v2.deployBlock = 1 | (.markets[] | select(.ticker == \"NVDA\") | .v2) += {registeredAt: 1789000000, registerTx: \"0x$(printf '%064d' 1)\"}")
expect_refusal "every selected market already registered" "nothing to do: the set is deployed and every selected market is registered" \
  $V2 --rehearse --rpc $LOCAL --registry "$DONE" --tickers NVDA --dry-run
expect_ok "a rehearsal plan (dry run)" "NVDA   0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --tickers NVDA,TSLA --dry-run
expect_ok "stand-in bots named in the plan" "rehearsal stand-ins (anvil #8/#9/#10) for null v2.bots" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --wave canary --dry-run
expect_refusal "a rehearsal writing into a registry" "is a registry (ops/markets/tier1.json), not a copy" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --tickers NVDA --out "$REGISTRY" --dry-run
expect_refusal "--resync with --deploy-only" "--resync needs --tickers or --wave" \
  $V2 --rehearse --rpc $LOCAL --registry "$REGISTRY" --deploy-only --resync --dry-run
expect_refusal "--verify with --resync" "--verify takes no --deployer-pk, --out, --resume, --resync or --deploy-only" \
  $V2 --verify --rpc $LOCAL --registry "$REGISTRY" --resync
expect_refusal "a registered market without --resync" "nothing to do: the set is deployed and every selected market is registered" \
  $V2 --rehearse --rpc $LOCAL --registry "$DONE" --tickers NVDA --dry-run
expect_ok "a registered market with --resync" "resync" \
  $V2 --rehearse --rpc $LOCAL --registry "$DONE" --tickers NVDA --resync --dry-run

echo "DeployV2Batch.sh write-back: the registerMarket recorder (script/v2/lib/register-tx.sh)"
# The recorder matches raw calldata by selector, so a signature that drifts from the compiled ABI finds nothing
# and every registration silently falls through to scanning the Clearinghouse's logs. These cases need no node:
# `cast sig`, `cast abi-encode` and `cast calldata` are offline, and the forge record is synthetic.
# shellcheck source=script/v2/lib/register-tx.sh
. "$ROOT/script/v2/lib/register-tx.sh"
ART=out/Clearinghouse.sol/Clearinghouse.json
[ -f "$ART" ] || fail "no $ART: run forge build first"
ABI_SIG=$(register_abi_sig "$ART")
[ -n "$ABI_SIG" ] || fail "no registerMarket in $ART's ABI"
[ "$REGISTER_SIG" = "$ABI_SIG" ] \
  || fail "REGISTER_SIG is \"$REGISTER_SIG\", the compiled ABI is \"$ABI_SIG\": the write-back would never find a registration"
CASES=$((CASES + 1)); printf '  ok    %-58s %s\n' "REGISTER_SIG is the compiled signature" "$ABI_SIG"

CH=0x53d7A6d0489Daf3d67b9A314e0eAB2B78Acab9C6
ASSET=0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC   # NVDA
OTHER=0x322F0929c4625eD5bAd873c95208D54E1c003b2d   # TSLA
ORACLE=0xEb82c3D0F89d47453F94f0C2b2a2752e27a19d9b
HASH=0x1111111111111111111111111111111111111111111111111111111111111111
V6_SIG="registerMarket(address,(bool,bool,uint64,uint16,address))"
RECORDS=0
run_record() { # <calldata> <receipt status> -> the path of a synthetic forge run-latest.json in $TMP
  local file; RECORDS=$((RECORDS + 1)); file="$TMP/run-latest-$RECORDS.json"
  node -e '
    const [file, data, status, hash, to] = process.argv.slice(1);
    require("fs").writeFileSync(file, JSON.stringify({
      transactions: [
        // a wiring call to the same contract first: the lookup must pick the registerMarket one, not the first row
        { hash: "0x" + "9".repeat(64), transaction: { to, input: "0x2f2ff15d" + "0".repeat(128) } },
        { hash, transaction: { to, input: data } }
      ],
      receipts: [
        { transactionHash: "0x" + "9".repeat(64), status: "0x1", blockNumber: "0x3e7" },
        { transactionHash: hash, status, blockNumber: "0x4d2" }
      ]
    }, null, 2));
  ' "$file" "$1" "$2" "$HASH" "$CH"
  [ -s "$file" ] || fail "could not write the synthetic forge record $file"
  echo "$file"
}
V7_CALL=$(cast calldata "$REGISTER_SIG" "$ASSET" "(true,false,2500000,25,$ORACLE,80)")
V6_CALL=$(cast calldata "$V6_SIG" "$ASSET" "(true,false,2500000,25,$ORACLE)")
OTHER_CALL=$(cast calldata "$REGISTER_SIG" "$OTHER" "(true,false,2500000,25,$ORACLE,300)")
recorder_case() { # <name> <expected "hash block" or empty> <run file> <asset>
  local name=$1 want=$2 got
  got=$(register_tx "$3" "$CH" "$4")
  [ "$got" = "$want" ] || fail "$name: register_tx printed \"$got\", expected \"$want\""
  CASES=$((CASES + 1)); printf '  ok    %-58s %s\n' "$name" "${want:-<falls through to the logs>}"
}
recorder_case "the recorder finds the registration transaction" "$HASH 0x4d2" "$(run_record "$V7_CALL" 0x1)" "$ASSET"
recorder_case "the same record read for another market finds nothing" "" "$(run_record "$V7_CALL" 0x1)" "$OTHER"
recorder_case "a v6-shaped registerMarket is not this registration" "" "$(run_record "$V6_CALL" 0x1)" "$ASSET"
recorder_case "another market's registration is not this one" "" "$(run_record "$OTHER_CALL" 0x1)" "$ASSET"
recorder_case "a reverted registration is not recorded" "" "$(run_record "$V7_CALL" 0x0)" "$ASSET"
recorder_case "a record that does not exist falls through" "" "$TMP/no-such-run.json" "$ASSET"

echo "DeployV2Batch.sh --broadcast needs a passed rehearsal of the same run"
READY=$(copy_with ".shared.admin = \"$ANVIL0\" | .v2.bots = {cranker: \"0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f\", pricer: \"0xa0Ee7A142d267C1f36714E4a8F75612F20a79720\", mmQuoter: \"0xBcd4042DE499D14e55001CcbB24a551F3b954096\"}")
plan_without=$(env -u EXPLORER_API_KEY DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$READY" --tickers NVDA --dry-run) \
  || fail "broadcast dry-run without explorer credential failed"
deploy_without=$(grep '^forge script script/v2/DeployV2.s.sol ' <<<"$plan_without")
grep -qF 'source verify  skipped (EXPLORER_API_KEY unset' <<<"$plan_without" \
  && [[ "$deploy_without" != *' --verify '* ]] \
  || fail "unset EXPLORER_API_KEY must skip source verification in the deploy command"
CASES=$((CASES + 1)); printf '  ok    %-58s %s\n' "no explorer credential" "source publication skipped in plan and command"
plan_with=$(env EXPLORER_API_KEY=fixture-only DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$READY" --tickers NVDA --dry-run) \
  || fail "broadcast dry-run with explorer credential failed"
deploy_with=$(grep '^forge script script/v2/DeployV2.s.sol ' <<<"$plan_with")
grep -qF 'source verify  requested (check publication separately)' <<<"$plan_with" \
  && [[ "$deploy_with" == *' --verify --verifier sourcify --chain 4663 '* ]] \
  || fail "set EXPLORER_API_KEY must request Sourcify in the deploy command"
CASES=$((CASES + 1)); printf '  ok    %-58s %s\n' "explorer credential present" "Sourcify requested in plan and command"

# Exercise the wrapper's exact forge-exit exception with synthetic receipts; this is deliberately
# stricter than checking only forge's completion marker or its receipt count.
eval "$(sed -n '/^source_publication_only_failure() {/,/^}/p' "$V2")"
declare -F source_publication_only_failure >/dev/null || fail "source-publication classifier not found"
printf -v H1 '0x%064d' 1
printf -v H2 '0x%064d' 2
jq -n --arg h1 "$H1" --arg h2 "$H2" '{transactions:[{hash:$h1},{hash:$h2}],receipts:[{transactionHash:$h1,status:"0x1"},{transactionHash:$h2,status:"0x1"}]}' > "$TMP/source-run.json"
jq '.receipts[1].status = "0x0"' "$TMP/source-run.json" > "$TMP/failed-run.json"
jq 'del(.receipts[1])' "$TMP/source-run.json" > "$TMP/missing-run.json"
jq '.receipts[1].transactionHash = .receipts[0].transactionHash' "$TMP/source-run.json" > "$TMP/duplicate-run.json"
printf '%s\n' 'ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.' 'Error: Failed to verify contract: fixture' 'Error: Not all (0 / 2) contracts were verified!' > "$TMP/source-only.log"
printf '%s\n' 'Error: Failed to verify contract: fixture' > "$TMP/no-completion.log"
printf '%s\n' 'ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.' > "$TMP/no-source-error.log"
printf '%s\n' 'ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.' 'Error: Failed to verify contract: fixture' '  Error: unrelated execution failure' > "$TMP/mixed-error.log"
classification_case() { # name expected forge-rc flags log run
  local name=$1 expected=$2 forge_rc=$3 flags=$4 log=$5 run=$6 got=reject
  VERIFY_FLAGS=$flags
  source_publication_only_failure "$forge_rc" "$log" "$run" && got=accept
  [ "$got" = "$expected" ] || fail "$name: expected $expected, got $got"
  CASES=$((CASES + 1)); printf '  ok    %-58s %s\n' "$name" "$expected"
}
classification_case "source-only forge failure after mined receipts" accept 1 --verify "$TMP/source-only.log" "$TMP/source-run.json"
classification_case "no source verification requested" reject 1 '' "$TMP/source-only.log" "$TMP/source-run.json"
classification_case "forge itself exited successfully" reject 0 --verify "$TMP/source-only.log" "$TMP/source-run.json"
classification_case "missing on-chain completion marker" reject 1 --verify "$TMP/no-completion.log" "$TMP/source-run.json"
classification_case "no source-publication error" reject 1 --verify "$TMP/no-source-error.log" "$TMP/source-run.json"
classification_case "indented unrelated error mixed in" reject 1 --verify "$TMP/mixed-error.log" "$TMP/source-run.json"
classification_case "one mined receipt failed" reject 1 --verify "$TMP/source-only.log" "$TMP/failed-run.json"
classification_case "one mined receipt missing" reject 1 --verify "$TMP/source-only.log" "$TMP/missing-run.json"
classification_case "duplicate receipt masks missing transaction" reject 1 --verify "$TMP/source-only.log" "$TMP/duplicate-run.json"

out=$(env DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$READY" --tickers NVDA 2>&1 </dev/null) && fail "broadcast without a rehearsal exited 0"
grep -qF "no passed rehearsal of this exact run in the last 24 h" <<<"$out" || { echo "$out" | tail -5; fail "no rehearsal: wrong refusal"; }
CASES=$((CASES + 1)); printf '  ok    %-58s %s\n' "no rehearsal record" "refused before any node call"
SHA=$(sed -nE 's/.*registry sha256 ([0-9a-f]{64}), fingerprint ([0-9a-f]{64}).*/\1/p' <<<"$out")
FP=$(sed -nE 's/.*registry sha256 ([0-9a-f]{64}), fingerprint ([0-9a-f]{64}).*/\2/p' <<<"$out")
[ -n "$SHA" ] && [ -n "$FP" ] || fail "the refusal did not print the registry sha256 and the fingerprint"
FAKE="broadcast/v2-batch/00000000T000000Z-refusals-$$"
mkdir -p "$FAKE"
trap 'rm -rf "$TMP" "$ROOT/$FAKE"' EXIT
record() { # passedAt markets admin -> rehearsal-passed.json in the fake log directory
  node -e 'const [f, sha, fp, at, sel, admin] = process.argv.slice(1); require("fs").writeFileSync(f, JSON.stringify({kind: "stonkhouse-v2-rehearsal", passedAt: Number(at), registrySha256: sha, fingerprint: fp, markets: sel, deployPhase: "fresh", admin}))' \
    "$FAKE/rehearsal-passed.json" "$SHA" "$FP" "$1" "$2" "$3"
}
record "$(( $(date +%s) - 90000 ))" "NVDA:register" "$ANVIL0"
expect_refusal "a rehearsal older than 24 h" "no passed rehearsal of this exact run" \
  env DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$READY" --tickers NVDA
record "$(date +%s)" "NVDA:register,TSLA:register" "$ANVIL0"
expect_refusal "a rehearsal of other markets" "no passed rehearsal of this exact run" \
  env DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$READY" --tickers NVDA
record "$(date +%s)" "NVDA:register" "0x0000000000000000000000000000000000000001"
expect_refusal "a rehearsal sent from another admin" "no passed rehearsal of this exact run" \
  env DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$READY" --tickers NVDA
record "$(date +%s)" "NVDA:register" "$ANVIL0"
expect_refusal "a matching rehearsal clears the check (then: no node)" "no RPC at $REMOTE" \
  env DEPLOYER_PK=$ANVIL0_PK $V2 --broadcast --rpc $REMOTE --registry "$READY" --tickers NVDA
rm -rf "$FAKE"

printf '\nREFUSALS PASSED: %s cases\n' "$CASES"
