// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {OrderComponents} from "../../src/interfaces/ISeaport.sol";

/// @notice Proves the shared fixture wires up and one clean cycle runs end to end.
contract SmokeTest is BaseTest {
    function test_fixtureWiring() public view {
        assertEq(vault.name(), "Callhouse NVDA");
        assertEq(vault.symbol(), "cNVDA");
        assertEq(vault.decimals(), 18);
        assertEq(address(vault.asset()), address(nvda));
        assertEq(address(vault.usdg()), address(usdg));
        assertEq(registry.collateralToken(), address(nvda));
        assertEq(registry.exerciseToken(), address(usdg));
        assertEq(registry.cycleNumber(), 1);
        assertTrue(registry.isWritingOpen());
        assertEq(vault.spotUsdg(), SPOT_USDG);
        assertEq(_phase(), 0);
    }

    function test_strikeLadderMatchesLiveMarket() public view {
        assertEq(registry.strikePerContract(optionIds[0]), 226_000_000);
        assertEq(registry.strikePerContract(optionIds[4]), 246_000_000);
        assertEq(registry.activeOptionIds().length, 5);
    }

    function test_depositMintsOneSharePerToken() public {
        uint256 shares = _deposit(alice, 10e18);
        assertEq(shares, 10e18, "first deposit is 1:1");
        assertEq(vault.totalAssets(), 10e18);
        assertEq(vault.balanceOf(alice), 10e18);
    }

    /// @dev The whole product in one test: deposit, write, list, fill, expire OTM, close,
    ///      claim the premium, then withdraw the collateral.
    function test_oneCleanCycle() public {
        _deposit(alice, 20e18);

        uint256 gross = _fullCycleOtm(10, _okUnitPrice());
        assertEq(gross, 20_000_000, "$2.00 x 10 contracts");

        // Overcall took 5%, so the vault received 95%.
        assertEq(usdg.balanceOf(overcallFee), 1_000_000, "Overcall fee");

        // The protocol fee is 10% of what the vault actually harvested.
        assertEq(usdg.balanceOf(feeSafe), 1_900_000, "10% of the 19 USDG net");

        // The remainder is claimable by the depositor, not folded into the share price.
        assertEq(vault.claimableUsdg(alice), 17_100_000, "90% of 19 USDG");
        assertEq(vault.totalAssets(), 20e18, "collateral came back whole, OTM");

        vm.prank(alice);
        vault.claimUsdg();
        assertEq(usdg.balanceOf(alice), 17_100_000);

        // Back to Idle, so redemption is instant again.
        assertEq(_phase(), 0);
        assertTrue(vault.canRedeemInstantly());

        vm.prank(alice);
        vault.redeem(20e18, alice, alice);
        assertEq(nvda.balanceOf(alice), 30e18, "all collateral back");
    }
}
