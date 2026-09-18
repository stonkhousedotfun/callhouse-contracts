// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeployV2Fixture} from "./DeployV2Fixture.t.sol";
import {RegisterMarkets} from "../../../script/v2/RegisterMarkets.s.sol";
import {V2DeployBase} from "../../../script/v2/lib/V2DeployBase.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {ExpiryCalendar} from "../../../src/v2/ExpiryCalendar.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {ChainlinkFeedSource} from "../../../src/v2/oracle/ChainlinkFeedSource.sol";
import {SettlementOracle} from "../../../src/v2/oracle/SettlementOracle.sol";
import {UniV3TwapSource} from "../../../src/v2/oracle/UniV3TwapSource.sol";
import {UniV3PayoutAdapter} from "../../../src/v2/periphery/UniV3PayoutAdapter.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../../src/mocks/MockStockToken.sol";
import {MockRoundFeed} from "../../../src/v2/mocks/MockRoundFeed.sol";
import {MockUniV3Pool} from "../../../src/v2/mocks/MockUniV3Pool.sol";

/// @notice `script/v2/RegisterMarkets.s.sol` over the mocks on a set deployed by DeployV2: NVDA with its pool (two
///         sources, payout route) and TSLA Chainlink-only are configured and registered, a re-run sends nothing, a
///         config drift is repaired, and each preflight refusal reverts with its message before any call is sent.
/// @dev The refusals run in ONE function, in order, as test/unit/DeploySoloPreflight.t.sol does.
contract RegisterMarketsPreflightTest is DeployV2Fixture {
    V2DeployBase.Contracts internal d;

    function setUp() public override {
        super.setUp();
        d = _deploy();
    }

    function test_register_nvdaWithPoolAndTslaChainlinkOnly() public {
        (uint256 registered, uint256 sent) = registerScript.runWith(_registerInputs(d), _signer(admin));
        assertEq(registered, 2, "two registerMarket calls");
        // NVDA: setFeed, setPool, setMarket, setRoute, registerMarket; TSLA: setFeed, setMarket, registerMarket
        assertEq(sent, 8, "8 admin calls");

        Clearinghouse ch = Clearinghouse(d.clearinghouse);
        V2Types.MarketConfig memory n = ch.market(address(nvda));
        assertTrue(n.enabled && !n.mintPaused, "NVDA enabled");
        assertEq(n.strikeTick, TICK_2_50);
        assertEq(n.exerciseFeeBps, 25);
        assertEq(n.oracle, d.settlementOracle);
        assertEq(ch.market(address(tsla)).strikeTick, TICK_2_50, "TSLA registered");

        (address feed, uint32 stale, uint16 jump) = ChainlinkFeedSource(d.chainlinkSource).feeds(address(nvda));
        assertEq(feed, address(nvdaFeed));
        assertEq(stale, 26 hours);
        assertEq(jump, 2000);
        (address p,,, uint32 window, uint128 floor) = UniV3TwapSource(d.univ3Source).pools(address(nvda));
        assertEq(p, address(pool));
        assertEq(window, 300);
        assertEq(floor, NVDA_FLOOR);
        (p,,,,) = UniV3TwapSource(d.univ3Source).pools(address(tsla));
        assertEq(p, address(0), "TSLA has no pool");

        (address[] memory sources, uint16 dev, uint32 delay, uint32 age) =
            SettlementOracle(d.settlementOracle).marketConfig(address(nvda));
        assertEq(sources.length, 2);
        assertEq(sources[0], d.chainlinkSource);
        assertEq(sources[1], d.univ3Source);
        assertEq(dev, 150);
        assertEq(delay, 21_600);
        assertEq(age, 3600);
        (sources,,,) = SettlementOracle(d.settlementOracle).marketConfig(address(tsla));
        assertEq(sources.length, 1, "TSLA: Chainlink only");
        assertEq(sources[0], d.chainlinkSource);

        (address routePool, uint24 fee) = UniV3PayoutAdapter(d.payoutAdapter).routes(address(nvda));
        assertEq(routePool, address(pool), "NVDA route");
        assertEq(fee, 500);
        (, fee) = UniV3PayoutAdapter(d.payoutAdapter).routes(address(tsla));
        assertEq(fee, 0, "TSLA no route");
        (bool ok, uint256 spot,) = SettlementOracle(d.settlementOracle).trySpot(address(tsla));
        assertTrue(ok, "TSLA spot through the registered source");
        assertEq(spot, 358_040_000, "358.04: the last pushed round");

        // idempotent
        (registered, sent) = registerScript.runWith(_registerInputs(d), _signer(admin));
        assertEq(registered, 0, "nothing registered twice");
        assertEq(sent, 0, "nothing sent twice");

        // a drifted source config is put back; the registration is not repeated
        vm.prank(admin);
        UniV3PayoutAdapter(d.payoutAdapter).setRoute(address(nvda), 0);
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        (RegisterMarkets.Call[] memory calls, bool registers) = registerScript.plan(in_, in_.markets[0]);
        assertEq(calls.length, 1, "one call: the route");
        assertFalse(registers, "no registration");
        (registered, sent) = registerScript.runWith(in_, _signer(admin));
        assertEq(sent, 1);
        (routePool,) = UniV3PayoutAdapter(d.payoutAdapter).routes(address(nvda));
        assertEq(routePool, address(pool), "route restored");

        // a source that stopped accepting the oracle's pins is re-allowed first (DeployV2 wired both; TSLA needs only
        // Chainlink, so the pool source is NVDA's call alone)
        vm.startPrank(admin);
        ChainlinkFeedSource(d.chainlinkSource).setOracle(d.settlementOracle, false);
        UniV3TwapSource(d.univ3Source).setOracle(d.settlementOracle, false);
        vm.stopPrank();
        in_ = _registerInputs(d);
        (calls,) = registerScript.plan(in_, in_.markets[0]);
        assertEq(calls.length, 2, "NVDA: both sources re-allowed");
        assertEq(calls[0].what, "chainlinkSource.setOracle(settlementOracle, true)", "Chainlink first");
        assertEq(calls[1].what, "univ3Source.setOracle(settlementOracle, true)");
        (calls,) = registerScript.plan(in_, in_.markets[1]);
        assertEq(calls.length, 1, "TSLA: Chainlink only");
        (registered, sent) = registerScript.runWith(in_, _signer(admin));
        assertEq(sent, 2, "sent once, for NVDA; TSLA's plan is empty by then");
        assertTrue(ChainlinkFeedSource(d.chainlinkSource).isOracle(d.settlementOracle), "chainlink re-allowed");
        assertTrue(UniV3TwapSource(d.univ3Source).isOracle(d.settlementOracle), "pool re-allowed");
    }

    /// A registry row that drops NVDA's pool: the plan unlists the pool source before it removes the pool, so after
    /// every single call a first series of a new expiry can still pin (pinning fails closed while the list names an
    /// unconfigured source).
    function test_register_droppedPool_unlistsBeforeUnconfiguring() public {
        registerScript.runWith(_registerInputs(d), _signer(admin));
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        (in_.markets[0].pool, in_.markets[0].minLiquidity, in_.markets[0].poolFee) = (address(0), 0, 0);
        (RegisterMarkets.Call[] memory calls,) = registerScript.plan(in_, in_.markets[0]);
        assertEq(calls.length, 3, "setMarket, setPool(0), clear the route");
        assertEq(calls[0].to, d.settlementOracle, "the list first");
        assertEq(
            calls[1].what, "univ3Source.setPool(NVDA, 0): remove a pool the registry does not list", "then the pool"
        );
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(admin);
            (bool ok,) = calls[i].to.call(calls[i].data);
            assertTrue(ok, calls[i].what);
            uint256 snap = vm.snapshotState();
            vm.prank(d.clearinghouse);
            // casting to 'uint40' is safe because i < 3
            // forge-lint: disable-next-line(unsafe-typecast)
            SettlementOracle(d.settlementOracle).pin(address(nvda), uint40(2_000_000_000 + i));
            vm.revertToState(snap);
        }
        (address p,,,,) = UniV3TwapSource(d.univ3Source).pools(address(nvda));
        assertEq(p, address(0), "pool removed");
    }

    function test_preflight_everyRefusalInOrder() public {
        RegisterMarkets.Inputs memory in_;

        // ---------------------------------------------------------------- the contract set
        in_ = _registerInputs(d);
        in_.markets = new V2DeployBase.MarketIn[](0);
        _refused(in_, "V2_TICKERS is empty");

        in_ = _registerInputs(d);
        in_.c.payoutAdapter = address(0);
        _refused(in_, "V2_PAYOUT_ADAPTER is zero");

        MockERC20 otherUsdg = new MockERC20("Global Dollar", "USDG", 6);
        in_ = _registerInputs(d);
        in_.usdg = address(otherUsdg);
        _refused(
            in_,
            string.concat(
                "clearinghouse.usdg() ", vm.toString(address(usdg)), " is not V2_USDG ", vm.toString(address(otherUsdg))
            )
        );

        in_ = _registerInputs(d);
        in_.admin = guardian;
        _refused(
            in_,
            string.concat("V2_ADMIN ", vm.toString(guardian), " does not hold DEFAULT_ADMIN_ROLE on the Clearinghouse")
        );

        vm.prank(admin);
        SettlementOracle(d.settlementOracle).setClearinghouse(address(0));
        _refused(
            _registerInputs(d),
            "settlementOracle.clearinghouse() 0x0000000000000000000000000000000000000000 is not V2_CLEARINGHOUSE: every createSeries would revert in oracle.pin (run the deploy wiring first)"
        );
        vm.prank(admin);
        SettlementOracle(d.settlementOracle).setClearinghouse(d.clearinghouse);

        in_ = _registerInputs(d);
        in_.exerciseFeeBps = 201;
        _refused(in_, "V2_EXERCISE_FEE_BPS above EXERCISE_FEE_CEIL_BPS (200)");

        in_ = _registerInputs(d);
        in_.markets[1] = _nvdaMarket();
        _refused(in_, "duplicate ticker in V2_TICKERS");

        // ---------------------------------------------------------------- the token (TSLA row)
        MockStockToken aapl = new MockStockToken("Apple Stock Token", "AAPL");
        in_ = _registerInputs(d);
        in_.markets[1].asset = address(aapl);
        _refused(
            in_,
            string.concat(
                "asset symbol mismatch: V2_MARKET_TSLA_ASSET ",
                vm.toString(address(aapl)),
                " is \"AAPL\", ticker is \"TSLA\""
            )
        );

        MockERC20 sixDp = new MockERC20("Tesla", "TSLA", 6);
        in_ = _registerInputs(d);
        in_.markets[1].asset = address(sixDp);
        _refused(in_, "TSLA: asset decimals != 18");

        MockERC20 plain = new MockERC20("Tesla", "TSLA", 18);
        in_ = _registerInputs(d);
        in_.markets[1].asset = address(plain);
        _refused(in_, "TSLA: asset uiMultiplier() probe failed: not a Robinhood Stock Token?");

        tsla.setUiMultiplier(0);
        _refused(_registerInputs(d), "TSLA: asset uiMultiplier() == 0");
        tsla.setUiMultiplier(1e18);

        tsla.setOraclePaused(true);
        _refused(_registerInputs(d), "TSLA: asset oraclePaused() is true: the issuer has halted its oracle");
        tsla.setOraclePaused(false);

        // ---------------------------------------------------------------- the feed
        MockRoundFeed aaplFeed = _feed("Robinhood AAPL / USD", TSLA_ANSWER);
        in_ = _registerInputs(d);
        in_.markets[1].feed = address(aaplFeed);
        _refused(
            in_,
            string.concat(
                "feed description mismatch: V2_MARKET_TSLA_FEED ",
                vm.toString(address(aaplFeed)),
                " is \"Robinhood AAPL / USD\", ticker is \"TSLA\""
            )
        );

        MockRoundFeed sixDpFeed = new MockRoundFeed(6, "RHTSLA / USD");
        sixDpFeed.push(358_040000, START - 1 hours);
        in_ = _registerInputs(d);
        in_.markets[1].feed = address(sixDpFeed);
        _refused(in_, "TSLA: unexpected feed decimals");

        MockRoundFeed zeroFeed = new MockRoundFeed(8, "RHTSLA / USD");
        zeroFeed.push(0, START - 1 hours);
        in_ = _registerInputs(d);
        in_.markets[1].feed = address(zeroFeed);
        _refused(in_, "TSLA: feed answer <= 0");

        MockRoundFeed staleFeed = new MockRoundFeed(8, "RHTSLA / USD");
        staleFeed.push(TSLA_ANSWER, START - 5 days);
        in_ = _registerInputs(d);
        in_.markets[1].feed = address(staleFeed);
        _refused(in_, "TSLA: feed is stale: age 432000 s > V2_MAX_FEED_AGE_S 345600");

        // ---------------------------------------------------------------- parameters
        in_ = _registerInputs(d);
        in_.markets[1].strikeTick = 2_500_050;
        _refused(in_, "TSLA: strikeTick 2500050 must be a non-zero multiple of 100");

        in_ = _registerInputs(d);
        in_.markets[1].maxDeviationBps = 1001;
        _refused(in_, "TSLA: maxDeviationBps outside [1, 1000]");

        in_ = _registerInputs(d);
        in_.markets[1].uncorroboratedDelay = 600;
        _refused(in_, "TSLA: uncorroboratedDelay outside [1800, 86400] s");

        in_ = _registerInputs(d);
        in_.markets[1].spotMaxAge = 0;
        _refused(in_, "TSLA: spotMaxAge outside [1, 345600] s");

        in_ = _registerInputs(d);
        in_.markets[1].minLiquidity = 1;
        _refused(in_, "TSLA: univ3MinLiquidity set without a pool");

        // ---------------------------------------------------------------- the pool (NVDA row)
        MockUniV3Pool tslaPool = new MockUniV3Pool(address(usdg), address(tsla), 500);
        in_ = _registerInputs(d);
        in_.markets[0].pool = address(tslaPool);
        _refused(
            in_,
            string.concat(
                "NVDA: pool tokens ",
                vm.toString(address(usdg)),
                ", ",
                vm.toString(address(tsla)),
                " are not {asset, USDG}"
            )
        );

        in_ = _registerInputs(d);
        in_.markets[0].poolFee = 3000;
        _refused(in_, "NVDA: pool fee() 500 is not V2_MARKET_NVDA_POOL_FEE 3000");

        MockUniV3Pool costly = new MockUniV3Pool(address(nvda), address(usdg), 20_000);
        in_ = _registerInputs(d);
        in_.markets[0].pool = address(costly);
        in_.markets[0].poolFee = 20_000;
        _refused(
            in_,
            "NVDA: pool fee tier 20000 is above 10000 (1 %): the Clearinghouse counts at most MAX_ROUTE_FEE_BPS (100 bps) of a payout route's fee, so every conversion through this pool would pay in kind, and UniV3PayoutAdapter.setRoute refuses it (CeilingExceeded)"
        );

        MockUniV3Pool stray = new MockUniV3Pool(address(nvda), address(usdg), 3000);
        in_ = _registerInputs(d);
        in_.markets[0].pool = address(stray);
        in_.markets[0].poolFee = 0;
        _refused(
            in_,
            "NVDA: the Uniswap v3 factory's (asset, USDG) pool at fee 3000 is 0x0000000000000000000000000000000000000000, not the registry pool"
        );

        pool.setLiquidity(0);
        _refused(_registerInputs(d), "NVDA: pool liquidity() == 0");
        pool.setLiquidity(POOL_LIQUIDITY);

        pool.setObserveReverts(true);
        _refused(_registerInputs(d), "NVDA: pool observe([1800, 0]) failed: no 30-minute TWAP");
        pool.setObserveReverts(false);

        // sweep contracts-c10: a ring the live 1801-slot pools could have flooded past a snapshot's window
        pool.setObservationCardinality(2400);
        _refused(
            _registerInputs(d),
            "NVDA: pool observationCardinality 2400 is below 2401 (SETTLEMENT_WINDOW + SNAPSHOT_GRACE + 1): one dust mint or burn per second could overwrite an expiry's window before the snapshot grace ends, and UniV3TwapSource.setPool refuses the pool (UnsupportedAsset); call increaseObservationCardinalityNext(2401) on the pool and wait until slot0().observationCardinality reaches it"
        );
        pool.setObservationCardinality(type(uint16).max);

        in_ = _registerInputs(d);
        in_.markets[0].minLiquidity = 0;
        _refused(in_, "NVDA: univ3MinLiquidity must be > 0 with a pool");

        // ---------------------------------------------------------------- already registered with another config
        registerScript.runWith(_registerInputs(d), _signer(admin));
        in_ = _registerInputs(d);
        in_.markets[1].strikeTick = 1_000_000;
        _refused(
            in_,
            string.concat(
                "TSLA: already registered on the Clearinghouse with another config (enabled true, strikeTick 2500000, exerciseFeeBps 25, mintFeePpm 300, oracle ",
                vm.toString(d.settlementOracle),
                "): change a live market with setMarketConfig by hand, not here"
            )
        );

        // a pool under its floor only warns: registration goes through (the config already matches, so nothing to send)
        in_ = _registerInputs(d);
        in_.markets[0].minLiquidity = POOL_LIQUIDITY + 1;
        (RegisterMarkets.Call[] memory calls,) = registerScript.plan(in_, in_.markets[0]);
        assertEq(calls.length, 1, "only the floor differs");
        registerScript.runWith(in_, _signer(admin));
        (,,,, uint128 floor) = UniV3TwapSource(d.univ3Source).pools(address(nvda));
        assertEq(floor, POOL_LIQUIDITY + 1, "floor above live liquidity accepted with a WARN");
    }

    /// @dev Expect `runWith` to revert with exactly `reason`, with no admin call sent: every preflight runs first.
    /*//////////////////////////////////////////////////////////////
                   COLLATERAL RENT (INTERFACE_VERSION 7)
    //////////////////////////////////////////////////////////////*/

    /// @notice The per-market rate reaches `MarketConfig.mintFeePpm`, and a re-run at the same rate sends nothing.
    /// @dev The rates are the design's §5.1 launch values (NVDA 80); TSLA keeps 0 here, so the same run covers both a
    ///      market that charges rent and one that does not. A 0 needs `allowZeroRent`, which is what a local fixture
    ///      or a devnet passes (DECISIONS §11) -- a run that can broadcast never has it.
    function test_register_mintFeePpmReachesTheMarketConfig() public {
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        in_.mintFeePpm = new uint32[](2);
        in_.mintFeePpm[0] = 80;
        in_.allowZeroRent = true;
        registerScript.runWith(in_, _signer(admin));

        Clearinghouse ch = Clearinghouse(d.clearinghouse);
        assertEq(ch.market(address(nvda)).mintFeePpm, 80, "NVDA registered at its launch rate");
        assertEq(ch.market(address(tsla)).mintFeePpm, 0, "TSLA registered with no rent");

        // A series created afterwards pins the rate and charges it.
        uint256 longId = ch.createSeries(address(nvda), false, 220_000_000, _nextWeekly());
        assertEq(ch.series(longId).mintFeePpm, 80, "pinned at creation");
        assertGt(ch.mintFee(longId, 100), 0, "and charged");

        (RegisterMarkets.Call[] memory again,) = registerScript.plan(in_, in_.markets[0]);
        assertEq(again.length, 0, "a re-run at the same rate sends nothing");
    }

    /// @notice A market already registered at another rate is refused, so a re-run cannot silently re-price mints.
    /// @dev `setMarketConfig` reaches NEW series only, so changing a live market's rate is a deliberate admin act, not
    ///      something a registry re-run does on its own.
    function test_register_refusesAMarketAlreadyRegisteredAtAnotherRate() public {
        RegisterMarkets.Inputs memory in_ = _registerInputs(d); // NVDA 80, TSLA 300
        registerScript.runWith(in_, _signer(admin));

        in_.mintFeePpm[0] = 200;
        _refused(
            in_,
            string.concat(
                "NVDA: already registered on the Clearinghouse with another config (enabled true, strikeTick 2500000, exerciseFeeBps 25, mintFeePpm 80, oracle ",
                vm.toString(d.settlementOracle),
                "): change a live market with setMarketConfig by hand, not here"
            )
        );
    }

    /// @notice A rate above MINT_FEE_CEIL_PPM is refused in the preflight, naming the ticker and the variable, before
    ///         anything is broadcast -- rather than reverting CeilingExceeded halfway through a 35-market run.
    function test_register_refusesAMintFeePpmAboveTheCeiling() public {
        RegisterMarkets.Inputs memory in_ = _registerInputs(d); // NVDA 80, TSLA 300
        in_.mintFeePpm[0] = V2Constants.MINT_FEE_CEIL_PPM + 1;
        _refused(
            in_,
            "NVDA: mintFeePpm 5001 is above MINT_FEE_CEIL_PPM (5000): lower V2_MARKET_NVDA_MINT_FEE_PPM or V2_MINT_FEE_PPM"
        );

        // The ceiling itself registers.
        in_.mintFeePpm[0] = V2Constants.MINT_FEE_CEIL_PPM;
        registerScript.runWith(in_, _signer(admin));
        assertEq(
            Clearinghouse(d.clearinghouse).market(address(nvda)).mintFeePpm,
            V2Constants.MINT_FEE_CEIL_PPM,
            "the ceiling is allowed"
        );
    }

    /// @notice A market whose effective rent rate is 0 is refused before anything is broadcast: with `premiumFeeBps` 0
    ///         at launch the rent at mint is the only fee a writer ever pays, so registering a market at 0 would put a
    ///         market on chain that charges writers nothing (release blocker, DECISIONS-2026-09-17 §11). The only way
    ///         through is `allowZeroRent`, which `DeployV2Batch.sh` exposes as `--allow-zero-rent` and refuses with
    ///         `--broadcast`.
    function test_register_refusesAZeroRentRateUnlessOptedIn() public {
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        in_.mintFeePpm[1] = 0; // TSLA
        _refused(in_, _zeroRentRefusal("TSLA"));

        // and the same for an Inputs that carries no rates at all, which is how the value used to default to 0
        in_ = _registerInputs(d);
        in_.mintFeePpm = new uint32[](0);
        _refused(in_, _zeroRentRefusal("NVDA"));

        in_ = _registerInputs(d);
        in_.mintFeePpm[1] = 0;
        in_.allowZeroRent = true;
        registerScript.runWith(in_, _signer(admin));
        Clearinghouse ch = Clearinghouse(d.clearinghouse);
        assertEq(ch.market(address(nvda)).mintFeePpm, 80, "NVDA still carries its rate");
        assertEq(ch.market(address(tsla)).mintFeePpm, 0, "and the opt-in let TSLA through at 0");
    }

    /// @dev The refusal a market with no writer rent gets (INTERFACE_VERSION 7, DECISIONS §11).
    function _zeroRentRefusal(string memory ticker) internal pure returns (string memory) {
        return string.concat(
            ticker,
            ": mintFeePpm is 0. INTERFACE_VERSION 7 charges the writer collateral rent at mint and premiumFeeBps is 0"
            " at launch, so this market would charge writers nothing. Set the registry's v2.mintFeePpm (v7 design"
            " 5.1). The zero-rent opt-in is honoured only under forge test (the fixtures); no forge script run"
            " reaches it, whatever the RPC, the chain id or the flags."
        );
    }

    /// @dev The next weekly expiry the calendar accepts, so a series can be created in a test.
    function _nextWeekly() internal view returns (uint40) {
        return ExpiryCalendar(d.expiryCalendar).nextExpiry(uint40(block.timestamp), true);
    }

    function _refused(RegisterMarkets.Inputs memory in_, string memory reason) internal {
        uint256 registeredBefore = Clearinghouse(d.clearinghouse).market(address(nvda)).strikeTick;
        vm.expectRevert(bytes(reason));
        registerScript.runWith(in_, _signer(admin));
        assertEq(
            Clearinghouse(d.clearinghouse).market(address(nvda)).strikeTick, registeredBefore, "nothing registered"
        );
    }
}
