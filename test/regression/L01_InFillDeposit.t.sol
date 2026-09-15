// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {Vault} from "../../src/Vault.sol";
import {OrderComponents} from "../../src/interfaces/ISeaport.sol";
import {InFillDepositor} from "../helpers/InFillDepositor.sol";

/// @title L-01 regression: a buyer cannot deposit inside its own fill and take that fill's premium
/// @notice From AUDIT-FINDINGS-2026-09-14 L-01 (Low). BUG: Seaport transfers the offer item (the option
///         ERC-1155) before the consideration item (USDG), so a contract buyer's `onERC1155Received` ran
///         after the vault's `authorizeOrder` wrote the fill and before the premium arrived. A `deposit`
///         from there passed every gate, its `_checkpointHarvest` found no new USDG, and the new shares
///         then took a pro-rata slice of the premium the buyer was paying. In the PoC (alice 20e18,
///         buyer fills 10 contracts at 1.90 and deposits 20e18 in the hook) alice was left 9.025000 USDG
///         of the fill's 18.050000 net and the buyer took the other 9.025000.
///
///         FIXED FORM: `_depositRefused` reason 7 refuses deposits and mints once any fill of the
///         transaction has written (`_fillArmed`), and `maxDeposit`/`maxMint` quote zero from the same
///         predicate. The fill completes, the buyer mints no shares, and alice keeps the whole net
///         premium. The same deposit made in its own transaction after the fill is unaffected and earns
///         none of that fill's premium, because the checkpoint then sees the USDG.
/// @dev Needs `isolate = true` (foundry.toml): without it the whole test function is one transaction and
///      the control's post-fill deposit would also be refused by the still-set transient flag.
contract L01_InFillDeposit is BaseTest {
    uint112 internal constant N = 10;
    uint256 internal constant BOOK = 20e18;

    InFillDepositor internal evil;

    function _setUpFill() internal returns (OrderComponents memory c) {
        _deposit(alice, BOOK);
        uint256 optionId = _rollOpen();
        c = _approveListing(optionId, N, _okUnitPrice());

        evil = new InFillDepositor(vault);
        _fund(address(evil), 2 * BOOK, 100_000_000);
        evil.approveAll(address(usdg), address(seaport));
        evil.approveAll(address(nvda), address(vault));
    }

    function _closeOtm() internal {
        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();
        _rollClose();
    }

    function _netPremium() internal pure returns (uint256) {
        uint256 gross = uint256(N) * _okUnitPrice();
        return gross - (gross * 500) / 10_000;
    }

    /// The attack: deposit and mint from inside the receive hook are both refused `DepositsClosed`, both
    /// quotes read zero there, the fill still completes, and alice keeps every unit of the net premium.
    function test_depositInsideTheBuyersReceiveHookIsRefused() public {
        OrderComponents memory c = _setUpFill();
        evil.arm(BOOK);

        vm.prank(address(evil));
        mockSeaport.fulfil(c, N);

        assertEq(evil.hookCalls(), 1, "the receive hook ran once, mid-fill");
        assertEq(evil.usdgInVaultInHook(), 0, "the premium had not landed when the hook ran");
        assertEq(evil.maxDepositInHook(), 0, "maxDeposit quotes zero inside the fill");
        assertEq(evil.maxMintInHook(), 0, "maxMint quotes zero inside the fill");
        assertEq(bytes4(evil.depositRevert()), Vault.DepositsClosed.selector, "deposit refused inside the fill");
        assertEq(bytes4(evil.mintRevert()), Vault.DepositsClosed.selector, "mint refused inside the fill");

        assertEq(vault.contractsWritten(), N, "the fill completed");
        assertEq(vault.balanceOf(address(evil)), 0, "the buyer minted no shares");
        assertEq(usdg.balanceOf(address(vault)), uint256(N) * _okUnitPrice(), "the premium landed");

        _closeOtm();
        assertEq(vault.claimableUsdg(alice), _netPremium(), "alice keeps the whole net premium");
        assertEq(vault.claimableUsdg(address(evil)), 0, "the buyer takes none of it");
    }

    /// The control: the same deposit in its own transaction right after the fill goes through, at the
    /// same share price, and earns none of that fill's premium because the checkpoint indexes it first.
    function test_control_theSameDepositAfterTheFillIsOpenAndEarnsNoneOfIt() public {
        OrderComponents memory c = _setUpFill();

        vm.prank(address(evil));
        mockSeaport.fulfil(c, N);
        assertEq(evil.hookCalls(), 1);

        assertEq(vault.maxDeposit(address(evil)), DEPOSIT_CAP - BOOK, "deposits are open again next transaction");
        vm.prank(address(evil));
        uint256 shares = vault.deposit(BOOK, address(evil));
        assertEq(shares, vault.balanceOf(alice), "same price as alice");

        _closeOtm();
        assertEq(vault.claimableUsdg(alice), _netPremium(), "alice keeps the whole net premium");
        assertEq(vault.claimableUsdg(address(evil)), 0, "the post-fill depositor takes none of it");
    }
}
