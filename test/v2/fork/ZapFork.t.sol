// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {V8AccessTest} from "../lib/V8Access.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {ExpiryCalendar} from "../../../src/v2/ExpiryCalendar.sol";
import {MockSettlementOracle} from "../../../src/v2/mocks/MockSettlementOracle.sol";
import {PayoutRouter} from "../../../src/v2/periphery/PayoutRouter.sol";
import {StockZap} from "../../../src/v2/periphery/StockZap.sol";
import {ForkFloor} from "./ForkFloor.sol";

/// @notice StockZap round trip over chain 4663's live NVDA/USDG v3 pool.
/// @dev Run with `FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC --match-path test/v2/fork/ZapFork.t.sol -vv`.
///      Without `--fork-url`, chain id is not 4663 and this suite executes no assertions. The v4 buy leg remains
///      intentionally absent: no launch-approved hookless Stock/USDG v4 PoolKey is pinned yet, so inventing one in
///      a fork fixture would bypass the same route-governance decision StockZap is designed to preserve.
contract ZapForkTest is V8AccessTest {
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant V3_ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address internal constant V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant V4_STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    uint24 internal constant NVDA_FEE = 500;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal user = makeAddr("user");

    ExpiryCalendar internal calendar;
    MockSettlementOracle internal oracle;
    Clearinghouse internal clearinghouse;
    PayoutRouter internal router;
    StockZap internal zap;

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
        calendar = _newCalendar(new uint32[](0), admin);
        oracle = new MockSettlementOracle();
        clearinghouse = _newClearinghouse(USDG, address(calendar), treasury, "", admin);
        router = new PayoutRouter(address(manager), USDG, V3_ROUTER, V4_POOL_MANAGER, V4_STATE_VIEW);
        _wire(address(router), "PayoutRouter", admin, 0);

        vm.startPrank(admin);
        clearinghouse.setDefaultOracle(address(oracle));
        clearinghouse.setDefaultMarketFees(0, 0);
        clearinghouse.registerMarket(NVDA, 100, true);
        router.setRouteV3(NVDA, NVDA_FEE);
        vm.stopPrank();
        zap = new StockZap(address(router), address(clearinghouse));
    }

    function test_fork_liveV3WriteDepositThenWalletExit() public onlyFork {
        uint256 usdgIn = 100e6;
        deal(USDG, user, usdgIn);
        vm.startPrank(user);
        IERC20(USDG).approve(address(zap), usdgIn);
        uint256 stockOut = zap.writeZap(NVDA, usdgIn, 1, user, type(uint40).max);
        assertGt(stockOut, 0, "live buy produced stock");
        assertEq(clearinghouse.free(user, NVDA), stockOut, "write output credited to the user's ledger");
        assertEq(IERC20(USDG).balanceOf(address(zap)), 0, "zap kept no USDG");
        assertEq(IERC20(NVDA).balanceOf(address(zap)), 0, "zap kept no stock");

        clearinghouse.withdraw(NVDA, stockOut, user);
        IERC20(NVDA).approve(address(zap), stockOut);
        uint256 before = IERC20(USDG).balanceOf(user);
        uint256 usdgOut = zap.exitZap(NVDA, stockOut, 1, user, type(uint40).max);
        vm.stopPrank();

        assertGt(usdgOut, 0, "live exit produced USDG");
        assertEq(IERC20(USDG).balanceOf(user) - before, usdgOut, "exit proceeds paid directly to the user");
        assertEq(IERC20(USDG).balanceOf(address(zap)), 0, "zap still kept no USDG");
        assertEq(IERC20(NVDA).balanceOf(address(zap)), 0, "zap still kept no stock");
    }

    /// @dev THE FLOOR (T-588, added here by T-OP-031). Every other test in this file carries a chain-id guard that
    ///      SKIPS when no fork is attached, so a run that never reached chain 4663 prints `0 failed` and exits 0 --
    ///      indistinguishable from a run in which every assertion held. This test carries no such guard. Under
    ///      `FOUNDRY_PROFILE=fork` it FAILS when the suite could not have executed, and it is the only test here
    ///      that can say so.
    ///
    ///      Its witness is `NVDA`, the live stock the round trip zaps in and out of: `setUp` registers it and
    ///      routes it, and the test moves it through the live v3 pool. `USDG`, `V3_ROUTER`, `V4_POOL_MANAGER` and
    ///      `V4_STATE_VIEW` are read too, but a fork without NVDA has nothing for this suite to swap.
    ///      A count of reported tests would not do: a skip IS a report, so such a floor is satisfied by a run in
    ///      which nothing ran. See `ForkFloor` for the rest of the reasoning.
    function test_fork_floor_zapForkExecutedAgainstARealFork() public {
        ForkFloor.requireExecutedAgainstRealFork(NVDA, "ZapFork");
    }
}
