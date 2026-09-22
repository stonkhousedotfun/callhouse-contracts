#!/usr/bin/env bash
# launch-v8.sh — the owner's v8 launch block as ONE gated script (T-OP-179).
#
#   script/v2/launch-v8.sh preflight  [--callhouse <dir>] [--run-dir <dir>] [--rpc <url>] [--skip-external a,b]
#   script/v2/launch-v8.sh deploy     --i-am-the-owner   (sends: 16 CREATEs + wiring; the deployer KEEPS ADMIN)
#   script/v2/launch-v8.sh writeback                     (callhouse tool: registry gains the sixteen + deployBlock)
#   script/v2/launch-v8.sh verify     --i-am-the-owner   (sends: externals, MapExternals, VerifyV8 gate, register, HandBack, VerifyV8)
#   script/v2/launch-v8.sh check                         (read-only post-checks)
#   script/v2/launch-v8.sh deploy|verify --dry-run       (a fork rehearsal of the SAME driver invocation, nothing sent, no key)
#   ... --pinned-tree  (or --tip HEAD)                     (T-OP-195: preflight / writeback / check / --dry-run ONLY -- this tree's
#                                                          HEAD is the pin, the live leekzor/v8 may be ahead; a sending deploy or
#                                                          verify with it is refused. Prints PINNED REHEARSAL in capitals)
#
# THIS SCRIPT IS A WRAPPER. Every transaction is sent by script/v2/broadcast-v8.sh (the landed launch driver);
# every registry write is made by callhouse ops/markets/write-back-v8.mjs; this file adds the checks the
# operator's copy-paste block asked a human to perform by eye, and refuses to continue when one fails:
#
#   - the CONTRACTS TIP: `git rev-parse leekzor/v8` and HEAD must both equal FINAL_TIP below. The pin is the
#     SHA this script was re-derived at; when the tip moves the owner re-pins it (or passes --tip <sha>, which
#     is printed in capitals) after re-reading §0 of docs/LAUNCH-COMMANDS-V8.md. A silent mismatch is how a
#     driver from one tip runs against a registry from another.
#   - the REGISTRY FACTS: guardian, the two 2-of-3 Safes and the launch set are READ from the registry and
#     compared with the values this script states (read from callhouse 52c4741d, never typed from memory);
#     any difference is a refusal by name. The script never types an address into a transaction: every
#     address the driver uses comes out of the registry through lib/registry-env.sh.
#   - the KEY: read with `read -rs` from the terminal inside `deploy` and `verify` ONLY, exported to the ONE
#     child process that sends, and unset again. A DEPLOYER_PK or ADMIN_PK already in the environment at
#     entry is refused (a key that arrived by env is a key in some file or history); a key-shaped argument is
#     refused before anything else is read (the driver refuses it too).
#   - the OWNER GATE: `deploy` and `verify` need --i-am-the-owner AND print the exact driver command, then
#     wait for the literal word `yes` on the terminal. Anything else aborts with nothing sent.
#   - the RPC: --rpc, else $LAUNCH_RPC, else FORK_URL from ~/.agent-bridge/stonkhouse/fork.env (mode 600).
#     The URL carries a key. It is never printed: every line of every child's output passes through `scrub`,
#     which replaces the URL by `<rpc host>`, BEFORE it reaches a log or the screen. (broadcast-v8.sh itself
#     prints `rpc <url>` at its :720 — that line is the reason the scrub exists.)
#   - the RUN DIR: under ./broadcast, the one path foundry.toml fs_permissions lets a forge script write
#     (DeployV8 V2_DEPLOY_OUT / V2_DEPLOY_RECORD_OUT). Every log path is echoed; every child's rc is propagated.
#
# WHAT IS NOT HERE, on purpose: no impersonation (--unlocked, anvil stand-ins: that is rehearse-v2.sh's job),
# no `--from register` re-entry after HandBack (§6 of the doc says why), no push, no Safe transaction (the
# day-zero batch is a separate, receipt-gated tool). This wrapper does not edit the drivers, the lib, DeployV8
# or VerifyV8; when their flags move, it is THIS file and docs/LAUNCH-COMMANDS-V8.md that are re-derived.
#
# Re-derived at contracts aeab59779b994ddad97df5b10c9b2383defab0b0 (leekzor/v8, 2026-09-22): broadcast-v8.sh
# flags :333-341 (--registry --rpc --execute --chain-id --from --run-dir --skip-external --self-test),
# `say` steps :724 (0 preflight) :853 (1 deploy) :895 (stop before verify) :909 (1b externals) :916 (2 VerifyV8
# gate) :959 (3 register, as the deployer: V2_ADMIN="$DEPLOYER_ADDR" at :311) :1020 (4 hand-back) :1027 (5
# VerifyV8 read-back) :1050 (done); ADMIN_PK refused at :732 via lib registry_env_refuse_admin_pk (:1060);
# run dir under ./broadcast :704-715 (foundry.toml:55 read-write ./broadcast); the write-back instruction the
# driver prints :888-890; lib EXTERNAL_SKIP_DEFAULT :608 = "hedger rewardsDistributorLender stockVenueAdapter".
set -euo pipefail

