// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {Vault} from "../../src/Vault.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {OrderComponents} from "../../src/interfaces/ISeaport.sol";

/// @title AF-02 regression: a redeem revert in an assigned week bricks `rollClose` and freezes everything
/// @notice Ported from the audit PoC `PoC_usdg_freeze_bricks_rollclose_assigned_week.t.sol` (AUDIT-FINDINGS
///         F-02, Medium), widened to the full trigger set found by the integration recon. BUG-PRESENT
///         FORM: every test below asserts that `rollClose` reverts and that nothing else leaves
///         Listed/Exercisable. Stage C-05 (stranded-claim state machine) inverts them: `rollClose` must
///         reach Idle with the claim kept, the queue must settle from idle NVDA, and a permissionless
///         `retryStrandedClaim()` must distribute the claim once the cause clears.
/// @dev Upstream `redeem` pushes the exercise asset (USDG) first and the underlying (NVDA) second, each
///      only if > 0, in one call (integrations/valorem.md §4.7). Either leg reverting reverts the redeem,
///      and today `rollClose` is the only exit from Listed/Exercisable. The triggers, all instant and none
///      behind a timelock (integrations/usdg.md §3, §7; robinhood-chain.md §3):
///        (a) USDG paused                              -> USDG leg reverts `ContractPaused`
///        (b) the vault frozen on USDG                 -> USDG leg reverts `AddressFrozen` (recipient)
///        (c) Clear frozen on USDG                     -> USDG leg reverts `AddressFrozen` (sender)
///        (d) Clear's USDG burnt by a supply controller-> USDG leg reverts on balance
///        (e) the vault blocklisted on NVDA, UNASSIGNED week -> NVDA leg reverts (redeem pushes NVDA too)
///      The control is a USDG freeze in an UNASSIGNED week, which closes because the USDG leg is zero
///      and Valorem skips zero transfers (the token alone would still revert a zero-value transfer).
contract AF02_UsdgFreezeRollClose is BaseTest {
    uint256 internal optionId;

    /// @dev Common set-up: alice 20e18, write+list+fill 10, bob deposits 30e18 in Listed and queues it,
    ///      the buyer exercises `assigned` contracts in the window.
    function _setupWeek(uint112 assigned) internal returns (uint256 bobShares) {
        _deposit(alice, 20e18);
        optionId = _rollOpen();
        OrderComponents memory c = _approveListing(optionId, 10, _okUnitPrice());
        _fill(c, 10);

        // Bob deposits during Listed (allowed until cycleExerciseTs) and queues everything.
        bobShares = _deposit(bob, 30e18);
        vm.prank(bob);
        vault.queueRedeem(bobShares);

        _warpToExercise();
        vault.lockBook();
        if (assigned != 0) _exercise(optionId, assigned);
    }

    /// @dev BUG PRESENT: rollClose reverts for the keeper and for anyone, at expiry and 30 days later,
    ///      and no other path releases principal.
    function _assertBricked(uint256 bobShares) internal {
        vm.prank(keeper);
        vm.expectRevert();
        vault.rollClose();

        vm.warp(expiryTs + 30 days);
        vm.expectRevert();
        vault.rollClose();
        vm.prank(keeper);
        vm.expectRevert();
        vault.rollClose();

        // No other exit.
        vm.expectRevert(abi.encodeWithSelector(Vault.WrongPhase.selector, Vault.Phase.Idle, Vault.Phase.Exercisable));
        vault.settleQueue();

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(Vault.UseQueue.selector);
        vault.redeem(aliceShares, alice, alice);

        vm.prank(alice);
        vm.expectRevert(Vault.UseQueue.selector);
        vault.withdraw(1e18, alice, alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Vault.EpochNotSettled.selector, 1, 1));
        vault.completeRedeem(bob);

        assertEq(nvda.balanceOf(bob), 0, "bob got nothing back");
        assertEq(uint8(vault.phase()), uint8(Vault.Phase.Exercisable), "stuck in Exercisable");
        assertEq(vault.queuedShares(), bobShares, "bob's queue never settles");
    }

    /// @dev The assigned-week fixture right after the exercise: 40e18 idle in the vault (10 unwritten
    ///      of alice + bob's 30), 9e18 still locked in Valorem, 231 USDG of strike proceeds in the claim.
    function _assertAssignedWeekState() internal view {
        assertEq(nvda.balanceOf(address(vault)), 40e18, "40 NVDA idle in the vault");
        assertEq(vault.lockedAssets(), 9e18);
        assertEq(vault.claimedExerciseProceeds(), 231_000_000);
    }

    /*//////////////////////////////////////////////////////////////
                              TRIGGERS
    //////////////////////////////////////////////////////////////*/

    /// (a) A global USDG pause after an assignment.
    function test_usdgPause_assignedWeek_bricksRollClose() public {
        uint256 bobShares = _setupWeek(1);
        _assertAssignedWeekState();

        usdg.pause();
        vm.warp(expiryTs + 1 hours);
        _assertBricked(bobShares);
        assertEq(nvda.balanceOf(address(vault)), 40e18, "40 NVDA frozen in the vault");

        // Lifting the pause is the only recovery.
        usdg.unpause();
        vault.rollClose();
        assertEq(uint8(vault.phase()), uint8(Vault.Phase.Idle));
        vm.prank(bob);
        vault.completeRedeem(bob);
        assertGt(nvda.balanceOf(bob), 29e18, "bob paid only after the pause lifted");
    }

    /// (b) Paxos freezes the vault address on USDG after an assignment.
    function test_vaultFrozenOnUsdg_assignedWeek_bricksRollClose() public {
        uint256 bobShares = _setupWeek(1);
        _assertAssignedWeekState();

        usdg.freeze(address(vault));
        vm.warp(expiryTs + 1 hours);
        _assertBricked(bobShares);

        // The Stock Token itself is NOT frozen: the vault simply holds it with no path out.
        assertEq(nvda.balanceOf(address(vault)), 40e18, "40 NVDA frozen in the vault");
        assertEq(nvda.balanceOf(alice), 10e18, "alice holds only what she never deposited");

        usdg.unfreeze(address(vault));
        vault.rollClose();
        assertEq(uint8(vault.phase()), uint8(Vault.Phase.Idle));
        vm.prank(bob);
        vault.completeRedeem(bob);
        assertGt(nvda.balanceOf(bob), 29e18, "bob paid only after USDG unfroze");
    }

    /// (c) Paxos freezes Valorem Clear on USDG: Clear is the SENDER of the redeem's USDG leg, so every
    ///     assigned claim on every market sharing that Clear is stuck, ours included.
    function test_clearFrozenOnUsdg_assignedWeek_bricksRollClose() public {
        uint256 bobShares = _setupWeek(1);
        _assertAssignedWeekState();

        usdg.freeze(address(clear));
        vm.warp(expiryTs + 1 hours);

        // The USDG leg is what reverts.
        vm.prank(keeper);
        vm.expectRevert(MockERC20.AddressFrozen.selector);
        vault.rollClose();
        _assertBricked(bobShares);
    }

    /// (d) A supply controller burns Clear's USDG out from under the claim: no freeze event, no pause,
    ///     and the redeem's USDG leg fails on balance.
    function test_clearUsdgBurntBySupplyController_assignedWeek_bricksRollClose() public {
        uint256 bobShares = _setupWeek(1);
        _assertAssignedWeekState();
        assertEq(usdg.balanceOf(address(clear)), 231_000_000, "the strike sits in Clear");

        usdg.burnFrom(address(clear), 231_000_000);
        assertEq(usdg.balanceOf(address(clear)), 0);

        vm.warp(expiryTs + 1 hours);
        _assertBricked(bobShares);
    }

    /// (e) The issuer blocklists the vault on NVDA in an UNASSIGNED week: redeem pushes the whole
    ///     collateral back as NVDA, the vault cannot receive it, and rollClose reverts. The F-02 text
    ///     names only USDG; the NVDA leg bites in every week that is not fully assigned.
    function test_vaultBlockedOnNvda_unassignedWeek_bricksRollClose() public {
        uint256 bobShares = _setupWeek(0);
        assertEq(vault.lockedAssets(), 10e18, "all 10 still locked, nothing assigned");

        nvda.blockAccount(address(vault));
        vm.warp(expiryTs + 1 hours);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(MockStockToken.AccountBlocked.selector, address(vault)));
        vault.rollClose();
        _assertBricked(bobShares);
    }

    /*//////////////////////////////////////////////////////////////
                               CONTROL
    //////////////////////////////////////////////////////////////*/

    /// Control: the identical USDG freeze in an UNASSIGNED week does not brick rollClose (no USDG push in
    /// redeem because Valorem skips zero transfers; the fee push is already best-effort). The brick is
    /// specific to a non-zero leg the token refuses.
    function test_control_unassignedWeekClosesUnderAVaultUsdgFreeze() public {
        _setupWeek(0);
        usdg.freeze(address(vault));
        vm.warp(expiryTs + 1 hours);
        vault.rollClose();
        assertEq(uint8(vault.phase()), uint8(Vault.Phase.Idle), "unassigned week closes");
        vm.prank(bob);
        (uint256 assets,) = vault.completeRedeem(bob);
        // Bob gets his Stock Token; his USDG leg is 0 (he queued after the fill was indexed).
        assertGt(assets, 29e18);
    }
}
