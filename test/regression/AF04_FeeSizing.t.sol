// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {Policy, PolicyParams} from "../../src/Policy.sol";
import {ValoremLib} from "../../src/lib/ValoremLib.sol";
import {SeaportOrderLib} from "../../src/lib/SeaportOrderLib.sol";
import {OrderComponents} from "../../src/interfaces/ISeaport.sol";

/// @title AF-04 regression: the Valorem fee can no longer come out of `reservedAssets`
/// @notice Ported from the audit PoC `FeePoc.t.sol` (AUDIT-FINDINGS F-04, Low). FIXED FORM (stage C-03,
///         decision D7, and the write-on-fill fill gate): `Policy.MAX_UTILIZATION_CEIL_BPS = 9_985`, so
///         governance cannot set 100% utilisation, and at the ceiling a maximum-size write with the
///         engine fee on still leaves the 15 bps inside the free balance. ACCOUNTING §7 invariant 6
///         (`balanceOf(vault) >= reservedAssets`) holds through the write and the settled redeemer is
///         paid. The second line of defence, `ReserveBreached` after the write, is reached here with
///         the mock clearinghouse's fee rate pushed far past the 15 bps the ceiling was sized for.
contract AF04_FeeSizing is BaseTest {
    /// @dev alice and bob deposit 10e18 each; bob queues and settles, so 10e18 is reserved to him and
    ///      10e18 is free. Valorem's fee is switched on and accepted.
    function _setupHalfReservedWithFeeOn() internal returns (PolicyParams memory p) {
        _deposit(alice, 10e18);
        _deposit(bob, 10e18);

        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        vault.queueRedeem(bobShares);
        vault.settleQueue();
        assertEq(vault.reservedAssets(), 10e18, "10e18 reserved to bob");

        (uint16 minOtm, uint16 maxOtm, uint16 minPremium,, uint16 feeBps, uint64 maxContracts) = vault.policy();
        p = PolicyParams(minOtm, maxOtm, minPremium, 9_985, feeBps, maxContracts);
        vm.startPrank(admin);
        vault.setPolicy(p);
        vault.acceptValoremFee(true);
        vm.stopPrank();
        mockClear.setFeesEnabled(true);
    }

    /// The PoC's first step no longer works: 100% utilisation is above the compiled ceiling.
    function test_governanceCannotSetFullUtilisation() public {
        (uint16 minOtm, uint16 maxOtm, uint16 minPremium,, uint16 feeBps, uint64 maxContracts) = vault.policy();
        PolicyParams memory p = PolicyParams(minOtm, maxOtm, minPremium, 10_000, feeBps, maxContracts);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Policy.UtilizationAboveCeiling.selector, uint16(10_000), uint16(9_985)));
        vault.setPolicy(p);

        // 9,985 itself is legal: the ceiling is inclusive.
        p.maxUtilizationBps = 9_985;
        vm.prank(admin);
        vault.setPolicy(p);
        (,,, uint16 util,,) = vault.policy();
        assertEq(util, 9_985, "the ceiling itself is accepted");
    }

    /// At the ceiling, the listing that used to eat the reserve is refused by capacity, and the
    /// largest legal fill leaves the fee inside the free balance.
    function test_feeStaysInsideTheFreeBalanceAtTheCeiling() public {
        _setupHalfReservedWithFeeOn();

        // FIXED: sizing is against totalAssets() = 10e18 free at 99.85%, which admits 9 contracts, not 10.
        uint256 pick = _rollOpen();
        OrderComponents memory ten = _buildOrder(pick, 10, _okUnitPrice());
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SeaportOrderLib.OfferExceedsCapacity.selector, uint256(10), uint256(9)));
        vault.approveListing(ten);

        OrderComponents memory nine = _approveListing(pick, 9, _okUnitPrice());
        _fill(nine, 9);

        // Valorem pulled 9e18 + 15 bps = 9.0135e18. The 10e18 reserved to bob is untouched.
        uint256 bal = nvda.balanceOf(address(vault));
        assertEq(bal, 20e18 - 9e18 - 0.0135e18, "collateral + 15 bps fee left the vault");
        assertGe(bal, vault.reservedAssets(), "ACCOUNTING invariant 6 holds: balance >= reservedAssets");
        assertEq(vault.lockedAssets(), 9e18, "nine lots locked");

        // bob's settled payout is honoured in full, mid-cycle, without a haircut.
        (uint256 due,) = vault.previewCompleteRedeem(bob);
        assertEq(due, 10e18, "no haircut: the reserve is fully backed");
        vm.prank(bob);
        (uint256 paid,) = vault.completeRedeem(bob);
        assertEq(paid, 10e18, "bob paid in full");
        assertEq(nvda.balanceOf(bob), 30e18);
    }

    /// The second line of defence. The ceiling leaves 15 bps of slack; a fee rate the ceiling was not
    /// sized for (255 bps, the mock's maximum) on a book whose utilisation floors almost nothing
    /// away would pull collateral + fee past the free balance and into the reserve. The fill gate
    /// measures the balance after the write and reverts the whole fill, so the reserve is never
    /// touched and nothing is written.
    ///
    ///      ARITHMETIC, BY HAND. alice 50.075e18, bob 10e18 queued and settled -> reserved 10e18,
    ///      balance 60.075e18, NAV 50.075e18. At 99.85% that admits floor(49.999) = 49 contracts...
    ///      so the cap of 50 is not reached; 49 x 1e18 x 1.0255 = 50.2495e18 > 50.075e18 free.
    ///      Balance after the pull would be 60.075 - 50.2495 = 9.8255e18 < 10e18 reserved.
    function test_reserveBreachIsCaughtAfterTheWrite() public {
        vm.prank(admin);
        vault.setDepositCap(100e18);
        _fund(alice, 30e18, 0);
        _deposit(alice, 50.075e18);
        _deposit(bob, 10e18);
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        vault.queueRedeem(bobShares);
        vault.settleQueue();
        assertEq(vault.reservedAssets(), 10e18);
        assertEq(vault.totalAssets(), 50.075e18);

        (uint16 minOtm, uint16 maxOtm, uint16 minPremium,, uint16 feeBps, uint64 maxContracts) = vault.policy();
        vm.startPrank(admin);
        vault.setPolicy(PolicyParams(minOtm, maxOtm, minPremium, 9_985, feeBps, maxContracts));
        vault.acceptValoremFee(true);
        vm.stopPrank();
        mockClear.setFeeBps(255);
        mockClear.setFeesEnabled(true);

        uint256 pick = _rollOpen();
        // 49 contracts clear the size gate; the price clears the floor including the fee at spot
        // (49 x 880_000 + 1.24950e18 x 220e6 / 1e18 = 43_120_000 + 274_890_000 = 318_010_000).
        OrderComponents memory c = _approveListing(pick, 49, 7_000_000);
        uint256 collateral = 49e18;
        uint256 fee = (collateral * 255) / 10_000;
        uint256 balanceAfterPull = 60.075e18 - collateral - fee;
        assertLt(balanceAfterPull, 10e18, "the pull would eat into the reserve");

        vm.startPrank(buyer);
        usdg.approve(address(seaport), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(ValoremLib.ReserveBreached.selector, balanceAfterPull, uint256(10e18)));
        mockSeaport.fulfil(c, 49);
        vm.stopPrank();

        assertEq(vault.contractsWritten(), 0, "nothing written");
        assertEq(nvda.balanceOf(address(vault)), 60.075e18, "nothing moved");
        vm.prank(bob);
        (uint256 paid,) = vault.completeRedeem(bob);
        assertEq(paid, 10e18, "bob's reserve is intact");
    }

    /// The bound in the Policy NatSpec, checked numerically over the whole free-balance range: n lots at
    /// 99.85% utilisation cost at most n × 1e18 × 1.0015 (fee floored, minimum one base unit), which is
    /// strictly less than the free balance for every free balance of at least one lot.
    function testFuzz_ceilingLeavesRoomForTheFee(uint256 free) public pure {
        free = bound(free, 1e18, 1_000_000e18);
        uint256 n = (free * 9_985) / 10_000 / 1e18;
        // T-OP-046: a free balance under one lot at 99.85 % (free < 1e18 * 10_000 / 9_985) is outside the property
        // ("for every free balance of at least one lot"); rejecting it counts as a rejection, a return counted as a pass.
        vm.assume(n != 0);
        uint256 collateral = n * 1e18;
        uint256 fee = (collateral * 15) / 10_000;
        if (fee == 0) fee = 1;
        assertLt(collateral + fee, free, "collateral plus the 15 bps fee must fit inside the free balance");
    }
}
