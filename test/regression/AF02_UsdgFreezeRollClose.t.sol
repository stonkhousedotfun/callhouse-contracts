// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {RealClearBase} from "../helpers/RealClearBase.sol";
import {Vault} from "../../src/Vault.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {IValoremClear} from "../../src/interfaces/IValoremClear.sol";
import {OrderComponents} from "../../src/interfaces/ISeaport.sol";

/// @title AF-02 regression: a redeem revert at `rollClose` strands the claim instead of bricking the vault
/// @notice Ported from the audit PoC `PoC_usdg_freeze_bricks_rollclose_assigned_week.t.sol` (AUDIT-FINDINGS
///         F-02, Medium), widened to the full trigger set found by the integration recon. FIXED FORM (stage
///         C-05): the same attacks run, and the final assertions are inverted. `rollClose` reaches Idle with
///         the claim kept (`isStranded()`), the queue settles from the idle balance at once, deposits and
///         instant redemption stay shut, `rollOpen` refuses `StillStranded`, and the permissionless
///         `retryStrandedClaim()` redeems the claim and pays every epoch that settled while stranded its
///         recorded share, to the base unit, the moment the cause clears.
/// @dev Upstream `redeem` pushes the exercise asset (USDG) first and the underlying (NVDA) second, each
///      only if > 0, in one call (integrations/valorem.md §4.7). Either leg reverting reverts the redeem.
///      The triggers, all instant and none behind a timelock (integrations/usdg.md §3, §7;
///      robinhood-chain.md §3):
///        (a) USDG paused                              -> USDG leg reverts `ContractPaused`
///        (b) the vault frozen on USDG                 -> USDG leg reverts `AddressFrozen` (recipient)
///        (c) Clear frozen on USDG                     -> USDG leg reverts `AddressFrozen` (sender)
///        (d) Clear's USDG burnt by a supply controller-> USDG leg reverts on balance
///        (e) the vault blocklisted on NVDA, UNASSIGNED week -> NVDA leg reverts (redeem pushes NVDA too)
///      The control is a USDG freeze in an UNASSIGNED week, which closes normally because the USDG leg is
///      zero and Valorem skips zero transfers (the token alone would still revert a zero-value transfer).
///
///      THE WORKED WEEK, shared by (a)-(d). alice 20e18; 10 written and sold at $2 (19.00 USDG to the vault,
///      indexed to alice's 20 shares by bob's deposit checkpoint: fee 0.95, net 18.05); bob 30e18 in Listed,
///      queued at once; 1 contract assigned, so 9e18 stays locked and 231 USDG sits in the claim.
///        rollClose (stranded)   idle 40e18, supply 50e18: bob's epoch takes 24e18 of idle and 0.6e18 of
///                               the claim; live shares keep 0.4e18 of it.
///        alice queues 10e18     idle 16e18, supply 20e18: 8e18 of idle and 0.4 x 10/20 = 0.2e18 of the
///        + settleQueue          claim; live shares keep 0.2e18.
///        retryStrandedClaim     redeem returns 9e18 NVDA + 231 USDG. The queue's 0.8e18 (7.2e18 NVDA,
///                               184.80 USDG) goes to the reserves; the live 0.2e18 (1.8e18 NVDA, 46.20
///                               USDG) to NAV and the index, fee-free.
///        bob collects           5.4e18 NVDA + 138.60 USDG (0.6 of the redeem, floors)
///        alice collects         8e18 + 1.8e18 NVDA + 46.20 USDG (0.2, the last share, takes what is left)
///        alice redeems 10e18    9.8e18 NVDA: NAV 40 - 24 + 9 - 8 - 5.4 - 1.8 = 9.8e18 over 10e18 shares
///      Every reserve and the vault's NVDA end at exactly zero.
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

    /// @dev The assigned-week fixture right after the exercise: 40e18 idle in the vault (10 unwritten
    ///      of alice + bob's 30), 9e18 still locked in Valorem, 231 USDG of strike proceeds in the claim.
    function _assertAssignedWeekState() internal view {
        assertEq(nvda.balanceOf(address(vault)), 40e18, "40 NVDA idle in the vault");
        assertEq(vault.lockedAssets(), 9e18);
        assertEq(vault.claimedExerciseProceeds(), 231_000_000);
    }

    /// @dev FIXED: an hour after expiry anyone closes, the close strands the claim and the vault is Idle
    ///      with the claim, the option and the written count all kept.
    function _closeStranded(uint256 expectedGen) internal {
        uint256 key = vault.claimKey();
        uint32 cycle = vault.cycleNumber();
        uint112 written = vault.contractsWritten();
        vm.warp(uint256(vault.cycleExpiryTs()) + 1 hours);

        vm.expectEmit(true, true, false, true, address(vault));
        emit Vault.ClaimStranded(cycle, key, expectedGen);
        vault.rollClose();

        assertEq(uint8(vault.phase()), uint8(Vault.Phase.Idle), "rollClose reaches Idle");
        assertTrue(vault.isStranded(), "the claim is stranded");
        assertEq(vault.claimKey(), key, "the claim is kept");
        assertEq(vault.contractsWritten(), written, "contractsWritten is kept, so the instant path stays shut");
        assertEq(vault.strandGen(), expectedGen, "generation");
        assertEq(vault.lastResolvedGen(), expectedGen - 1, "not resolved yet");
    }

    /// @dev What stranded means for the exits: the queue works, the instant path, deposits and a new
    ///      cycle do not, and the claim cannot be retried while the cause persists.
    function _assertStrandedGates() internal {
        assertFalse(vault.canRedeemInstantly(), "instant redemption is off while stranded");
        assertEq(vault.maxDeposit(carol), 0, "deposits quoted shut while stranded");
        assertEq(vault.maxMint(carol), 0, "mints quoted shut while stranded");
        vm.startPrank(carol);
        nvda.approve(address(vault), 1e18);
        vm.expectRevert(Vault.DepositsClosed.selector);
        vault.deposit(1e18, carol);
        vm.stopPrank();

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(Vault.UseQueue.selector);
        vault.redeem(aliceShares, alice, alice);

        // Whatever type the keeper names, the vault refuses to arm a cycle over the claim.
        uint256 nextOption = optionIds[RUNG_PICK];
        vm.prank(keeper);
        vm.expectRevert(Vault.StillStranded.selector);
        vault.rollOpen(nextOption);

        vm.expectRevert(Vault.StillStranded.selector);
        vault.retryStrandedClaim();
    }

    function _complete(address who) internal returns (uint256 assets, uint256 usdgOut) {
        vm.prank(who);
        (assets, usdgOut) = vault.completeRedeem(who);
    }

    function _strandLeft(uint256 gen) internal view returns (uint256 wadLeft, uint256 assetsLeft, uint256 usdgLeft) {
        (,, wadLeft, assetsLeft, usdgLeft) = vault.strands(gen);
    }

    /// @dev The whole worked week of the contract NatSpec, from a stranded assigned close to an empty
    ///      vault, asserted to the base unit. `clearCause` lifts whatever stopped the redeem.
    function _runAssignedWeekToTheEnd(function() internal clearCause) internal {
        // --- stranded close: the epoch settles from idle and records its share of the claim ---
        assertEq(vault.epochId(), 2, "bob's epoch settled inside the stranded close");
        assertEq(vault.reservedAssets(), 24e18, "bob's idle slice: 30e18 x (40e18 + 1) / (50e18 + 1)");
        assertEq(vault.epochStrandWad(1), 0.6e18, "the epoch owns 30/50 of the claim");
        assertEq(vault.epochStrandGen(1), 1);
        assertEq(vault.strandedRemainingWad(), 0.4e18, "live shares keep 20/50 of the claim");
        assertEq(vault.lockedAssets(), 9e18, "the claim is still read live");
        // NAV counts only the live shares' part of the claim: 16e18 idle net of the reserve + 0.4 x 9e18.
        assertEq(vault.totalAssets(), 16e18 + 3.6e18, "NAV = idle - reserved + locked x remaining share");

        _assertStrandedGates();

        // --- bob is paid his idle slice NOW, before the freeze lifts ---
        (uint256 bobDue, uint256 bobDueUsdg) = vault.previewCompleteRedeem(bob);
        assertEq(bobDue, 24e18, "preview quotes the idle slice only: the claim share is not collectable yet");
        assertEq(bobDueUsdg, 0, "bob queued after the fill was indexed, so no escrow USDG");
        (uint256 bobAssets,) = _complete(bob);
        assertEq(bobAssets, 24e18, "bob paid 24e18 NVDA while stranded");
        assertEq(nvda.balanceOf(bob), 24e18);
        assertEq(vault.owedStrandWad(bob), 0.6e18, "bob's share of the claim is staged against him");
        assertEq(vault.owedStrandGen(bob), 1);
        assertEq(vault.epochStrandWad(1), 0, "the epoch's share was drawn down in full");
        assertEq(vault.reservedAssets(), 0, "the idle reserve is collected");

        // Nothing else to collect for bob: his claim share is owed but not yet redeemable.
        vm.prank(bob);
        vm.expectRevert(Vault.StillStranded.selector);
        vault.completeRedeem(bob);

        // --- alice queues half while stranded and settles flat: idle slice now, claim share later ---
        vm.prank(alice);
        vault.queueRedeem(10e18);
        vm.expectEmit(true, false, false, true, address(vault));
        emit Vault.EpochStrandShare(2, 1, 0.2e18);
        vault.settleQueue();
        assertEq(vault.reservedAssets(), 8e18, "alice's idle slice: 10e18 x (16e18 + 1) / (20e18 + 1)");
        assertEq(vault.epochStrandWad(2), 0.2e18, "0.4 x 10/20 of the claim");
        assertEq(vault.strandedRemainingWad(), 0.2e18);
        assertEq(vault.totalAssets(), 8e18 + 1.8e18, "NAV: 8e18 idle net of reserve + 0.2 x 9e18");
        (uint256 aliceDue, uint256 aliceDueUsdg) = vault.previewCompleteRedeem(alice);
        assertEq(aliceDue, 8e18, "alice's preview excludes the still-stranded share");
        assertEq(aliceDueUsdg, 0);

        // --- the cause clears; anyone retries ---
        clearCause();
        vm.expectEmit(true, false, false, true, address(vault));
        emit Vault.StrandedClaimRecovered(1, 9e18, 231_000_000, 0.8e18);
        vault.retryStrandedClaim();

        assertFalse(vault.isStranded(), "resolved");
        assertEq(vault.claimKey(), 0, "the claim is redeemed");
        assertEq(vault.contractsWritten(), 0, "flat again");
        assertTrue(vault.canRedeemInstantly(), "the instant path reopens");
        assertEq(vault.lastResolvedGen(), 1);
        assertEq(vault.strandedRemainingWad(), 0);
        assertEq(nvda.balanceOf(address(vault)), 16e18 + 9e18, "9e18 of collateral came back");
        assertEq(vault.reservedAssets(), 8e18 + 7.2e18, "the queue's 0.8 of the 9e18 is reserved");
        assertEq(vault.usdgReservedForQueue(), 184_800_000, "the queue's 0.8 of the 231 USDG is reserved");
        (uint256 wadLeft, uint256 assetsLeft, uint256 usdgLeft) = _strandLeft(1);
        assertEq(wadLeft, 0.8e18);
        assertEq(assetsLeft, 7.2e18);
        assertEq(usdgLeft, 184_800_000);
        // Live shares' 0.2 of the USDG went through the harvest fee-free, to alice's 10 remaining shares.
        assertEq(vault.claimableUsdg(alice), 18_050_000 + 46_200_000, "alice: her premium plus 0.2 of the strike");
        // The premium fee is 0.95 whether the stranded close could push it (Clear frozen, Clear burnt: the
        // vault's own USDG was never blocked) or the retry's harvest did (pause, vault frozen). Nothing
        // of the strike is fee'd on either path.
        assertEq(usdg.balanceOf(feeSafe), 950_000, "the premium fee was swept, nothing more");
        assertGt(vault.maxDeposit(carol), 0, "deposits reopen once the claim is redeemed");

        // --- bob collects his share of the redeemed claim ---
        (bobDue, bobDueUsdg) = vault.previewCompleteRedeem(bob);
        assertEq(bobDue, 5.4e18, "0.6 of 9e18");
        assertEq(bobDueUsdg, 138_600_000, "0.6 of 231 USDG");
        vm.expectEmit(true, true, false, true, address(vault));
        emit Vault.StrandShareSettled(bob, 1, 0.6e18, 5.4e18, 138_600_000);
        (bobAssets, bobDueUsdg) = _complete(bob);
        assertEq(bobAssets, 5.4e18, "bob's NVDA from the claim");
        assertEq(bobDueUsdg, 138_600_000, "bob's USDG from the claim");
        assertEq(nvda.balanceOf(bob), 24e18 + 5.4e18, "bob has 29.4e18 in total");
        assertEq(usdg.balanceOf(bob), 138_600_000);
        assertEq(vault.owedStrandWad(bob), 0);
        (wadLeft, assetsLeft, usdgLeft) = _strandLeft(1);
        assertEq(wadLeft, 0.2e18, "alice's share is what is left of the generation");

        // --- alice collects: idle slice plus the LAST share of the claim, which takes what is left ---
        (aliceDue, aliceDueUsdg) = vault.previewCompleteRedeem(alice);
        assertEq(aliceDue, 8e18 + 1.8e18, "preview: idle slice + 0.2 of the claim");
        assertEq(aliceDueUsdg, 46_200_000);
        (uint256 aliceAssets, uint256 aliceUsdg) = _complete(alice);
        assertEq(aliceAssets, aliceDue, "paid what was quoted");
        assertEq(aliceUsdg, aliceDueUsdg);
        (wadLeft, assetsLeft, usdgLeft) = _strandLeft(1);
        assertEq(wadLeft, 0, "the generation is drained");
        assertEq(assetsLeft, 0, "to the base unit");
        assertEq(usdgLeft, 0, "on both legs");
        assertEq(vault.reservedAssets(), 0, "no asset reserve left");
        assertEq(vault.usdgReservedForQueue(), 0, "no USDG reserve left");

        // --- alice redeems her remaining 10 shares instantly and claims her USDG ---
        assertEq(vault.totalAssets(), 9.8e18, "NAV: 40 - 24 + 9 - 8 - 5.4 - 1.8");
        vm.prank(alice);
        uint256 out = vault.redeem(10e18, alice, alice);
        assertEq(out, 9.8e18, "alice's live shares are worth 0.2 x 9e18 more than before the retry");
        vm.prank(alice);
        vault.claimUsdg();
        assertEq(usdg.balanceOf(alice), 46_200_000 + 18_050_000 + 46_200_000);

        assertEq(nvda.balanceOf(address(vault)), 0, "the vault is empty of NVDA");
        assertEq(usdg.balanceOf(address(vault)), 0, "and of USDG");
        assertEq(
            nvda.balanceOf(alice) + nvda.balanceOf(bob) + nvda.balanceOf(buyer), 60e18, "50 deposited + buyer's 10"
        );
        assertEq(vault.totalSupply(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                              TRIGGERS
    //////////////////////////////////////////////////////////////*/

    function _unpauseUsdg() internal {
        usdg.unpause();
    }

    function _unfreezeVault() internal {
        usdg.unfreeze(address(vault));
    }

    function _unfreezeClear() internal {
        usdg.unfreeze(address(clear));
    }

    /// @dev Burnt USDG does not come back on its own: only the supply controller re-minting Clear's
    ///      balance (the live `increaseSupplyToAddress`) makes the redeem possible again.
    function _refundClear() internal {
        usdg.mint(address(clear), 231_000_000);
    }

    /// (a) A global USDG pause after an assignment: the close strands; the pause lifting is the recovery.
    function test_usdgPause_assignedWeek_strandsThenRecovers() public {
        _setupWeek(1);
        _assertAssignedWeekState();
        usdg.pause();
        _closeStranded(1);
        _runAssignedWeekToTheEnd(_unpauseUsdg);
    }

    /// (b) Paxos freezes the vault address on USDG after an assignment.
    function test_vaultFrozenOnUsdg_assignedWeek_strandsThenRecovers() public {
        _setupWeek(1);
        _assertAssignedWeekState();
        usdg.freeze(address(vault));
        _closeStranded(1);
        // The Stock Token itself is NOT frozen, and that is exactly what the stranded state uses.
        assertEq(nvda.balanceOf(address(vault)), 40e18);
        _runAssignedWeekToTheEnd(_unfreezeVault);
    }

    /// (c) Paxos freezes Valorem Clear on USDG: Clear is the SENDER of the redeem's USDG leg, so every
    ///     assigned claim on every market sharing that Clear is stuck, ours included.
    function test_clearFrozenOnUsdg_assignedWeek_strandsThenRecovers() public {
        _setupWeek(1);
        _assertAssignedWeekState();
        usdg.freeze(address(clear));
        _closeStranded(1);
        _runAssignedWeekToTheEnd(_unfreezeClear);
    }

    /// (d) A supply controller burns Clear's USDG out from under the claim: no freeze event, no pause,
    ///     and the redeem's USDG leg fails on balance. The claim strands until the balance is restored.
    function test_clearUsdgBurntBySupplyController_assignedWeek_strandsUntilRefunded() public {
        _setupWeek(1);
        _assertAssignedWeekState();
        assertEq(usdg.balanceOf(address(clear)), 231_000_000, "the strike sits in Clear");
        usdg.burnFrom(address(clear), 231_000_000);
        assertEq(usdg.balanceOf(address(clear)), 0);
        _closeStranded(1);
        _runAssignedWeekToTheEnd(_refundClear);
    }

    /// (e) The issuer blocklists the vault on NVDA in an UNASSIGNED week: redeem pushes the whole
    ///     collateral back as NVDA, the vault cannot receive it, and the close strands. The F-02 text
    ///     names only USDG; the NVDA leg bites in every week that is not fully assigned. While the
    ///     vault is blocked nobody can be paid NVDA at all (the Stock Token is the thing that is
    ///     frozen), so the queue's idle slice waits with the claim share and both pay on unblock.
    function test_vaultBlockedOnNvda_unassignedWeek_strandsThenRecovers() public {
        uint256 bobShares = _setupWeek(0);
        assertEq(vault.lockedAssets(), 10e18, "all 10 still locked, nothing assigned");
        nvda.blockAccount(address(vault));
        _closeStranded(1);

        assertEq(vault.reservedAssets(), 24e18, "bob's idle slice reserved");
        assertEq(vault.epochStrandWad(1), 0.6e18, "and 30/50 of the claim");
        assertEq(vault.queuedShares(), 0, "bob's queue settled");
        assertEq(vault.queuedSharesOf(bob), bobShares, "bob's entry is settled but uncollected");
        assertEq(vault.totalAssets(), 16e18 + 4e18, "NAV: idle net of reserve + 0.4 x 10e18");

        // The Stock Token leg is the one thing a Stock Token blocklist is allowed to stop.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MockStockToken.AccountBlocked.selector, address(vault)));
        vault.completeRedeem(bob);
        vm.expectRevert(Vault.StillStranded.selector);
        vault.retryStrandedClaim();

        nvda.unblockAccount(address(vault));
        vm.expectEmit(true, false, false, true, address(vault));
        emit Vault.StrandedClaimRecovered(1, 10e18, 0, 0.6e18);
        vault.retryStrandedClaim();
        assertEq(nvda.balanceOf(address(vault)), 50e18, "all 10e18 came back");
        assertEq(vault.reservedAssets(), 24e18 + 6e18, "the queue's 0.6 of the 10e18 is reserved");
        assertEq(vault.usdgReservedForQueue(), 0, "no USDG leg on an unassigned week");

        (uint256 due,) = vault.previewCompleteRedeem(bob);
        assertEq(due, 30e18, "bob is quoted his whole 30e18: idle slice plus the claim share");
        (uint256 got,) = _complete(bob);
        assertEq(got, 30e18, "bob gets exactly what he put in");
        assertEq(vault.reservedAssets(), 0);
        (uint256 wadLeft, uint256 assetsLeft,) = _strandLeft(1);
        assertEq(wadLeft, 0);
        assertEq(assetsLeft, 0);
        assertEq(vault.totalAssets(), 20e18, "alice's 20e18 untouched");
        assertTrue(vault.canRedeemInstantly());
    }

    /*//////////////////////////////////////////////////////////////
                               CONTROL
    //////////////////////////////////////////////////////////////*/

    /// Control: the identical USDG freeze in an UNASSIGNED week closes normally (no USDG push in redeem
    /// because Valorem skips zero transfers; the fee push is already best-effort). Nothing strands.
    function test_control_unassignedWeekClosesUnderAVaultUsdgFreeze() public {
        _setupWeek(0);
        usdg.freeze(address(vault));
        vm.warp(expiryTs + 1 hours);
        vault.rollClose();
        assertEq(uint8(vault.phase()), uint8(Vault.Phase.Idle), "unassigned week closes");
        assertFalse(vault.isStranded(), "nothing stranded");
        assertEq(vault.claimKey(), 0, "the claim was redeemed");
        assertEq(vault.strandGen(), 0, "no generation was opened");
        assertEq(vault.epochStrandWad(1), 0, "the epoch owns no claim share");
        assertTrue(vault.canRedeemInstantly());
        vm.expectRevert(Vault.NotStranded.selector);
        vault.retryStrandedClaim();
        (uint256 assets,) = _complete(bob);
        // Bob gets his Stock Token; his USDG leg is 0 (he queued after the fill was indexed).
        assertGt(assets, 29e18);
    }

    /*//////////////////////////////////////////////////////////////
                          GAS STARVATION
    //////////////////////////////////////////////////////////////*/

    /// A caller who starves `rollClose` of gas must not be able to strand a claim that would redeem: the
    /// inner call's out-of-gas is told apart from a refusal by the gas left afterwards and reverts
    /// `RedeemOutOfGas`. Walked up from far too little gas to enough, the call either reverts leaving
    /// Exercisable with the claim untouched, or succeeds having redeemed it. It never lands in between.
    function test_gasStarvedRollCloseNeverStrands() public {
        _setupWeek(1);
        _assertAssignedWeekState();
        vm.warp(expiryTs + 1 hours);

        bool succeeded;
        uint256 attempts;
        for (uint256 g = 60_000; g <= 2_000_000; g += 2_500) {
            attempts++;
            vm.prank(keeper);
            (bool ok,) = address(vault).call{gas: g}(abi.encodeCall(Vault.rollClose, ()));
            if (ok) {
                succeeded = true;
                assertEq(vault.claimKey(), 0, "a call that succeeded redeemed the claim");
                assertFalse(vault.isStranded(), "a gas-starved call stranded a redeemable claim");
                break;
            }
            assertEq(uint8(vault.phase()), uint8(Vault.Phase.Exercisable), "a failed call changed nothing");
            assertTrue(vault.claimKey() != 0, "a failed call kept the claim");
            assertEq(vault.strandGen(), 0, "a failed call opened no generation");
        }
        assertTrue(succeeded, "rollClose eventually went through with enough gas");
        assertGt(attempts, 1, "at least one starved attempt was refused");
        assertEq(nvda.balanceOf(address(vault)), 49e18, "9e18 back on the successful close");
    }

    /*//////////////////////////////////////////////////////////////
                         A SECOND GENERATION
    //////////////////////////////////////////////////////////////*/

    /// A claim strands, is resolved, a NEW cycle runs and strands again, all while bob has never
    /// collected his first-generation entry. Generations resolve in order, bob's first-generation share
    /// is folded from the resolved generation the moment he collects, and the second generation pays
    /// its own epoch from its own redeem. Both generations drain to zero.
    function test_restrandInALaterGenerationWithAnUncollectedEarlierGenOwner() public {
        _setupWeek(1);
        usdg.pause();
        _closeStranded(1);
        assertEq(vault.epochStrandWad(1), 0.6e18, "bob's epoch (gen 1)");

        // Gen 1 resolves. Bob does not collect.
        usdg.unpause();
        vault.retryStrandedClaim();
        assertEq(vault.lastResolvedGen(), 1);
        (uint256 wadLeft1, uint256 assetsLeft1, uint256 usdgLeft1) = _strandLeft(1);
        assertEq(wadLeft1, 0.6e18, "bob's share is still in the generation");
        assertEq(assetsLeft1, 5.4e18);
        assertEq(usdgLeft1, 138_600_000);
        assertEq(vault.reservedAssets(), 24e18 + 5.4e18, "bob's idle slice and claim share are both reserved");

        // A new week: carol deposits, 10 written and sold, carol queues, 2 assigned, USDG paused at the close.
        exerciseTs = uint40(block.timestamp + 6 days);
        expiryTs = uint40(block.timestamp + 7 days);
        _installCycle();
        feed.setAnswer(SPOT_FEED);
        uint256 carolShares = _deposit(carol, 30e18);
        uint256 supply = vault.totalSupply();
        optionId = _rollOpen();
        OrderComponents memory c = _approveListing(optionId, 10, _okUnitPrice());
        _fill(c, 10);
        vm.prank(carol);
        vault.queueRedeem(carolShares);
        _warpToExercise();
        vault.lockBook();
        _exercise(optionId, 2);
        usdg.pause();
        uint256 carolEpoch = vault.epochId();
        _closeStranded(2);

        // Carol's epoch is generation 2 and takes carol/supply of the second claim.
        uint256 carolWad = (1e18 * carolShares) / supply;
        assertEq(vault.epochStrandWad(carolEpoch), carolWad, "carol's epoch owns its share of the second claim");
        assertEq(vault.epochStrandGen(carolEpoch), 2);
        assertEq(vault.strandedRemainingWad(), 1e18 - carolWad);
        assertEq(vault.lockedAssets(), 8e18, "8e18 locked behind the second claim");

        // Bob collects DURING the second stranding: his gen-1 entry settles, his gen-1 share is folded
        // from the resolved generation, his NVDA is paid, and his USDG is deferred by the pause.
        (uint256 bobDue, uint256 bobDueUsdg) = vault.previewCompleteRedeem(bob);
        assertEq(bobDue, 24e18 + 5.4e18, "idle slice + 0.6 of the first claim");
        assertEq(bobDueUsdg, 138_600_000);
        vm.expectEmit(true, true, false, true, address(vault));
        emit Vault.UsdgLegDeferred(bob, bob, 138_600_000);
        (uint256 bobAssets, uint256 bobUsdg) = _complete(bob);
        assertEq(bobAssets, 24e18 + 5.4e18, "bob's NVDA, both parts, paid while gen 2 is stranded");
        assertEq(bobUsdg, 0, "USDG deferred by the pause");
        assertEq(vault.owedQueueUsdg(bob), 138_600_000, "and still owed");
        (wadLeft1, assetsLeft1, usdgLeft1) = _strandLeft(1);
        assertEq(wadLeft1, 0, "generation 1 is drained");
        assertEq(assetsLeft1, 0);
        assertEq(usdgLeft1, 0);

        // Gen 2 resolves; carol collects her idle slice and her share of the second claim; bob his USDG.
        usdg.unpause();
        uint256 balBefore = nvda.balanceOf(address(vault));
        vault.retryStrandedClaim();
        assertEq(vault.lastResolvedGen(), 2);
        assertEq(nvda.balanceOf(address(vault)) - balBefore, 8e18, "8e18 came back");
        (uint256 wadLeft2, uint256 assetsLeft2, uint256 usdgLeft2) = _strandLeft(2);
        assertEq(wadLeft2, carolWad);
        assertEq(assetsLeft2, (8e18 * carolWad) / 1e18);
        assertEq(usdgLeft2, (462_000_000 * carolWad) / 1e18);

        (uint256 carolDue, uint256 carolDueUsdg) = vault.previewCompleteRedeem(carol);
        (uint256 carolAssets, uint256 carolUsdg) = _complete(carol);
        assertEq(carolAssets, carolDue, "carol paid what was quoted");
        assertEq(carolUsdg, carolDueUsdg);
        (wadLeft2, assetsLeft2, usdgLeft2) = _strandLeft(2);
        assertEq(wadLeft2, 0, "generation 2 is drained");
        assertEq(assetsLeft2, 0);
        assertEq(usdgLeft2, 0);

        (uint256 bobAssets2, uint256 bobUsdg2) = _complete(bob);
        assertEq(bobAssets2, 0);
        assertEq(bobUsdg2, 138_600_000, "bob's deferred USDG arrives once the pause lifts");

        assertEq(vault.reservedAssets(), 0, "no asset reserve left after both generations");
        assertEq(vault.usdgReservedForQueue(), 0, "no USDG reserve left after both generations");
        assertTrue(vault.canRedeemInstantly(), "flat again");
        assertEq(vault.owedStrandWad(bob), 0);
        assertEq(vault.owedStrandWad(carol), 0);
    }

    /// A holder who re-queues while holding an uncollected stranded-claim entry keeps the share: the
    /// flush stages it (no tokens move), and it is paid when the owner finally collects.
    function test_reQueuingWhileStrandedStagesTheClaimShareWithoutPayingIt() public {
        _setupWeek(1);
        usdg.pause();
        _closeStranded(1);

        // Alice queues half now; bob re-queues nothing (he has no shares), so use alice for the flush:
        // alice's first entry settles flat while stranded, then she queues again before collecting.
        vm.prank(alice);
        vault.queueRedeem(10e18);
        vault.settleQueue();
        assertEq(vault.epochStrandWad(2), 0.2e18);

        vm.prank(alice);
        vault.queueRedeem(5e18); // flushes the settled epoch-2 entry into owed balances
        assertEq(vault.owedAssets(alice), 8e18, "idle slice staged");
        assertEq(vault.owedStrandWad(alice), 0.2e18, "claim share staged, not paid");
        assertEq(vault.owedStrandGen(alice), 1);
        assertEq(vault.epochStrandWad(2), 0, "the epoch's share was drawn down");
        assertEq(nvda.balanceOf(alice), 10e18, "nothing was paid by the flush");

        // She collects the staged idle slice now; the share waits for the claim.
        (uint256 got,) = _complete(alice);
        assertEq(got, 8e18);
        assertEq(vault.owedStrandWad(alice), 0.2e18, "the stranded share survives the collection");

        // Her new entry settles into epoch 3, another 0.2e18 x 5/10 of the claim, same generation.
        vault.settleQueue();
        assertEq(vault.epochStrandWad(3), 0.1e18);

        usdg.unpause();
        vault.retryStrandedClaim();

        // One collection settles the epoch-3 entry, adds its share to the staged one (same generation)
        // and folds 0.3e18 of the redeem: alice and bob between them take every base unit.
        (uint256 due, uint256 dueUsdg) = vault.previewCompleteRedeem(alice);
        (uint256 assets, uint256 usdgOut) = _complete(alice);
        assertEq(assets, due, "preview == payout across a staged plus a settled share");
        assertEq(usdgOut, dueUsdg);
        assertEq(usdgOut, (231_000_000 * 0.3e18) / 1e18, "0.3 of the strike USDG");
        _complete(bob);
        (uint256 wadLeft, uint256 assetsLeft, uint256 usdgLeft) = _strandLeft(1);
        assertEq(wadLeft, 0);
        assertEq(assetsLeft, 0);
        assertEq(usdgLeft, 0);
        assertEq(vault.reservedAssets(), 0);
        assertEq(vault.usdgReservedForQueue(), 0);
    }
}

/// @notice The same suite against the REAL Valorem Clear bytecode (6436c82): the redeem's two pushes,
///         their order and their revert behaviour are Valorem's, not the mock's, and the gas-starvation
///         bound has to hold against the real `redeem` cost.
contract AF02_UsdgFreezeRollClose_RealClear is AF02_UsdgFreezeRollClose, RealClearBase {
    function _deployClear() internal override returns (IValoremClear) {
        return _deployRealClear();
    }
}
