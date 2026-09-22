#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# registry-env.sh — THE registry -> V2_* environment projection (T-OP-113).
#
# ONE LIB, TWO CALLERS. Everything DeployV8.s.sol, RegisterMarkets.s.sol and VerifyV8.s.sol read from
# the environment (script/v2/lib/V2DeployBase.sol lists the names) is derived from the registry
# (`ops/markets/tier1.json`) and the F2-02 recon (`v2-sources.json`) HERE and nowhere else.
# script/v2/DeployV2Batch.sh sources this file and calls its stages in the order its own run needs;
# script/v2/broadcast-v8.sh (OWN8-03, the launch driver) sources it and calls `registry_env_load`
# before each forge step. Before this file existed the wrapper held the projection inline and the
# driver exported ONLY V2_EXPECT_CHAIN_ID (T-OP-095 drift item 1, T-192 suspicion 5): every
# `vm.envAddress` in DeployV8 died on the driver's first forge step, and the wrapper could not be the
# driver because it registers before VerifyV8. A second copy of the export table in the driver was
# the wrong fix -- two tables drift, and drift here is a deploy with the wrong principal.
#
# THE CODE IN EVERY STAGE IS THE WRAPPER'S OWN, MOVED VERBATIM (DeployV2Batch.sh at aa84d88b,
# :130-139, :186-188, :308-411, :413-427, :445-471, :502-530, :533-600, :687-750, :752-812). The proof
# that the move changed nothing is an `env | grep ^V2_ | sort` diff of the wrapper before and after on
# the fixture, quoted in the T-OP-113 ledger entry. Read the wrapper's comments for the WHY of each
# value; they travelled with the code.
#
# WHAT A CALLER MUST DEFINE BEFORE SOURCING: `die` (exit non-zero with a message). Everything else the
# stages read is a plain shell variable the caller sets from its own flags, listed per stage below.
# NOTHING HERE PRINTS except through `die`: the plan is the caller's to print, from the variables the
# read stages leave behind.
#
# STAGES, in the order the wrapper runs them (each sets globals, none takes arguments):
#   registry_env_read_shared      STATE SOURCES               -> USDG GUARDIAN FEE_RECIPIENT ROUTER FACTORY VERIFIER
#                                                                V4_POOL_MANAGER V4_STATE_VIEW WETH USDG_WETH_V3_POOL
#                                                                TOKEN_POOL_* HOLIDAYS PREMIUM_FEE.. MINT_FEE_PPM WHY_RENT
#   registry_env_read_contracts   STATE CONTRACT_KEYS         -> contract_of RECORDED DEPLOY_BLOCK
#   registry_env_read_bots        STATE MODE                  -> CRANKER PRICER MM_QUOTER STANDIN_BOTS BOT_NOTE
#   registry_env_launch_guard     STATE TICKERS DEPLOY_ONLY ALLOW_OFF_LAUNCH -> TICKERS (upper, space-separated) LAUNCH_SET OFF_LAUNCH
#   market_row <T>                STATE SOURCES REGISTER_ONLY LIST_PASS ALLOW_RENT -> one validated row on stdout
#   registry_env_export_shared    MODE CHAIN_EXPECT ADMIN_ADDR GUARDIAN DEPLOYER_ADDR REG_TREASURY NO_SCHEDULE
#                                 + everything the read stages set  -> scrubs stale V2_* and exports the shared set
#   export_contracts              STATE CONTRACT_KEYS         -> V2_<CONTRACT> for every recorded slot (unset when absent)
#   export_market <T> "<row>"     STATE                       -> V2_MARKET_<T>_*
#   registry_env_market <T>       = market_row + export_market
#   registry_env_fee_recipient_from_splitter                  -> V2_FEE_RECIPIENT from v2.flywheel.feeSplitter when
#                                                                shared.feeRecipient is null (T-OP-081 #3a, see below)
#   registry_env_load <registry> <sources>                    -> the whole shared projection in one call, for a caller
#                                                                with no phase logic of its own (the driver)
#   registry_env_externals                                    -> deploy the supplied externals, record, MapExternals (T-OP-116/153)
#   registry_env_direct_register_ok <deployer>                -> DIRECT_REGISTER=1 while the deployer holds LISTING+CONFIG_ADMIN at 0 (T-OP-161)
#   registry_env_refuse_admin_pk                              -> dies when ADMIN_PK is in the environment (T-OP-161)
#   registry_env_refuse_deployer_is_principal <deployer>     -> dies when the deployer is a registry principal (T-OP-161 (f))
#   registry_env_handback                                     -> HandBack.s.sol + hasRole(ADMIN, deployer)==false read-back, AFTER RegisterMarkets (T-OP-161)
# -------------------------------------------------------------------------------------------------

# ---------------------------------------------------------------- constants
# V2Constants.MIN_POOL_OBSERVATION_CARDINALITY (SETTLEMENT_WINDOW + SNAPSHOT_GRACE + 1). Owner sign-off c10: a pool
# whose observation ring is shorter can be flooded past an expiry's window before the snapshot grace ends, so the
# market is registered CHAINLINK-ONLY instead. Every launch pool but NVDA's and SPCX's is below it.
MIN_POOL_CARDINALITY=2401
# anvil's public dev accounts ("test test ... junk"): rehearsal stand-ins for null registry bots.
ANVIL8=0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f
ANVIL9=0xa0Ee7A142d267C1f36714E4a8F75612F20a79720
ANVIL10=0xBcd4042DE499D14e55001CcbB24a551F3b954096
# Sixteen contracts IN DEPLOY ORDER (V2DeployBase.Contracts). flywheel.* live at v2.flywheel, not v2.contracts.
CONTRACT_KEYS="accessManager flywheel.feeSplitter expiryCalendar sources.chainlink sources.univ3 sources.dataStreams settlementOracle keeperRewards clearinghouse orderBook autoRoller payoutAdapter makerRegistry makerVault rewardsDistributor flywheel.buybackExecutor"

# T-OP-116 / T-OP-141 / T-OP-173: V2_HOUSE_LIMITS_FILE (the per-ticker House limits file DeployHouseVault reads with a
# no-default vm.envString; the lib defaults it to script/v2/fixtures/house-limits.v8.json, the owner-approved launch
# limits, and an operator export survives the scrub) and the six V2_HOUSE_LIMITS_* tunables. There is NO dev-defaults
# switch any more: the landed script reads the file and nothing else, so an export of V2_HOUSE_LIMITS_DEV_DEFAULTS did
# nothing while the missing file killed pass A after DeployV8 had spent its sixteen CREATEs (T-OP-165 dry run, F3).
KEEP_OVERRIDES="V2_PAYOUT_SLIPPAGE_BPS V2_BOUNTY_SNAPSHOT V2_BOUNTY_FINALIZE V2_BOUNTY_SETTLE V2_BOUNTY_REDEEM V2_BOUNTY_ROLL V2_BOUNTY_CANCEL_STALE V2_KEEPER_DAILY_CAP V2_VAULT_MAX_SERIES_UNITS V2_VAULT_MAX_TOTAL_NOTIONAL V2_VAULT_ASK_TOLERANCE_BPS V2_VAULT_MAX_BID_BPS_OF_SPOT V2_VAULT_MAX_ORDER_LIFETIME_S V2_VAULT_MAX_DAILY_OUTFLOW V2_BASE_URI V2_MAX_FEED_AGE_S V2_HOUSE_LIMITS_FILE V2_HOUSE_LIMITS_MAX_SERIES_UNITS V2_HOUSE_LIMITS_MAX_TOTAL_NOTIONAL V2_HOUSE_LIMITS_ASK_TOLERANCE_BPS V2_HOUSE_LIMITS_MAX_BID_BPS_OF_SPOT V2_HOUSE_LIMITS_MAX_ORDER_LIFETIME_S V2_HOUSE_LIMITS_MAX_DAILY_OUTFLOW"

# ---------------------------------------------------------------- helpers
# The lib's own directory, so a default path is absolute wherever the caller's cwd is (T-OP-173).
REGISTRY_ENV_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
is_addr() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
checksum() { cast to-check-sum-address "$1"; }
jqr() { jq -r "$1" "$STATE"; }

