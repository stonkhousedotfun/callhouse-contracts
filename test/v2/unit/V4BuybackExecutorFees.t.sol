// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V4BuybackConfig, V4BuybackExecutor} from "../../../src/v2/periphery/V4BuybackExecutor.sol";
import {MockPonsLaunchHook} from "../mocks/MockPonsLaunchHook.sol";
import {V4BuybackExecutorFixture} from "./V4BuybackExecutorBase.t.sol";

/// @notice V4BuybackExecutor's fee guard (the C3-602 correction, ADR-15 §5): the cap covers the MEASURED TOTAL of
///         every fee component, the per-pool `launches(poolId)` record is what is read for the hook fee and the
///         creator tax, the hook's global `hookFeeBps()` is never read, the PoolManager protocol fee and the pool's
///         LP fee are read at call time, and a hook that charges more than it declares is caught after the fill.
/// @dev The pinned venue's total is 201 bps (1 v3 + 100 hook + 100 creator tax) and 211 bps with the protocol fee at
///      v4's 0.10 % ceiling; the fixture's cap is 250 bps, so both pass and every raise below is a real refusal.
contract V4BuybackExecutorFeesTest is V4BuybackExecutorFixture {
    event Bought(
        uint256 usdgIn,
        uint256 usdgSpent,
        uint256 wethOut,
        uint256 tokenOut,
        uint256 minWethOut,
        uint256 declaredFeeBps,
        uint256 measuredFeeBps
    );

    /// @dev `1000 | (1000 << 12)`: v4's maximum protocol fee, 1,000 pips (0.10 %) in each direction.
    uint24 internal constant MAX_PROTOCOL_FEE = 1000 | (1000 << 12);

    /*//////////////////////////////////////////////////////////////
                        WHAT THE GUARD READS
    //////////////////////////////////////////////////////////////*/

    function test_feeBps_countsEveryComponentOfThePinnedVenue() public view {
        (uint16 v3Bps, uint16 lpBps, uint16 protocolBps, uint16 hookBps, uint16 taxBps, uint256 total) = exec.feeBps();
        assertEq(v3Bps, 1, "the v3 0.01 % fee is 1 bp");
        assertEq(lpBps, 0, "the launch pool's LP fee is 0");
        assertEq(protocolBps, 0, "no protocol fee is set");
        assertEq(hookBps, 100, "the pool's frozen hook fee");
        assertEq(taxBps, 100, "the pool's frozen creator tax");
        assertEq(total, 201, "201 bps total, not the 100 bps a hookFeeBps-only read would report");
    }

    /// @dev The whole point of the C3-602 correction: the hook owner's GLOBAL setter seeds future launches only. A
    ///      guard that read `hookFeeBps()` would see 1,000 here and refuse a buy that is still charged 200 bps — and,
    ///      worse, would have missed the creator tax all along.
    function test_feeBps_ignoresTheHooksGlobalGetter() public {
        hook.setGlobalHookFeeBps(1000);
        assertEq(hook.hookFeeBps(), 1000, "the global getter really did change");

        (,,, uint16 hookBps, uint16 taxBps, uint256 total) = exec.feeBps();
        assertEq(hookBps, 100, "the per-pool record is what is read");
        assertEq(taxBps, 100);
        assertEq(total, 201);

        (,,, uint256 expectedOut) = _expected(USDG_IN);
        (, uint256 tokenOut) = _buy(USDG_IN, 1, 0);
        assertEq(tokenOut, expectedOut, "and the fill is unchanged");
    }

    function test_feeBps_countsAnLpFeeOnThePinnedPool() public {
        manager.setPool(key, uint160(1 << 96), 0, 0, 3000);
        (, uint16 lpBps,,,, uint256 total) = exec.feeBps();
        assertEq(lpBps, 30, "3,000 pips is 30 bps");
        assertEq(total, 231);
    }

    function test_feeBps_failsClosedOnALaunchRecordThatMoved() public {
        hook.setLaunch(
            poolId,
            MockPonsLaunchHook.Launch({
                registered: false,
                memecoinIsCurrency0: false,
                memecoin: address(tok),
                quoteToken: address(0),
                creatorTaxBps: 100,
                hookFeeBps: 100
            })
        );
        vm.expectRevert(V2Errors.NoSource.selector);
        exec.feeBps();
        vm.prank(splitter);
        vm.expectRevert(V2Errors.NoSource.selector);
        exec.buy(USDG_IN, 1, 0);
        assertEq(v3.swaps(), 0, "nothing was spent");

        hook.setLaunch(
            poolId,
            MockPonsLaunchHook.Launch({
                registered: true,
                memecoinIsCurrency0: false,
                memecoin: address(usdg),
                quoteToken: address(0),
                creatorTaxBps: 100,
                hookFeeBps: 100
            })
        );
        vm.expectRevert(V2Errors.NoSource.selector);
        exec.feeBps();
        vm.prank(splitter);
        vm.expectRevert(V2Errors.NoSource.selector);
        exec.buy(USDG_IN, 1, 0);
        assertEq(v3.swaps(), 0, "still nothing was spent");
    }

    /*//////////////////////////////////////////////////////////////
                      THE DECLARED CAP, BEFORE SPENDING
    //////////////////////////////////////////////////////////////*/

    /// @dev C3-604 P2: if the mock always mints the cut to `key.hooks`, deleting the declared check still fails
    ///      the measured check with the same revert. Paying the cut to a third address makes measured output
    ///      terms 0, so only the declared check (201 > 200) reverts before any USDG moves.
    function test_declaredCap_aloneRevertsWhenCutIsPaidToAThirdAddress() public {
        address third = makeAddr("third");
        manager.setCutRecipient(third);
        V4BuybackConfig memory cfg = _cfg();
        cfg.maxTotalFeeBps = 200;
        V4BuybackExecutor tight = new V4BuybackExecutor(cfg);
        vm.prank(splitter);
        usdg.approve(address(tight), type(uint256).max);
        (,,,,, uint256 declared) = tight.feeBps();
        assertEq(declared, 201, "v3 1 + hook 100 + tax 100");
        vm.prank(splitter);
        vm.expectRevert(abi.encodeWithSelector(V4BuybackExecutor.FeeCapExceeded.selector, 201, 200));
        tight.buy(USDG_IN, 1, 0);
        assertEq(v3.swaps(), 0, "declared check runs before the v3 leg");
        assertEq(tok.balanceOf(third), 0, "no cut was minted");
    }

    function test_buy_refusesARaisedPerPoolFeeBeforeSpendingAnything() public {
        uint256 splitterUsdg = usdg.balanceOf(splitter);
        // The 2,000 bps total the hook's own registerPool would still allow, with the hook fee AT the 300-bps hook
        // ceiling and the rest in the creator tax (T-429). At 1000/1000 the hook ceiling fires first and this test
        // would stop reaching the combined cap it exists to cover; a hook fee over the ceiling has its own witnesses.
        _setLaunch(300, 1700);

        (,,,,, uint256 total) = exec.feeBps();
        assertEq(total, 2001);
        vm.prank(splitter);
        vm.expectRevert(abi.encodeWithSelector(V4BuybackExecutor.FeeCapExceeded.selector, 2001, FEE_CAP_BPS));
        exec.buy(USDG_IN, 1, 0);

        assertEq(v3.swaps(), 0, "the v3 leg never ran");
        assertEq(manager.swaps(), 0, "the v4 leg never ran");
        assertEq(usdg.balanceOf(splitter), splitterUsdg, "not one unit of USDG left the splitter");
        _assertHoldsNothing(0, 0, 0, 0);
    }

    function test_buy_capIsInclusiveAtTheBoundary() public {
        // 1 (v3) + 149 + 100 = 250 = the cap.
        _setLaunch(149, 100);
        (,,,,, uint256 total) = exec.feeBps();
        assertEq(total, FEE_CAP_BPS);
        (, uint256 tokenOut) = _buy(USDG_IN, 1, 0);
        assertGt(tokenOut, 0, "exactly at the cap is allowed");

        // One bp more is not.
        _setLaunch(150, 100);
        vm.prank(splitter);
        vm.expectRevert(abi.encodeWithSelector(V4BuybackExecutor.FeeCapExceeded.selector, 251, FEE_CAP_BPS));
        exec.buy(USDG_IN, 1, 0);
    }

    function test_buy_countsTheProtocolFeeTowardsTheCap() public {
        manager.setPool(key, uint160(1 << 96), 0, MAX_PROTOCOL_FEE, 0);
        (,, uint16 protocolBps,,, uint256 total) = exec.feeBps();
        assertEq(protocolBps, 10, "1,000 pips per direction is 10 bps");
        assertEq(total, 211, "the venue's worst case with the controller acting");

        // The fixture's 250 bps cap still allows it, and the fill is 0.10 % smaller.
        (,,, uint256 expectedOut) = _expected(USDG_IN);
        (, uint256 tokenOut) = _buy(USDG_IN, 1, 0);
        assertEq(tokenOut, expectedOut);

        // An executor whose cap sits between 201 and 211 refuses the same buy, before spending anything.
        V4BuybackConfig memory cfg = _cfg();
        cfg.maxTotalFeeBps = 205;
        V4BuybackExecutor tight = new V4BuybackExecutor(cfg);
        vm.prank(splitter);
        usdg.approve(address(tight), type(uint256).max);
        vm.prank(splitter);
        vm.expectRevert(abi.encodeWithSelector(V4BuybackExecutor.FeeCapExceeded.selector, 211, 205));
        tight.buy(USDG_IN, 1, 0);
    }

    function test_buy_refusesAProtocolFeeAboveV4sOwnCeiling() public {
        manager.setPool(key, uint160(1 << 96), 0, 2000, 0);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        exec.feeBps();
        vm.prank(splitter);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        exec.buy(USDG_IN, 1, 0);
        assertEq(v3.swaps(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                    THE MEASURED CAP, AFTER THE FILL
    //////////////////////////////////////////////////////////////*/

    /// @dev A hook that takes more than its record declares. The declared read still says 201 bps, so a guard that
    ///      trusted the record alone would let the buy through; the executor measures the hook's actual balance
    ///      delta across the swap and reverts the whole call.
    function test_buy_refusesAnUndeclaredHookCut() public {
        manager.setExtraCutBps(200);
        (,,,,, uint256 declared) = exec.feeBps();
        assertEq(declared, 201, "the declared read sees nothing");

        uint256 splitterUsdg = usdg.balanceOf(splitter);
        vm.prank(splitter);
        vm.expectRevert(abi.encodeWithSelector(V4BuybackExecutor.FeeCapExceeded.selector, 401, FEE_CAP_BPS));
        exec.buy(USDG_IN, 1, 0);

        assertEq(usdg.balanceOf(splitter), splitterUsdg, "the whole call reverted, so nothing moved");
        assertEq(tok.balanceOf(splitter), 0);
        _assertHoldsNothing(0, 0, 0, 0);
    }

    function test_buy_allowsAnUndeclaredCutInsideTheCapAndReportsBoth() public {
        manager.setExtraCutBps(40);
        (uint256 wethOut,,, uint256 expectedOut) = _expected(USDG_IN);

        vm.expectEmit(true, true, true, true, address(exec));
        emit Bought(USDG_IN, USDG_IN, wethOut, expectedOut, exec.wethFloor(USDG_IN), 201, 241);
        (, uint256 tokenOut) = _buy(USDG_IN, 1, 0);
        assertEq(tokenOut, expectedOut);
    }

    /// @dev Both halves of the guard at once: the record is raised as far as the cap allows AND the hook takes an
    ///      undeclared cut on top. The measured total is what refuses it.
    function test_buy_measuredTotalCatchesWhatTheDeclaredTotalAllows() public {
        _setLaunch(149, 100); // declared 250, exactly the cap
        manager.setExtraCutBps(1);

        (,,,,, uint256 declared) = exec.feeBps();
        assertEq(declared, FEE_CAP_BPS, "the declared total is inside the cap");
        vm.prank(splitter);
        vm.expectRevert(abi.encodeWithSelector(V4BuybackExecutor.FeeCapExceeded.selector, 251, FEE_CAP_BPS));
        exec.buy(USDG_IN, 1, 0);
    }

    /// @dev F-05-07, the report's witness. `IBuybackExecutor` promises a refusal above
    ///      `V2Constants.MAX_HOOK_FEE_BPS` (300) and the code only enforced the COMBINED `maxTotalFeeBps`. A pool
    ///      declaring a 301-bps hook fee under a 302-bps combined cap therefore passed every check while breaking
    ///      the published promise. The two quantities are different: the combined cap's own constructor ceiling is
    ///      2,500. PROVE BY BREAKING: remove the hook-ceiling check and this test goes red, because the declared
    ///      total of 302 is exactly at the combined cap and nothing else refuses it.
    function test_buy_refusesAHookFeeAboveTheHookCeilingEvenUnderTheCombinedCap() public {
        V4BuybackConfig memory cfg = _cfg();
        cfg.maxTotalFeeBps = 302; // v3 1 + hook 301 + tax 0 = 302, exactly at this cap
        V4BuybackExecutor wide = new V4BuybackExecutor(cfg);
        vm.prank(splitter);
        usdg.approve(address(wide), type(uint256).max);
        _setLaunch(301, 0);

        (,,,,, uint256 declared) = wide.feeBps();
        assertEq(declared, 302, "the combined cap does not refuse this");
        assertLe(declared, cfg.maxTotalFeeBps, "which is the whole point of the witness");

        uint256 splitterUsdg = usdg.balanceOf(splitter);
        vm.prank(splitter);
        vm.expectRevert(abi.encodeWithSelector(V4BuybackExecutor.HookFeeCapExceeded.selector, 301, 300));
        wide.buy(USDG_IN, 1, 0);
        assertEq(usdg.balanceOf(splitter), splitterUsdg, "not one unit of USDG left the splitter");
    }

    /// @dev The same witness through {execute}, the entry point `FeeSplitter.buyback` actually calls. The ceiling is
    ///      checked once per entry point, so each copy needs its own witness: with only the {buy} test above, the
    ///      {execute} copy could be deleted and every test in this file would stay green.
    ///      PROVE BY BREAKING: remove the hook-ceiling check in {execute} and this test goes red.
    function test_execute_refusesAHookFeeAboveTheHookCeilingEvenUnderTheCombinedCap() public {
        V4BuybackConfig memory cfg = _cfg();
        cfg.maxTotalFeeBps = 302; // v3 1 + hook 301 + tax 0 = 302, exactly at this cap
        V4BuybackExecutor wide = new V4BuybackExecutor(cfg);
        vm.prank(splitter);
        usdg.approve(address(wide), type(uint256).max);
        _setLaunch(301, 0);

        uint256 splitterUsdg = usdg.balanceOf(splitter);
        vm.prank(splitter);
        vm.expectRevert(abi.encodeWithSelector(V4BuybackExecutor.HookFeeCapExceeded.selector, 301, 300));
        wide.execute(USDG_IN, 1);
        assertEq(usdg.balanceOf(splitter), splitterUsdg, "not one unit of USDG left the splitter");
    }

    /// @dev The ceiling is a bound, not an equality: 300 is allowed.
    function test_buy_allowsAHookFeeExactlyAtTheHookCeiling() public {
        V4BuybackConfig memory cfg = _cfg();
        cfg.maxTotalFeeBps = 400;
        V4BuybackExecutor wide = new V4BuybackExecutor(cfg);
        vm.prank(splitter);
        usdg.approve(address(wide), type(uint256).max);
        _setLaunch(300, 0);
        vm.prank(splitter);
        (, uint256 tokenOut) = wide.buy(USDG_IN, 1, 0);
        assertGt(tokenOut, 0, "exactly at the hook ceiling is allowed");
    }
}
