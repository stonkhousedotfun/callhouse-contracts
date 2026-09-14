// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {Vault} from "../../src/Vault.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {OrderComponents} from "../../src/interfaces/ISeaport.sol";

/// @title AF-03 regression: `completeRedeem` pays the NVDA and USDG legs all-or-nothing
/// @notice Ported from the audit PoC `PoC_completeredeem_all_or_nothing_legs.t.sol` (AUDIT-FINDINGS F-03,
///         Medium), plus the frozen-RECEIVER case from the USDG recon. BUG-PRESENT FORM: a USDG-side
///         failure takes the Stock Token leg down with it while non-queuers exit instantly. Stage C-02
///         inverts these: the NVDA leg is paid with `safeTransfer`, the USDG leg is best-effort through
///         `_tryTransfer`, and `owedQueueUsdg` / `usdgReservedForQueue` change only on success.
contract AF03_CompleteRedeemLegs is BaseTest {
    function _closeCycle() internal {
        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();
        _rollClose();
    }

    /// @dev alice & bob deposit 20e18; 10 contracts filled at $2; alice queues all 20e18.
    function _setupFilledWeekWithAliceQueued() internal {
        _deposit(alice, 20e18);
        _deposit(bob, 20e18);
        uint256 optionId = _rollOpen(10);
        OrderComponents memory c = _approveListing(optionId, 10, _okUnitPrice());
        _fill(c, 10);
        vm.prank(alice);
        vault.queueRedeem(20e18);
    }

    /// (a1) Global USDG pause after settlement: alice's 20e18 NVDA principal cannot be collected while
    ///      bob exits instantly. Nothing in the vault pays the asset leg alone.
    function test_usdgPause_freezesQueuedPrincipal() public {
        _setupFilledWeekWithAliceQueued();
        _closeCycle();
        assertEq(_phase(), uint8(Vault.Phase.Idle), "flat");

        (uint256 owedA, uint256 owedU) = vault.previewCompleteRedeem(alice);
        assertEq(owedA, 20e18);
        assertGt(owedU, 0, "almost every settled entry carries some USDG");

        usdg.pause();

        // bob, unqueued, exits with his full principal: the instant path never touches USDG.
        vm.prank(bob);
        assertEq(vault.redeem(20e18, bob, bob), 20e18, "bob instant redeem works under USDG pause");
        assertEq(nvda.balanceOf(bob), 30e18);

        // BUG PRESENT: alice cannot get her NVDA. The USDG leg reverts and takes the NVDA leg with it.
        uint256 before = nvda.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(MockERC20.ContractPaused.selector);
        vault.completeRedeem(alice);

        // No other path: no free shares to redeem.
        assertEq(vault.balanceOf(alice), 0);
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(1, alice, alice);

        assertEq(nvda.balanceOf(alice), before, "alice got no NVDA");
        assertEq(vault.owedAssets(alice) + _pendingAssets(alice), 20e18, "20e18 NVDA principal still locked");

        // Only lifting the USDG pause releases her Stock Token.
        usdg.unpause();
        vm.prank(alice);
        (uint256 a, uint256 u) = vault.completeRedeem(alice);
        assertEq(a, 20e18);
        assertEq(u, owedU);
    }

    /// (a2) Vault frozen on USDG while Listed. The OTM rollClose still succeeds (the fee push is
    ///      best-effort and `clear.redeem` only moves NVDA), bob exits, alice's principal is locked for
    ///      as long as the freeze lasts, which on this chain has so far meant for ever.
    function test_vaultFrozenOnUsdg_freezesQueuedPrincipalIndefinitely() public {
        _setupFilledWeekWithAliceQueued();

        usdg.freeze(address(vault));

        _closeCycle(); // must still succeed: SECURITY finding 4 made the fee push best-effort
        assertEq(_phase(), uint8(Vault.Phase.Idle), "rollClose survived the freeze");

        (uint256 owedA, uint256 owedU) = vault.previewCompleteRedeem(alice);
        assertEq(owedA, 20e18);
        assertGt(owedU, 0);

        vm.prank(bob);
        assertEq(vault.redeem(20e18, bob, bob), 20e18, "bob exits");

        // A year passes; still locked.
        vm.warp(block.timestamp + 365 days);
        vm.prank(alice);
        vm.expectRevert(MockERC20.AddressFrozen.selector);
        vault.completeRedeem(alice);

        // Receiver choice does not help: the vault itself is the frozen sender.
        vm.prank(alice);
        vm.expectRevert(MockERC20.AddressFrozen.selector);
        vault.completeRedeem(carol);

        assertEq(nvda.balanceOf(alice), 10e18, "alice still missing 20e18 NVDA");
        assertEq(nvda.balanceOf(address(vault)), 20e18, "her NVDA sits in the vault, unpayable");
    }

    /// (a3) The RECEIVER is frozen on USDG while the vault is healthy: paying alice's own address
    ///      reverts on the USDG leg, so her NVDA is not paid either.
    function test_frozenReceiver_blocksTheNvdaLegToo() public {
        _setupFilledWeekWithAliceQueued();
        _closeCycle();

        (uint256 owedA, uint256 owedU) = vault.previewCompleteRedeem(alice);
        assertEq(owedA, 20e18);
        assertGt(owedU, 0);

        usdg.freeze(alice);

        // BUG PRESENT: the recipient check on the USDG leg reverts the whole payout.
        vm.prank(alice);
        vm.expectRevert(MockERC20.AddressFrozen.selector);
        vault.completeRedeem(alice);
        assertEq(nvda.balanceOf(alice), 10e18, "no NVDA paid");
        assertEq(vault.owedAssets(alice) + _pendingAssets(alice), 20e18, "principal still parked");
    }

    /// (b) Stock Token pause: alice's queue USDG is locked while bob's `claimUsdg` works. This is the
    ///     mirror case AUDIT-SCOPE §5 A.2 documents as expected; the leg split fixes it too.
    function test_stockPause_blocksQueueUsdg() public {
        _setupFilledWeekWithAliceQueued();
        _closeCycle();

        (, uint256 owedU) = vault.previewCompleteRedeem(alice);
        assertGt(owedU, 0);

        nvda.pause();

        uint256 bobBefore = usdg.balanceOf(bob);
        vm.prank(bob);
        uint256 got = vault.claimUsdg();
        assertGt(got, 0, "bob's USDG claim works under the pause");
        assertEq(usdg.balanceOf(bob) - bobBefore, got);

        uint256 aliceBefore = usdg.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(MockStockToken.TokenPaused.selector);
        vault.completeRedeem(alice);
        assertEq(usdg.balanceOf(alice), aliceBefore, "alice's queue USDG is stuck behind the NVDA leg");
    }

    function _pendingAssets(address who) internal view returns (uint256) {
        (uint256 a,) = vault.previewCompleteRedeem(who);
        return a - vault.owedAssets(who);
    }
}
