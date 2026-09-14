// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {Policy, PolicyParams} from "../../src/Policy.sol";

/// @title AF-04 regression: the Valorem fee can no longer come out of `reservedAssets`
/// @notice Ported from the audit PoC `FeePoc.t.sol` (AUDIT-FINDINGS F-04, Low). FIXED FORM (stage C-03,
///         decision D7): `Policy.MAX_UTILIZATION_CEIL_BPS = 9_985`, so governance cannot set 100%
///         utilisation, and at the ceiling a maximum-size write with the engine fee on still leaves the
///         15 bps inside the free balance. ACCOUNTING §7 invariant 6 (`balanceOf(vault) >= reservedAssets`)
///         holds through the write and the settled redeemer is paid.
/// @dev The second line of defence, `ReserveBreached` when `asset.balanceOf(vault) < reservedAssets`
///      after a write, lives in the write-on-fill path (stage C-06A) and is tested there with the
///      ceiling bypassed in the harness.
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

    /// At the ceiling, the write that used to eat the reserve is refused by size, and the largest legal
    /// write leaves the fee inside the free balance.
    function test_feeStaysInsideTheFreeBalanceAtTheCeiling() public {
        _setupHalfReservedWithFeeOn();

        // FIXED: sizing is against totalAssets() = 10e18 free at 99.85%, which admits 9 contracts, not 10.
        uint256 pick = optionIds[RUNG_PICK];
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Policy.ContractsAboveUtilization.selector, uint256(10), uint256(9)));
        vault.rollOpen(pick, 10);

        vm.prank(keeper);
        vault.rollOpen(pick, 9);

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

    /// The bound in the Policy NatSpec, checked numerically over the whole free-balance range: n lots at
    /// 99.85% utilisation cost at most n × 1e18 × 1.0015 (fee floored, minimum one base unit), which is
    /// strictly less than the free balance for every free balance of at least one lot.
    function testFuzz_ceilingLeavesRoomForTheFee(uint256 free) public pure {
        free = bound(free, 1e18, 1_000_000e18);
        uint256 n = (free * 9_985) / 10_000 / 1e18;
        if (n == 0) return;
        uint256 collateral = n * 1e18;
        uint256 fee = (collateral * 15) / 10_000;
        if (fee == 0) fee = 1;
        assertLt(collateral + fee, free, "collateral plus the 15 bps fee must fit inside the free balance");
    }
}
