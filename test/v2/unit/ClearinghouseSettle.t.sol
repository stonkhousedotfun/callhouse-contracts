// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {ClearinghouseTestBase} from "./ClearinghouseBase.t.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {OptionMath} from "../../../src/v2/lib/OptionMath.sol";
import {MockSettlementOracle} from "../../../src/v2/mocks/MockSettlementOracle.sol";

/// @notice A bounty payer that always reverts, to show a failing KeeperRewards cannot take a settlement down.
contract ClearinghouseRevertingRewards {
    error RewardsDown();

    function reward(address, bytes32) external pure returns (uint256) {
        revert RewardsDown();
    }
}

/// @notice Clearinghouse.settle: expiry gate, oracle not final / final / reverting, finalize from inside settle,
///         stored amounts, idempotency, the SETTLE bounty gate, and the oracle and fee pinned at creation.
contract ClearinghouseSettleTest is ClearinghouseTestBase {
    uint256 internal callId;
    uint256 internal putId;

    function setUp() public override {
        super.setUp();
        callId = _call(K_240, FRI_2026_09_18);
        putId = _put(K_200, FRI_2026_09_18);
    }

    /*//////////////////////////////////////////////////////////////
                              EXPIRY GATE
    //////////////////////////////////////////////////////////////*/

    function test_settle_notExpired() public {
        _write(alice, callId, 10, bob);
        oracle.setSettlement(address(nvda), FRI_2026_09_18, V2Types.SettlementStatus.Finalized, 250_000_000);
        vm.warp(FRI_2026_09_18 - 1);
        vm.prank(keeper);
        vm.expectRevert(V2Errors.NotExpired.selector);
        ch.settle(callId);

        vm.warp(FRI_2026_09_18);
        vm.prank(keeper);
        assertTrue(ch.settle(callId), "settles from the expiry second once the price is final");
    }

    function test_settle_unknownSeries() public {
        vm.expectRevert(V2Errors.UnknownSeries.selector);
        ch.settle(_short(callId));
        vm.expectRevert(V2Errors.UnknownSeries.selector);
        ch.settle(424_242);
    }

    /*//////////////////////////////////////////////////////////////
                             ORACLE NOT FINAL
    //////////////////////////////////////////////////////////////*/

    /// @dev None, Pending and Held all return false without storing anything; finalize is attempted each time.
    function test_settle_notFinalReturnsFalse() public {
        _write(alice, callId, 10, bob);
        vm.warp(FRI_2026_09_18 + V2Constants.FINALIZE_DELAY);
        V2Types.SettlementStatus[3] memory states =
            [V2Types.SettlementStatus.None, V2Types.SettlementStatus.Pending, V2Types.SettlementStatus.Held];
        for (uint256 i; i < states.length; ++i) {
            oracle.setSettlement(address(nvda), FRI_2026_09_18, states[i], 0);
            uint256 calls = oracle.finalizeCalls();
            vm.recordLogs();
            vm.prank(keeper);
            assertFalse(ch.settle(callId), "not final -> false");
            assertEq(vm.getRecordedLogs().length, 0, "no event");
            assertEq(oracle.finalizeCalls(), calls + 1, "finalize was tried");
            assertFalse(ch.series(callId).settled);
        }
        assertEq(usdg.balanceOf(keeper), 0, "no bounty for a call that did not advance");
    }

    /// @dev Between expiry and expiry + FINALIZE_DELAY the oracle's finalize reverts TooEarly: settle swallows it.
    function test_settle_finalizeTooEarlyIsNotFinal() public {
        _write(alice, callId, 10, bob);
        vm.warp(FRI_2026_09_18 + 1);
        vm.prank(keeper);
        assertFalse(ch.settle(callId));
        assertEq(oracle.finalizeCalls(), 0, "the TooEarly revert was caught");
    }

    function test_settle_revertingOracleIsNotFinal() public {
        _write(alice, callId, 10, bob);
        vm.warp(FRI_2026_09_18 + 1 days);
        oracle.setFinalizeMode(address(nvda), FRI_2026_09_18, MockSettlementOracle.FinalizeMode.Revert, 0);
        oracle.setSettlementPriceReverts(true);
        vm.prank(keeper);
        assertFalse(ch.settle(callId), "both oracle calls revert -> false, not a revert");
    }

    /// @dev A view that reverts still lets finalize settle the series.
    function test_settle_revertingViewFallsBackToFinalize() public {
        _write(alice, callId, 10, bob);
        vm.warp(FRI_2026_09_18 + 1 days);
        oracle.setSettlementPriceReverts(true);
        oracle.setFinalizeMode(address(nvda), FRI_2026_09_18, MockSettlementOracle.FinalizeMode.FinalizeOnCall, 250e6);
        vm.prank(keeper);
        assertTrue(ch.settle(callId));
        assertEq(ch.series(callId).settlementPrice, 250e6);
    }

    /*//////////////////////////////////////////////////////////////
                                  FINAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Pending in the view, final after the finalize settle itself makes.
    function test_settle_finalizesThroughTheOracle() public {
        _write(alice, callId, 10, bob);
        oracle.setSettlement(address(nvda), FRI_2026_09_18, V2Types.SettlementStatus.Pending, 0);
        oracle.setFinalizeMode(address(nvda), FRI_2026_09_18, MockSettlementOracle.FinalizeMode.FinalizeOnCall, 250e6);
        vm.warp(FRI_2026_09_18 + V2Constants.FINALIZE_DELAY);
        vm.prank(keeper);
        assertTrue(ch.settle(callId));
        assertEq(oracle.finalizeCalls(), 1);
        (V2Types.SettlementStatus status, uint256 price) = oracle.settlementPrice(address(nvda), FRI_2026_09_18);
        assertEq(uint8(status), uint8(V2Types.SettlementStatus.Finalized));
        assertEq(price, 250e6);
    }

    /// @dev Already final in the view: finalize is not called at all.
    function test_settle_finalViewSkipsFinalize() public {
        _write(alice, callId, 10, bob);
        _settle(callId, 250e6);
        assertEq(oracle.finalizeCalls(), 0);
    }

    /// @dev NVDA call K = 240, P = 250: gross = 1e16 * 10 / 250 = 4e14, fee = min(1e16 * 25 bps, 10 % of gross) = 2.5e13.
    function test_settle_storesCallAmountsAndEmits() public {
        _write(alice, callId, 10, bob);
        oracle.setSettlement(address(nvda), FRI_2026_09_18, V2Types.SettlementStatus.Finalized, 250e6);
        vm.warp(FRI_2026_09_18 + V2Constants.FINALIZE_DELAY);
        vm.expectEmit(true, false, false, true, address(ch));
        emit IClearinghouse.SeriesSettled(callId, 250e6, 3.75e14, 2.5e13, 9.6e15);
        vm.prank(keeper);
        assertTrue(ch.settle(callId));

        V2Types.Series memory s = ch.series(callId);
        assertTrue(s.settled);
        assertEq(s.settlementPrice, 250e6);
        assertEq(s.longPayoutPerUnit, 3.75e14);
        assertEq(s.feePerUnit, 2.5e13);
        assertEq(s.shortPayoutPerUnit, 9.6e15);
        assertEq(uint256(s.longPayoutPerUnit) + s.feePerUnit + s.shortPayoutPerUnit, V2Constants.UNIT);
        assertEq(ch.locked(callId), 10 * V2Constants.UNIT, "settlement moves nothing");
    }

    /// @dev Put K = 200, P = 190: gross = 0.10 USDG, fee = min(2.00 * 25 bps = 0.005, 0.01) = 0.005.
    function test_settle_storesPutAmounts() public {
        _write(alice, putId, 3, bob);
        _settle(putId, 190e6);
        V2Types.Series memory s = ch.series(putId);
        assertEq(s.longPayoutPerUnit, 95_000);
        assertEq(s.feePerUnit, 5_000);
        assertEq(s.shortPayoutPerUnit, 1_900_000);
    }

    function test_settle_idempotent() public {
        _write(alice, callId, 10, bob);
        _settle(callId, 250e6);
        uint256 bounty = usdg.balanceOf(keeper);
        assertEq(bounty, SETTLE_BOUNTY);

        oracle.setSettlement(address(nvda), FRI_2026_09_18, V2Types.SettlementStatus.Finalized, 999e6);
        vm.recordLogs();
        vm.prank(carol);
        assertFalse(ch.settle(callId), "second settle is a no-op");
        assertEq(vm.getRecordedLogs().length, 0, "no second SeriesSettled, no bounty log");
        assertEq(ch.series(callId).settlementPrice, 250e6, "amounts never change");
        assertEq(usdg.balanceOf(carol), ACTOR_USDG, "no second bounty");
    }

    /// @dev One settlement price per (underlying, expiry): each series of the expiry settles on its own call.
    function test_settle_seriesOfOneExpirySettleIndependently() public {
        _write(alice, callId, 10, bob);
        _write(alice, putId, 10, bob);
        _settle(callId, 230e6);
        assertFalse(ch.series(putId).settled, "settling one series leaves the other");
        vm.prank(keeper);
        assertTrue(ch.settle(putId));
        assertEq(ch.series(putId).settlementPrice, 230e6);
        assertEq(ch.series(putId).longPayoutPerUnit, 0, "OTM put");
    }

    /*//////////////////////////////////////////////////////////////
                                 BOUNTY
    //////////////////////////////////////////////////////////////*/

    function test_settle_zeroSupplyPaysNoBounty() public {
        _write(alice, putId, 5, alice);
        vm.prank(alice);
        ch.close(putId, 5);

        _settle(callId, 250e6);
        assertEq(usdg.balanceOf(keeper), 0, "a series nobody wrote pays nothing");

        vm.prank(keeper);
        assertTrue(ch.settle(putId));
        assertEq(usdg.balanceOf(keeper), 0, "a series closed back to zero supply pays nothing");
    }

    function test_settle_bountyToCaller() public {
        _write(alice, callId, 1, bob);
        _settle(callId, 250e6);
        assertEq(usdg.balanceOf(keeper), SETTLE_BOUNTY, "msg.sender earns the SETTLE bounty");
        assertEq(rewards.spentToday(), SETTLE_BOUNTY);
    }

    /// @dev sweep contracts-c02: a dust series earned the full SETTLE bounty, so dust series could spend the shared
    ///      daily cap. The bounty now needs the series' collateral, valued at the settlement price, worth at least
    ///      minRedeemPayout (1.00 USDG at deploy), the REDEEM threshold. With the spot band skipped, one unit of a
    ///      99.00 put locks 0.99 USDG (no bounty) and one unit of a 100.00 put 1.00 USDG (bounty); settled at 99.99,
    ///      one unit of a call locks 0.01 share worth 0.9999 USDG (no bounty) and a second unit makes it 1.9998.
    function test_settle_bountyNeedsTheSeriesWorthMinRedeemPayout() public {
        oracle.setSpot(address(nvda), false, 0, 0); // no band: dust strikes are creatable
        uint256 dustPut = _put(99_000_000, FRI_2026_09_18);
        uint256 onePut = _put(100_000_000, FRI_2026_09_18);
        uint256 dustCall = _call(K_240, FRI_2026_09_11);
        uint256 twoCall = _call(K_220, FRI_2026_09_11);
        _write(alice, dustPut, 1, bob);
        _write(alice, onePut, 1, bob);
        _write(alice, dustCall, 1, bob);
        _write(alice, twoCall, 2, bob);
        assertEq(ch.locked(dustPut), 990_000);
        assertEq(ch.locked(onePut), 1_000_000);

        _settle(dustCall, 99_990_000);
        assertEq(usdg.balanceOf(keeper), 0, "a call worth 0.9999 USDG at P pays no bounty");
        vm.prank(keeper);
        assertTrue(ch.settle(twoCall));
        assertEq(usdg.balanceOf(keeper), SETTLE_BOUNTY, "two units, 1.9998 USDG: bounty");

        _settle(dustPut, 150e6);
        assertEq(usdg.balanceOf(keeper), SETTLE_BOUNTY, "a put locking 0.99 USDG pays no bounty");
        vm.prank(keeper);
        assertTrue(ch.settle(onePut));
        assertEq(usdg.balanceOf(keeper), 2 * SETTLE_BOUNTY, "exactly the threshold pays");
    }

    /// @dev The threshold is the admin's REDEEM knob: raised to 5.00 USDG, a 2.50 USDG call pays nothing; at 0 any
    ///      series with supply pays, as before.
    function test_settle_bountyThresholdFollowsMinRedeemPayout() public {
        _write(alice, callId, 1, bob);
        _write(alice, putId, 1, bob);
        vm.prank(admin);
        ch.setMinRedeemPayout(5_000_000);
        _settle(callId, 250e6);
        assertEq(usdg.balanceOf(keeper), 0, "1 unit at 250.00 locks 2.50 USDG of value");

        vm.prank(admin);
        ch.setMinRedeemPayout(0);
        vm.prank(keeper);
        assertTrue(ch.settle(putId));
        assertEq(usdg.balanceOf(keeper), SETTLE_BOUNTY, "threshold 0: any supply pays");
    }

    function test_settle_bountyPayerFailuresDoNotBlock() public {
        _write(alice, callId, 1, bob);
        _write(alice, putId, 1, bob);
        uint256 other = _call(K_220, FRI_2026_09_18);
        _write(alice, other, 1, bob);

        vm.prank(admin);
        rewards.setCaller(address(ch), false); // reward() now reverts NotAuthorized
        _settle(callId, 250e6);
        assertEq(usdg.balanceOf(keeper), 0);

        ClearinghouseRevertingRewards down = new ClearinghouseRevertingRewards();
        vm.prank(admin);
        ch.setKeeperRewards(address(down));
        vm.prank(keeper);
        assertTrue(ch.settle(putId), "a reverting payer is ignored");

        vm.prank(admin);
        ch.setKeeperRewards(address(0));
        vm.prank(keeper);
        assertTrue(ch.settle(other), "no payer at all");
    }

    /*//////////////////////////////////////////////////////////////
                            PINNED AT CREATION
    //////////////////////////////////////////////////////////////*/

    /// @dev The market's fee moves from 25 to 200 bps after creation: settlement still charges 25 bps. A series created
    ///      afterwards on the same expiry charges 200 bps.
    function test_settle_feePinnedAtCreation() public {
        _write(alice, callId, 10, bob);
        V2Types.MarketConfig memory cfg = _cfg(address(oracle));
        cfg.exerciseFeeBps = V2Constants.EXERCISE_FEE_CEIL_BPS;
        vm.prank(admin);
        ch.setMarketConfig(address(nvda), cfg);
        uint256 later = _call(K_220, FRI_2026_09_18);
        _write(alice, later, 10, bob);

        _settle(callId, 250e6);
        _settle(later, 250e6);
        (, uint256 fee25,) = OptionMath.settlementPerUnit(false, K_240, 250e6, FEE_BPS);
        (, uint256 fee200,) = OptionMath.settlementPerUnit(false, K_220, 250e6, 200);
        assertEq(ch.series(callId).feePerUnit, fee25, "old series keeps 25 bps");
        assertEq(fee25, 2.5e13);
        assertEq(ch.series(later).feePerUnit, fee200, "new series has 200 bps");
    }

    /// @dev The market is pointed at another oracle after creation: the series still settles on its own.
    function test_settle_oraclePinnedAtCreation() public {
        _write(alice, callId, 10, bob);
        MockSettlementOracle other = new MockSettlementOracle();
        other.setSettlement(address(nvda), FRI_2026_09_18, V2Types.SettlementStatus.Finalized, 999e6);
        vm.prank(admin);
        ch.setMarketConfig(address(nvda), _cfg(address(other)));

        _settle(callId, 250e6);
        assertEq(ch.series(callId).settlementPrice, 250e6, "read from the pinned oracle");
        assertEq(other.finalizeCalls(), 0);
    }

    /// @dev A final price beyond uint128 is clamped, never a revert that would strand the series.
    function test_settle_hugePriceIsClamped() public {
        _write(alice, callId, 10, bob);
        _write(alice, putId, 10, bob);
        _settle(callId, type(uint256).max);
        vm.prank(keeper);
        assertTrue(ch.settle(putId));

        V2Types.Series memory c = ch.series(callId);
        assertEq(c.settlementPrice, type(uint128).max);
        (uint256 l, uint256 f, uint256 sh) = OptionMath.settlementPerUnit(false, K_240, type(uint128).max, FEE_BPS);
        assertEq(c.longPayoutPerUnit, l);
        assertEq(c.feePerUnit, f);
        assertEq(c.shortPayoutPerUnit, sh);
        assertEq(ch.series(putId).longPayoutPerUnit, 0, "a put at an absurd price is worthless");
    }

    /// @dev Settlement, like redemption, ignores every guardian and admin switch.
    function test_settle_ignoresPausesAndDisabledMarket() public {
        _write(alice, callId, 10, bob);
        vm.startPrank(guardian);
        ch.setMintPaused(address(nvda), true);
        ch.setCreatePaused(true);
        vm.stopPrank();
        V2Types.MarketConfig memory off = _cfg(address(oracle));
        off.enabled = false;
        vm.prank(admin);
        ch.setMarketConfig(address(nvda), off);
        _settle(callId, 250e6);
    }

    function test_settle_logs() public {
        _write(alice, callId, 10, bob);
        oracle.setSettlement(address(nvda), FRI_2026_09_18, V2Types.SettlementStatus.Finalized, 250e6);
        vm.warp(FRI_2026_09_18 + V2Constants.FINALIZE_DELAY);
        vm.recordLogs();
        vm.prank(keeper);
        ch.settle(callId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[0].emitter, address(ch));
        assertEq(logs[0].topics[0], IClearinghouse.SeriesSettled.selector, "SeriesSettled precedes the bounty transfer");
        assertEq(logs[logs.length - 1].emitter, address(rewards), "then KeeperRewards pays");
    }
}
