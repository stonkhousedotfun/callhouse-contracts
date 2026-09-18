// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ClearinghouseTestBase} from "./ClearinghouseBase.t.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MockSettlementOracle} from "../../../src/v2/mocks/MockSettlementOracle.sol";

/// @notice Pause matrix, architecture §3.5 invariant 4: close, redeem and withdraw (and ERC-1155 transfers, settle of a
///         final price, fee sweeps) succeed under every combination of guardian and admin switches and with a reverting
///         or absent oracle; the switches stop only new risk (mint, createSeries).
/// @dev Flags, one bit each: 1 mint paused, 2 creation paused, 4 market disabled, 8 oracle reverting on every call.
///      Every combination runs from the same snapshot.
contract ClearinghousePausesTest is ClearinghouseTestBase {
    uint256 internal constant MINT_PAUSED = 1;
    uint256 internal constant CREATE_PAUSED = 2;
    uint256 internal constant DISABLED = 4;
    uint256 internal constant ORACLE_REVERTS = 8;
    uint256 internal constant ALL = 16;

    uint256 internal callId;
    uint256 internal putId;

    function setUp() public override {
        super.setUp();
        callId = _call(K_240, FRI_2026_09_18);
        putId = _put(K_200, FRI_2026_09_18);
        _write(alice, callId, 20, alice);
        _write(alice, putId, 20, alice);
        _write(alice, callId, 10, bob);
        _write(alice, putId, 10, bob);
        _deposit(alice, address(nvda), 5e18);
        _deposit(alice, address(usdg), 100e6);
        vm.prank(bob);
        ch.setPayoutInKind(true);
    }

    function test_pauseMatrix_beforeSettlement() public {
        for (uint256 flags; flags < ALL; ++flags) {
            uint256 snap = vm.snapshotState();
            _apply(flags);

            // Never paused.
            vm.startPrank(alice);
            ch.close(callId, 5);
            ch.close(putId, 5);
            ch.withdraw(address(nvda), 1e18, alice);
            ch.withdraw(address(usdg), 10e6, alice);
            ch.deposit(address(usdg), 1e6, alice);
            ch.setOperator(mm, true);
            vm.stopPrank();
            vm.prank(bob);
            ch.safeTransferFrom(bob, carol, callId, 3, "");
            _assertBacked(callId);
            _assertBacked(putId);

            // New risk only.
            vm.prank(alice);
            if (flags & DISABLED != 0) {
                vm.expectRevert(V2Errors.MarketDisabled.selector);
            } else if (flags & MINT_PAUSED != 0) {
                vm.expectRevert(V2Errors.MintPaused.selector);
            }
            ch.mint(callId, 1, alice, alice);

            if (flags & DISABLED != 0) {
                vm.expectRevert(V2Errors.MarketDisabled.selector);
            } else if (flags & CREATE_PAUSED != 0) {
                vm.expectRevert(V2Errors.CreatePaused.selector);
            }
            ch.createSeries(address(nvda), false, K_220, FRI_2026_09_18);

            // Expiry passes: close still works until settlement, settle simply cannot advance on a broken oracle.
            vm.warp(FRI_2026_09_18 + 1 days);
            vm.prank(alice);
            ch.close(callId, 1);
            oracle.setSettlement(address(nvda), FRI_2026_09_18, V2Types.SettlementStatus.Finalized, 250e6);
            vm.prank(keeper);
            assertEq(ch.settle(callId), flags & ORACLE_REVERTS == 0, "settles unless the oracle reverts");

            vm.revertToState(snap);
        }
    }

    function test_pauseMatrix_afterSettlement() public {
        _settle(callId, 250e6);
        vm.prank(keeper);
        ch.settle(putId);

        for (uint256 flags; flags < ALL + 1; ++flags) {
            uint256 snap = vm.snapshotState();
            if (flags == ALL) {
                // Every switch on and the oracle gone entirely: no code at its address.
                _apply(ALL - 1);
                vm.etch(address(oracle), "");
            } else {
                _apply(flags);
            }

            (uint256 paid,) = _redeem(callId, bob);
            assertEq(paid, 10 * 3.75e14, "long redeemed");
            (paid,) = _redeem(putId, bob);
            assertEq(paid, 0, "OTM put burned");

            address[] memory writer = new address[](1);
            writer[0] = alice;
            vm.prank(keeper);
            assertEq(ch.redeemBatch(_short(callId), writer), 1, "batch works");
            (paid,) = _redeem(callId, alice);
            assertEq(paid, 20 * 3.75e14);
            (paid,) = _redeem(_short(putId), alice);
            assertEq(paid, 30 * 2e6);

            vm.startPrank(alice);
            ch.withdraw(address(nvda), 5e18, alice);
            ch.withdraw(address(usdg), 100e6, alice);
            vm.stopPrank();
            ch.sweepFees(address(nvda));
            assertEq(nvda.balanceOf(treasury), 30 * 2.5e13);

            vm.prank(keeper);
            assertFalse(ch.settle(callId), "already settled: no oracle read");
            assertEq(ch.locked(callId), 0);
            assertEq(ch.locked(putId), 0);
            assertEq(nvda.balanceOf(address(ch)), 0, "everything paid out");
            assertEq(usdg.balanceOf(address(ch)), 0);

            vm.revertToState(snap);
        }
    }

    /// @dev The guardian can pause, never un-write: a paused market's positions keep their full value.
    function test_pauses_doNotTouchBalancesOrLedger() public {
        uint256 freeNvda = ch.free(alice, address(nvda));
        uint256 lockedCall = ch.locked(callId);
        _apply(MINT_PAUSED | CREATE_PAUSED | DISABLED);
        assertEq(ch.free(alice, address(nvda)), freeNvda);
        assertEq(ch.locked(callId), lockedCall);
        assertEq(ch.balanceOf(bob, callId), 10);
    }

    function _apply(uint256 flags) internal {
        if (flags & MINT_PAUSED != 0) {
            vm.prank(guardian);
            ch.setMintPaused(address(nvda), true);
        }
        if (flags & CREATE_PAUSED != 0) {
            vm.prank(guardian);
            ch.setCreatePaused(true);
        }
        if (flags & DISABLED != 0) {
            V2Types.MarketConfig memory off = _cfg(address(oracle));
            off.enabled = false;
            vm.prank(admin);
            ch.setMarketConfig(address(nvda), off);
        }
        if (flags & ORACLE_REVERTS != 0) {
            oracle.setTrySpotReverts(true);
            oracle.setSettlementPriceReverts(true);
            oracle.setFinalizeMode(address(nvda), FRI_2026_09_18, MockSettlementOracle.FinalizeMode.Revert, 0);
        }
    }
}