FINAL_TIP="aeab59779b994ddad97df5b10c9b2383defab0b0"
# The registry facts, as read from callhouse leekzor/v8 52c4741ded4f7b685eb6008207331f9a25f59da7
# ops/markets/tier1.json with jq (never typed): owner rulings 2026-09-22 05:45Z (launch set) and 06:12Z (guardian).
EXPECT_GUARDIAN="0x29741A8d283a253E8Ce10aDfd04C6507438b6F39"
EXPECT_ADMIN_SAFE="0x6f8A7B77b72511cD8939596b1659bA28C28f101B"
EXPECT_TREASURY_SAFE="0x014b996a084690FB27265BfAC157b04e9FeBbF4E"
EXPECT_LAUNCH_SET="NVDA,SPCX"
CHAIN_ID=4663
# The owner's window, in REGISTRY-KEY spelling (the driver's own default; passing it is belt and braces):
# Hedger, RewardsDistributorLender and StockVenueAdapter are OUT for launch (owner 2026-09-22 05:45Z).
SKIP_DEFAULT="hedger,rewardsDistributorLender,stockVenueAdapter"
FORK_ENV="$HOME/.agent-bridge/stonkhouse/fork.env"

# The contracts tree the driver runs from: this script's own repo by default, or LAUNCH_CONTRACTS=<dir> (the
# operator's warm tree at the tip; the script may then live anywhere). Everything is resolved from ROOT.
ROOT=${LAUNCH_CONTRACTS:-$(cd "$(dirname "$0")/../.." && pwd)}
ROOT=$(cd "$ROOT" && pwd)
HERE="$ROOT/script/v2"
DRIVER="$HERE/broadcast-v8.sh"
[ -f "$DRIVER" ] || { printf '!! %s\n' "no launch driver at $DRIVER (LAUNCH_CONTRACTS / this script's location must be a callhouse-contracts tree)" >&2; exit 1; }

say() { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- refusals that need no input at all
# A key-shaped argument (0x + 64 hex) or a --private-key flag anywhere on argv: refused before anything is read.
for a in "$@"; do
  case "$a" in
    --private-key|--private-key=*) die "a --private-key argument was passed. Keys are typed at the prompt inside deploy/verify, never on a command line" ;;
  esac
  if printf '%s' "$a" | grep -Eq '^(0x)?[0-9a-fA-F]{64}$'; then
    die "a key-shaped argument was passed on the command line. It is in your shell history and in ps output: rotate it if it was real. Keys are typed at the prompt inside deploy/verify"
  fi
done
[ -z "${ADMIN_PK:-}" ] || die "ADMIN_PK is set in the environment. The launch registers as the DEPLOYER inside its deferred-ADMIN window (T-OP-161); a second key is never needed. unset ADMIN_PK (and rotate it if it was real)"
[ -z "${DEPLOYER_PK:-}" ] || die "DEPLOYER_PK is set in the environment at entry. This script reads the key at the prompt inside deploy/verify only, so that it never lives in a file, an env export or a history line. unset DEPLOYER_PK"

# ---------------------------------------------------------------- arguments
SUB=${1:-}; shift || true
# The callhouse v8 worktree: --callhouse, else LAUNCH_CALLHOUSE, else the sibling `v8-callhouse` of this tree
# (wt/v8-contracts -> wt/v8-callhouse) or the workspace's wt/v8-callhouse. Never the main checkout: it may be on
# another branch, and this script refuses a tree that is not at its own leekzor/v8.
CALLHOUSE=${LAUNCH_CALLHOUSE:-}
if [ -z "$CALLHOUSE" ]; then
  for c in "$ROOT/../v8-callhouse" "$ROOT/../wt/v8-callhouse"; do [ -d "$c" ] && CALLHOUSE=$c && break; done
  CALLHOUSE=${CALLHOUSE:-"$ROOT/../wt/v8-callhouse"}
