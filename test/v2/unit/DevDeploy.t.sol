// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";
import {DevDeploy} from "../../../script/v2/DevDeploy.s.sol";
import {BaseV2Test} from "../BaseV2.t.sol";
import {AutoRoller} from "../../../src/v2/AutoRoller.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MakerRegistry} from "../../../src/v2/mm/MakerRegistry.sol";
import {MakerVault} from "../../../src/v2/mm/MakerVault.sol";
import {RewardsDistributor} from "../../../src/v2/mm/RewardsDistributor.sol";
import {MockPayoutSwapRouter} from "../../../src/v2/mocks/MockPayoutSwapRouter.sol";
import {MockPayoutV3Factory} from "../../../src/v2/mocks/MockPayoutV3Factory.sol";
import {MockRoundFeed} from "../../../src/v2/mocks/MockRoundFeed.sol";
import {MockUniV3Pool} from "../../../src/v2/mocks/MockUniV3Pool.sol";
import {FeeSplitter} from "../../../src/v2/periphery/FeeSplitter.sol";
import {UniV3PayoutAdapter} from "../../../src/v2/periphery/UniV3PayoutAdapter.sol";

/// @notice `script/v2/DevDeploy.s.sol` over the v2 mocks: every core contract is deployed and wired as the devnet
///         needs it (roles, markets, sources, fees, bounties, funding), the mock feed copies the real feed's history,
///         the periphery (AutoRoller, UniV3PayoutAdapter, MakerRegistry + MakerVault + RewardsDistributor) is deployed
///         and wired or skipped / refused by its flag, the JSON mirrors the registry's `v2.contracts`, one ITM NVDA call
///         goes from write to a USDG redemption on the deployed set with the keeper paid, a writer is rolled, and the
///         vault quotes both sides.
/// @dev Driven through `runWith(Inputs)` (no env, no node checks), as test/v2/unit/FreezeV1.t.sol drives its script.
///      The "real" feeds are MockRoundFeeds with 12 hourly rounds; the NVDA pool is a MockUniV3Pool at tick 222385
///      (220.0012 USDG per share, SettlementOracleSources.t.sol) and TSLA has none (Chainlink only, as on the devnet).
///      SwapRouter02 is a MockPayoutSwapRouter over a MockPayoutV3Factory that returns that pool for (NVDA, USDG, 500)
///      and sells NVDA at 220.00 from its own USDG.
contract DevDeployTest is BaseV2Test {
    int24 internal constant TICK_220 = 222385;
    uint128 internal constant LIQ = 1e19;
    uint64 internal constant TICK_2_50 = 2_500_000;
    /// @dev A 210.00 call on the Thursday daily: 10 USDG in the money at 220.
    uint128 internal constant ITM_STRIKE = 210_000_000;

    /// @dev Thursday 2026-09-10 10:00 EDT: inside the regular session before THU_2026_09_10's close.
    uint256 internal constant THU_10AM = 1_789_048_800;

    DevDeploy internal script;
    MockRoundFeed internal realNvdaFeed;
    MockRoundFeed internal realTslaFeed;
    MockUniV3Pool internal pool;
    MockPayoutV3Factory internal factory;
    MockPayoutSwapRouter internal router;
    address internal pricer = makeAddr("pricer");
    address internal cranker = makeAddr("cranker");

    function _deployFeeds() internal override {
        realNvdaFeed = new MockRoundFeed(8, "RHNVDA / USD");
        realTslaFeed = new MockRoundFeed(8, "RHTSLA / USD");
        for (uint256 i; i < 12; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            int256 wiggle = int256(i) * 1_000_000; // +0.01 USDG per round
            realNvdaFeed.push(NVDA_FEED_ANSWER - 11_000_000 + wiggle, START - (12 - i) * 1 hours);
            realTslaFeed.push(TSLA_FEED_ANSWER - 11_000_000 + wiggle, START - (12 - i) * 1 hours);
        }
        pool = new MockUniV3Pool(address(usdg), address(nvda), 500);
        // forge-lint: disable-next-line(unsafe-typecast)
        pool.pushState(uint40(START - 2 days), TICK_220, LIQ);
        factory = new MockPayoutV3Factory();
        factory.setPool(address(nvda), address(usdg), 500, address(pool));
        router = new MockPayoutSwapRouter(address(factory));
        router.setPrice(address(nvda), NVDA_SPOT);
        usdg.mint(address(router), 1_000_000e6);
        script = new DevDeploy();
        usdg.mint(admin, 5_000e6);
    }

    function _inputs() internal view returns (DevDeploy.Inputs memory in_) {
        in_.admin = admin;
        in_.guardian = guardian;
        // The treasury and the fee recipient are two roles that used to share one address. The treasury keeps the
        // EOA; the fee recipient is now the FeeSplitter the run deploys, so it is left unset here and adopted.
        in_.treasury = treasury;
        in_.feeRecipient = address(0);
        in_.pricer = pricer;
        in_.mmQuoter = mm;
        in_.cranker = cranker;
        in_.burnBps = 5000;
        in_.usdg = address(usdg);
        in_.markets = new DevDeploy.MarketIn[](2);
        in_.markets[0] = DevDeploy.MarketIn({
            ticker: "NVDA",
            underlying: address(nvda),
            feed: address(realNvdaFeed),
            pool: address(pool),
            minLiquidity: 1e18,
            strikeTick: TICK_2_50
        });
        in_.markets[1] = DevDeploy.MarketIn({
            ticker: "TSLA",
            underlying: address(tsla),
            feed: address(realTslaFeed),
            pool: address(0),
            minLiquidity: 0,
            strikeTick: TICK_2_50
        });
        in_.mockFeed = true;
        in_.holidays = new uint32[](2);
        in_.holidays[0] = 20703; // Labor Day 2026-09-07
        in_.holidays[1] = 20783; // Thanksgiving 2026-11-26
        // v7 (c05): the launch fee set -- the writer fee is collateral rent at mint, so the premium fee is 0.
        in_.fees = V2Types.FeeParams({
            premiumFeeBps: 0, resaleFeeBps: 0, takerFeeFlat: 100_000, takerFeeCapBps: 1000, makerRebateBps: 5000
        });
        in_.exerciseFeeBps = 25;
        in_.maxDeviationBps = 150;
        in_.uncorroboratedDelay = 21_600;
        in_.spotMaxAge = 3600;
        in_.bountySnapshot = 50_000;
        in_.bountyFinalize = 50_000;
        in_.bountySettle = 50_000;
        in_.bountyRedeem = 20_000;
        in_.bountyRoll = 50_000;
        in_.bountyCancelStale = 20_000; // v7 (c16)
        in_.dailyCap = 100e6;
        in_.mintFeePpm = 80; // v7 (c05): NVDA's launch rate, so the dev deploy exercises a non-zero rent
        in_.fund = 1_000e6;
        in_.swapRouter = address(router);
        in_.payoutSlippageBps = 30;
        in_.vaultLimits = MakerVault.Limits({
            maxSeriesUnits: 10_000,
            maxTotalNotional: 250_000e6,
            askToleranceBps: 100,
            maxBidBpsOfSpot: 1_000,
            maxOrderLifetime: 0,
            maxDailyOutflow: 2_500e6
        });
    }

    /*//////////////////////////////////////////////////////////////
                                 WIRING
    //////////////////////////////////////////////////////////////*/

    function test_runWith_wiresTheCoreSet() public {
        DevDeploy.Deployment memory d = script.runWith(_inputs());

        // roles: admin everywhere, guardian where the contracts have one
        bytes32 adminRole = V2Constants.DEFAULT_ADMIN_ROLE;
        assertTrue(d.calendar.authority().code.length > 0, "calendar is Managed");
        vm.prank(admin);
        d.calendar.setHolidays(new uint32[](0), true);
        // v8 (C8-04): the sources, the oracle and KeeperRewards are Managed; the manager maps their selectors.
        assertTrue(d.chainlink.authority().code.length > 0, "chainlink is Managed");
        assertTrue(d.univ3.authority().code.length > 0, "univ3 is Managed");
        assertTrue(d.oracle.authority().code.length > 0, "oracle is Managed");
        assertTrue(d.keeperRewards.authority().code.length > 0, "rewards is Managed");
        vm.startPrank(admin);
        d.oracle.setKeeperRewards(address(d.keeperRewards)); // CONFIG_ADMIN through the manager
        d.keeperRewards.setDailyCap(100e6); // FEE_MANAGER through the manager
        vm.stopPrank();
        // v8 (C8-02): the Clearinghouse is Managed too; its role table lives on the same manager.
        AccessManager chMgr = AccessManager(d.clearinghouse.authority());
        (bool listingOk,) = chMgr.hasRole(V8Roles.LISTING, admin);
        (bool guardianOk,) = chMgr.hasRole(V8Roles.GUARDIAN, guardian);
        assertTrue(listingOk, "clearinghouse LISTING on manager");
        assertTrue(guardianOk, "clearinghouse guardian on manager");
        // C8-03: the book is Managed and shares the one manager; admin holds its fee lanes, guardian the pause.
        assertEq(d.orderBook.authority(), address(chMgr), "book and clearinghouse share the one manager");
        (bool feeOk,) = chMgr.hasRole(V8Roles.FEE_MANAGER, admin);
        assertTrue(feeOk, "book FEE_MANAGER on manager");
        // Exercise the pause lane instead of re-reading hasRole: `guardian` already holds GUARDIAN from the
        // oracle and Clearinghouse wiring, so a hasRole read stays green even if the book's own
        // setTargetFunctionRole(setTradingPaused -> GUARDIAN) and its admin grant were deleted from the script.
        vm.prank(admin);
        d.orderBook.setTradingPaused(true);
        vm.prank(admin);
        d.orderBook.setTradingPaused(false);
        vm.prank(guardian);
        d.orderBook.setTradingPaused(true);
        vm.prank(guardian);
        d.orderBook.setTradingPaused(false);
        assertTrue(d.clearinghouse.isMinter(address(d.orderBook)), "book joined the minter allow-list");
        (bool scriptOk,) = chMgr.hasRole(V8Roles.LISTING, address(script));
        assertFalse(scriptOk, "the script contract holds no listing role");

        // calendar
        assertTrue(d.calendar.holiday(20703), "Labor Day seeded");
        assertTrue(d.calendar.isValidExpiry(THU_2026_09_10), "Thursday daily");

        // sources and oracle
        (address nvdaFeed,,) = d.chainlink.feeds(address(nvda));
        (address tslaFeed,,) = d.chainlink.feeds(address(tsla));
        assertEq(nvdaFeed, d.markets[0].feed, "NVDA feed = the mock");
        assertEq(tslaFeed, d.markets[1].feed, "TSLA feed = the mock");
        assertTrue(nvdaFeed != address(realNvdaFeed), "mock, not the real feed");
        (address p,,,, uint128 minLiq) = d.univ3.pools(address(nvda));
        assertEq(p, address(pool), "NVDA pool");
        assertEq(minLiq, 1e18, "registry liquidity floor");
        (address tslaPool,,,,) = d.univ3.pools(address(tsla));
        assertEq(tslaPool, address(0), "TSLA has no pool");

        (address[] memory nvdaSources, uint16 dev, uint32 delay, uint32 age) = d.oracle.marketConfig(address(nvda));
        assertEq(nvdaSources.length, 2, "NVDA: two sources");
        assertEq(nvdaSources[0], address(d.chainlink), "Chainlink first");
        assertEq(nvdaSources[1], address(d.univ3), "pool second");
        assertEq(dev, 150, "maxDeviationBps");
        assertEq(delay, 21_600, "uncorroboratedDelay");
        assertEq(age, 3600, "spotMaxAge");
        (address[] memory tslaSources,,,) = d.oracle.marketConfig(address(tsla));
        assertEq(tslaSources.length, 1, "TSLA: Chainlink only");
        assertEq(d.oracle.clearinghouse(), address(d.clearinghouse), "oracle -> clearinghouse");
        assertEq(d.oracle.keeperRewards(), address(d.keeperRewards), "oracle -> rewards");
        assertTrue(d.chainlink.isOracle(address(d.oracle)), "chainlink source accepts the oracle's pins");
        assertTrue(d.univ3.isOracle(address(d.oracle)), "pool source accepts the oracle's pins");

        // clearinghouse
        V2Types.MarketConfig memory m = d.clearinghouse.market(address(nvda));
        assertTrue(m.enabled, "NVDA enabled");
        assertFalse(m.mintPaused, "NVDA not paused");
        assertEq(m.strikeTick, TICK_2_50, "strike tick");
        assertEq(m.exerciseFeeBps, 25, "exercise fee");
        assertEq(m.oracle, address(d.oracle), "market oracle");
        assertEq(d.clearinghouse.market(address(tsla)).strikeTick, TICK_2_50, "TSLA registered");
        // v7 (c05): MINT_FEE_PPM reaches every registered market and is pinned into the series created after it.
        assertEq(d.clearinghouse.market(address(nvda)).mintFeePpm, 80, "NVDA rent rate");
        assertEq(d.clearinghouse.market(address(tsla)).mintFeePpm, 80, "TSLA rent rate");
        assertEq(d.clearinghouse.calendar(), address(d.calendar), "calendar");
        assertEq(d.clearinghouse.feeRecipient(), d.feeSplitter, "fee recipient is the splitter, not an EOA");
        assertEq(address(d.clearinghouse.keeperRewards()), address(d.keeperRewards), "clearinghouse -> rewards");
        assertEq(d.clearinghouse.baseUri(), "https://app.stonkhouse.fun/api/token/", "base URI");
        assertFalse(d.clearinghouse.thirdPartyRedeemAllowed(address(d.orderBook)), "book opted out");

        // order book
        V2Types.FeeParams memory f = d.orderBook.feeParams();
        assertEq(f.premiumFeeBps, 0, "premium fee: 0 from v7 (c05), the writer fee is rent at mint");
        assertEq(f.resaleFeeBps, 0, "resale fee");
        assertEq(f.takerFeeFlat, 100_000, "taker flat");
        assertEq(f.takerFeeCapBps, 1000, "taker cap");
        assertEq(f.makerRebateBps, 5000, "rebate");
        assertEq(d.orderBook.clearinghouse(), address(d.clearinghouse), "book -> clearinghouse");
        assertEq(d.orderBook.feeRecipient(), d.feeSplitter, "book fee recipient is the splitter, not an EOA");

        // keeper rewards
        assertTrue(d.keeperRewards.isCaller(address(d.oracle)), "oracle may reward");
        assertTrue(d.keeperRewards.isCaller(address(d.clearinghouse)), "clearinghouse may reward");
        assertEq(d.keeperRewards.bounty(V2Constants.ACTION_SNAPSHOT), 50_000, "SNAPSHOT");
        assertEq(d.keeperRewards.bounty(V2Constants.ACTION_FINALIZE), 50_000, "FINALIZE");
        assertEq(d.keeperRewards.bounty(V2Constants.ACTION_SETTLE), 50_000, "SETTLE");
        assertEq(d.keeperRewards.bounty(V2Constants.ACTION_REDEEM), 20_000, "REDEEM");
        assertEq(d.keeperRewards.bounty(V2Constants.ACTION_ROLL), 50_000, "ROLL");
        assertEq(d.keeperRewards.bounty(V2Constants.ACTION_CANCEL_STALE), 20_000, "CANCEL_STALE (v7 c16)");
        assertEq(d.keeperRewards.dailyCap(), 100e6, "daily cap");
        assertEq(usdg.balanceOf(address(d.keeperRewards)), 1_000e6, "funded");
        assertEq(usdg.balanceOf(admin), 4_000e6, "funded from admin");
    }

    /// @notice The C2-09 / C2-10 / C2-11 wiring of the hand-off notes, on the default (auto) flags.
    /*//////////////////////////////////////////////////////////////
                              THE FLYWHEEL
    //////////////////////////////////////////////////////////////*/

    /// @notice C8-DEVDEPLOY-FLYWHEEL: the devnet has a REAL FeeSplitter, the fee path runs through it, and the
    ///         AccessManager it has always constructed is now published.
    /// @dev WHY EACH ASSERTION IS HERE RATHER THAN A HAPPY-PATH SWEEP. T-119's flywheel gates check for CONTRACT
    ///      CODE at the splitter and the executor. A second EOA, or a passthrough stub, would satisfy a naive
    ///      "is it set" check and record a flywheel that does not exist -- a false green, which is worse than the
    ///      honest named skip T-119 ships today. So this asserts the splitter is a CONTRACT, that it is the
    ///      address the two fee takers actually hold, and that the treasury is NOT that address.
    function test_flywheel_feeSplitterIsRealAndIsTheFeePath() public {
        DevDeploy.Deployment memory d = script.runWith(_inputs());

        assertTrue(d.feeSplitter != address(0), "a FeeSplitter address was emitted");
        assertGt(d.feeSplitter.code.length, 0, "the FeeSplitter is a contract, not an EOA standing in for one");
        assertEq(d.clearinghouse.feeRecipient(), d.feeSplitter, "the Clearinghouse pays the splitter");
        assertEq(d.orderBook.feeRecipient(), d.feeSplitter, "the OrderBook pays the splitter");

        // The splitter is not the treasury and the treasury is not the splitter: that conflation is what made the
        // old single-EOA wiring look correct.
        assertEq(FeeSplitter(d.feeSplitter).treasury(), treasury, "the splitter's exit is the treasury");
        assertTrue(d.feeSplitter != treasury, "the splitter and the treasury are different addresses");
        assertEq(FeeSplitter(d.feeSplitter).usdg(), address(usdg), "the splitter takes USDG");
    }

    /// @dev KeeperRewards takes the TREASURY, not the splitter. Its third constructor argument is the Treasury Safe
    ///      (`src/v2/KeeperRewards.sol:121`, and :91-92 "Protocol-owned money (bounties) can only leave to it"), and
    ///      prod passes `treasurySafe` there while passing the splitter to the other two
    ///      (`script/v2/DeployV8.s.sol:529` vs `:502`). Routing defunded bounties through a burn-and-split would be
    ///      a different thing than wiring the fee path.
    function test_flywheel_keeperRewardsKeepsTheTreasuryNotTheSplitter() public {
        DevDeploy.Deployment memory d = script.runWith(_inputs());
        assertEq(d.keeperRewards.treasury(), treasury, "keeper bounties return to the treasury");
        assertTrue(d.keeperRewards.treasury() != d.feeSplitter, "and NOT through the splitter");
    }

    /// @dev The manager was always constructed; it was simply never published, so T-119 had to recover it from a
    ///      deployed contract's `authority()`. There is still exactly ONE.
    function test_flywheel_accessManagerIsPublishedAndIsTheOnlyOne() public {
        DevDeploy.Deployment memory d = script.runWith(_inputs());
        assertTrue(d.accessManager != address(0), "the AccessManager is emitted");
        assertGt(d.accessManager.code.length, 0, "and it is a contract");
        assertEq(d.clearinghouse.authority(), d.accessManager, "the Clearinghouse is on it");
        assertEq(d.orderBook.authority(), d.accessManager, "the OrderBook is on it");
        assertEq(FeeSplitter(d.feeSplitter).authority(), d.accessManager, "and so is the splitter");
    }

    /// @dev The cranker is a PRINCIPAL holding BUYBACK, not a role. v8 has eleven roles and none is called
    ///      "cranker" (`src/v2/access/V8Roles.sol` COUNT = 11).
    function test_flywheel_crankerHoldsBuybackAndBuybackIsMapped() public {
        DevDeploy.Deployment memory d = script.runWith(_inputs());
        AccessManager mgr = AccessManager(d.accessManager);

        assertEq(
            mgr.getTargetFunctionRole(d.feeSplitter, FeeSplitter.buyback.selector),
            V8Roles.BUYBACK,
            "buyback(uint256) is mapped to BUYBACK on the splitter"
        );
        (bool holds,) = mgr.hasRole(V8Roles.BUYBACK, cranker);
        assertTrue(holds, "the cranker principal holds BUYBACK");
        assertEq(V8Roles.COUNT, 11, "v8 has eleven roles and none of them is a cranker role");
    }

    /// @dev On a bare anvil the executor CANNOT be deployed -- its constructor reads live v4 pool state and needs a
    ///      registered launch hook. The JSON must say WHICH path ran, so a null executor here is never mistaken for
    ///      a failed one on a fork.
    function test_flywheel_bareAnvilEmitsNoExecutorAndSaysSo() public {
        DevDeploy.Inputs memory in_ = _inputs();
        DevDeploy.Deployment memory d = script.runWith(in_);

        assertEq(d.buybackExecutor, address(0), "no buyback executor on a bare anvil");
        string memory json = script.toJson(in_, d);
        assertTrue(_contains(json, "\"mode\": \"bare-anvil\""), "the JSON names the bare-anvil path");
        assertTrue(_contains(json, "\"accessManager\""), "the JSON publishes the accessManager");
        assertTrue(_contains(json, "\"feeSplitter\""), "the JSON publishes the feeSplitter");
        assertTrue(_contains(json, "\"cranker\""), "the JSON publishes the cranker principal");
        assertTrue(_contains(json, "\"mmQuoter\""), "mmQuoter is still spelled mmQuoter");
    }

    /// @dev A fork run that has not been given the venue REFUSES by name instead of quietly falling back to the
    ///      bare-anvil path. A flywheel that silently did not deploy is the false green criterion 5 forbids.
    function test_flywheel_forkWithoutVenueRefusesByName() public {
        DevDeploy.Inputs memory in_ = _inputs();
        in_.flywheel.fork = true;
        vm.expectRevert();
        script.runWith(in_);
    }

    function test_runWith_wiresThePeriphery() public {
        DevDeploy.Deployment memory d = script.runWith(_inputs());
        bytes32 adminRole = V2Constants.DEFAULT_ADMIN_ROLE;

        // AutoRoller
        AutoRoller roller = AutoRoller(d.autoRoller);
        assertTrue(address(roller).code.length > 0, "AutoRoller deployed");
        assertEq(address(roller.orderBook()), address(d.orderBook), "roller -> book");
        assertEq(address(roller.clearinghouse()), address(d.clearinghouse), "roller -> clearinghouse");
        assertEq(roller.usdg(), address(usdg), "roller usdg");
        // C8-05: the roller is `Managed` on the SAME manager as the core (the devnet no longer deploys a second
        // one), and `reprice` is PRICER there rather than a role on the roller.
        AccessManager rollerMgr = AccessManager(roller.authority());
        assertEq(address(rollerMgr), d.clearinghouse.authority(), "one manager for the whole devnet");
        (bool pricerOk,) = rollerMgr.hasRole(V8Roles.PRICER, pricer);
        assertTrue(pricerOk, "pricer role");
        assertEq(
            rollerMgr.getTargetFunctionRole(address(roller), AutoRoller.reprice.selector),
            V8Roles.PRICER,
            "reprice is PRICER"
        );
        assertEq(address(roller.keeperRewards()), address(d.keeperRewards), "roller -> rewards");
        assertTrue(d.keeperRewards.isCaller(address(roller)), "roller may reward");
        assertEq(d.keeperRewards.bounty(V2Constants.ACTION_ROLL), 50_000, "ROLL bounty");
        assertEq(roller.minRollUnits(), roller.DEFAULT_MIN_ROLL_UNITS(), "min roll units");

        // PayoutAdapter
        UniV3PayoutAdapter adapter = UniV3PayoutAdapter(d.payoutAdapter);
        assertTrue(address(adapter).code.length > 0, "PayoutAdapter deployed");
        assertEq(adapter.usdg(), address(usdg), "adapter usdg");
        assertEq(adapter.router(), address(router), "adapter router");
        assertEq(adapter.factory(), address(factory), "factory from the router");
        assertTrue(adapter.hasRole(adminRole, admin), "adapter admin");
        (address nvdaPool, uint24 nvdaFee) = adapter.routes(address(nvda));
        assertEq(nvdaPool, address(pool), "NVDA routed through its TWAP pool");
        assertEq(nvdaFee, 500, "at the pool's fee tier");
        (, uint24 tslaFee) = adapter.routes(address(tsla));
        assertEq(tslaFee, 0, "TSLA: no pool, no route");
        assertEq(d.clearinghouse.payoutAdapter(), address(adapter), "clearinghouse -> adapter");
        assertEq(d.clearinghouse.maxPayoutSlippageBps(), 30, "slippage bound");

        // maker suite
        MakerRegistry makers = MakerRegistry(d.makerRegistry);
        MakerVault vault = MakerVault(d.makerVault);
        RewardsDistributor distributor = RewardsDistributor(d.rewardsDistributor);
        assertTrue(makers.authority().code.length > 0, "registry is Managed");
        vm.prank(admin);
        makers.setTier(admin, 0);
        assertEq(address(d.orderBook.makerRegistry()), address(makers), "book -> registry");
        assertEq(address(vault.orderBook()), address(d.orderBook), "vault -> book");
        assertEq(address(vault.clearinghouse()), address(d.clearinghouse), "vault -> clearinghouse");
        // C8-05: TREASURY_ADMIN and QUOTER live on the manager, `deposit` is permissionless, and the vault's and
        // the distributor's exits point at the devnet's fee recipient (DeployV8 sets the real Treasury Safe).
        AccessManager vaultMgr = AccessManager(vault.authority());
        assertEq(address(vaultMgr), d.clearinghouse.authority(), "vault on the same manager");
        (bool treasuryOk,) = vaultMgr.hasRole(V8Roles.TREASURY_ADMIN, admin);
        (bool quoterOk,) = vaultMgr.hasRole(V8Roles.QUOTER, mm);
        assertTrue(treasuryOk, "admin holds TREASURY_ADMIN");
        assertTrue(quoterOk, "quoter role");
        assertEq(
            vaultMgr.getTargetFunctionRole(address(vault), MakerVault.deposit.selector),
            0,
            "deposit carries no role: it is permissionless in v8"
        );
        assertEq(vault.treasury(), treasury, "the vault's only exit");
        assertEq(distributor.treasury(), treasury, "the distributor's only exit");
        MakerVault.Limits memory l = vault.limits();
        assertEq(l.maxSeriesUnits, 10_000, "maxSeriesUnits");
        assertEq(l.maxTotalNotional, 250_000e6, "maxTotalNotional");
        assertEq(l.askToleranceBps, 100, "askToleranceBps");
        assertEq(l.maxBidBpsOfSpot, 1_000, "maxBidBpsOfSpot");
        assertEq(l.maxOrderLifetime, 0, "maxOrderLifetime");
        assertTrue(d.clearinghouse.isOperator(address(vault), address(d.orderBook)), "book operates the vault ledger");
        assertTrue(d.clearinghouse.isApprovedForAll(address(vault), address(d.orderBook)), "book moves vault tokens");
        assertEq(usdg.allowance(address(vault), address(d.orderBook)), type(uint256).max, "book pulls vault USDG");
        assertEq(address(distributor.usdg()), address(usdg), "distributor usdg");
        assertEq(distributor.authority(), address(vaultMgr), "distributor on the same manager");
        assertFalse(address(script).code.length == 0, "script alive");
        // The script broadcasts as the admin, so it is the admin that holds the roles, not the script contract.
        (bool scriptHoldsPricer,) = rollerMgr.hasRole(V8Roles.PRICER, address(script));
        (bool scriptHoldsQuoter,) = vaultMgr.hasRole(V8Roles.QUOTER, address(script));
        assertFalse(scriptHoldsPricer, "the script contract holds no periphery role");
        assertFalse(scriptHoldsQuoter, "nor the quoting one");
    }

    /// @notice V2-ARCHITECTURE §2.1: grantRole and revokeRole revert NotAuthorized on every contract that still
    ///         overrides _checkRole. The v8 Managed set (calendar, the price sources, the oracle, KeeperRewards,
    ///         the Clearinghouse, the MakerRegistry, since C8-05 the AutoRoller, the MakerVault and the
    ///         RewardsDistributor, and since C8-03 the OrderBook) has no AccessControl surface at all, so the call
    ///         reverts with no data rather than with NotAuthorized: its role table lives on the AccessManager.
    ///         UniV3PayoutAdapter is the last one still carrying an on-contract role table.
    function test_roles_grantAndRevokeErrorPerContract() public {
        DevDeploy.Deployment memory d = script.runWith(_inputs());
        bytes32 role = V2Constants.GUARDIAN_ROLE;
        address[1] memory shared = [d.payoutAdapter];
        vm.startPrank(alice);
        for (uint256 i; i < shared.length; ++i) {
            vm.expectRevert(V2Errors.NotAuthorized.selector);
            IAccessControl(shared[i]).grantRole(role, alice);
            vm.expectRevert(V2Errors.NotAuthorized.selector);
            IAccessControl(shared[i]).revokeRole(V2Constants.DEFAULT_ADMIN_ROLE, admin);
        }
        address[11] memory managed = [
            address(d.calendar),
            address(d.chainlink),
            address(d.univ3),
            address(d.oracle),
            address(d.keeperRewards),
            address(d.clearinghouse), // C8-02 moved the Clearinghouse onto the manager as well
            d.makerRegistry,
            d.autoRoller, // C8-05 moved these three across, so they lost grantRole/revokeRole entirely
            d.makerVault,
            d.rewardsDistributor,
            address(d.orderBook) // C8-03 moved the book onto the manager: no grantRole, so no revert data
        ];
        for (uint256 i; i < managed.length; ++i) {
            // v8 (C8-04): Managed contracts have no AccessControl surface at all; the role table lives on the manager.
            // T-522. A LOW-LEVEL CALL, NOT `vm.expectRevert()`. The C8-05 author flagged this line themselves -
            // moving a contract into `managed` swaps a selector-specific assertion for a bare one, "and if I got it
            // wrong the test still passes". It did: putting `payoutAdapter` in this array, which DOES have grantRole
            // and refuses alice with NotAuthorized, left the test green. A bare expectRevert accepts ANY revert, so
            // it cannot tell "no such function" from "function here, caller refused" - which is the only thing this
            // loop exists to say. `vm.expectRevert(bytes(""))` is not the fix either: on this forge it PANICS the
            // runner rather than failing the test when the revert carries data (alloy-dyn-abi, "range end index 4
            // out of range for slice of length 0"), so a mismatch crashes instead of reporting. Asserting on the
            // returndata of a raw call says exactly what is meant and fails cleanly.
            (bool grantOk, bytes memory grantRet) =
                managed[i].call(abi.encodeWithSelector(IAccessControl.grantRole.selector, role, alice));
            assertFalse(grantOk, "grantRole must revert on a Managed target");
            assertEq(grantRet.length, 0, "a Managed target has no grantRole, so the revert carries NO data");
            // And revokeRole, which the move silently dropped: `shared` above asserts both calls, `managed` asserted
            // only grantRole, so the three contracts C8-05 moved across lost half their coverage in the move.
            (bool revokeOk, bytes memory revokeRet) = managed[i].call(
                abi.encodeWithSelector(IAccessControl.revokeRole.selector, V2Constants.DEFAULT_ADMIN_ROLE, admin)
            );
            assertFalse(revokeOk, "revokeRole must revert on a Managed target");
            assertEq(revokeRet.length, 0, "a Managed target has no revokeRole, so the revert carries NO data");
        }
        vm.stopPrank();
    }

    function test_mockFeed_copiesHistoryAndIsFresh() public {
        DevDeploy.Deployment memory d = script.runWith(_inputs());
        MockRoundFeed mock = MockRoundFeed(d.markets[0].feed);

        assertEq(mock.decimals(), 8, "decimals copied");
        // 8 real rounds + the fresh one
        assertEq(mock.roundsInPhase(1), script.MOCK_HISTORY_ROUNDS() + 1, "history + fresh round");
        (, int256 realLatest,, uint256 realAt,) = realNvdaFeed.latestRoundData();
        (, int256 oldest,, uint256 oldestAt,) = mock.getRoundData(mock.roundId(1, 1));
        (, int256 realOldest,, uint256 realOldestAt,) = realNvdaFeed.getRoundData(realNvdaFeed.roundId(1, 5));
        assertEq(oldest, realOldest, "oldest copied answer");
        assertEq(oldestAt, realOldestAt, "oldest copied timestamp");
        (, int256 copiedLatest,, uint256 copiedAt,) = mock.getRoundData(mock.roundId(1, 8));
        assertEq(copiedLatest, realLatest, "latest real round copied");
        assertEq(copiedAt, realAt, "latest real timestamp copied");
        (, int256 head,, uint256 headAt,) = mock.latestRoundData();
        assertEq(head, realLatest, "fresh round repeats the latest answer");
        assertEq(headAt, block.timestamp, "fresh round stamped now");

        (uint256 spot, uint256 at) = d.oracle.spot(address(nvda));
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(spot, uint256(realLatest) / 100, "spot from the mock, 8 dp -> 6 dp");
        assertEq(at, block.timestamp, "fresh");
        (bool ok,,) = d.oracle.trySpot(address(tsla));
        assertTrue(ok, "TSLA spot");
    }

    function test_mockFeedOff_pointsAtTheRealFeed() public {
        DevDeploy.Inputs memory in_ = _inputs();
        in_.mockFeed = false;
        DevDeploy.Deployment memory d = script.runWith(in_);
        (address nvdaFeed,,) = d.chainlink.feeds(address(nvda));
        assertEq(nvdaFeed, address(realNvdaFeed), "real NVDA feed");
        assertEq(d.markets[0].feed, address(realNvdaFeed), "market out feed");
        assertEq(d.markets[0].realFeed, address(realNvdaFeed), "realFeed");
    }

    function test_periphery_offSkips() public {
        DevDeploy.Inputs memory in_ = _inputs();
        in_.autoRoller = DevDeploy.Flag.Off;
        in_.payoutAdapter = DevDeploy.Flag.Off;
        in_.makerSuite = DevDeploy.Flag.Off;
        DevDeploy.Deployment memory d = script.runWith(in_);
        assertEq(d.autoRoller, address(0), "AutoRoller off");
        assertEq(d.payoutAdapter, address(0), "PayoutAdapter off");
        assertEq(d.makerVault, address(0), "maker suite off");
        assertEq(d.makerRegistry, address(0), "registry off");
        assertEq(d.rewardsDistributor, address(0), "distributor off");
        assertEq(d.clearinghouse.payoutAdapter(), address(0), "no conversion");
        assertEq(address(d.orderBook.makerRegistry()), address(0), "no maker registry on the book");
        assertTrue(address(d.orderBook) != address(0), "core still deployed");
    }

    /// @notice Periphery addresses do not depend on the core: switching them off moves no core contract.
    function test_periphery_offKeepsCoreAddresses() public {
        uint256 snap = vm.snapshotState();
        DevDeploy.Deployment memory on = script.runWith(_inputs());
        vm.revertToState(snap);
        DevDeploy.Inputs memory in_ = _inputs();
        in_.autoRoller = DevDeploy.Flag.Off;
        in_.payoutAdapter = DevDeploy.Flag.Off;
        in_.makerSuite = DevDeploy.Flag.Off;
        DevDeploy.Deployment memory off = script.runWith(in_);
        assertEq(address(off.clearinghouse), address(on.clearinghouse), "clearinghouse");
        assertEq(address(off.orderBook), address(on.orderBook), "orderBook");
        assertEq(address(off.keeperRewards), address(on.keeperRewards), "keeperRewards");
    }

    /// @dev One required flag per test: a revert inside runWith leaves the test's broadcast open.
    function test_periphery_requiredDeploysEverything() public {
        DevDeploy.Inputs memory in_ = _inputs();
        in_.autoRoller = DevDeploy.Flag.Required;
        in_.payoutAdapter = DevDeploy.Flag.Required;
        in_.makerSuite = DevDeploy.Flag.Required;
        DevDeploy.Deployment memory d = script.runWith(in_);
        assertTrue(d.autoRoller != address(0), "AutoRoller");
        assertTrue(d.payoutAdapter != address(0), "PayoutAdapter");
        assertTrue(d.makerVault != address(0) && d.makerRegistry != address(0), "vault + registry");
        assertTrue(d.rewardsDistributor != address(0), "distributor");
    }

    function test_periphery_autoPayoutAdapterWithoutRouterSkips() public {
        DevDeploy.Inputs memory in_ = _inputs();
        in_.swapRouter = makeAddr("no router here");
        DevDeploy.Deployment memory d = script.runWith(in_);
        assertEq(d.payoutAdapter, address(0), "skipped");
        assertEq(d.clearinghouse.payoutAdapter(), address(0), "conversion off");
        assertTrue(d.autoRoller != address(0) && d.makerVault != address(0), "the rest still deployed");
    }

    function test_periphery_requiredPayoutAdapterWithoutRouterReverts() public {
        DevDeploy.Inputs memory in_ = _inputs();
        in_.payoutAdapter = DevDeploy.Flag.Required;
        in_.swapRouter = makeAddr("no router here");
        vm.expectRevert(abi.encodeWithSelector(DevDeploy.PeripheryMissing.selector, "UniV3PayoutAdapter (C2-10)"));
        script.runWith(in_);
    }

    function test_payoutAdapter_factoryPoolMismatchReverts() public {
        address other = makeAddr("another NVDA/USDG 0.05% pool");
        factory.setPool(address(nvda), address(usdg), 500, other);
        vm.expectRevert(abi.encodeWithSelector(DevDeploy.RouteMismatch.selector, "NVDA", other, address(pool)));
        script.runWith(_inputs());
    }

    function test_adminUnderfunded_reverts() public {
        DevDeploy.Inputs memory in_ = _inputs();
        in_.fund = 5_000e6 + 1;
        vm.expectRevert(abi.encodeWithSelector(DevDeploy.AdminUnderfunded.selector, 5_000e6, 5_000e6 + 1));
        script.runWith(in_);
    }

    function test_toJson_mirrorsRegistryContracts() public {
        DevDeploy.Inputs memory in_ = _inputs();
        DevDeploy.Deployment memory d = script.runWith(in_);
        string memory json = script.toJson(in_, d);

        assertEq(vm.parseJsonAddress(json, ".contracts.clearinghouse"), address(d.clearinghouse), "clearinghouse");
        assertEq(vm.parseJsonAddress(json, ".contracts.orderBook"), address(d.orderBook), "orderBook");
        assertEq(vm.parseJsonAddress(json, ".contracts.settlementOracle"), address(d.oracle), "oracle");
        assertEq(vm.parseJsonAddress(json, ".contracts.expiryCalendar"), address(d.calendar), "calendar");
        assertEq(vm.parseJsonAddress(json, ".contracts.keeperRewards"), address(d.keeperRewards), "rewards");
        assertEq(vm.parseJsonAddress(json, ".contracts.sources.chainlink"), address(d.chainlink), "chainlink");
        assertEq(vm.parseJsonAddress(json, ".contracts.sources.univ3"), address(d.univ3), "univ3");
        assertEq(vm.parseJsonAddress(json, ".markets[0].feed"), d.markets[0].feed, "NVDA feed");
        assertEq(vm.parseJsonAddress(json, ".markets[1].underlying"), address(tsla), "TSLA");
        assertEq(vm.parseJsonAddress(json, ".roles.guardian"), guardian, "guardian");
        assertEq(vm.parseJsonUint(json, ".config.premiumFeeBps"), 0, "premium fee");
        assertEq(vm.parseJsonUint(json, ".config.mintFeePpm"), 80, "mint fee ppm (v7 c05)");
        assertEq(vm.parseJsonString(json, ".config.bountyCancelStale"), "20000", "CANCEL_STALE bounty (v7 c16)");
        assertEq(vm.parseJsonUint(json, ".config.keeperFund"), 1_000e6, "fund");
        assertTrue(vm.parseJsonBool(json, ".mockFeed"), "mockFeed");
        assertEq(vm.parseJsonAddressArray(json, ".markets[0].sources").length, 2, "NVDA sources");
        assertEq(vm.parseJsonAddressArray(json, ".markets[1].sources").length, 1, "TSLA sources");
        assertEq(vm.parseJsonAddress(json, ".contracts.autoRoller"), d.autoRoller, "autoRoller");
        assertEq(vm.parseJsonAddress(json, ".contracts.payoutAdapter"), d.payoutAdapter, "payoutAdapter");
        assertEq(vm.parseJsonAddress(json, ".contracts.makerVault"), d.makerVault, "makerVault");
        assertEq(vm.parseJsonAddress(json, ".contracts.makerRegistry"), d.makerRegistry, "makerRegistry");
        assertEq(vm.parseJsonAddress(json, ".contracts.rewardsDistributor"), d.rewardsDistributor, "distributor");
        assertEq(vm.parseJsonAddress(json, ".config.swapRouter02"), address(router), "router");
        assertEq(vm.parseJsonUint(json, ".config.payoutSlippageBps"), 30, "slippage");
        assertEq(vm.parseJsonUint(json, ".config.makerVaultLimits.maxSeriesUnits"), 10_000, "vault units");
        assertEq(vm.parseJsonString(json, ".config.makerVaultLimits.maxTotalNotional"), "250000000000", "notional");
        assertEq(
            vm.parseJsonString(json, ".config.makerVaultLimits.maxDailyOutflow"), "2500000000", "outflow cap (v7 c21)"
        );
    }

    function test_toJson_peripheryOffIsNull() public {
        DevDeploy.Inputs memory in_ = _inputs();
        in_.autoRoller = DevDeploy.Flag.Off;
        in_.payoutAdapter = DevDeploy.Flag.Off;
        in_.makerSuite = DevDeploy.Flag.Off;
        DevDeploy.Deployment memory d = script.runWith(in_);
        string memory json = script.toJson(in_, d);
        // periphery keys exist and are null
        string[5] memory keys;
        keys[0] = ".contracts.autoRoller";
        keys[1] = ".contracts.payoutAdapter";
        keys[2] = ".contracts.makerVault";
        keys[3] = ".contracts.makerRegistry";
        keys[4] = ".contracts.rewardsDistributor";
        for (uint256 i; i < keys.length; ++i) {
            assertTrue(vm.keyExistsJson(json, keys[i]), keys[i]);
            assertTrue(_contains(json, string.concat("\"", _lastKey(keys[i]), "\": null")), "null");
        }
    }

    function _lastKey(string memory path) internal pure returns (string memory) {
        bytes memory b = bytes(path);
        uint256 dot;
        for (uint256 i; i < b.length; ++i) {
            if (b[i] == ".") dot = i;
        }
        bytes memory out = new bytes(b.length - dot - 1);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[dot + 1 + i];
        }
        return string(out);
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
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

    /*//////////////////////////////////////////////////////////////
                           A CYCLE ON THE SET
    //////////////////////////////////////////////////////////////*/

    /// @notice Write on fill, buy, snapshot, settle (the Clearinghouse finalizes, both sources corroborate), redeem:
    ///         the deployed set works end to end, the payout is converted to USDG through the PayoutAdapter's route,
    ///         and the keeper earns SNAPSHOT + REDEEM (+ SETTLE).
    function test_cycle_itmCallSettlesCorroboratedAndPaysKeeper() public {
        DevDeploy.Deployment memory d = script.runWith(_inputs());
        uint40 e = THU_2026_09_10;

        // alice writes an ITM call on fill, bob buys 100 units (1 share) at 11.00
        uint256 longId = d.clearinghouse.createSeries(address(nvda), false, ITM_STRIKE, e);
        (bool pinned,,,,) = d.oracle.settlementConfig(address(nvda), e);
        (,,, bool feedPinned) = d.chainlink.pinnedFeeds(address(nvda), e);
        (,,,, bool poolPinned,) = d.univ3.pinnedPools(address(nvda), e);
        assertTrue(pinned && feedPinned && poolPinned, "the series pinned its expiry on the oracle and both sources");
        vm.startPrank(alice);
        nvda.approve(address(d.clearinghouse), type(uint256).max);
        d.clearinghouse.deposit(address(nvda), 5e18, alice);
        d.clearinghouse.setOperator(address(d.orderBook), true);
        uint256 orderId = d.orderBook.place(longId, V2Types.OrderKind.AskWrite, 11_000_000, 100, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        usdg.approve(address(d.orderBook), type(uint256).max);
        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        (uint64 filled, uint256 premium,) = d.orderBook
            .take(
                V2Types.TakeParams({
                    longId: longId,
                    buying: true,
                    orderIds: ids,
                    units: 100,
                    minUnits: 100,
                    limitPrice: 11_000_000,
                    writeToSell: false,
                    recipient: bob,
                    deadline: uint40(block.timestamp + 60),
                    // v8: hard cap on the taker-side fees; the existing cases assert fee behaviour elsewhere, so they opt out
                    maxTotalFee: type(uint128).max
                })
            );
        vm.stopPrank();
        assertEq(filled, 100, "filled");
        assertEq(premium, 11_000_000, "premium 11.00 USDG");
        assertEq(d.clearinghouse.balanceOf(bob, longId), 100, "bob long");

        // the settlement window: the mock feed holds 220.00 across it (the devnet's set-feed.mjs does this)
        MockRoundFeed mock = MockRoundFeed(d.markets[0].feed);
        vm.warp(e + 5);
        mock.push(NVDA_FEED_ANSWER, e - 1800 - 60);
        mock.push(NVDA_FEED_ANSWER, block.timestamp);
        vm.prank(keeper);
        assertEq(d.oracle.snapshot(address(nvda), e), 1, "pool snapshot");

        vm.warp(e + V2Constants.FINALIZE_DELAY);
        vm.prank(keeper);
        assertTrue(d.clearinghouse.settle(longId), "settled through the oracle");
        (V2Types.SettlementStatus status, uint256 price) = d.oracle.settlementPrice(address(nvda), e);
        assertEq(uint8(status), uint8(V2Types.SettlementStatus.Finalized), "final");
        assertEq(price, 220_000_000, "Chainlink price, corroborated by the pool");
        V2Types.Series memory s = d.clearinghouse.series(longId);
        assertGt(s.longPayoutPerUnit, 0, "ITM");

        uint256 owed = uint256(s.longPayoutPerUnit) * 100;
        uint256 value = owed * price / 1e18;
        uint256 bobUsdg = usdg.balanceOf(bob);
        vm.prank(keeper);
        (uint256 paid, bool inUsdg) = d.clearinghouse.redeem(longId, bob);
        assertTrue(inUsdg, "converted through the PayoutAdapter");
        assertEq(paid, value, "bob paid the value at 220.00 in USDG");
        assertEq(usdg.balanceOf(bob) - bobUsdg, value, "USDG arrived");
        assertEq(nvda.balanceOf(address(router)), owed, "the Stock Token payout was sold");
        assertEq(d.clearinghouse.balanceOf(bob, longId), 0, "burned");
        assertEq(usdg.balanceOf(keeper), 50_000 + 50_000 + 20_000, "SNAPSHOT + SETTLE + REDEEM bounties");
    }

    /// @notice The seed's AutoRoller path (ops/devnet/seed.mjs): the C2-09 writer setup, a weekly smart-pricing
    ///         strategy, one roll inside a regular session on a fresh round (ROLL bounty to the caller), and the
    ///         pricer's reprice inside the band.
    function test_cycle_autoRollerRollsAWriterAndThePricerReprices() public {
        DevDeploy.Deployment memory d = script.runWith(_inputs());
        AutoRoller roller = AutoRoller(d.autoRoller);

        vm.startPrank(alice);
        nvda.approve(address(d.clearinghouse), type(uint256).max);
        d.clearinghouse.deposit(address(nvda), 20e18, alice);
        d.clearinghouse.setPayoutToLedger(true);
        d.clearinghouse.setOperator(address(d.orderBook), true);
        d.clearinghouse.setOperator(address(roller), true);
        d.orderBook.setDelegate(address(roller), true);
        roller.setStrategy(
            address(nvda),
            V2Types.Strategy({
                active: true,
                weekly: true,
                smartPricing: true,
                otmBps: 500,
                askBps: 60,
                minAskBps: 50, // T-OP-063 / SEC-13: MIN_ASK_BPS is 50 now; 30 would revert CeilingExceeded
                maxAskBps: 150,
                maxUnits: 1_000
            })
        );
        vm.stopPrank();

        // after the close nothing rolls; inside the session with a fresh round it does
        vm.prank(keeper);
        assertFalse(roller.roll(alice, address(nvda)), "START is after the close");
        vm.warp(THU_10AM);
        MockRoundFeed(d.markets[0].feed).push(NVDA_FEED_ANSWER, THU_10AM);
        vm.prank(keeper);
        assertTrue(roller.roll(alice, address(nvda)), "rolled");

        (uint256 longId, uint256 orderId, uint40 expiry) = roller.position(alice, address(nvda));
        assertEq(expiry, FRI_2026_09_11, "the weekly at least 24 h out");
        assertTrue(orderId != 0, "a live roll order");
        V2Types.Series memory s = d.clearinghouse.series(longId);
        assertEq(s.strike, 232_500_000, "220 x 1.05 rounded up to the 2.50 tick");
        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        V2Types.Order memory o = d.orderBook.getOrders(ids)[0];
        assertEq(o.maker, alice, "maker of record is the writer");
        assertEq(uint8(o.kind), uint8(V2Types.OrderKind.AskWrite), "write on fill");
        assertEq(o.price, 1_320_000, "60 bps of 220.00");
        assertEq(o.units, 1_000, "maxUnits");
        assertEq(usdg.balanceOf(keeper), 50_000, "ROLL bounty");

        vm.prank(pricer);
        roller.reprice(alice, address(nvda), 1_100_000);
        (, uint256 repriced,) = roller.position(alice, address(nvda));
        assertTrue(repriced != orderId, "replaced by the pricer");
    }

    /// @notice The seed's MakerVault path: admin funds the vault, the quoter moves collateral into the ledger and
    ///         quotes an AskWrite and a Bid on one series inside the guards.
    function test_makerVault_fundedAndQuotesBothSides() public {
        DevDeploy.Deployment memory d = script.runWith(_inputs());
        MakerVault vault = MakerVault(d.makerVault);
        uint256 longId = d.clearinghouse.createSeries(address(nvda), false, 230_000_000, FRI_2026_09_11);

        _fund(admin, 0, 50e18, 0);
        vm.startPrank(admin);
        usdg.approve(address(vault), 2_000e6);
        vault.deposit(address(usdg), 2_000e6);
        nvda.approve(address(vault), 50e18);
        vault.deposit(address(nvda), 50e18);
        vm.stopPrank();

        vm.startPrank(mm);
        vault.depositToClearinghouse(address(nvda), 50e18);
        uint256 ask = vault.place(longId, V2Types.OrderKind.AskWrite, 2_500_000, 500, 0);
        uint256 bid = vault.place(longId, V2Types.OrderKind.Bid, 1_500_000, 300, 0);
        vm.stopPrank();

        assertEq(d.clearinghouse.free(address(vault), address(nvda)), 50e18, "write collateral in the vault ledger");
        uint256[] memory ids = vault.orderIdsOf(longId);
        assertEq(ids.length, 2, "two quotes");
        assertEq(ids[0], ask, "ask");
        assertEq(ids[1], bid, "bid");
        V2Types.Order[] memory orders = d.orderBook.getOrders(ids);
        assertEq(orders[0].maker, address(vault), "vault makes the ask");
        assertEq(orders[1].maker, address(vault), "vault makes the bid");
        assertEq(usdg.balanceOf(address(vault)), 2_000e6 - 4_500_000, "bid escrow: 3 shares at 1.50");
        (uint256 units,,) = vault.exposure(longId);
        assertEq(units, 500, "worst case: the ask fills");
        // v7 (c21): the bid's escrow is charged at placement and the ask is not booked at all, so the outflow
        // counter is exactly the escrow and the rest of the day's budget is still there.
        (uint256 used, uint256 available) = vault.outflow();
        assertEq(used, 4_500_000, "only the bid's escrow is booked");
        assertEq(available, uint256(_inputs().vaultLimits.maxDailyOutflow) - 4_500_000, "the rest of the cap");
    }
}
