#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# pin-deployed.sh — pins the runtime artifacts of the v2 set live on chain 4663 (C3-101, F1 D12).
#
# VerifyV2 must not compare the 13 live core addresses with whatever `out/` the current checkout builds:
# `src/` moves on after a deploy (TickMath was rewritten after the deployed rev 1b08755) and the check would
# FAIL on code nobody changed on chain. So the runtimes of the commit that DID deploy the set are committed
# under script/artifacts/v2-4663/, each proven against the chain, and VerifyV2 compares a registry address
# that the manifest lists with its pinned artifact (every other address, e.g. a fresh rehearsal deploy,
# still with `out/`). The pinned files are part of DeployV2Batch.sh's rehearsal fingerprint.
#
# This script is the only writer of that directory: never hand-edit it. What it does:
#   1. `forge build` in --build, a clean checkout of the deployed commit (submodules initialised); records
#      its full SHA, the submodule SHAs, the forge version and the compiler settings from the artifacts.
#   2. per contract of the set (VerifyV2's order), from that build: `deployedBytecode.object` and
#      `.immutableReferences` into <dir>/<Contract>.json; refuses an artifact with link references.
#   3. reads the registry's address and `eth_getCode` at one block (--block, default the head): the
#      runtime must equal the artifact byte for byte outside the immutable slots (the CBOR tail included:
#      `bytecode_hash = "none"` leaves only the solc version there). The live immutable words are recorded,
#      so artifact + words == the chain's code hash can be re-proved offline (test/v2/unit/VerifyV2Pinned).
#   4. the deploy transaction of each address (from --deploy-record, the forge run JSON of the deploy, or
#      else from the manifest already committed): receipt status 1, `contractAddress` == the address, and the
#      transaction input starts with the artifact's creation bytecode (the rest is the constructor args).
#   5. writes <dir>/manifest.json with all of it. Any mismatch: prints it, writes nothing, exits 1.
#
#   script/v2/pin-deployed.sh --build <checkout> --registry <registry> --deploy-record <run.json> [--block <n>]
#   script/v2/pin-deployed.sh --check --build <checkout> --registry <registry>
#
#   --build <dir>          checkout of the deployed commit; must be clean (out/ and cache/ are ignored)
#   --registry <path>      the registry whose `v2.contracts` (13) and `v2.deployBlock` name the live set
#   --deploy-record <f>    forge's run JSON of the deploy (DeployV2Batch.sh keeps it as
#                          broadcast/v2-batch/<utc>/deploy-run-latest.json); its CREATE transactions give each
#                          address's deploy transaction. Default: the transactions the committed manifest records.
#   --rpc <url>            default $RH_RPC, else https://rpc.mainnet.chain.robinhood.com (chain 4663 required)
#   --block <n>            the block the runtimes are read at. Default: the head. The public RPC serves state only
#                          ~15 minutes behind its head, so an old block is usually unreadable there.
#   --check                regenerate into a temp directory and compare with the committed directory; writes
#                          nothing. Every file must be identical except the manifest's `checkedAt` (the block read):
#                          the set is immutable, so its code, code hashes and immutable words are the same at any
#                          block. Exit 0 prints "pin-deployed --check: N pinned runtimes match". Exit 1 otherwise.
#
# After a redeploy of core contracts (a new set, new addresses): check out the commit that deployed it in its
# own worktree and run the first form against the registry the batch wrote back; commit the directory with
# that registry change. docs/DEPLOY-V2.md "Pinned deployed runtimes". bash + jq + cast + node, no python.
# -------------------------------------------------------------------------------------------------
set -euo pipefail

CALLER_PWD=$PWD
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
export PATH="$HOME/.foundry/bin:$PATH"

PIN_DIR=script/artifacts/v2-4663
CHAIN=4663
# registry key : contract name, in VerifyV2's `_set` order (the deploy order)
SET="expiryCalendar:ExpiryCalendar sources.chainlink:ChainlinkFeedSource sources.univ3:UniV3TwapSource
sources.dataStreams:DataStreamsSource settlementOracle:SettlementOracle clearinghouse:Clearinghouse orderBook:OrderBook
keeperRewards:KeeperRewards autoRoller:AutoRoller payoutAdapter:UniV3PayoutAdapter makerRegistry:MakerRegistry
makerVault:MakerVault rewardsDistributor:RewardsDistributor"

