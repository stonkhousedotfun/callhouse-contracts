// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {Vault} from "../../src/Vault.sol";
import {ValoremLib} from "../../src/lib/ValoremLib.sol";
import {OrderComponents} from "../../src/interfaces/ISeaport.sol";
import {Distributor} from "../../src/Distributor.sol";

/// @notice Regression tests for the findings of the 2026-09-12 adversarial security audit.
/// @dev Each test here corresponds to a finding that was CONFIRMED with a working exploit. They
///      exist to fail loudly if a future change reopens one of these holes, so do not weaken an
///      assertion here to make an unrelated change pass.
contract VaultSecurityTest is BaseTest {
    /*//////////////////////////////////////////////////////////////
        CRITICAL — the assignment NAV-crash deposit
        Reported independently by four audit surfaces:
        access-control-01, phase-reentrancy-01, share-accounting-01, economic-mev-1.
    //////////////////////////////////////////////////////////////*/

    /// @dev THE ATTACK, and why it worked.
    ///
    ///      Assignment happens entirely inside Valorem. A buyer calls `exercise`, takes the
    ///      collateral, and leaves the strike USDG sitting in the claim. There is no callback
    ///      into the vault. `lockedAssets()` reads that claim live, so `totalAssets()` COLLAPSES
    ///      inside the exerciser's own transaction, while the offsetting strike proceeds stay
    ///      invisible until `rollClose` redeems the claim hours later.
    ///
    ///      `lockBook()` is permissionless and nobody is obliged to call it, and `rollClose`
    ///      accepts phase Listed, so the vault can legitimately sit in Listed for the whole
    ///      24-hour exercise window. That left anyone free to exercise, watch the share price
    ///      crash in the same block, mint shares against the crashed NAV, and then collect a
    ///      pro-rata slice of the strike proceeds at `rollClose` — taken straight out of the
    ///      pockets of the depositors whose collateral was actually assigned. The attacker's
    ///      principal round-trips untouched, so the extraction is riskless.
    ///
    ///      The fix closes deposits on the CYCLE'S TIMESTAMP rather than on the phase enum, so
    ///      the window shuts whether or not anybody calls `lockBook` and whether or not the
    ///      keeper is alive.
    function test_critical_cannotDepositAfterAssignmentCrashesNav() public {
        _deposit(alice, 20e18);

        uint256 optionId = _rollOpen(19);
        OrderComponents memory c = _approveListing(optionId, 19, _okUnitPrice());
        _fill(c, 19);

        uint256 navBefore = vault.totalAssets();
        assertEq(navBefore, 20e18, "NAV is whole while the call is live");

        // The buyer exercises the moment the window opens. The vault is still in Listed.
        _warpToExercise();
        _exercise(optionId, 19);

        assertEq(uint8(vault.phase()), 1, "still Listed: nobody called lockBook");
        assertEq(vault.totalAssets(), 1e18, "NAV collapsed in the exerciser's own transaction");
        assertEq(vault.contractsAssigned(), 19, "every contract was assigned");

        // The attack is minting against that crashed NAV. It must be impossible.
        assertEq(vault.maxDeposit(bob), 0, "the quote refuses too, so the UI cannot offer it");
        assertEq(vault.maxMint(bob), 0);

        vm.startPrank(bob);
        nvda.approve(address(vault), 19e18);
        vm.expectRevert(abi.encodeWithSelector(Vault.DepositsClosedForCycle.selector, exerciseTs));
        vault.deposit(19e18, bob);
        vm.stopPrank();

        // The honest depositor keeps the entire assignment.
        _warpToExpiry();
        _rollClose();
        assertEq(vault.totalSupply(), 20e18, "no attacker shares were ever minted");
        assertGt(vault.claimableUsdg(alice), 0, "and the strike proceeds are all hers");
    }

    /// @dev The window closes on the timestamp, not on `lockBook`, so a dead keeper cannot
    ///      reopen it. This is the whole point of the fix.
    function test_critical_windowClosesEvenIfNobodyEverCallsLockBook() public {
        _deposit(alice, 20e18);
        uint256 optionId = _rollOpen(10);
        OrderComponents memory c = _approveListing(optionId, 10, _okUnitPrice());
        _fill(c, 10);

        // One second before the window opens, a deposit is still legitimate.
        vm.warp(uint256(exerciseTs) - 1);
        assertGt(vault.maxDeposit(bob), 0, "deposits are open right up to the deadline");
        _deposit(bob, 1e18);

        // One second later, with nothing else changed and no assignment yet, it is shut.
        vm.warp(exerciseTs);
        assertEq(uint8(vault.phase()), 1, "still Listed");
        assertEq(vault.contractsAssigned(), 0, "nothing assigned yet; the clock alone closes it");
        assertEq(vault.maxDeposit(carol), 0);

        vm.startPrank(carol);
        nvda.approve(address(vault), 1e18);
        vm.expectRevert(abi.encodeWithSelector(Vault.DepositsClosedForCycle.selector, exerciseTs));
        vault.deposit(1e18, carol);
        vm.stopPrank();
    }

    /// @dev Closing the deposit window must not trap anyone. Every exit stays open.
    function test_critical_closedWindowStillLetsEveryoneOut() public {
        _deposit(alice, 20e18);
        uint256 optionId = _rollOpen(10);
        OrderComponents memory c = _approveListing(optionId, 10, _okUnitPrice());
        _fill(c, 10);

        _warpToExercise();
        _exercise(optionId, 4);

        // Deposits are shut...
        assertEq(vault.maxDeposit(bob), 0);

        // ...but queueing, claiming and closing all still work.
        vm.prank(alice);
        vault.queueRedeem(5e18);
        assertEq(vault.queuedSharesOf(alice), 5e18, "a depositor can always start leaving");

        vault.lockBook();
        _warpToExpiry();
        _rollClose();

        vm.prank(alice);
        (uint256 assets,) = vault.completeRedeem(alice);
        assertGt(assets, 0, "and can always finish leaving");

        vm.prank(alice);
        vault.claimUsdg();
    }

    /*//////////////////////////////////////////////////////////////
        HIGH — an unbounded cycle tenor freezing the collateral
        valorem-adapter-3 / access-control-02.
    //////////////////////////////////////////////////////////////*/

    /// @dev The Overcall registry is owned by a single third-party EOA, and its `setCycle` bounds
    ///      the expiry only from BELOW (`exerciseAt + MIN_EXERCISE_WINDOW`). Nothing stops it
    ///      setting an expiry years out, by malice or by fat finger. The vault snapshots that
    ///      expiry, and `rollClose` then refuses to run until it passes — so up to 95% of
    ///      depositor collateral would sit locked in Valorem for the whole tenor with no
    ///      redemption path for anyone. A skipped week is strictly better than that.
    function test_high_refusesAnAbsurdlyLongCycleBeforeAnyCollateralMoves() public {
        _deposit(alice, 20e18);

        uint40 farExercise = uint40(block.timestamp + 1 days);
        uint40 farExpiry = uint40(block.timestamp + 3650 days);

        uint256[] memory ids = new uint256[](1);
        uint96[] memory ks = new uint96[](1);
        ids[0] = clear.newOptionType(address(nvda), 1e18, address(usdg), 231_000_000, farExercise, farExpiry);
        ks[0] = 231_000_000;
        registry.setCycleWithStrikes(ids, ks, farExercise, farExpiry);

        assertTrue(registry.isWritingOpen(), "the registry is perfectly happy with this cycle");

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Vault.BadCycleWindow.selector, farExercise, farExpiry));
        vault.rollOpen(ids[0], 10);

        // Nothing moved: the check runs before the write.
        assertEq(uint8(vault.phase()), 0, "still Idle");
        assertEq(vault.totalAssets(), 20e18, "collateral untouched");
        assertTrue(vault.canRedeemInstantly(), "and everyone can still leave");
    }

    /// @dev A normal weekly cycle is unaffected by the bound.
    function test_high_normalWeeklyCycleStillWrites() public {
        _deposit(alice, 20e18);
        _rollOpen(10);
        assertEq(uint8(vault.phase()), 1, "a 7-day cycle is nowhere near the 21-day ceiling");
    }

    /// @dev The vault must not depend on the registry having validated the option it writes. The
    ///      whole deposit gate rests on "assignment cannot happen before `cycleExerciseTs`", and
    ///      that only holds if the option actually written shares that timestamp.
    function test_high_refusesAnOptionWhoseWindowDiffersFromTheCycle() public {
        _deposit(alice, 20e18);

        // An option whose exercise time is a day earlier than the cycle claims.
        uint40 rogueExercise = exerciseTs - 1 days;
        uint256 rogue = clear.newOptionType(address(nvda), 1e18, address(usdg), 231_000_000, rogueExercise, expiryTs);

        uint256[] memory ids = new uint256[](2);
        uint96[] memory ks = new uint96[](2);
        ids[0] = optionIds[RUNG_PICK];
        ks[0] = strikes[RUNG_PICK];
        ids[1] = rogue;
        ks[1] = 231_000_001;
        registry.setCycleWithStrikes(ids, ks, exerciseTs, expiryTs);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ValoremLib.OptionWindowMismatch.selector, rogueExercise, expiryTs));
        vault.rollOpen(rogue, 10);
    }

    /*//////////////////////////////////////////////////////////////
        MEDIUM — a blocked fee recipient must not freeze the vault
        usdg-distribution-02 / token-integration-1 / economic-mev-5.
    //////////////////////////////////////////////////////////////*/

    /// @dev `rollClose` is the ONLY function that redeems the claim, clears `contractsWritten`
    ///      and settles the redeem queue. An earlier draft pushed the protocol fee inside it with
    ///      a hard transfer, so a blocklisted fee Safe, a paused USDG, or a recipient that
    ///      reverts on receive would revert `rollClose` — freezing every unit of collateral,
    ///      stranding the queue and blocking every future cycle, over a fee that harms only us.
    ///      The push is now best-effort and {Vault.sweepFee} is the recovery path.
    function test_medium_blockedFeeRecipientDoesNotFreezeTheVault() public {
        _deposit(alice, 20e18);
        uint256 optionId = _rollOpen(10);
        OrderComponents memory c = _approveListing(optionId, 10, _okUnitPrice());
        _fill(c, 10);

        // The stablecoin issuer blocklists our fee Safe.
        usdg.freeze(feeSafe);

        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();

        // The week still closes.
        _rollClose();
        assertEq(uint8(vault.phase()), 0, "the vault returned to Idle");
        assertEq(vault.contractsWritten(), 0, "the claim was redeemed");
        assertEq(usdg.balanceOf(feeSafe), 0, "the fee could not be paid");
        // 5% of the 19_000_000 premium = 950_000; alice, the only holder, nets 18_050_000.
        assertEq(vault.pendingFeeUsdg(), 950_000, "and is held, not lost");

        // Depositors are entirely unaffected.
        assertEq(vault.claimableUsdg(alice), 18_050_000, "their share is untouched");
        vm.prank(alice);
        vault.claimUsdg();
        assertTrue(vault.canRedeemInstantly());
        vm.prank(alice);
        vault.redeem(20e18, alice, alice);
        assertEq(nvda.balanceOf(alice), 30e18, "all collateral back");

        // Sweeping while still blocked is a no-op that reverts rather than losing the fee.
        vm.expectRevert(Distributor.NothingToClaim.selector);
        vault.sweepFee();
        assertEq(vault.pendingFeeUsdg(), 950_000, "still held");

        // Once the block lifts, anyone can push it through. It always goes to the stored
        // recipient, never to the caller.
        usdg.unfreeze(feeSafe);
        vm.prank(carol);
        uint256 paid = vault.sweepFee();
        assertEq(paid, 950_000);
        assertEq(usdg.balanceOf(feeSafe), 950_000, "paid to the fee Safe, not to carol");
        assertEq(usdg.balanceOf(carol), 0);
        assertEq(vault.pendingFeeUsdg(), 0);
    }

    /*//////////////////////////////////////////////////////////////
        MEDIUM — the Valorem fee escape hatch has to actually work
        valorem-adapter-1.
    //////////////////////////////////////////////////////////////*/

    /// @dev Valorem's engine fee is 15 bps of notional charged ON TOP of the collateral, so the
    ///      write pulls collateral + fee. Approving only the collateral made every `rollOpen`
    ///      revert on allowance once the switch flipped — which meant `acceptValoremFee` was
    ///      still non-functional even after the flag was wired through to the adapter. With no
    ///      upgradeability, that would have ended the product's ability to write, permanently.
    function test_medium_acceptedValoremFeeActuallyLetsTheVaultWrite() public {
        _deposit(alice, 20e18);
        mockClear.setFeesEnabled(true);

        uint256 optionId = optionIds[RUNG_PICK];

        // Refused until governance accepts, which is the intended gate.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Vault.ValoremFeeNotAccepted.selector, uint8(15)));
        vault.rollOpen(optionId, 10);

        vm.prank(admin);
        vault.acceptValoremFee(true);

        // And now it genuinely writes, paying the 15 bps on top of the collateral.
        uint256 before = nvda.balanceOf(address(vault));
        vm.prank(keeper);
        vault.rollOpen(optionId, 10);

        assertEq(uint8(vault.phase()), 1, "written");
        assertEq(vault.contractsWritten(), 10);
        // 10 lots of collateral plus 15 bps of that notional.
        uint256 expectedFee = (10e18 * 15) / 10_000;
        assertEq(before - nvda.balanceOf(address(vault)), 10e18 + expectedFee, "collateral + engine fee left");
        assertEq(vault.lockedAssets(), 10e18, "only the collateral is locked behind the claim");

        // No standing allowance is left behind for the clearinghouse.
        assertEq(nvda.allowance(address(vault), address(clear)), 0, "allowance scrubbed");
    }
}
