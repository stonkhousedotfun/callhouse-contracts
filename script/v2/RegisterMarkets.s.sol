// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {V2Constants} from "../../src/v2/interfaces/V2Constants.sol";
import {V2Types} from "../../src/v2/interfaces/V2Types.sol";
import {IChainlinkFeed} from "../../src/interfaces/IChainlinkFeed.sol";
import {IStockToken} from "../../src/interfaces/IStockToken.sol";
import {Clearinghouse} from "../../src/v2/Clearinghouse.sol";
import {ChainlinkFeedSource} from "../../src/v2/oracle/ChainlinkFeedSource.sol";
import {DataStreamsSource} from "../../src/v2/oracle/DataStreamsSource.sol";
import {SettlementOracle} from "../../src/v2/oracle/SettlementOracle.sol";
import {UniV3TwapSource} from "../../src/v2/oracle/UniV3TwapSource.sol";
import {IUniV3PoolFactory} from "../../src/v2/periphery/PayoutDeps.sol";
import {UniV3PayoutAdapter} from "../../src/v2/periphery/UniV3PayoutAdapter.sol";
import {V2DeployBase} from "./lib/V2DeployBase.sol";

/// @notice The Uniswap v3 pool reads the registration preflight makes (v3-core IUniswapV3PoolImmutables / State /
///         DerivedState).
interface IUniV3PoolView {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/// @notice Registers markets on a deployed v2 set, registry-driven: for every ticker in V2_TICKERS, a preflight of its
///         token, feed and pool, then its price sources, its SettlementOracle config, its USDG payout route and last its
///         Clearinghouse registration. One admin transaction per step that the chain does not already hold.
/// @dev Driven by `script/v2/DeployV2Batch.sh`, ONE ticker per forge run, so the registry write-back
///      (`markets[i].v2.registeredAt` / `registerTx`) follows each market. By hand:
///        ADMIN_PK=... V2_TICKERS=NVDA V2_MARKET_NVDA_ASSET=0x... <the rest of V2_*> \
///          forge script script/v2/RegisterMarkets.s.sol --rpc-url $RH_RPC --broadcast --slow --no-storage-caching
///      With no ADMIN_PK the calls are sent from V2_ADMIN, which only an anvil node that unlocked it accepts.
///
///      PER MARKET, the environment (the batch fills it from the registry row):
///        V2_MARKET_<T>_ASSET          `asset`, the 18-dp Stock Token
///        V2_MARKET_<T>_FEED           `feed`, the Chainlink proxy (8 dp)
///        V2_MARKET_<T>_POOL           `v2.univ3Pool`; unset or zero = Chainlink only and no payout route
///        V2_MARKET_<T>_MIN_LIQUIDITY  `v2.univ3MinLiquidity` (pool L units), with the pool only
///        V2_MARKET_<T>_POOL_FEE       the pool's fee tier from v2-sources.json; 0 = read from the pool
///        V2_MARKET_<T>_STRIKE_TICK    `v2.strikeTick`
///        V2_MARKET_<T>_MAX_DEVIATION_BPS, _UNCORROBORATED_DELAY_S, _SPOT_MAX_AGE_S   `v2.defaults` + `v2.overrides`
///        V2_MARKET_<T>_MINT_FEE_PPM   `v2.mintFeePpm`, over the shared V2_MINT_FEE_PPM, over 0 (v7, c05)
///      shared: V2_ADMIN, V2_USDG, V2_EXERCISE_FEE_BPS (registry `v2.fees`), V2_CLEARINGHOUSE, V2_SETTLEMENT_ORACLE,
///      V2_SOURCE_CHAINLINK, V2_SOURCE_UNIV3, V2_SOURCE_DATA_STREAMS, V2_PAYOUT_ADAPTER; V2_MAX_FEED_AGE_S (default 4
///      days); V2_MINT_FEE_PPM (default 0, the rate every market without an override is registered with);
///      V2_EXPECT_CHAIN_ID (default 4663).
///
///      PREFLIGHT per market, each refusal naming the value read and the value expected, before anything is sent:
///        token   symbol == ticker, 18 decimals, `uiMultiplier()` answers > 0, `oraclePaused()` answers false
///        feed    description contains the ticker, 8 decimals, roundId != 0, answer > 0, updatedAt within
///                V2_MAX_FEED_AGE_S
///        config  strikeTick a non-zero multiple of PRICE_TICK; exercise fee <= EXERCISE_FEE_CEIL_BPS; deviation, delay
///                and spot age inside SettlementOracle's bounds; mintFeePpm <= MINT_FEE_CEIL_PPM (v7), so
///                registerMarket cannot revert CeilingExceeded mid-run
///        pool    (when set) code, tokens {asset, USDG}, `fee()` equal to V2_MARKET_<T>_POOL_FEE when given and at most
///                V2Constants.MAX_ROUTE_FEE_TIER (10000, 1 %: the pool is also the market's payout route, and the
///                Clearinghouse counts at most MAX_ROUTE_FEE_BPS of a route's fee, so a costlier route would pay every
///                conversion in kind; UniV3PayoutAdapter.setRoute refuses it), the
///                adapter's factory returns this pool for (asset, USDG, fee), `liquidity()` > 0, `observe([1800, 0])`
///                answers (a 30-minute TWAP is possible), `slot0().observationCardinality` at least
///                V2Constants.MIN_POOL_OBSERVATION_CARDINALITY (2401) (a shallower ring can be flooded past a snapshot's
///                window, sweep contracts-c10, and UniV3TwapSource.setPool refuses it), a floor > 0; a pool below its
///                floor only WARNs: its source then reports not-ok and settlement falls back to Chainlink with the
///                uncorroborated delay, the designed failure (callhouse ops/markets/README.md)
///        chain   not registered yet, or registered with exactly this config (then nothing is sent for it)
///      Once, for the set: every contract has code, the Clearinghouse's usdg is V2_USDG, V2_ADMIN holds
///      DEFAULT_ADMIN_ROLE on the Clearinghouse, the oracle, both sources and the adapter, and the oracle names the
///      Clearinghouse (the only caller of SettlementOracle.pin, without which createSeries reverts).
///
///      CALLS per market, in this order, each only when the chain differs:
///        chainlinkSource.setOracle(oracle, true), univ3Source.setOracle(oracle, true) (with a pool)   normally wired
///                                                                             by DeployV2 already: nothing to send
///        chainlinkSource.setFeed(asset, feed, DEFAULT_MAX_STALE, DEFAULT_MAX_ROUND_JUMP_BPS)
///        univ3Source.setPool(asset, pool, minLiquidity, DEFAULT_WINDOW)       (with a pool)
///        settlementOracle.setMarket(asset, [chainlink] | [chainlink, univ3], deviation, delay, spot age)
///        univ3Source.setPool(asset, 0)            (removes a pool the registry has not, once the list no longer names it)
///        payoutAdapter.setRoute(asset, poolFee)                               (or clears a route the registry has not)
///        clearinghouse.registerMarket(asset, {enabled, !mintPaused, strikeTick, exerciseFeeBps, oracle,
///                                            mintFeePpm})                                                LAST
///      DataStreamsSource is never configured (C2-12: owner-gated) and never listed; its feed id for the market is only
///      reported.
///
///      LISTED SOURCES ARE CONFIGURED (INTERFACE_VERSION 6). Pinning fails closed: SettlementOracle.pin reverts, and
///      with it every first series of an expiry, while the market's list names a source that has no configuration
///      for the asset (V2Errors.SourceNotPinned(source, NoSource)) or does not list the oracle (NotAuthorized). So a
///      source is configured and accepts the oracle's pins before the list names it, and is unconfigured only after
///      the list dropped it: no step of a run leaves a live market unable to create series.
contract RegisterMarkets is V2DeployBase {
    struct Inputs {
        address admin;
        address usdg;
        uint16 exerciseFeeBps;
        uint32 maxFeedAge;
        Contracts c;
        MarketIn[] markets;
        uint256 expectChainId;
        /// @dev INTERFACE_VERSION 7: the collateral-rent rate registered per market, parallel to `markets`. Read from
        ///      `V2_MARKET_<T>_MINT_FEE_PPM`, falling back to the shared `V2_MINT_FEE_PPM` and then to 0, which is the
        ///      registry's `v2.overrides` over `v2.defaults` shape. It lives here rather than in MarketIn because
        ///      MarketIn belongs to V2DeployBase, which this work package does not own.
        uint32[] mintFeePpm;
        /// @dev INTERFACE_VERSION 7 release blocker (DECISIONS-2026-09-17 §11): registering a market whose rent rate
        ///      is 0 is refused, because `premiumFeeBps` is 0 at launch and the rent is then the only writer fee. An
        ///      opt-in asked for here is only granted under the forge TEST runner ({V2DeployBase.zeroRentAllowed}),
        ///      so this field cannot open a `forge script` run -- not a `--broadcast`, not a dry run against live
        ///      4663, not a `--resume`. The fixtures are the one place it is honoured.
        bool allowZeroRent;
    }

    /*//////////////////////////////////////////////////////////////
                                  ENTRY
    //////////////////////////////////////////////////////////////*/

    function run() external returns (uint256 registered, uint256 sent) {
        Inputs memory in_ = inputsFromEnv();
        uint256 adminPk = vm.envOr("ADMIN_PK", uint256(0));
        Signer memory admin = adminPk != 0 ? Signer(adminPk, vm.addr(adminPk)) : Signer(0, in_.admin);
        require(
            admin.addr == in_.admin,
            string.concat(
                "ADMIN_PK is not V2_ADMIN's key: it signs as ",
                vm.toString(admin.addr),
                ", V2_ADMIN is ",
                vm.toString(in_.admin)
            )
        );
        require(
            block.chainid == in_.expectChainId,
            string.concat("chain id ", vm.toString(block.chainid), ", expected ", vm.toString(in_.expectChainId))
        );
        (registered, sent) = runWith(in_, admin);
        console2.log("");
        console2.log(
            string.concat(
                "REGISTER DONE: ",
                vm.toString(in_.markets.length),
                " market(s), ",
                vm.toString(registered),
                " registerMarket call(s), ",
                vm.toString(sent),
                " admin call(s) sent"
            )
        );
    }

    function inputsFromEnv() public view returns (Inputs memory in_) {
        in_.admin = vm.envAddress("V2_ADMIN");
        in_.usdg = vm.envAddress("V2_USDG");
        in_.exerciseFeeBps = _u16(vm.envUint("V2_EXERCISE_FEE_BPS"), "V2_EXERCISE_FEE_BPS");
        in_.maxFeedAge = _u32(vm.envOr("V2_MAX_FEED_AGE_S", uint256(DEFAULT_MAX_FEED_AGE)), "V2_MAX_FEED_AGE_S");
        in_.c = contractsFromEnv();
        in_.markets = marketsFromEnv();
        in_.expectChainId = vm.envOr("V2_EXPECT_CHAIN_ID", CHAIN_ID_4663);
        in_.allowZeroRent = allowZeroRentFromEnv();
        in_.mintFeePpm = mintFeePpmFromEnv(in_.markets);
    }

    /// @notice Preflight every market first, then configure and register them one by one.
    /// @return registered registerMarket calls sent
    /// @return sent       admin calls sent in total
    function runWith(Inputs memory in_, Signer memory admin) public returns (uint256 registered, uint256 sent) {
        require(in_.markets.length != 0, "V2_TICKERS is empty");
        preflightSet(in_);
        for (uint256 i; i < in_.markets.length; ++i) {
            for (uint256 j; j < i; ++j) {
                require(!_eq(in_.markets[i].ticker, in_.markets[j].ticker), "duplicate ticker in V2_TICKERS");
                require(in_.markets[i].asset != in_.markets[j].asset, "two tickers share one asset");
            }
            preflightMarket(in_, in_.markets[i]);
        }
        for (uint256 i; i < in_.markets.length; ++i) {
            MarketIn memory m = in_.markets[i];
            console2.log(string.concat("register ", m.ticker));
            (Call[] memory calls, bool registers) = plan(in_, m);
            for (uint256 k; k < calls.length; ++k) {
                console2.log(string.concat("  call  ", calls[k].what));
            }
            _execute(admin, calls);
            sent += calls.length;
            if (registers) ++registered;
            _postCheck(in_, m);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                PREFLIGHT
    //////////////////////////////////////////////////////////////*/

    /// @notice The contract set and the admin's roles on it.
    function preflightSet(Inputs memory in_) public view {
        console2.log("preflight (contract set)");
        Contracts memory c = in_.c;
        _code(c.clearinghouse, "V2_CLEARINGHOUSE");
        _code(c.settlementOracle, "V2_SETTLEMENT_ORACLE");
        _code(c.chainlinkSource, "V2_SOURCE_CHAINLINK");
        _code(c.univ3Source, "V2_SOURCE_UNIV3");
        _code(c.dataStreamsSource, "V2_SOURCE_DATA_STREAMS");
        _code(c.payoutAdapter, "V2_PAYOUT_ADAPTER");
        _ok("clearinghouse, oracle, sources and payout adapter have code");
        address chUsdg = Clearinghouse(c.clearinghouse).usdg();
        require(
            chUsdg == in_.usdg,
            string.concat("clearinghouse.usdg() ", vm.toString(chUsdg), " is not V2_USDG ", vm.toString(in_.usdg))
        );
        require(UniV3TwapSource(c.univ3Source).usdg() == in_.usdg, "univ3Source.usdg() is not V2_USDG");
        require(UniV3PayoutAdapter(c.payoutAdapter).usdg() == in_.usdg, "payoutAdapter.usdg() is not V2_USDG");
        _ok("clearinghouse, univ3 source and payout adapter all use V2_USDG");
        _adminOf(c.clearinghouse, in_.admin, "Clearinghouse");
        _adminOf(c.settlementOracle, in_.admin, "SettlementOracle");
        _adminOf(c.chainlinkSource, in_.admin, "ChainlinkFeedSource");
        _adminOf(c.univ3Source, in_.admin, "UniV3TwapSource");
        _adminOf(c.payoutAdapter, in_.admin, "UniV3PayoutAdapter");
        _ok("V2_ADMIN holds DEFAULT_ADMIN_ROLE on all five");
        address pinCaller = SettlementOracle(c.settlementOracle).clearinghouse();
        require(
            pinCaller == c.clearinghouse,
            string.concat(
                "settlementOracle.clearinghouse() ",
                vm.toString(pinCaller),
                " is not V2_CLEARINGHOUSE: every createSeries would revert in oracle.pin (run the deploy wiring first)"
            )
        );
        _ok("settlementOracle.clearinghouse() is the Clearinghouse (createSeries can pin)");
        require(
            in_.exerciseFeeBps <= V2Constants.EXERCISE_FEE_CEIL_BPS,
            "V2_EXERCISE_FEE_BPS above EXERCISE_FEE_CEIL_BPS (200)"
        );
        _ok(string.concat("exercise fee ", vm.toString(in_.exerciseFeeBps), " bps <= 200"));
    }

    /// @dev The rent rate `m` is registered with: `in_.mintFeePpm` is parallel to `in_.markets`, and an Inputs built
    ///      by hand without it (the preflight suites do that) reads as 0, the v6 behaviour.
    function _mintFeePpmOf(Inputs memory in_, MarketIn memory m) internal pure returns (uint32) {
        for (uint256 i; i < in_.markets.length && i < in_.mintFeePpm.length; ++i) {
            if (_eq(in_.markets[i].ticker, m.ticker)) return in_.mintFeePpm[i];
        }
        return 0;
    }

    function _adminOf(address target, address admin, string memory name) internal view {
        require(
            IAccessControl(target).hasRole(V2Constants.DEFAULT_ADMIN_ROLE, admin),
            string.concat("V2_ADMIN ", vm.toString(admin), " does not hold DEFAULT_ADMIN_ROLE on the ", name)
        );
    }

    /// @notice One market's token, feed, parameters, pool and on-chain registration state.
    function preflightMarket(Inputs memory in_, MarketIn memory m) public view {
        console2.log(string.concat("preflight ", m.ticker));
        require(bytes(m.ticker).length != 0, "empty ticker in V2_TICKERS");
        _asset(m);
        _feed(m, in_.maxFeedAge);

        require(
            m.strikeTick != 0 && m.strikeTick % V2Constants.PRICE_TICK == 0,
            string.concat(m.ticker, ": strikeTick ", vm.toString(m.strikeTick), " must be a non-zero multiple of 100")
        );
        _ok(string.concat("strikeTick ", vm.toString(m.strikeTick), " (USDG base units per share)"));
        require(
            m.maxDeviationBps != 0 && m.maxDeviationBps <= 1000,
            string.concat(m.ticker, ": maxDeviationBps outside [1, 1000]")
        );
        require(
            m.uncorroboratedDelay >= 30 minutes && m.uncorroboratedDelay <= 24 hours,
            string.concat(m.ticker, ": uncorroboratedDelay outside [1800, 86400] s")
        );
        require(
            m.spotMaxAge != 0 && m.spotMaxAge <= 4 days, string.concat(m.ticker, ": spotMaxAge outside [1, 345600] s")
        );
        _ok(
            string.concat(
                "oracle: deviation ",
                vm.toString(m.maxDeviationBps),
                " bps, uncorroborated delay ",
                vm.toString(m.uncorroboratedDelay),
                " s, spot max age ",
                vm.toString(m.spotMaxAge),
                " s"
            )
        );

        // INTERFACE_VERSION 7 (c05): the collateral-rent rate the market is registered with. The Clearinghouse would
        // revert CeilingExceeded above MINT_FEE_CEIL_PPM; refusing here names the ticker and the variable, before
        // anything is broadcast.
        uint32 ppm = _mintFeePpmOf(in_, m);
        // Release blocker (DECISIONS-2026-09-17 §11): `premiumFeeBps` is 0 at launch, so the rent at mint is the only
        // fee a writer ever pays. A market registered at 0 charges writers nothing and only a NEW `setMarketConfig`
        // plus new series could fix it, so it is refused here rather than deployed and patched. The opt-in runs
        // through `zeroRentAllowed`, which is false in every `forge script` context: this refusal stands on a direct
        // `forge script RegisterMarkets --rpc-url <live 4663> --broadcast` with `V2_ALLOW_ZERO_RENT` exported, and on
        // the same run without `--broadcast`, because the forge subcommand is the gate and no flag changes it.
        require(
            ppm != 0 || zeroRentAllowed(in_.allowZeroRent),
            string.concat(
                m.ticker,
                ": mintFeePpm is 0. INTERFACE_VERSION 7 charges the writer collateral rent at mint and premiumFeeBps"
                " is 0 at launch, so this market would charge writers nothing. Set the registry's v2.mintFeePpm (v7"
                " design 5.1). The zero-rent opt-in is honoured only under forge test (the fixtures); no forge script"
                " run reaches it, whatever the RPC, the chain id or the flags."
            )
        );
        require(
            ppm <= V2Constants.MINT_FEE_CEIL_PPM,
            string.concat(
                m.ticker,
                ": mintFeePpm ",
                vm.toString(uint256(ppm)),
                " is above MINT_FEE_CEIL_PPM (",
                vm.toString(V2Constants.MINT_FEE_CEIL_PPM),
                "): lower ",
                _mk(m.ticker, "MINT_FEE_PPM"),
                " or V2_MINT_FEE_PPM"
            )
        );
        _ok(
            string.concat(
                "mintFeePpm ",
                vm.toString(uint256(ppm)),
                " <= ",
                vm.toString(V2Constants.MINT_FEE_CEIL_PPM),
                " (millionths of locked collateral per 7 days of remaining life)"
            )
        );

        if (m.pool != address(0)) {
            _pool(in_, m);
        } else {
            require(m.minLiquidity == 0, string.concat(m.ticker, ": univ3MinLiquidity set without a pool"));
            _ok("no pool: Chainlink only, ITM call payouts in kind");
        }

        V2Types.MarketConfig memory cur = Clearinghouse(in_.c.clearinghouse).market(m.asset);
        if (cur.strikeTick == 0) {
            _ok("not registered on the Clearinghouse yet");
        } else {
            require(
                cur.enabled && cur.strikeTick == m.strikeTick && cur.exerciseFeeBps == in_.exerciseFeeBps
                    && cur.oracle == in_.c.settlementOracle && cur.mintFeePpm == ppm,
                string.concat(
                    m.ticker,
                    ": already registered on the Clearinghouse with another config (enabled ",
                    cur.enabled ? "true" : "false",
                    ", strikeTick ",
                    vm.toString(cur.strikeTick),
                    ", exerciseFeeBps ",
                    vm.toString(cur.exerciseFeeBps),
                    ", mintFeePpm ",
                    vm.toString(uint256(cur.mintFeePpm)),
                    ", oracle ",
                    vm.toString(cur.oracle),
                    "): change a live market with setMarketConfig by hand, not here"
                )
            );
            _ok("already registered on the Clearinghouse with this config");
        }
        bytes32 feedId = DataStreamsSource(in_.c.dataStreamsSource).feedIdOf(m.asset);
        console2.log(
            string.concat(
                "  info  DataStreamsSource feed id ", feedId == bytes32(0) ? "none (disabled)" : vm.toString(feedId)
            )
        );
    }

    /// @dev The Stock Token: DeploySolo.s.sol's checks (a token without the two issuer views is not a Stock Token).
    function _asset(MarketIn memory m) internal view {
        _code(m.asset, _mk(m.ticker, "ASSET"));
        string memory symbol = IERC20Metadata(m.asset).symbol();
        require(
            _eq(symbol, m.ticker),
            string.concat(
                "asset symbol mismatch: ",
                _mk(m.ticker, "ASSET"),
                " ",
                vm.toString(m.asset),
                " is \"",
                symbol,
                "\", ticker is \"",
                m.ticker,
                "\""
            )
        );
        _ok(string.concat("asset symbol == ticker (", symbol, ")"));
        require(IERC20Metadata(m.asset).decimals() == 18, string.concat(m.ticker, ": asset decimals != 18"));
        _ok("asset decimals == 18");
        (bool ok, bytes memory data) = m.asset.staticcall(abi.encodeWithSelector(IStockToken.uiMultiplier.selector));
        require(
            ok && data.length == 32,
            string.concat(m.ticker, ": asset uiMultiplier() probe failed: not a Robinhood Stock Token?")
        );
        require(abi.decode(data, (uint256)) > 0, string.concat(m.ticker, ": asset uiMultiplier() == 0"));
        _ok(string.concat("asset uiMultiplier() answers, > 0 (", vm.toString(abi.decode(data, (uint256))), ")"));
        (ok, data) = m.asset.staticcall(abi.encodeWithSelector(IStockToken.oraclePaused.selector));
        require(
            ok && data.length == 32,
            string.concat(m.ticker, ": asset oraclePaused() probe failed: not a Robinhood Stock Token?")
        );
        require(
            !abi.decode(data, (bool)),
            string.concat(m.ticker, ": asset oraclePaused() is true: the issuer has halted its oracle")
        );
        _ok("asset oraclePaused() answers, false");
    }

    /// @dev The Chainlink proxy of the ticker, live.
    function _feed(MarketIn memory m, uint32 maxAge) internal view {
        _code(m.feed, _mk(m.ticker, "FEED"));
        IChainlinkFeed f = IChainlinkFeed(m.feed);
        string memory description = f.description();
        require(
            _contains(description, m.ticker),
            string.concat(
                "feed description mismatch: ",
                _mk(m.ticker, "FEED"),
                " ",
                vm.toString(m.feed),
                " is \"",
                description,
                "\", ticker is \"",
                m.ticker,
                "\""
            )
        );
        _ok(string.concat("feed description contains the ticker (\"", description, "\")"));
        require(f.decimals() == 8, string.concat(m.ticker, ": unexpected feed decimals"));
        _ok("feed decimals == 8");
        (uint80 roundId, int256 answer,, uint256 updatedAt,) = f.latestRoundData();
        require(roundId != 0, string.concat(m.ticker, ": feed roundId == 0"));
        require(answer > 0, string.concat(m.ticker, ": feed answer <= 0"));
        require(
            updatedAt != 0 && updatedAt <= block.timestamp,
            string.concat(m.ticker, ": feed updatedAt is zero or in the future")
        );
        uint256 age = block.timestamp - updatedAt;
        require(
            age <= maxAge,
            string.concat(
                m.ticker,
                ": feed is stale: age ",
                vm.toString(age),
                " s > V2_MAX_FEED_AGE_S ",
                vm.toString(uint256(maxAge))
            )
        );
        _ok(string.concat("feed answer ", vm.toString(answer), " (8 dp), age ", vm.toString(age), " s"));
    }

    /// @dev The registry's Uniswap v3 pool: the pair, the factory's own pool at its fee, live liquidity, 30-minute
    ///      observations, and its floor.
    function _pool(Inputs memory in_, MarketIn memory m) internal view {
        IUniV3PoolView pool = IUniV3PoolView(m.pool);
        _code(m.pool, _mk(m.ticker, "POOL"));
        address t0 = pool.token0();
        address t1 = pool.token1();
        require(
            (t0 == m.asset && t1 == in_.usdg) || (t0 == in_.usdg && t1 == m.asset),
            string.concat(m.ticker, ": pool tokens ", vm.toString(t0), ", ", vm.toString(t1), " are not {asset, USDG}")
        );
        _ok("pool tokens are {asset, USDG}");
        uint24 fee = pool.fee();
        require(
            m.poolFee == 0 || m.poolFee == fee,
            string.concat(
                m.ticker,
                ": pool fee() ",
                vm.toString(uint256(fee)),
                " is not ",
                _mk(m.ticker, "POOL_FEE"),
                " ",
                vm.toString(uint256(m.poolFee))
            )
        );
        require(
            fee <= V2Constants.MAX_ROUTE_FEE_TIER,
            string.concat(
                m.ticker,
                ": pool fee tier ",
                vm.toString(uint256(fee)),
                " is above 10000 (1 %): the Clearinghouse counts at most MAX_ROUTE_FEE_BPS (100 bps) of a payout",
                " route's fee, so every conversion through this pool would pay in kind, and",
                " UniV3PayoutAdapter.setRoute refuses it (CeilingExceeded)"
            )
        );
        _ok(
            string.concat(
                "pool fee tier ", vm.toString(uint256(fee)), " <= 10000 (a payout route the floor allows for)"
            )
        );
        address factory = UniV3PayoutAdapter(in_.c.payoutAdapter).factory();
        address canonical = IUniV3PoolFactory(factory).getPool(m.asset, in_.usdg, fee);
        require(
            canonical == m.pool,
            string.concat(
                m.ticker,
                ": the Uniswap v3 factory's (asset, USDG) pool at fee ",
                vm.toString(uint256(fee)),
                " is ",
                vm.toString(canonical),
                ", not the registry pool"
            )
        );
        _ok(string.concat("pool is the factory's (asset, USDG) pool at fee ", vm.toString(uint256(fee))));
        uint128 liquidity = pool.liquidity();
        require(liquidity > 0, string.concat(m.ticker, ": pool liquidity() == 0"));
        uint32[] memory ago = new uint32[](2);
        ago[0] = 1800;
        (bool ok,) = m.pool.staticcall(abi.encodeCall(IUniV3PoolView.observe, (ago)));
        require(ok, string.concat(m.ticker, ": pool observe([1800, 0]) failed: no 30-minute TWAP"));
        _ok("pool observe([1800, 0]) answers");
        (,,, uint16 cardinality,,,) = pool.slot0();
        // The named threshold UniV3TwapSource.setPool itself enforces (owner sign-off c10, DECISIONS-2026-09-17 §7):
        // every launch pool but NVDA's and SPCX's is below it and is registered Chainlink-only instead, so this
        // refusal has to fire before anything is broadcast.
        uint256 minCardinality = V2Constants.MIN_POOL_OBSERVATION_CARDINALITY;
        require(
            cardinality >= minCardinality,
            string.concat(
                m.ticker,
                ": pool observationCardinality ",
                vm.toString(uint256(cardinality)),
                " is below ",
                vm.toString(minCardinality),
                " (SETTLEMENT_WINDOW + SNAPSHOT_GRACE + 1): one dust mint or burn per second could overwrite an",
                " expiry's window before the snapshot grace ends, and UniV3TwapSource.setPool refuses the pool",
                " (UnsupportedAsset); call increaseObservationCardinalityNext(",
                vm.toString(minCardinality),
                ") on the pool and wait until slot0().observationCardinality reaches it"
            )
        );
        _ok(
            string.concat(
                "pool observationCardinality ",
                vm.toString(uint256(cardinality)),
                " >= ",
                vm.toString(minCardinality),
                " (outlasts a flood through the snapshot grace)"
            )
        );
        require(m.minLiquidity > 0, string.concat(m.ticker, ": univ3MinLiquidity must be > 0 with a pool"));
        if (liquidity < m.minLiquidity) {
            _warn(
                string.concat(
                    "pool liquidity ",
                    vm.toString(liquidity),
                    " is below univ3MinLiquidity ",
                    vm.toString(m.minLiquidity),
                    ": its source will report not-ok until it recovers (Chainlink-only settlement)"
                )
            );
        } else {
            _ok(
                string.concat(
                    "pool liquidity ", vm.toString(liquidity), " >= univ3MinLiquidity ", vm.toString(m.minLiquidity)
                )
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                                   PLAN
    //////////////////////////////////////////////////////////////*/

    /// @notice The admin calls that bring one market to its registry config, and whether they include registerMarket.
    function plan(Inputs memory in_, MarketIn memory m) public view returns (Call[] memory calls, bool registers) {
        Call[] memory buf = new Call[](7);
        uint256 n;
        Contracts memory c = in_.c;
        ChainlinkFeedSource chainlink = ChainlinkFeedSource(c.chainlinkSource);
        UniV3TwapSource univ3 = UniV3TwapSource(c.univ3Source);
        SettlementOracle oracle = SettlementOracle(c.settlementOracle);
        UniV3PayoutAdapter adapter = UniV3PayoutAdapter(c.payoutAdapter);
        Clearinghouse ch = Clearinghouse(c.clearinghouse);

        // The sources the market lists must accept the oracle's pins before the registration makes series possible.
        // DeployV2 wires this for the whole set, so a normal run plans nothing here.
        if (!chainlink.isOracle(c.settlementOracle)) {
            buf[n++] = Call(
                c.chainlinkSource,
                abi.encodeCall(chainlink.setOracle, (c.settlementOracle, true)),
                "chainlinkSource.setOracle(settlementOracle, true)"
            );
        }
        if (m.pool != address(0) && !univ3.isOracle(c.settlementOracle)) {
            buf[n++] = Call(
                c.univ3Source,
                abi.encodeCall(univ3.setOracle, (c.settlementOracle, true)),
                "univ3Source.setOracle(settlementOracle, true)"
            );
        }

        uint32 maxStale = chainlink.DEFAULT_MAX_STALE();
        uint16 maxJump = chainlink.DEFAULT_MAX_ROUND_JUMP_BPS();
        (address feed, uint32 stale, uint16 jump) = chainlink.feeds(m.asset);
        if (feed != m.feed || stale != maxStale || jump != maxJump) {
            buf[n++] = Call(
                c.chainlinkSource,
                abi.encodeCall(chainlink.setFeed, (m.asset, m.feed, maxStale, maxJump)),
                string.concat("chainlinkSource.setFeed(", m.ticker, ", feed, 26 h, 2000 bps)")
            );
        }

        uint32 window = univ3.DEFAULT_WINDOW();
        (address pool,,, uint32 curWindow, uint128 curFloor) = univ3.pools(m.asset);
        if (m.pool != address(0) && (pool != m.pool || curWindow != window || curFloor != m.minLiquidity)) {
            buf[n++] = Call(
                c.univ3Source,
                abi.encodeCall(univ3.setPool, (m.asset, m.pool, m.minLiquidity, window)),
                string.concat("univ3Source.setPool(", m.ticker, ", pool, ", vm.toString(m.minLiquidity), " L, 300 s)")
            );
        }

        address[] memory want = new address[](m.pool == address(0) ? 1 : 2);
        want[0] = c.chainlinkSource;
        if (m.pool != address(0)) want[1] = c.univ3Source;
        (address[] memory sources, uint16 dev, uint32 delay, uint32 age) = oracle.marketConfig(m.asset);
        if (
            !_sameList(sources, want) || dev != m.maxDeviationBps || delay != m.uncorroboratedDelay
                || age != m.spotMaxAge
        ) {
            buf[n++] = Call(
                c.settlementOracle,
                abi.encodeCall(
                    oracle.setMarket, (m.asset, want, m.maxDeviationBps, m.uncorroboratedDelay, m.spotMaxAge)
                ),
                string.concat(
                        "settlementOracle.setMarket(",
                        m.ticker,
                        m.pool == address(0) ? ", [chainlink], " : ", [chainlink, univ3], ",
                        vm.toString(m.maxDeviationBps),
                        " bps, ",
                        vm.toString(m.uncorroboratedDelay),
                        " s, ",
                        vm.toString(m.spotMaxAge),
                        " s)"
                    )
            );
        }

        // After setMarket: while the oracle's list still names the pool source, removing its pool would refuse every
        // first series of an expiry (pinning fails closed).
        if (m.pool == address(0) && pool != address(0)) {
            buf[n++] = Call(
                c.univ3Source,
                abi.encodeCall(univ3.setPool, (m.asset, address(0), 0, 0)),
                string.concat("univ3Source.setPool(", m.ticker, ", 0): remove a pool the registry does not list")
            );
        }

        (address routePool, uint24 routeFee) = adapter.routes(m.asset);
        if (m.pool != address(0)) {
            uint24 fee = m.poolFee != 0 ? m.poolFee : IUniV3PoolView(m.pool).fee();
            if (routePool != m.pool || routeFee != fee) {
                buf[n++] = Call(
                    c.payoutAdapter,
                    abi.encodeCall(adapter.setRoute, (m.asset, fee)),
                    string.concat("payoutAdapter.setRoute(", m.ticker, ", fee ", vm.toString(uint256(fee)), ")")
                );
            }
        } else if (routeFee != 0) {
            buf[n++] = Call(
                c.payoutAdapter,
                abi.encodeCall(adapter.setRoute, (m.asset, uint24(0))),
                string.concat("payoutAdapter.setRoute(", m.ticker, ", 0): clear a route the registry does not list")
            );
        }

        if (ch.market(m.asset).strikeTick == 0) {
            V2Types.MarketConfig memory cfg = V2Types.MarketConfig({
                enabled: true,
                mintPaused: false,
                strikeTick: m.strikeTick,
                exerciseFeeBps: in_.exerciseFeeBps,
                oracle: c.settlementOracle,
                mintFeePpm: _mintFeePpmOf(in_, m)
            });
            buf[n++] = Call(
                c.clearinghouse,
                abi.encodeCall(ch.registerMarket, (m.asset, cfg)),
                string.concat(
                    "clearinghouse.registerMarket(",
                    m.ticker,
                    ", enabled, strikeTick ",
                    vm.toString(m.strikeTick),
                    ", exerciseFeeBps ",
                    vm.toString(in_.exerciseFeeBps),
                    ", mintFeePpm ",
                    vm.toString(uint256(cfg.mintFeePpm)),
                    ", oracle)"
                )
            );
            registers = true;
        }
        calls = _trim(buf, n);
    }

    function _sameList(address[] memory a, address[] memory b) internal pure returns (bool) {
        if (a.length != b.length) return false;
        for (uint256 i; i < a.length; ++i) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    /// @dev After the calls (the simulation under `forge script`; VerifyV2 is the gate against the chain).
    function _postCheck(Inputs memory in_, MarketIn memory m) internal view {
        (Call[] memory left,) = plan(in_, m);
        require(left.length == 0, string.concat(m.ticker, ": post-check: config still differs after the admin calls"));
        (bool ok, uint256 price,) = SettlementOracle(in_.c.settlementOracle).trySpot(m.asset);
        console2.log(
            string.concat(
                "  post-check: ",
                m.ticker,
                " registered and configured; oracle trySpot ",
                ok ? "ok " : "not ok (a quiet feed older than spotMaxAge; informational) ",
                vm.toString(price)
            )
        );
    }
}