fi
RUN_DIR=${LAUNCH_RUN_DIR:-}
RPC=${LAUNCH_RPC:-}
TIP_OVERRIDE=""
PINNED=0
OWNER=0
DRY=0
SKIP=$SKIP_DEFAULT
while [ $# -gt 0 ]; do
  case "$1" in
    --callhouse) CALLHOUSE=${2:?--callhouse needs a dir}; shift 2 ;;
    --run-dir) RUN_DIR=${2:?--run-dir needs a dir}; shift 2 ;;
    --rpc) RPC=${2:?--rpc needs a url}; shift 2 ;;
    --tip) TIP_OVERRIDE=${2:?--tip needs a sha}; shift 2 ;;
    --pinned-tree) PINNED=1; shift ;;
    --skip-external) SKIP=${2:?--skip-external needs a,b}; shift 2 ;;
    --i-am-the-owner) OWNER=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,48p' "$0"; exit 0 ;;
    *) die "unknown argument '$1' (see --help)" ;;
  esac
done
case "$SUB" in preflight|deploy|writeback|verify|check) ;; ""|-h|--help) sed -n '2,48p' "$0"; exit 0 ;; *) die "unknown subcommand '$SUB': preflight | deploy | writeback | verify | check" ;; esac

# ---------------------------------------------------------------- the RPC, and the scrub that keeps it out of every log
if [ -z "$RPC" ]; then
  [ -f "$FORK_ENV" ] || die "no --rpc, no LAUNCH_RPC, and $FORK_ENV does not exist (the operator's fork.env, mode 600, one line FORK_URL=...)"
  FORK_URL=""
  set -a; . "$FORK_ENV"; set +a
  [ -n "${FORK_URL:-}" ] || die "$FORK_ENV did not set FORK_URL"
  RPC=$FORK_URL
  RPC_SRC="FORK_URL from $FORK_ENV"
else
  RPC_SRC="--rpc / LAUNCH_RPC"
fi
RPC_HOST=$(printf '%s' "$RPC" | sed -E 's#^[a-z]+://([^/@]*@)?([^/:?]+).*$#\2#')
[ -n "$RPC_HOST" ] || die "could not read a host out of the RPC url"
# Literal (not regex) replacement of the URL by "<rpc HOST>" on every line, unbuffered enough for tee.
scrub() { awk -v u="$RPC" -v h="<rpc $RPC_HOST>" '{ s=$0; out=""; while ((i=index(s,u))>0) { out=out substr(s,1,i-1) h; s=substr(s,i+length(u)) } print out s; fflush() }'; }

# ---------------------------------------------------------------- the prologue: tip, trees, registry facts
say "launch-v8 $SUB  ($(date -u +%FT%TZ))"
info "contracts   $ROOT"
info "rpc         $RPC_HOST ($RPC_SRC; the url itself is never printed)"

# Tools present (versions into the log; the driver and the lib need all five).
for t in forge cast anvil node jq git; do command -v "$t" >/dev/null || die "$t is not on PATH"; done
info "forge       $(forge --version 2>/dev/null | head -1)"
info "cast        $(cast --version 2>/dev/null | head -1)"
info "node        $(node --version)   jq $(jq --version)"

# The contracts tip. Fetch (a read), then both the remote ref and HEAD must be the pin.
#
# T-OP-195: `--pinned-tree` (or `--tip HEAD`) makes THIS TREE'S HEAD the pin and skips the remote-tip equality,
# for the NON-SENDING subcommands only (preflight, writeback, check, and deploy/verify with --dry-run). While
# rows land, leekzor/v8 moves every few minutes and every pinned rehearsal was refused at :158 before it ran a
# line. A sending deploy or verify with the flag is refused by name below: the live tip rule for those is
# unchanged, and so are their two refusal texts (docs/LAUNCH-COMMANDS-V8.md §8 row 1 names them). `--tip <sha>`
# is a different thing -- it re-pins for ALL subcommands and still requires remote == HEAD == that sha.
PIN=$FINAL_TIP
if [ "$TIP_OVERRIDE" = HEAD ]; then PINNED=1; TIP_OVERRIDE=""; fi
if [ "$PINNED" = 1 ]; then
  case "$SUB" in
    deploy|verify) [ "$DRY" = 1 ] || die "--pinned-tree is refused for $SUB: a sending subcommand runs only at the live leekzor/v8 tip (drop the flag, or add --dry-run for a rehearsal). Nothing was run" ;;
  esac
  PIN=$(git -C "$ROOT" rev-parse HEAD)
