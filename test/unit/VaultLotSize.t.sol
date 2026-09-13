// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {ValoremLib} from "../../src/lib/ValoremLib.sol";

/// @notice REGRESSION (2026-09-13 finding): the vault prices everything per one token, so it must
///         refuse a cycle whose lot is anything else.
/// @dev THE BUG. `rollOpen` checked the OTM band, the premium floor and utilisation against the
///      compiled `Policy.LOT = 1e18`, but wrote whatever `lotSize` the registry reported. The
///      registry owner (a single third-party EOA) may change `lotSize` between cycles
///      (OvercallRegistry `setLotSize` only refuses while a cycle is live), and `setCycle` accepts
///      any ladder whose `underlyingAmount` equals the new lot. With an unrescaled ladder at lot
///      2e18, a strike of 227 USDG per contract is 113.50 per token against 220 spot, yet the band
///      saw 3.2% out of the money: the proof of concept wrote 23 contracts, a buyer filled at the
///      premium floor, exercised, and took ~$4,879 out of an $11,000 book. Any lot above ~1.03e18
///      passed the band with an in-the-money strike; a lot above 1/0.95 with cap sizing also locked
///      assets already reserved for settled redeemers.
///      THE FIX. `ValoremLib.write` reverts `UnexpectedLotSize(1e18, lotSize)` unless the cycle's
///      lot is exactly 1e18. A lot change now costs a skipped week, which is the worst case
///      SECURITY.md claims for the registry owner.
contract VaultLotSizeTest is BaseTest {
    /// @dev Mirrors the real registry's constraints: `setLotSize` only once the recorded cycle has
    ///      expired, then a fresh ladder with `underlyingAmount == lot` and `setCycle`.
    function _installLotCycle(uint96 lot) internal returns (uint256[] memory ids) {
        vm.warp(expiryTs);
        assertFalse(registry.isCycleLive(), "the real registry refuses setLotSize while a cycle is live");
        registry.setLotSize(lot);

        exerciseTs = uint40(block.timestamp + 6 days);
        expiryTs = uint40(block.timestamp + 7 days);

        uint96[5] memory s = [uint96(227_000_000), 231_000_000, 236_000_000, 241_000_000, 246_000_000];
        ids = new uint256[](5);
        uint96[] memory st = new uint96[](5);
        for (uint256 i; i < 5; i++) {
            ids[i] = clear.newOptionType(address(nvda), lot, address(usdg), s[i], exerciseTs, expiryTs);
            st[i] = s[i];
        }
        registry.setCycleWithStrikes(ids, st, exerciseTs, expiryTs);
        feed.setAnswer(SPOT_FEED);
    }

    function _assertRefused(uint96 lot, uint112 n) internal {
        uint256[] memory ids = _installLotCycle(lot);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ValoremLib.UnexpectedLotSize.selector, uint96(1e18), lot));
        vault.rollOpen(ids[0], n);
        assertEq(vault.contractsWritten(), 0, "nothing written");
        assertEq(vault.lockedAssets(), 0, "no collateral locked");
        assertEq(_phase(), 0, "still Idle: a skipped week, nothing worse");
    }

    /// The proof-of-concept case: lot 2e18, keeper sizing floor(idle * 95% / lot) = 23.
    function test_lot2x_isRefused() public {
        _deposit(alice, 30e18);
        _deposit(bob, 20e18);
        _assertRefused(2e18, 23);
    }

    /// Just above one token, where the in-the-money strike still passes a per-token band.
    function test_lot108_isRefused() public {
        _deposit(alice, 30e18);
        _deposit(bob, 20e18);
        _assertRefused(1.08e18, 43);
    }

    /// A lot below one token is refused too: the band would be wrong the other way.
    function test_lotBelowOneToken_isRefused() public {
        _deposit(alice, 30e18);
        _deposit(bob, 20e18);
        _assertRefused(0.5e18, 40); // inside utilisation (47), so the lot check is what refuses it
    }

    /// Cap sizing with lot 1.1e18 would have written into assets reserved for a settled redeemer;
    /// now the write is refused and the redeemer collects.
    function test_lot110_reservedAssetsStayCollectable() public {
        _deposit(alice, 30e18);
        _deposit(bob, 20e18);
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        vault.queueRedeem(bobShares);
        _fullCycleOtm(10, _okUnitPrice());
        assertEq(vault.reservedAssets(), 20e18, "bob's 20 NVDA reserved");

        _assertRefused(1.1e18, 28);

        vm.prank(bob);
        (uint256 assets,) = vault.completeRedeem(bob);
        assertEq(assets, 20e18, "the reserve was never touched");
    }

    /// Back at exactly one token, writing works again.
    function test_lotBackToOneToken_writes() public {
        _deposit(alice, 30e18);
        uint256[] memory ids = _installLotCycle(1e18);
        vm.prank(keeper);
        vault.rollOpen(ids[0], 10);
        assertEq(vault.contractsWritten(), 10);
        assertEq(vault.lockedAssets(), 10e18);
    }
}
