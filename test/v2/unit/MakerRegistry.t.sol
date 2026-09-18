// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {MakerTestBase} from "./MakerBase.t.sol";
import {IMakerRegistry} from "../../../src/v2/interfaces/IMakerRegistry.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {MakerRegistry} from "../../../src/v2/mm/MakerRegistry.sol";

/// @notice MakerRegistry (C2-11): admin tiers, bounds and events, and the integration proof that a tier changes the
///         rebate the REAL OrderBook actually pays in USDG.
/// @dev Every take below buys 200 units at 2.00 across two 100-unit write asks: premium 4.00, taker fee
///      min(0.10, 0.40) = 0.10 USDG, split pro rata 0.05 / 0.05; seller fee 5 % = 0.10 per maker.
contract MakerRegistryTest is MakerTestBase {
    uint256 internal constant SHARE = 50_000; // each maker's half of the 0.10 USDG taker fee
    uint256 internal constant NET_PREMIUM = 2_000_000 - 100_000; // 2.00 premium less the 5 % primary fee

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_setTier_adminOnlyBoundedAndLogged() public {
        vm.expectEmit(address(registry));
        emit IMakerRegistry.TierSet(alice, 7_500);
        vm.prank(admin);
        registry.setTier(alice, 7_500);
        assertEq(registry.rebateBps(alice), 7_500);
        assertEq(registry.rebateBps(bob), 0, "unset = book default");

        vm.startPrank(admin);
        registry.setTier(alice, 10_000);
        assertEq(registry.rebateBps(alice), 10_000, "the whole share is allowed");
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        registry.setTier(alice, 10_001);
        registry.setTier(alice, 0);
        assertEq(registry.rebateBps(alice), 0, "back to the default");
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        registry.setTier(stranger, 10_000);
        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        registry.grantRole(V2Constants.DEFAULT_ADMIN_ROLE, stranger);
    }

    function test_constructor_rejectsZeroAdmin() public {
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        new MakerRegistry(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                     INTEGRATION WITH THE REAL BOOK
    //////////////////////////////////////////////////////////////*/

    /// @dev Places alice's and bob's asks, carol takes both; returns the two makers' USDG gains, the treasury's gain and
    ///      the two OrderFilled rebates.
    function _round()
        internal
        returns (uint256 aliceGain, uint256 bobGain, uint256 feeGain, uint256[2] memory rebates)
    {
        uint256 aliceAsk = _place(alice, callId, WRITE, P2_00, 100);
        uint256 bobAsk = _place(bob, callId, WRITE, P2_00, 100);
        (uint256 a0, uint256 b0, uint256 t0) = (usdg.balanceOf(alice), usdg.balanceOf(bob), usdg.balanceOf(treasury));
        vm.recordLogs();
        _take(carol, _buy(callId, _ids(aliceAsk, bobAsk), 200, P2_00, carol));
        Vm.Log[] memory fills = _filledLogs(vm.getRecordedLogs());
        assertEq(fills.length, 2, "two fills");
        assertEq(_makerOf(fills[0]), alice);
        assertEq(_makerOf(fills[1]), bob);
        rebates = [_rebateOf(fills[0]), _rebateOf(fills[1])];
        aliceGain = usdg.balanceOf(alice) - a0;
        bobGain = usdg.balanceOf(bob) - b0;
        feeGain = usdg.balanceOf(treasury) - t0;
    }

    function test_tiersChangeTheRebateTheBookPays() public {
        (uint256 aliceGain, uint256 bobGain, uint256 feeGain, uint256[2] memory rebates) = _round();
        assertEq(rebates[0], SHARE / 2, "default: 50 % of alice's share");
        assertEq(rebates[1], SHARE / 2, "default: 50 % of bob's share");
        assertEq(aliceGain, NET_PREMIUM + 25_000);
        assertEq(bobGain, NET_PREMIUM + 25_000);
        assertEq(feeGain, 200_000 + 100_000 - 50_000, "seller fees + taker fee - rebates");

        vm.prank(admin);
        registry.setTier(alice, 10_000);
        (aliceGain, bobGain, feeGain, rebates) = _round();
        assertEq(rebates[0], SHARE, "alice tier 100 %");
        assertEq(rebates[1], SHARE / 2, "bob untouched");
        assertEq(aliceGain, NET_PREMIUM + 50_000, "alice is paid the larger rebate in USDG");
        assertEq(bobGain, NET_PREMIUM + 25_000);
        assertEq(feeGain, 300_000 - 75_000, "the protocol keeps less");

        vm.prank(admin);
        registry.setTier(alice, 2_000);
        (aliceGain,, feeGain, rebates) = _round();
        assertEq(rebates[0], 10_000, "alice tier 20 %");
        assertEq(aliceGain, NET_PREMIUM + 10_000);
        assertEq(feeGain, 300_000 - 35_000);

        vm.prank(admin);
        registry.setTier(alice, 0);
        (aliceGain,,, rebates) = _round();
        assertEq(rebates[0], SHARE / 2, "tier 0 = book default again");
        assertEq(aliceGain, NET_PREMIUM + 25_000);
    }

    function test_bookWithoutRegistryPaysTheDefault() public {
        vm.startPrank(admin);
        registry.setTier(alice, 10_000);
        book.setMakerRegistry(IMakerRegistry(address(0)));
        vm.stopPrank();
        (uint256 aliceGain,,, uint256[2] memory rebates) = _round();
        assertEq(rebates[0], SHARE / 2, "registry unset: tier ignored");
        assertEq(aliceGain, NET_PREMIUM + 25_000);
    }

    function test_vaultTierIsPaidToTheVault() public {
        vm.prank(admin);
        registry.setTier(address(vault), 10_000);
        _vaultLedger(address(nvda), 1e18);
        uint256 id = _vaultPlace(callId, WRITE, P2_00, 100);
        vm.recordLogs();
        _take(alice, _buy(callId, _ids(id), 100, P2_00, alice));
        Vm.Log[] memory fills = _filledLogs(vm.getRecordedLogs());
        assertEq(_rebateOf(fills[0]), 100_000, "the vault's tier returns the whole taker fee");
        assertEq(usdg.balanceOf(address(vault)), VAULT_USDG + 2_000_000 - 100_000 + 100_000);
    }
}
