// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AutoRoller} from "../../src/v2/AutoRoller.sol";
import {Clearinghouse} from "../../src/v2/Clearinghouse.sol";
import {ExpiryCalendar} from "../../src/v2/ExpiryCalendar.sol";
import {KeeperRewards} from "../../src/v2/KeeperRewards.sol";
import {OrderBook} from "../../src/v2/OrderBook.sol";
import {IClearinghouse} from "../../src/v2/interfaces/IClearinghouse.sol";
import {IMakerRegistry} from "../../src/v2/interfaces/IMakerRegistry.sol";
import {IOrderBook} from "../../src/v2/interfaces/IOrderBook.sol";
import {V2Constants} from "../../src/v2/interfaces/V2Constants.sol";
import {V2Types} from "../../src/v2/interfaces/V2Types.sol";
import {MakerRegistry} from "../../src/v2/mm/MakerRegistry.sol";
import {MakerVault} from "../../src/v2/mm/MakerVault.sol";
import {RewardsDistributor} from "../../src/v2/mm/RewardsDistributor.sol";
import {MockRoundFeed} from "../../src/v2/mocks/MockRoundFeed.sol";
import {ChainlinkFeedSource} from "../../src/v2/oracle/ChainlinkFeedSource.sol";
import {IAggregatorV3} from "../../src/v2/oracle/OracleDeps.sol";
import {SettlementOracle} from "../../src/v2/oracle/SettlementOracle.sol";
import {UniV3TwapSource} from "../../src/v2/oracle/UniV3TwapSource.sol";
import {UniV3PayoutAdapter} from "../../src/v2/periphery/UniV3PayoutAdapter.sol";

/// @notice The one Uniswap v3 pool getter DevDeploy reads to route a market's payouts at its own pool's fee tier.
interface IDevDeployPoolFee {
    function fee() external view returns (uint24);
}

