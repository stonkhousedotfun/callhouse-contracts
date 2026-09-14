// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {PolicyParams} from "../../src/Policy.sol";

/// @title AF-04 regression: the Valorem fee is not counted in write sizing and comes out of `reservedAssets`
/// @notice Ported from the audit PoC `FeePoc.t.sol` (AUDIT-FINDINGS F-04, Low). BUG-PRESENT FORM: at 100%
///         utilisation with the engine fee on, the write pulls collateral + 15 bps from the raw balance,
///         reserved tokens included, and a settled redeemer can no longer be paid. Stage C-03 inverts
///         this: `MAX_UTILIZATION_CEIL_BPS = 9_985` refuses the policy, and the write-on-fill path
///         reverts `ReserveBreached` if `asset.balanceOf(vault) < reservedAssets` after any write.
/// @dev Needs a non-default policy (utilisation 100%, allowed by `Policy.validate` today) plus Valorem's
///      fee switch and the vault's `acceptValoremFee`. ACCOUNTING §7 invariant 6
///      (`balanceOf(vault) >= reservedAssets`) is what breaks.
contract AF04_FeeSizing is BaseTest {
    function test_feeEatsTheReserveAtFullUtilisation() public {
        _deposit(alice, 10e18);
        _deposit(bob, 10e18);

        // bob queues and settles: 10e18 is now reserved for him, 10e18 is free.
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        vault.queueRedeem(bobShares);
        vault.settleQueue();
        assertEq(vault.reservedAssets(), 10e18, "10e18 reserved to bob");

        // Governance sets utilisation to 100% and accepts the fee; Valorem switches its fee on.
        (uint16 minOtm, uint16 maxOtm, uint16 minPremium,, uint16 feeBps, uint64 maxContracts) = vault.policy();
        PolicyParams memory p = PolicyParams(minOtm, maxOtm, minPremium, 10_000, feeBps, maxContracts);
        vm.startPrank(admin);
        vault.setPolicy(p);
        vault.acceptValoremFee(true);
        vm.stopPrank();
        mockClear.setFeesEnabled(true);

        // BUG PRESENT: sizing is against totalAssets() = 10e18 free, so 10 contracts pass, and Valorem
        // pulls 10e18 + 0.015e18. The 15 bps came out of bob's reserve.
        vm.prank(keeper);
        vault.rollOpen(optionIds[RUNG_PICK], 10);

        uint256 bal = nvda.balanceOf(address(vault));
        emit log_named_uint("vault balance after write", bal);
        emit log_named_uint("reservedAssets", vault.reservedAssets());
        assertEq(bal, 9.985e18, "collateral + 15 bps fee left the vault");
        assertLt(bal, vault.reservedAssets(), "ACCOUNTING invariant 6 broken: balance < reservedAssets");

        // bob's settled payout can no longer be honoured from what is left.
        vm.prank(bob);
        vm.expectRevert();
        vault.completeRedeem(bob);
    }
}
