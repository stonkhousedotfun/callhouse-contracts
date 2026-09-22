// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MakerVault} from "../../../src/v2/mm/MakerVault.sol";
import {V4PoolKey} from "../../../src/v2/periphery/BuybackDeps.sol";

/// @notice What the v2/v8 production scripts share: the environment they read, the launch values of the parameters
///         the registry does not hold, the artifact paths, the `roles.v8.json` manifest reader and the logging helpers.
///         `script/v2/DeployV8.s.sol` deploys and wires the contract set, `script/v2/RegisterMarkets.s.sol` configures
///         and registers markets, `script/v2/VerifyV2.s.sol` checks all of it read-only.
/// @dev THE NAME STAYS `V2DeployBase` ON PURPOSE. INTERFACE_VERSION 8 renamed the deploy script (`DeployV8`) and will
///      rename the verifier (`VerifyV8`, C8-10b), but the shared base keeps its name and the `V2_` environment prefix
///      keeps its: 03-INTERFACES §4 keeps the registry block named `v2`, and renaming ~100 env call sites would break
///      `DeployV2Batch.sh`'s `KEEP_OVERRIDES` handling for nothing. New names are ADDED here, never renamed.
///
///      THE REGISTRY IS NEVER PARSED IN SOLIDITY. `script/v2/DeployV2Batch.sh` reads callhouse `ops/markets/tier1.json`
///      (and `ops/markets/v2-sources.json`) with jq and exports the values below; an operator running a script by hand
///      exports the same names. Every name starts with `V2_` so the batch can drop every stale `V2_*` export of the
///      operator's shell (an env file of a v2 service sets several) before it runs forge, and so no name collides with
///      the v1 scripts' (`USDG`, `ADMIN`, `ASSET`...), which test/unit/DeploySoloPreflight.t.sol sets in the shared
///      process environment. Keys are the one exception, as in every script of this repository: `DEPLOYER_PK` and
///      `ADMIN_PK`, environment only, never a flag.
///
///      ROLES ARE NOT IN SOLIDITY EITHER. `script/v2/roles.v8.json` is the frozen source of truth for the eleven role
///      ids, their delays, the selector map, the role admins and the role guardians ({ROLES_JSON}). Everything that
///      needs one READS it at run time through the helpers in the MANIFEST section; nothing hand-types a signature.
///      `foundry.toml`'s `fs_permissions` grants read access to exactly that path.
///
///      UNITS as in src/v2: prices and ticks in USDG base units (6 dp) per share, fees and deviations in bps, delays and
///      ages in seconds, bounties and caps in USDG base units, pool liquidity in L, vault units in 0.01-share units.
abstract contract V2DeployBase is Script {
    using stdJson for string;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Robinhood Chain. Every script refuses another chain unless V2_EXPECT_CHAIN_ID says otherwise.
    uint256 public constant CHAIN_ID_4663 = 4663;

    /// @notice ERC-1155 metadata base of the Clearinghouse (INTERFACE-CHANGES v4 clarification; W2-09 serves it).
    string public constant LAUNCH_BASE_URI = "https://app.stonkhouse.fun/api/token/";

    /// @notice The frozen role manifest: ids, delays, selector map, role admins, role guardians.
    /// @dev Path from the repository root, which is the cwd of both `forge script` and `forge test`. It is listed in
    ///      `foundry.toml` `fs_permissions`; without that entry every read here fails "path is not allowed".
    string public constant ROLES_JSON = "script/v2/roles.v8.json";

    /// @notice Launch values of the parameters the registry does not carry (C2-07, C2-09, C2-10, C2-11 hand-off notes,
    ///         the F2-04 devnet). Each can be overridden through its `V2_*` variable; docs/DEPLOY-V2.md lists them.
    uint16 public constant LAUNCH_PAYOUT_SLIPPAGE_BPS = 30;
    uint256 public constant LAUNCH_BOUNTY_SNAPSHOT = 50_000;
    uint256 public constant LAUNCH_BOUNTY_FINALIZE = 50_000;
    uint256 public constant LAUNCH_BOUNTY_SETTLE = 50_000;
    uint256 public constant LAUNCH_BOUNTY_REDEEM = 20_000;
    uint256 public constant LAUNCH_BOUNTY_ROLL = 50_000;
    /// @dev INTERFACE_VERSION 7: the permissionless `AutoRoller.cancelStale` bounty, like REDEEM's, paid at most once
    ///      per ROLL (v7 design §5.2). Env `V2_BOUNTY_CANCEL_STALE`.
    uint256 public constant LAUNCH_BOUNTY_CANCEL_STALE = 20_000;
    uint256 public constant LAUNCH_KEEPER_DAILY_CAP = 100e6;
    uint64 public constant LAUNCH_VAULT_MAX_SERIES_UNITS = 10_000;
    uint128 public constant LAUNCH_VAULT_MAX_TOTAL_NOTIONAL = 250_000e6;
    uint16 public constant LAUNCH_VAULT_ASK_TOLERANCE_BPS = 100;
    uint16 public constant LAUNCH_VAULT_MAX_BID_BPS_OF_SPOT = 1000;
    uint32 public constant LAUNCH_VAULT_MAX_ORDER_LIFETIME = 0;
    /// @dev INTERFACE_VERSION 7: net USDG the MakerVault quoter may pay out at once, refilling over MakerVault
    ///      .OUTFLOW_WINDOW, so at most 2x this in any 24 h (v7 design §5.3). Env `V2_VAULT_MAX_DAILY_OUTFLOW`;
    ///      `DeployV8` requires it non-zero and `VerifyV2` FAILs on a fresh deploy that differs.
    uint128 public constant LAUNCH_VAULT_MAX_DAILY_OUTFLOW = 2_500e6;

    /*//////////////////////////////////////////////////////////////
                       FLYWHEEL LAUNCH VALUES (v8 §6)
    //////////////////////////////////////////////////////////////*/

    /// @notice Share of every FeeSplitter distribution that goes to the buyback-and-burn balance, bps; the rest goes
    ///         to the Treasury Safe. 50/50 is the owner decision recorded in V8-DESIGN.md §0 row 5 (V3-D5/D9/D11/D15).
    /// @dev There is NO compiled bound on `FeeSplitter.setBurnBps` (IFeeSplitter §setBurnBps: "fully adjustable",
    ///      V3-D25), so this launch value is the only place the 50/50 split is written down for the deploy.
    uint16 public constant LAUNCH_BURN_BPS = 5000;

    /// @notice Slippage the FeeSplitter's Stock Token conversion floor allows, bps below the oracle's ok spot.
    /// @dev Same value as the Clearinghouse payout floor; `FeeSplitter.setConversionSlippageBps` refuses anything
    ///      above `V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS`, which is the ceiling both share.
    uint16 public constant LAUNCH_CONVERSION_SLIPPAGE_BPS = 30;

    /// @notice The buyback executor's fee cap over the MEASURED total of every fee component, bps.
    /// @dev Above the 211 bps worst case of the pinned venue (1 v3 + 100 hook + 100 creator + 10 protocol ceiling)
    ///      measured by C3-602; test/v2/unit/V4BuybackExecutorBase.t.sol `FEE_CAP_BPS` uses the same number.
    uint16 public constant LAUNCH_BUYBACK_MAX_TOTAL_FEE_BPS = 250;

    /// @notice The buyback executor's v3 TWAP floor tolerance, bps, INCLUDING the v3 pool's own fee.
    /// @dev 1 bp of pool fee plus a 50 bp tolerance, the shape C3-602 used for its floor.
    uint16 public constant LAUNCH_BUYBACK_SLIPPAGE_BPS = 51;

    /// @notice The buyback executor's v3 TWAP window, seconds.
    uint32 public constant LAUNCH_BUYBACK_TWAP_WINDOW = 300;

    /// @notice Harmonic-mean in-range liquidity floor the buyback executor requires of its v3 leg, pool L units.
    uint128 public constant LAUNCH_BUYBACK_MIN_LIQUIDITY = 1e18;

    /*//////////////////////////////////////////////////////////////
                          THE COLLATERAL-RENT GUARD
    //////////////////////////////////////////////////////////////*/

    /// @dev Why a market that charges collateral rent must never be registered BY A SCRIPT (V8-DESIGN.md §4.3); the
    ///      tail of every refusal {mintFeePpmFromEnv} raises, so the deploy path says it in one voice.
    ///
    ///      THE v7 GUARD IS INVERTED HERE, NOT DELETED. v7 refused rent == 0 because `premiumFeeBps` was 0 and the
    ///      rent was the only writer fee. v8 charges 5% of the premium on first sale and launches rent at 0 on every
    ///      market, so the dangerous value is now a NON-ZERO one: rent is turned on later through
    ///      `Clearinghouse.setMarketFees` under the 72 h MARKET_FEE_MANAGER lane, where it is visible for three days
    ///      and cancellable by the guardian -- never through a deploy script, which is immediate and unreviewed.
    ///      The machinery ({rentAllowed}, {_inTestContext}) is the same unspoofable one; only the sense changed.
    string internal constant _WHY_RENT = "INTERFACE_VERSION 8 charges 5% of the premium on first sale and launches collateral rent at 0 on every market"
        " (V8-DESIGN 4.3), so a deploy script must never put a rent-bearing market on chain: turn rent on afterwards"
        " through Clearinghouse.setMarketFees under the 72 h MARKET_FEE_MANAGER lane. The rent opt-in is honoured only"
        " under forge test (the fixtures); no forge script run reaches it, whatever the RPC, the chain id or the flags.";

    /// @dev What a run that exported `V2_ALLOW_RENT` outside the forge test runner is told, so the opt-in is never
    ///      silently dropped (the v7 wording of DECISIONS-2026-09-17 §11, inverted with the guard).
    string internal constant _RENT_IGNORED = "V2_ALLOW_RENT IGNORED: the rent opt-in is a test-only code path (forge test / coverage / snapshot)."
        " A forge script run -- dry run, --broadcast or --resume -- never opts in, whatever the RPC, the chain id or"
        " the flags. Leave the rate at 0 and set it later with Clearinghouse.setMarketFees (V8-DESIGN 4.3).";

    /// @notice The deploy-time freshness bound of a Chainlink feed: the us_equities_24/5 feeds print nothing all
    ///         weekend (worst observed gap 78.24 h), so this is DeploySolo's four days, not the source's 26 h `maxStale`.
    uint32 public constant DEFAULT_MAX_FEED_AGE = 4 days;

    /*//////////////////////////////////////////////////////////////
                               ARTIFACTS
    //////////////////////////////////////////////////////////////*/

    /// @notice `forge build` artifacts the deploy creates from and the verifier compares against, in deploy order.
    /// @dev `out/AccessManager.sol/AccessManager.json` exists because `src/v2/access/V8AccessManagerArtifact.sol`
    ///      imports the UNMODIFIED OpenZeppelin contract for exactly this reason: solc only compiles what something
    ///      imports, so without that file there is no artifact for `DeployV8` to create from.
    string public constant ART_ACCESS_MANAGER = "out/AccessManager.sol/AccessManager.json";
    string public constant ART_FEE_SPLITTER = "out/FeeSplitter.sol/FeeSplitter.json";
    string public constant ART_EXPIRY_CALENDAR = "out/ExpiryCalendar.sol/ExpiryCalendar.json";
    string public constant ART_CHAINLINK_SOURCE = "out/ChainlinkFeedSource.sol/ChainlinkFeedSource.json";
    string public constant ART_UNIV3_SOURCE = "out/UniV3TwapSource.sol/UniV3TwapSource.json";
    string public constant ART_DATA_STREAMS_SOURCE = "out/DataStreamsSource.sol/DataStreamsSource.json";
    string public constant ART_SETTLEMENT_ORACLE = "out/SettlementOracle.sol/SettlementOracle.json";
    string public constant ART_KEEPER_REWARDS = "out/KeeperRewards.sol/KeeperRewards.json";
    string public constant ART_CLEARINGHOUSE = "out/Clearinghouse.sol/Clearinghouse.json";
    string public constant ART_ORDER_BOOK = "out/OrderBook.sol/OrderBook.json";
    string public constant ART_AUTO_ROLLER = "out/AutoRoller.sol/AutoRoller.json";
    string public constant ART_PAYOUT_ROUTER = "out/PayoutRouter.sol/PayoutRouter.json";
    string public constant ART_MAKER_REGISTRY = "out/MakerRegistry.sol/MakerRegistry.json";
    string public constant ART_MAKER_VAULT = "out/MakerVault.sol/MakerVault.json";
    string public constant ART_REWARDS_DISTRIBUTOR = "out/RewardsDistributor.sol/RewardsDistributor.json";
    string public constant ART_BUYBACK_EXECUTOR = "out/V4BuybackExecutor.sol/V4BuybackExecutor.json";
    // P8-06B and P8-03 added these three to `roles.v8.json` `.targets` and stopped there, which is what C8-DEPLOYVERIFY
    // is repairing. `forge` writes an artifact under `out/<file>.sol/<contract>.json` wherever the source sits, so the
    // `src/v2/periphery/` and `src/v2/periphery/house/` paths do not appear here.
    string public constant ART_HOUSE_VAULT = "out/HouseVault.sol/HouseVault.json";
    string public constant ART_HOUSE_VAULT_FACTORY = "out/HouseVaultFactory.sol/HouseVaultFactory.json";
    string public constant ART_HEDGER = "out/Hedger.sol/Hedger.json";
    // T-170 added these two to `roles.v8.json` `.targets` and stopped there, exactly as P8-06B and P8-03 had
    // done before it. `test/v2/unit/ManifestResolvers.t.sol` is what caught it this time.
    string public constant ART_EARN_VAULT = "out/EarnVault.sol/EarnVault.json";
    string public constant ART_STOCK_VENUE_ADAPTER = "out/StockVenueAdapter.sol/StockVenueAdapter.json";

    /// @dev v7 ONLY. `UniV3PayoutAdapter` left the v8 set -- `PayoutRouter` replaces it -- but the live v7 deployment
    ///      on 4663 still has one, so `VerifyV2` (C8-10b renames it `VerifyV8`) can still name its artifact while it
    ///      checks that chain. Nothing in `DeployV8` reads this.
    string public constant ART_PAYOUT_ADAPTER = "out/UniV3PayoutAdapter.sol/UniV3PayoutAdapter.json";

    /// @notice The runtimes of the set live on chain 4663, pinned from the commit that deployed it (C3-101). VerifyV2
    ///         compares an address this manifest lists, under the same registry name, with the pinned artifact instead
    ///         of `out/` -- on CHAIN_ID_4663 only; on any other chain nothing is pinned. `script/v2/pin-deployed.sh` is
    ///         its only writer, and DeployV2Batch.sh puts every file of its directory into the rehearsal fingerprint.
    string public constant PINNED_MANIFEST = "script/artifacts/v2-4663/manifest.json";

    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice The INTERFACE_VERSION 8 contract set: TWENTY-TWO contracts, of which the first sixteen are the ones
    ///         this script CREATEs IN DEPLOY ORDER, one field per registry entry, and the last six are supplied
    ///         externally -- deployed by their own tasks and arriving by `V2_*` environment variable. The split is
    ///         {_externallySupplied} in DeployV8, and it is why `CONTRACT_KEYS` in DeployV2Batch.sh is sixteen and
    ///         not twenty-two: that list is the RECORDED set this run mines and counts.
    /// @dev The order is a dependency order and `DeployV8._deploy` walks it top to bottom:
    ///        - the manager is first because every other constructor takes it as `authority`;
    ///        - the splitter is before the Clearinghouse because it IS the Clearinghouse's `feeRecipient_`, which the
    ///          constructor refuses to leave zero (src/v2/Clearinghouse.sol:205);
    ///        - the calendar is before the Clearinghouse, which requires it to have code;
    ///        - the OrderBook, the roller and the vault are after the Clearinghouse they read;
    ///        - the buyback executor is last because it pins the splitter (src/v2/periphery/V4BuybackExecutor.sol:234).
    struct Contracts {
        address accessManager; // V2_ACCESS_MANAGER       v2.contracts.accessManager   ART_ACCESS_MANAGER
        address feeSplitter; // V2_FEE_SPLITTER          v2.flywheel.feeSplitter      ART_FEE_SPLITTER
        address expiryCalendar; // V2_EXPIRY_CALENDAR       v2.contracts.expiryCalendar  ART_EXPIRY_CALENDAR
        address chainlinkSource; // V2_SOURCE_CHAINLINK      v2.contracts.sources.chainlink   ART_CHAINLINK_SOURCE
        address univ3Source; // V2_SOURCE_UNIV3          v2.contracts.sources.univ3   ART_UNIV3_SOURCE
        address dataStreamsSource; // V2_SOURCE_DATA_STREAMS   v2.contracts.sources.dataStreams ART_DATA_STREAMS_SOURCE
        address settlementOracle; // V2_SETTLEMENT_ORACLE     v2.contracts.settlementOracle    ART_SETTLEMENT_ORACLE
        address keeperRewards; // V2_KEEPER_REWARDS        v2.contracts.keeperRewards   ART_KEEPER_REWARDS
        address clearinghouse; // V2_CLEARINGHOUSE         v2.contracts.clearinghouse   ART_CLEARINGHOUSE
        address orderBook; // V2_ORDER_BOOK            v2.contracts.orderBook       ART_ORDER_BOOK
        address autoRoller; // V2_AUTO_ROLLER           v2.contracts.autoRoller      ART_AUTO_ROLLER
        // 03-INTERFACES §4: the registry KEY `payoutAdapter` is kept and now names the PayoutRouter.
        address payoutRouter; // V2_PAYOUT_ROUTER         v2.contracts.payoutAdapter   ART_PAYOUT_ROUTER
        address makerRegistry; // V2_MAKER_REGISTRY        v2.contracts.makerRegistry   ART_MAKER_REGISTRY
        address makerVault; // V2_MAKER_VAULT           v2.contracts.makerVault      ART_MAKER_VAULT
        address rewardsDistributor; // V2_REWARDS_DISTRIBUTOR   v2.contracts.rewardsDistributor  ART_REWARDS_DISTRIBUTOR
        address buybackExecutor; // V2_BUYBACK_EXECUTOR      v2.flywheel.buybackExecutor  ART_BUYBACK_EXECUTOR
        // NOT DEPLOYED BY `DeployV8`, but named by `roles.v8.json` `.targets`, so every manifest walk has to be able
        // to resolve them. They are deployed by their own tasks and supplied by address; a deploy that is asked to
        // map one it was not given REFUSES rather than mapping the zero address (see `DeployV8._mapTarget`).
        address houseVault; // V2_HOUSE_VAULT           ART_HOUSE_VAULT
        address houseVaultFactory; // V2_HOUSE_VAULT_FACTORY   ART_HOUSE_VAULT_FACTORY
        address hedger; // V2_HEDGER                ART_HEDGER
        // P8-05's SECOND `RewardsDistributor` instance: the same contract, the same artifact, a different address
        // and a different reward token. `roles.v8.json` keys it `RewardsDistributorLender`.
        address rewardsDistributorLender; // V2_LENDER_REWARDS        ART_REWARDS_DISTRIBUTOR
        address earnVault; // V2_EARN_VAULT            ART_EARN_VAULT
        address stockVenueAdapter; // V2_STOCK_VENUE_ADAPTER   ART_STOCK_VENUE_ADAPTER
    }

    /// @notice Who holds what in INTERFACE_VERSION 8. Registry `shared.safes`, `shared.feeRecipient` and `v2.bots`.
    /// @dev NO TARGET HOLDS A ROLE ANY MORE. Every entry here is a principal of the one `AccessManager`, and which
    ///      roles it gets is read from `roles.v8.json` `.holders`, never hard-coded. `deployer` holds ADMIN only
    ///      while the deploy runs and renounces it in the same batch.
    struct Roles {
        address adminSafe; // V2_ADMIN_SAFE     shared.safes.admin: ADMIN + the five delayed lanes + OPS_ADMIN
        address treasurySafe; // V2_TREASURY_SAFE  shared.safes.treasury: the only address money can leave to
        address guardianKey; // V2_GUARDIAN       v2.bots.guardian: GUARDIAN, instant
        address pricerKey; // V2_PRICER         v2.bots.pricer: PRICER, instant
        address quoterKey; // V2_MM_QUOTER      v2.bots.quoter: QUOTER, instant
        // v7 gave the cranker NO role (ADR-06). v8 gives it BUYBACK, from `roles.v8.json` `.holders.crankerKey`.
        address crankerKey; // V2_CRANKER        v2.bots.cranker: BUYBACK, instant
        // Registry `shared.feeRecipient`. It IS the FeeSplitter this run deploys; the preflight REFUSES a mismatch.
        address feeRecipient; // V2_FEE_RECIPIENT
        address deployer; // V2_DEPLOYER       the transient initial ADMIN; holds nothing when the run ends
    }

    /// @notice Addresses the set depends on and does not deploy.
    struct External {
        address usdg; // V2_USDG: registry shared.usdg
        address swapRouter02; // V2_SWAP_ROUTER02: registry v2.uniswapV3.swapRouter02
        address univ3Factory; // V2_UNIV3_FACTORY: registry v2.uniswapV3.factory (must be swapRouter02.factory())
        address dataStreamsVerifier; // V2_DATA_STREAMS_VERIFIER: v2-sources.json contracts.verifierProxy
        // INTERFACE_VERSION 8: the PayoutRouter's v4 leg and the buyback executor's, the same pair of contracts.
        address v4PoolManager; // V2_V4_POOL_MANAGER: v2-sources.json contracts.v4PoolManager
        address v4StateView; // V2_V4_STATE_VIEW: v2-sources.json contracts.v4StateView (the lens over that manager)
    }

    /// @notice Protocol parameters. `fees` and `exerciseFeeBps` come from the registry `v2.fees`; the rest from the
    ///         LAUNCH_* constants unless overridden.
    struct Params {
        V2Types.FeeParams fees; // V2_PREMIUM_FEE_BPS, V2_RESALE_FEE_BPS, V2_TAKER_FEE_FLAT, V2_TAKER_FEE_CAP_BPS,
        // V2_MAKER_REBATE_BPS
        uint16 exerciseFeeBps; // V2_EXERCISE_FEE_BPS (per market, pinned into each series)
        uint16 payoutSlippageBps; // V2_PAYOUT_SLIPPAGE_BPS
        uint256 bountySnapshot; // V2_BOUNTY_SNAPSHOT
        uint256 bountyFinalize; // V2_BOUNTY_FINALIZE
        uint256 bountySettle; // V2_BOUNTY_SETTLE
        uint256 bountyRedeem; // V2_BOUNTY_REDEEM
        uint256 bountyRoll; // V2_BOUNTY_ROLL
        uint256 bountyCancelStale; // V2_BOUNTY_CANCEL_STALE (v7)
        uint256 dailyCap; // V2_KEEPER_DAILY_CAP
        MakerVault.Limits vaultLimits; // V2_VAULT_MAX_SERIES_UNITS, V2_VAULT_MAX_TOTAL_NOTIONAL,
        // V2_VAULT_ASK_TOLERANCE_BPS, V2_VAULT_MAX_BID_BPS_OF_SPOT, V2_VAULT_MAX_ORDER_LIFETIME_S,
        // V2_VAULT_MAX_DAILY_OUTFLOW (v7)
        string baseUri; // V2_BASE_URI
    }

    /// @notice INTERFACE_VERSION 8 flywheel inputs (V8-DESIGN §6): what the FeeSplitter is configured with and what
    ///         the V4BuybackExecutor pins forever at construction.
    /// @dev The executor takes NO admin and has no setter: every field below is immutable once it is deployed, so a
    ///      wrong one is replaced by deploying a new executor and pointing the splitter at it (TREASURY_ADMIN, 24 h).
    ///      `poolKey` is the registry's `shared.token.poolKey` verbatim: `currency0` must be native ETH (address 0)
    ///      and `currency1` the STONKHOUSE token, which is also what `FeeSplitter.setToken` is given.
    struct Flywheel {
        uint16 burnBps; // V2_BURN_BPS: share of a distribution that is bought back and burned
        uint16 conversionSlippageBps; // V2_CONVERSION_SLIPPAGE_BPS: the splitter's Stock Token conversion floor
        address weth; // V2_WETH: WETH9, the buyback's middle leg
        address v3UsdgWethPool; // V2_BUYBACK_V3_POOL: the USDG/WETH v3 pool the first leg swaps and reads its TWAP in
        V4PoolKey poolKey; // V2_TOKEN_POOL_*: shared.token.poolKey, the ONE v4 pool the token is bought on
        uint16 maxTotalFeeBps; // V2_BUYBACK_MAX_TOTAL_FEE_BPS
        uint16 maxSlippageBps; // V2_BUYBACK_SLIPPAGE_BPS
        uint32 twapWindow; // V2_BUYBACK_TWAP_WINDOW_S
        uint128 minLiquidity; // V2_BUYBACK_MIN_LIQUIDITY
    }

    /// @notice One market, from its registry row: `asset`, `feed`, `v2.univ3Pool`, `v2.univ3MinLiquidity`,
    ///         `v2.strikeTick`, `v2.defaults` merged with `v2.overrides`, and the pool's fee from v2-sources.json.
    struct MarketIn {
        string ticker; // V2_TICKERS entry
        address asset; // V2_MARKET_<T>_ASSET
        address feed; // V2_MARKET_<T>_FEED
        address pool; // V2_MARKET_<T>_POOL, zero or unset = Chainlink only, no payout route
        uint128 minLiquidity; // V2_MARKET_<T>_MIN_LIQUIDITY, pool L units (0 without a pool)
        uint24 poolFee; // V2_MARKET_<T>_POOL_FEE, 0 = read from the pool
        uint64 strikeTick; // V2_MARKET_<T>_STRIKE_TICK
        uint16 maxDeviationBps; // V2_MARKET_<T>_MAX_DEVIATION_BPS
        uint32 uncorroboratedDelay; // V2_MARKET_<T>_UNCORROBORATED_DELAY_S
        uint32 spotMaxAge; // V2_MARKET_<T>_SPOT_MAX_AGE_S
        bool enabled; // V2_MARKET_<T>_ENABLED: registry v2.status == live (C3-102 staged listing)
        // `pool` is the SETTLEMENT univ3 pool, NOT the payout route. The payout route is
        // `markets[].v2.payoutRoute` (RegisterMarkets.s.sol:763-764: "Payout is markets[].v2.payoutRoute
        // (O8-03), NOT the settlement univ3Pool") and is the four fields below.
        uint8 payoutVenue; // V2_MARKET_<T>_PAYOUT_VENUE: 0 none, 1 v3, 2 v4 (IPayoutRouter.Venue)
        uint24 payoutFee; // V2_MARKET_<T>_PAYOUT_FEE, 0 when the venue is none
        int24 payoutTickSpacing; // V2_MARKET_<T>_PAYOUT_TICK_SPACING, v4 only
        bytes32 payoutPoolId; // V2_MARKET_<T>_PAYOUT_POOL_ID, v4 only: the PINNED pool the key must hash to
    }

    /// @notice A broadcaster: a key from the environment, or (pk == 0) an address the node has unlocked, which is how
    ///         `DeployV2Batch.sh --rehearse` impersonates the registry admin on an anvil fork.
    struct Signer {
        uint256 pk;
        address addr;
    }

    /// @notice One admin transaction, built from a read of the chain so a re-run sends only what is still missing.
    struct Call {
        address to;
        bytes data;
        string what;
    }

    /*//////////////////////////////////////////////////////////////
                               ENVIRONMENT
    //////////////////////////////////////////////////////////////*/

    function contractsFromEnv() public view returns (Contracts memory c) {
        c.accessManager = vm.envOr("V2_ACCESS_MANAGER", address(0));
        c.feeSplitter = vm.envOr("V2_FEE_SPLITTER", address(0));
        c.expiryCalendar = vm.envOr("V2_EXPIRY_CALENDAR", address(0));
        c.chainlinkSource = vm.envOr("V2_SOURCE_CHAINLINK", address(0));
        c.univ3Source = vm.envOr("V2_SOURCE_UNIV3", address(0));
        c.dataStreamsSource = vm.envOr("V2_SOURCE_DATA_STREAMS", address(0));
        c.settlementOracle = vm.envOr("V2_SETTLEMENT_ORACLE", address(0));
        c.keeperRewards = vm.envOr("V2_KEEPER_REWARDS", address(0));
        c.clearinghouse = vm.envOr("V2_CLEARINGHOUSE", address(0));
        c.orderBook = vm.envOr("V2_ORDER_BOOK", address(0));
        c.autoRoller = vm.envOr("V2_AUTO_ROLLER", address(0));
        // ADDED, never renamed: `V2_PAYOUT_ADAPTER` still names the v7 adapter on live 4663, so the v8 router gets
        // its own name and an operator resuming a v7 set cannot accidentally feed it to a v8 run.
        c.payoutRouter = vm.envOr("V2_PAYOUT_ROUTER", address(0));
        c.makerRegistry = vm.envOr("V2_MAKER_REGISTRY", address(0));
        c.makerVault = vm.envOr("V2_MAKER_VAULT", address(0));
        c.rewardsDistributor = vm.envOr("V2_REWARDS_DISTRIBUTOR", address(0));
        c.buybackExecutor = vm.envOr("V2_BUYBACK_EXECUTOR", address(0));
        c.houseVault = vm.envOr("V2_HOUSE_VAULT", address(0));
        c.houseVaultFactory = vm.envOr("V2_HOUSE_VAULT_FACTORY", address(0));
        c.hedger = vm.envOr("V2_HEDGER", address(0));
        c.rewardsDistributorLender = vm.envOr("V2_LENDER_REWARDS", address(0));
        c.earnVault = vm.envOr("V2_EARN_VAULT", address(0));
        c.stockVenueAdapter = vm.envOr("V2_STOCK_VENUE_ADAPTER", address(0));
    }

    /// @notice The eight v8 principals. `V2_ADMIN_SAFE` and `V2_TREASURY_SAFE` are new; the four bot names and
    ///         `V2_FEE_RECIPIENT` keep their v7 spelling so DeployV2Batch.sh's exports do not have to move.
    /// @dev `V2_DEPLOYER` is optional here and defaults to zero: `DeployV8.run()` fills it from `DEPLOYER_PK` (or from
    ///      the unlocked sender of a rehearsal) before the preflight sees it, which is the only place that knows it.
    function rolesFromEnv() public view returns (Roles memory r) {
        r.adminSafe = vm.envAddress("V2_ADMIN_SAFE");
        r.treasurySafe = vm.envAddress("V2_TREASURY_SAFE");
        r.guardianKey = vm.envAddress("V2_GUARDIAN");
        r.pricerKey = vm.envAddress("V2_PRICER");
        r.quoterKey = vm.envAddress("V2_MM_QUOTER");
        r.crankerKey = vm.envAddress("V2_CRANKER");
        // OPTIONAL ON PURPOSE. `shared.feeRecipient` IS the FeeSplitter this run deploys, so on a fresh
        // deploy nobody can know it yet and the registry carries null; DeployV8 documents unset as
        // "whatever this run creates" and fills it in, then refuses a mismatch on a resume. Reading it
        // with envAddress made that documented path revert before the run started.
        r.feeRecipient = vm.envOr("V2_FEE_RECIPIENT", address(0));
        r.deployer = vm.envOr("V2_DEPLOYER", address(0));
    }

    function externalFromEnv() public view returns (External memory e) {
        e.usdg = vm.envAddress("V2_USDG");
        e.swapRouter02 = vm.envAddress("V2_SWAP_ROUTER02");
        e.univ3Factory = vm.envAddress("V2_UNIV3_FACTORY");
        e.dataStreamsVerifier = vm.envAddress("V2_DATA_STREAMS_VERIFIER");
        e.v4PoolManager = vm.envAddress("V2_V4_POOL_MANAGER");
        e.v4StateView = vm.envAddress("V2_V4_STATE_VIEW");
    }

    function paramsFromEnv() public view returns (Params memory p) {
        p.fees = V2Types.FeeParams({
            premiumFeeBps: _u16(vm.envUint("V2_PREMIUM_FEE_BPS"), "V2_PREMIUM_FEE_BPS"),
            resaleFeeBps: _u16(vm.envUint("V2_RESALE_FEE_BPS"), "V2_RESALE_FEE_BPS"),
            takerFeeFlat: _u32(vm.envUint("V2_TAKER_FEE_FLAT"), "V2_TAKER_FEE_FLAT"),
            takerFeeCapBps: _u16(vm.envUint("V2_TAKER_FEE_CAP_BPS"), "V2_TAKER_FEE_CAP_BPS"),
            makerRebateBps: _u16(vm.envUint("V2_MAKER_REBATE_BPS"), "V2_MAKER_REBATE_BPS")
        });
        p.exerciseFeeBps = _u16(vm.envUint("V2_EXERCISE_FEE_BPS"), "V2_EXERCISE_FEE_BPS");
        p.payoutSlippageBps =
            _u16(vm.envOr("V2_PAYOUT_SLIPPAGE_BPS", uint256(LAUNCH_PAYOUT_SLIPPAGE_BPS)), "V2_PAYOUT_SLIPPAGE_BPS");
        p.bountySnapshot = vm.envOr("V2_BOUNTY_SNAPSHOT", LAUNCH_BOUNTY_SNAPSHOT);
        p.bountyFinalize = vm.envOr("V2_BOUNTY_FINALIZE", LAUNCH_BOUNTY_FINALIZE);
        p.bountySettle = vm.envOr("V2_BOUNTY_SETTLE", LAUNCH_BOUNTY_SETTLE);
        p.bountyRedeem = vm.envOr("V2_BOUNTY_REDEEM", LAUNCH_BOUNTY_REDEEM);
        p.bountyRoll = vm.envOr("V2_BOUNTY_ROLL", LAUNCH_BOUNTY_ROLL);
        p.bountyCancelStale = vm.envOr("V2_BOUNTY_CANCEL_STALE", LAUNCH_BOUNTY_CANCEL_STALE);
        p.dailyCap = vm.envOr("V2_KEEPER_DAILY_CAP", LAUNCH_KEEPER_DAILY_CAP);
        p.vaultLimits = MakerVault.Limits({
            maxSeriesUnits: _u64(
                vm.envOr("V2_VAULT_MAX_SERIES_UNITS", uint256(LAUNCH_VAULT_MAX_SERIES_UNITS)),
                "V2_VAULT_MAX_SERIES_UNITS"
            ),
            maxTotalNotional: _u128(
                vm.envOr("V2_VAULT_MAX_TOTAL_NOTIONAL", uint256(LAUNCH_VAULT_MAX_TOTAL_NOTIONAL)),
                "V2_VAULT_MAX_TOTAL_NOTIONAL"
            ),
            askToleranceBps: _u16(
                vm.envOr("V2_VAULT_ASK_TOLERANCE_BPS", uint256(LAUNCH_VAULT_ASK_TOLERANCE_BPS)),
                "V2_VAULT_ASK_TOLERANCE_BPS"
            ),
            maxBidBpsOfSpot: _u16(
                vm.envOr("V2_VAULT_MAX_BID_BPS_OF_SPOT", uint256(LAUNCH_VAULT_MAX_BID_BPS_OF_SPOT)),
                "V2_VAULT_MAX_BID_BPS_OF_SPOT"
            ),
            maxOrderLifetime: _u32(
                vm.envOr("V2_VAULT_MAX_ORDER_LIFETIME_S", uint256(LAUNCH_VAULT_MAX_ORDER_LIFETIME)),
                "V2_VAULT_MAX_ORDER_LIFETIME_S"
            ),
            maxDailyOutflow: _u128(
                vm.envOr("V2_VAULT_MAX_DAILY_OUTFLOW", uint256(LAUNCH_VAULT_MAX_DAILY_OUTFLOW)),
                "V2_VAULT_MAX_DAILY_OUTFLOW"
            )
        });
        p.baseUri = vm.envOr("V2_BASE_URI", string(LAUNCH_BASE_URI));
    }

    /// @notice The flywheel inputs: the splitter's two dials and everything the buyback executor pins forever.
    /// @dev `V2_TOKEN_POOL_CURRENCY0` is required to be native ETH by the executor's own constructor
    ///      (src/v2/periphery/V4BuybackExecutor.sol:235); it is read rather than assumed so a registry that moves it
    ///      is refused by the contract instead of silently re-derived here.
    function flywheelFromEnv() public view returns (Flywheel memory f) {
        f.burnBps = _u16(vm.envOr("V2_BURN_BPS", uint256(LAUNCH_BURN_BPS)), "V2_BURN_BPS");
        f.conversionSlippageBps = _u16(
            vm.envOr("V2_CONVERSION_SLIPPAGE_BPS", uint256(LAUNCH_CONVERSION_SLIPPAGE_BPS)),
            "V2_CONVERSION_SLIPPAGE_BPS"
        );
        f.weth = vm.envAddress("V2_WETH");
        f.v3UsdgWethPool = vm.envAddress("V2_BUYBACK_V3_POOL");
        f.poolKey = V4PoolKey({
            currency0: vm.envOr("V2_TOKEN_POOL_CURRENCY0", address(0)),
            currency1: vm.envAddress("V2_TOKEN_POOL_CURRENCY1"),
            fee: _u24(vm.envUint("V2_TOKEN_POOL_FEE"), "V2_TOKEN_POOL_FEE"),
            tickSpacing: _i24(vm.envInt("V2_TOKEN_POOL_TICK_SPACING"), "V2_TOKEN_POOL_TICK_SPACING"),
            hooks: vm.envAddress("V2_TOKEN_POOL_HOOKS")
        });
        f.maxTotalFeeBps = _u16(
            vm.envOr("V2_BUYBACK_MAX_TOTAL_FEE_BPS", uint256(LAUNCH_BUYBACK_MAX_TOTAL_FEE_BPS)),
            "V2_BUYBACK_MAX_TOTAL_FEE_BPS"
        );
        f.maxSlippageBps =
            _u16(vm.envOr("V2_BUYBACK_SLIPPAGE_BPS", uint256(LAUNCH_BUYBACK_SLIPPAGE_BPS)), "V2_BUYBACK_SLIPPAGE_BPS");
        f.twapWindow =
            _u32(vm.envOr("V2_BUYBACK_TWAP_WINDOW_S", uint256(LAUNCH_BUYBACK_TWAP_WINDOW)), "V2_BUYBACK_TWAP_WINDOW_S");
        f.minLiquidity = _u128(
            vm.envOr("V2_BUYBACK_MIN_LIQUIDITY", uint256(LAUNCH_BUYBACK_MIN_LIQUIDITY)), "V2_BUYBACK_MIN_LIQUIDITY"
        );
    }

    /// @notice The collateral-rent rate each market is registered with (INTERFACE_VERSION 8: 0 on every market).
    /// @dev `V2_MARKET_<T>_MINT_FEE_PPM` over the shared `V2_MINT_FEE_PPM` over 0, so a batch that exports one rate per
    ///      market and a run that exports a single default both work; that is the registry's `v2.overrides` over
    ///      `v2.defaults` shape. `RegisterMarkets` refuses a rate above `V2Constants.MINT_FEE_CEIL_PPM` in its
    ///      preflight, before anything is broadcast, and `VerifyV2` compares the live `MarketConfig.mintFeePpm`
    ///      against these.
    ///
    ///      THE v7 GUARD IS INVERTED (V8-DESIGN.md §4.3). v7 refused an ABSENT or ZERO rate because the rent was then
    ///      the only writer fee. v8 takes 5% of the premium on first sale and launches rent at 0 everywhere, so 0 is
    ///      now the expected value and a NON-ZERO one is what must never reach the chain from a script: rent is a
    ///      72 h MARKET_FEE_MANAGER operation, visible and cancellable, and a deploy script is neither.
    ///      {rentAllowed} is the one way through and it answers true only under the forge TEST runner, so no
    ///      `forge script` run -- dry run, `--broadcast` or `--resume` -- can take it, whatever the RPC or chain id.
    /// @param ms The markets, in V2_TICKERS order.
    /// @return ppm Millionths of the locked collateral per MINT_FEE_PERIOD of remaining life, parallel to `ms`.
    function mintFeePpmFromEnv(MarketIn[] memory ms) public view returns (uint32[] memory ppm) {
        bool allowRent = allowRentFromEnv();
        (bool hasShared, uint256 shared) = _envUintIfSet("V2_MINT_FEE_PPM");
        ppm = new uint32[](ms.length);
        for (uint256 i; i < ms.length; ++i) {
            string memory key = _mk(ms[i].ticker, "MINT_FEE_PPM");
            (bool has, uint256 raw) = _envUintIfSet(key);
            // An absent rate is 0, which is the v8 launch value: absence is no longer a refusal, it is the default.
            ppm[i] = _u32(has ? raw : (hasShared ? shared : 0), has ? key : "V2_MINT_FEE_PPM");
            require(
                ppm[i] == 0 || allowRent,
                string.concat(
                    ms[i].ticker, ": collateral rent rate is ", vm.toString(uint256(ppm[i])), ", not 0. ", _WHY_RENT
                )
            );
        }
    }

    /// @notice Whether this run may register or verify a market that charges its writers collateral rent.
    /// @dev `V2_ALLOW_RENT` names the intent; {rentAllowed} decides, and it answers true only under the forge TEST
    ///      runner. An unset or empty variable, "false" and "0" are all off, so a shell that exports the name blank
    ///      (the batch clears every stale `V2_*`) never opts in by accident.
    function allowRentFromEnv() public view returns (bool) {
        if (!vm.envExists("V2_ALLOW_RENT")) return false;
        string memory raw = vm.envString("V2_ALLOW_RENT");
        if (bytes(raw).length == 0 || _eq(raw, "false") || _eq(raw, "0")) return false;
        return rentAllowed(true);
    }

    /// @notice Whether this run is the forge TEST runner rather than one of the deploy scripts.
    /// @dev THE RENT OPT-IN HANGS OFF THIS. `vm.isContext` is answered by the forge binary from the SUBCOMMAND it is
    ///      running: `forge test`, `forge coverage` and `forge snapshot` are the TestGroup, and `forge script` reports
    ///      ScriptDryRun, ScriptBroadcast or ScriptResume and never TestGroup. No environment variable, wrapper flag,
    ///      `--rpc-url`, chain id, fork or block timestamp can make a script run look like a test one, which is what
    ///      the other candidates could not promise: a fork of 4663 keeps chain id 4663, and a fresh fork's head block
    ///      is minutes old, so neither the chain id nor the clock separates a rehearsal from the live chain. The
    ///      subcommand does.
    ///
    ///      `virtual` only so the suite can drive the SCRIPT-context branches
    ///      (test/v2/unit/ZeroRentLocality.t.sol overrides it to false). The override can only ever TIGHTEN --
    ///      nothing anywhere overrides it to true -- so pointing `forge script` at a test double is refused exactly
    ///      like pointing it at the real script.
    function _inTestContext() internal view virtual returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.TestGroup);
    }

    /// @notice The one gate every rent opt-in passes through, however it arrived: the environment (`V2_ALLOW_RENT`)
    ///         or an `Inputs` built in Solidity (the fixtures).
    /// @dev Outside the forge test runner the answer is always false, and the run is told so by name rather than
    ///      quietly ignoring what the operator asked for.
    function rentAllowed(bool requested) public view returns (bool) {
        if (!requested) return false;
        if (_inTestContext()) return true;
        _warn(_RENT_IGNORED);
        return false;
    }

    /// @dev `(true, value)` when `name` is exported with a non-empty value, `(false, 0)` otherwise. `vm.envExists` is
    ///      true for a name exported blank, which is how a cleared variable reaches a forge script.
    function _envUintIfSet(string memory name) internal view returns (bool set, uint256 value) {
        if (!vm.envExists(name)) return (false, 0);
        if (bytes(vm.envString(name)).length == 0) return (false, 0);
        return (true, vm.envUint(name));
    }

    /// @notice NYSE full-day closures as day indexes (v2-sources.json `nyseHolidays.*.fullDays[].dayIndex`).
    function holidaysFromEnv() public view returns (uint32[] memory days_) {
        uint256[] memory raw = vm.envUint("V2_HOLIDAYS", ",");
        days_ = new uint32[](raw.length);
        for (uint256 i; i < raw.length; ++i) {
            days_[i] = _u32(raw[i], "V2_HOLIDAYS entry");
        }
    }

    /// @notice The markets named in V2_TICKERS, each from its V2_MARKET_<TICKER>_* variables.
    function marketsFromEnv() public view returns (MarketIn[] memory ms) {
        string[] memory tickers = vm.envString("V2_TICKERS", ",");
        ms = new MarketIn[](tickers.length);
        for (uint256 i; i < tickers.length; ++i) {
            string memory t = tickers[i];
            ms[i] = MarketIn({
                ticker: t,
                asset: vm.envAddress(_mk(t, "ASSET")),
                feed: vm.envAddress(_mk(t, "FEED")),
                pool: vm.envOr(_mk(t, "POOL"), address(0)),
                minLiquidity: _u128(vm.envOr(_mk(t, "MIN_LIQUIDITY"), uint256(0)), _mk(t, "MIN_LIQUIDITY")),
                poolFee: _u24(vm.envOr(_mk(t, "POOL_FEE"), uint256(0)), _mk(t, "POOL_FEE")),
                strikeTick: _u64(vm.envUint(_mk(t, "STRIKE_TICK")), _mk(t, "STRIKE_TICK")),
                maxDeviationBps: _u16(vm.envUint(_mk(t, "MAX_DEVIATION_BPS")), _mk(t, "MAX_DEVIATION_BPS")),
                uncorroboratedDelay: _u32(
                    vm.envUint(_mk(t, "UNCORROBORATED_DELAY_S")), _mk(t, "UNCORROBORATED_DELAY_S")
                ),
                spotMaxAge: _u32(vm.envUint(_mk(t, "SPOT_MAX_AGE_S")), _mk(t, "SPOT_MAX_AGE_S")),
                // C3-102: fail closed. A missing V2_MARKET_<T>_ENABLED must not register a planned
                // market enabled (the previous `true` default) and must not make VerifyV2 FAIL a
                // correctly disabled row. DeployV2Batch always exports the registry derivation.
                enabled: vm.envOr(_mk(t, "ENABLED"), false),
                payoutVenue: payoutVenueOf(t),
                payoutFee: payoutFeeOf(t),
                payoutTickSpacing: payoutTickSpacingOf(t),
                payoutPoolId: payoutPoolIdOf(t)
            });
        }
    }

    /*//////////////////////////////////////////////////////////////
                         ROLE MANIFEST (roles.v8.json)
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                      THE PAYOUT ROUTE, PER TICKER
    //////////////////////////////////////////////////////////////*/

    /// @notice The payout route of one ticker, from `V2_MARKET_<T>_PAYOUT_*`, which `DeployV2Batch.sh:605-618`
    ///         exports from `markets[].v2.payoutRoute`.
    /// @dev THESE ARE THE READERS BEHIND THE {MarketIn} FIELDS OF THE SAME NAME. {marketsFromEnv} calls each one
    ///      once per ticker; every consumer reads `m.payout*` off the struct rather than calling these again, so
    ///      the env spelling is decoded in exactly one place.
    ///
    ///      An earlier revision of this comment claimed the fields could not live on {MarketIn} because it "is
    ///      constructed with NAMED ARGUMENTS in `RegisterMarkets.s.sol`", which this task does not own. THAT WAS
    ///      FALSE and it is worth recording why, because it nearly cost this task its seventh criterion:
    ///      `RegisterMarkets.s.sol` takes `MarketIn` as a PARAMETER in seventeen places and constructs it in
    ///      none, and the `MarketIn({...})` literals in `DevDeploy.s.sol` and `DevDeployFork.t.sol` belong to
    ///      `DevDeploy`'s OWN struct (`DevDeploy.s.sol:160`), which is a different type -- `DevDeploy is Script`,
    ///      not `V2DeployBase`. The only construction sites of THIS struct are {marketsFromEnv} below and the two
    ///      in `test/v2/unit/DeployV2Fixture.t.sol`. A comment asserting a blocker nobody re-checked is the same
    ///      failure as the constructor comment this task was opened to delete.
    ///
    ///      `script/v2/RegisterMarkets.s.sol:818-827` still holds a parallel `_payoutVenue`. This mirrors it RULE
    ///      FOR RULE -- same accepted spellings, same revert text -- and names those lines so the two cannot drift
    ///      unnoticed. A follow-up that owns that file should delete its copy and read `m.payoutVenue` instead.

    /// @notice `V2_MARKET_<T>_PAYOUT_VENUE`: unset/empty/none/null = 0, v3 = 1, v4 = 2 (`IPayoutRouter.Venue`).
    function payoutVenueOf(string memory ticker) internal view returns (uint8) {
        if (!vm.envExists(_mk(ticker, "PAYOUT_VENUE"))) return 0;
        string memory v = vm.envString(_mk(ticker, "PAYOUT_VENUE"));
        if (bytes(v).length == 0 || _eq(v, "none") || _eq(v, "null")) return 0;
        if (_eq(v, "v3")) return 1;
        if (_eq(v, "v4")) return 2;
        revert(string.concat(ticker, ": PAYOUT_VENUE must be none|v3|v4, got ", v));
    }

    /// @notice `V2_MARKET_<T>_PAYOUT_FEE`, 0 when the venue is none.
    function payoutFeeOf(string memory ticker) internal view returns (uint24) {
        return _u24(vm.envOr(_mk(ticker, "PAYOUT_FEE"), uint256(0)), _mk(ticker, "PAYOUT_FEE"));
    }

    /// @notice `V2_MARKET_<T>_PAYOUT_TICK_SPACING`, v4 only.
    function payoutTickSpacingOf(string memory ticker) internal view returns (int24) {
        return _i24(vm.envOr(_mk(ticker, "PAYOUT_TICK_SPACING"), int256(0)), _mk(ticker, "PAYOUT_TICK_SPACING"));
    }

    /// @notice `V2_MARKET_<T>_PAYOUT_POOL_ID`, v4 only: the pool the route's `(asset, usdg, fee, tickSpacing)`
    ///         key MUST hash to. Zero when unset, which for a v4 venue is a refusal, not a default -- see
    ///         `VerifyV8._routeAndSettlementPool`. `DeployV2Batch.sh:618` exports it, or unsets it when the
    ///         registry row has none, so absence keeps its meaning.
    function payoutPoolIdOf(string memory ticker) internal view returns (bytes32) {
        return vm.envOr(_mk(ticker, "PAYOUT_POOL_ID"), bytes32(0));
    }

    /// @notice The frozen role manifest as a string, read from {ROLES_JSON} at run time.
    /// @dev EVERY consumer reads it here rather than mirroring the table in Solidity. `src/v2/access/V8Roles.sol` is a
    ///      compiled mirror for the CONTRACTS' benefit and test/v2/lib/V8Access.sol asserts the two agree; a script
    ///      that hand-typed a third copy would be the drift source the freeze exists to prevent.
    function rolesJson() public view returns (string memory) {
        return vm.readFile(ROLES_JSON);
    }

    /// @notice The `uint64` id of a role named in `.roles`.
    function roleIdOf(string memory json, string memory roleName) public pure returns (uint64) {
        return _u64(json.readUint(string.concat(".roles.", roleName)), string.concat("roles.", roleName));
    }

    /// @notice The execution delay `roleName` is granted with, seconds, from `.delaysS`.
    function roleDelayOf(string memory json, string memory roleName) public pure returns (uint32) {
        return _u32(json.readUint(string.concat(".delaysS.", roleName)), string.concat("delaysS.", roleName));
    }

    /// @notice The role name a target's signature is mapped to, from `.targets.<target>`.
    /// @dev A manifest key is a full signature -- `setTier(address,uint16)` -- and the parens and commas are not valid
    ///      in dotted JSON-path notation, so the key MUST be quoted in bracket form. The dotted form fails with
    ///      "must return exactly one JSON value", which reads like a missing key rather than a syntax problem; that is
    ///      why this is spelled out here and why nothing builds the path by hand. Mirrors test/v2/lib/V8Access.sol:106.
    function roleNameOfSig(string memory json, string memory targetName, string memory sig)
        public
        pure
        returns (string memory)
    {
        return json.readString(string.concat(".targets.", targetName, '["', sig, '"]'));
    }

    /// @notice Every signature listed for `targetName`, in manifest order.
    function targetSigs(string memory json, string memory targetName) public pure returns (string[] memory) {
        return vm.parseJsonKeys(json, string.concat(".targets.", targetName));
    }

    /// @notice Every target name in `.targets`, in manifest order.
    function targetNames(string memory json) public pure returns (string[] memory) {
        return vm.parseJsonKeys(json, ".targets");
    }

    /// @notice Every principal name in `.holders`, in manifest order.
    function holderNames(string memory json) public pure returns (string[] memory) {
        return vm.parseJsonKeys(json, ".holders");
    }

    /// @notice The role names `holderName` holds, from `.holders.<holderName>`.
    function holderRoles(string memory json, string memory holderName) public pure returns (string[] memory) {
        return json.readStringArray(string.concat(".holders.", holderName));
    }

    /// @notice Every role name in `.roleAdmin`, and every role name in `.roleGuardian`.
    function roleAdminNames(string memory json) public pure returns (string[] memory) {
        return vm.parseJsonKeys(json, ".roleAdmin");
    }

    function roleGuardianNames(string memory json) public pure returns (string[] memory) {
        return vm.parseJsonKeys(json, ".roleGuardian");
    }

    /// @notice The role name that administers / guards `roleName`.
    function roleAdminOf(string memory json, string memory roleName) public pure returns (string memory) {
        return json.readString(string.concat(".roleAdmin.", roleName));
    }

    function roleGuardianOf(string memory json, string memory roleName) public pure returns (string memory) {
        return json.readString(string.concat(".roleGuardian.", roleName));
    }

    /// @notice The four-byte selector of a manifest signature.
    /// @dev The signature string is the source of truth; the selector is DERIVED from it here and never typed.
    function selectorOf(string memory sig) public pure returns (bytes4) {
        return bytes4(keccak256(bytes(sig)));
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev `V2_MARKET_<ticker>_<field>`.
    function _mk(string memory ticker, string memory field) internal pure returns (string memory) {
        return string.concat("V2_MARKET_", ticker, "_", field);
    }

    function _startBroadcast(Signer memory s) internal {
        if (s.pk != 0) vm.startBroadcast(s.pk);
        else vm.startBroadcast(s.addr);
    }

    /// @dev Sends `calls` from `s`, each required to succeed; the revert names the call.
    function _execute(Signer memory s, Call[] memory calls) internal {
        if (calls.length == 0) return;
        _startBroadcast(s);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = calls[i].to.call(calls[i].data);
            require(ok, string.concat("admin call reverted: ", calls[i].what));
        }
        vm.stopBroadcast();
    }

    /// @dev Copies the first `n` entries of `buf`.
    function _trim(Call[] memory buf, uint256 n) internal pure returns (Call[] memory calls) {
        calls = new Call[](n);
        for (uint256 i; i < n; ++i) {
            calls[i] = buf[i];
        }
    }

    function _ok(string memory what) internal pure {
        console2.log(string.concat("  ok    ", what));
    }

    function _warn(string memory what) internal pure {
        console2.log(string.concat("  WARN  ", what));
    }

    function _skip(string memory what) internal pure {
        console2.log(string.concat("  skip  ", what));
    }

    function _code(address a, string memory name) internal view {
        require(a != address(0), string.concat(name, " is zero"));
        require(a.code.length != 0, string.concat(name, " ", vm.toString(a), " has no code"));
    }

    function _nonZero(address a, string memory name) internal pure {
        require(a != address(0), string.concat(name, " is zero"));
    }

    /// @dev Substring test (feed descriptions are "RHNVDA / USD" or "Robinhood TSLA / USD"). An empty needle matches
    ///      nothing, so an empty ticker is never a wildcard.
    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i; i + n.length <= h.length; ++i) {
            bool same = true;
            for (uint256 k; same && k < n.length; ++k) {
                if (h[i + k] != n[k]) same = false;
            }
            if (same) return true;
        }
        return false;
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _u16(uint256 v, string memory name) internal pure returns (uint16) {
        require(v <= type(uint16).max, string.concat(name, " does not fit uint16"));
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(v);
    }

    function _u24(uint256 v, string memory name) internal pure returns (uint24) {
        require(v <= type(uint24).max, string.concat(name, " does not fit uint24"));
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(v);
    }

    /// @dev A Uniswap tick spacing is signed and always positive in practice; the bounds are checked rather than
    ///      assumed so a registry typo cannot wrap into a huge negative spacing inside the pinned PoolKey.
    function _i24(int256 v, string memory name) internal pure returns (int24) {
        require(v >= type(int24).min && v <= type(int24).max, string.concat(name, " does not fit int24"));
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(v);
    }

    function _u32(uint256 v, string memory name) internal pure returns (uint32) {
        require(v <= type(uint32).max, string.concat(name, " does not fit uint32"));
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(v);
    }

    function _u64(uint256 v, string memory name) internal pure returns (uint64) {
        require(v <= type(uint64).max, string.concat(name, " does not fit uint64"));
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(v);
    }

    function _u128(uint256 v, string memory name) internal pure returns (uint128) {
        require(v <= type(uint128).max, string.concat(name, " does not fit uint128"));
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(v);
    }

    /// @dev Fee parameters under the V2Constants ceilings, with a message naming the first one above its ceiling.
    function _checkFees(V2Types.FeeParams memory f) internal pure {
        require(f.premiumFeeBps <= V2Constants.PREMIUM_FEE_CEIL_BPS, "premiumFeeBps above PREMIUM_FEE_CEIL_BPS (1000)");
        require(f.resaleFeeBps <= V2Constants.PREMIUM_FEE_CEIL_BPS, "resaleFeeBps above PREMIUM_FEE_CEIL_BPS (1000)");
        // INTERFACE_VERSION 8: `require(f.premiumFeeBps <= f.resaleFeeBps)` WAS HERE AND IS DELETED DELIBERATELY.
        // v7 refused a premium fee above the resale fee because writing into a one-tick bid of your own second
        // wallet and reselling the long dodged the larger of the two. v8 launches premium 500 / resale 0, so that
        // require would refuse the launch configuration itself. V8-DESIGN.md §4.3 records the owner's decision to
        // LEAVE THAT DODGE OPEN and charge no rent for it: it costs only the 5% on writers who bother, the
        // protocol's own MakerVault and AutoRoller writers cannot do it, and the indexer flags the pattern so it can
        // be measured. Do not "restore" this check -- restoring it breaks the launch fee table.
        require(f.takerFeeFlat <= V2Constants.TAKER_FEE_FLAT_CEIL, "takerFeeFlat above TAKER_FEE_FLAT_CEIL (1000000)");
        require(
            f.takerFeeCapBps <= V2Constants.TAKER_FEE_CAP_CEIL_BPS, "takerFeeCapBps above TAKER_FEE_CAP_CEIL_BPS (1000)"
        );
        require(f.makerRebateBps <= V2Constants.BPS, "makerRebateBps above 10000");
    }
}
