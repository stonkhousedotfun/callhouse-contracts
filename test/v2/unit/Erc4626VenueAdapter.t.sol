// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {V8AccessTest} from "../lib/V8Access.sol";
import {Erc4626VenueAdapter} from "../../../src/v2/periphery/earn/adapters/Erc4626VenueAdapter.sol";
import {Mock4626Vault} from "../../../src/v2/mocks/Mock4626Vault.sol";
import {MockForwardingVault} from "../mocks/MockForwardingVault.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";

/// @notice Erc4626VenueAdapter against {Mock4626Vault} (a venue that HOLDS what it receives) and
///         {MockForwardingVault} (a venue that allocates it onward in the same call). No fork, no RPC.
/// @dev Morpho Blue on 4663 is `0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010` (recon:11,247). It is a constructor
///      argument in production, not compiled in. Named here so a search of `src/` cannot find it as a literal.
contract Erc4626VenueAdapterTest is V8AccessTest {
    MockERC20 internal usdg;
    Mock4626Vault internal vault4626;
    Erc4626VenueAdapter internal adapter;

    address internal vault = makeAddr("earnVault");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant DEP = 10_000e6;

    /// @dev 4663 Morpho Blue (v8-plan/LENDING-RECON-2026-09-19.md:11,247). Tests/NatSpec only.
    address internal constant MORPHO_4663 = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;
    /// @dev Steakhouse USDG ERC-4626 (recon:29). Tests/NatSpec only.
    address internal constant STEAKHOUSE_USDG = 0xBeEff033F34C046626B8D0A041844C5d1A5409dd;

    function setUp() public {
        _deployManager();
        usdg = new MockERC20("USDG", "USDG", 6);
        vault4626 = new Mock4626Vault(IERC20(address(usdg)));
        adapter = new Erc4626VenueAdapter(address(manager), address(usdg), address(vault4626), vault);
        usdg.mint(vault, DEP * 10);
        vm.prank(vault);
        usdg.approve(address(adapter), type(uint256).max);
        vm.label(address(adapter), "Erc4626VenueAdapter");
        vm.label(address(vault4626), "Mock4626Vault");
        // Keep the recon addresses referenced so they exist in this test file and nowhere in src/.
        assertTrue(MORPHO_4663 != address(0) && STEAKHOUSE_USDG != address(0));
    }

    function test_constructor_rejectsCodelessVenue() public {
        vm.expectRevert(V2Errors.NoSource.selector);
        new Erc4626VenueAdapter(address(manager), address(usdg), makeAddr("noCode"), vault);
    }

    function test_constructor_rejectsCodelessAsset() public {
        vm.expectRevert(V2Errors.NoSource.selector);
        new Erc4626VenueAdapter(address(manager), makeAddr("noCode"), address(vault4626), vault);
    }

    function test_constructor_rejectsWrongAsset() public {
        MockERC20 other = new MockERC20("OTHER", "OTHER", 6);
        Mock4626Vault otherVault = new Mock4626Vault(IERC20(address(other)));
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        new Erc4626VenueAdapter(address(manager), address(usdg), address(otherVault), vault);
    }

    function test_withdrawable_isMaxWithdrawNotNominalWorth() public {
        vm.prank(vault);
        adapter.deposit(DEP);
        uint256 worth = adapter.totalAssets();
        assertGt(worth, 0);
        vault4626.setWithdrawCap(1_000e6);
        uint256 can = adapter.withdrawable();
        assertEq(can, 1_000e6, "throttled maxWithdraw");
        assertLt(can, worth, "withdrawable is the throttle, not the position");
        assertGt(adapter.totalAssets(), can, "nominal worth still large");
    }

    /*------------- T-OP-008: deposit returns what LEFT the adapter, whatever the venue does with it -------------*/

    /// @dev An adapter over `venue`, owned by the same `vault` stand-in and funded the same way as {adapter}.
    function _adapterOver(address venue_) internal returns (Erc4626VenueAdapter a) {
        a = new Erc4626VenueAdapter(address(manager), address(usdg), venue_, vault);
        vm.prank(vault);
        usdg.approve(address(a), type(uint256).max);
    }

    /// @dev THE DEFECT, AGAINST THE SHAPE OF THE LIVE VENUE. Steakhouse USDG on 4663 passes a deposit straight to
    ///      its allocator, so its own USDG balance ends where it started while shares are minted. The old measure
    ///      was that venue-balance delta and returned 0 here. The two preconditions are asserted so this test
    ///      cannot pass against a venue that holds: against a holding venue both measures agree.
    function test_deposit_forwardingVenue_returnsWhatLeftTheAdapter() public {
        MockForwardingVault fwd = new MockForwardingVault(IERC20(address(usdg)), 10_000);
        Erc4626VenueAdapter a = _adapterOver(address(fwd));
        uint256 vaultBefore = usdg.balanceOf(vault);
        uint256 venueBefore = usdg.balanceOf(address(fwd));
        vm.prank(vault);
        uint256 deposited = a.deposit(DEP);

        assertEq(usdg.balanceOf(address(fwd)), venueBefore, "precondition: the venue forwarded everything onward");
        assertGt(fwd.balanceOf(address(a)), 0, "precondition: shares were minted, so the deposit happened");
        assertEq(usdg.balanceOf(fwd.sink()), DEP, "precondition: the assets are at the allocator");

        assertEq(deposited, DEP, "deposit must return what left the adapter, not the venue balance delta (0 here)");
        assertEq(vaultBefore - usdg.balanceOf(vault), deposited, "the return is exactly what the vault paid");
        assertEq(usdg.balanceOf(address(a)), 0, "the adapter keeps no float");
    }

    /// @dev THE MIXED CASE, the one a naive fix gets wrong: the venue keeps 60 % and allocates 40 %. The old
    ///      measure returned the 60 %. What left the adapter is the whole offer.
    function test_deposit_mixedVenue_holdsPartForwardsPart_returnsTheWholeOffer() public {
        MockForwardingVault fwd = new MockForwardingVault(IERC20(address(usdg)), 4_000);
        Erc4626VenueAdapter a = _adapterOver(address(fwd));
        uint256 vaultBefore = usdg.balanceOf(vault);
        uint256 venueBefore = usdg.balanceOf(address(fwd));
        vm.prank(vault);
        uint256 deposited = a.deposit(DEP);

        assertEq(usdg.balanceOf(address(fwd)) - venueBefore, (DEP * 6_000) / 10_000, "precondition: venue kept 60 %");
        assertEq(deposited, DEP, "the whole offer left the adapter; the venue's retained 60 % is not the answer");
        assertEq(vaultBefore - usdg.balanceOf(vault), deposited, "the return is exactly what the vault paid");
        assertEq(a.totalAssets(), DEP, "and the position is worth the whole offer");
    }

    /// @dev SHAPE INDEPENDENCE, the other half of the proof. A venue that HOLDS must return the same true figure
    ///      as one that forwards, or the fix has only swapped one venue-specific measure for another.
    function test_deposit_holdingVenue_returnsWhatLeftTheAdapter() public {
        uint256 vaultBefore = usdg.balanceOf(vault);
        uint256 venueBefore = usdg.balanceOf(address(vault4626));
        vm.prank(vault);
        uint256 deposited = adapter.deposit(DEP);

        assertEq(usdg.balanceOf(address(vault4626)) - venueBefore, DEP, "precondition: the holding venue kept it all");
        assertEq(deposited, DEP, "a holding venue returns the same true figure as a forwarding one");
        assertEq(vaultBefore - usdg.balanceOf(vault), deposited, "the return is exactly what the vault paid");
    }

    /// @dev Every split between holding and forwarding, every size: the return is what the vault paid. Against
    ///      the old measure this is red for any split that forwards at least one base unit.
    function testFuzz_deposit_returnIsWhatLeft_forAnyForwardShare(uint16 bps, uint256 amount) public {
        bps = uint16(bound(bps, 0, 10_000));
        amount = bound(amount, 1, DEP * 10);
        MockForwardingVault fwd = new MockForwardingVault(IERC20(address(usdg)), bps);
        Erc4626VenueAdapter a = _adapterOver(address(fwd));
        uint256 vaultBefore = usdg.balanceOf(vault);
        vm.prank(vault);
        uint256 deposited = a.deposit(amount);
        assertEq(deposited, amount, "deposit must return what left the adapter for every hold/forward split");
        assertEq(vaultBefore - usdg.balanceOf(vault), deposited, "the return is exactly what the vault paid");
        assertEq(usdg.balanceOf(address(a)), 0, "the adapter keeps no float");
    }

    /// @dev The try/catch STAYS (T-OP-008 acceptance 3). A venue that refuses the deposit is not an outage: the
    ///      adapter reports 0, refunds the vault in full, and does not revert.
    function test_deposit_venueReverts_returnsZeroAndRefundsTheVault() public {
        vm.mockCallRevert(address(vault4626), abi.encodeWithSelector(IERC4626.deposit.selector), bytes("paused"));
        uint256 vaultBefore = usdg.balanceOf(vault);
        vm.prank(vault);
        uint256 deposited = adapter.deposit(DEP);
        assertEq(deposited, 0, "nothing left for the venue");
        assertEq(usdg.balanceOf(vault), vaultBefore, "the whole offer came back to the vault");
        assertEq(usdg.balanceOf(address(adapter)), 0, "and none of it stayed in the adapter");
    }

    /// @dev T-OP-008 REWROTE THIS TEST, DELIBERATELY. It was `test_deposit_returnIsMeasuredVenueDelta_notPreview`
    ///      and asserted `deposited == the venue's asset-balance delta` and `deposited < DEP` against a 10 %
    ///      deposit-fee venue -- it pinned the venue-delta measure, the same measure that returns 0 against a
    ///      venue that forwards. A deposit fee is taken INSIDE the venue after the venue has taken the whole
    ///      offer: all of DEP left the adapter and the vault, and the skim shows in what the position is worth,
    ///      not in what was delivered. `EarnVault.sweepToVenue` credits its own measured delta (EarnVault.sol:819),
    ///      which here is also all of DEP, so the return now agrees with the vault's own measure where it did not.
    function test_deposit_feeTakingVenue_returnIsWhatLeft_andTheFeeShowsInPositionValue() public {
        vault4626.setFees(1_000, 0); // 10 % deposit skim
        uint256 vaultBefore = usdg.balanceOf(vault);
        uint256 venueBefore = usdg.balanceOf(address(vault4626));
        vm.prank(vault);
        uint256 deposited = adapter.deposit(DEP);
        uint256 venueDelta = usdg.balanceOf(address(vault4626)) - venueBefore;
        assertLt(venueDelta, DEP, "precondition: the fee-taking venue kept less than it took");
        assertEq(deposited, DEP, "the whole offer left the adapter; the fee is inside the venue");
        assertEq(usdg.balanceOf(vault), vaultBefore - DEP, "caller paid the offer");
        assertLt(adapter.totalAssets(), DEP, "the skim is visible in the position's value");
    }

    function test_withdraw_returnIsMeasuredRecipientDelta_andDoesNotRevertWhenShort() public {
        vm.prank(vault);
        adapter.deposit(DEP);
        vault4626.setWithdrawCap(1_000e6);
        uint256 toBefore = usdg.balanceOf(vault);
        vm.prank(vault);
        uint256 got = adapter.withdraw(DEP, vault);
        assertEq(got, usdg.balanceOf(vault) - toBefore, "measured recipient delta");
        assertLt(got, DEP, "short of the ask");
        assertGt(got, 0);
    }

    function test_withdraw_feeTakingVenue_measuredNotTrusted() public {
        vm.prank(vault);
        adapter.deposit(DEP);
        vault4626.setFees(0, 1_000); // 10 % withdraw skim
        uint256 toBefore = usdg.balanceOf(vault);
        vm.prank(vault);
        uint256 got = adapter.withdraw(1_000e6, vault);
        assertEq(got, usdg.balanceOf(vault) - toBefore);
        assertLt(got, 1_000e6, "fee is visible in the measured delta");
    }

    /*--------------------- T-170: authorisation, the protected fact ---------------------*/

    /// @dev THE HOLE THIS TASK CLOSED. `withdraw(uint256,address)` was `external nonReentrant` with no access
    ///      modifier and a caller-supplied recipient, so any EOA could call `withdraw(type(uint256).max, attacker)`
    ///      and be paid whatever the venue would release. This asserts the PROTECTED FACT -- a stranger cannot
    ///      withdraw -- and not the presence of a modifier, so it goes red if the guard is removed by any means.
    function test_withdraw_strangerCannotDrainToItself() public {
        vm.prank(vault);
        adapter.deposit(DEP);
        assertGt(adapter.withdrawable(), 0, "venue must hold something, or this test proves nothing");

        uint256 before = usdg.balanceOf(stranger);
        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        adapter.withdraw(type(uint256).max, stranger);
        assertEq(usdg.balanceOf(stranger), before, "not one wei may move");

        // The vault itself still works: the guard authorises, it does not disable.
        vm.prank(vault);
        uint256 got = adapter.withdraw(DEP, vault);
        assertGt(got, 0, "the owning vault must still be able to withdraw");
    }

    /// @dev deposit is the same class: unauthenticated, and its leftover refund pays the caller.
    function test_deposit_strangerCannotCall() public {
        usdg.mint(stranger, DEP);
        vm.prank(stranger);
        usdg.approve(address(adapter), type(uint256).max);
        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        adapter.deposit(DEP);
    }

    /// @dev The authorisation is anchored to immutable state, not to anything a caller can present.
    function test_vault_isImmutableAndNotCallerSupplied() public view {
        assertEq(adapter.vault(), vault, "vault is the immutable the guard reads");
    }

    function test_constructor_rejectsZeroVault() public {
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        new Erc4626VenueAdapter(address(manager), address(usdg), address(vault4626), address(0));
    }
}
