// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {Vault} from "../../src/Vault.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";

/// @title AF-03 regression: `completeRedeem` pays the NVDA leg even when the USDG leg cannot move
/// @notice Ported from the audit PoC `PoC_completeredeem_all_or_nothing_legs.t.sol` (AUDIT-FINDINGS F-03,
///         Medium), plus the frozen-RECEIVER case from the USDG recon. FIXED FORM (stage C-02): the same
///         attack runs, and the final assertions are inverted. The Stock Token leg is paid with
///         `safeTransfer`, the USDG leg is best-effort through `_tryTransfer`, and `owedQueueUsdg` /
///         `usdgReservedForQueue` / `usdgAccounted` change only when the USDG actually moved. A settled
///         queuer therefore gets her principal on the first call whatever USDG is doing, and collects the
///         USDG once the obstruction clears, to the same or to another receiver.
contract AF03_CompleteRedeemLegs is BaseTest {
    function _closeCycle() internal {
        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();
        _rollClose();
    }

    /// @dev alice & bob deposit 20e18; 10 contracts filled at $1.90; alice queues all 20e18.
    function _setupFilledWeekWithAliceQueued() internal {
        _deposit(alice, 20e18);
        _deposit(bob, 20e18);
        _openAndSell(10);
        vm.prank(alice);
        vault.queueRedeem(20e18);
    }

    /// @dev The books a deferred USDG leg must leave untouched.
    struct UsdgBooks {
        uint256 owed;
        uint256 reserved;
        uint256 accounted;
        uint256 vaultBalance;
    }

    function _usdgBooks(address who) internal view returns (UsdgBooks memory b) {
        b.owed = vault.owedQueueUsdg(who);
        b.reserved = vault.usdgReservedForQueue();
        b.accounted = vault.usdgAccounted();
        b.vaultBalance = usdg.balanceOf(address(vault));
    }

    function _assertUsdgBooksUnchanged(UsdgBooks memory before, address who, string memory why) internal view {
        UsdgBooks memory now_ = _usdgBooks(who);
        assertEq(now_.owed, before.owed, string.concat(why, ": owedQueueUsdg moved without a transfer"));
        assertEq(now_.reserved, before.reserved, string.concat(why, ": usdgReservedForQueue moved without a transfer"));
        assertEq(now_.accounted, before.accounted, string.concat(why, ": usdgAccounted was debited for nothing"));
        assertEq(now_.vaultBalance, before.vaultBalance, string.concat(why, ": USDG left the vault"));
    }

    /// (a1) Global USDG pause after settlement: alice collects her 20e18 NVDA on the first call, the
    ///      USDG stays booked to her, and she collects it after the unpause.
    function test_usdgPause_paysTheNvdaLegAndDefersTheUsdgLeg() public {
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

        // FIXED: alice gets her NVDA now. The USDG leg is deferred, and every USDG book is untouched.
        uint256 usdgBefore = usdg.balanceOf(alice);
        vm.expectEmit(true, true, false, true, address(vault));
        emit Vault.UsdgLegDeferred(alice, alice, owedU);
        vm.prank(alice);
        (uint256 a, uint256 u) = vault.completeRedeem(alice);
        assertEq(a, 20e18, "principal paid on the first call");
        assertEq(u, 0, "USDG leg reported as not paid");
        assertEq(nvda.balanceOf(alice), 30e18, "the NVDA reached her");
        assertEq(usdg.balanceOf(alice), usdgBefore, "no USDG moved under the pause");
        assertEq(vault.owedAssets(alice), 0, "asset leg fully collected");
        assertEq(vault.reservedAssets(), 0, "asset reserve released");
        assertEq(vault.owedQueueUsdg(alice), owedU, "USDG still booked to alice");
        assertEq(vault.usdgReservedForQueue(), owedU, "and still reserved for the queue");

        // A second call with only USDG left says exactly why nothing moved, and changes nothing.
        UsdgBooks memory books = _usdgBooks(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Vault.UsdgLegBlocked.selector, owedU));
        vault.completeRedeem(alice);
        _assertUsdgBooksUnchanged(books, alice, "blocked retry");

        // Lifting the pause releases the USDG.
        usdg.unpause();
        vm.prank(alice);
        (a, u) = vault.completeRedeem(alice);
        assertEq(a, 0, "no principal left");
        assertEq(u, owedU, "the deferred USDG is paid in full");
        assertEq(usdg.balanceOf(alice), usdgBefore + owedU);
        assertEq(vault.owedQueueUsdg(alice), 0);
        assertEq(vault.usdgReservedForQueue(), 0, "queue USDG reserve fully released");
    }

    /// (a2) Vault frozen on USDG while Listed. The OTM rollClose still succeeds (the fee push is
    ///      best-effort and `clear.redeem` only moves NVDA), bob exits, and alice's principal is paid
    ///      on the first call however long the freeze lasts. The USDG waits for the unfreeze.
    function test_vaultFrozenOnUsdg_stillPaysQueuedPrincipal() public {
        _setupFilledWeekWithAliceQueued();

        usdg.freeze(address(vault));

        _closeCycle(); // must still succeed: SECURITY finding 4 made the fee push best-effort
        assertEq(_phase(), uint8(Vault.Phase.Idle), "rollClose survived the freeze");

        (uint256 owedA, uint256 owedU) = vault.previewCompleteRedeem(alice);
        assertEq(owedA, 20e18);
        assertGt(owedU, 0);

        vm.prank(bob);
        assertEq(vault.redeem(20e18, bob, bob), 20e18, "bob exits");

        // A year passes. FIXED: the principal is paid; only the USDG waits.
        vm.warp(block.timestamp + 365 days);
        vm.prank(alice);
        (uint256 a, uint256 u) = vault.completeRedeem(alice);
        assertEq(a, 20e18, "principal paid under the vault-side freeze");
        assertEq(u, 0, "USDG deferred");
        assertEq(nvda.balanceOf(alice), 30e18, "alice has her 20e18 NVDA back");
        assertEq(nvda.balanceOf(address(vault)), 0, "nothing left in the vault on the asset side");
        assertEq(vault.owedQueueUsdg(alice), owedU, "USDG still owed");

        // Receiver choice does not help while the vault itself is the frozen sender, and nothing moves.
        UsdgBooks memory books = _usdgBooks(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Vault.UsdgLegBlocked.selector, owedU));
        vault.completeRedeem(carol);
        _assertUsdgBooksUnchanged(books, alice, "frozen vault");

        usdg.unfreeze(address(vault));
        vm.prank(alice);
        (a, u) = vault.completeRedeem(alice);
        assertEq(a, 0);
        assertEq(u, owedU, "USDG collected after the unfreeze");
        assertEq(vault.usdgReservedForQueue(), 0);
    }

    /// (a3) The RECEIVER is frozen on USDG while the vault is healthy: paying alice's own address moves
    ///      the NVDA, defers the USDG, and she then collects the USDG to a receiver that is not frozen.
    function test_frozenReceiver_getsTheNvdaAndCollectsUsdgElsewhere() public {
        _setupFilledWeekWithAliceQueued();
        _closeCycle();

        (uint256 owedA, uint256 owedU) = vault.previewCompleteRedeem(alice);
        assertEq(owedA, 20e18);
        assertGt(owedU, 0);

        usdg.freeze(alice);

        // FIXED: the recipient check on the USDG leg no longer blocks the NVDA leg.
        vm.prank(alice);
        (uint256 a, uint256 u) = vault.completeRedeem(alice);
        assertEq(a, 20e18, "NVDA paid to the USDG-frozen receiver");
        assertEq(u, 0, "USDG deferred");
        assertEq(nvda.balanceOf(alice), 30e18);
        assertEq(vault.owedQueueUsdg(alice), owedU, "USDG still booked");

        // Same receiver again: blocked, nothing moves.
        UsdgBooks memory books = _usdgBooks(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Vault.UsdgLegBlocked.selector, owedU));
        vault.completeRedeem(alice);
        _assertUsdgBooksUnchanged(books, alice, "frozen receiver");

        // A different receiver works right away: the vault is not the frozen party.
        uint256 carolBefore = usdg.balanceOf(carol);
        vm.prank(alice);
        (a, u) = vault.completeRedeem(carol);
        assertEq(a, 0);
        assertEq(u, owedU, "USDG paid to carol");
        assertEq(usdg.balanceOf(carol), carolBefore + owedU);
        assertEq(vault.owedQueueUsdg(alice), 0);
        assertEq(vault.usdgReservedForQueue(), 0);
    }

    /// (a4) Both legs owed, both healthy: one call pays both, exactly as before the split.
    function test_healthyTokens_payBothLegsInOneCall() public {
        _setupFilledWeekWithAliceQueued();
        _closeCycle();
        (uint256 owedA, uint256 owedU) = vault.previewCompleteRedeem(alice);

        uint256 usdgBefore = usdg.balanceOf(alice);
        vm.prank(alice);
        (uint256 a, uint256 u) = vault.completeRedeem(alice);
        assertEq(a, owedA);
        assertEq(u, owedU);
        assertEq(nvda.balanceOf(alice), 30e18);
        assertEq(usdg.balanceOf(alice), usdgBefore + owedU);
        assertEq(vault.reservedAssets(), 0);
        assertEq(vault.usdgReservedForQueue(), 0);
    }

    /// (b) Stock Token pause: the mirror case. The NVDA leg is a hard `safeTransfer` (there is nothing
    ///     to pay principal with while the issuer has paused the token), so `completeRedeem` reverts and
    ///     alice's queue USDG waits behind it while bob's `claimUsdg` works. AUDIT-SCOPE §5 A.2 documents
    ///     this asymmetry as accepted: a Stock Token pause is the issuer stopping settlement, and the
    ///     USDG follows the principal once the pause lifts.
    function test_stockPause_blocksQueueUsdgBehindThePrincipal() public {
        _setupFilledWeekWithAliceQueued();
        _closeCycle();

        (uint256 owedA, uint256 owedU) = vault.previewCompleteRedeem(alice);
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
        assertEq(usdg.balanceOf(alice), aliceBefore, "alice's queue USDG waits behind the NVDA leg");
        assertEq(vault.owedAssets(alice) + _pendingAssets(alice), owedA, "principal still booked");

        nvda.unpause();
        vm.prank(alice);
        (uint256 a, uint256 u) = vault.completeRedeem(alice);
        assertEq(a, owedA);
        assertEq(u, owedU);
    }

    function _pendingAssets(address who) internal view returns (uint256) {
        (uint256 a,) = vault.previewCompleteRedeem(who);
        return a - vault.owedAssets(who);
    }
}
