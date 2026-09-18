// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployV2} from "../../../script/v2/DeployV2.s.sol";
import {RegisterMarkets} from "../../../script/v2/RegisterMarkets.s.sol";
import {VerifyV2} from "../../../script/v2/VerifyV2.s.sol";
import {V2DeployBase} from "../../../script/v2/lib/V2DeployBase.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MakerVault} from "../../../src/v2/mm/MakerVault.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../../src/mocks/MockStockToken.sol";
import {MockRoundFeed} from "../../../src/v2/mocks/MockRoundFeed.sol";
import {MockUniV3Pool} from "../../../src/v2/mocks/MockUniV3Pool.sol";
import {MockPayoutV3Factory} from "../../../src/v2/mocks/MockPayoutV3Factory.sol";
import {MockPayoutSwapRouter} from "../../../src/v2/mocks/MockPayoutSwapRouter.sol";
import {MockVerifierProxy} from "../../../src/v2/mocks/MockVerifierProxy.sol";

/// @notice The world the three v2 deploy scripts run against in their unit tests: USDG and two Stock Tokens named like
///         the registry's (symbols NVDA and TSLA, which the preflights compare with the ticker), Chainlink-shaped round
///         feeds with the chain's descriptions, a USDG/NVDA Uniswap v3 pool known to a factory, a SwapRouter02 stand-in
///         on that factory, and a Data Streams VerifierProxy. TSLA has no pool (Chainlink only), as the fork rehearsal
///         registers it.
/// @dev Inputs are built explicitly and the scripts are driven through their `runWith` / `check` entries: `vm.setEnv`
///      writes the process environment every test thread shares (test/unit/DeploySoloPreflight.t.sol explains), so the
///      one env-driven test of these scripts (DeployV2Env.t.sol) uses only `V2_*` names, which nothing else sets.
abstract contract DeployV2Fixture is Test {
    uint256 internal constant START = 1_789_000_000;
    int256 internal constant NVDA_ANSWER = 220_00000000;
    int256 internal constant TSLA_ANSWER = 358_04000000;
    /// @dev 220.0012 USDG per share with USDG as token0 (SettlementOracleSources.t.sol).
    int24 internal constant TICK_220 = 222385;
    uint128 internal constant POOL_LIQUIDITY = 1e19;
    uint128 internal constant NVDA_FLOOR = 1.7e18;
    uint64 internal constant TICK_2_50 = 2_500_000;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal cranker = makeAddr("cranker");
    address internal pricer = makeAddr("pricer");
    address internal mmQuoter = makeAddr("mmQuoter");
    address internal deployer = makeAddr("deployer");

    MockERC20 internal usdg;
    MockStockToken internal nvda;
    MockStockToken internal tsla;
    MockRoundFeed internal nvdaFeed;
    MockRoundFeed internal tslaFeed;
    MockUniV3Pool internal pool;
    MockPayoutV3Factory internal factory;
    MockPayoutSwapRouter internal router;
    MockVerifierProxy internal verifier;

    DeployV2 internal deployScript;
    RegisterMarkets internal registerScript;
    VerifyV2 internal verifyScript;

    function setUp() public virtual {
        vm.warp(START);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        nvda = new MockStockToken("NVIDIA Stock Token", "NVDA");
        tsla = new MockStockToken("Tesla Stock Token", "TSLA");
        nvdaFeed = _feed("RHNVDA / USD", NVDA_ANSWER);
        tslaFeed = _feed("Robinhood TSLA / USD", TSLA_ANSWER);
        pool = new MockUniV3Pool(address(usdg), address(nvda), 500);
        // casting to 'uint40' is safe because START - 2 days is a 2026 unix time
        // forge-lint: disable-next-line(unsafe-typecast)
        pool.pushState(uint40(START - 2 days), TICK_220, POOL_LIQUIDITY);
        factory = new MockPayoutV3Factory();
        factory.setPool(address(nvda), address(usdg), 500, address(pool));
        router = new MockPayoutSwapRouter(address(factory));
        verifier = new MockVerifierProxy();
        deployScript = new DeployV2();
        registerScript = new RegisterMarkets();
        verifyScript = new VerifyV2();
    }

    /// @dev Twelve hourly rounds, the last one an hour old.
    function _feed(string memory description, int256 answer) internal returns (MockRoundFeed f) {
        f = new MockRoundFeed(8, description);
        for (uint256 i; i < 12; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            f.push(answer - 11_000_000 + int256(i) * 1_000_000, START - (12 - i) * 1 hours);
        }
    }

    function _holidays() internal pure returns (uint32[] memory h) {
        h = new uint32[](2);
        h[0] = 20703; // Labor Day 2026-09-07
        h[1] = 20783; // Thanksgiving 2026-11-26
    }

    function _roles() internal view returns (V2DeployBase.Roles memory) {
        return V2DeployBase.Roles({
            admin: admin,
            guardian: guardian,
            feeRecipient: feeRecipient,
            cranker: cranker,
            pricer: pricer,
            mmQuoter: mmQuoter
        });
    }

    function _external() internal view returns (V2DeployBase.External memory) {
        return V2DeployBase.External({
            usdg: address(usdg),
            swapRouter02: address(router),
            univ3Factory: address(factory),
            dataStreamsVerifier: address(verifier)
        });
    }

    /// @dev The registry's v2.fees and the launch values of everything else.
    ///      INTERFACE_VERSION 7 (c05): `premiumFeeBps` is 0 at launch -- the writer fee is collateral rent charged by
    ///      `Clearinghouse.mint`, and `V2DeployBase._checkFees` refuses `premiumFeeBps > resaleFeeBps` because a
    ///      premium fee above the resale fee is the dodge the rent replaces.
    function _params() internal pure returns (V2DeployBase.Params memory p) {
        p.fees = V2Types.FeeParams({
            premiumFeeBps: 0, resaleFeeBps: 0, takerFeeFlat: 100_000, takerFeeCapBps: 1000, makerRebateBps: 5000
        });
        p.exerciseFeeBps = 25;
        p.payoutSlippageBps = 30;
        p.bountySnapshot = 50_000;
        p.bountyFinalize = 50_000;
        p.bountySettle = 50_000;
        p.bountyRedeem = 20_000;
        p.bountyRoll = 50_000;
        p.bountyCancelStale = 20_000;
        p.dailyCap = 100e6;
        p.vaultLimits = MakerVault.Limits({
            maxSeriesUnits: 10_000,
            maxTotalNotional: 250_000e6,
            askToleranceBps: 100,
            maxBidBpsOfSpot: 1000,
            maxOrderLifetime: 0,
            maxDailyOutflow: 2_500e6
        });
        p.baseUri = "https://app.stonkhouse.fun/api/token/";
    }

    function _deployInputs() internal view returns (DeployV2.Inputs memory in_) {
        in_.roles = _roles();
        in_.ext = _external();
        in_.params = _params();
        in_.holidays = _holidays();
        in_.expectChainId = block.chainid;
    }

    function _signer(address who) internal pure returns (V2DeployBase.Signer memory) {
        return V2DeployBase.Signer({pk: 0, addr: who});
    }

    /// @dev The whole set, deployed and wired from `deployer` (creates) and `admin` (calls).
    function _deploy() internal returns (V2DeployBase.Contracts memory d) {
        (d,) = deployScript.runWith(_deployInputs(), _signer(deployer), _signer(admin));
    }

    function _nvdaMarket() internal view returns (V2DeployBase.MarketIn memory) {
        return V2DeployBase.MarketIn({
            ticker: "NVDA",
            asset: address(nvda),
            feed: address(nvdaFeed),
            pool: address(pool),
            minLiquidity: NVDA_FLOOR,
            poolFee: 500,
            strikeTick: TICK_2_50,
            maxDeviationBps: 150,
            uncorroboratedDelay: 21_600,
            spotMaxAge: 3600
        });
    }

    function _tslaMarket() internal view returns (V2DeployBase.MarketIn memory) {
        return V2DeployBase.MarketIn({
            ticker: "TSLA",
            asset: address(tsla),
            feed: address(tslaFeed),
            pool: address(0),
            minLiquidity: 0,
            poolFee: 0,
            strikeTick: TICK_2_50,
            maxDeviationBps: 150,
            uncorroboratedDelay: 21_600,
            spotMaxAge: 3600
        });
    }

    function _registerInputs(V2DeployBase.Contracts memory d)
        internal
        view
        returns (RegisterMarkets.Inputs memory in_)
    {
        in_.admin = admin;
        in_.usdg = address(usdg);
        in_.exerciseFeeBps = 25;
        in_.maxFeedAge = 4 days;
        in_.c = d;
        in_.markets = new V2DeployBase.MarketIn[](2);
        in_.markets[0] = _nvdaMarket();
        in_.markets[1] = _tslaMarket();
        in_.expectChainId = block.chainid;
        in_.mintFeePpm = _mintFeePpm();
    }

    /// @dev INTERFACE_VERSION 7 (c05): the launch rent rates of the two fixture markets (v7 design §5.1), parallel to
    ///      the market list. Non-zero on both sides so the deploy -> register -> verify round trip actually carries a
    ///      rate rather than comparing two zeroes.
    function _mintFeePpm() internal pure returns (uint32[] memory ppm) {
        ppm = new uint32[](2);
        ppm[0] = 80; // NVDA
        ppm[1] = 300; // TSLA
    }

    function _verifyInputs(V2DeployBase.Contracts memory d, bool fresh)
        internal
        view
        returns (VerifyV2.Inputs memory in_)
    {
        in_.c = d;
        in_.roles = _roles();
        in_.deployer = deployer;
        in_.ext = _external();
        in_.params = _params();
        in_.holidays = _holidays();
        in_.markets = new V2DeployBase.MarketIn[](2);
        in_.markets[0] = _nvdaMarket();
        in_.markets[1] = _tslaMarket();
        in_.mintFeePpm = _mintFeePpm();
        in_.unregistered = new address[](0);
        in_.expectFresh = fresh;
        in_.expectChainId = block.chainid;
    }
}
