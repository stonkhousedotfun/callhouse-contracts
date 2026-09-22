// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {V8AccessTest} from "../lib/V8Access.sol";
import {StockVenueAdapter} from "../../../src/v2/periphery/earn/adapters/StockVenueAdapter.sol";
import {Mock4626Vault} from "../../../src/v2/mocks/Mock4626Vault.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";

/// @notice StockVenueAdapter ships disabled: recon 2026-09-19 had 12 Morpho stock-loan markets at zero
///         supply and zero borrow (v8-plan/LENDING-RECON-2026-09-19.md:12,177). P8-04 is the enable decision.
contract StockVenueAdapterTest is V8AccessTest {
    MockERC20 internal nvda;
    Mock4626Vault internal vault4626;
    StockVenueAdapter internal adapter;

    address internal vault = makeAddr("earnVault");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant DEP = 10e18;

    function setUp() public {
        _deployManager();
        nvda = new MockERC20("NVDA", "NVDA", 18);
        vault4626 = new Mock4626Vault(IERC20(address(nvda)));
        adapter = new StockVenueAdapter(address(manager), address(nvda), address(vault4626), vault);
        nvda.mint(vault, DEP * 10);
        vm.prank(vault);
        nvda.approve(address(adapter), type(uint256).max);
    }

    function test_constructsDisabled() public view {
        assertFalse(adapter.enabled());
        assertEq(adapter.withdrawable(), 0);
        assertEq(adapter.totalAssets(), 0);
    }

    function test_deposit_isNoOpWhileDisabled_takesNoTokens() public {
        uint256 before = nvda.balanceOf(vault);
        vm.prank(vault);
        uint256 deposited = adapter.deposit(DEP);
        assertEq(deposited, 0);
        assertEq(nvda.balanceOf(vault), before, "disabled deposit does not pull");
        assertEq(adapter.totalAssets(), 0);
    }

    /// @dev An UNFUNDED disabled adapter withdraws 0 — but it would do that enabled too, because the venue
    ///      is empty and `_withdrawFromVenue` returns 0 when `maxWithdraw` is 0. Asserted here with the
    ///      reason named so nobody later reads this as "the flag stops withdrawals"; it does not, and
    ///      {test_disabledAdapterCanStillBeDrained} is the test that pins what actually happens.
    function test_withdraw_returnsZeroWhileDisabled_becauseTheVenueIsEmpty() public {
        assertEq(adapter.totalAssets(), 0, "precondition: nothing in the venue");
        vm.prank(vault);
        uint256 got = adapter.withdraw(DEP, vault);
        assertEq(got, 0);
    }

    /*//////////////////////////////////////////////////////////////
        `enabled` GATES DEPOSITS ONLY — the NAV-collapse regression
    //////////////////////////////////////////////////////////////*/

    /// Fund the adapter, then turn it off. This is the state the whole finding is about.
    function _fundThenDisable() internal returns (uint256 funded) {
        adapter.setEnabled(true);
        vm.prank(vault);
        adapter.deposit(DEP);
        funded = adapter.totalAssets();
        assertGt(funded, 0, "precondition: the venue really holds assets");
        adapter.setEnabled(false);
    }

    /// @dev THE REGRESSION. Before the fix `totalAssets()` was `if (!enabled) return 0;`, so one
    ///      {setEnabled}(false) erased the venue balance from {EarnVault.totalAssets}
    ///      (`EarnVault.sol:642` adds `a.totalAssets()`), underpaying redemptions and over-minting
    ///      deposits. Custody does not change because a flag flipped.
    function test_disablingAFundedAdapterDoesNotHideItsAssets() public {
        uint256 funded = _fundThenDisable();
        assertEq(adapter.totalAssets(), funded, "disabled adapter must still report what it holds");
        assertFalse(adapter.enabled(), "and it really is disabled");
    }

    /// @dev {withdrawable} feeds {EarnVault.fundable} (`EarnVault.sol:433`) and, more importantly,
    ///      {EarnVault.setAdapter}'s pull (`EarnVault.sol:511`). Zero here while funded is what let the
    ///      stranding guard pass over a funded venue.
    function test_withdrawableIsHonestWhileDisabled() public {
        _fundThenDisable();
        assertGt(adapter.withdrawable(), 0, "a disabled adapter must still say what can be pulled out");
    }

    /// @dev A brake must never trap inventory — the rule {HouseVault} states for its own at
    ///      `HouseVault.sol:654`. Disabling stops NEW money going in; it must not strand what is there,
    ///      or {EarnVault.setAdapter} could never drain the adapter it is replacing.
    function test_disabledAdapterCanStillBeDrained() public {
        uint256 funded = _fundThenDisable();
        uint256 before = nvda.balanceOf(vault);
        vm.prank(vault);
        uint256 got = adapter.withdraw(funded, vault);
        assertEq(got, funded, "the whole balance comes out while disabled");
        assertEq(nvda.balanceOf(vault) - before, funded, "and it reaches the vault");
        assertEq(adapter.totalAssets(), 0, "nothing left behind");
    }

    /// @dev The half that must keep working: disabled still refuses to ACQUIRE a position. If this ever
    ///      goes green with a non-zero deposit, "ships disabled" means nothing.
    function test_disabledStillRefusesNewDeposits_afterBeingFunded() public {
        uint256 funded = _fundThenDisable();
        uint256 before = nvda.balanceOf(vault);
        vm.prank(vault);
        uint256 deposited = adapter.deposit(DEP);
        assertEq(deposited, 0, "no new assets placed while disabled");
        assertEq(nvda.balanceOf(vault), before, "and none taken from the vault");
        assertEq(adapter.totalAssets(), funded, "the existing position is untouched");
    }

    function test_setEnabled_restricted() public {
        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        adapter.setEnabled(true);
        adapter.setEnabled(true);
        assertTrue(adapter.enabled());
    }

    function test_onceEnabled_behavesLikeErc4626Adapter() public {
        adapter.setEnabled(true);
        vm.prank(vault);
        uint256 deposited = adapter.deposit(DEP);
        assertEq(deposited, DEP);
        assertGt(adapter.withdrawable(), 0);
        assertGt(adapter.totalAssets(), 0);
        vm.prank(vault);
        uint256 got = adapter.withdraw(DEP / 2, vault);
        assertEq(got, DEP / 2);
    }
}
