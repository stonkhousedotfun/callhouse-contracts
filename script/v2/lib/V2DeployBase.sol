// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MakerVault} from "../../../src/v2/mm/MakerVault.sol";

/// @notice What the three v2 production scripts share: the environment they read, the launch values of the parameters
///         the registry does not hold, the artifact paths and the logging helpers.
///         `script/v2/DeployV2.s.sol` deploys and wires the contract set, `script/v2/RegisterMarkets.s.sol` configures
///         and registers markets, `script/v2/VerifyV2.s.sol` checks all of it read-only.
/// @dev THE REGISTRY IS NEVER PARSED IN SOLIDITY. `script/v2/DeployV2Batch.sh` reads callhouse `ops/markets/tier1.json`
///      (and `ops/markets/v2-sources.json`) with jq and exports the values below; an operator running a script by hand
///      exports the same names. Every name starts with `V2_` so the batch can drop every stale `V2_*` export of the
///      operator's shell (an env file of a v2 service sets several) before it runs forge, and so no name collides with
///      the v1 scripts' (`USDG`, `ADMIN`, `ASSET`...), which test/unit/DeploySoloPreflight.t.sol sets in the shared
///      process environment. Keys are the one exception, as in every script of this repository: `DEPLOYER_PK` and
///      `ADMIN_PK`, environment only, never a flag.
///
///      UNITS as in src/v2: prices and ticks in USDG base units (6 dp) per share, fees and deviations in bps, delays and
///      ages in seconds, bounties and caps in USDG base units, pool liquidity in L, vault units in 0.01-share units.
abstract contract V2DeployBase is Script {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Robinhood Chain. Every script refuses another chain unless V2_EXPECT_CHAIN_ID says otherwise.
    uint256 public constant CHAIN_ID_4663 = 4663;

    /// @notice ERC-1155 metadata base of the Clearinghouse (INTERFACE-CHANGES v4 clarification; W2-09 serves it).
    string public constant LAUNCH_BASE_URI = "https://app.stonkhouse.fun/api/token/";

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
    ///      `DeployV2` requires it non-zero and `VerifyV2` FAILs on a fresh deploy that differs.
    uint128 public constant LAUNCH_VAULT_MAX_DAILY_OUTFLOW = 2_500e6;

    /// @dev Why a market with no collateral rent must never be registered (INTERFACE_VERSION 7, DECISIONS §11); the
    ///      tail of every refusal {mintFeePpmFromEnv} raises, so the deploy path says it in one voice.
    string internal constant _WHY_RENT = "INTERFACE_VERSION 7 charges the writer collateral rent at mint and premiumFeeBps is 0 at launch, so"
        " this market would charge writers nothing. Set the rate (v7 design 5.1). The zero-rent opt-in is honoured"
        " only under forge test (the fixtures); no forge script run reaches it, whatever the RPC, the chain id or"
        " the flags.";

    /// @dev What a run that exported `V2_ALLOW_ZERO_RENT` outside the forge test runner is told, so the opt-in is
    ///      never silently dropped (release blocker, DECISIONS-2026-09-17 §11).
    string internal constant _ZERO_RENT_IGNORED = "V2_ALLOW_ZERO_RENT IGNORED: the zero-rent opt-in is a test-only code path (forge test / coverage / snapshot)."
        " A forge script run -- dry run, --broadcast or --resume -- never opts in, whatever the RPC, the chain id or"
        " the flags. Set the rate (v7 design 5.1).";

    /// @notice The deploy-time freshness bound of a Chainlink feed: the us_equities_24/5 feeds print nothing all
    ///         weekend (worst observed gap 78.24 h), so this is DeploySolo's four days, not the source's 26 h `maxStale`.
    uint32 public constant DEFAULT_MAX_FEED_AGE = 4 days;

    /// @notice `forge build` artifacts the deploy creates from and the verifier compares against.
    string public constant ART_EXPIRY_CALENDAR = "out/ExpiryCalendar.sol/ExpiryCalendar.json";
    string public constant ART_CHAINLINK_SOURCE = "out/ChainlinkFeedSource.sol/ChainlinkFeedSource.json";
    string public constant ART_UNIV3_SOURCE = "out/UniV3TwapSource.sol/UniV3TwapSource.json";
    string public constant ART_DATA_STREAMS_SOURCE = "out/DataStreamsSource.sol/DataStreamsSource.json";
    string public constant ART_SETTLEMENT_ORACLE = "out/SettlementOracle.sol/SettlementOracle.json";
    string public constant ART_CLEARINGHOUSE = "out/Clearinghouse.sol/Clearinghouse.json";
    string public constant ART_ORDER_BOOK = "out/OrderBook.sol/OrderBook.json";
    string public constant ART_KEEPER_REWARDS = "out/KeeperRewards.sol/KeeperRewards.json";
    string public constant ART_AUTO_ROLLER = "out/AutoRoller.sol/AutoRoller.json";
    string public constant ART_PAYOUT_ADAPTER = "out/UniV3PayoutAdapter.sol/UniV3PayoutAdapter.json";
    string public constant ART_MAKER_REGISTRY = "out/MakerRegistry.sol/MakerRegistry.json";
    string public constant ART_MAKER_VAULT = "out/MakerVault.sol/MakerVault.json";
    string public constant ART_REWARDS_DISTRIBUTOR = "out/RewardsDistributor.sol/RewardsDistributor.json";

    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice The v2 contract set, one field per registry `v2.contracts` entry (sources flattened).
    struct Contracts {
        address expiryCalendar; // V2_EXPIRY_CALENDAR
        address chainlinkSource; // V2_SOURCE_CHAINLINK
        address univ3Source; // V2_SOURCE_UNIV3
        address dataStreamsSource; // V2_SOURCE_DATA_STREAMS
        address settlementOracle; // V2_SETTLEMENT_ORACLE
        address clearinghouse; // V2_CLEARINGHOUSE
        address orderBook; // V2_ORDER_BOOK
        address keeperRewards; // V2_KEEPER_REWARDS
        address autoRoller; // V2_AUTO_ROLLER
        address payoutAdapter; // V2_PAYOUT_ADAPTER
        address makerRegistry; // V2_MAKER_REGISTRY
        address makerVault; // V2_MAKER_VAULT
        address rewardsDistributor; // V2_REWARDS_DISTRIBUTOR
    }

    /// @notice Who holds what. Registry `shared.admin`, `shared.guardian`, `shared.feeRecipient` and `v2.bots`.
    struct Roles {
        address admin; // V2_ADMIN: DEFAULT_ADMIN_ROLE on every contract (the one hot key, owner decision)
        address guardian; // V2_GUARDIAN: GUARDIAN_ROLE on Clearinghouse, OrderBook, SettlementOracle
        address feeRecipient; // V2_FEE_RECIPIENT: Clearinghouse and OrderBook fees
        address cranker; // V2_CRANKER: no role anywhere (ADR-06); checked to hold none
        address pricer; // V2_PRICER: PRICER_ROLE on AutoRoller
        address mmQuoter; // V2_MM_QUOTER: QUOTER_ROLE on MakerVault
    }

    /// @notice Addresses the set depends on and does not deploy.
    struct External {
        address usdg; // V2_USDG: registry shared.usdg
        address swapRouter02; // V2_SWAP_ROUTER02: registry v2.uniswapV3.swapRouter02
        address univ3Factory; // V2_UNIV3_FACTORY: registry v2.uniswapV3.factory (must be swapRouter02.factory())
        address dataStreamsVerifier; // V2_DATA_STREAMS_VERIFIER: v2-sources.json contracts.verifierProxy
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
        c.expiryCalendar = vm.envOr("V2_EXPIRY_CALENDAR", address(0));
        c.chainlinkSource = vm.envOr("V2_SOURCE_CHAINLINK", address(0));
        c.univ3Source = vm.envOr("V2_SOURCE_UNIV3", address(0));
        c.dataStreamsSource = vm.envOr("V2_SOURCE_DATA_STREAMS", address(0));
        c.settlementOracle = vm.envOr("V2_SETTLEMENT_ORACLE", address(0));
        c.clearinghouse = vm.envOr("V2_CLEARINGHOUSE", address(0));
        c.orderBook = vm.envOr("V2_ORDER_BOOK", address(0));
        c.keeperRewards = vm.envOr("V2_KEEPER_REWARDS", address(0));
        c.autoRoller = vm.envOr("V2_AUTO_ROLLER", address(0));
        c.payoutAdapter = vm.envOr("V2_PAYOUT_ADAPTER", address(0));
        c.makerRegistry = vm.envOr("V2_MAKER_REGISTRY", address(0));
        c.makerVault = vm.envOr("V2_MAKER_VAULT", address(0));
        c.rewardsDistributor = vm.envOr("V2_REWARDS_DISTRIBUTOR", address(0));
    }

    function rolesFromEnv() public view returns (Roles memory r) {
        r.admin = vm.envAddress("V2_ADMIN");
        r.guardian = vm.envAddress("V2_GUARDIAN");
        r.feeRecipient = vm.envAddress("V2_FEE_RECIPIENT");
        r.cranker = vm.envAddress("V2_CRANKER");
        r.pricer = vm.envAddress("V2_PRICER");
        r.mmQuoter = vm.envAddress("V2_MM_QUOTER");
    }

    function externalFromEnv() public view returns (External memory e) {
        e.usdg = vm.envAddress("V2_USDG");
        e.swapRouter02 = vm.envAddress("V2_SWAP_ROUTER02");
        e.univ3Factory = vm.envAddress("V2_UNIV3_FACTORY");
        e.dataStreamsVerifier = vm.envAddress("V2_DATA_STREAMS_VERIFIER");
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

    /// @notice The collateral-rent rate each market is registered with (INTERFACE_VERSION 7, c05).
    /// @dev `V2_MARKET_<T>_MINT_FEE_PPM` over the shared `V2_MINT_FEE_PPM`, so a batch that exports one rate per market
    ///      and a run that exports a single default both work; that is the registry's `v2.overrides` over `v2.defaults`
    ///      shape. `RegisterMarkets` refuses a rate above `V2Constants.MINT_FEE_CEIL_PPM` in its preflight, before
    ///      anything is broadcast, and `VerifyV2` compares the live `MarketConfig.mintFeePpm` against these.
    ///
    ///      THERE IS NO 0 DEFAULT (release blocker, DECISIONS-2026-09-17 §11). `premiumFeeBps` is 0 at launch, so the
    ///      rent at mint is the only fee a writer ever pays: a rate that is absent or 0 would put a market on chain
    ///      that charges writers nothing, and both are refused by name here. {allowZeroRentFromEnv} is the one way
    ///      through and it answers true only under the forge TEST runner ({zeroRentAllowed}), so no `forge script`
    ///      run -- dry run, `--broadcast` or `--resume` -- can take it, whatever the RPC or the chain id.
    /// @param ms The markets, in V2_TICKERS order.
    /// @return ppm Millionths of the locked collateral per MINT_FEE_PERIOD of remaining life, parallel to `ms`.
    function mintFeePpmFromEnv(MarketIn[] memory ms) public view returns (uint32[] memory ppm) {
        bool allowZero = allowZeroRentFromEnv();
        (bool hasShared, uint256 shared) = _envUintIfSet("V2_MINT_FEE_PPM");
        ppm = new uint32[](ms.length);
        for (uint256 i; i < ms.length; ++i) {
            string memory key = _mk(ms[i].ticker, "MINT_FEE_PPM");
            (bool has, uint256 raw) = _envUintIfSet(key);
            if (!allowZero) {
                require(
                    has || hasShared,
                    string.concat(
                        ms[i].ticker,
                        ": no collateral rent rate: neither ",
                        key,
                        " nor V2_MINT_FEE_PPM is set. ",
                        _WHY_RENT
                    )
                );
            }
            ppm[i] = _u32(has ? raw : shared, has ? key : "V2_MINT_FEE_PPM");
            if (!allowZero) {
                require(ppm[i] != 0, string.concat(ms[i].ticker, ": collateral rent rate is 0. ", _WHY_RENT));
            }
        }
    }

    /// @notice Whether this run may register or verify a market that charges its writers no collateral rent at all.
    /// @dev `V2_ALLOW_ZERO_RENT` names the intent; {zeroRentAllowed} decides, and it answers true only under the
    ///      forge TEST runner. An unset or empty variable, "false" and "0" are all off, so a shell that exports the
    ///      name blank (the batch clears every stale `V2_*`) never opts in by accident.
    function allowZeroRentFromEnv() public view returns (bool) {
        if (!vm.envExists("V2_ALLOW_ZERO_RENT")) return false;
        string memory raw = vm.envString("V2_ALLOW_ZERO_RENT");
        if (bytes(raw).length == 0 || _eq(raw, "false") || _eq(raw, "0")) return false;
        return zeroRentAllowed(true);
    }

    /// @notice Whether this run is the forge TEST runner rather than one of the deploy scripts.
    /// @dev THE ZERO-RENT OPT-IN HANGS OFF THIS (release blocker, DECISIONS-2026-09-17 §11). `vm.isContext` is
    ///      answered by the forge binary from the SUBCOMMAND it is running: `forge test`, `forge coverage` and
    ///      `forge snapshot` are the TestGroup, and `forge script` reports ScriptDryRun, ScriptBroadcast or
    ///      ScriptResume and never TestGroup. No environment variable, wrapper flag, `--rpc-url`, chain id, fork or
    ///      block timestamp can make a script run look like a test one, which is what the other candidates could not
    ///      promise: a fork of 4663 keeps chain id 4663, and a fresh fork's head block is minutes old, so neither the
    ///      chain id nor the clock separates a rehearsal from the live chain. The subcommand does.
    ///
    ///      `virtual` only so the suite can drive the SCRIPT-context branches
    ///      (test/v2/unit/ZeroRentLocality.t.sol overrides it to false). The override can only ever TIGHTEN --
    ///      nothing anywhere overrides it to true -- so pointing `forge script` at a test double is refused exactly
    ///      like pointing it at the real script.
    function _inTestContext() internal view virtual returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.TestGroup);
    }

    /// @notice The one gate every zero-rent opt-in passes through, however it arrived: the environment
    ///         (`V2_ALLOW_ZERO_RENT`) or an `Inputs` built in Solidity (the fixtures).
    /// @dev Outside the forge test runner the answer is always false, and the run is told so by name rather than
    ///      quietly ignoring what the operator asked for.
    function zeroRentAllowed(bool requested) public view returns (bool) {
        if (!requested) return false;
        if (_inTestContext()) return true;
        _warn(_ZERO_RENT_IGNORED);
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
                spotMaxAge: _u32(vm.envUint(_mk(t, "SPOT_MAX_AGE_S")), _mk(t, "SPOT_MAX_AGE_S"))
            });
        }
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
        // INTERFACE_VERSION 7 (c05): a premium fee above the resale fee is the leak itself -- a writer who mints
        // through the book pays it once and a resale of the same long pays less, so writing to a one-tick bid of
        // your own address and reselling dodges it. The writer fee is collateral rent at mint from v7 and
        // premiumFeeBps is 0 at launch; this refusal keeps any later tuning from re-opening the dodge.
        require(f.premiumFeeBps <= f.resaleFeeBps, "premiumFeeBps above resaleFeeBps (v7: the c05 resale dodge)");
        require(f.takerFeeFlat <= V2Constants.TAKER_FEE_FLAT_CEIL, "takerFeeFlat above TAKER_FEE_FLAT_CEIL (1000000)");
        require(
            f.takerFeeCapBps <= V2Constants.TAKER_FEE_CAP_CEIL_BPS, "takerFeeCapBps above TAKER_FEE_CAP_CEIL_BPS (1000)"
        );
        require(f.makerRebateBps <= V2Constants.BPS, "makerRebateBps above 10000");
    }
}
