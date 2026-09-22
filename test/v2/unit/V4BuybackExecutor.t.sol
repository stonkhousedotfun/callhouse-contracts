// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V4PoolKey} from "../../../src/v2/periphery/BuybackDeps.sol";
import {V4BuybackConfig, V4BuybackExecutor} from "../../../src/v2/periphery/V4BuybackExecutor.sol";
import {MockBuybackV3Pool} from "../mocks/MockBuybackV3Pool.sol";
import {MockPonsLaunchHook} from "../mocks/MockPonsLaunchHook.sol";
import {MockV4PoolManager} from "../mocks/MockV4PoolManager.sol";
import {MockV4StateView} from "../mocks/MockV4StateView.sol";
import {MockWeth9} from "../mocks/MockWeth9.sol";
import {V4BuybackExecutorFixture} from "./V4BuybackExecutorBase.t.sol";

contract InFlightCallbackAttacker {
    function hitV3(address exec, int256 amount0, int256 amount1) external {
        V4BuybackExecutor(payable(exec)).uniswapV3SwapCallback(amount0, amount1, "");
    }

    function hitUnlock(address exec, bytes calldata data) external {
        V4BuybackExecutor(payable(exec)).unlockCallback(data);
    }
}

/// @notice V4BuybackExecutor: what the constructor pins (and every venue it refuses to be pinned to, the token's
///         eleven hookless trap pools included), the splitter-only caller gate, the full route, the v3 TWAP floor
///         and the caller's floor on top of it, the minimum-out gate, unspent USDG going home, the two callbacks'
///         caller and in-flight checks, and that nothing of the four route assets is ever left behind.
/// @dev The fee guard has its own suite, `V4BuybackExecutorFees.t.sol`.
contract V4BuybackExecutorTest is V4BuybackExecutorFixture {
    event Bought(
        uint256 usdgIn,
        uint256 usdgSpent,
        uint256 wethOut,
        uint256 tokenOut,
        uint256 minWethOut,
        uint256 declaredFeeBps,
        uint256 measuredFeeBps
    );

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    function test_constructor_pinsTheRoute() public view {
        assertEq(exec.splitter(), splitter);
        assertEq(address(exec.usdg()), address(usdg));
        assertEq(exec.weth(), address(weth));
        assertEq(exec.token(), address(tok));
        assertEq(exec.v3Pool(), address(v3));
        assertEq(exec.v3Fee(), V3_FEE, "v3 fee read from the pool, not declared");
        assertTrue(exec.wethIsToken0(), "token order read from the pool");
        assertEq(exec.poolManager(), address(manager));
        assertEq(exec.stateView(), address(lens));
        assertEq(exec.hooks(), address(hook));
        assertEq(exec.poolId(), poolId, "pool id is the hash of the pinned key");
        assertEq(keccak256(abi.encode(exec.key())), poolId, "key() rebuilds the pinned key from immutables");
        assertEq(exec.maxTotalFeeBps(), FEE_CAP_BPS);
        assertEq(exec.maxSlippageBps(), SLIPPAGE_BPS);
        assertEq(exec.twapWindow(), WINDOW);
        assertEq(exec.minLiquidity(), MIN_LIQUIDITY);
    }

    function test_constructor_refusesZeroSplitter() public {
        V4BuybackConfig memory cfg = _cfg();
        cfg.splitter = address(0);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        new V4BuybackExecutor(cfg);
    }

    function test_constructor_refusesNonNativeCurrency0() public {
        V4BuybackConfig memory cfg = _cfg();
        cfg.key.currency0 = address(usdg);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        new V4BuybackExecutor(cfg);
    }

    function test_constructor_refusesTokenThatIsUsdgOrWeth() public {
        V4BuybackConfig memory cfg = _cfg();
        cfg.key.currency1 = address(weth);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        new V4BuybackExecutor(cfg);
    }

    /// @dev The trap pools. None of the token's eleven other v4 pools has a hook (C3-602 read them from the
    ///      PoolManager's Initialize logs), so a hookless key can never be pinned — the fee terms this executor is
    ///      required to read simply do not exist there.
    function test_constructor_refusesHooklessTrapPoolKey() public {
        uint24[3] memory trapFees = [uint24(902_000), 250_000, 70_000];
        int24[3] memory trapSpacings = [int24(18_000), 2500, 700];
        for (uint256 i; i < trapFees.length; ++i) {
            V4BuybackConfig memory cfg = _cfg();
            cfg.key = V4PoolKey({
                currency0: address(0),
                currency1: address(tok),
                fee: trapFees[i],
                tickSpacing: trapSpacings[i],
                hooks: address(0)
            });
            vm.expectRevert(V2Errors.NoSource.selector);
            new V4BuybackExecutor(cfg);
        }
    }

    /// @dev A key that differs from the pinned one only in `fee` or `tickSpacing` hashes to another pool id, which
    ///      the hook has no launch record for, so it is refused even with the right hook address.
    function test_constructor_refusesUnregisteredPoolIdOnTheSameHook() public {
        V4BuybackConfig memory cfg = _cfg();
        cfg.key.tickSpacing = 60;
        vm.expectRevert(V2Errors.NoSource.selector);
        new V4BuybackExecutor(cfg);

        cfg = _cfg();
        cfg.key.fee = 3000;
        vm.expectRevert(V2Errors.NoSource.selector);
        new V4BuybackExecutor(cfg);
    }

    function test_constructor_refusesLaunchRecordForAnotherToken() public {
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
        new V4BuybackExecutor(_cfg());
    }

    function test_constructor_refusesNonEthQuotedLaunch() public {
        hook.setLaunch(
            poolId,
            MockPonsLaunchHook.Launch({
                registered: true,
                memecoinIsCurrency0: false,
                memecoin: address(tok),
                quoteToken: address(usdg),
                creatorTaxBps: 100,
                hookFeeBps: 100
            })
        );
        vm.expectRevert(V2Errors.NoSource.selector);
        new V4BuybackExecutor(_cfg());
    }

    function test_constructor_refusesHookOrLensOnAnotherPoolManager() public {
        MockV4PoolManager other = new MockV4PoolManager();

        hook.setPoolManager(address(other));
        vm.expectRevert(V2Errors.NoSource.selector);
        new V4BuybackExecutor(_cfg());
        hook.setPoolManager(address(manager));

        lens.setPoolManager(address(other));
        vm.expectRevert(V2Errors.NoSource.selector);
        new V4BuybackExecutor(_cfg());
    }

    function test_constructor_refusesV3PoolOfTheWrongPair() public {
        MockBuybackV3Pool wrong = new MockBuybackV3Pool(address(tok), address(usdg), V3_FEE);
        V4BuybackConfig memory cfg = _cfg();
        cfg.v3Pool = address(wrong);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        new V4BuybackExecutor(cfg);
    }

    function test_constructor_refusesShallowObservationRing() public {
        v3.setObservationCardinality(1);
        vm.expectRevert(V2Errors.NoSource.selector);
        new V4BuybackExecutor(_cfg());
    }

    function test_constructor_refusesBoundsOutOfRange() public {
        V4BuybackConfig memory cfg = _cfg();
        cfg.maxTotalFeeBps = 0;
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        new V4BuybackExecutor(cfg);

        cfg = _cfg();
        cfg.maxTotalFeeBps = exec.MAX_TOTAL_FEE_CEIL_BPS() + 1;
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        new V4BuybackExecutor(cfg);

        // A tolerance below the pool's own fee could never be met.
        cfg = _cfg();
        cfg.maxSlippageBps = 0;
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        new V4BuybackExecutor(cfg);

        cfg = _cfg();
        cfg.maxSlippageBps = 301;
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        new V4BuybackExecutor(cfg);

        cfg = _cfg();
        cfg.twapWindow = 59;
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        new V4BuybackExecutor(cfg);

        cfg = _cfg();
        cfg.twapWindow = 1 hours + 1;
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        new V4BuybackExecutor(cfg);

        cfg = _cfg();
        cfg.minLiquidity = 0;
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        new V4BuybackExecutor(cfg);
    }

    /*//////////////////////////////////////////////////////////////
                            CALLER GATE
    //////////////////////////////////////////////////////////////*/

    function test_buy_onlyTheSplitterMayCall() public {
        usdg.mint(stranger, USDG_IN);
        vm.prank(stranger);
        usdg.approve(address(exec), type(uint256).max);

        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        exec.buy(USDG_IN, 1, 0);

        vm.expectRevert(V2Errors.NotAuthorized.selector);
        exec.buy(USDG_IN, 1, 0);

        assertEq(v3.swaps(), 0, "a refused caller never reached the venue");
        assertEq(usdg.balanceOf(stranger), USDG_IN, "a refused caller keeps its USDG");
    }

    /*//////////////////////////////////////////////////////////////
                              THE ROUTE
    //////////////////////////////////////////////////////////////*/

    function test_buy_runsTheRouteAndSendsEverythingToTheSplitter() public {
        (uint256 wethOut, uint256 gross, uint256 cut, uint256 expectedOut) = _expected(USDG_IN);
        uint256 splitterUsdg = usdg.balanceOf(splitter);

        vm.expectEmit(true, true, true, true, address(exec));
        emit Bought(
            USDG_IN, USDG_IN, wethOut, expectedOut, _quoteWeth(USDG_IN) * (10_000 - SLIPPAGE_BPS) / 10_000, 201, 201
        );
        (uint256 usdgSpent, uint256 tokenOut) = _buy(USDG_IN, 1, 0);

        assertEq(usdgSpent, USDG_IN, "the whole input was consumed");
        assertEq(tokenOut, expectedOut, "tokens out are the swap delta net of the hook's cut");
        assertEq(gross - cut, expectedOut, "gross minus the hook's cut is what arrived");
        assertEq(tok.balanceOf(splitter), expectedOut, "every token went to the splitter");
        assertEq(usdg.balanceOf(splitter), splitterUsdg - USDG_IN, "the whole input left the splitter");
        assertEq(tok.balanceOf(address(hook)), cut, "the hook kept its fee and the creator tax");
        assertEq(v3.swaps(), 1);
        assertEq(manager.swaps(), 1);
        _assertHoldsNothing(0, 0, 0, 0);
    }

    function test_buy_returnsUnspentUsdgToTheSplitter() public {
        // A v3 pool that consumes only 90 % of the input but still pays the full fill.
        v3.setSwap(MockBuybackV3Pool.Mode.Good, wethPerUsdg, 10_000, 9000);
        uint256 splitterUsdg = usdg.balanceOf(splitter);

        (uint256 usdgSpent, uint256 tokenOut) = _buy(USDG_IN, 1, 0);

        assertEq(usdgSpent, USDG_IN * 9000 / 10_000, "only what the pool took counts as spent");
        assertGt(tokenOut, 0);
        assertEq(usdg.balanceOf(splitter), splitterUsdg - usdgSpent, "the unspent USDG came back in the same call");
        _assertHoldsNothing(0, 0, 0, 0);
    }

    function test_buy_refusesZeroInputAndZeroMinimum() public {
        vm.prank(splitter);
        vm.expectRevert(V2Errors.BadUnits.selector);
        exec.buy(0, 1, 0);

        vm.prank(splitter);
        vm.expectRevert(V2Errors.BadPrice.selector);
        exec.buy(USDG_IN, 0, 0);

        assertEq(v3.swaps(), 0);
    }

    function test_buy_refusesBelowMinTokenOut() public {
        (,,, uint256 expectedOut) = _expected(USDG_IN);

        vm.prank(splitter);
        vm.expectRevert(
            abi.encodeWithSelector(V4BuybackExecutor.TooLittleTokens.selector, expectedOut, expectedOut + 1)
        );
        exec.buy(USDG_IN, expectedOut + 1, 0);

        // Exactly the fill is accepted.
        (, uint256 tokenOut) = _buy(USDG_IN, expectedOut, 0);
        assertEq(tokenOut, expectedOut);
    }

    /*//////////////////////////////////////////////////////////////
                             TWAP FLOOR
    //////////////////////////////////////////////////////////////*/

    function test_buy_refusesAFillBelowTheTwapFloor() public {
        uint256 floor = exec.wethFloor(USDG_IN);
        // 1 % worse than the TWAP, against a 0.51 % tolerance.
        v3.setSwap(MockBuybackV3Pool.Mode.Good, wethPerUsdg, 9900, 10_000);
        (uint256 wethOut,,,) = _expected(USDG_IN);
        assertLt(wethOut, floor, "the fixture really is below the floor");

        vm.prank(splitter);
        vm.expectRevert(abi.encodeWithSelector(V4BuybackExecutor.FloorNotMet.selector, wethOut, floor));
        exec.buy(USDG_IN, 1, 0);
        assertEq(manager.swaps(), 0, "the v4 leg never ran");
        _assertHoldsNothing(0, 0, 0, 0);

        // Inside the tolerance the same route fills.
        v3.setSwap(MockBuybackV3Pool.Mode.Good, wethPerUsdg, 9960, 10_000);
        (, uint256 tokenOut) = _buy(USDG_IN, 1, 0);
        assertGt(tokenOut, 0);
    }

    function test_buy_callerFloorRaisesButCannotLower() public {
        uint256 twapFloor = exec.wethFloor(USDG_IN);
        (uint256 wethOut,,,) = _expected(USDG_IN);

        // A caller asking for more than the venue pays is refused at ITS floor.
        vm.prank(splitter);
        vm.expectRevert(abi.encodeWithSelector(V4BuybackExecutor.FloorNotMet.selector, wethOut, wethOut + 1));
        exec.buy(USDG_IN, 1, wethOut + 1);

        // A caller passing 0, or anything under the TWAP floor, still gets the contract's floor: the fill below it
        // is refused with the TWAP floor as the minimum, not with the caller's.
        v3.setSwap(MockBuybackV3Pool.Mode.Good, wethPerUsdg, 9900, 10_000);
        (uint256 worse,,,) = _expected(USDG_IN);
        vm.prank(splitter);
        vm.expectRevert(abi.encodeWithSelector(V4BuybackExecutor.FloorNotMet.selector, worse, twapFloor));
        exec.buy(USDG_IN, 1, 1);
    }

    function test_buy_refusesWhenTheTwapCannotBeRead() public {
        v3.setObserveReverts(true);
        vm.prank(splitter);
        vm.expectRevert();
        exec.buy(USDG_IN, 1, 0);
        v3.setObserveReverts(false);

        // A window the pool's liquidity cannot support is a NoSource, not a bad price.
        V4BuybackConfig memory cfg = _cfg();
        cfg.minLiquidity = V3_LIQUIDITY * 2;
        V4BuybackExecutor strict = new V4BuybackExecutor(cfg);
        vm.prank(splitter);
        usdg.approve(address(strict), type(uint256).max);
        vm.prank(splitter);
        vm.expectRevert(V2Errors.NoSource.selector);
        strict.buy(USDG_IN, 1, 0);
    }

    function test_wethFloor_viewMatchesTheGuard() public {
        assertEq(exec.wethFloor(USDG_IN), _quoteWeth(USDG_IN) * (10_000 - SLIPPAGE_BPS) / 10_000);
        vm.expectRevert(V2Errors.BadUnits.selector);
        exec.wethFloor(0);
    }

    /*//////////////////////////////////////////////////////////////
                              CALLBACKS
    //////////////////////////////////////////////////////////////*/

    function test_unlockCallback_refusesEveryCallerOutsideABuy() public {
        bytes memory data = abi.encode(uint256(1 ether));

        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        exec.unlockCallback(data);

        // Even the real PoolManager: no buy is on the stack, so there is nothing to call back about.
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        manager.pokeUnlockCallback(address(exec), data);

        vm.prank(address(manager));
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        exec.unlockCallback(data);
    }

    function test_uniswapV3SwapCallback_refusesEveryCallerOutsideABuy() public {
        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        exec.uniswapV3SwapCallback(-1, int256(USDG_IN), "");

        // The pinned pool itself cannot make the executor pay outside a buy.
        vm.prank(address(v3));
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        exec.uniswapV3SwapCallback(-1, int256(USDG_IN), "");
    }

    function test_buy_refusesAPoolThatAsksForTheOutputToken() public {
        v3.setSwap(MockBuybackV3Pool.Mode.WrongSide, wethPerUsdg, 10_000, 10_000);
        vm.prank(splitter);
        vm.expectRevert(V2Errors.BadUnits.selector);
        exec.buy(USDG_IN, 1, 0);
        _assertHoldsNothing(0, 0, 0, 0);
    }

    function test_receive_acceptsOnlyWeth() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(exec).call{value: 1 ether}("");
        assertFalse(ok, "a stranger cannot leave ETH here");
        assertEq(address(exec).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            HOLDS NOTHING
    //////////////////////////////////////////////////////////////*/

    function test_buy_refusesAWrapperThatUnderpaysTheUnwrap() public {
        weth.setMode(MockWeth9.Mode.ShortPay, 9000);
        vm.prank(splitter);
        vm.expectRevert(V2Errors.BadUnits.selector);
        exec.buy(USDG_IN, 1, 0);
        _assertHoldsNothing(0, 0, 0, 0);
    }

    function test_buy_refusesAWrapperThatDoesNotBurn() public {
        weth.setMode(MockWeth9.Mode.NoBurn, 10_000);
        vm.prank(splitter);
        vm.expectRevert(V2Errors.BadUnits.selector);
        exec.buy(USDG_IN, 1, 0);
        _assertHoldsNothing(0, 0, 0, 0);
    }

    /// @dev Assets someone sends here directly are measured around, never swept into a buy and never left as a
    ///      shortfall: every check is a delta against the balance at entry.
    function test_buy_measuresAroundDonationsAndLeavesThemUntouched() public {
        usdg.mint(address(exec), 7e6);
        tok.mint(address(exec), 3e18);
        weth.mint(address(exec), 11);
        vm.deal(address(weth), address(weth).balance + 11);

        (,,, uint256 expectedOut) = _expected(USDG_IN);
        (uint256 usdgSpent, uint256 tokenOut) = _buy(USDG_IN, 1, 0);

        assertEq(usdgSpent, USDG_IN);
        assertEq(tokenOut, expectedOut, "the donation was not counted as a fill");
        assertEq(tok.balanceOf(splitter), expectedOut, "the donated tokens were not sent to the splitter");
        _assertHoldsNothing(7e6, 11, 3e18, 0);
    }

    function test_buy_repeatsWithoutCarryingAnythingOver() public {
        for (uint256 i; i < 3; ++i) {
            (,,, uint256 expectedOut) = _expected(USDG_IN);
            (, uint256 tokenOut) = _buy(USDG_IN, 1, 0);
            assertEq(tokenOut, expectedOut, "every buy stands alone");
            _assertHoldsNothing(0, 0, 0, 0);
        }
        assertEq(manager.unlocker(), address(0), "the lock is closed between buys");
    }

    function test_execute_burnsAndSupplyDeltaMatches() public {
        vm.prank(splitter);
        (uint256 tokenOut, uint256 burned) = exec.execute(USDG_IN, 1);
        // `burned` is measured around the burn itself (chain-state supply delta), not across the
        // mock's mint-to-pay. On the live PoolManager, take() transfers existing tokens so the
        // whole-call supply delta equals this figure; FeeSplitter checks that.
        assertEq(burned, tokenOut);
        assertEq(tok.balanceOf(splitter), 0, "execute does not send tokens to the splitter");
        assertEq(tok.balanceOf(address(exec)), 0);
    }

    function test_execute_onlySplitter() public {
        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        exec.execute(USDG_IN, 1);
    }

    function test_uniswapV3SwapCallback_refusesStrangerDuringBuy() public {
        InFlightCallbackAttacker attacker = new InFlightCallbackAttacker();
        v3.setInFlightAttacker(address(attacker));
        vm.prank(splitter);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        exec.buy(USDG_IN, 1, 0);
    }

    function test_unlockCallback_refusesStrangerDuringBuy() public {
        InFlightCallbackAttacker attacker = new InFlightCallbackAttacker();
        manager.setInFlightUnlockAttacker(address(attacker));
        vm.prank(splitter);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        exec.buy(USDG_IN, 1, 0);
    }

    function test_constructor_refusesNearMissFeeAndSpacingAndCurrency() public {
        V4BuybackConfig memory cfg = _cfg();
        cfg.key.fee = 1;
        vm.expectRevert(V2Errors.NoSource.selector);
        new V4BuybackExecutor(cfg);
        cfg = _cfg();
        cfg.key.tickSpacing = cfg.key.tickSpacing + 1;
        vm.expectRevert(V2Errors.NoSource.selector);
        new V4BuybackExecutor(cfg);
        cfg = _cfg();
        cfg.key.currency0 = address(weth);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        new V4BuybackExecutor(cfg);
    }
}