elif [ -n "$TIP_OVERRIDE" ]; then
  PIN=$TIP_OVERRIDE
  info "TIP OVERRIDDEN ON THE COMMAND LINE: --tip $PIN (the pinned FINAL_TIP is $FINAL_TIP). Re-read docs/LAUNCH-COMMANDS-V8.md §0 before trusting this run"
fi
git -C "$ROOT" fetch --quiet leekzor v8 || die "git fetch leekzor v8 failed in $ROOT"
REMOTE_TIP=$(git -C "$ROOT" rev-parse leekzor/v8)
LOCAL_HEAD=$(git -C "$ROOT" rev-parse HEAD)
if [ "$PINNED" = 1 ]; then
  info "PINNED REHEARSAL: HEAD $PIN used as the pin (--pinned-tree); leekzor/v8 is $REMOTE_TIP$([ "$REMOTE_TIP" = "$PIN" ] && echo ' (== HEAD)' || echo " ($(git -C "$ROOT" rev-list --count "$PIN..$REMOTE_TIP" 2>/dev/null || echo '?') commit(s) ahead)"); the pinned FINAL_TIP is $FINAL_TIP. THIS RUN CANNOT SEND: it is not the launch tip"
else
  [ "$REMOTE_TIP" = "$PIN" ] || die "leekzor/v8 is $REMOTE_TIP, not the pinned FINAL_TIP $PIN. The tip moved: re-derive §0 of docs/LAUNCH-COMMANDS-V8.md at the new tip, re-pin FINAL_TIP in this script (or pass --tip after reading what moved). Nothing was run"
fi
[ "$LOCAL_HEAD" = "$PIN" ] || die "this tree's HEAD is $LOCAL_HEAD, not the pinned FINAL_TIP $PIN. forge compiles HEAD: check out the tip (git -C $ROOT checkout --detach $PIN) or use the operator's warm tree"
DIRTY=$(git -C "$ROOT" status --porcelain | grep -v '^?? \(out\|cache\|broadcast\)/' || true)
[ -z "$DIRTY" ] || die "the contracts tree is not clean (tracked or unexpected untracked files):
$DIRTY"
if [ "$PINNED" = 1 ]; then info "contracts   HEAD == pin $PIN (PINNED REHEARSAL, not the launch tip), tree clean"
else info "contracts   HEAD == leekzor/v8 == FINAL_TIP $PIN, tree clean"; fi

# The callhouse tree: a v8 worktree at ITS tip (the main checkout may sit on another branch: never that).
[ -d "$CALLHOUSE/.git" ] || [ -f "$CALLHOUSE/.git" ] || die "callhouse worktree not found at $CALLHOUSE (--callhouse <dir> or LAUNCH_CALLHOUSE; create one with: node scripts/operator/mkwt.mjs callhouse v8-callhouse <callhouse leekzor/v8 sha>)"
git -C "$CALLHOUSE" fetch --quiet leekzor v8 || die "git fetch leekzor v8 failed in $CALLHOUSE"
CH_TIP=$(git -C "$CALLHOUSE" rev-parse leekzor/v8)
CH_HEAD=$(git -C "$CALLHOUSE" rev-parse HEAD)
[ "$CH_HEAD" = "$CH_TIP" ] || die "callhouse worktree $CALLHOUSE is at $CH_HEAD, not its leekzor/v8 tip $CH_TIP. The registry and the write-back tool must be the tip's: git -C $CALLHOUSE checkout --detach leekzor/v8"
REGISTRY="$CALLHOUSE/ops/markets/tier1.json"
SOURCES="$CALLHOUSE/ops/markets/v2-sources.json"
[ -f "$REGISTRY" ] || die "registry not found: $REGISTRY"
[ -f "$SOURCES" ] || die "v2-sources.json not found beside the registry: $SOURCES (the driver requires it)"
info "callhouse   $CALLHOUSE at $CH_HEAD (== its leekzor/v8)"
info "registry    $REGISTRY  sha256 $(shasum -a 256 "$REGISTRY" | cut -d' ' -f1)"
info "sources     $SOURCES  sha256 $(shasum -a 256 "$SOURCES" | cut -d' ' -f1)"