/// @notice Deploys the v2 core set on a LOCAL ANVIL FORK of chain 4663 for the devnet (callhouse ops/devnet/up.sh):
///         ExpiryCalendar, ChainlinkFeedSource, UniV3TwapSource, SettlementOracle, Clearinghouse, OrderBook and
///         KeeperRewards, wired and funded, against the REAL USDG, Stock Tokens, Chainlink feeds and USDG/NVDA pool.
///         NVDA settles on both sources (Chainlink, then the pool), TSLA on Chainlink only.
/// @dev NOT A PRODUCTION DEPLOY. C2-13 owns the mainnet deploy/configure/verify scripts. {run} refuses any node that is
///      not anvil (`web3_clientVersion`) and any chain other than 4663, and it never reads a key: up.sh broadcasts
///      with `--unlocked --sender <anvil account #0>`, an account anvil unlocks itself.
///
///      UNITS as everywhere in src/v2: prices and strike ticks in USDG base units (6 dp) per whole share, fees and
///      deviations in bps, delays and ages in seconds, bounties and budgets in USDG base units, pool liquidity in L.
///
///      ORDER (every step broadcast from ADMIN, which holds DEFAULT_ADMIN_ROLE on everything):
///        1. price feeds: with DEV_MOCK_FEED=1 (the default) one MockRoundFeed per market, seeded with the real
///           feed's last MOCK_HISTORY_ROUNDS rounds of the current phase (answers and timestamps) plus one round
///           with the latest answer stamped now, so `latest` is ok (a predecessor exists) and spot is fresh.
///           ops/devnet/set-feed.mjs pushes further rounds: that is how the devnet controls settlement prices
///           after `evm_increaseTime`, which a live feed cannot follow. DEV_MOCK_FEED=0 points at the real feed.
///        2. ExpiryCalendar(admin, holidays) with DEV_HOLIDAYS (up.sh passes ops/markets/v2-sources.json
///           `nyseHolidays.*.fullDays[].dayIndex`; the compiled fallback is the same 2026-2028 list).
///        3. ChainlinkFeedSource(admin).setFeed per market (DEFAULT_MAX_STALE, DEFAULT_MAX_ROUND_JUMP_BPS);
///           UniV3TwapSource(admin, usdg).setPool for every market with a pool (registry univ3MinLiquidity,
///           DEFAULT_WINDOW).
///        4. SettlementOracle(admin, guardian).setMarket per market: [chainlink] or [chainlink, univ3], with the
///           registry defaults (maxDeviationBps 150, uncorroboratedDelay 6 h, spotMaxAge 1 h).
///        5. Clearinghouse(admin, usdg, calendar, feeRecipient, BASE_URI); GUARDIAN_ROLE to guardian;
///           registerMarket per market (enabled, strikeTick, exerciseFeeBps, oracle).
///        6. OrderBook(clearinghouse, admin, guardian, feeRecipient, fees) with the registry `v2.fees`.
///        7. KeeperRewards(usdg, admin): setCaller(oracle) and setCaller(clearinghouse), the six bounties, the daily
///           cap, then `fund` from ADMIN's USDG (up.sh deals it first; too little reverts AdminUnderfunded).
///           oracle.setClearinghouse, oracle.setKeeperRewards, clearinghouse.setKeeperRewards.
///        8. PERIPHERY, in this order (the C2-09 / C2-10 / C2-11 hand-off notes):
///           a. AutoRoller(book, admin): PRICER_ROLE to the pricer, setKeeperRewards, and KeeperRewards.setCaller(roller)
///              (its ROLL bounty is step 7's). {_deployAutoRoller}
///           b. UniV3PayoutAdapter(admin, usdg, SwapRouter02): setRoute(underlying, the pool's own fee tier) for every
///              market with a pool (NVDA: 500), then clearinghouse.setPayoutAdapter(adapter, PAYOUT_SLIPPAGE_BPS).
///              {_deployPayoutAdapter}
///           c. MakerRegistry(admin) -> orderBook.setMakerRegistry -> MakerVault(book, admin, mmQuoter, limits) ->
///              RewardsDistributor(usdg, admin). The vault is funded by ops/devnet/seed.mjs, not here.
///              {_deployMakerSuite}
///        9. chainlink.setOracle(oracle, true), univ3.setOracle(oracle, true): the sources accept the oracle's pins, so
///           every series seed.mjs creates pins its expiry's settlement configuration down to the feed and the pool
///           (INTERFACE_VERSION 6; step 7 already pointed the oracle at the Clearinghouse). Sent last so that no
///           contract address of an earlier step moves with the admin's nonce.
///
///      PERIPHERY FLAGS (plan F2-04 "Staging"). DEV_AUTO_ROLLER, DEV_PAYOUT_ADAPTER, DEV_MAKER_SUITE = `auto` (default:
///      deploy when the hook can, skip cleanly when a prerequisite is missing) | `0` (never; the JSON carries `null`)
///      | `1` (required: revert PeripheryMissing when the hook returns nothing). The AutoRoller and the maker suite
///      always deploy; the PayoutAdapter needs a SwapRouter02 with code (SWAP_ROUTER_02), so `auto` skips it on a
///      node without one and `1` refuses. Hooks run after the core wiring, so core addresses do not move when a
///      periphery contract is added or switched off, and with the pinned deployer nonce (up.sh) the periphery
///      addresses are the same on every run with the same flags.
///
///      ENVIRONMENT (all optional; up.sh passes the registry's values explicitly)
///        ADMIN, GUARDIAN, FEE_RECIPIENT     anvil accounts #0, #1, #2
///        DEV_PRICER, DEV_MM_QUOTER          anvil #9, #10: the role holders the periphery hooks grant to
///        USDG, NVDA_TOKEN, NVDA_FEED, NVDA_POOL, NVDA_MIN_LIQUIDITY, NVDA_STRIKE_TICK,
///        TSLA_TOKEN, TSLA_FEED, TSLA_STRIKE_TICK                 registry ops/markets/tier1.json
///        PREMIUM_FEE_BPS, RESALE_FEE_BPS, TAKER_FEE_FLAT, TAKER_FEE_CAP_BPS, MAKER_REBATE_BPS, EXERCISE_FEE_BPS
///                                           registry `v2.fees` (0 from INTERFACE_VERSION 7, 0, 100000, 1000, 5000, 25)
///        MINT_FEE_PPM                       registry `v2.fees.mintFeePpm`: the collateral rent every dev market is
///                                           registered with, millionths per MINT_FEE_PERIOD (devnet 0; <= 5000)
///        MAX_DEVIATION_BPS, UNCORROBORATED_DELAY_S, SPOT_MAX_AGE_S   registry `v2.defaults` (150, 21600, 90000 —
///                                           25 h, what `ops/devnet/up.sh` passes; this script's own fallback is 3600)
///        BOUNTY_SNAPSHOT, BOUNTY_FINALIZE, BOUNTY_SETTLE, BOUNTY_REDEEM, BOUNTY_ROLL, BOUNTY_CANCEL_STALE
///                                           USDG base units (devnet: 50000, 50000, 50000, 20000, 50000, 20000)
///        KEEPER_DAILY_CAP, KEEPER_FUND      USDG base units (devnet: 100 USDG, 1,000 USDG)
///        DEV_MOCK_FEED                      1 (default) | 0
///        DEV_HOLIDAYS                       comma-separated day indexes
///        DEV_AUTO_ROLLER, DEV_PAYOUT_ADAPTER, DEV_MAKER_SUITE    auto | 0 | 1
///        SWAP_ROUTER_02                     registry `v2.uniswapV3.swapRouter02` (0xCaf681a6...5cb2)
///        PAYOUT_SLIPPAGE_BPS                Clearinghouse conversion bound, bps (30, the launch bound; ceiling 300)
///        MM_MAX_SERIES_UNITS, MM_MAX_TOTAL_NOTIONAL, MM_ASK_TOLERANCE_BPS, MM_MAX_BID_BPS_OF_SPOT,
///        MM_MAX_ORDER_LIFETIME_S, MM_MAX_DAILY_OUTFLOW
///                                           MakerVault limits (10_000 units, 250,000 USDG, 100, 1_000, 0, 2,500 USDG)
///        DEVNET_OUT                         JSON path, default broadcast/devnet/devdeploy.json (foundry.toml
///                                           allows writes under ./broadcast only); "" writes nothing
///
///      `runWith(Inputs)` is the whole procedure with explicit inputs and no node checks; the tests drive it.
contract DevDeploy is Script {
    /*//////////////////////////////////////////////////////////////
                         CHAIN 4663 (the registry)
    //////////////////////////////////////////////////////////////*/

    address public constant USDG_4663 = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address public constant NVDA_4663 = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address public constant NVDA_FEED_4663 = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address public constant NVDA_POOL_4663 = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;
    address public constant TSLA_4663 = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address public constant TSLA_FEED_4663 = 0x4A1166a659A55625345e9515b32adECea5547C38;
    /// @notice Uniswap SwapRouter02 on 4663 (registry `v2.uniswapV3.swapRouter02`).
    address public constant SWAP_ROUTER_02_4663 = 0xCaf681a66D020601342297493863E78C959E5cb2;

    /// @notice ERC-1155 metadata base (INTERFACE-CHANGES v4 clarification).
    string public constant BASE_URI = "https://app.stonkhouse.fun/api/token/";

    /// @notice Real-feed rounds copied into each mock, oldest first, before the fresh round stamped now.
    uint256 public constant MOCK_HISTORY_ROUNDS = 8;

    /// @dev anvil's default mnemonic accounts #0, #1, #2, #9 and #10 ("test test ... junk"): public dev accounts.
    address internal constant ANVIL_0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address internal constant ANVIL_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address internal constant ANVIL_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address internal constant ANVIL_9 = 0xa0Ee7A142d267C1f36714E4a8F75612F20a79720;
    address internal constant ANVIL_10 = 0xBcd4042DE499D14e55001CcbB24a551F3b954096;

    uint256 private constant AGGREGATOR_ROUND_MASK = type(uint64).max;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Periphery switch: Auto deploys when the hook is implemented, Off never calls it, Required reverts
    ///         PeripheryMissing when it returns nothing.
    enum Flag {
        Auto,
        Off,
        Required
    }

    /// @notice One market to register.
    struct MarketIn {
        string ticker;
        address underlying; // 18-dp Stock Token
        address feed; // the real Chainlink proxy
        address pool; // USDG/underlying Uniswap v3 pool; address(0) = Chainlink only
        uint128 minLiquidity; // pool L units
        uint64 strikeTick; // USDG base units per share
    }

    struct Inputs {
        address admin;
        address guardian;
        address feeRecipient;
        address pricer;
        address mmQuoter;
        address usdg;
        MarketIn[] markets;
        bool mockFeed;
        uint32[] holidays;
        V2Types.FeeParams fees;
        uint16 exerciseFeeBps;
        uint16 maxDeviationBps;
        uint32 uncorroboratedDelay; // seconds
        uint32 spotMaxAge; // seconds
        uint256 bountySnapshot; // USDG base units
        uint256 bountyFinalize;
        uint256 bountySettle;
        uint256 bountyRedeem;
        uint256 bountyRoll;
        uint256 bountyCancelStale; // v7 (c16): AutoRoller.cancelStale, BOUNTY_CANCEL_STALE
        uint256 dailyCap; // USDG base units per rolling 24 h
        uint256 fund; // USDG base units pulled from admin into KeeperRewards
        Flag autoRoller;
        Flag payoutAdapter;
        Flag makerSuite;
        address swapRouter; // SwapRouter02 the PayoutAdapter swaps through
        uint16 payoutSlippageBps; // Clearinghouse conversion bound, bps
        MakerVault.Limits vaultLimits;
        /// @dev v7 (c05): the collateral-rent rate every dev market is registered with, MINT_FEE_PPM. Millionths of
        ///      the locked collateral per MINT_FEE_PERIOD of remaining life, at most MINT_FEE_CEIL_PPM.
        uint32 mintFeePpm;
    }

    /// @notice What was deployed for one market.
    struct MarketOut {
        string ticker;
        address underlying;
        address realFeed;
        address feed; // what ChainlinkFeedSource reads: the mock when mockFeed, else realFeed
        address pool;
        address[] sources; // SettlementOracle priority order
    }

    struct Deployment {
        ExpiryCalendar calendar;
        ChainlinkFeedSource chainlink;
        UniV3TwapSource univ3;
        SettlementOracle oracle;
        Clearinghouse clearinghouse;
        OrderBook orderBook;
        KeeperRewards keeperRewards;
        // periphery: address(0) when its flag is off or its hook skipped
        address autoRoller;
        address payoutAdapter;
        address makerVault;
        address makerRegistry;
        address rewardsDistributor;
        MarketOut[] markets;
    }

    error NotAnvil(string clientVersion);
    error WrongChain(uint256 chainId);
    error AdminUnderfunded(uint256 have, uint256 need);
    error PeripheryMissing(string what);
    error BadFlag(string name, string value);
    error RouteMismatch(string ticker, address routed, address pool);

    /*//////////////////////////////////////////////////////////////
                                 ENTRY
    //////////////////////////////////////////////////////////////*/

    /// @notice Env-driven entry for `forge script`: node checks, deploy, JSON.
    function run() external returns (Deployment memory d) {
        if (block.chainid != 4663) revert WrongChain(block.chainid);
        string memory client = string(vm.rpc("web3_clientVersion", "[]"));
        if (!_contains(client, "anvil/")) revert NotAnvil(client);

        Inputs memory in_ = inputsFromEnv();
        d = runWith(in_);

        string memory out = vm.envOr("DEVNET_OUT", string("broadcast/devnet/devdeploy.json"));
        if (bytes(out).length != 0) {
            vm.writeFile(out, toJson(in_, d));
            console2.log("addresses written to", out);
        }
    }

    /// @notice The whole deploy with explicit inputs, broadcast from `in_.admin`.
    function runWith(Inputs memory in_) public returns (Deployment memory d) {
        uint256 adminUsdg = IERC20(in_.usdg).balanceOf(in_.admin);
        if (adminUsdg < in_.fund) revert AdminUnderfunded(adminUsdg, in_.fund);

        vm.startBroadcast(in_.admin);

        // 1. feeds
        uint256 n = in_.markets.length;
        address[] memory feeds = new address[](n);
        for (uint256 i; i < n; ++i) {
            feeds[i] = in_.mockFeed ? address(_deployMockFeed(in_.markets[i])) : in_.markets[i].feed;
        }

        // 2-4. calendar, sources, oracle
        d.calendar = new ExpiryCalendar(in_.admin, in_.holidays);
        d.chainlink = new ChainlinkFeedSource(in_.admin);
        d.univ3 = new UniV3TwapSource(in_.admin, in_.usdg);
        d.oracle = new SettlementOracle(in_.admin, in_.guardian);
        d.markets = new MarketOut[](n);
        for (uint256 i; i < n; ++i) {
            MarketIn memory m = in_.markets[i];
            d.chainlink
                .setFeed(
                    m.underlying, feeds[i], d.chainlink.DEFAULT_MAX_STALE(), d.chainlink.DEFAULT_MAX_ROUND_JUMP_BPS()
                );
            address[] memory sources = new address[](m.pool == address(0) ? 1 : 2);
            sources[0] = address(d.chainlink);
            if (m.pool != address(0)) {
                d.univ3.setPool(m.underlying, m.pool, m.minLiquidity, d.univ3.DEFAULT_WINDOW());
                sources[1] = address(d.univ3);
            }
            d.oracle.setMarket(m.underlying, sources, in_.maxDeviationBps, in_.uncorroboratedDelay, in_.spotMaxAge);
            d.markets[i] = MarketOut({
                ticker: m.ticker,
                underlying: m.underlying,
                realFeed: m.feed,
                feed: feeds[i],
                pool: m.pool,
                sources: sources
            });
        }

        // 5. clearinghouse
        d.clearinghouse = new Clearinghouse(in_.admin, in_.usdg, address(d.calendar), in_.feeRecipient, BASE_URI);
        d.clearinghouse.grantRole(V2Constants.GUARDIAN_ROLE, in_.guardian);
        for (uint256 i; i < n; ++i) {
            d.clearinghouse
                .registerMarket(
                    in_.markets[i].underlying,
                    V2Types.MarketConfig({
                        enabled: true,
                        mintPaused: false,
                        strikeTick: in_.markets[i].strikeTick,
                        exerciseFeeBps: in_.exerciseFeeBps,
                        oracle: address(d.oracle),
                        mintFeePpm: in_.mintFeePpm
                    })
                );
        }

        // 6. order book
        d.orderBook = new OrderBook(
            IClearinghouse(address(d.clearinghouse)), in_.admin, in_.guardian, in_.feeRecipient, in_.fees
        );

        // 7. keeper rewards and the bounty wiring
        d.keeperRewards = new KeeperRewards(IERC20(in_.usdg), in_.admin);
        d.keeperRewards.setCaller(address(d.oracle), true);
        d.keeperRewards.setCaller(address(d.clearinghouse), true);
        d.keeperRewards.setBounty(V2Constants.ACTION_SNAPSHOT, in_.bountySnapshot);
        d.keeperRewards.setBounty(V2Constants.ACTION_FINALIZE, in_.bountyFinalize);
        d.keeperRewards.setBounty(V2Constants.ACTION_SETTLE, in_.bountySettle);
        d.keeperRewards.setBounty(V2Constants.ACTION_REDEEM, in_.bountyRedeem);
        d.keeperRewards.setBounty(V2Constants.ACTION_ROLL, in_.bountyRoll);
        // v7 (c16): the sixth action. Set here even when the AutoRoller is off, so a devnet that turns it on later
        // does not have to re-wire the rewards.
        d.keeperRewards.setBounty(V2Constants.ACTION_CANCEL_STALE, in_.bountyCancelStale);
        d.keeperRewards.setDailyCap(in_.dailyCap);
        if (in_.fund != 0) {
            IERC20(in_.usdg).approve(address(d.keeperRewards), in_.fund);
            d.keeperRewards.fund(in_.fund);
        }
        d.oracle.setClearinghouse(address(d.clearinghouse));
        d.oracle.setKeeperRewards(address(d.keeperRewards));
        d.clearinghouse.setKeeperRewards(address(d.keeperRewards));

        // 8. periphery extension points (plan F2-04 "Staging")
        if (in_.autoRoller != Flag.Off) {
            d.autoRoller = _deployAutoRoller(in_, d);
            if (d.autoRoller == address(0) && in_.autoRoller == Flag.Required) {
                revert PeripheryMissing("AutoRoller (C2-09)");
            }
        }
        if (in_.payoutAdapter != Flag.Off) {
            d.payoutAdapter = _deployPayoutAdapter(in_, d);
            if (d.payoutAdapter == address(0) && in_.payoutAdapter == Flag.Required) {
                revert PeripheryMissing("UniV3PayoutAdapter (C2-10)");
            }
        }
        if (in_.makerSuite != Flag.Off) {
            (d.makerVault, d.makerRegistry, d.rewardsDistributor) = _deployMakerSuite(in_, d);
            if (d.makerVault == address(0) && in_.makerSuite == Flag.Required) {
                revert PeripheryMissing("MakerVault, MakerRegistry, RewardsDistributor (C2-11)");
            }
        }

        // 9. the sources accept the oracle's pins (INTERFACE_VERSION 6). Last, so no contract address moves; still
        //    before any series, which only ops/devnet/seed.mjs creates.
        d.chainlink.setOracle(address(d.oracle), true);
        d.univ3.setOracle(address(d.oracle), true);

        vm.stopBroadcast();
        _log(in_, d);
    }

    /*//////////////////////////////////////////////////////////////
                    PERIPHERY (C2-09, C2-10, C2-11)
    //////////////////////////////////////////////////////////////*/

    /// @notice C2-09: the AutoRoller, its pricer and its ROLL bounty payer.
    /// @dev Runs inside the admin broadcast, after the core wiring. The constructor reads the Clearinghouse and USDG
    ///      from the book; the ROLL bounty itself was set in step 7 (`in_.bountyRoll`), so here the roller only becomes
    ///      a KeeperRewards caller. ops/devnet/seed.mjs onboards one writer and rolls it.
    function _deployAutoRoller(Inputs memory in_, Deployment memory d) internal virtual returns (address) {
        AutoRoller roller = new AutoRoller(IOrderBook(address(d.orderBook)), in_.admin);
        if (in_.pricer != address(0)) roller.grantRole(V2Constants.PRICER_ROLE, in_.pricer);
        roller.setKeeperRewards(address(d.keeperRewards));
        d.keeperRewards.setCaller(address(roller), true);
        return address(roller);
    }

    /// @notice C2-10: the Uniswap v3 PayoutAdapter, a route per market with a pool, and the Clearinghouse pointed at it.
    ///         address(0) when `in_.swapRouter` has no code (not a 4663 node, and no mock router given).
    /// @dev A route uses the fee tier of the market's own pool (`in_.markets[i].pool.fee()`, NVDA/USDG 0.05 % = 500),
    ///      and the factory the router swaps through must return that very pool (RouteMismatch otherwise), so the pool
    ///      the TWAP source reads and the pool payouts sell into are one pool. Markets without a pool (TSLA on the
    ///      devnet) get no route and are paid in kind.
    function _deployPayoutAdapter(Inputs memory in_, Deployment memory d) internal virtual returns (address) {
        if (in_.swapRouter.code.length == 0) return address(0);
        UniV3PayoutAdapter adapter = new UniV3PayoutAdapter(in_.admin, in_.usdg, in_.swapRouter);
        for (uint256 i; i < in_.markets.length; ++i) {
            MarketIn memory m = in_.markets[i];
            if (m.pool == address(0)) continue;
            adapter.setRoute(m.underlying, IDevDeployPoolFee(m.pool).fee());
            (address routed,) = adapter.routes(m.underlying);
            if (routed != m.pool) revert RouteMismatch(m.ticker, routed, m.pool);
        }
        d.clearinghouse.setPayoutAdapter(address(adapter), in_.payoutSlippageBps);
        return address(adapter);
    }

    /// @notice C2-11: MakerRegistry (wired into the book), MakerVault (QUOTER_ROLE to the MM quoter) and
    ///         RewardsDistributor.
    /// @dev The vault's constructor makes the book its Clearinghouse operator and ERC-1155 / USDG spender. It starts
    ///      empty: ops/devnet/seed.mjs funds it (admin deposit), moves collateral into its Clearinghouse ledger and
    ///      places its quotes. No maker tier is set (every maker gets the book's makerRebateBps).
    function _deployMakerSuite(Inputs memory in_, Deployment memory d)
        internal
        virtual
        returns (address vault, address registry, address distributor)
    {
        MakerRegistry makers = new MakerRegistry(in_.admin);
        d.orderBook.setMakerRegistry(IMakerRegistry(address(makers)));
        MakerVault mv = new MakerVault(IOrderBook(address(d.orderBook)), in_.admin, in_.mmQuoter, in_.vaultLimits);
        RewardsDistributor rd = new RewardsDistributor(IERC20(in_.usdg), in_.admin);
        return (address(mv), address(makers), address(rd));
    }

    /*//////////////////////////////////////////////////////////////
                                 INPUTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Inputs from the environment, defaulting to the registry values of 2026-09-16 and anvil accounts.
    function inputsFromEnv() public view returns (Inputs memory in_) {
        in_.admin = vm.envOr("ADMIN", ANVIL_0);
        in_.guardian = vm.envOr("GUARDIAN", ANVIL_1);
        in_.feeRecipient = vm.envOr("FEE_RECIPIENT", ANVIL_2);
        in_.pricer = vm.envOr("DEV_PRICER", ANVIL_9);
        in_.mmQuoter = vm.envOr("DEV_MM_QUOTER", ANVIL_10);
        in_.usdg = vm.envOr("USDG", USDG_4663);

        in_.markets = new MarketIn[](2);
        in_.markets[0] = MarketIn({
            ticker: "NVDA",
            underlying: vm.envOr("NVDA_TOKEN", NVDA_4663),
            feed: vm.envOr("NVDA_FEED", NVDA_FEED_4663),
            pool: vm.envOr("NVDA_POOL", NVDA_POOL_4663),
            minLiquidity: uint128(vm.envOr("NVDA_MIN_LIQUIDITY", uint256(1.7e18))),
            strikeTick: uint64(vm.envOr("NVDA_STRIKE_TICK", uint256(2_500_000)))
        });
        in_.markets[1] = MarketIn({
            ticker: "TSLA",
            underlying: vm.envOr("TSLA_TOKEN", TSLA_4663),
            feed: vm.envOr("TSLA_FEED", TSLA_FEED_4663),
            pool: address(0), // Chainlink only on the devnet (plan F2-04)
            minLiquidity: 0,
            strikeTick: uint64(vm.envOr("TSLA_STRIKE_TICK", uint256(2_500_000)))
        });

        in_.mockFeed = vm.envOr("DEV_MOCK_FEED", uint256(1)) != 0;
        uint256[] memory days_ = vm.envOr("DEV_HOLIDAYS", ",", _defaultHolidays());
        in_.holidays = new uint32[](days_.length);
        for (uint256 i; i < days_.length; ++i) {
            in_.holidays[i] = uint32(days_[i]);
        }

        // v7 (c05): the writer fee is collateral rent at mint, so the premium fee on the book is 0 at launch and on
        // every dev deploy. DeployV2/VerifyV2 refuse premiumFeeBps > resaleFeeBps; 0/0 satisfies it.
        in_.fees = V2Types.FeeParams({
            premiumFeeBps: uint16(vm.envOr("PREMIUM_FEE_BPS", uint256(0))),
            resaleFeeBps: uint16(vm.envOr("RESALE_FEE_BPS", uint256(0))),
            takerFeeFlat: uint32(vm.envOr("TAKER_FEE_FLAT", uint256(100_000))),
            takerFeeCapBps: uint16(vm.envOr("TAKER_FEE_CAP_BPS", uint256(1000))),
            makerRebateBps: uint16(vm.envOr("MAKER_REBATE_BPS", uint256(5000)))
        });
        in_.exerciseFeeBps = uint16(vm.envOr("EXERCISE_FEE_BPS", uint256(25)));
        in_.maxDeviationBps = uint16(vm.envOr("MAX_DEVIATION_BPS", uint256(150)));
        in_.uncorroboratedDelay = uint32(vm.envOr("UNCORROBORATED_DELAY_S", uint256(21_600)));
        in_.spotMaxAge = uint32(vm.envOr("SPOT_MAX_AGE_S", uint256(3600)));

        in_.bountySnapshot = vm.envOr("BOUNTY_SNAPSHOT", uint256(50_000));
        in_.bountyFinalize = vm.envOr("BOUNTY_FINALIZE", uint256(50_000));
        in_.bountySettle = vm.envOr("BOUNTY_SETTLE", uint256(50_000));
        in_.bountyRedeem = vm.envOr("BOUNTY_REDEEM", uint256(20_000));
        in_.bountyRoll = vm.envOr("BOUNTY_ROLL", uint256(50_000));
        in_.bountyCancelStale = vm.envOr("BOUNTY_CANCEL_STALE", uint256(20_000));
        in_.dailyCap = vm.envOr("KEEPER_DAILY_CAP", uint256(100e6));
        in_.fund = vm.envOr("KEEPER_FUND", uint256(1000e6));

        in_.autoRoller = _flag("DEV_AUTO_ROLLER");
        in_.payoutAdapter = _flag("DEV_PAYOUT_ADAPTER");
        in_.makerSuite = _flag("DEV_MAKER_SUITE");
        in_.swapRouter = vm.envOr("SWAP_ROUTER_02", SWAP_ROUTER_02_4663);
        in_.payoutSlippageBps = uint16(vm.envOr("PAYOUT_SLIPPAGE_BPS", uint256(30)));
        in_.vaultLimits = MakerVault.Limits({
            maxSeriesUnits: uint64(vm.envOr("MM_MAX_SERIES_UNITS", uint256(10_000))),
            maxTotalNotional: uint128(vm.envOr("MM_MAX_TOTAL_NOTIONAL", uint256(250_000e6))),
            askToleranceBps: uint16(vm.envOr("MM_ASK_TOLERANCE_BPS", uint256(100))),
            maxBidBpsOfSpot: uint16(vm.envOr("MM_MAX_BID_BPS_OF_SPOT", uint256(1_000))),
            maxOrderLifetime: uint32(vm.envOr("MM_MAX_ORDER_LIFETIME_S", uint256(0))),
            // v7 (c21): net USDG the quoter may pay out at once, refilling over MakerVault.OUTFLOW_WINDOW.
            maxDailyOutflow: uint128(vm.envOr("MM_MAX_DAILY_OUTFLOW", uint256(2_500e6)))
        });
        in_.mintFeePpm = uint32(vm.envOr("MINT_FEE_PPM", uint256(0)));
    }

    /// @notice NYSE full-day closures 2026-2028 as day indexes (callhouse ops/markets/v2-sources.json, R13).
    function _defaultHolidays() internal pure returns (uint256[] memory h) {
        uint16[29] memory closures = [
            20454,
            20472,
            20500,
            20546,
            20598,
            20623,
            20637,
            20703,
            20783,
            20812, // 2026
            20819,
            20836,
            20864,
            20903,
            20969,
            20987,
            21004,
            21067,
            21147,
            21176, // 2027
            21200,
            21235,
            21288,
            21333,
            21354,
            21369,
            21431,
            21511,
            21543 // 2028
        ];
        h = new uint256[](closures.length);
        for (uint256 i; i < closures.length; ++i) {
            h[i] = closures[i];
        }
    }

    function _flag(string memory name) internal view returns (Flag) {
        string memory v = vm.envOr(name, string("auto"));
        bytes32 k = keccak256(bytes(v));
        if (k == keccak256("auto") || k == keccak256("")) return Flag.Auto;
        if (k == keccak256("0")) return Flag.Off;
        if (k == keccak256("1")) return Flag.Required;
        revert BadFlag(name, v);
    }

    /*//////////////////////////////////////////////////////////////
                                  FEEDS
    //////////////////////////////////////////////////////////////*/

    /// @dev A MockRoundFeed with the real feed's decimals, its last MOCK_HISTORY_ROUNDS rounds of the current phase
    ///      (oldest first, real answers and timestamps) and one more round with the latest answer stamped now.
    function _deployMockFeed(MarketIn memory m) internal returns (MockRoundFeed mock) {
        IAggregatorV3 real = IAggregatorV3(m.feed);
        mock = new MockRoundFeed(real.decimals(), string.concat("DEVNET MOCK RH", m.ticker, " / USD"));

        (uint80 id, int256 latestAnswer,, uint256 latestAt,) = real.latestRoundData();
        int256[] memory answers = new int256[](MOCK_HISTORY_ROUNDS);
        uint256[] memory times = new uint256[](MOCK_HISTORY_ROUNDS);
        uint256 count;
        answers[count] = latestAnswer;
        times[count] = latestAt;
        ++count;
        while (count < MOCK_HISTORY_ROUNDS && (id & AGGREGATOR_ROUND_MASK) > 1) {
            --id;
            (, int256 a,, uint256 t,) = real.getRoundData(id);
            if (t == 0) break;
            answers[count] = a;
            times[count] = t;
            ++count;
        }
        for (uint256 i = count; i > 0; --i) {
            mock.push(answers[i - 1], times[i - 1]);
        }
        mock.push(latestAnswer, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                                  JSON
    //////////////////////////////////////////////////////////////*/

    /// @notice The deployment as JSON. `contracts` mirrors the registry's `v2.contracts` (null = not deployed).
    function toJson(Inputs memory in_, Deployment memory d) public view returns (string memory) {
        string memory markets;
        for (uint256 i; i < d.markets.length; ++i) {
            MarketOut memory m = d.markets[i];
            string memory sources;
            for (uint256 j; j < m.sources.length; ++j) {
                sources = string.concat(sources, j == 0 ? "" : ", ", _q(vm.toString(m.sources[j])));
            }
            markets = string.concat(
                markets,
                i == 0 ? "" : ",",
                "\n    {\"ticker\": ",
                _q(m.ticker),
                ", \"underlying\": ",
                _addr(m.underlying),
                ", \"feed\": ",
                _addr(m.feed),
                ", \"realFeed\": ",
                _addr(m.realFeed),
                ", \"mockFeed\": ",
                in_.mockFeed ? _addr(m.feed) : "null",
                ", \"pool\": ",
                _addr(m.pool),
                ", \"strikeTick\": ",
                _q(vm.toString(uint256(in_.markets[i].strikeTick))),
                ", \"sources\": [",
                sources,
                "]}"
            );
        }
        string memory contracts = string.concat(
            "{\n    \"clearinghouse\": ",
            _addr(address(d.clearinghouse)),
            ",\n    \"orderBook\": ",
            _addr(address(d.orderBook)),
            ",\n    \"settlementOracle\": ",
            _addr(address(d.oracle)),
            ",\n    \"expiryCalendar\": ",
            _addr(address(d.calendar)),
            ",\n    \"keeperRewards\": ",
            _addr(address(d.keeperRewards)),
            ",\n    \"autoRoller\": ",
            _addr(d.autoRoller),
            ",\n    \"payoutAdapter\": ",
            _addr(d.payoutAdapter),
            ",\n    \"makerVault\": ",
            _addr(d.makerVault),
            ",\n    \"makerRegistry\": ",
            _addr(d.makerRegistry),
            ",\n    \"rewardsDistributor\": ",
            _addr(d.rewardsDistributor),
            ",\n    \"sources\": {\"chainlink\": ",
            _addr(address(d.chainlink)),
            ", \"univ3\": ",
            _addr(address(d.univ3)),
            ", \"dataStreams\": null}\n  }"
        );
        string memory config = string.concat(_configFeesJson(in_), _configRestJson(in_));
        return string.concat(
            "{\n  \"chainId\": ",
            vm.toString(block.chainid),
            ",\n  \"mockFeed\": ",
            in_.mockFeed ? "true" : "false",
            ",\n  \"roles\": {\"admin\": ",
            _addr(in_.admin),
            ", \"guardian\": ",
            _addr(in_.guardian),
            ", \"feeRecipient\": ",
            _addr(in_.feeRecipient),
            ", \"pricer\": ",
            _addr(in_.pricer),
            ", \"mmQuoter\": ",
            _addr(in_.mmQuoter),
            "},\n  \"usdg\": ",
            _addr(in_.usdg),
            ",\n  \"contracts\": ",
            contracts,
            ",\n  \"markets\": [",
            markets,
            "\n  ],\n  \"config\": ",
            config,
            "\n}\n"
        );
    }

    /// @dev MakerVault.Limits in the vault's units: amounts as decimal strings (USDG base units can pass 2^53).
    /// @dev The `config` object's fee half. Split from {_configRestJson} only because one `string.concat` of the
    ///      whole object runs the via_ir stack out of slots.
    function _configFeesJson(Inputs memory in_) internal pure returns (string memory) {
        return string.concat(
            "{\"premiumFeeBps\": ",
            vm.toString(uint256(in_.fees.premiumFeeBps)),
            ", \"resaleFeeBps\": ",
            vm.toString(uint256(in_.fees.resaleFeeBps)),
            ", \"takerFeeFlat\": ",
            _q(vm.toString(uint256(in_.fees.takerFeeFlat))),
            ", \"takerFeeCapBps\": ",
            vm.toString(uint256(in_.fees.takerFeeCapBps)),
            ", \"makerRebateBps\": ",
            vm.toString(uint256(in_.fees.makerRebateBps)),
            ", \"exerciseFeeBps\": ",
            vm.toString(uint256(in_.exerciseFeeBps)),
            ", \"mintFeePpm\": ",
            vm.toString(uint256(in_.mintFeePpm))
        );
    }

    /// @dev The `config` object's remaining half, closing brace included.
    function _configRestJson(Inputs memory in_) internal pure returns (string memory) {
        return string.concat(
            ", \"bountyCancelStale\": ",
            _q(vm.toString(in_.bountyCancelStale)),
            ", \"maxDeviationBps\": ",
            vm.toString(uint256(in_.maxDeviationBps)),
            ", \"uncorroboratedDelayS\": ",
            vm.toString(uint256(in_.uncorroboratedDelay)),
            ", \"spotMaxAgeS\": ",
            vm.toString(uint256(in_.spotMaxAge)),
            ", \"keeperDailyCap\": ",
            _q(vm.toString(in_.dailyCap)),
            ", \"keeperFund\": ",
            _q(vm.toString(in_.fund)),
            ", \"swapRouter02\": ",
            _addr(in_.swapRouter),
            ", \"payoutSlippageBps\": ",
            vm.toString(uint256(in_.payoutSlippageBps)),
            ", \"makerVaultLimits\": ",
            _vaultLimitsJson(in_.vaultLimits),
            "}"
        );
    }

    function _vaultLimitsJson(MakerVault.Limits memory l) internal pure returns (string memory) {
        return string.concat(
            "{\"maxSeriesUnits\": ",
            vm.toString(uint256(l.maxSeriesUnits)),
            ", \"maxTotalNotional\": ",
            _q(vm.toString(uint256(l.maxTotalNotional))),
            ", \"askToleranceBps\": ",
            vm.toString(uint256(l.askToleranceBps)),
            ", \"maxBidBpsOfSpot\": ",
            vm.toString(uint256(l.maxBidBpsOfSpot)),
            ", \"maxOrderLifetimeS\": ",
            vm.toString(uint256(l.maxOrderLifetime)),
            ", \"maxDailyOutflow\": ",
            _q(vm.toString(uint256(l.maxDailyOutflow))),
            "}"
        );
    }

    function _addr(address a) internal pure returns (string memory) {
        return a == address(0) ? "null" : _q(vm.toString(a));
    }

    function _q(string memory s) internal pure returns (string memory) {
        return string.concat("\"", s, "\"");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _log(Inputs memory in_, Deployment memory d) internal pure {
        console2.log("DevDeploy (devnet only), admin", in_.admin);
        console2.log("  ExpiryCalendar     ", address(d.calendar));
        console2.log("  ChainlinkFeedSource", address(d.chainlink));
        console2.log("  UniV3TwapSource    ", address(d.univ3));
        console2.log("  SettlementOracle   ", address(d.oracle));
        console2.log("  Clearinghouse      ", address(d.clearinghouse));
        console2.log("  OrderBook          ", address(d.orderBook));
        console2.log("  KeeperRewards      ", address(d.keeperRewards));
        console2.log("  AutoRoller         ", d.autoRoller);
        console2.log("  PayoutAdapter      ", d.payoutAdapter);
        console2.log("  MakerVault         ", d.makerVault);
        console2.log("  MakerRegistry      ", d.makerRegistry);
        console2.log("  RewardsDistributor ", d.rewardsDistributor);
        for (uint256 i; i < d.markets.length; ++i) {
            console2.log("  market", d.markets[i].ticker, "feed", d.markets[i].feed);
        }
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i; i + n.length <= h.length; ++i) {
            bool eq = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    eq = false;
                    break;
                }
            }
            if (eq) return true;
        }
        return false;
    }
}