registry_env_read_shared() { # STATE SOURCES -> the shared values, validated
# T-OP-173 (F3). The House limits file DeployHouseVault reads (`V2_HOUSE_LIMITS_FILE`, no-default vm.envString at
# DeployHouseVault.s.sol) is resolved HERE, in the read phase, before any forge step: the operator's export wins,
# else the repository's owner-approved launch file (script/v2/fixtures/house-limits.v8.json, ruling 06:07Z), as an
# absolute path; a path that does not exist dies by name now rather than at pass A, after DeployV8 has spent its
# sixteen CREATEs. Exported by registry_env_export_shared (the name is in KEEP_OVERRIDES, so it survives the scrub).
HOUSE_LIMITS_FILE=${V2_HOUSE_LIMITS_FILE:-$REGISTRY_ENV_LIB_DIR/../fixtures/house-limits.v8.json}
case "$HOUSE_LIMITS_FILE" in /*) ;; *) HOUSE_LIMITS_FILE=$PWD/$HOUSE_LIMITS_FILE ;; esac
[ -f "$HOUSE_LIMITS_FILE" ] || die "V2_HOUSE_LIMITS_FILE names $HOUSE_LIMITS_FILE, which does not exist. DeployHouseVault reads the per-ticker House limits from it (no default in the script); the repository ships the owner-approved launch limits at script/v2/fixtures/house-limits.v8.json (T-OP-158, ruling 2026-09-22 06:07Z). Refused before any forge step, not at the externals stage"
HOUSE_LIMITS_FILE=$(cd "$(dirname "$HOUSE_LIMITS_FILE")" && pwd)/$(basename "$HOUSE_LIMITS_FILE")
USDG=$(jqr '.shared.usdg'); GUARDIAN=$(jqr '.shared.guardian'); FEE_RECIPIENT=$(jqr '.shared.feeRecipient')
ROUTER=$(jqr '.v2.uniswapV3.swapRouter02'); FACTORY=$(jqr '.v2.uniswapV3.factory')
VERIFIER=$(jq -r '.contracts.verifierProxy.address // empty' "$SOURCES")
# DeployV8.s.sol:416-417 requires V2_V4_POOL_MANAGER and V2_V4_STATE_VIEW and calls _code() on both. Neither
# was exported here, so every v8 run died in vm.envAddress AFTER a full solc compile, with a bare
# "environment variable not found" and nothing naming the registry or the recon file. They are read from
# v2-sources.json rather than written as literals for the same reason verifierProxy is: contracts.* is the
# external-dependency block, each entry carrying codeExists, and a literal in this script goes stale in
# silence the day the chain redeploys. The v2 registry block cannot hold them -- build-markets.mjs
# exact-key checks it and rejects an added uniswapV4 key.
V4_POOL_MANAGER=$(jq -r '.contracts.v4PoolManager.address // empty' "$SOURCES")
V4_STATE_VIEW=$(jq -r '.contracts.v4StateView.address // empty' "$SOURCES")
for pair in "shared.usdg:$USDG" "shared.guardian:$GUARDIAN" "v2.uniswapV3.swapRouter02:$ROUTER" "v2.uniswapV3.factory:$FACTORY" "v2-sources contracts.verifierProxy.address:$VERIFIER" "v2-sources contracts.v4PoolManager.address:$V4_POOL_MANAGER" "v2-sources contracts.v4StateView.address:$V4_STATE_VIEW"; do
  is_addr "${pair#*:}" || die "${pair%%:*} '${pair#*:}' is not an address"
done

# ---------------------------------------------------------------- the buyback leg and the pool key
# T-LP-12. DeployV8 reads these six with a no-default vm.env* (script/v2/lib/V2DeployBase.sol:448-455)
# and this wrapper exported none of them, so a v8 run died inside vm.envAddress AFTER a full solc
# compile, with a bare "environment variable not found" naming no file -- the same defect as the v4
# pair above, six more times. They are READ from the fixtures rather than written as literals here for
# the same reason verifierProxy is: a literal goes stale in silence the day the chain redeploys.
#
# WHERE EACH ONE LIVES, and the rule that decides it:
#   WETH and the v3 USDG/WETH pool are EXTERNAL chain dependencies with code, exactly like the router,
#   the quoter and the v4 pair, so they belong in v2-sources.json .contracts.* -- the recon block,
#   generated by ops/recon/r13-probe.mjs, each entry carrying codeExists.
#   The STONKHOUSE v4 pool key is DEPLOYMENT CONFIGURATION of the token launch, not a contract (two of
#   its five fields are not addresses), so it belongs in the registry -- at `shared.token.poolKey`,
#   which is the only home the schema defines (build-markets.mjs SHARED_TOKEN_KEYS :144, POOL_KEY_KEYS
#   :145). T-OP-005: this comment used to name `v2.flywheel.tokenPool`, and DEPLOY-V2.md:509 still
#   does. That text is a TRAP rather than merely stale -- a reader who follows it writes the values
#   into a path `build-markets.mjs --check` REFUSES, and then has to undo it. The doc is outside this
#   row's fence and is reported, not edited.
# BOTH FIXTURES CARRY weth AND usdgWethV3Pool SINCE T-OP-038 (script/v2/fixtures/v2-sources.json,
# copied from the callhouse recon at a named SHA); the refusals below are now the guard for a fixture
# that lost a key, not the expected outcome. They refuse by name -- the variable, the file and the path,
# in a second and without a compile -- which is still the point. The values' derivations and code
# hashes remain in docs/V2-FLYWHEEL-ROUTE-SPIKE.md:50,53,65. (T-OP-074 corrected this comment.)
WETH=$(jq -r '.contracts.weth.address // empty' "$SOURCES")
USDG_WETH_V3_POOL=$(jq -r '.contracts.usdgWethV3Pool.address // empty' "$SOURCES")
# T-OP-005. The v4 pool key lives at `shared.token.poolKey`, which is the ONLY home the registry
# schema defines for it -- ops/markets/build-markets.mjs SHARED_TOKEN_KEYS (:144) and POOL_KEY_KEYS
# (:145), enforced by exactKeys. This read used `.v2.flywheel.tokenPool.*`, a path the schema forbids,
# so `--check` correctly refused any registry that carried it (T-OP-002, callhouse 13cfdb95). Adding
# tokenPool to the skeleton would have created a SECOND home and, because exactKeys is symmetric, made
# it required on every registry. The registry was right and the wrapper was wrong.
TOKEN_POOL_CURRENCY0=$(jqr '.shared.token.poolKey.currency0 // empty')
TOKEN_POOL_CURRENCY1=$(jqr '.shared.token.poolKey.currency1 // empty')
TOKEN_POOL_HOOKS=$(jqr '.shared.token.poolKey.hooks // empty')
TOKEN_POOL_FEE=$(jqr '.shared.token.poolKey.fee // empty')
TOKEN_POOL_TICK_SPACING=$(jqr '.shared.token.poolKey.tickSpacing // empty')
for pair in "V2_WETH:v2-sources contracts.weth.address:$WETH" \
            "V2_BUYBACK_V3_POOL:v2-sources contracts.usdgWethV3Pool.address:$USDG_WETH_V3_POOL" \
            "V2_TOKEN_POOL_CURRENCY1:registry shared.token.poolKey.currency1:$TOKEN_POOL_CURRENCY1" \
            "V2_TOKEN_POOL_HOOKS:registry shared.token.poolKey.hooks:$TOKEN_POOL_HOOKS"; do
  v=${pair##*:}; rest=${pair%:*}; name=${rest%%:*}; path=${rest#*:}
  [ -n "$v" ] || die "$name has no value: $path is absent or null. DeployV8 reads it with a no-default vm.envAddress (script/v2/lib/V2DeployBase.sol:448-455); the address is recorded in docs/V2-FLYWHEEL-ROUTE-SPIKE.md and the fixture has not been taught it"
  is_addr "$v" || die "$name '$v' is not an address ($path)"
done
# fee is a uint24 and 0 IS a legal value for this pool (the STONKHOUSE pool's LP fee is static 0,
# docs/V2-FLYWHEEL-ROUTE-SPIKE.md:65,93), so absence must be distinguished from zero -- `// empty`
# does that, because jq's alternative operator only replaces null and false.
[ -n "$TOKEN_POOL_FEE" ] || die "V2_TOKEN_POOL_FEE has no value: registry shared.token.poolKey.fee is absent or null. 0 is a legal fee for this pool, so it must be written down rather than defaulted"
is_uint "$TOKEN_POOL_FEE" || die "V2_TOKEN_POOL_FEE '$TOKEN_POOL_FEE' is not an unsigned integer (registry shared.token.poolKey.fee)"
# AC9 / T-OP-005. currency0 is NOT exported: DeployV8 reads it with vm.envOr(..., address(0))
# (script/v2/lib/V2DeployBase.sol:451) and the v4 leg spends NATIVE ETH, so the zero address is the
# intended value and the default already is it. Absent, null or zero is therefore legal and silent.
# A PRESENT, NON-ZERO currency0 is refused HERE rather than left to DeployV8.s.sol:489, because the
# whole purpose of this wrapper is to refuse before solc runs (:330-331) -- catching it downstream
# costs a full compile to learn the same fact.
if [ -n "$TOKEN_POOL_CURRENCY0" ] && [ "$TOKEN_POOL_CURRENCY0" != "0x0000000000000000000000000000000000000000" ]; then
  die "V2_TOKEN_POOL_CURRENCY0 '$TOKEN_POOL_CURRENCY0' is not the zero address (registry shared.token.poolKey.currency0). The STONKHOUSE v4 leg spends native ETH, so currency0 must be the zero address or absent; DeployV8 defaults it with vm.envOr (script/v2/lib/V2DeployBase.sol:451)"
fi
# tickSpacing is an int24 in the PoolKey type, but a v4 pool cannot exist with one below 1: PoolManager.initialize
# refuses `tickSpacing < MIN_TICK_SPACING (1)` (TickSpacingTooSmall), so a zero or negative value here names a pool
# that cannot be, and only V4BuybackExecutor's constructor would have caught it -- AFTER the core deploy
# (T-OP-142 finding 4, refused here by name instead; T-OP-116). The earlier text said "CAN be negative": the
# type can, the pool cannot.
[ -n "$TOKEN_POOL_TICK_SPACING" ] || die "V2_TOKEN_POOL_TICK_SPACING has no value: registry shared.token.poolKey.tickSpacing is absent or null"
[[ "$TOKEN_POOL_TICK_SPACING" =~ ^-?[0-9]+$ ]] || die "V2_TOKEN_POOL_TICK_SPACING '$TOKEN_POOL_TICK_SPACING' is not an integer (registry shared.token.poolKey.tickSpacing)"
[ "$TOKEN_POOL_TICK_SPACING" -ge 1 ] || die "V2_TOKEN_POOL_TICK_SPACING $TOKEN_POOL_TICK_SPACING is below 1 (registry shared.token.poolKey.tickSpacing): Uniswap v4 PoolManager.initialize refuses tickSpacing < 1 (TickSpacingTooSmall), so no such pool can exist; only V4BuybackExecutor's constructor would have refused it, after the core deploy"
# shared.feeRecipient IS the FeeSplitter (DeployV8.s.sol:503). A registry describing a set that has
# not been deployed yet cannot know it, so null is legal there and means "whatever this run creates";
# a non-null value must still be an address, and DeployV8 refuses it if it is not the splitter.
case "$FEE_RECIPIENT" in
  null|"") FEE_RECIPIENT="" ;;
  *) is_addr "$FEE_RECIPIENT" || die "shared.feeRecipient '$FEE_RECIPIENT' is not an address" ;;
esac
HOLIDAYS=$(jq -r '[.nyseHolidays[].fullDays[].dayIndex] | sort | map(tostring) | join(",")' "$SOURCES")
[ -n "$HOLIDAYS" ] || die "no nyseHolidays fullDays in $SOURCES"
FEES=$(jq -r '.v2.fees | [.premiumFeeBps, .resaleFeeBps, .takerFeeFlat, .takerFeeCapBps, .makerRebateBps, .exerciseFeeBps] | map(tostring) | join(" ")' "$STATE")
read -r PREMIUM_FEE RESALE_FEE TAKER_FLAT TAKER_CAP MAKER_REBATE EXERCISE_FEE <<<"$FEES"
for v in "$PREMIUM_FEE" "$RESALE_FEE" "$TAKER_FLAT" "$TAKER_CAP" "$MAKER_REBATE" "$EXERCISE_FEE"; do is_uint "$v" || die "registry v2.fees has a non-integer value ($FEES)"; done
# INTERFACE_VERSION 8 (V8-DESIGN.md §4): v8 launches premium 500 / resale 0. The v7
# `premiumFeeBps <= resaleFeeBps` refusal is deleted deliberately — the dodge is a knowingly
# accepted owner risk. DeployV8 / V2DeployBase already dropped the same check.
# The shared rent rate; a market's own v2.mintFeePpm overrides it. RegisterMarkets reads V2_MINT_FEE_PPM as the
# fallback for every ticker without a V2_MARKET_<T>_MINT_FEE_PPM. ABSENT IS NOT 0 (DECISIONS-2026-09-17 §11): an
# absent block leaves every market without its own rate with no rate at all, which market_row refuses by name.
MINT_FEE_PPM=$(jq -r '.v2.fees.mintFeePpm // empty | tostring' "$STATE")
if [ -n "$MINT_FEE_PPM" ]; then
  is_uint "$MINT_FEE_PPM" || die "registry v2.fees.mintFeePpm '$MINT_FEE_PPM' is not an integer"
  [ "$MINT_FEE_PPM" -le 5000 ] || die "registry v2.fees.mintFeePpm $MINT_FEE_PPM is above MINT_FEE_CEIL_PPM (5000)"
fi
# The tail of both rent refusals, so market_row says it once.
WHY_RENT="INTERFACE_VERSION 8 launches collateral rent at 0 and takes premiumFeeBps 500 on first sale (V8-DESIGN.md §4.3). A NON-ZERO mintFeePpm must never reach the chain from this wrapper. Set the rate to 0, or pass --allow-rent for a local fixture or a devnet (never with --broadcast, --dry-run only)"
}

# ---------------------------------------------------------------- contracts recorded
contract_of() {
  case "$1" in
    flywheel.feeSplitter) jqr '.v2.flywheel.feeSplitter // empty' ;;
    flywheel.buybackExecutor) jqr '.v2.flywheel.buybackExecutor // empty' ;;
    *) jqr ".v2.contracts.$1 // empty" ;;
  esac
}
registry_env_read_contracts() { # STATE CONTRACT_KEYS -> contract_of, RECORDED, DEPLOY_BLOCK
RECORDED=0
for k in $CONTRACT_KEYS; do
  a=$(contract_of "$k")
  if [ -n "$a" ]; then is_addr "$a" || die "registry v2.contracts.$k '$a' is not an address"; RECORDED=$((RECORDED + 1)); fi
done
DEPLOY_BLOCK=$(jqr '.v2.deployBlock // empty')
[ -z "$DEPLOY_BLOCK" ] || is_uint "$DEPLOY_BLOCK" || die "registry v2.deployBlock '$DEPLOY_BLOCK' is not a block number"
}

# ---------------------------------------------------------------- bots
bot() { # name anvil-stand-in
  local v; v=$(jqr ".v2.bots.$1 // empty")
  if [ -n "$v" ]; then is_addr "$v" || die "registry v2.bots.$1 '$v' is not an address"; echo "$v"; return; fi
  [ "$MODE" = rehearse ] || die "registry v2.bots.$1 is null or absent: run ops/v2/derive-bot-keys.sh (owner) before --$MODE"
  echo "$2"
}
registry_env_read_bots() { # STATE MODE -> CRANKER PRICER MM_QUOTER, STANDIN_BOTS, BOT_NOTE
BOT_NOTE=""
# THE NAME MUST BE THE REGISTRY'S NAME, and `// empty` cannot tell a wrong name from a null value.
# INTERFACE_VERSION 8 renamed this key: ops/v2/derive-bot-keys.sh writes `v2.bots.quoter` (index 62) and
# ops/markets/build-markets.mjs V2_BOT_NAMES knows only {cranker,pricer,quoter,guardian}. The v7 name
# `mmQuoter` is not a key at all, so `.v2.bots.mmQuoter // empty` was ALWAYS empty and a rehearsal
# silently used the anvil stand-in while the owner's derived quoter sat in the registry unread. The env
# var keeps its v7 spelling on purpose -- V2DeployBase.sol:238 is `V2_MM_QUOTER  v2.bots.quoter` -- so
# only the REGISTRY KEY moves here.
CRANKER=$(bot cranker "$ANVIL8"); PRICER=$(bot pricer "$ANVIL9"); MM_QUOTER=$(bot quoter "$ANVIL10")
# THE NOTE IS DERIVED FROM WHAT WAS ACTUALLY USED, not from which registry values are null, and that
# distinction is the defect. The old form listed keys whose VALUE was null; an ABSENT key is not null,
# so a misspelled lookup never appeared here. Worse, it went quiet exactly when things were right: once
# the owner ran derive-bot-keys all four values were set, STANDIN_BOTS became empty, the note vanished,
# and `bot mmQuoter` still returned anvil #10. Comparing the resolved address against the stand-in it
# would have come from cannot drift from the lookup, because it IS the lookup's result.
STANDIN_BOTS=""
if [ "$CRANKER" = "$ANVIL8" ]; then STANDIN_BOTS="cranker"; fi
if [ "$PRICER" = "$ANVIL9" ]; then STANDIN_BOTS="${STANDIN_BOTS:+$STANDIN_BOTS,}pricer"; fi
if [ "$MM_QUOTER" = "$ANVIL10" ]; then STANDIN_BOTS="${STANDIN_BOTS:+$STANDIN_BOTS,}quoter"; fi
[ -z "$STANDIN_BOTS" ] || BOT_NOTE="rehearsal stand-ins (anvil #8/#9/#10) used for v2.bots: $STANDIN_BOTS"
}

# ---------------------------------------------------------------- the launch-set guard
registry_env_launch_guard() { # STATE TICKERS DEPLOY_ONLY ALLOW_OFF_LAUNCH -> TICKERS LAUNCH_SET OFF_LAUNCH
  TICKERS=$(echo "$TICKERS" | tr ',' ' ' | tr '[:lower:]' '[:upper:]')

  # THE LAUNCH-SET GUARD (T-OP-104). The registry's root `launchSet.markets` is the owner's launch set (ruling
  # 2026-09-21: NVDA and SPCX) and, per its own note, is deliberately NOT derived from `wave` or `status`.
  # Until this guard, nothing in the deploy path read it: `--wave wave1` would have registered every wave1
  # market, seventeen of them single-source, and the ruling was enforced by nobody typing the wrong flag.
  # FAIL CLOSED on a registry with no block at all -- a guard that cannot see its subject must refuse, not
  # pass -- and refuse every selection outside the set, naming each offender, unless the operator typed
  # --allow-off-launch, which the plan records. The check runs on the FINAL ticker list, so it covers
  # --tickers, --wave, --resync and --register-only alike; --deploy-only registers nothing and --verify
  # selects nothing, so neither reaches it.
  LAUNCH_SET=$(jq -r 'if (.launchSet.markets | type) == "array" then [.launchSet.markets[] | ascii_upcase] | sort | join(",") else "" end' "$STATE")
  [ -n "$LAUNCH_SET" ] || die "registry has no launchSet.markets block: the launch-set guard cannot hold this run to the owner's launch set (NVDA, SPCX). Add the block as ops/markets/tier1.json carries it (build-markets.mjs validates and preserves it); do not derive it from wave or status"
  OFF_LAUNCH=""
  if [ "$DEPLOY_ONLY" = 0 ]; then
    # A ticker the registry does not carry at all is NOT an off-launch market: it keeps market_row's own
    # refusal ("ZZZZ is not in the registry", the batch-refusals `unknown ticker` case), which is the message a
    # typo deserves. MEASURED: the first scratch run of the suite reddened that case when this guard named ZZZZ.
    KNOWN=$(jq -r '[.markets[].ticker | ascii_upcase] | join(",")' "$STATE")
    for T in $TICKERS; do
      case ",$KNOWN," in *",$T,"*) ;; *) continue ;; esac
      case ",$LAUNCH_SET," in *",$T,"*) ;; *) OFF_LAUNCH="${OFF_LAUNCH:+$OFF_LAUNCH,}$T" ;; esac
    done
    OFF_LAUNCH=$(echo "$OFF_LAUNCH" | tr ',' '\n' | sort | paste -sd, -)
    if [ -n "$OFF_LAUNCH" ] && [ "$ALLOW_OFF_LAUNCH" = 0 ]; then
      n=$(echo "$OFF_LAUNCH" | tr ',' '\n' | grep -c .)
      die "launch set [$LAUNCH_SET] (registry launchSet.markets, owner ruling 2026-09-21) excludes $n selected market(s): $OFF_LAUNCH. Only the launch set is registered at launch; for a post-launch wave pass --allow-off-launch, which this wrapper logs"
    fi
  fi
}

# market_row T -> "asset feed pool floor fee tick dev delay age mintFeePpm enabled registeredAt" (validated)
market_row() {
  local T=$1 row asset feed pool floor fee tick dev delay age reg ppm card status enabled
  [[ "$T" =~ ^[A-Z0-9]+$ ]] || die "ticker '$T' is not A-Z0-9"
  row=$(jq -c --arg t "$T" '.markets[] | select(.ticker == $t)' "$STATE")
  [ -n "$row" ] || die "$T is not in the registry"
  [ "$(jq -r '.verification.ok' <<<"$row")" = true ] || die "$T: verification.ok is not true (issues: $(jq -c '.verification.issues' <<<"$row")); rebuild the registry first"
  jq -e '.v2 | type == "object"' <<<"$row" >/dev/null || die "$T: no v2 block"
  asset=$(jq -r '.asset' <<<"$row"); feed=$(jq -r '.feed' <<<"$row")
  pool=$(jq -r '.v2.univ3Pool // ""' <<<"$row"); floor=$(jq -r '.v2.univ3MinLiquidity // "0"' <<<"$row")
  tick=$(jq -r '.v2.strikeTick // ""' <<<"$row")
  # v2.defaults merged with the market's v2.overrides (registry README "v2 blocks")
  dev=$(jq -r --argjson d "$(jq -c '.v2.defaults' "$STATE")" '(.v2.overrides.maxDeviationBps // $d.maxDeviationBps) | tostring' <<<"$row")
  delay=$(jq -r --argjson d "$(jq -c '.v2.defaults' "$STATE")" '(.v2.overrides.uncorroboratedDelayS // $d.uncorroboratedDelayS) | tostring' <<<"$row")
  age=$(jq -r --argjson d "$(jq -c '.v2.defaults' "$STATE")" '(.v2.overrides.spotMaxAgeS // $d.spotMaxAgeS) | tostring' <<<"$row")
  reg=$(jq -r '.v2.registeredAt // ""' <<<"$row")
  # INTERFACE_VERSION 7 (c05): the collateral-rent rate, market override over the shared v2.fees.mintFeePpm. There is
  # no fallback to 0 (DECISIONS §11): absent stays empty here and is refused below.
  ppm=$(jq -r --argjson f "$(jq -c '.v2.fees' "$STATE")" '(.v2.mintFeePpm // .v2.overrides.mintFeePpm // $f.mintFeePpm // empty) | tostring' <<<"$row")
  status=$(jq -r '.v2.status // empty' <<<"$row")
  case "$status" in
    live) enabled=true ;;
    planned|paused) enabled=false ;;
    *) die "$T: v2.status '$status' is not planned|live|paused (C3-102: enabled = (v2.status == live))" ;;
  esac
  # --register-only always registers DISABLED; the later listing pass derives enabled from v2.status
  # like every other run. It does NOT override it: the listing pass marks the markets it lists
  # v2.status=live in the write-back first, so phase 3 (which re-derives expectations from v2.status)
  # and the chain agree. An override here made VerifyV8 compare planned-means-disabled against an
  # on-chain enabled=true, and it also silently re-enabled a "paused" market.
  if [ "$REGISTER_ONLY" = 1 ] && [ "$LIST_PASS" = 0 ]; then enabled=false; fi
  is_addr "$asset" || die "$T: asset '$asset' is not an address"
  is_addr "$feed" || die "$T: feed '$feed' is not an address"
  [ -n "$tick" ] && [ "$tick" != 0 ] || die "$T: v2.strikeTick is not set"
  [ -n "$ppm" ] || ppm_for_ceil=0
  [ -n "$ppm" ] && ppm_for_ceil=$ppm
  for v in "$floor" "$tick" "$dev" "$delay" "$age" "$ppm_for_ceil"; do is_uint "$v" || die "$T: non-integer registry value '$v'"; done
  # V2Constants.MINT_FEE_CEIL_PPM; RegisterMarkets' preflight refuses the same, before anything is broadcast.
  [ "$ppm_for_ceil" -le 5000 ] || die "$T: v2.mintFeePpm $ppm_for_ceil is above MINT_FEE_CEIL_PPM (5000): the Clearinghouse's _checkConfig reverts CeilingExceeded"
  # INTERFACE_VERSION 8 inverted the rent refusals (V8-DESIGN.md §4.3). Absent still has no rate.
  # A non-zero effective mintFeePpm is refused unless --allow-rent.
  if [ "$ALLOW_RENT" = 0 ]; then
    [ -n "$ppm" ] || die "$T: no collateral rent rate: neither markets[].v2.mintFeePpm nor v2.fees.mintFeePpm is set. $WHY_RENT"
    [ "$ppm" = 0 ] || die "$T: v2.mintFeePpm is $ppm (non-zero). $WHY_RENT"
  fi
  [ -n "$ppm" ] || ppm=0
  fee=0
  if [ -n "$pool" ]; then
    is_addr "$pool" || die "$T: v2.univ3Pool '$pool' is not an address"
    [ "$floor" != 0 ] || die "$T: v2.univ3Pool without v2.univ3MinLiquidity"
    fee=$(jq -r --arg t "$T" --arg p "$(echo "$pool" | tr 'A-F' 'a-f')" \
      '[.markets[] | select(.ticker == $t) | .pools[]? | select((.address | ascii_downcase) == $p) | .fee][0] // empty' "$SOURCES")
    is_uint "$fee" || die "$T: v2.univ3Pool $pool is not a pool of $T in $SOURCES (re-run the recon)"
    # The pool is also the market's payout route. The Clearinghouse counts at most MAX_ROUTE_FEE_BPS (100 bps) of a
    # route's fee, so a costlier tier would pay every conversion in kind; UniV3PayoutAdapter.setRoute refuses it.
    [ "$fee" -le 10000 ] || die "$T: v2.univ3Pool $pool has fee tier $fee in $SOURCES, above 10000 (1 %): the Clearinghouse counts at most MAX_ROUTE_FEE_BPS (100 bps) of a payout route's fee, so every conversion through it would pay in kind, and UniV3PayoutAdapter.setRoute refuses it (CeilingExceeded); choose a pool of 10000 or less, or none"
    # Owner sign-off c10 (DECISIONS-2026-09-17 §7). The recon already measured the ring, so this refuses before any
    # RPC call; RegisterMarkets' preflight re-reads slot0() on chain and UniV3TwapSource.setPool refuses it too.
    card=$(jq -r --arg t "$T" --arg p "$(echo "$pool" | tr 'A-F' 'a-f')" \
      '[.markets[] | select(.ticker == $t) | .pools[]? | select((.address | ascii_downcase) == $p) | .cardinality][0] // empty' "$SOURCES")
    is_uint "$card" || die "$T: v2.univ3Pool $pool has no observation cardinality in $SOURCES (re-run the recon)"
    [ "$card" -ge "$MIN_POOL_CARDINALITY" ] || die "$T: v2.univ3Pool $pool has observationCardinality $card in $SOURCES, below MIN_POOL_OBSERVATION_CARDINALITY ($MIN_POOL_CARDINALITY = SETTLEMENT_WINDOW + SNAPSHOT_GRACE + 1): one dust mint or burn per second could overwrite the expiry's window before the snapshot grace ends, and UniV3TwapSource.setPool refuses the pool (UnsupportedAsset). Register $T CHAINLINK-ONLY (drop v2.univ3Pool and v2.univ3MinLiquidity from the registry row, which also drops its payout route), or call increaseObservationCardinalityNext($MIN_POOL_CARDINALITY) on the pool, wait until slot0().observationCardinality reaches it and re-run the recon"
  else
    pool=0x0000000000000000000000000000000000000000
    [ "$floor" = 0 ] || die "$T: v2.univ3MinLiquidity without v2.univ3Pool"
  fi
  echo "$asset $feed $pool $floor $fee $tick $dev $delay $age $ppm $enabled ${reg:--}"
}

# ---------------------------------------------------------------- environment for forge
# Drop every stale V2_* export (an env file of a v2 service sets several) except the tunable overrides the plan
# printed, then export exactly what this run means.
# T-182 / F-DCON-06. CAPTURED HERE, BEFORE THE SCRUB BELOW EATS IT. The rc=90 deferral tells the operator to
# "re-run this exact command with V2_SCHEDULE_PHASE=execute", and until now that instruction could not be
# followed by anyone: `V2_SCHEDULE_PHASE` is a `V2_*` name, so the unset loop below dropped it, and
# {run_forge_scheduled} then exported `schedule` over it regardless. Reading it into a non-`V2_` variable is
# what makes the printed recovery a real command.
#
# ONLY `execute` IS ACCEPTED. The schedule leg is the script's decision, not the operator's -- an operator who
# could ask for `schedule` could skip the execute leg on a rehearsal and get a green run that sent nothing.
RESUME_PHASE=${V2_SCHEDULE_PHASE:-}
case "$RESUME_PHASE" in
  "" | execute) ;;
  *) die "V2_SCHEDULE_PHASE=$RESUME_PHASE is not a resume phase this script accepts: only 'execute', which re-runs the already-scheduled operations once every readyAt has passed. The schedule leg is chosen by the script." ;;
esac

registry_env_export_shared() { # scrub every stale V2_* except the tunable overrides, then export the shared set
for v in $(compgen -v | grep '^V2_' || true); do
  case " $KEEP_OVERRIDES " in *" $v "*) ;; *) unset "$v" ;; esac
done
unset TICKERS_ENV KEY_ENV
export V2_EXPECT_CHAIN_ID=$CHAIN_EXPECT
export V2_ADMIN=$ADMIN_ADDR V2_GUARDIAN=$GUARDIAN
# T-OP-173: the House limits file, resolved in the read phase (absolute, existing); DeployHouseVault reads it at
# createVault. An operator export of the same name is what the read phase honoured, so this is never a downgrade.
export V2_HOUSE_LIMITS_FILE=$HOUSE_LIMITS_FILE
# THE TWO v8 SAFES, EXPORTED AFTER THE SCRUB ABOVE AND NOT BEFORE IT. They were set inside the mode
# case three hundred lines earlier, which the `unset` loop above then wiped -- in --broadcast as well
# as --rehearse -- so DeployV8 died in vm.envAddress("V2_ADMIN_SAFE") on the first line of the first
# run, every time, on every chain. That is why no v8 deploy or rehearsal had ever got past step 1.
export V2_ADMIN_SAFE=$ADMIN_ADDR
# T-182 / F-SCRIPTS-11. REHEARSE ONLY, and after the scrub for the same reason V2_ADMIN_SAFE is. `--rehearse`
# impersonates the registry admin on an anvil fork with `--unlocked --sender`, so RegisterMarkets broadcasts from
# a Signer with no key. `--broadcast` unsets ADMIN_PK as well, and used to reach that same impersonating path
# against a mainnet Safe: the roles preflight passed (the Safe does hold LISTING) and forge then failed at
# signing. RegisterMarkets refuses a key-less signer unless this says the node has actually unlocked it.
if [ "$MODE" = rehearse ]; then export V2_UNLOCKED_ADMIN=true; else unset V2_UNLOCKED_ADMIN; fi
if is_addr "$REG_TREASURY"; then export V2_TREASURY_SAFE=$(checksum "$REG_TREASURY"); else unset V2_TREASURY_SAFE; fi
# `shared.feeRecipient` IS the FeeSplitter, which a fresh deploy has not created yet. Exporting the
# literal "null" makes vm.envAddress throw; exporting a stale address makes DeployV8 refuse the run
# (DeployV8.s.sol:494). Unset means "whatever this run creates", which is the only true answer.
if is_addr "$FEE_RECIPIENT"; then export V2_FEE_RECIPIENT=$(checksum "$FEE_RECIPIENT"); else unset V2_FEE_RECIPIENT; fi
export V2_CRANKER=$CRANKER V2_PRICER=$PRICER V2_MM_QUOTER=$MM_QUOTER
export V2_USDG=$USDG V2_SWAP_ROUTER02=$ROUTER V2_UNIV3_FACTORY=$FACTORY V2_DATA_STREAMS_VERIFIER=$VERIFIER
export V2_V4_POOL_MANAGER=$V4_POOL_MANAGER V2_V4_STATE_VIEW=$V4_STATE_VIEW
# T-LP-12: the buyback's v3 leg and the pinned STONKHOUSE v4 pool key. V2_TOKEN_POOL_CURRENCY0 is NOT
# exported: DeployV8 reads it with vm.envOr(..., address(0)) and the v4 leg spends native ETH, so the
# zero address is the only correct value and the default already is it (DEPLOY-V2.md:114).
export V2_WETH=$(checksum "$WETH") V2_BUYBACK_V3_POOL=$(checksum "$USDG_WETH_V3_POOL")
export V2_TOKEN_POOL_CURRENCY1=$(checksum "$TOKEN_POOL_CURRENCY1") V2_TOKEN_POOL_HOOKS=$(checksum "$TOKEN_POOL_HOOKS")
export V2_TOKEN_POOL_FEE=$TOKEN_POOL_FEE V2_TOKEN_POOL_TICK_SPACING=$TOKEN_POOL_TICK_SPACING
export V2_HOLIDAYS=$HOLIDAYS
export V2_PREMIUM_FEE_BPS=$PREMIUM_FEE V2_RESALE_FEE_BPS=$RESALE_FEE V2_TAKER_FEE_FLAT=$TAKER_FLAT
export V2_TAKER_FEE_CAP_BPS=$TAKER_CAP V2_MAKER_REBATE_BPS=$MAKER_REBATE V2_EXERCISE_FEE_BPS=$EXERCISE_FEE
# INTERFACE_VERSION 7 (c05); V2_MARKET_<T>_MINT_FEE_PPM overrides it per market. An absent shared rate is exported as
# nothing at all, never as 0: V2DeployBase refuses a market whose rate is set nowhere (DECISIONS §11).
if [ -n "$MINT_FEE_PPM" ]; then export V2_MINT_FEE_PPM=$MINT_FEE_PPM; else unset V2_MINT_FEE_PPM; fi
# The zero-rent opt-in is NEVER exported (DECISIONS-2026-09-17 §11, codex review): the forge scripts honour it under
# `forge test` alone, so exporting it would only make a stale operator variable look meaningful. Clearing it here also
# drops one an operator's shell carries in.
unset V2_ALLOW_RENT
[ -z "$DEPLOYER_ADDR" ] || export V2_DEPLOYER=$DEPLOYER_ADDR
# Registration and listing are delayed AccessManager lanes on any chain that has had the handover, so
# the schedule path is not a rehearsal-only nicety: exporting it only under --rehearse left
# `--broadcast --register-only` sending raw admin calls with nothing to refuse them.
if [ "$MODE" = verify ] || [ "$NO_SCHEDULE" = 1 ]; then unset V2_SCHEDULE; else export V2_SCHEDULE=true; fi
}

env_name() { # registry contract key -> V2_* name (V2DeployBase env)
  case "$1" in
    accessManager) echo V2_ACCESS_MANAGER ;;
    flywheel.feeSplitter) echo V2_FEE_SPLITTER ;;
    flywheel.buybackExecutor) echo V2_BUYBACK_EXECUTOR ;;
    clearinghouse) echo V2_CLEARINGHOUSE ;; orderBook) echo V2_ORDER_BOOK ;; settlementOracle) echo V2_SETTLEMENT_ORACLE ;;
    expiryCalendar) echo V2_EXPIRY_CALENDAR ;; keeperRewards) echo V2_KEEPER_REWARDS ;; autoRoller) echo V2_AUTO_ROLLER ;;
    payoutAdapter) echo V2_PAYOUT_ROUTER ;; makerVault) echo V2_MAKER_VAULT ;; makerRegistry) echo V2_MAKER_REGISTRY ;;
    rewardsDistributor) echo V2_REWARDS_DISTRIBUTOR ;; sources.chainlink) echo V2_SOURCE_CHAINLINK ;;
    sources.univ3) echo V2_SOURCE_UNIV3 ;; sources.dataStreams) echo V2_SOURCE_DATA_STREAMS ;;
    houseVault) echo V2_HOUSE_VAULT ;; houseVaultFactory) echo V2_HOUSE_VAULT_FACTORY ;;
    hedger) echo V2_HEDGER ;; rewardsDistributorLender) echo V2_LENDER_REWARDS ;;
    earnVault) echo V2_EARN_VAULT ;; stockVenueAdapter) echo V2_STOCK_VENUE_ADAPTER ;;
  esac
}

# THE SIX THIS RUN DOES NOT DEPLOY. roles.v8.json names them as targets, their own tasks deploy them, and they
# reach DeployV8 by environment. They are deliberately NOT in CONTRACT_KEYS: that list is the RECORDED set this
# run creates and counts, and adding them to it would make every "$RECORDED of $NKEYS" check demand contracts
# this run never mines.
#
# They are exported with the SAME unset-when-absent rule as the recorded set, and that rule is the entire point.
# DeployV8._mapTarget distinguishes "not supplied" (skip the target and say so) from "supplied as zero" (map
# three selectors against nothing while telling the operator the row was wired). Exporting an EMPTY value would
# collapse that distinction, and `--register-only` on a chain where one of these was forgotten would report a
# wired row over an unmapped contract whose restricted selectors answer to ADMIN by default (06-QUIRKS A.8).
EXTERNAL_KEYS="houseVault houseVaultFactory hedger rewardsDistributorLender earnVault stockVenueAdapter"
export_contracts() { # from STATE
  local k a
  for k in $CONTRACT_KEYS $EXTERNAL_KEYS; do
    a=$(contract_of "$k")
    if [ -n "$a" ]; then export "$(env_name "$k")=$a"; else unset "$(env_name "$k")"; fi
  done
}
export_market() { # ticker "row"
  local T=$1 asset feed pool floor fee tick dev delay age ppm enabled venue pfee pts hv
  read -r asset feed pool floor fee tick dev delay age ppm enabled _ <<<"$2"
  export "V2_MARKET_${T}_ASSET=$asset" "V2_MARKET_${T}_FEED=$feed" "V2_MARKET_${T}_POOL=$pool"
  export "V2_MARKET_${T}_MIN_LIQUIDITY=$floor" "V2_MARKET_${T}_POOL_FEE=$fee" "V2_MARKET_${T}_STRIKE_TICK=$tick"
  export "V2_MARKET_${T}_MAX_DEVIATION_BPS=$dev" "V2_MARKET_${T}_UNCORROBORATED_DELAY_S=$delay" "V2_MARKET_${T}_SPOT_MAX_AGE_S=$age"
  # INTERFACE_VERSION 7 (c05): RegisterMarkets reads this over the shared V2_MINT_FEE_PPM, and VerifyV8 compares it
  # with the live MarketConfig.mintFeePpm.
  export "V2_MARKET_${T}_MINT_FEE_PPM=$ppm"
  # C3-102: RegisterMarkets / VerifyV8 treat enabled as (v2.status == live).
  export "V2_MARKET_${T}_ENABLED=$enabled"
  # T-OP-161 (i) / T-OP-156 / T-OP-171: the per-ticker HouseVault (markets[].v2.houseVault), EIP-55, UNSET when the
  # key is null -- the unset-when-absent rule export_contracts applies to the externals, so VerifyV8's second-vault
  # subject tells "not supplied" from "zero". The name is V2DeployBase's _mk(ticker, "HOUSE_VAULT").
  hv=$(jq -r --arg t "$T" '.markets[] | select(.ticker == $t) | .v2.houseVault // empty' "$STATE")
  if [ -n "$hv" ]; then
    is_addr "$hv" || die "$T: markets[].v2.houseVault '$hv' is not an address"
    export "V2_MARKET_${T}_HOUSE_VAULT=$(checksum "$hv")"
  else
    unset "V2_MARKET_${T}_HOUSE_VAULT"
  fi
  venue=$(jq -r --arg t "$T" '.markets[] | select(.ticker == $t) | .v2.payoutRoute.venue // empty' "$STATE")
  if [ -z "$venue" ] || [ "$venue" = "null" ]; then
    export "V2_MARKET_${T}_PAYOUT_VENUE=none"
    unset "V2_MARKET_${T}_PAYOUT_FEE" "V2_MARKET_${T}_PAYOUT_TICK_SPACING"
  else
    pfee=$(jq -r --arg t "$T" '.markets[] | select(.ticker == $t) | .v2.payoutRoute.fee | tostring' "$STATE")
    pts=$(jq -r --arg t "$T" '.markets[] | select(.ticker == $t) | .v2.payoutRoute.tickSpacing | tostring' "$STATE")
    ppid=$(jq -r --arg t "$T" '.markets[] | select(.ticker == $t) | .v2.payoutRoute.poolId // empty' "$STATE")
    export "V2_MARKET_${T}_PAYOUT_VENUE=$venue"
    export "V2_MARKET_${T}_PAYOUT_FEE=$pfee"
    export "V2_MARKET_${T}_PAYOUT_TICK_SPACING=$pts"
    # The pinned pool. setRouteV4 rebuilds the PoolKey from fee+tickSpacing and never sees this, so
    # RegisterMarkets checks the rebuild against it (O8-03 pins one hookless pool per ticker).
    if [ -n "$ppid" ]; then export "V2_MARKET_${T}_PAYOUT_POOL_ID=$ppid"; else unset "V2_MARKET_${T}_PAYOUT_POOL_ID"; fi
  fi
}

# registry_env_market <T>: the per-market projection, validated then exported. What the wrapper does at
# each RegisterMarkets step (`row=$(market_row "$T"); export_market "$T" "$row"`), as one call.
registry_env_market() {
  local row
  row=$(market_row "$1")
  export_market "$1" "$row"
}

# T-OP-081 finding #3a. `shared.feeRecipient` IS the FeeSplitter (DeployV8.s.sol:587 sets
# `in_.roles.feeRecipient = d.feeSplitter` on a fresh deploy), so a registry describing a set that has not
# been deployed yet carries it as null, and {registry_env_export_shared} correctly leaves V2_FEE_RECIPIENT
# UNSET for the deploy step (exporting a literal "null" throws in vm.envAddress; a stale address is refused
# at DeployV8.s.sol:578). But VerifyV8 reads the SAME variable (VerifyV8.s.sol:525,554:
# `clearinghouse.feeRecipient == V2_FEE_RECIPIENT`, `orderBook.feeRecipient == V2_FEE_RECIPIENT`), and with it
# unset both checks compare the live splitter against address(0) and FAIL on a correct deploy. The
# write-back records `v2.flywheel.feeSplitter` one phase earlier, so once it is recorded the answer is known:
# export it from there. A NON-NULL shared.feeRecipient wins (it was validated as an address by
# {registry_env_read_shared}, and DeployV8 refuses it if it is not the splitter), so a registry that has
# already been written back through callhouse ops/markets/write-back-v8.mjs projects the same value by
# either path. NOTHING is exported when neither is known: an unset variable is the truthful state before
# the splitter exists, and VerifyV8 reporting the mismatch is then the right outcome.
registry_env_fee_recipient_from_splitter() { # STATE -> V2_FEE_RECIPIENT, or nothing
  local rec splitter
  rec=$(jqr '.shared.feeRecipient // empty')
  if is_addr "$rec"; then export V2_FEE_RECIPIENT=$(checksum "$rec"); return 0; fi
  splitter=$(jqr '.v2.flywheel.feeSplitter // empty')
  if is_addr "$splitter"; then export V2_FEE_RECIPIENT=$(checksum "$splitter"); return 0; fi
  unset V2_FEE_RECIPIENT
}

# registry_env_load <registry> <sources>: the whole shared projection for a caller that has no phase
# logic of its own -- the launch driver. Reads, then exports, in the wrapper's order. The caller sets
# MODE, CHAIN_EXPECT, ADMIN_ADDR, DEPLOYER_ADDR, REG_TREASURY and NO_SCHEDULE first (the driver derives
# ADMIN_ADDR/REG_TREASURY from the same registry fields the wrapper does; see broadcast-v8.sh). Per-market
# values are NOT exported here: they follow the caller's selection through {registry_env_market}, and the
# launch-set guard through {registry_env_launch_guard}.
registry_env_load() {
  STATE=$1; SOURCES=$2
  [ -f "$STATE" ] || die "registry not found: $STATE"
  [ -f "$SOURCES" ] || die "v2-sources.json not found: $SOURCES"
  registry_env_read_shared
  registry_env_read_contracts
  registry_env_read_bots
  registry_env_export_shared
  export_contracts
  registry_env_fee_recipient_from_splitter
}

# =================================================================================================
# THE EXTERNALS STAGE (T-OP-116). The six EXTERNAL_KEYS above are deployed by their own scripts, not
# by DeployV8, and until this stage existed NO driver ran those scripts: rehearse-v2.sh went
# DeployV8 -> RegisterMarkets -> VerifyV8 and broadcast-v8.sh went DeployV8 -> VerifyV8 -> register,
# so VerifyV8 FAILED on a CORRECT core deploy every time -- `every roles.v8.json target resolves to an
# address this run was given` and `every roles.v8.json selector is mapped to its manifest role on
# chain` (docs/V8-LISTING-REHEARSAL.md, T-OP-081 finding #3b: 117 ok / 4 FAIL on every run).
#
# ONE STAGE, TWO CALLERS, the same rule as the projection above: DeployV2Batch.sh calls
# {registry_env_externals} between its DeployV8 phase and its VerifyV8 phase (which is where
# rehearse-v2.sh gets it), broadcast-v8.sh calls it at the start of its verify step, after the
# operator's core write-back. Both hand it the same caller facts (listed at the function).
#
# WHAT IT DOES, in DEPENDENCY ORDER, and why that order (EXTERNAL_DEPLOY_ORDER below):
#   1. houseVaultFactory  script/v2/DeployHouseVault.s.sol (T-OP-141; not at this base). Constructor
#      houseVault         (orderBook, manager, calendar, oracle, splitter): core only. The same script then
#                         calls `factory.createVault` for the launch market -- a LISTING selector, which the
#                         deployer still holds as its transient step-4 self-grant while the hand-back is
#                         deferred -- so the vault exists in the same run and after the factory.
#   2. earnVault          script/v2/DeployEarnVault.s.sol. Constructor (orderBook, manager, usdg, splitter):
#                         core only, nothing from another external. The same script ALSO builds
#   3. stockVenueAdapter  ... `new StockVenueAdapter(manager, usdg, venue, earnVault)` AFTER the vault, in
#                         the same run, and ONLY when V2_EARN_VENUE names an ERC-4626 over USDG (none is
#                         named anywhere today). Skipped by default (owner window).
#   4. rewardsDistributorLender  script/v2/DeployLenderRewards.s.sol. Constructor (token, manager, treasury).
#                         Skipped by default (owner window, pending).
#   5. hedger             NO script; its constructor needs a Morpho address no registry or recon names.
#                         Skipped by default (owner: OUT).
#   An external that is neither skipped nor deployable is REPORTED as unsupplied, by name -- never
#   silently skipped: a skip is the owner's list or the operator's --skip-external, printed either way.
#
# THE MAPPING SUB-STEP (amendment #3, owner decision 2026-09-22 05:35Z, M-0446996d3fc44c3a). DeployV8 maps
# every manifest selector in its step 3 from the DEPLOYER at delay 0 and used to renounce ADMIN in its step 9
# in the same run (DeployV8.s.sol:52-64), so an external deployed afterwards had unmapped selectors and the
# only path left was the Admin Safe's ADMIN lane (48 h). The owner chose to EXTEND THE DEPLOYER'S ADMIN
# WINDOW instead (T-OP-153): DeployV8 with `V2_DEFER_HANDBACK=true` stops before step 9; the stage below
# deploys the supplied externals; `script/v2/MapExternals.s.sol` maps every SUPPLIED external's selectors
# at delay 0 through DeployV8's own _pendingMapping while ADMIN is still held (unsupplied ones skipped by
# name); then VerifyV8 (the gate); then -- amendment #4, T-OP-161, owner decision 2026-09-22 05:50Z -- the
# launch set is registered by the DEPLOYER DIRECTLY, still inside the window (it holds LISTING and CONFIG_ADMIN
# at delay 0 from DeployV8 step 4, so RegisterMarkets' single-run path applies: no schedule, no Safe, no
# 1 h / 24 h wait, no rc=90); and only then `script/v2/HandBack.s.sol`, the deferred step 9, idempotent
# ({registry_env_handback}). THE ACCEPTED HOT-KEY WINDOW is therefore "from DeployV8 until HandBack" =
# DeployV8 -> write-back -> externals -> MapExternals -> VerifyV8 -> RegisterMarkets -> HandBack, and both
# drivers run those steps back to back to keep it as short as the operator's write-back allows (stated in
# both docs' sequence tables). No Safe action is needed for mapping or for the launch listing any more; the
# rc=90 "schedule, print the Safe calls and stop" shape is kept ONLY for POST-LAUNCH registrations and
# listings (`--register-only`, `--resync`, a later wave: the window is closed and the Safe's lanes apply --
# {registry_env_direct_register_ok} decides by reading the manager, never from a flag) and where a LISTING
# action is genuinely required (createVault, T-OP-141's script). The two scripts are called BY THESE EXACT
# NAMES; until T-OP-153 lands they do not exist at this base and the stage dies naming the missing file --
# that is the expected state, not a defect of this stage.
#
# THE OWNER'S LAUNCH SET OF EXTERNALS (this window): HouseVaultFactory + HouseVault(s) + EarnVault. Hedger
# is OUT -- skipped through V2_SKIP_EXTERNALS, never removed from roles.v8.json -- and StockVenueAdapter and
# RewardsDistributorLender are pending the owner's answer and are treated as skipped until told. That is
# EXTERNAL_SKIP_DEFAULT below: the skip list every run starts from unless --skip-external replaces it
# (`--skip-external none` skips nothing).
#
# FORBIDDEN, and refused rather than left to discipline: skipping a key whose address is already
# supplied (recorded, or exported); a skip that does not print; a key outside EXTERNAL_KEYS; typing an
# address here (every address is read from the registry, the recon file or a deploy script's output).
#
# THIS STAGE PRINTS. The rule at the top of this file ("nothing here prints except through die") is
# for the PROJECTION stages, whose output is the caller's plan. This stage runs forge and moves the
# registry, and a step that sends transactions and says nothing is the failure the drivers exist to
# prevent; every line it prints is prefixed `  externals:` so a caller's log can be grepped for it.
# =================================================================================================

EXTERNAL_DEPLOY_ORDER="houseVaultFactory houseVault earnVault stockVenueAdapter rewardsDistributorLender hedger"
# The owner's window (M-0446996d3fc44c3a): hedger OUT; stockVenueAdapter and rewardsDistributorLender pending, skipped
# until told. Replaced wholesale by --skip-external; cleared by --skip-external none.
EXTERNAL_SKIP_DEFAULT="hedger rewardsDistributorLender stockVenueAdapter"
# T-OP-153's two scripts, called by exactly these names in this order after the externals are deployed.
EXTERNAL_MAP_SCRIPT="script/v2/MapExternals.s.sol:MapExternals"
EXTERNAL_HANDBACK_SCRIPT="script/v2/HandBack.s.sol:HandBack"

# registry key -> roles.v8.json target name (the name VerifyV8 walks and DeployV8._externallySupplied lists)
external_target_of() {
  case "$1" in
    houseVault) echo HouseVault ;; houseVaultFactory) echo HouseVaultFactory ;; hedger) echo Hedger ;;
    rewardsDistributorLender) echo RewardsDistributorLender ;; earnVault) echo EarnVault ;;
    stockVenueAdapter) echo StockVenueAdapter ;;
  esac
}
# registry key -> the forge script that CREATEs it, or nothing when no production script exists (T-225).
# stockVenueAdapter is built by DeployEarnVault in the same run as earnVault, so it has no script of its own.
external_script_of() {
  case "$1" in
    houseVaultFactory) echo "script/v2/DeployHouseVault.s.sol:DeployHouseVault" ;;
    rewardsDistributorLender) echo "script/v2/DeployLenderRewards.s.sol:DeployLenderRewards" ;;
    earnVault) echo "script/v2/DeployEarnVault.s.sol:DeployEarnVault" ;;
    *) echo "" ;;
  esac
}
# A script wired by name that is not at this base (T-OP-141 DeployHouseVault, T-OP-153 MapExternals/HandBack) dies
# HERE, by file name and row, rather than inside forge as "No such file or directory": the expected state until
# those rows land, and the line the ledger quotes.
external_script_present() { # <path:Contract> <row>
  [ -f "${1%%:*}" ] || die "externals: ${1%%:*} is not at this base: it lands with $2. Until then this stage cannot run its ${1##*:} step; that is the expected state, not a defect of the drivers"
}
ext_say() { printf '  externals: %s\n' "$*"; }

# --skip-external a,b -> EXT_SKIP (space-separated, validated). Refuses a name outside EXTERNAL_KEYS and a
# key whose address this run already has: a skipped external is one the run does NOT wire, and skipping
# one that is wired would make VerifyV8 (which reads V2_SKIP_EXTERNALS, sibling row) look away from a live
# contract. That is the "skip that hides itself" the row forbids.
externals_parse_skip() { # SKIP_EXTERNAL STATE -> EXT_SKIP, EXT_SKIP_SRC, V2_SKIP_EXTERNALS exported (MANIFEST names)
  local k a targets="" list
  EXT_SKIP=""
  # THE DEFAULT IS THE OWNER'S LIST, and it is printed as such: an empty --skip-external means "the owner's
  # window", the literal `none` means "skip nothing", anything else replaces the list wholesale.
  case "${SKIP_EXTERNAL:-}" in
    "") list=$EXTERNAL_SKIP_DEFAULT; EXT_SKIP_SRC="owner window (M-0446996d3fc44c3a)" ;;
    none) list=""; EXT_SKIP_SRC="--skip-external none" ;;
    *) list=$(echo "$SKIP_EXTERNAL" | tr ',' ' '); EXT_SKIP_SRC="--skip-external" ;;
  esac
  for k in $list; do
    case " $EXTERNAL_KEYS " in *" $k "*) ;; *) die "--skip-external $k: not one of the six externals ($EXTERNAL_KEYS)" ;; esac
    a=$(contract_of "$k")
    [ -z "$a" ] || die "--skip-external $k: refused, its address is already recorded at v2.contracts.$k ($a). A skip is for an external this run does not wire; VerifyV8 must not be told to look away from a contract that is there"
    eval "a=\${$(env_name "$k"):-}"
    [ -z "$a" ] || die "--skip-external $k: refused, $(env_name "$k") is exported ($a): the address was supplied to this run"
    EXT_SKIP="${EXT_SKIP:+$EXT_SKIP }$k"
    targets="${targets:+$targets,}$(external_target_of "$k")"
  done
  # Exported as the MANIFEST NAMES (roles.v8.json `targets` keys: Hedger, not hedger and not V2_HEDGER), the
  # spelling T-OP-140 LANDED in VerifyV8 (VerifyV8.s.sol:128-138 at 576f2fc1: "a comma list of MANIFEST NAMES among
  # the six externally supplied targets"; an unknown entry, or one whose target IS supplied, fails closed). The
  # first version of this function exported the V2_* env names on the strength of a pre-landing agreement, and
  # VerifyV8 would have refused every launch run by name (T-OP-161 correction). MapExternals (T-OP-153) reads the
  # same variable and the same spelling. Unset when nothing is skipped -- an empty string would read as "skip the
  # target named ''".
  if [ -n "$targets" ]; then export V2_SKIP_EXTERNALS=$targets; else unset V2_SKIP_EXTERNALS; fi
}

# Records one external at v2.contracts.<key> in STATE, and its start block at v2.externalDeployBlocks.<key>,
# atomically (<file>.tmp + rename, 2-space JSON + newline, as the builder and DeployV2Batch.sh write_back
# do). Refuses to overwrite a DIFFERENT recorded address; the same address is idempotent. THE KEYS MAY BE
# ABSENT FROM THE SKELETON: T-OP-114 adds the six contract keys AND the `v2.externalDeployBlocks` block
# (coordinator relay M-fcc36e22d2264e5d: callhouse indexer/lib/env.ts:58-82 refuses V2_EARN_VAULT /
# V2_HOUSE_VAULT_FACTORY without a dedicated start block) to both registry skeletons; until it lands, a
# written-back registry carries keys `build-markets.mjs --check` refuses (T-OP-081 finding #3b, operator's
# note). Recording anyway is right -- the address and its block are facts about the chain -- and the
# builder's refusal is the loud signal, not a silent drop here. The block is the CREATE receipt's block
# (a lower bound for the indexer, as DeployV8.recordBlocks records the core's); "-" when the run has no
# receipt to vouch for one, written as null and said so, never guessed from the head.
# T-OP-161 (h). The per-ticker vault slots (T-OP-156's registry key, `markets[].v2.houseVault`: null | strict
# address). DeployHouseVault's JSON out carries `houseVaults` keyed by ticker; a ticker whose vault is not created
# yet is the zero address there (pending Safe action) and is written as NULL, never 0x0 -- the schema refuses 0x0.
# `v2.contracts.houseVault` (the single slot VerifyV8 walks) stays the FIRST launch ticker's vault, recorded by
# the caller through registry_env_record_external.
registry_env_record_house_vaults() { # <DeployHouseVault out json>
  node -e '
    const fs = require("fs");
    const [file, outFile] = process.argv.slice(1);
    const reg = JSON.parse(fs.readFileSync(file, "utf8"));
    const out = JSON.parse(fs.readFileSync(outFile, "utf8"));
    const vaults = out.houseVaults || {};
    const isAddr = (a) => typeof a === "string" && /^0x[0-9a-fA-F]{40}$/.test(a);
    const zero = "0x0000000000000000000000000000000000000000";
    let n = 0;
    for (const [ticker, addr] of Object.entries(vaults)) {
      const m = (reg.markets || []).find((x) => x.ticker === ticker);
      if (!m) throw new Error(`houseVaults.${ticker}: no registry row for ${ticker}`);
      if (!m.v2 || typeof m.v2 !== "object") throw new Error(`${ticker}: no v2 block`);
      const value = isAddr(addr) && addr.toLowerCase() !== zero ? addr : null;   // 0x0 = pending, written as null
      const have = m.v2.houseVault;
      if (have && value && have.toLowerCase() !== value.toLowerCase()) throw new Error(`markets[${ticker}].v2.houseVault is ${have} in the registry, this run created ${value}: refusing to overwrite`);
      if (value !== null || have === undefined) m.v2.houseVault = value;
      if (value !== null) n += 1;
    }
    const tmp = file + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(reg, null, 2) + "\n");
    fs.renameSync(tmp, file);
    console.log(n);
  ' "$STATE" "$1" || die "externals: per-ticker write-back of markets[].v2.houseVault failed: $STATE"
}

registry_env_record_external() { # key addr block|-
  node -e '
    const fs = require("fs");
    const [file, key, addr, block] = process.argv.slice(1);
    const reg = JSON.parse(fs.readFileSync(file, "utf8"));
    if (!reg.v2 || typeof reg.v2.contracts !== "object") throw new Error("registry has no v2.contracts block");
    const have = reg.v2.contracts[key];
    if (have && have.toLowerCase() !== addr.toLowerCase()) throw new Error(`v2.contracts.${key} is ${have} in the registry, this run deployed ${addr}: refusing to overwrite`);
    reg.v2.contracts[key] = addr;
    if (!reg.v2.externalDeployBlocks || typeof reg.v2.externalDeployBlocks !== "object") reg.v2.externalDeployBlocks = {};
    const b = block === "-" ? null : Number(block);
    if (b !== null && !(Number.isInteger(b) && b > 0)) throw new Error(`${key}: deploy block ${JSON.stringify(block)} is not a positive integer`);
    const haveB = reg.v2.externalDeployBlocks[key];
    if (haveB && b !== null && haveB !== b) throw new Error(`v2.externalDeployBlocks.${key} is ${haveB} in the registry, this run says ${b}: refusing to overwrite`);
    if (b !== null || haveB === undefined) reg.v2.externalDeployBlocks[key] = b;
    const tmp = file + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(reg, null, 2) + "\n");
    fs.renameSync(tmp, file);
  ' "$STATE" "$1" "$2" "$3" || die "externals: write-back of v2.contracts.$1 / v2.externalDeployBlocks.$1 failed: $STATE"
}

# The gas the run spent and the block it landed in, from forge's run-latest.json for <script file>, or
# "-" when there is no record (a simulation). Receipts are summed; the CREATE's block is the min.
externals_run_stats() { # <Script>.s.sol -> "gas block txs"
  local run="$BROADCAST_DIR/$1/$CHAIN_EXPECT/run-latest.json"
  [ -f "$run" ] || { echo "- - -"; return 0; }
  jq -r '[.receipts[] | select(.status == "0x1")] as $r
    | ($r | map(.gasUsed | if type == "string" then (ltrimstr("0x") | explode | reduce .[] as $c (0; . * 16 + (if $c >= 97 then $c - 87 elif $c >= 65 then $c - 55 else $c - 48 end))) else . end) | add // 0) as $gas
    | ($r | map(.blockNumber | if type == "string" then (ltrimstr("0x") | explode | reduce .[] as $c (0; . * 16 + (if $c >= 97 then $c - 87 elif $c >= 65 then $c - 55 else $c - 48 end))) else . end) | min // "-") as $blk
    | "\($gas) \($blk) \($r | length)"' "$run" 2>/dev/null || echo "- - -"
}

# `cast codesize` must be non-zero before an address is recorded or exported: the deploy JSON/log is
# written while forge simulates, before it broadcasts (the same rule DeployV2Batch.sh mined_addresses applies).
externals_require_code() { # key addr
  is_addr "$2" || die "externals: $1: '$2' is not an address (read from the deploy script's output)"
  [ "$(cast codesize "$2" --rpc-url "$RPC")" != 0 ] || die "externals: $1: $2 has no code on $RPC after the deploy script exited 0: the transaction was not mined; nothing recorded"
}

# One external landed: record, export under its V2_* name, and remember it for the mapping sub-step.
externals_landed() { # key addr script-file
  local stats gas blk txs
  externals_require_code "$1" "$2"
  stats=$(externals_run_stats "$3"); read -r gas blk txs <<<"$stats"
  registry_env_record_external "$1" "$2" "$blk"
  export "$(env_name "$1")=$2"
  EXT_DEPLOYED="${EXT_DEPLOYED:+$EXT_DEPLOYED }$1=$2"
  ext_say "$1 $2  recorded at v2.contracts.$1 (start block ${blk}$([ "$blk" = - ] && echo ': no receipt block, written as null' || true)), exported $(env_name "$1")  (gas $gas, txs $txs)"
}

# The forge invocation every external deploy uses. The signer is the deployer -- DEPLOYER_PK from the
# environment, or the unlocked V2_DEPLOYER a rehearsal impersonates (EXT_DEPLOY_FLAGS carries
# `--unlocked --sender`) -- because these scripts create contracts and nothing more; every privileged
# call they would need is printed for the Safe. EXECUTE=0 simulates (no --broadcast) and records nothing.
#
# V2_SCHEDULE / V2_SCHEDULE_PHASE ARE SCRUBBED HERE (T-OP-181, run-4 stop). registry_env_export_shared exports
# V2_SCHEDULE=true for the Safe's scheduled RegisterMarkets path (:413), and the direct register step and the
# driver unset both for the deployer's single-run path (DeployV2Batch.sh run_forge_direct, broadcast-v8.sh
# run_register_direct). The externals stage did neither, so DeployHouseVault.s.sol saw V2_SCHEDULE=true with an
# EMPTY phase and refused pass A ("V2_SCHEDULE_PHASE must be schedule or execute, got ''") on the first
# externals step of run 4 -- and would on launch day. Every externals-stage script this function runs
# (DeployHouseVault, DeployLenderRewards, DeployEarnVault, MapExternals, HandBack) sends as the DEPLOYER inside
# the deferred window, single-run, no schedule: the only reader of the two names among them is DeployHouseVault,
# whose scheduled path is the Safe's post-launch one, never this stage's. Scrubbed at the invocation, not
# exported globally, so :413's export still reaches the Safe path.
# V2_UNLOCKED_ADMIN IS SCRUBBED TOO (T-OP-181 amendment, T-OP-165 runs 5-9): the rehearsal exports it (:384) so
# RegisterMarkets may impersonate the Safe on a fork, and DeployHouseVault reads the same flag as "take the Safe
# path" -- on a fresh, still-unmapped factory that path reverts. The externals stage sends as the DEPLOYER under
# its deferred ADMIN, on a fork and on the chain alike, so the flag must not reach it.
# shellcheck disable=SC2086
externals_forge() { # log target [env assignments are the caller's]
  local log=$1; shift
  if [ "$EXECUTE" = 0 ] && [ -z "${DEPLOYER_PK:-}" ] && [ -z "${V2_DEPLOYER:-}" ]; then
    # A dry run with no deployer known (the driver carries on without one; VerifyV8 then reports its deployer
    # checks NOT CHECKED). Both scripts read DEPLOYER_PK or V2_DEPLOYER before their preflight, so a simulation
    # here would die on the signer and say nothing about the inputs; print the command instead of running it.
    printf 'would run: V2_EXPECT_CHAIN_ID=%s forge script %s --rpc-url <rpc> --broadcast --slow --no-storage-caching --non-interactive\n' "$CHAIN_EXPECT" "$*" > "$log"
    ext_say "$(cat "$log") (no deployer known: not simulated)"
    return 0
  fi
  if [ "$EXECUTE" = 1 ]; then
    V2_EXPECT_CHAIN_ID="$CHAIN_EXPECT" env -u V2_SCHEDULE -u V2_SCHEDULE_PHASE -u V2_UNLOCKED_ADMIN \
      forge script "$@" --rpc-url "$RPC" --broadcast --slow --no-storage-caching --non-interactive ${EXT_DEPLOY_FLAGS:-} > "$log" 2>&1
  else
    V2_EXPECT_CHAIN_ID="$CHAIN_EXPECT" env -u V2_SCHEDULE -u V2_SCHEDULE_PHASE -u V2_UNLOCKED_ADMIN \
      forge script "$@" --rpc-url "$RPC" --no-storage-caching --non-interactive ${EXT_DEPLOY_FLAGS:-} > "$log" 2>&1
  fi
}

# 1. the House factory and its vault(s): script/v2/DeployHouseVault.s.sol (T-OP-141, not at this base). The
# contract agreed with that lane (M-505ce463b5f14fdc / M-7ea869d4624d491e): inputs from the V2_* environment
# (manager, book, calendar, oracle, splitter, V2_ADMIN_SAFE, V2_TICKERS + V2_MARKET_<T>_ASSET for the launch
# tickers, V2_HOUSE_LIMITS_FILE resolved in the read phase), signer DEPLOYER_PK
# else V2_DEPLOYER; prints `  V2_HOUSE_VAULT_FACTORY <addr>`, `  V2_HOUSE_VAULT_<T> <addr>` per vault and
# `  V2_HOUSE_VAULT <addr>` ONCE for the first launch ticker; writes V2_HOUSE_DEPLOY_OUT JSON {houseVaultFactory,
# houseVault, houseVaults{T:addr}, safeActionRequired, pendingCreateVault[], ...}; optional V2_HOUSE_VAULT_FACTORY
# reuses a deployed factory; V2_HOUSE_REQUIRE_VAULTS=true makes "vault not creatable" a revert.
#
# TWO PASSES, and the ordering is the window's: createVault is a LISTING selector and the deployer can send it
# only once the NEW factory's createVault is mapped -- which MapExternals does, and only for a factory that
# exists. So: pass A deploys the factory (the vault is not creatable yet: printed as pending, exit 0), the
# stage records the factory and runs MapExternals (factory mapped), pass B reuses the factory with
# V2_HOUSE_REQUIRE_VAULTS=true and creates the vault(s) as the deployer, whose transient step-4 LISTING
# self-grant is still live while the hand-back is deferred; the stage records v2.contracts.houseVault (the
# first launch ticker's, coordinator answer A on Q-5c08997202314b50; per-ticker vaults are a callhouse row) and
# the final MapExternals (after every external) maps the vault(s).
externals_house_env() { # the launch tickers' rows + limits for DeployHouseVault
  local t launch
  for v in V2_ACCESS_MANAGER V2_ORDER_BOOK V2_EXPIRY_CALENDAR V2_SETTLEMENT_ORACLE V2_FEE_SPLITTER V2_ADMIN_SAFE; do
    [ -n "${!v:-}" ] || die "externals: houseVaultFactory needs $v exported and it is unset: the core set must be recorded in $STATE and export_contracts run before this stage"
  done
  launch=$(jq -r 'if (.launchSet.markets | type) == "array" then [.launchSet.markets[] | ascii_upcase] | join(",") else "" end' "$STATE")
  [ -n "$launch" ] || die "externals: registry has no launchSet.markets block: DeployHouseVault creates one vault per launch ticker and this stage will not guess the set"
  for t in $(echo "$launch" | tr ',' ' '); do registry_env_market "$t"; done
  export V2_TICKERS=$launch
  # T-OP-173: the limits file was resolved and checked in the read phase and exported with the shared set; a run
  # that reaches here without it has skipped the projection, which is refused rather than defaulted.
  [ -n "${V2_HOUSE_LIMITS_FILE:-}" ] && [ -f "$V2_HOUSE_LIMITS_FILE" ] \
    || die "externals: V2_HOUSE_LIMITS_FILE is unset or names a missing file (${V2_HOUSE_LIMITS_FILE:-<unset>}): registry_env_read_shared resolves it before any forge step; this stage will not guess the House limits"
}
externals_deploy_house() {
  local log out addr vault n
  external_script_present "$(external_script_of houseVaultFactory)" "T-OP-141"
  externals_house_env
  # pass A: the factory. A vault is NOT creatable yet (createVault unmapped on a fresh factory): pending, exit 0.
  log="$LOGDIR/externals-house-A.log"; out="$LOGDIR/externals-house-A.json"
  rm -f "$out" "$BROADCAST_DIR/DeployHouseVault.s.sol/$CHAIN_EXPECT/run-latest.json"
  ext_say "houseVaultFactory: $(external_script_of houseVaultFactory) pass A (factory; launch tickers $V2_TICKERS; limits $V2_HOUSE_LIMITS_FILE)"
  if ! V2_HOUSE_DEPLOY_OUT="$out" externals_forge "$log" "$(external_script_of houseVaultFactory)"; then
    grep -E "preflight|Error|revert|not " "$log" | head -8 | sed 's/^/    /' || true
    die "externals: DeployHouseVault pass A failed (log: $log). Nothing recorded; re-run to retry, or --skip-external houseVaultFactory,houseVault"
  fi
  grep -E "^\s+ok |V2_HOUSE|pending|SKIPPED" "$log" | sed 's/^/    /' || true
  if [ "$EXECUTE" = 0 ]; then ext_say "houseVaultFactory: SIMULATED only (no --broadcast); nothing recorded"; return 0; fi
  [ -f "$out" ] || die "externals: DeployHouseVault exited 0 but wrote no $out (V2_HOUSE_DEPLOY_OUT); log $log"
  addr=$(jq -r '.houseVaultFactory // empty' "$out")
  externals_landed houseVaultFactory "$addr" DeployHouseVault.s.sol
  # the factory's createVault mapped, so the deployer may create
  externals_map_externals "factory"
  # pass B: the vault(s), on the recorded factory; not creatable is now a revert, by name.
  log="$LOGDIR/externals-house-B.log"; out="$LOGDIR/externals-house-B.json"
  rm -f "$out" "$BROADCAST_DIR/DeployHouseVault.s.sol/$CHAIN_EXPECT/run-latest.json"
  ext_say "houseVault: $(external_script_of houseVaultFactory) pass B (createVault per launch ticker on factory $addr, as the deployer under its transient LISTING)"
  if ! V2_HOUSE_DEPLOY_OUT="$out" V2_HOUSE_VAULT_FACTORY="$addr" V2_HOUSE_REQUIRE_VAULTS=true externals_forge "$log" "$(external_script_of houseVaultFactory)"; then
    grep -E "preflight|Error|revert|not |LISTING|createVault" "$log" | head -8 | sed 's/^/    /' || true
    die "externals: DeployHouseVault pass B failed (log: $log): a vault was not creatable by the deployer even after MapExternals mapped the factory. The factory IS recorded; re-run to retry the vaults"
  fi
  grep -E "^\s+ok |V2_HOUSE|created" "$log" | sed 's/^/    /' || true
  [ -f "$out" ] || die "externals: DeployHouseVault pass B wrote no $out; log $log"
  vault=$(jq -r '.houseVault // empty' "$out")
  [ -n "$vault" ] || die "externals: DeployHouseVault pass B recorded no houseVault in $out (safeActionRequired $(jq -r '.safeActionRequired' "$out"))"
  externals_landed houseVault "$vault" DeployHouseVault.s.sol
  # T-OP-161 (h): every launch ticker's vault at markets[].v2.houseVault (null while pending, never 0x0);
  # v2.contracts.houseVault above is the first ticker's, the single slot VerifyV8 walks.
  n=$(registry_env_record_house_vaults "$out")
  ext_say "houseVault: $n per-ticker vault(s) recorded at markets[].v2.houseVault ($(jq -c '.houseVaults' "$out")); v2.contracts.houseVault = the first launch ticker's ($vault)"
  # T-OP-198. RE-EXPORT THE PER-TICKER VAULTS FROM STATE. externals_house_env projected V2_MARKET_<T>_* BEFORE pass B
  # existed, so V2_MARKET_<T>_HOUSE_VAULT was unset for every ticker (null in the registry at that point), and
  # nothing after the recorder re-read it: externals_landed exports V2_HOUSE_VAULT only, and MapExternals "final"
  # (T-OP-196 maps every V2_MARKET_<T>_HOUSE_VAULT) inherited the stale environment -- SPCX's vault stayed unmapped
  # (run 4c). Re-projected through registry_env_market from STATE, the file the recorder just wrote, rather than
  # from the pass-B JSON: the JSON is what the recorder CONSUMED (a 0x0 pending vault, a refused overwrite), STATE
  # is what it WROTE, and every later reader (VerifyV8, the write-back, the read-back below) reads STATE.
  # Idempotent: market_row validates registry facts only (no pre-deploy refusal), and export_market unsets the
  # variable again for a ticker whose vault is still null.
  externals_reexport_house_vaults
}

# T-OP-198: V2_MARKET_<T>_HOUSE_VAULT for every launch ticker, from STATE, after the per-ticker write-back. Said
# per ticker so the log shows which vault the final MapExternals pass will see (and which is still pending).
externals_reexport_house_vaults() {
  local t v
  for t in $(echo "${V2_TICKERS:-}" | tr ',' ' '); do
    registry_env_market "$t"
    eval "v=\${V2_MARKET_${t}_HOUSE_VAULT:-}"
    ext_say "houseVault: V2_MARKET_${t}_HOUSE_VAULT ${v:-<unset: markets[$t].v2.houseVault is null (pending)>} re-exported from $STATE"
  done
}

# 2. the lender RewardsDistributor. V2_STONKHOUSE_TOKEN is the registry's shared.token.address -- the only
# home the schema gives the token -- refused by name when null: DeployLenderRewards reads it with a
# no-default vm.envAddress and would die after a compile with a message naming no file.
externals_deploy_lender() {
  local token log out addr
  token=$(jqr '.shared.token.address // empty')
  [ -n "$token" ] || die "externals: rewardsDistributorLender needs the STONKHOUSE token, and registry shared.token.address is null. DeployLenderRewards.s.sol reads it as V2_STONKHOUSE_TOKEN (18-dp, symbol STONKHOUSE, re-derived on chain). Fill it (callhouse ops/markets, T-OP-108 shape) or pass --skip-external rewardsDistributorLender"
  is_addr "$token" || die "externals: registry shared.token.address '$token' is not an address"
  [ -n "${V2_TREASURY_SAFE:-}" ] || die "externals: rewardsDistributorLender needs V2_TREASURY_SAFE (registry shared.safes.treasury), which is unset: the lender pays the Treasury Safe and DeployLenderRewards refuses a code-less treasury"
  log="$LOGDIR/externals-lender.log"; out="$LOGDIR/externals-lender.json"
  rm -f "$out" "$BROADCAST_DIR/DeployLenderRewards.s.sol/$CHAIN_EXPECT/run-latest.json"
  ext_say "rewardsDistributorLender: $(external_script_of rewardsDistributorLender) (V2_STONKHOUSE_TOKEN from shared.token.address $token)"
  # V2_LENDER_DEPLOY_OUT is where the script writes its report (vm.writeJson; ./broadcast is the one read-write
  # fs_permissions path, foundry.toml:55, so LOGDIR must live under it -- both callers' log dirs do).
  if ! V2_STONKHOUSE_TOKEN="$token" V2_LENDER_DEPLOY_OUT="$out" externals_forge "$log" "$(external_script_of rewardsDistributorLender)"; then
    grep -E "preflight|Error|revert|not " "$log" | head -8 | sed 's/^/    /' || true
    die "externals: DeployLenderRewards failed (log: $log). Nothing recorded; re-run to retry, or --skip-external rewardsDistributorLender"
  fi
  grep -E "^\s+ok " "$log" | sed 's/^/    /' || true
  if [ "$EXECUTE" = 1 ]; then
    [ -f "$out" ] || die "externals: DeployLenderRewards exited 0 but wrote no $out (V2_LENDER_DEPLOY_OUT): the address cannot be read back; log $log"
    addr=$(jq -r '.lenderRewardsDistributor // empty' "$out")
    externals_landed rewardsDistributorLender "$addr" DeployLenderRewards.s.sol
    ext_say "rewardsDistributorLender: its 3 manifest selectors are UNMAPPED until the Safe maps them (below); the script's own printed rows are the same calls"
  else
    ext_say "rewardsDistributorLender: SIMULATED only (no --broadcast); nothing recorded"
  fi
}

# 3 + 4. the Earn vault, and the venue adapter when a venue is named. V2_EARN_VENUE is read from the recon
# file (v2-sources.json .contracts.earnVenue.address): an ERC-4626 over USDG is an EXTERNAL chain dependency
# with code, the same class as the router, the quoter and the v4 pair, so `contracts.*` is its home -- and
# no registry or recon file carries it today (docs/DEPLOY-V2.md, "blocked on an owner input"). Without it
# the vault deploys with adapter == 0 and stockVenueAdapter is REPORTED as unsupplied, never faked.
externals_deploy_earn() {
  local venue log addr adapter zap
  venue=$(jq -r '.contracts.earnVenue.address // empty' "$SOURCES")
  if [ -n "$venue" ]; then
    is_addr "$venue" || die "externals: v2-sources contracts.earnVenue.address '$venue' is not an address"
    export V2_EARN_VENUE=$venue
    ext_say "earnVault + stockVenueAdapter: $(external_script_of earnVault) (V2_EARN_VENUE from v2-sources contracts.earnVenue.address $venue)"
  else
    unset V2_EARN_VENUE
    ext_say "earnVault: $(external_script_of earnVault) (no v2-sources contracts.earnVenue.address: the vault deploys with adapter == 0 and stockVenueAdapter is NOT deployed)"
  fi
  for v in V2_ACCESS_MANAGER V2_ORDER_BOOK V2_USDG V2_FEE_SPLITTER; do
    [ -n "${!v:-}" ] || die "externals: earnVault needs $v exported and it is unset: the core set must be recorded in $STATE and export_contracts run before this stage"
  done
  log="$LOGDIR/externals-earn.log"
  rm -f "$BROADCAST_DIR/DeployEarnVault.s.sol/$CHAIN_EXPECT/run-latest.json"
  if ! externals_forge "$log" "$(external_script_of earnVault)"; then
    grep -E "preflight|Error|revert|not " "$log" | head -8 | sed 's/^/    /' || true
    die "externals: DeployEarnVault failed (log: $log). Nothing recorded; re-run to retry, or --skip-external earnVault"
  fi
  grep -E "^\s+ok |SKIPPED" "$log" | sed 's/^/    /' || true
  if [ "$EXECUTE" = 1 ]; then
    # DeployEarnVault prints `  V2_EARN_VAULT <addr>` (and `  V2_STOCK_VENUE_ADAPTER <addr>`, `  StockZap <addr>`)
    # and writes no JSON; the address is read off those lines, then required to hold code.
    addr=$(grep -oE 'V2_EARN_VAULT[[:space:]]+0x[0-9a-fA-F]{40}' "$log" | tail -1 | grep -oE '0x[0-9a-fA-F]{40}' || true)
    [ -n "$addr" ] || die "externals: DeployEarnVault exited 0 but printed no 'V2_EARN_VAULT <address>' line (log: $log)"
    externals_landed earnVault "$addr" DeployEarnVault.s.sol
    adapter=$(grep -oE 'V2_STOCK_VENUE_ADAPTER[[:space:]]+0x[0-9a-fA-F]{40}' "$log" | tail -1 | grep -oE '0x[0-9a-fA-F]{40}' || true)
    if [ -n "$adapter" ]; then
      externals_landed stockVenueAdapter "$adapter" DeployEarnVault.s.sol
      ext_say "stockVenueAdapter: NOT wired. EarnVault.setAdapter is TREASURY_ADMIN and StockVenueAdapter.setEnabled is CONFIG_ADMIN: both are the Safe's (DeployEarnVault prints them)"
    elif [ -n "$venue" ]; then
      die "externals: a venue was given but DeployEarnVault printed no V2_STOCK_VENUE_ADAPTER line (log: $log)"
    else
      EXT_UNSUPPLIED="${EXT_UNSUPPLIED:+$EXT_UNSUPPLIED }stockVenueAdapter"
      ext_say "stockVenueAdapter: UNSUPPLIED (no venue named). VerifyV8 will FAIL on StockVenueAdapter until one is"
    fi
    # StockZap has no registry key, no V2_* input and no manifest row (docs/DEPLOY-V2.md, T-225): reported, not recorded.
    zap=$(grep -oE 'StockZap[[:space:]]+0x[0-9a-fA-F]{40}' "$log" | tail -1 | grep -oE '0x[0-9a-fA-F]{40}' || true)
    [ -z "$zap" ] || ext_say "StockZap $zap deployed beside the vault (NOT recorded: the registry has no key for it -- T-225)"
  else
    ext_say "earnVault: SIMULATED only (no --broadcast); nothing recorded"
  fi
}

# THE MAPPING SUB-STEP (amendment #3): MapExternals.s.sol maps every SUPPLIED external's manifest selectors at
# delay 0 from the deployer, which still holds ADMIN because DeployV8 ran with V2_DEFER_HANDBACK=true; then
# HandBack.s.sol is the deferred step 9. Both are T-OP-153's and are called by exactly these names; every
# V2_* the recorded set and the externals need is already exported (export_contracts + the stage's own
# exports), and V2_SKIP_EXTERNALS names what MapExternals must skip. MapExternals runs TWICE when the house
# pair is deployed (once for the fresh factory, once at the end for everything). After the final pass every
# selector of every supplied external is READ BACK here (`getTargetFunctionRole == roleIdOf(manifest role)`), because
# a mapping script that exits 0 having mapped nothing is exactly the false green the drivers exist to
# refuse; nothing here types a selector or a role id (roles.v8.json + `cast sig`, as DeployV8 derives them).
# Sets EXT_MAPPED (count of selectors verified mapped).
# One MapExternals pass, labelled: "factory" (so the deployer may createVault on the fresh factory) and "final"
# (after every external). A no-op for what is already mapped.
externals_map_externals() { # <label>
  local log="$LOGDIR/externals-map-$1.log"
  external_script_present "$EXTERNAL_MAP_SCRIPT" "T-OP-153"
  ext_say "MapExternals ($1): ${EXTERNAL_MAP_SCRIPT%%:*} (deployer holds ADMIN: DeployV8 ran with V2_DEFER_HANDBACK=true; skips V2_SKIP_EXTERNALS=${V2_SKIP_EXTERNALS:-<unset>})"
  if ! externals_forge "$log" "$EXTERNAL_MAP_SCRIPT"; then
    grep -E "preflight|Error|revert|not |skip" "$log" | head -8 | sed 's/^/    /' || true
    die "externals: MapExternals ($1) failed (log: $log). The deployer still holds ADMIN: fix the input and re-run this command; HandBack has NOT been sent"
  fi
  grep -E "^\s+(ok|WARN|skip|call) |MAP DONE|DONE" "$log" | sed 's/^/    /' || true
}
# THE MAPPING SUB-STEP, ALONE (T-OP-161 / amendment #4, owner decision 2026-09-22 05:50Z). MapExternals runs here,
# at the end of the externals stage, while the deployer still holds ADMIN. HandBack does NOT: it moved to
# {registry_env_handback}, which both drivers call AFTER RegisterMarkets, because the launch set is registered by
# the DEPLOYER DIRECTLY inside the same deferred-ADMIN window (it holds LISTING and CONFIG_ADMIN at delay 0 from
# DeployV8 step 4, so RegisterMarkets' single-run path applies: no schedule, no Safe, no 1 h / 24 h wait). The
# accepted hot-key window is therefore DeployV8 -> externals -> MapExternals -> VerifyV8 (gate) -> RegisterMarkets
# -> HandBack, and a run that stops anywhere before HandBack leaves the deployer holding ADMIN and says so.
# T-OP-198: one target's selectors read back off the manager, as its manifest name maps them. Prints nothing on
# success, dies on the first disagreement, and returns the count on stdout -- the same loop for the six externals
# (by registry key) and for the per-ticker House vaults (by ticker), so the two cannot drift.
externals_read_back_target() { # <manifest target> <addr> <what, for the message>
  local target=$1 addr=$2 what=$3 sigs sig sel role_name role_id have n=0
  sigs=$(jq -r --arg t "$target" '.targets[$t] // {} | keys_unsorted[]' "$ROLES_JSON")
  [ -n "$sigs" ] || die "externals: roles.v8.json lists no selectors under .targets.$target"
  while IFS= read -r sig; do
    [ -n "$sig" ] || continue
    sel=$(cast sig "$sig")
    role_name=$(jq -r --arg t "$target" --arg s "$sig" '.targets[$t][$s]' "$ROLES_JSON")
    role_id=$(jq -r --arg r "$role_name" '.roles[$r]' "$ROLES_JSON")
    is_uint "$role_id" || die "externals: roles.v8.json .roles.$role_name is not a role id (for $target.$sig)"
    have=$(cast call "$V2_ACCESS_MANAGER" "getTargetFunctionRole(address,bytes4)(uint64)" "$addr" "$sel" --rpc-url "$RPC" | awk '{print $1}')
    if [ "$have" != "$role_id" ]; then
      # T-OP-210: two different facts print the same disagreement. In the window MapExternals just ran and exited 0,
      # so the chain contradicting it is a script defect. After HandBack nothing ran, and a wrong mapping can only be
      # repaired from the Admin Safe; saying "run before HandBack" there sends the operator to a step that cannot run.
      if [ "${EXT_MAP_RAN:-yes}" = yes ]; then
        die "externals: after MapExternals, $what $target.$sig ($sel) maps to role '$have', not $role_name ($role_id): the script exited 0 but the chain disagrees; HandBack has NOT been sent -- fix and re-run this command"
      else
        die "externals: $what $target.$sig ($sel) maps to role '$have', not $role_name ($role_id), and the deployer no longer holds ADMIN (HandBack has run), so this cannot be re-mapped from here. Map it from the Admin Safe: setTargetFunctionRole is an ADMIN operation -- schedule it on the manager and execute after delaysS.ADMIN (the day-zero batch's map stage, docs/V8-DAY-ZERO-ADMIN-BATCH.md) -- then re-run this command"
      fi
    fi
    n=$((n + 1))
  done <<<"$sigs"
  echo "$n"
}
externals_map_final() {
  local k t target addr m n=0 nv=0 extra="" have window=open
  external_script_present "$EXTERNAL_HANDBACK_SCRIPT" "T-OP-153"   # both scripts must exist before the window opens
  # T-OP-210 (run 4e drill 5). This function used to run MapExternals UNCONDITIONALLY, on the theory that "the map is
  # a no-op on a resume". It is not: MapExternals.s.sol:297-311 (_requireDeployerHoldsAdmin) reverts before it plans
  # anything, so once HandBack has run -- which is every run after launch: the wave --register-only, --resync, the
  # lost-write-back recovery -- the stage died here with "does not hold ADMIN ... run before HandBack.s.sol", an
  # instruction that can never be followed again. The fact is read off the manager instead of assumed: with the
  # window OPEN the behaviour below is unchanged; with the window CLOSED and nothing new deployed this run, the
  # recorded mappings are READ BACK (the same T-OP-198 loop, the same die on a disagreement) and the run goes on;
  # with the window CLOSED and a new external deployed, the stage refuses and names the only path that can map it.
  if [ -n "${V2_DEPLOYER:-}" ]; then
    have=$(cast call "$V2_ACCESS_MANAGER" "hasRole(uint64,address)(bool,uint32)" 0 "$V2_DEPLOYER" --rpc-url "$RPC" 2>/dev/null | head -1)
    case "$have" in
      true) window=open ;;
      false) window=closed ;;
      *) die "externals: cannot read hasRole(ADMIN, $V2_DEPLOYER) off $V2_ACCESS_MANAGER (got '$have'): the window state decides whether MapExternals may run, and a guess here is how a post-launch run dies at the wrong line" ;;
    esac
  fi
  EXT_MAP_RAN=yes
  if [ "$window" = closed ]; then
    if [ -n "$EXT_DEPLOYED" ]; then
      die "externals: the deployer $V2_DEPLOYER does not hold ADMIN (HandBack has run) and this run deployed [$EXT_DEPLOYED]: their selectors cannot be mapped from here. Map them from the Admin Safe: setTargetFunctionRole is an ADMIN operation -- schedule it on the manager and execute after delaysS.ADMIN (the day-zero batch's map stage, docs/V8-DAY-ZERO-ADMIN-BATCH.md) -- and re-run this command once the mapping is on chain"
    fi
    EXT_MAP_RAN=no
    ext_say "MapExternals (final): SKIPPED -- the deployer $V2_DEPLOYER no longer holds ADMIN (the window closed at HandBack) and this run deployed no external; reading the recorded mappings back instead (T-OP-210)"
  else
    externals_map_externals "final"
  fi
  if [ "$EXECUTE" = 1 ]; then
    for k in $EXTERNAL_DEPLOY_ORDER; do
      eval "addr=\${$(env_name "$k"):-}"
      [ -n "$addr" ] || continue
      target=$(external_target_of "$k")
      m=$(externals_read_back_target "$target" "$addr" "$k") || exit $?
      n=$((n + m))
    done
    # T-OP-198: the per-ticker House vaults (T-OP-196 maps every V2_MARKET_<T>_HOUSE_VAULT). The first launch
    # ticker's vault IS V2_HOUSE_VAULT (registry option A) and was counted under the houseVault key above; every
    # OTHER ticker's vault is read back here under the same .targets.HouseVault selectors, so the line below rises
    # by one HouseVault's selector count per extra vault (15 at roles.v8.json interfaceVersion 8: 27 -> 42 for two).
    for t in $(echo "${V2_TICKERS:-}" | tr ',' ' '); do
      eval "addr=\${V2_MARKET_${t}_HOUSE_VAULT:-}"
      [ -n "$addr" ] || continue
      [ "$(printf '%s' "$addr" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "${V2_HOUSE_VAULT:-}" | tr '[:upper:]' '[:lower:]')" ] || continue
      m=$(externals_read_back_target HouseVault "$addr" "houseVault[$t]") || exit $?
      ext_say "MapExternals: houseVault[$t] $addr: $m selector(s) read back mapped (per-ticker vault, T-OP-196)"
      nv=$((nv + m)); extra="${extra:+$extra,}$t"
    done
    n=$((n + nv))
    if [ "$EXT_MAP_RAN" = yes ]; then
      ext_say "MapExternals: $n selector(s) of the supplied externals read back mapped to their manifest roles${extra:+ (incl. $nv for the per-ticker vault(s) $extra)}"
    else
      ext_say "MapExternals: window closed, nothing re-mapped; $n selector(s) of the recorded externals read back mapped to their manifest roles${extra:+ (incl. $nv for the per-ticker vault(s) $extra)}"
    fi
  else
    ext_say "MapExternals: SIMULATED only; nothing read back"
  fi
  EXT_MAPPED=$n
}

# THE DEFERRED STEP 9, after RegisterMarkets (T-OP-161). HandBack.s.sol drops the deployer's transient
# memberships and renounces ADMIN (DeployV8 steps 8 and 9, T-OP-153's script, idempotent), then the one fact the
# window is about is READ BACK off the manager: hasRole(ADMIN, deployer) == false. Callers: broadcast-v8.sh step 4
# and DeployV2Batch.sh phase 2c, both after every launch market has been registered by the deployer. Reads the
# same caller facts as the stage (LOGDIR, RPC, EXECUTE, V2_ACCESS_MANAGER, V2_DEPLOYER).
registry_env_handback() {
  local log="$LOGDIR/externals-handback.log" have
  external_script_present "$EXTERNAL_HANDBACK_SCRIPT" "T-OP-153"
  [ -n "${V2_ACCESS_MANAGER:-}" ] || die "hand-back: V2_ACCESS_MANAGER is unset: load the projection before this step"
  ext_say "HandBack: ${EXTERNAL_HANDBACK_SCRIPT%%:*} (the deferred DeployV8 step 9, AFTER RegisterMarkets: the deployer renounces; idempotent)"
  if ! externals_forge "$log" "$EXTERNAL_HANDBACK_SCRIPT"; then
    grep -E "preflight|Error|revert|not |skip" "$log" | head -8 | sed 's/^/    /' || true
    die "hand-back: HandBack failed (log: $log). THE DEPLOYER STILL HOLDS ADMIN; re-run this command until it renounces -- VerifyV8 refuses a deployer that holds anything"
  fi
  grep -E "^\s+(ok|WARN|skip|call) |DONE|holds nothing|renounce" "$log" | sed 's/^/    /' || true
  if [ "$EXECUTE" = 1 ] && [ -n "${V2_DEPLOYER:-}" ]; then
    have=$(cast call "$V2_ACCESS_MANAGER" "hasRole(uint64,address)(bool,uint32)" 0 "$V2_DEPLOYER" --rpc-url "$RPC" | head -1)
    [ "$have" = false ] || die "hand-back: after HandBack the deployer $V2_DEPLOYER still holds ADMIN (hasRole(0) = $have): the window is not closed; do not proceed"
    ext_say "HandBack: the deployer $V2_DEPLOYER no longer holds ADMIN (read back)"
  else
    ext_say "HandBack: SIMULATED only; nothing read back"
  fi
}

# THE DIRECT-REGISTER PREDICATE (T-OP-161). True while the deployer holds LISTING and CONFIG_ADMIN at execution
# delay 0 on the manager -- the state DeployV8 step 4 leaves it in until HandBack. Read off the chain, never
# inferred from which flags this run was started with: a resumed run whose earlier half already handed back
# must take the scheduled (Safe) path, and a fresh run whose hand-back is still pending must not. Requires the
# recorded core set (V2_ACCESS_MANAGER) and a deployer address; answers 1 (direct) or 0 (scheduled) and prints
# why. On a dry run with no node answer it answers 0.
registry_env_direct_register_ok() { # <deployer address> -> DIRECT_REGISTER=1|0, DIRECT_REGISTER_WHY
  local dep=$1 listing config l_m l_d c_m c_d
  DIRECT_REGISTER=0; DIRECT_REGISTER_WHY=""
  is_addr "$dep" || { DIRECT_REGISTER_WHY="no deployer address: the scheduled path"; return 0; }
  [ -n "${V2_ACCESS_MANAGER:-}" ] || { DIRECT_REGISTER_WHY="V2_ACCESS_MANAGER unset: the scheduled path"; return 0; }
  listing=$(jq -r '.roles.LISTING // empty' "$ROLES_JSON"); config=$(jq -r '.roles.CONFIG_ADMIN // empty' "$ROLES_JSON")
  is_uint "$listing" && is_uint "$config" || die "direct-register: roles.v8.json lacks .roles.LISTING / .roles.CONFIG_ADMIN"
  read -r l_m l_d <<<"$(cast call "$V2_ACCESS_MANAGER" "hasRole(uint64,address)(bool,uint32)" "$listing" "$dep" --rpc-url "$RPC" 2>/dev/null | tr '\n' ' ')"
  read -r c_m c_d <<<"$(cast call "$V2_ACCESS_MANAGER" "hasRole(uint64,address)(bool,uint32)" "$config" "$dep" --rpc-url "$RPC" 2>/dev/null | tr '\n' ' ')"
  if [ "$l_m" = true ] && [ "${l_d:-1}" = 0 ] && [ "$c_m" = true ] && [ "${c_d:-1}" = 0 ]; then
    DIRECT_REGISTER=1
    DIRECT_REGISTER_WHY="the deployer $dep holds LISTING and CONFIG_ADMIN at execution delay 0 (the deferred-ADMIN window is open): RegisterMarkets goes DIRECT, no schedule, no Safe"
  else
    DIRECT_REGISTER_WHY="the deployer $dep does not hold LISTING and CONFIG_ADMIN at delay 0 (LISTING member=${l_m:-?} delay=${l_d:-?}, CONFIG_ADMIN member=${c_m:-?} delay=${c_d:-?}): the window is closed, so this is a post-launch registration and takes the SCHEDULED path (Safe, rc=90)"
  fi
}

# THE DEPLOYER MUST NOT BE A PRINCIPAL (T-OP-161 amendment (f); DeployV8._principals :356-378 refuses it after a
# full compile, and T-OP-160 found the owner's guardian wallet IS the mnemonic index-0 key). Refused HERE, in one
# second, before step 1: the resolved deployer address against every principal the registry names -- the two
# Safes, the guardian, the ops wallet and the four bots. Both refuse by name, naming both sides. Reads STATE.
registry_env_refuse_deployer_is_principal() { # <deployer address>
  local dep=$1 lower name v
  is_addr "$dep" || return 0
  lower=$(echo "$dep" | tr 'A-F' 'a-f')
  # shared.admin is NOT in this list (T-OP-181 amendment, T-OP-174): it mirrors shared.safes.admin, which is
  # refused above and by DeployV2Batch.sh:262-263, and in the FIXTURE it is anvil #0 -- the default
  # REHEARSAL_DEPLOYER -- so keeping it killed every fixture rehearsal with "the deployer IS the registry's
  # shared.admin". tier1.json's shared.admin is the Safe either way.
  for name in shared.safes.admin shared.safes.treasury shared.guardian shared.opsWallet \
              v2.bots.cranker v2.bots.pricer v2.bots.quoter v2.bots.guardian; do
    v=$(jqr ".$name // empty" | tr 'A-F' 'a-f')
    [ -n "$v" ] || continue
    [ "$v" != "$lower" ] || die "the deployer $dep IS the registry's $name. v8 needs seven distinct principals (DeployV8._principals) and a key that deploys must not be a key that guards, quotes or signs anything else afterwards: choose another deployer key, or change $name in the registry (owner decision). Refused before any compile or transaction"
  done
}

# ADMIN_PK ON LAUNCH DAY IS A DEFECT, NOT A FALLBACK (T-OP-161, acceptance 3). The register step is sent by the
# deployer inside its own window; an ADMIN_PK in the environment is a second key on the box that nothing on the
# launch path needs, and one that would make RegisterMarkets sign as someone the projection did not name. Both
# drivers refuse it by name before their first forge step. The value is never printed.
registry_env_refuse_admin_pk() {
  [ -z "${ADMIN_PK:-}" ] \
    || die "ADMIN_PK is set in the environment. On launch day the launch set is registered by the DEPLOYER directly inside its deferred-ADMIN window (T-OP-161, owner decision 2026-09-22 05:50Z) and the drivers derive the register step's signer from DEPLOYER_PK themselves; a separate ADMIN_PK is a second key this path never needs. Unset it (and rotate it if it was real). Post-launch listings go through the Admin Safe's LISTING lane, which holds no key on this machine either"
}

# registry_env_externals: the stage. CALLER FACTS it reads (every one a plain variable the caller sets):
#   STATE           the registry this run writes (rehearsal copy or the real file); recorded slots are read from it
#   SOURCES         v2-sources.json next to it (contracts.earnVenue.address)
#   RPC MODE CHAIN_EXPECT ADMIN_ADDR ROLES_JSON EXECUTE(0|1)
#   LOGDIR          under ./broadcast (forge's one read-write path); logs and the Safe-calls file land here
#   BROADCAST_DIR   where forge writes <Script>.s.sol/<chain>/run-latest.json (FOUNDRY_BROADCAST on a rehearsal)
#   EXT_DEPLOY_FLAGS  the deploy signer's forge flags (`--unlocked --sender <deployer>` on a fork; empty with DEPLOYER_PK)
#   SKIP_EXTERNAL   the --skip-external list, comma-separated registry keys
# and the V2_* projection ALREADY LOADED for the recorded core set (export_contracts after the core write-back).
# LEAVES: EXT_DEPLOYED ("key=addr" ...), EXT_REUSED, EXT_SKIP (+ EXT_SKIP_SRC), EXT_UNSUPPLIED, EXT_MAPPED,
# V2_SKIP_EXTERNALS (exported for MapExternals and VerifyV8 as a comma list of the skipped externals' V2_* env
# names), and every deployed external's V2_* name exported. Returns 0 (mapped; HAND-BACK PENDING -- the caller
# registers the launch set by the deployer and then calls registry_env_handback) or dies.
registry_env_externals() {
  local k a
  EXT_DEPLOYED=""; EXT_REUSED=""; EXT_UNSUPPLIED=""; EXT_MAPPED=0
  [ -n "${LOGDIR:-}" ] && [ -d "$LOGDIR" ] || die "externals: LOGDIR is unset or missing: the stage writes logs and the Safe-calls file there"
  [ -n "${V2_ACCESS_MANAGER:-}" ] || die "externals: V2_ACCESS_MANAGER is unset: the core set must be recorded in $STATE and export_contracts run before this stage"
  is_addr "${ADMIN_ADDR:-}" || die "externals: ADMIN_ADDR '${ADMIN_ADDR:-}' is not an address (the Admin Safe the mapping sub-step schedules from)"
  externals_parse_skip
  ext_say "stage: deploy order $EXTERNAL_DEPLOY_ORDER; skipping: ${EXT_SKIP:-none} ($EXT_SKIP_SRC); mode $MODE; execute $EXECUTE"
  for k in $EXTERNAL_DEPLOY_ORDER; do
    case " $EXT_SKIP " in *" $k "*)
      ext_say "$k: SKIPPED by --skip-external (V2_SKIP_EXTERNALS carries $(env_name "$k") for VerifyV8)"; continue ;;
    esac
    a=$(contract_of "$k")
    if [ -n "$a" ]; then
      # Recorded by an earlier run (a resume): reuse, never redeploy. Exported so the mapping pass and VerifyV8 see it.
      externals_require_code "$k" "$a"
      export "$(env_name "$k")=$a"
      EXT_REUSED="${EXT_REUSED:+$EXT_REUSED }$k=$a"
      ext_say "$k $a  already recorded at v2.contracts.$k, reused"
      continue
    fi
    case "$k" in
      houseVaultFactory) externals_deploy_house ;;
      houseVault)
        # Built by externals_deploy_house in the same run as the factory (createVault). Reached with neither
        # when the factory was skipped or reused: still absent, still said.
        case " $EXT_DEPLOYED $EXT_UNSUPPLIED " in *" houseVault="*|*" houseVault "*) ;;
          *) EXT_UNSUPPLIED="${EXT_UNSUPPLIED:+$EXT_UNSUPPLIED }houseVault"
             ext_say "houseVault: UNSUPPLIED -- created only by DeployHouseVault beside a fresh factory; that did not happen in this run. VerifyV8 will FAIL on HouseVault until it is" ;;
        esac ;;
      rewardsDistributorLender) externals_deploy_lender ;;
      earnVault) externals_deploy_earn ;;
      stockVenueAdapter)
        # Built by externals_deploy_earn in the same run as the vault, which also reports it absent. Reached with
        # neither when earnVault was skipped or reused: still absent, still said.
        case " $EXT_DEPLOYED $EXT_UNSUPPLIED " in *" stockVenueAdapter="*|*" stockVenueAdapter "*) ;;
          *) EXT_UNSUPPLIED="${EXT_UNSUPPLIED:+$EXT_UNSUPPLIED }stockVenueAdapter"
             ext_say "stockVenueAdapter: UNSUPPLIED -- built only by DeployEarnVault beside a fresh vault, with a venue named; neither happened in this run. VerifyV8 will FAIL on StockVenueAdapter until it is" ;;
        esac ;;
      *)
        EXT_UNSUPPLIED="${EXT_UNSUPPLIED:+$EXT_UNSUPPLIED }$k"
        ext_say "$k: UNSUPPLIED -- no production deploy script in this repository (docs/DEPLOY-V2.md, the T-225 table$([ "$k" = houseVault ] && echo '; created by HouseVaultFactory.createVault, a LISTING-lane Safe call' || true)). Not deployed, not skipped: VerifyV8 will FAIL on $(external_target_of "$k") until a sibling row supplies it"
        ;;
    esac
  done
  # The mapping sub-step. In the window (a fresh deploy or a resume before HandBack) it runs MapExternals; after
  # HandBack it reads the recorded mappings back instead (T-OP-210 -- the old "ALWAYS, a no-op on a resume" was
  # wrong: MapExternals refuses a deployer without ADMIN). HandBack is NOT here (T-OP-161): the deployer registers
  # the launch set first, then the caller runs registry_env_handback. A run that stops after this line in the
  # window leaves the deployer holding ADMIN, and says so.
  externals_map_final
  if [ "${EXT_MAP_RAN:-yes}" = yes ]; then
    ext_say "summary: deployed [${EXT_DEPLOYED:-none}] reused [${EXT_REUSED:-none}] skipped [${EXT_SKIP:-none}] unsupplied [${EXT_UNSUPPLIED:-none}] selectors read back mapped $EXT_MAPPED; HAND-BACK PENDING (after RegisterMarkets; the deployer still holds ADMIN)"
  else
    ext_say "summary: deployed [${EXT_DEPLOYED:-none}] reused [${EXT_REUSED:-none}] skipped [${EXT_SKIP:-none}] unsupplied [${EXT_UNSUPPLIED:-none}] selectors read back mapped $EXT_MAPPED; window CLOSED (HandBack has run; the deployer holds no ADMIN) -- delayed admin calls in this run take the Safe's lanes"
  fi
  return 0
}
