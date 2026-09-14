// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";

/// @title AF-05 regression: the saturating NAV hides an `adminBurn` shortfall and later depositors fund it
/// @notice Ported from the audit PoC `PoC_adminburn_shortfall_hidden_by_saturating_nav.t.sol`
///         (AUDIT-FINDINGS F-05, Low). BUG-PRESENT FORM: after the issuer burns more than the free idle
///         balance while epochs are uncollected, NAV clamps to 0 (Idle) or is overstated by the shortfall
///         (Listed), deposits stay open, and new money pays old settled claims first come, first served.
///         Stage C-04 inverts this: `totalAssets = max(balance + locked - reserved, 0)`, and one
///         `_depositRefused()` predicate closes deposits (`DepositsClosed`, `maxDeposit == 0`) whenever
///         `balanceOf(vault) < reservedAssets`, with a pro-rata haircut on the shortfall.
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

    /// Idle: a burn below `reservedAssets` clamps NAV to 0, deposits stay open, and a new depositor funds
    /// a settled claimant's payout.
    function test_idle_adminBurnShortfallIsTakenFromANewDepositor() public {
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
        assertLt(nvda.balanceOf(address(vault)), vault.reservedAssets(), "invariant broken: balance < reserved");

        // BUG PRESENT: NAV silently clamps to zero and deposits are still quoted at the full cap.
        assertEq(vault.totalAssets(), 0, "NAV silently clamps to zero");
        assertEq(vault.maxDeposit(dave), 1_000e18, "deposits still quoted at full cap");

        // alice is paid in full, first come first served.
        assertEq(_complete(alice), 50e18, "alice paid in full");

        // bob cannot be paid from what is left.
        vm.prank(bob);
        vm.expectRevert();
        vault.completeRedeem(bob);

        // dave arrives and deposits at NAV 0.
        uint256 daveShares = _deposit(dave, 100e18);

        // bob now collects his 25 out of dave's principal.
        assertEq(_complete(bob), 25e18, "bob paid from dave's deposit");

        // dave exits instantly (the vault is Idle with nothing written) and has lost 25.
        vm.prank(dave);
        uint256 daveOut = vault.redeem(daveShares, dave, dave);
        assertApproxEqAbs(daveOut, 75e18, 1, "dave recovers only 75");
        assertGe(100e18 - daveOut, 25e18 - 1, "25 NVDA of the seizure moved onto a post-burn depositor");

        // Pro-rata reference: 150 of claims (alice 50, bob 25 reserved + 25 shares, carol 50) lost 100,
        // so every claim should keep 1/3. Instead the reserved legs got 100%, carol and bob's free
        // shares got 0, and dave, who was not even present at the burn, lost 25.
        assertEq(vault.convertToAssets(vault.balanceOf(carol)), 0, "carol wiped");
    }

    /// Listed: the free part clamps to 0 while locked collateral is added in full, so NAV overstates by
    /// the shortfall and a depositor buys in above true value.
    function test_listed_shortfallOverstatesNav() public {
        _deposit(alice, 50e18);
        _deposit(bob, 50e18);

        _queue(alice, 50e18);
        vault.settleQueue();
        assertEq(vault.reservedAssets(), 50e18);

        _rollOpen(47);
        assertEq(vault.lockedAssets(), 47e18);
        assertEq(nvda.balanceOf(address(vault)), 53e18);

        nvda.adminBurn(address(vault), 20e18); // balance 33 < reserved 50
        uint256 trueNav = 33e18 + 47e18 - 50e18; // 30
        // BUG PRESENT: NAV reads 47 against a true 30.
        assertEq(vault.totalAssets(), 47e18, "NAV reads 47 against a true 30");
        assertEq(trueNav, 30e18);

        uint256 daveShares = _deposit(dave, 47e18);
        // alice is still paid in full out of dave's deposit.
        assertEq(_complete(alice), 50e18, "alice paid in full (uses dave's tokens)");

        // Run the cycle to expiry OTM and close.
        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();
        _rollClose();

        vm.prank(dave);
        uint256 daveOut = vault.redeem(daveShares, dave, dave);
        assertApproxEqAbs(daveOut, 38.5e18, 1e16, "dave's 47 is worth ~38.5");
        assertGt(47e18 - daveOut, 8e18, "~8.5 NVDA of the seizure moved onto a post-burn depositor");
    }
}
