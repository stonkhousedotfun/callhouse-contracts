// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {ValoremLib} from "../../src/lib/ValoremLib.sol";
import {OrderComponents} from "../../src/interfaces/ISeaport.sol";

/// @notice REGRESSION (2026-09-13 finding): the vault prices everything per one token, so it must
///         refuse an option type whose lot is anything else.
/// @dev THE BUG. The arm gate checked the OTM band, the premium floor and utilisation against the
///      compiled `Policy.LOT = 1e18`, but accepted whatever `underlyingAmount` the option type
///      carried. `newOptionType` is permissionless, so any lot can exist on the clearinghouse. With
///      an unrescaled ladder at lot 2e18, a strike of 227 USDG per contract is 113.50 per token
///      against 220 spot, yet the band saw 3.2% out of the money: the proof of concept wrote 23
///      contracts, a buyer filled at the premium floor, exercised, and took ~$4,879 out of an
///      $11,000 book. Any lot above ~1.03e18 passed the band with an in-the-money strike; a lot
///      above 1/0.95 with cap sizing also locked assets already reserved for settled redeemers.
///      THE FIX. `ValoremLib.open` reverts `UnexpectedLotSize(1e18, lot)` unless the type's
///      `underlyingAmount` is exactly one token, before anything is armed. A wrong lot is a week
///      that cannot open, nothing worse.
contract VaultLotSizeTest is BaseTest {
    /// @dev Create a fresh week's ladder on the clearinghouse with the given lot, as a keeper could.
    function _installLotCycle(uint96 lot) internal returns (uint256[] memory ids) {
        vm.warp(expiryTs);
        exerciseTs = uint40(block.timestamp + 6 days);
        expiryTs = uint40(block.timestamp + 7 days);

        uint96[5] memory s = [uint96(227_000_000), 231_000_000, 236_000_000, 241_000_000, 246_000_000];
        ids = new uint256[](5);
        for (uint256 i; i < 5; i++) {
            ids[i] = clear.newOptionType(address(nvda), lot, address(usdg), s[i], exerciseTs, expiryTs);
        }
        feed.setAnswer(SPOT_FEED);
    }

    function _assertRefused(uint96 lot) internal {
        uint256[] memory ids = _installLotCycle(lot);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ValoremLib.UnexpectedLotSize.selector, uint96(1e18), lot));
        vault.rollOpen(ids[0]);
        assertEq(vault.contractsWritten(), 0, "nothing written");
        assertEq(vault.lockedAssets(), 0, "no collateral locked");
        assertEq(_phase(), 0, "still Idle: a skipped week, nothing worse");
    }

    /// The proof-of-concept case: lot 2e18.
    function test_lot2x_isRefused() public {
        _deposit(alice, 30e18);
        _deposit(bob, 20e18);
        _assertRefused(2e18);
    }

    /// Just above one token, where the in-the-money strike still passes a per-token band.
    function test_lot108_isRefused() public {
        _deposit(alice, 30e18);
        _deposit(bob, 20e18);
        _assertRefused(1.08e18);
    }

    /// A lot below one token is refused too: the band would be wrong the other way.
    function test_lotBelowOneToken_isRefused() public {
        _deposit(alice, 30e18);
        _deposit(bob, 20e18);
        _assertRefused(0.5e18);
    }

    /// Cap sizing with lot 1.1e18 would have written into assets reserved for a settled redeemer;
    /// now the type cannot even be armed and the redeemer collects.
    function test_lot110_reservedAssetsStayCollectable() public {
        _deposit(alice, 30e18);
        _deposit(bob, 20e18);
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        vault.queueRedeem(bobShares);
        _fullCycleOtm(10, _okUnitPrice());
        assertEq(vault.reservedAssets(), 20e18, "bob's 20 NVDA reserved");

        _assertRefused(1.1e18);

        vm.prank(bob);
        (uint256 assets,) = vault.completeRedeem(bob);
        assertEq(assets, 20e18, "the reserve was never touched");
    }

    /// Back at exactly one token, arming, listing and writing all work again.
    function test_lotBackToOneToken_writes() public {
        _deposit(alice, 30e18);
        uint256[] memory ids = _installLotCycle(1e18);
        vm.prank(keeper);
        vault.rollOpen(ids[0]);
        assertEq(vault.cycleStrikeUsdg(), 227_000_000, "the 227 rung armed");
        OrderComponents memory c = _approveListing(ids[0], 10, _okUnitPrice());
        _fill(c, 10);
        assertEq(vault.contractsWritten(), 10);
        assertEq(vault.lockedAssets(), 10e18);
    }
}