# The registry facts this script states, read back and compared. A mismatch is a refusal by name.
REG_GUARDIAN=$(jq -r '.shared.guardian // empty' "$REGISTRY")
REG_ADMIN_SAFE=$(jq -r '.shared.safes.admin // empty' "$REGISTRY")
REG_TREASURY_SAFE=$(jq -r '.shared.safes.treasury // empty' "$REGISTRY")
REG_LAUNCH_SET=$(jq -r 'if (.launchSet.markets|type)=="array" then (.launchSet.markets|join(",")) else "" end' "$REGISTRY")
[ "$REG_GUARDIAN" = "$EXPECT_GUARDIAN" ] || die "registry shared.guardian is '$REG_GUARDIAN', this script states $EXPECT_GUARDIAN (owner ruling 2026-09-22 06:12Z). Re-derive before continuing"
[ "$REG_ADMIN_SAFE" = "$EXPECT_ADMIN_SAFE" ] || die "registry shared.safes.admin is '$REG_ADMIN_SAFE', this script states $EXPECT_ADMIN_SAFE (T-OP-111)"
[ "$REG_TREASURY_SAFE" = "$EXPECT_TREASURY_SAFE" ] || die "registry shared.safes.treasury is '$REG_TREASURY_SAFE', this script states $EXPECT_TREASURY_SAFE (T-OP-111)"
[ "$REG_LAUNCH_SET" = "$EXPECT_LAUNCH_SET" ] || die "registry launchSet.markets is '$REG_LAUNCH_SET', this script states $EXPECT_LAUNCH_SET (owner ruling 2026-09-21)"
info "registry    guardian $REG_GUARDIAN  admin safe $REG_ADMIN_SAFE  treasury safe $REG_TREASURY_SAFE  launch set [$REG_LAUNCH_SET]"
info "registry    v2.deployBlock=$(jq -r '.v2.deployBlock' "$REGISTRY")  contracts.accessManager=$(jq -r '.v2.contracts.accessManager' "$REGISTRY")  contracts.houseVault=$(jq -r '.v2.contracts.houseVault' "$REGISTRY")"
info "sources     contracts keys: $(jq -r '.contracts | keys | join(",")' "$SOURCES")"

