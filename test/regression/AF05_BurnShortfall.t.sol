// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {Vault} from "../../src/Vault.sol";

/// @title AF-05 regression: an `adminBurn` shortfall closes deposits and is shared pro rata by the reserve
/// @notice Ported from the audit PoC `PoC_adminburn_shortfall_hidden_by_saturating_nav.t.sol`
///         (AUDIT-FINDINGS F-05, Low). FIXED FORM (stage C-04, decisions D6 and D8): `totalAssets =
///         max(balance + locked - reserved, 0)`, one `_depositRefused()` predicate closes deposits
///         (`DepositsClosed`, `maxDeposit == 0`) whenever `balanceOf(vault) < reservedAssets`, and every
///         uncollected reserved claimant takes the same `balance / reservedAssets` fraction of what is
///         booked to them. A depositor who arrives after the burn loses nothing to it.
/// @dev The live Stock Token's `adminBurn(from, amount)` is a BARE `_burn` (ADMIN_BURNER_ROLE, one EOA)
///      with no pause and no blocklist modifier; {MockStockToken.adminBurn} mirrors it.
contract AF05_BurnShortfall is BaseTest {
    address internal dave = makeAddr("dave");

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        vault.setDepositCap(1_000e18);

        _fund(alice, 20e18, 0);
        _fund(bob, 20e18, 0);
        _fund(carol, 20e18, 0);
        _fund(dave, 100e18, 0);
    }

    function _queue(address who, uint256 shares) internal {
        vm.prank(who);
        vault.queueRedeem(shares);
    }

    function _complete(address who) internal returns (uint256 assets) {
        vm.prank(who);
        (assets,) = vault.completeRedeem(who);
    }

    function _assertDepositsClosed(address who, string memory why) internal {
        assertEq(vault.maxDeposit(who), 0, string.concat(why, ": maxDeposit must quote zero"));
        assertEq(vault.maxMint(who), 0, string.concat(why, ": maxMint must quote zero"));
        vm.startPrank(who);
        nvda.approve(address(vault), 1e18);
        vm.expectRevert(Vault.DepositsClosed.selector);
        vault.deposit(1e18, who);
        vm.expectRevert(Vault.DepositsClosed.selector);
        vault.mint(1e18, who);
        vm.stopPrank();
    }

    /// Idle: a burn below `reservedAssets` closes deposits, the two reserved claimants share the balance
    /// pro rata, and the depositor who arrives afterwards gets exactly what he put in back.
    function test_idle_adminBurnShortfallIsSharedByTheReserveAndClosesDeposits() public {
        _deposit(alice, 50e18);
        _deposit(bob, 50e18);
        _deposit(carol, 50e18);

        _queue(alice, 50e18);
        vault.settleQueue();
        _queue(bob, 25e18);
        vault.settleQueue();

        assertEq(vault.reservedAssets(), 75e18, "reserved");
        assertEq(nvda.balanceOf(address(vault)), 150e18, "balance");
        assertEq(vault.totalSupply(), 75e18, "supply: bob 25 + carol 50");

        // Issuer seizure of 100 NVDA from the vault.
        nvda.adminBurn(address(vault), 100e18);
        assertEq(nvda.balanceOf(address(vault)), 50e18);
        assertLt(nvda.balanceOf(address(vault)), vault.reservedAssets(), "balance < reserved: the reserve is unbacked");

        // FIXED: NAV is honestly zero (50 + 0 - 75 < 0) and deposits are shut, not quoted at the cap.
        assertEq(vault.totalAssets(), 0, "NAV reads zero");
        _assertDepositsClosed(dave, "unbacked reserve");
        assertTrue(vault.canRedeemInstantly(), "the instant path is open, but a share is worth nothing");
        vm.prank(carol);
        vm.expectRevert(Vault.ZeroAssets.selector);
        vault.redeem(50e18, carol, carol);

        // Both reserved claimants take the same 50/75 fraction, whichever order they collect in.
        (uint256 aliceDue,) = vault.previewCompleteRedeem(alice);
        (uint256 bobDue,) = vault.previewCompleteRedeem(bob);
        uint256 balance = nvda.balanceOf(address(vault)); // 50e18 over a 75e18 reserve
        assertEq(aliceDue, (50e18 * balance) / 75e18, "alice quoted two thirds");
        assertEq(bobDue, (25e18 * balance) / 75e18, "bob quoted two thirds");

        vm.expectEmit(true, false, false, true, address(vault));
        emit Vault.ReserveHaircut(alice, 50e18, aliceDue);
        assertEq(_complete(alice), aliceDue, "alice paid the quoted haircut");
        // The fraction survives alice's collection (16.67e18 of the 25e18 booked); the last claimant
        // takes exactly what is left, so floor rounding never strands a base unit in the reserve.
        (uint256 bobDueAfter,) = vault.previewCompleteRedeem(bob);
        assertApproxEqAbs(bobDueAfter, bobDue, 1, "bob's fraction is unchanged by alice collecting first");
        assertEq(bobDueAfter, 50e18 - aliceDue, "bob, last, is quoted exactly what is left");
        assertEq(_complete(bob), bobDueAfter, "bob paid the quote");
        assertEq(vault.reservedAssets(), 0, "reserve fully collected");
        assertEq(nvda.balanceOf(address(vault)), 0, "the whole balance went to the reserve, no dust");

        // Deposits reopen once the reserve is collected, priced on the honest NAV of zero.
        assertEq(vault.maxDeposit(dave), 1_000e18, "deposits reopen");
        uint256 daveShares = _deposit(dave, 100e18);

        // dave exits instantly and has lost nothing to a burn that happened before he arrived.
        vm.prank(dave);
        uint256 daveOut = vault.redeem(daveShares, dave, dave);
        assertApproxEqAbs(daveOut, 100e18, 2, "dave recovers his full deposit");

        // carol's shares are worth nothing: her backing was what the issuer burnt.
        assertEq(vault.convertToAssets(vault.balanceOf(carol)), 0, "carol's shares are worth zero");
    }

    /// Listed: NAV counts the locked collateral and subtracts the whole reserve, deposits shut while the
    /// balance is below the reserve, and a claimant who collects during the shortfall takes the haircut.
    function test_listed_shortfallIsHonestlyPricedAndClosesDeposits() public {
        _deposit(alice, 50e18);
        _deposit(bob, 50e18);

        _queue(alice, 50e18);
        vault.settleQueue();
        assertEq(vault.reservedAssets(), 50e18);

        _rollOpen(47);
        assertEq(vault.lockedAssets(), 47e18);
        assertEq(nvda.balanceOf(address(vault)), 53e18);

        nvda.adminBurn(address(vault), 20e18); // balance 33 < reserved 50
        // FIXED: NAV reads the true 30 (33 + 47 - 50), not 47.
        assertEq(vault.totalAssets(), 33e18 + 47e18 - 50e18, "NAV reads the true 30e18");
        _assertDepositsClosed(dave, "Listed with an unbacked reserve");

        // alice collects during the shortfall: 50 booked, 33/50 of it paid. The reserve is a claim on
        // the idle balance, so the burn lands on it first; bob's shares keep the 47e18 locked.
        (uint256 aliceDue,) = vault.previewCompleteRedeem(alice);
        assertEq(aliceDue, 33e18, "haircut quoted");
        assertEq(_complete(alice), 33e18, "haircut paid");
        assertEq(vault.reservedAssets(), 0);
        assertEq(nvda.balanceOf(address(vault)), 0);

        // Deposits reopen on the honest book: 47e18 locked, nothing idle, nothing reserved.
        assertEq(vault.totalAssets(), 47e18, "NAV is the locked collateral");
        assertGt(vault.maxDeposit(dave), 0, "deposits reopen");
        uint256 daveShares = _deposit(dave, 47e18);

        // Run the cycle to expiry OTM and close.
        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();
        _rollClose();

        // dave gets back what he put in; the burn was borne before he arrived.
        vm.prank(dave);
        uint256 daveOut = vault.redeem(daveShares, dave, dave);
        assertApproxEqAbs(daveOut, 47e18, 2, "dave's 47 is still worth 47");
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(bob)), 47e18, 2, "bob keeps the locked 47");
    }

    /// Listed, nobody collects: the returning collateral refills the balance above the reserve, deposits
    /// reopen without anyone being haircut, and the reserved claimant is then paid in full. The loss
    /// stays with the live shares, whose NAV read it honestly the whole time.
    function test_listed_returningCollateralRefillsTheReserveAndReopensDeposits() public {
        _deposit(alice, 50e18);
        _deposit(bob, 50e18);
        _queue(alice, 50e18);
        vault.settleQueue();
        _rollOpen(47);

        nvda.adminBurn(address(vault), 20e18); // balance 33 < reserved 50
        _assertDepositsClosed(dave, "before the collateral returns");
        assertEq(vault.totalAssets(), 30e18, "true NAV during the shortfall");

        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();
        _rollClose();

        // 47e18 came back: balance 80 >= reserved 50. No haircut, deposits open, NAV unchanged at 30.
        assertEq(nvda.balanceOf(address(vault)), 80e18);
        assertEq(vault.totalAssets(), 30e18, "NAV did not move on the close");
        assertGt(vault.maxDeposit(dave), 0, "deposits reopen once the reserve is backed again");
        (uint256 aliceDue,) = vault.previewCompleteRedeem(alice);
        assertEq(aliceDue, 50e18, "alice quoted in full");
        assertEq(_complete(alice), 50e18, "alice paid in full");
        assertEq(vault.convertToAssets(vault.balanceOf(bob)), 30e18, "bob's 50 shares are worth the true 30");

        // A depositor now buys in at the honest price and loses nothing.
        uint256 daveShares = _deposit(dave, 30e18);
        vm.prank(dave);
        assertApproxEqAbs(vault.redeem(daveShares, dave, dave), 30e18, 2, "dave gets his 30 back");
    }

    /// The haircut is order-independent: three reserved claimants collecting in either order all take
    /// the same fraction, and the reserve drains to exactly the balance.
    function testFuzz_haircutFractionIsTheSameForEveryClaimant(uint256 burnSeed, bool bobFirst) public {
        _deposit(alice, 50e18);
        _deposit(bob, 50e18);
        _deposit(carol, 50e18);
        _queue(alice, 50e18);
        _queue(bob, 30e18);
        _queue(carol, 10e18);
        vault.settleQueue();
        assertEq(vault.reservedAssets(), 90e18);

        uint256 burn = bound(burnSeed, 60e18 + 1, 150e18); // leaves the balance below the 90e18 reserve
        nvda.adminBurn(address(vault), burn);
        uint256 bal = 150e18 - burn;
        assertLt(bal, 90e18);
        assertEq(vault.maxDeposit(dave), 0, "deposits shut");

        (uint256 aliceDue,) = vault.previewCompleteRedeem(alice);
        (uint256 bobDue,) = vault.previewCompleteRedeem(bob);
        (uint256 carolDue,) = vault.previewCompleteRedeem(carol);
        assertEq(aliceDue, (50e18 * bal) / 90e18);
        assertEq(bobDue, (30e18 * bal) / 90e18);
        assertEq(carolDue, (10e18 * bal) / 90e18);

        // Each payout is quoted the instant before it is made (that is exact) and compared with the
        // quote taken before anyone collected: the fraction moves by at most one base unit of floor
        // rounding per earlier collection, whichever order people arrive in.
        if (bobFirst) {
            assertEq(_complete(bob), bobDue, "bob first");
            assertApproxEqAbs(_complete(carol), carolDue, 1, "carol second");
            assertApproxEqAbs(_complete(alice), aliceDue, 2, "alice last");
        } else {
            assertEq(_complete(alice), aliceDue, "alice first");
            assertApproxEqAbs(_complete(bob), bobDue, 1, "bob second");
            assertApproxEqAbs(_complete(carol), carolDue, 2, "carol last");
        }
        assertEq(vault.reservedAssets(), 0, "reserve drained");
        // The last claimant's booked amount IS the remaining reserve, so the haircut pays exactly the
        // remaining balance: no base unit is stranded.
        assertEq(nvda.balanceOf(address(vault)), 0, "the reserve drained to exactly the balance");
        assertEq(vault.maxDeposit(dave), 1_000e18, "deposits reopen at NAV zero");
    }
}
