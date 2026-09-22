// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {DevDeploy} from "../../../script/v2/DevDeploy.s.sol";
import {AutoRoller} from "../../../src/v2/AutoRoller.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MakerVault} from "../../../src/v2/mm/MakerVault.sol";
import {UniV3PayoutAdapter} from "../../../src/v2/periphery/UniV3PayoutAdapter.sol";
import {MockRoundFeed} from "../../../src/v2/mocks/MockRoundFeed.sol";
import {IAggregatorV3} from "../../../src/v2/oracle/OracleDeps.sol";

import {ForkFloor} from "./ForkFloor.sol";

/// @notice `script/v2/DevDeploy.s.sol` against the LIVE chain-4663 contracts on a fork: the mock feed starts from the
///         real NVDA feed's latest round, spot and the pool's TWAP are live, a series on the next daily expiry can be
///         created, the periphery is wired against the live SwapRouter02 and NVDA/USDG pool, and DEV_MOCK_FEED=0 wires
///         the real feed. The devnet (callhouse ops/devnet/up.sh) runs the same
///         `runWith` through `forge script --broadcast` and then a full seeded cycle.
/// @dev Run with:  FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC --match-path "test/v2/fork/DevDeployFork.t.sol" -vv
///      Without a fork (chain id != 4663) every test logs and returns, as the other fork suites do.
contract DevDeployForkTest is Test {
    DevDeploy internal script;
    address internal admin = makeAddr("devAdmin");
    address internal guardian = makeAddr("devGuardian");
    address internal treasury = makeAddr("devTreasury");

    modifier onlyFork() {
        if (block.chainid != 4663) {
            console2.log("skipping: not forked onto 4663 (chainid %s)", block.chainid);
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        if (block.chainid != 4663) return;
        script = new DevDeploy();
    }

    function dealUsdg(address to, uint256 amount) external {
        deal(script.USDG_4663(), to, amount, false);
    }

    /// @dev The registry's values (script defaults) with test-owned roles; KeeperRewards is funded when `deal` can
    ///      locate USDG's balance slot on the proxy.
    function _inputs(bool mockFeed) internal returns (DevDeploy.Inputs memory in_) {
        in_.admin = admin;
        in_.guardian = guardian;
        in_.feeRecipient = treasury;
        in_.pricer = makeAddr("devPricer");
        in_.mmQuoter = makeAddr("devQuoter");
        in_.usdg = script.USDG_4663();
        in_.markets = new DevDeploy.MarketIn[](2);
        in_.markets[0] = DevDeploy.MarketIn({
            ticker: "NVDA",
            underlying: script.NVDA_4663(),
            feed: script.NVDA_FEED_4663(),
            pool: script.NVDA_POOL_4663(),
            minLiquidity: 1.7e18,
            strikeTick: 2_500_000
        });
        in_.markets[1] = DevDeploy.MarketIn({
            ticker: "TSLA",
            underlying: script.TSLA_4663(),
            feed: script.TSLA_FEED_4663(),
            pool: address(0),
            minLiquidity: 0,
            strikeTick: 2_500_000
        });
        in_.mockFeed = mockFeed;
        in_.holidays = new uint32[](1);
        in_.holidays[0] = 20783; // 2026-11-26
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
        in_.mintFeePpm = 80; // v7 (c05): NVDA's launch rate, so the fork deploy carries a real rent rate
        in_.swapRouter = script.SWAP_ROUTER_02_4663();
        in_.payoutSlippageBps = 30;
        in_.vaultLimits = MakerVault.Limits({
            maxSeriesUnits: 10_000,
            maxTotalNotional: 250_000e6,
            askToleranceBps: 100,
            maxBidBpsOfSpot: 1_000,
            maxOrderLifetime: 0,
            maxDailyOutflow: 2_500e6
        });
        try this.dealUsdg(admin, 1_000e6) {
            in_.fund = 1_000e6;
        } catch {
            console2.log("deal() could not locate the USDG balance slot; KeeperRewards left unfunded");
        }
    }

    function test_fork_devDeploy_mockFeedFromLiveHistory_spotPoolAndSeries() public onlyFork {
        DevDeploy.Inputs memory in_ = _inputs(true);
        DevDeploy.Deployment memory d = script.runWith(in_);
        address nvda = script.NVDA_4663();

        (uint80 realId, int256 realAnswer,, uint256 realAt,) = IAggregatorV3(script.NVDA_FEED_4663()).latestRoundData();
        MockRoundFeed mock = MockRoundFeed(d.markets[0].feed);
        (, int256 copied,, uint256 copiedAt,) = mock.getRoundData(mock.roundId(1, mock.roundsInPhase(1) - 1));
        assertEq(copied, realAnswer, "latest real answer copied");
        assertEq(copiedAt, realAt, "latest real timestamp copied");
        assertGt(mock.roundsInPhase(1), 2, "history copied");
        console2.log("real NVDA round id:", uint256(realId));

        (uint256 spot, uint256 at) = d.oracle.spot(nvda);
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(spot, uint256(realAnswer) / 100, "spot = live answer at 6 dp");
        assertEq(at, block.timestamp, "fresh");

        (bool poolOk, uint256 poolPrice,) = d.univ3.latest(nvda);
        assertTrue(poolOk, "live pool TWAP over the registry liquidity floor");
        uint256 diff = poolPrice > spot ? poolPrice - spot : spot - poolPrice;
        console2.log("pool vs feed (bps):", diff * 10_000 / spot);

        uint40 expiry = d.calendar.nextExpiry(uint40(block.timestamp + 1 hours), false);
        uint256 tick = 2_500_000;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 strike = uint128((spot * 10_200 / 10_000 + tick - 1) / tick * tick);
        uint256 longId = d.clearinghouse.createSeries(nvda, false, strike, expiry);
        assertTrue(d.clearinghouse.seriesExists(longId), "series on the next daily expiry");
        assertEq(d.clearinghouse.mintCutoff(longId), expiry - 1800, "cutoff");

        assertEq(IERC20(script.USDG_4663()).balanceOf(address(d.keeperRewards)), in_.fund, "funded as configured");
    }

    /// @notice The periphery on the live chain: the adapter routes NVDA through the registry pool at 0.05 % (the
    ///         factory SwapRouter02 swaps against returns the same pool the TWAP source reads), TSLA has no route, and
    ///         the roller and the vault are wired to the deployed book.
    function test_fork_devDeploy_peripheryOnLiveRouterAndPool() public onlyFork {
        DevDeploy.Deployment memory d = script.runWith(_inputs(true));
        address nvda = script.NVDA_4663();

        UniV3PayoutAdapter adapter = UniV3PayoutAdapter(d.payoutAdapter);
        assertTrue(address(adapter) != address(0), "adapter deployed on 4663");
        (address pool, uint24 fee) = adapter.routes(nvda);
        assertEq(pool, script.NVDA_POOL_4663(), "NVDA routed through the registry pool");
        assertEq(fee, 500, "0.05 %");
        (, uint24 tslaFee) = adapter.routes(script.TSLA_4663());
        assertEq(tslaFee, 0, "TSLA unrouted");
        assertEq(d.clearinghouse.payoutAdapter(), address(adapter), "clearinghouse -> adapter");
        assertEq(d.clearinghouse.maxPayoutSlippageBps(), 30, "slippage");

        AutoRoller roller = AutoRoller(d.autoRoller);
        assertEq(address(roller.orderBook()), address(d.orderBook), "roller -> book");
        // C8-05: roller, vault and distributor are `Managed` on the devnet's single AccessManager.
        AccessManager mgr = AccessManager(d.clearinghouse.authority());
        assertEq(roller.authority(), address(mgr), "one manager for the whole devnet");
        (bool pricerOk,) = mgr.hasRole(V8Roles.PRICER, makeAddr("devPricer"));
        assertTrue(pricerOk, "pricer");
        assertTrue(d.keeperRewards.isCaller(address(roller)), "roller may reward");
        assertEq(address(d.orderBook.makerRegistry()), d.makerRegistry, "book -> registry");
        (bool quoterOk,) = mgr.hasRole(V8Roles.QUOTER, makeAddr("devQuoter"));
        assertTrue(quoterOk, "quoter");
        assertEq(MakerVault(d.makerVault).authority(), address(mgr), "vault on the same manager");
        assertTrue(d.rewardsDistributor.code.length > 0, "distributor");
    }

    function test_fork_devDeploy_realFeedMode() public onlyFork {
        DevDeploy.Deployment memory d = script.runWith(_inputs(false));
        address nvda = script.NVDA_4663();
        (address feed,,) = d.chainlink.feeds(nvda);
        assertEq(feed, script.NVDA_FEED_4663(), "real feed");
        (bool ok, uint256 price,) = d.chainlink.latest(nvda);
        (, int256 realAnswer,,,) = IAggregatorV3(script.NVDA_FEED_4663()).latestRoundData();
        assertTrue(ok, "live latest");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(price, uint256(realAnswer) / 100, "live price");
    }

    /// @dev THE FLOOR (T-588). Every other test in this file carries a chain-id guard that SKIPS when no fork is
    ///      attached, so a run that never reached chain 4663 prints `0 failed` and exits 0 -- indistinguishable from
    ///      a run in which every invariant held. This test carries no such guard. Under `FOUNDRY_PROFILE=fork` it
    ///      FAILS when the suite could not have executed, and it is the only test here that can say so.
    ///
    ///      Its witness is `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, an address this suite's own tests read.
    ///      USDG, mirrored from `script/v2/DevDeploy.s.sol:139` (`USDG_4663`) rather than retyped: this suite has no address
    ///      constants of its own and reads that one through `script.USDG_4663()`, which is unavailable here because
    ///      `setUp` returns early off-fork.
    ///      A count of reported tests would not do: a skip IS a report, so such a floor is satisfied by a run in
    ///      which nothing ran. See `ForkFloor` for the rest of the reasoning.
    function test_fork_floor_devDeployForkExecutedAgainstARealFork() public {
        ForkFloor.requireExecutedAgainstRealFork(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, "DevDeployFork");
    }
}