# The run dir: under ./broadcast (foundry.toml fs_permissions; the driver refuses anything else by name).
RUN_DIR=${RUN_DIR:-"$ROOT/broadcast/v8-launch/$(date -u +%Y%m%dT%H%M%SZ)"}
case "$RUN_DIR" in "$ROOT"/broadcast/*) ;; *) die "--run-dir $RUN_DIR must be under $ROOT/broadcast (foundry.toml fs_permissions read-write ./broadcast)" ;; esac
mkdir -p "$RUN_DIR"
LOG="$RUN_DIR/launch-$SUB-$(date -u +%Y%m%dT%H%M%SZ).log"
info "run dir     $RUN_DIR"
info "log         $LOG   (every child's output, scrubbed)"
info "skip        --skip-external $SKIP"

# The chain the RPC answers, before anything else asks it.
CHAIN_ON_RPC=$(cast chain-id --rpc-url "$RPC" 2>&1 | scrub) || die "cast chain-id failed against $RPC_HOST: $CHAIN_ON_RPC"
[ "$CHAIN_ON_RPC" = "$CHAIN_ID" ] || die "the RPC at $RPC_HOST answers chain id '$CHAIN_ON_RPC', not $CHAIN_ID"
info "chain       $CHAIN_ON_RPC at block $(cast block-number --rpc-url "$RPC" 2>&1 | scrub)"

# Runs a child with its output scrubbed and tee'd into $LOG; propagates the child's rc, never tee's.
run_logged() {
  set +e
  "$@" 2>&1 | scrub | tee -a "$LOG"
  local rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

# The owner gate: --i-am-the-owner, the exact command printed, the word `yes` typed, then the key typed unseen.
# The key lives in this shell's DEPLOYER_PK variable only between `read -rs` and the child's exit.
owner_gate() {
  local what=$1; shift
  [ "$OWNER" = 1 ] || die "$what SENDS TRANSACTIONS and needs --i-am-the-owner"
  [ -t 0 ] || die "$what needs a terminal to confirm on (stdin is not a tty)"
  say "OWNER GATE — $what will run exactly:"
  printf '   %s\n' "$*" | scrub
  printf '   Type the word yes to send (anything else aborts, nothing sent): '
  local answer
  read -r answer </dev/tty
  [ "$answer" = "yes" ] || die "aborted at the owner gate ('$answer'); nothing sent"
  printf '   DEPLOYER_PK (0x + 64 hex, typed unseen, never stored): '
  read -rs DEPLOYER_PK </dev/tty; printf '\n'
  printf '%s' "$DEPLOYER_PK" | grep -Eq '^0x[0-9a-fA-F]{64}$' || { unset DEPLOYER_PK; die "that is not a 0x-prefixed 32-byte hex key; nothing sent"; }
}

driver_args=(--registry "$REGISTRY" --rpc "$RPC" --run-dir "$RUN_DIR" --skip-external "$SKIP")

case "$SUB" in
# ---------------------------------------------------------------- preflight (sends nothing)
preflight)
  say "P1. build (warm tree: seconds; a cold tree: minutes — never on the clock)"
  run_logged forge build --skip test || die "forge build failed (rc $?)"
  say "P2. export-abis --check against $CALLHOUSE"
  run_logged bash "$HERE/export-abis.sh" --check --callhouse "$CALLHOUSE" --skip-build || die "export-abis --check refused: the callhouse ABIs do not match this tip (rc $?)"
  say "P3. broadcast-v8 --self-test (no node, no key, no transaction)"
  run_logged bash "$DRIVER" --self-test || die "broadcast-v8 --self-test failed (rc $?)"
  grep -q "SELF-TEST PASSED" "$LOG" || die "the self-test did not print SELF-TEST PASSED"
  say "P4. DRY RUN of the launch driver against the real registry (simulates DeployV8; sends nothing)"
  info "bash script/v2/broadcast-v8.sh --registry <registry> --rpc <rpc $RPC_HOST> --run-dir $RUN_DIR --skip-external $SKIP"
  run_logged bash "$DRIVER" "${driver_args[@]}" || die "the dry run refused or failed (rc $?): read the last !! line in $LOG, fix the INPUT it names, re-run preflight"
  grep -q "stopped before verify: registry not yet written back" "$LOG" || die "the dry run did not reach 'stopped before verify' — read $LOG"
  say "preflight PASSED  (self-test + dry run at $PIN against $REGISTRY)"
  info "next: script/v2/launch-v8.sh deploy --i-am-the-owner --run-dir $RUN_DIR"
  ;;

# ---------------------------------------------------------------- deploy (sends; the deployer keeps ADMIN)
deploy)
  if [ "$DRY" = 1 ]; then
    say "D0. deploy --dry-run: the same driver invocation WITHOUT --execute (nothing sent, no key)"
    [ -z "${LAUNCH_DEPLOYER:-}" ] || export V2_DEPLOYER="$LAUNCH_DEPLOYER"
    run_logged bash "$DRIVER" "${driver_args[@]}" --chain-id "$CHAIN_ID" || die "deploy --dry-run failed (rc $?): $LOG"
    say "deploy --dry-run done  ($LOG)"
    exit 0
  fi
  DEPLOY_BLOCK=$(jq -r '.v2.deployBlock' "$REGISTRY")
  [ "$DEPLOY_BLOCK" = null ] || die "the registry already carries v2.deployBlock=$DEPLOY_BLOCK: a set is recorded. A second deploy is the set twice. If a run died half-way, write back and use verify"
  owner_gate "deploy" bash script/v2/broadcast-v8.sh --registry "$REGISTRY" --rpc "<rpc $RPC_HOST>" --run-dir "$RUN_DIR" --skip-external "$SKIP" --execute --chain-id "$CHAIN_ID"
  say "D1. DeployV8 (V2_DEFER_HANDBACK=true inside the driver): 16 CREATEs + wiring; THE DEPLOYER KEEPS ADMIN until verify"
  set +e
  DEPLOYER_PK="$DEPLOYER_PK" bash "$DRIVER" "${driver_args[@]}" --execute --chain-id "$CHAIN_ID" 2>&1 | scrub | tee -a "$LOG"
  rc=${PIPESTATUS[0]}
  set -e
  unset DEPLOYER_PK
  if [ "$rc" != 0 ]; then
    printf '!! deploy exited %s. If CREATEs were sent, SOME contracts exist and the deployer HOLDS ADMIN: do NOT run deploy again.\n' "$rc" | tee -a "$LOG" >&2
    printf '!! Recover: the V2_ADDRESS lines in %s/deploy.log -> write-back -> verify. See docs/LAUNCH-COMMANDS-V8.md §8.\n' "$RUN_DIR" | tee -a "$LOG" >&2
    exit "$rc"
  fi
  [ -f "$RUN_DIR/deploy-record.json" ] || die "deploy exited 0 but $RUN_DIR/deploy-record.json is missing: read $LOG before anything else"
  say "deploy DONE  record $RUN_DIR/deploy-record.json  addresses $RUN_DIR/deploy-addresses.json"
  info "AT ONCE (the deployer holds ADMIN): script/v2/launch-v8.sh writeback --run-dir $RUN_DIR && script/v2/launch-v8.sh verify --i-am-the-owner --run-dir $RUN_DIR"
  ;;

# ---------------------------------------------------------------- writeback (callhouse tool; commits the registry locally)
writeback)
  RECORD="$RUN_DIR/deploy-record.json"
  [ -f "$RECORD" ] || die "no deploy record at $RECORD (--run-dir must be the deploy's run dir)"
  WB="$CALLHOUSE/ops/markets/write-back-v8.mjs"
  [ -f "$WB" ] || die "write-back tool not found: $WB"
  say "W1. write-back --check (diff only; exit 1 here means 'would change', which is expected before the write)"
  run_logged node "$WB" --deployment "$RECORD" --registry "$REGISTRY" --check || info "(--check exited $?: paths listed above would change)"
  say "W2. write-back (writes the sixteen + deployBlock + principals' twins into $REGISTRY)"
  run_logged node "$WB" --deployment "$RECORD" --registry "$REGISTRY" || die "write-back refused (rc $?): read the lines above; the registry was NOT written"
  say "W3. build-markets --check on the written-back registry (validators + the on-chain pool probe)"
  ( cd "$CALLHOUSE" && run_logged node ops/markets/build-markets.mjs --check ) || die "build-markets --check is red on the written-back registry (rc $?): fix before verify"
  info "registry now  deployBlock=$(jq -r '.v2.deployBlock' "$REGISTRY")  accessManager=$(jq -r '.v2.contracts.accessManager' "$REGISTRY")  feeSplitter=$(jq -r '.v2.flywheel.feeSplitter' "$REGISTRY")"
  say "W4. local commit in $CALLHOUSE (no push: pushing leekzor is the operator's, after the whole sequence)"
  git -C "$CALLHOUSE" add ops/markets/tier1.json
  git -C "$CALLHOUSE" commit -q -m "v8: tier1 write-back after DeployV8 (deployBlock $(jq -r '.v2.deployBlock' "$REGISTRY"))" || die "git commit failed in $CALLHOUSE"
  info "committed $(git -C "$CALLHOUSE" rev-parse HEAD)"
  say "writeback DONE"
  info "AT ONCE: script/v2/launch-v8.sh verify --i-am-the-owner --run-dir $RUN_DIR"
  ;;

# ---------------------------------------------------------------- verify (sends: externals, MapExternals, gate, register, HandBack, read-back)
verify)
  DEPLOY_BLOCK=$(jq -r '.v2.deployBlock' "$REGISTRY")
  [ "$DEPLOY_BLOCK" != null ] || die "the registry carries no v2.deployBlock: run writeback first (the driver's fingerprint and VerifyV8 read the addresses from the registry, never from a log)"
  if [ "$DRY" = 1 ]; then
    say "V0. verify --dry-run: the same driver invocation WITHOUT --execute (simulates externals / MapExternals / VerifyV8 / register; sends nothing, no key)"
    [ -z "${LAUNCH_DEPLOYER:-}" ] || export V2_DEPLOYER="$LAUNCH_DEPLOYER"
    run_logged bash "$DRIVER" "${driver_args[@]}" --chain-id "$CHAIN_ID" --from verify || die "verify --dry-run failed (rc $?): $LOG"
    say "verify --dry-run done  ($LOG)"
    exit 0
  fi
  owner_gate "verify" bash script/v2/broadcast-v8.sh --registry "$REGISTRY" --rpc "<rpc $RPC_HOST>" --run-dir "$RUN_DIR" --skip-external "$SKIP" --execute --chain-id "$CHAIN_ID" --from verify
  say "V1. --from verify: 1b externals -> MapExternals -> 2 VerifyV8 (gate) -> 3 register (deployer) -> 4 HandBack -> 5 VerifyV8 (read-back)"
  set +e
  DEPLOYER_PK="$DEPLOYER_PK" bash "$DRIVER" "${driver_args[@]}" --execute --chain-id "$CHAIN_ID" --from verify 2>&1 | scrub | tee -a "$LOG"
  rc=${PIPESTATUS[0]}
  set -e
  unset DEPLOYER_PK
  if [ "$rc" != 0 ]; then
    printf '!! verify exited %s. If HandBack (step 4) did not run, THE DEPLOYER STILL HOLDS ADMIN: fix the input it names and re-run this exact command (idempotent over recorded externals; MapExternals no-op on mapped selectors; HandBack idempotent). §8 of the doc.\n' "$rc" | tee -a "$LOG" >&2
    exit "$rc"
  fi
  if ! grep -q "VERIFY PASSED" "$LOG"; then
    die "verify exited 0 but no 'VERIFY PASSED' line is in $LOG: a VerifyV8 log with no summary is FAILED-INCOMPLETE (T-OP-152), not a pass"
  fi
  say "verify DONE  receipt $RUN_DIR/verify-passed.json"
  info "next: script/v2/launch-v8.sh check --run-dir $RUN_DIR"
  ;;

# ---------------------------------------------------------------- check (read-only)
check)
  say "C1. the verify log's summary lines"
  VLOG=$(ls -t "$RUN_DIR"/launch-verify-*.log 2>/dev/null | head -1 || true)
  if [ -n "$VLOG" ]; then
    info "log $VLOG"
    grep -E "VERIFY PASSED|VERIFY FAILED|FAILED-INCOMPLETE|NOT CHECKED|externals:|HandBack|hand-back|FINGERPRINT" "$VLOG" | sed 's/^/   /' || true
  else
    info "no launch-verify-*.log in $RUN_DIR yet"
  fi
  [ -f "$RUN_DIR/verify-passed.json" ] && info "receipt     $RUN_DIR/verify-passed.json ($(jq -c '.' "$RUN_DIR/verify-passed.json" 2>/dev/null | cut -c1-160))" || info "receipt     none at $RUN_DIR/verify-passed.json (registration is refused without it)"

  say "C2. the manager: the deployer holds nothing, the Admin Safe holds ADMIN at the manifest delay"
  AM=$(jq -r '.v2.contracts.accessManager // empty' "$REGISTRY")
  [ -n "$AM" ] || die "v2.contracts.accessManager is null in the registry: nothing to check yet"
  ADMIN_DELAY=$(jq -r '.delaysS.ADMIN' "$HERE/roles.v8.json")
  DEPLOYER_ADDR=${LAUNCH_DEPLOYER:-$(jq -r '.deployer // .wallets.deployer // empty' "$RUN_DIR/deploy-record.json" 2>/dev/null || true)}
  if [ -n "$DEPLOYER_ADDR" ]; then
    info "hasRole(ADMIN, deployer $DEPLOYER_ADDR): $(cast call "$AM" 'hasRole(uint64,address)(bool,uint32)' 0 "$DEPLOYER_ADDR" --rpc-url "$RPC" 2>&1 | scrub | tr '\n' ' ')   (want: false 0)"
  else
    info "deployer address unknown (set LAUNCH_DEPLOYER=<address> to check it shed ADMIN)"
  fi
  info "hasRole(ADMIN, admin safe $REG_ADMIN_SAFE): $(cast call "$AM" 'hasRole(uint64,address)(bool,uint32)' 0 "$REG_ADMIN_SAFE" --rpc-url "$RPC" 2>&1 | scrub | tr '\n' ' ')   (want: true $ADMIN_DELAY)"

  say "C3. the launch set is registered (Clearinghouse.market(asset) per launch ticker, assets read from the registry)"
  CH=$(jq -r '.v2.contracts.clearinghouse // empty' "$REGISTRY")
  [ -n "$CH" ] || die "v2.contracts.clearinghouse is null in the registry"
  for T in $(printf '%s' "$REG_LAUNCH_SET" | tr ',' ' '); do
    ASSET=$(jq -r --arg t "$T" '.markets[] | select(.ticker==$t) | .asset' "$REGISTRY")
    HV=$(jq -r --arg t "$T" '.markets[] | select(.ticker==$t) | .v2.houseVault' "$REGISTRY")
    info "$T asset $ASSET  houseVault(registry) $HV"
    info "  market(asset): $(cast call "$CH" 'market(address)' "$ASSET" --rpc-url "$RPC" 2>&1 | scrub | tr '\n' ' ' | cut -c1-140)"
  done

  say "C4. the registry after the run"
  info "deployBlock=$(jq -r '.v2.deployBlock' "$REGISTRY")  contracts.houseVault=$(jq -r '.v2.contracts.houseVault' "$REGISTRY")  externalDeployBlocks=$(jq -c '.v2.externalDeployBlocks' "$REGISTRY")"
  info "uncommitted registry changes in $CALLHOUSE: $(git -C "$CALLHOUSE" status --porcelain -- ops/markets | wc -l | tr -d ' ') file(s) (the externals stage writes back inside verify; commit them: git -C $CALLHOUSE add ops/markets && git -C $CALLHOUSE commit -m 'v8: launch set registered')"
  info "later listings / config: node script/v2/day-zero-batch.mjs --registry $REGISTRY --abis $CALLHOUSE/ops/abis/v2 --verify-receipt $RUN_DIR/verify-passed.json --rpc <rpc> --out $RUN_DIR/day-zero  (Safe path; the receipt is required)"
  say "check DONE  (read-only; nothing sent)"
  ;;
esac
