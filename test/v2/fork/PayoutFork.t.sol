// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {ExpiryCalendar} from "../../../src/v2/ExpiryCalendar.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MockSettlementOracle} from "../../../src/v2/mocks/MockSettlementOracle.sol";
import {IAggregatorV3} from "../../../src/v2/oracle/OracleDeps.sol";
import {IUniV3PoolFactory, IUniV3SwapRouter02} from "../../../src/v2/periphery/PayoutDeps.sol";
import {UniV3PayoutAdapter} from "../../../src/v2/periphery/UniV3PayoutAdapter.sol";

interface IPoolSlot0 {
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

    function token0() external view returns (address);
}

/// @notice QuoterV2 (v3-periphery), non-view: it simulates the swap and reverts internally.
interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

/// @notice USDG payouts on a fork of chain 4663 (C2-10): the real Clearinghouse and UniV3PayoutAdapter over the LIVE
///         NVDA, TSLA and GME Stock Tokens, USDG, SwapRouter02 and Uniswap v3 pools. The launch bound, 30 bps, is
///         measured above each route's pool fee (INTERFACE_VERSION 6): the floor is value less 30 bps + routeFeeBps.
///           1. an ITM NVDA call long is redeemed in USDG through the 0.05 % pool, at most 35 bps (30 + 5) short of its
///              settlement value;
///           2. after a large sale pushes the NVDA pool 5 % below the settlement price, the same redemption falls back
///              to NVDA in kind (and the pool's quote proves why);
///           3. TSLA, which has a live pool but no route on the adapter, pays in kind; routed through its 0.30 % pool
///              it converts at the 30 bps launch bound, at most 60 bps (30 + 30) short, where a flat 30 bps floor
///              would have paid in kind (the pool fee alone is 30 bps);
///           4. GME routed through its 1 % pool converts at the launch bound, at most 130 bps (30 + 100) short.
/// @dev Run with:  FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC --match-path "test/v2/fork/PayoutFork.t.sol" -vv
///      Without a fork (chain id != 4663) every test logs and returns, as test/fork/ForkLive.t.sol does.
///
///      WHAT IS REAL. Tokens, router, factory, pools and quoter are the live contracts at the RPC's latest block. The
///      Clearinghouse, ExpiryCalendar and adapter are deployed fresh; the settlement price comes from a
///      MockSettlementOracle pinned to the pool's own mid price (slot0) at the time of writing. Pinning to the pool
///      rather than to the Chainlink feed isolates what this suite proves, the conversion's execution cost (pool fee
///      plus price impact) against the bound, from how far the feed and the pool happen to sit apart at the fork
///      block (weekends and overnight the feed stands still while the pool trades). The feed is still read and the
///      two are required to agree within 10 %, which catches scale and token-order mistakes in the mid computation.
///
///      FUNDING. Stock Tokens are minted to test accounts with forge's `deal` (storage-slot discovery on the live
///      token). The clock is warped forward past the series' expiry; the pools only ever see time move forward.
contract PayoutForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant GME = 0x1b0E319c6A659F002271B69dB8A7df2F911c153E;
    address constant CRWV = 0x5f10A1C971B69e47e059e1dC91901B59b3fB49C3; // Stock Token with no Uniswap pool at R13
    address constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address constant TSLA_FEED = 0x4A1166a659A55625345e9515b32adECea5547C38;
    address constant GME_FEED = 0x27C71df6A64fB476468EdF256CF72c038baB5B67;
    address constant NVDA_POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3; // 0.05 %, USDG token0
    address constant TSLA_POOL = 0xf4ACdAEEB7022862A763C9B1B885e11191c889E3; // 0.30 %, TSLA token0
    address constant GME_POOL = 0xE9713f453aDB9245B19559790c96F470a18F2fDF; // 1 %, GME token0 (registry v2.univ3Pool)
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2; // SwapRouter02
    address constant FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant QUOTER = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7; // QuoterV2

    uint24 constant NVDA_FEE = 500;
    uint24 constant TSLA_FEE = 3000;
    uint24 constant GME_FEE = 10_000;
    /// @dev The Clearinghouse's conversion bound in this suite: the launch bound, V2DeployBase.LAUNCH_PAYOUT_SLIPPAGE_BPS
    ///      (DeployV2EnvTest pins the default). USDG within 30 bps of value beyond the route's pool fee.
    uint16 constant SLIPPAGE_BPS = 30;
    uint64 constant STRIKE_TICK = 1_000_000;
    uint16 constant EXERCISE_FEE_BPS = 25;
    /// @dev Units minted to EACH of bob and carol: 100 shares, so an ITM long 10 % deep is owed ~9.75 shares (~$2,100).
    uint64 constant UNITS = 10_000;
    /// @dev How far test 2 pushes the NVDA pool below the settlement price.
    uint256 constant PUSH_BPS = 500;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice"); // writer
    address bob = makeAddr("bob"); // long holder
    address carol = makeAddr("carol"); // second long holder
    address whale = makeAddr("whale"); // moves the pool in test 2

    ExpiryCalendar calendar;
    MockSettlementOracle oracle;
    Clearinghouse ch;
    UniV3PayoutAdapter adapter;

    modifier onlyFork() {
        if (block.chainid != 4663) {
            console2.log("skipping: not forked onto 4663 (chainid %s)", block.chainid);
            return;
        }
        _;
    }

    function setUp() public {
        if (block.chainid != 4663) return;
        calendar = new ExpiryCalendar(admin, new uint32[](0));
        oracle = new MockSettlementOracle();
        ch = new Clearinghouse(admin, USDG, address(calendar), treasury, "https://app.stonkhouse.fun/api/token/");
        adapter = new UniV3PayoutAdapter(admin, USDG, ROUTER);
        V2Types.MarketConfig memory cfg = V2Types.MarketConfig({
            enabled: true,
            mintPaused: false,
            strikeTick: STRIKE_TICK,
            exerciseFeeBps: EXERCISE_FEE_BPS,
            oracle: address(oracle),
            mintFeePpm: 0
        });
        vm.startPrank(admin);
        ch.registerMarket(NVDA, cfg);
        ch.registerMarket(TSLA, cfg);
        ch.registerMarket(GME, cfg);
        adapter.setRoute(NVDA, NVDA_FEE);
        ch.setPayoutAdapter(address(adapter), SLIPPAGE_BPS);
        vm.stopPrank();
        vm.label(address(ch), "Clearinghouse");
        vm.label(address(adapter), "UniV3PayoutAdapter");
        vm.label(ROUTER, "SwapRouter02");
        vm.label(NVDA_POOL, "NVDA/USDG 0.05%");
        vm.label(TSLA_POOL, "TSLA/USDG 0.30%");
        vm.label(GME_POOL, "GME/USDG 1%");
    }

    /*//////////////////////////////////////////////////////////////
                        THE LIVE UNISWAP DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    /// @dev The adapter's assumptions about the live router: SwapRouter02's deadline-free exactInputSingle, the factory
    ///      it derives pools from, and the pools the routes resolve to.
    function test_fork_liveRouterFactoryAndRoutes() public onlyFork {
        assertEq(IUniV3SwapRouter02(ROUTER).factory(), FACTORY, "router's v3 factory");
        assertEq(adapter.factory(), FACTORY, "adapter read the same factory");
        assertTrue(_dispatches(ROUTER.code, 0x04e45aaf), "router dispatches SwapRouter02 exactInputSingle");
        assertFalse(_dispatches(ROUTER.code, 0x414bf389), "and not the v1 SwapRouter variant with a deadline");

        (address pool, uint24 fee) = adapter.routes(NVDA);
        assertEq(pool, NVDA_POOL, "NVDA route resolves to the registry pool");
        assertEq(fee, NVDA_FEE);
        assertEq(IPoolSlot0(NVDA_POOL).token0(), USDG, "USDG is token0 of the NVDA pool");
        assertEq(IPoolSlot0(TSLA_POOL).token0(), TSLA, "TSLA is token0 of the TSLA pool");
        assertEq(IUniV3PoolFactory(FACTORY).getPool(TSLA, USDG, TSLA_FEE), TSLA_POOL);
        assertEq(IUniV3PoolFactory(FACTORY).getPool(GME, USDG, GME_FEE), GME_POOL);
        assertEq(IPoolSlot0(GME_POOL).token0(), GME, "GME is token0 of the GME pool");

        vm.startPrank(admin);
        vm.expectRevert(V2Errors.NoSource.selector);
        adapter.setRoute(CRWV, 3000); // no pool on the live factory
        vm.expectRevert(V2Errors.NoSource.selector);
        adapter.setRoute(NVDA, 2500); // not a fee tier
        vm.stopPrank();
    }

    /// @dev Why the adapter refuses `amountIn == 0`: the live router reads it as "sell my own balance", so anyone's
    ///      dust left in the router is sold for the caller.
    function test_fork_liveRouterZeroAmountSellsItsOwnBalance() public onlyFork {
        deal(NVDA, ROUTER, 1e16);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        uint256 out = IUniV3SwapRouter02(ROUTER)
            .exactInputSingle(
                IUniV3SwapRouter02.ExactInputSingleParams({
                tokenIn: NVDA,
                tokenOut: USDG,
                fee: NVDA_FEE,
                recipient: stranger,
                amountIn: 0,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0
            })
            );
        assertGt(out, 0, "the router sold its own balance for a caller who paid nothing");
        assertEq(IERC20(USDG).balanceOf(stranger), out);
        assertEq(IERC20(NVDA).balanceOf(ROUTER), 0);

        vm.prank(stranger);
        vm.expectRevert(V2Errors.BadUnits.selector);
        adapter.swapToUsdg(NVDA, 0, 1, stranger);
    }

    /// @dev A direct adapter swap on the live pool: exact pull, everything sold, nothing left, output near mid; and a
    ///      floor at mid (unreachable after the pool fee) reverts with the router's own message.
    function test_fork_directSwapOnLivePool() public onlyFork {
        uint256 mid = _mid(NVDA_POOL);
        uint256 amount = 1e18;
        uint256 value = amount * mid / 1e18;
        deal(NVDA, carol, 2 * amount);
        vm.startPrank(carol);
        IERC20(NVDA).approve(address(adapter), 2 * amount);
        vm.expectRevert(bytes("Too little received"));
        adapter.swapToUsdg(NVDA, amount, value, carol);

        uint256 g = gasleft();
        uint256 out = adapter.swapToUsdg(NVDA, amount, value * 9_900 / 10_000, carol);
        g -= gasleft();
        vm.stopPrank();

        console2.log("direct swap, 1 NVDA: mid value / USDG out (6dp):", value, out);
        console2.log("direct swap shortfall vs mid, bps:", _shortfallBps(value, out));
        console2.log("gas: UniV3PayoutAdapter.swapToUsdg on the live pool:", g);
        assertEq(IERC20(USDG).balanceOf(carol), out, "measured output delivered");
        assertEq(IERC20(NVDA).balanceOf(carol), amount, "exactly one share pulled");
        _assertAdapterEmpty(NVDA);
    }

    /*//////////////////////////////////////////////////////////////
                    1. ITM NVDA CALL LONG REDEEMS IN USDG
    //////////////////////////////////////////////////////////////*/

    function test_fork_itmNvdaCallLong_redeemsToUsdgWithinTheLaunchBound() public onlyFork {
        assertEq(adapter.routeFeeBps(NVDA), 5, "0.05 % route: 5 bps");
        uint256 price = _mid(NVDA_POOL);
        _logFeedAgreement(NVDA_FEED, price);
        (uint256 longId, uint256 owed) = _writeAndSettle(NVDA, price);
        uint256 value = owed * price / 1e18;
        uint256 minOut = _floor(value, NVDA);
        uint256 quoted = _quote(NVDA, owed, NVDA_FEE);

        uint256 chNvda = IERC20(NVDA).balanceOf(address(ch));
        vm.recordLogs();
        vm.prank(keeper);
        uint256 g = gasleft();
        (uint256 paid, bool inUsdg) = ch.redeem(longId, bob);
        g -= gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        console2.log("settlement price = NVDA pool mid (USDG 6dp):", price);
        console2.log("owed NVDA base units:", owed);
        console2.log("settlement value / minOut (USDG 6dp):", value, minOut);
        console2.log("quoter / USDG received (6dp):", quoted, paid);
        console2.log("USDG received vs settlement value, shortfall bps:", _shortfallBps(value, paid));
        console2.log("gas: Clearinghouse.redeem converted to USDG on the live pool, no bounty:", g);

        assertTrue(inUsdg, "converted to USDG");
        assertEq(IERC20(USDG).balanceOf(bob), paid, "the holder received the USDG");
        assertEq(IERC20(NVDA).balanceOf(bob), 0, "and no NVDA");
        assertGe(paid, minOut, "within 30 bps + the 5 bps route fee of settlement value");
        _assertShortfallWithinBound(value, paid, NVDA);
        assertEq(paid, quoted, "exactly what the pool quoted");
        assertEq(chNvda - IERC20(NVDA).balanceOf(address(ch)), owed, "the Clearinghouse sold exactly the payout");
        assertEq(IERC20(NVDA).allowance(address(ch), address(adapter)), 0, "approval zeroed");
        _assertAdapterEmpty(NVDA);
        _assertRedeemedLog(logs, longId, bob, USDG, paid, owed);
    }

    /*//////////////////////////////////////////////////////////////
                   2. POOL PUSHED AWAY -> IN KIND FALLBACK
    //////////////////////////////////////////////////////////////*/

    function test_fork_poolPushedAway_redemptionFallsBackInKind() public onlyFork {
        uint256 price = _mid(NVDA_POOL);
        (uint256 longId, uint256 owed) = _writeAndSettle(NVDA, price);
        uint256 value = owed * price / 1e18;
        uint256 minOut = _floor(value, NVDA);

        uint256 quotedBefore = _quote(NVDA, owed, NVDA_FEE);
        assertGe(quotedBefore, minOut, "control: before the push the pool would have converted");

        uint256 sold = _pushNvdaPoolDown(PUSH_BPS);
        uint256 pushedMid = _mid(NVDA_POOL);
        uint256 quotedAfter = _quote(NVDA, owed, NVDA_FEE);
        console2.log("NVDA sold into the pool to push it:", sold);
        console2.log("pool mid before / after the push (USDG 6dp):", price, pushedMid);
        console2.log("minOut / quote before the push (USDG 6dp):", minOut, quotedBefore);
        console2.log("quote after the push (USDG 6dp), shortfall bps:", quotedAfter, _shortfallBps(value, quotedAfter));
        assertLe(pushedMid, price * (10_000 - PUSH_BPS + 1) / 10_000, "pool pushed at least 5 % down");
        assertLt(quotedAfter, minOut, "the pushed pool cannot meet minOut");

        uint256 chNvda = IERC20(NVDA).balanceOf(address(ch));
        vm.recordLogs();
        vm.prank(keeper);
        (uint256 paid, bool inUsdg) = ch.redeem(longId, bob);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(inUsdg, "fell back to in kind");
        assertEq(paid, owed);
        assertEq(IERC20(NVDA).balanceOf(bob), owed, "holder received the NVDA payout");
        assertEq(IERC20(USDG).balanceOf(bob), 0, "and no USDG");
        assertEq(chNvda - IERC20(NVDA).balanceOf(address(ch)), owed);
        assertEq(IERC20(NVDA).allowance(address(ch), address(adapter)), 0, "approval rolled back");
        _assertAdapterEmpty(NVDA);
        _assertRedeemedLog(logs, longId, bob, NVDA, owed, owed);

        // The reason, reproduced outside the try/catch: the same swap reverts in the live router.
        vm.startPrank(bob);
        IERC20(NVDA).approve(address(adapter), owed);
        vm.expectRevert(bytes("Too little received"));
        adapter.swapToUsdg(NVDA, owed, minOut, bob);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
               3. TSLA: NO ROUTE, THEN ITS 0.30 % POOL
    //////////////////////////////////////////////////////////////*/

    function test_fork_tsla_inKindWithoutRoute_andConvertsThroughItsPoolAtTheLaunchBound() public onlyFork {
        (address pool, uint24 fee) = adapter.routes(TSLA);
        assertEq(pool, address(0), "no TSLA route on the adapter");
        assertEq(fee, 0);
        assertEq(adapter.routeFeeBps(TSLA), 0);
        assertEq(IUniV3PoolFactory(FACTORY).getPool(TSLA, USDG, TSLA_FEE), TSLA_POOL, "although a live pool exists");

        uint256 price = _mid(TSLA_POOL);
        _logFeedAgreement(TSLA_FEED, price);
        (uint256 longId, uint256 owed) = _writeAndSettle(TSLA, price);

        vm.recordLogs();
        vm.prank(keeper);
        (uint256 paid, bool inUsdg) = ch.redeem(longId, bob);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertFalse(inUsdg, "paid in kind");
        assertEq(paid, owed);
        assertEq(IERC20(TSLA).balanceOf(bob), owed, "holder received TSLA");
        assertEq(IERC20(USDG).balanceOf(bob), 0);
        _assertRedeemedLog(logs, longId, bob, TSLA, owed, owed);

        vm.startPrank(bob);
        IERC20(TSLA).approve(address(adapter), owed);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        adapter.swapToUsdg(TSLA, owed, 1, bob);
        vm.stopPrank();

        // Routed through its 0.30 % pool (RegisterMarkets routes every registry pool at its own fee tier), TSLA
        // converts at the 30 bps launch bound: the floor is value less 30 + 30 bps. A flat 30 bps floor could never be
        // met, because the pool fee alone is 30 bps. carol redeems half of her longs, then dave the other half through
        // the pool carol's sale moved.
        address dave = makeAddr("dave");
        vm.prank(carol);
        ch.safeTransferFrom(carol, dave, longId, UNITS / 2, "");
        uint256 half = uint256(UNITS / 2) * ch.series(longId).longPayoutPerUnit;
        uint256 value = half * price / 1e18;
        vm.prank(admin);
        adapter.setRoute(TSLA, TSLA_FEE);
        assertEq(adapter.routeFeeBps(TSLA), 30, "0.30 % route: 30 bps");
        uint256 minOut = _floor(value, TSLA);
        assertEq(minOut, value * (10_000 - 60) / 10_000);
        uint256 quoted = _quote(TSLA, half, TSLA_FEE);
        console2.log("TSLA value / minOut at 30 + 30 bps / quote (6dp):", value, minOut, quoted);
        console2.log("TSLA quote shortfall bps (0.30 % pool):", _shortfallBps(value, quoted));
        assertLt(quoted, value * (10_000 - SLIPPAGE_BPS) / 10_000, "a flat 30 bps floor would have paid in kind");
        assertGe(quoted, minOut, "the fee-aware floor is met");

        vm.prank(keeper);
        (paid, inUsdg) = ch.redeem(longId, carol);
        console2.log("TSLA value / USDG received by carol (6dp):", value, paid);
        console2.log("TSLA shortfall bps (0.30 % pool), carol:", _shortfallBps(value, paid));
        assertTrue(inUsdg, "routed TSLA converts at the launch bound");
        assertEq(paid, quoted, "exactly what the pool quoted");
        assertEq(IERC20(USDG).balanceOf(carol), paid, "carol received USDG");
        assertEq(IERC20(TSLA).balanceOf(carol), 0, "and no TSLA");
        _assertShortfallWithinBound(value, paid, TSLA);
        _assertAdapterEmpty(TSLA);

        vm.prank(keeper);
        (paid, inUsdg) = ch.redeem(longId, dave);
        console2.log("TSLA shortfall bps (0.30 % pool), dave after carol:", _shortfallBps(value, paid));
        assertTrue(inUsdg, "the second half converts too");
        assertEq(IERC20(USDG).balanceOf(dave), paid);
        _assertShortfallWithinBound(value, paid, TSLA);
        _assertAdapterEmpty(TSLA);
    }

    /*//////////////////////////////////////////////////////////////
                       4. GME THROUGH ITS 1 % POOL
    //////////////////////////////////////////////////////////////*/

    function test_fork_gme_convertsThroughItsOnePercentPoolAtTheLaunchBound() public onlyFork {
        vm.prank(admin);
        adapter.setRoute(GME, GME_FEE);
        (address pool,) = adapter.routes(GME);
        assertEq(pool, GME_POOL, "GME route resolves to the registry pool");
        assertEq(adapter.routeFeeBps(GME), 100, "1 % route: 100 bps");

        uint256 price = _mid(GME_POOL);
        _logFeedAgreement(GME_FEED, price);
        (uint256 longId, uint256 owed) = _writeAndSettle(GME, price);
        uint256 value = owed * price / 1e18;
        uint256 minOut = _floor(value, GME);
        assertEq(minOut, value * (10_000 - 130) / 10_000);
        uint256 quoted = _quote(GME, owed, GME_FEE);
        console2.log("GME value / minOut at 30 + 100 bps / quote (6dp):", value, minOut, quoted);
        console2.log("GME quote shortfall bps (1 % pool):", _shortfallBps(value, quoted));
        assertGe(quoted, minOut, "the fee-aware floor is met");

        vm.recordLogs();
        vm.prank(keeper);
        uint256 g = gasleft();
        (uint256 paid, bool inUsdg) = ch.redeem(longId, bob);
        g -= gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        console2.log("GME value / USDG received (6dp):", value, paid);
        console2.log("gas: Clearinghouse.redeem converted through the 1 % pool, no bounty:", g);

        assertTrue(inUsdg, "routed GME converts at the launch bound");
        assertEq(paid, quoted, "exactly what the pool quoted");
        assertEq(IERC20(USDG).balanceOf(bob), paid);
        assertEq(IERC20(GME).balanceOf(bob), 0, "and no GME");
        _assertShortfallWithinBound(value, paid, GME);
        _assertAdapterEmpty(GME);
        _assertRedeemedLog(logs, longId, bob, USDG, paid, owed);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Creates a call 10 % in the money at `price` on the next session close, has alice write UNITS longs to bob
    ///      and UNITS to carol, warps past expiry and settles at `price` through the mock oracle. Returns the series
    ///      and what bob (and carol) are owed, underlying base units.
    function _writeAndSettle(address asset, uint256 price) internal returns (uint256 longId, uint256 owed) {
        // casting to 'uint128' is safe: a Stock Token price in USDG 6 dp is far below 2^128
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 strike = uint128(price * 9 / 10 / STRIKE_TICK * STRIKE_TICK);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 expiry = calendar.nextExpiry(uint40(block.timestamp + 1 hours), false);
        oracle.setSpot(asset, true, price, block.timestamp);
        longId = ch.createSeries(asset, false, strike, expiry);

        uint256 collateral = 2 * uint256(UNITS) * V2Constants.UNIT;
        deal(asset, alice, collateral);
        vm.startPrank(alice);
        IERC20(asset).approve(address(ch), collateral);
        ch.deposit(asset, collateral, alice);
        ch.mint(longId, UNITS, alice, bob);
        ch.mint(longId, UNITS, alice, carol);
        vm.stopPrank();

        vm.warp(uint256(expiry) + V2Constants.FINALIZE_DELAY);
        oracle.setSettlement(asset, expiry, V2Types.SettlementStatus.Finalized, price);
        vm.prank(keeper);
        assertTrue(ch.settle(longId), "settled");
        owed = uint256(UNITS) * ch.series(longId).longPayoutPerUnit;
        console2.log("strike / expiry:", strike, expiry);
    }

    /// @dev The pool's current mid price, USDG base units (6 dp) per whole 18-dp share, in either token order.
    ///      slot0's sqrtPriceX96^2 / 2^192 is token1 base units per token0 base unit.
    function _mid(address pool) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = IPoolSlot0(pool).slot0();
        uint256 q96 = 1 << 96;
        if (IPoolSlot0(pool).token0() == USDG) {
            return Math.mulDiv(Math.mulDiv(1e18, q96, sqrtPriceX96), q96, sqrtPriceX96);
        }
        return Math.mulDiv(Math.mulDiv(sqrtPriceX96, sqrtPriceX96, q96), 1e18, q96);
    }

    function _quote(address asset, uint256 amountIn, uint24 fee) internal returns (uint256 out) {
        (out,,,) = IQuoterV2(QUOTER)
            .quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: asset, tokenOut: USDG, amountIn: amountIn, fee: fee, sqrtPriceLimitX96: 0
            })
            );
    }

    /// @dev Sells NVDA into the 0.05 % pool until its mid is `bps` lower, using the swap's price limit so the push is
    ///      exact whatever the liquidity. USDG is token0, so a lower NVDA price is a HIGHER sqrtPrice: the NVDA price
    ///      scales with 1 / sqrtPrice^2, and sqrtPrice must grow by sqrt(1e4 / (1e4 - bps)). Returns the NVDA sold.
    function _pushNvdaPoolDown(uint256 bps) internal returns (uint256 sold) {
        (uint160 sqrtPriceX96,,,,,,) = IPoolSlot0(NVDA_POOL).slot0();
        uint256 scale = Math.sqrt(1e36 * 10_000 / (10_000 - bps)); // 1e18 fixed point
        // casting to 'uint160' is safe: a ~2.6 % increase of a live sqrtPriceX96 (~5.4e33) stays far below 2^160
        // forge-lint: disable-next-line(unsafe-typecast)
        uint160 limit = uint160(uint256(sqrtPriceX96) * scale / 1e18);
        uint256 budget = 1_000_000e18;
        deal(NVDA, whale, budget);
        vm.startPrank(whale);
        IERC20(NVDA).approve(ROUTER, budget);
        IUniV3SwapRouter02(ROUTER)
            .exactInputSingle(
                IUniV3SwapRouter02.ExactInputSingleParams({
                tokenIn: NVDA,
                tokenOut: USDG,
                fee: NVDA_FEE,
                recipient: whale,
                amountIn: budget,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: limit
            })
            );
        vm.stopPrank();
        sold = budget - IERC20(NVDA).balanceOf(whale);
    }

    function _logFeedAgreement(address feed, uint256 poolMid) internal view {
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        // casting to 'uint256' is safe: a live Stock Token answer is positive
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 feedPrice = uint256(answer) / 100; // 8 dp -> 6 dp
        uint256 dev = (feedPrice > poolMid ? feedPrice - poolMid : poolMid - feedPrice) * 10_000 / feedPrice;
        console2.log("feed latest (USDG 6dp), age s:", feedPrice, block.timestamp - updatedAt);
        console2.log("pool mid vs feed, bps:", dev);
        assertLe(dev, 1000, "pool mid and feed within 10 % (scale / token-order sanity)");
    }

    /// @dev The Clearinghouse's conversion floor for `asset` in this suite: value less SLIPPAGE_BPS + the adapter's
    ///      route fee (never near the 300 bps cap here).
    function _floor(uint256 value, address asset) internal view returns (uint256) {
        return value * (10_000 - SLIPPAGE_BPS - adapter.routeFeeBps(asset)) / 10_000;
    }

    /// @dev What the conversion left behind is at most maxPayoutSlippageBps + routeFee of the value (rounded up: the
    ///      floor rounds down by less than one base unit).
    function _assertShortfallWithinBound(uint256 value, uint256 paid, address asset) internal view {
        uint256 allowedBps = uint256(ch.maxPayoutSlippageBps()) + adapter.routeFeeBps(asset);
        uint256 shortfall = paid >= value ? 0 : value - paid;
        console2.log(
            "shortfall / allowed (USDG 6dp), bps:", shortfall, (value * allowedBps + 9_999) / 10_000, allowedBps
        );
        assertLe(shortfall, (value * allowedBps + 9_999) / 10_000, "shortfall <= maxPayoutSlippageBps + routeFee");
    }

    function _shortfallBps(uint256 value, uint256 got) internal pure returns (uint256) {
        return got >= value ? 0 : (value - got) * 10_000 / value;
    }

    function _assertAdapterEmpty(address asset) internal view {
        assertEq(IERC20(asset).balanceOf(address(adapter)), 0, "adapter holds no stock");
        assertEq(IERC20(USDG).balanceOf(address(adapter)), 0, "adapter holds no USDG");
        assertEq(IERC20(asset).allowance(address(adapter), ROUTER), 0, "no router allowance left");
    }

    function _assertRedeemedLog(
        Vm.Log[] memory logs,
        uint256 tokenId,
        address holder,
        address delivered,
        uint256 amount,
        uint256 inKind
    ) internal view {
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(ch) || logs[i].topics[0] != IClearinghouse.Redeemed.selector) continue;
            assertEq(uint256(logs[i].topics[1]), tokenId);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), holder);
            (address to, uint64 units, address asset, uint256 paid, uint256 owed, bool toLedger) =
                abi.decode(logs[i].data, (address, uint64, address, uint256, uint256, bool));
            assertEq(to, holder);
            assertEq(units, UNITS);
            assertEq(asset, delivered, "Redeemed.asset");
            assertEq(paid, amount, "Redeemed.amount");
            assertEq(owed, inKind, "Redeemed.amountInKind");
            assertFalse(toLedger);
            found = true;
        }
        assertTrue(found, "Redeemed logged");
    }

    /// @dev Whether runtime `code` contains `PUSH4 selector` (0x63 ++ selector), how solc's dispatcher compares it.
    function _dispatches(bytes memory code, bytes4 selector) internal pure returns (bool) {
        for (uint256 i; i + 4 < code.length; ++i) {
            if (
                code[i] == 0x63 && code[i + 1] == selector[0] && code[i + 2] == selector[1]
                    && code[i + 3] == selector[2] && code[i + 4] == selector[3]
            ) return true;
        }
        return false;
    }
}