die() { echo "pin-deployed: $*" >&2; exit 1; }
abs() { case "$1" in /*) echo "$1" ;; *) echo "$CALLER_PWD/$1" ;; esac; }

BUILD=""; REGISTRY=""; RECORD=""; RPC="${RH_RPC:-https://rpc.mainnet.chain.robinhood.com}"; BLOCK=""; CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --build) [ $# -ge 2 ] || die "--build needs a value"; BUILD=$(abs "$2"); shift 2 ;;
    --registry) [ $# -ge 2 ] || die "--registry needs a value"; REGISTRY=$(abs "$2"); shift 2 ;;
    --deploy-record) [ $# -ge 2 ] || die "--deploy-record needs a value"; RECORD=$(abs "$2"); shift 2 ;;
    --rpc) [ $# -ge 2 ] || die "--rpc needs a value"; RPC=$2; shift 2 ;;
    --block) [ $# -ge 2 ] || die "--block needs a value"; BLOCK=$2; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h | --help) sed -n '3,/^# ----/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done
[ -n "$BUILD" ] && [ -d "$BUILD" ] || die "--build <checkout of the deployed commit> is required"
[ -n "$REGISTRY" ] && [ -f "$REGISTRY" ] || die "--registry <path> is required"
[ -z "$RECORD" ] || [ -f "$RECORD" ] || die "deploy record not found: $RECORD"
MANIFEST="$ROOT/$PIN_DIR/manifest.json"
[ "$CHECK" = 0 ] || [ -f "$MANIFEST" ] || die "--check needs a committed $PIN_DIR/manifest.json"
[ -n "$RECORD" ] || [ -f "$MANIFEST" ] || die "--deploy-record <run.json> is required when no manifest is committed yet"

G=$(command -v git)
[ -x /opt/homebrew/bin/git ] && G=/opt/homebrew/bin/git
REV=$("$G" -C "$BUILD" rev-parse HEAD) || die "$BUILD is not a git checkout"
[ -z "$("$G" -C "$BUILD" status --porcelain --untracked-files=no)" ] || die "$BUILD has uncommitted changes: pin from a clean checkout of the deployed commit"
SUBMODULES=$("$G" -C "$BUILD" submodule status | awk '{ sub(/^[-+ U]/, "", $1); print $2 "=" $1 }')

chain=$(cast chain-id --rpc-url "$RPC") || die "no RPC at $RPC"
[ "$chain" = "$CHAIN" ] || die "chain id $chain at $RPC, expected $CHAIN"
[ -n "$BLOCK" ] || BLOCK=$(cast block-number --rpc-url "$RPC")
BLOCK_JSON=$(cast block "$BLOCK" --json --rpc-url "$RPC") || die "cannot read block $BLOCK"
BLOCK_HASH=$(jq -r '.hash' <<<"$BLOCK_JSON")
BLOCK_TS=$(cast to-dec "$(jq -r '.timestamp' <<<"$BLOCK_JSON")")
DEPLOY_BLOCK=$(jq -r '.v2.deployBlock // empty' "$REGISTRY")
[ -n "$DEPLOY_BLOCK" ] || die "the registry records no v2.deployBlock"

echo "== forge build in $BUILD ($REV)"
build_log=$(mktemp "${TMPDIR:-/tmp}/pin-deployed-build.XXXXXX")
(cd "$BUILD" && forge build) > "$build_log" 2>&1 || { tail -30 "$build_log"; die "forge build failed in $BUILD"; }
rm -f "$build_log"
FORGE_VERSION=$(forge --version | head -1)

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pin-deployed.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/pin"
mkdir -p "$OUT" "$TMP/entries"

bad=0; n=0
for pair in $SET; do
  n=$((n + 1))
  key=${pair%%:*}; name=${pair#*:}
  art="$BUILD/out/$name.sol/$name.json"
  [ -f "$art" ] || die "$art missing after forge build"
  [ "$(jq -r '.deployedBytecode.linkReferences | length' "$art")" = 0 ] || die "$name links a library: not supported"
  addr=$(jq -r --arg k "$key" '.v2.contracts | getpath($k | split(".")) // empty' "$REGISTRY")
  [ -n "$addr" ] && [ "$addr" != null ] || die "the registry has no v2.contracts.$key"
  addr=$(cast to-check-sum-address "$addr")
  src=$(jq -r '.metadata.settings.compilationTarget | keys[0]' "$art")

  # the pinned artifact: VerifyV2 reads it through BytecodeCheck exactly like a forge artifact, so it has the same
  # shape -- `immutableReferences` only when the contract has immutables, as forge writes it
  jq --arg name "$name" --arg src "$src" --arg rev "$REV" \
    '{contractName: $name, sourcePath: $src, sourceRev: $rev,
      deployedBytecode: ({object: .deployedBytecode.object}
        + (if .deployedBytecode | has("immutableReferences")
           then {immutableReferences: .deployedBytecode.immutableReferences} else {} end))}' \
    "$art" > "$OUT/$name.json"

  cast code "$addr" --block "$BLOCK" --rpc-url "$RPC" > "$TMP/$name.live"
  code_hash=$(cast keccak "$(cat "$TMP/$name.live")")
  runtime_keccak=$(cast keccak "$(jq -r '.deployedBytecode.object' "$art")")
  creation=$(jq -r '.bytecode.object' "$art")
  creation_keccak=$(cast keccak "$creation")

  # masked comparison + the live immutable words (node: no keccak needed here)
  node -e '
    const fs = require("fs");
    const [artFile, liveFile, outFile] = process.argv.slice(1);
    const a = JSON.parse(fs.readFileSync(artFile, "utf8"));
    const want = Buffer.from(a.deployedBytecode.object.replace(/^0x/, ""), "hex");
    const got = Buffer.from(fs.readFileSync(liveFile, "utf8").trim().replace(/^0x/, ""), "hex");
    const mask = new Uint8Array(want.length);
    const imm = [];
    for (const [id, refs] of Object.entries(a.deployedBytecode.immutableReferences || {})) {
      for (const r of refs) {
        for (let k = 0; k < r.length; k++) mask[r.start + k] = 1;
        const v = got.length >= r.start + r.length ? "0x" + got.subarray(r.start, r.start + r.length).toString("hex") : null;
        imm.push({ id, start: r.start, length: r.length, value: v });
      }
    }
    imm.sort((x, y) => x.start - y.start);
    let firstDiff = -1;
    if (got.length === want.length) {
      for (let i = 0; i < want.length; i++) if (!mask[i] && got[i] !== want[i]) { firstDiff = i; break; }
    }
    const match = got.length === want.length && firstDiff === -1;
    fs.writeFileSync(outFile, JSON.stringify({ match, codeSize: got.length, artifactSize: want.length, firstDiff,
      maskedBytes: mask.reduce((s, m) => s + m, 0), immutables: imm.map(({ start, length, value }) => ({ start, length, value })) }));
  ' "$art" "$TMP/$name.live" "$TMP/$name.cmp"
  match=$(jq -r '.match' "$TMP/$name.cmp")

  # the deploy transaction
  tx=""
  if [ -n "$RECORD" ]; then
    tx=$(jq -r --arg n "$name" --arg a "$addr" \
      '[.transactions[] | select(.transactionType == "CREATE" and .contractName == $n and ((.contractAddress // "") | ascii_downcase) == ($a | ascii_downcase)) | .hash] | first // empty' "$RECORD")
  else
    tx=$(jq -r --arg k "$key" '.contracts[$k].deploy.tx // empty' "$MANIFEST")
  fi
  [ -n "$tx" ] || die "no deploy transaction for $key ($name at $addr)"
  receipt=$(cast receipt "$tx" --json --rpc-url "$RPC") || die "no receipt for $tx"
  r_status=$(cast to-dec "$(jq -r '.status' <<<"$receipt")")
  r_addr=$(jq -r '.contractAddress // ""' <<<"$receipt")
  r_block=$(cast to-dec "$(jq -r '.blockNumber' <<<"$receipt")")
  input=$(cast tx "$tx" input --rpc-url "$RPC")
  prefix=false; args=""
  case "$input" in "$creation"*) prefix=true; args="0x${input:${#creation}}" ;; esac
  deploy_ok=false
  if [ "$r_status" = 1 ] && [ "$(cast to-check-sum-address "${r_addr:-0x0000000000000000000000000000000000000000}")" = "$addr" ] && [ "$prefix" = true ]; then
    deploy_ok=true
  fi

  printf '  %-20s %-19s %s  runtime %s (%s B, code hash %s)  deploy tx %s block %s: %s\n' "$key" "$name" "$addr" \
    "$([ "$match" = true ] && echo match || echo MISMATCH)" "$(jq -r '.codeSize' "$TMP/$name.cmp")" "$code_hash" "$tx" "$r_block" \
    "$([ "$deploy_ok" = true ] && echo "creation input == artifact + args" || echo "DEPLOY TX MISMATCH (status $r_status, contractAddress $r_addr, prefix $prefix)")"
  [ "$match" = true ] || { bad=$((bad + 1)); jq -c '{codeSize, artifactSize, firstDiff}' "$TMP/$name.cmp" >&2; }
  [ "$deploy_ok" = true ] || bad=$((bad + 1))

  jq -n --arg key "$key" --arg name "$name" --arg addr "$addr" --arg src "$src" --arg file "$PIN_DIR/$name.json" \
    --arg codeHash "$code_hash" --arg rk "$runtime_keccak" --arg ck "$creation_keccak" \
    --arg tx "$tx" --argjson txBlock "$r_block" --arg args "$args" --slurpfile cmp "$TMP/$name.cmp" \
    '{key: $key, value: {contract: $name, address: $addr, sourcePath: $src, artifact: $file,
      runtimeArtifactKeccak: $rk, creationArtifactKeccak: $ck,
      codeHash: $codeHash, codeSize: $cmp[0].codeSize, match: $cmp[0].match, maskedBytes: $cmp[0].maskedBytes,
      immutables: $cmp[0].immutables,
      deploy: {tx: $tx, block: $txBlock, creationInputIsArtifactPlusArgs: true, constructorArgs: $args}}}' \
    > "$TMP/entries/$(printf '%02d' "$n")-$name.json"
done
[ "$bad" = 0 ] || die "$bad mismatch(es) above: nothing written. A pinned runtime must be proven against the chain."

# compiler settings, as the artifacts record them (identical for every contract of the set)
first=$(echo "$SET" | head -1 | awk '{print $1}'); first=${first#*:}
settings=$(jq -c '{solc: .metadata.compiler.version, evmVersion: .metadata.settings.evmVersion,
  optimizer: .metadata.settings.optimizer.enabled, optimizerRuns: .metadata.settings.optimizer.runs,
  viaIR: .metadata.settings.viaIR, bytecodeHash: .metadata.settings.metadata.bytecodeHash}' "$BUILD/out/$first.sol/$first.json")
for pair in $SET; do
  name=${pair#*:}
  s=$(jq -c '{solc: .metadata.compiler.version, evmVersion: .metadata.settings.evmVersion,
    optimizer: .metadata.settings.optimizer.enabled, optimizerRuns: .metadata.settings.optimizer.runs,
    viaIR: .metadata.settings.viaIR, bytecodeHash: .metadata.settings.metadata.bytecodeHash}' "$BUILD/out/$name.sol/$name.json")
  [ "$s" = "$settings" ] || die "$name was compiled with other settings ($s) than $first ($settings)"
done

jq -n --argjson chain "$CHAIN" --arg rev "$REV" --arg subs "$SUBMODULES" --arg forge "$FORGE_VERSION" \
  --argjson settings "$settings" --argjson deployBlock "$DEPLOY_BLOCK" --argjson block "$BLOCK" \
  --arg blockHash "$BLOCK_HASH" --argjson ts "$BLOCK_TS" --slurpfile entries <(cat "$TMP"/entries/*.json | jq -s '.') \
  '{kind: "stonkhouse-v2-pinned-runtimes",
    note: "Written by script/v2/pin-deployed.sh; never hand-edit. VerifyV2 compares a registry address listed here with its pinned artifact instead of out/ (C3-101).",
    chainId: $chain,
    source: {repository: "callhouse-contracts", rev: $rev,
      submodules: ($subs | split("\n") | map(select(length > 0) | split("=") | {key: .[0], value: .[1]}) | from_entries),
      build: "forge build (the checkout foundry.toml: profile.default)", forge: $forge, compiler: $settings},
    deployBlock: $deployBlock,
    checkedAt: {block: $block, blockHash: $blockHash, timestamp: $ts},
    contracts: ($entries[0] | from_entries)}' > "$OUT/manifest.json"

N=$(echo $SET | wc -w | tr -d ' ')
if [ "$CHECK" = 1 ]; then
  # the block read is the one field allowed to differ
  jq -S 'del(.checkedAt)' "$OUT/manifest.json" > "$TMP/manifest.generated"
  jq -S 'del(.checkedAt)' "$MANIFEST" > "$TMP/manifest.committed"
  rc=0
  diff "$TMP/manifest.generated" "$TMP/manifest.committed" >&2 || rc=1
  diff -r -x manifest.json "$OUT" "$ROOT/$PIN_DIR" >&2 || rc=1
  [ "$rc" = 0 ] || die "the committed $PIN_DIR differs from what $REV and the chain at block $BLOCK give (diff above)"
  echo "pin-deployed --check: $N pinned runtimes match ($REV, read at block $BLOCK; committed at block $(jq -r '.checkedAt.block' "$MANIFEST"))"
else
  mkdir -p "$ROOT/$PIN_DIR"
  rm -f "$ROOT/$PIN_DIR"/*.json
  cp "$OUT"/*.json "$ROOT/$PIN_DIR/"
  echo "pinned $N runtimes of $REV into $PIN_DIR (block $BLOCK, $BLOCK_HASH)"
fi
