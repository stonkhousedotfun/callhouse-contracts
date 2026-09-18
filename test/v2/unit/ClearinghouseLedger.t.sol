// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ClearinghouseTestBase} from "./ClearinghouseBase.t.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";

/// @notice An 18-dp token that burns 1 % of every transferFrom in flight, to prove deposit credits the measured delta.
contract ClearinghouseFeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee Stock Token", "FEEx") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        uint256 fee = value / 100;
        _spendAllowance(from, msg.sender, value);
        _burn(from, fee);
        _transfer(from, to, value - fee);
        return true;
    }
}

/// @notice Clearinghouse ledger: deposit delta measurement, supported assets, withdraw, operators and payout prefs.
contract ClearinghouseLedgerTest is ClearinghouseTestBase {
    function test_deposit_creditsAndEmits() public {
        vm.expectEmit(true, true, false, true, address(ch));
        emit IClearinghouse.Deposited(alice, address(usdg), 1_000e6, alice);
        _deposit(alice, address(usdg), 1_000e6);
        assertEq(ch.free(alice, address(usdg)), 1_000e6);
        assertEq(usdg.balanceOf(address(ch)), 1_000e6);

        _deposit(alice, address(nvda), 3e18);
        assertEq(ch.free(alice, address(nvda)), 3e18);
        assertEq(ch.free(alice, address(tsla)), 0);
    }

    function test_deposit_toAnotherAccount() public {
        vm.expectEmit(true, true, false, true, address(ch));
        emit IClearinghouse.Deposited(bob, address(nvda), 1e18, alice);
        vm.prank(alice);
        ch.deposit(address(nvda), 1e18, bob);
        assertEq(ch.free(bob, address(nvda)), 1e18);
        assertEq(ch.free(alice, address(nvda)), 0);
        assertEq(nvda.balanceOf(alice), ACTOR_SHARES - 1e18, "pulled from the caller");
    }

    function test_deposit_measuresBalanceDelta() public {
        ClearinghouseFeeOnTransferToken fot = new ClearinghouseFeeOnTransferToken();
        vm.prank(admin);
        ch.registerMarket(address(fot), _cfg(address(oracle)));
        fot.mint(alice, 100e18);
        vm.prank(alice);
        fot.approve(address(ch), type(uint256).max);

        vm.expectEmit(true, true, false, true, address(ch));
        emit IClearinghouse.Deposited(alice, address(fot), 99e18, alice);
        _deposit(alice, address(fot), 100e18);
        assertEq(ch.free(alice, address(fot)), 99e18, "credited what arrived, not what was asked");
        assertEq(fot.balanceOf(address(ch)), 99e18);
    }

    function test_deposit_unsupportedAsset() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(alice, 1e18);
        vm.prank(alice);
        other.approve(address(ch), 1e18);
        vm.prank(alice);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        ch.deposit(address(other), 1e18, alice);

        vm.prank(alice);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        ch.deposit(address(0), 1, alice);
    }

    function test_deposit_disabledMarketUnderlyingStillAccepted() public {
        V2Types.MarketConfig memory off = _cfg(address(oracle));
        off.enabled = false;
        vm.prank(admin);
        ch.setMarketConfig(address(nvda), off);
        _deposit(alice, address(nvda), 1e18);
        assertEq(ch.free(alice, address(nvda)), 1e18);
    }

    function test_deposit_revertsWhenTransferFails() public {
        usdg.pause();
        vm.prank(alice);
        vm.expectRevert(MockERC20.ContractPaused.selector);
        ch.deposit(address(usdg), 1e6, alice);
    }

    function test_withdraw_sendsAndEmits() public {
        _deposit(alice, address(usdg), 500e6);
        vm.expectEmit(true, true, false, true, address(ch));
        emit IClearinghouse.Withdrawn(alice, address(usdg), 200e6, carol);
        vm.prank(alice);
        ch.withdraw(address(usdg), 200e6, carol);
        assertEq(ch.free(alice, address(usdg)), 300e6);
        assertEq(usdg.balanceOf(carol), ACTOR_USDG + 200e6);

        vm.prank(alice);
        ch.withdraw(address(usdg), 300e6, alice);
        assertEq(ch.free(alice, address(usdg)), 0);
        assertEq(usdg.balanceOf(address(ch)), 0);
    }

    /// @dev Accepted behaviour (sweep contracts-c03, V2-ARCHITECTURE §6.1 and §6.2): issuer freezes are not mirrored
    ///      onto the ledger. A USDG-frozen, Stock-Token-blocklisted account cannot withdraw to itself, but it can
    ///      withdraw its free balance to another address: the tokens see only the Clearinghouse and the recipient.
    function test_withdraw_frozenOrBlocklistedAccountCanPayAnotherAddress() public {
        address clean = makeAddr("clean");
        _deposit(bob, address(usdg), 5e6);
        _deposit(bob, address(nvda), 1e18);
        usdg.freeze(bob);
        nvda.blockAccount(bob);

        vm.startPrank(bob);
        vm.expectRevert();
        ch.withdraw(address(usdg), 5e6, bob);
        vm.expectRevert();
        ch.withdraw(address(nvda), 1e18, bob);
        ch.withdraw(address(usdg), 5e6, clean);
        ch.withdraw(address(nvda), 1e18, clean);
        vm.stopPrank();
        assertEq(usdg.balanceOf(clean), 5e6);
        assertEq(nvda.balanceOf(clean), 1e18);
        assertEq(ch.free(bob, address(usdg)) + ch.free(bob, address(nvda)), 0);
    }

    function test_withdraw_moreThanFree() public {
        _deposit(alice, address(nvda), 2e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InsufficientCollateral.selector, 2e18, 2e18 + 1));
        ch.withdraw(address(nvda), 2e18 + 1, alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InsufficientCollateral.selector, 0, 1));
        ch.withdraw(address(nvda), 1, bob);
    }

    function test_withdraw_lockedCollateralIsNotFree() public {
        uint256 longId = _call(K_240, FRI_2026_09_18);
        _write(alice, longId, 100, bob);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InsufficientCollateral.selector, 0, 1));
        ch.withdraw(address(nvda), 1, alice);
    }

    /*//////////////////////////////////////////////////////////////
                               OPERATORS
    //////////////////////////////////////////////////////////////*/

    function test_setOperator_emitsAndStores() public {
        vm.expectEmit(true, true, false, true, address(ch));
        emit IClearinghouse.OperatorSet(alice, mm, true);
        vm.prank(alice);
        ch.setOperator(mm, true);
        assertTrue(ch.isOperator(alice, mm));
        assertFalse(ch.isOperator(mm, alice), "directional");

        vm.prank(alice);
        ch.setOperator(mm, false);
        assertFalse(ch.isOperator(alice, mm));
    }

    function test_operator_mintsFromWritersCollateralOnly() public {
        uint256 longId = _call(K_240, FRI_2026_09_18);
        _deposit(alice, address(nvda), 1e18);

        vm.prank(mm);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        ch.mint(longId, 10, alice, carol);

        vm.prank(alice);
        ch.setOperator(mm, true);
        vm.prank(mm);
        ch.mint(longId, 10, alice, carol);
        assertEq(ch.balanceOf(carol, longId), 10, "operator chooses the long receiver");
        assertEq(ch.balanceOf(alice, _short(longId)), 10, "the short always lands on the writer");
        assertEq(ch.free(alice, address(nvda)), 1e18 - 10e16);

        // Nothing else: no withdraw, no close for the account.
        vm.prank(mm);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InsufficientCollateral.selector, 0, 1));
        ch.withdraw(address(nvda), 1, mm);

        vm.prank(alice);
        ch.setOperator(mm, false);
        vm.prank(mm);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        ch.mint(longId, 1, alice, carol);
    }

    /*//////////////////////////////////////////////////////////////
                                  PREFS
    //////////////////////////////////////////////////////////////*/

    function test_payoutPrefs() public {
        (bool inKind, bool toLedger) = ch.payoutPrefs(alice);
        assertFalse(inKind);
        assertFalse(toLedger);

        vm.expectEmit(true, false, false, true, address(ch));
        emit IClearinghouse.PayoutPrefsSet(alice, true, false);
        vm.prank(alice);
        ch.setPayoutInKind(true);

        vm.expectEmit(true, false, false, true, address(ch));
        emit IClearinghouse.PayoutPrefsSet(alice, true, true);
        vm.prank(alice);
        ch.setPayoutToLedger(true);

        (inKind, toLedger) = ch.payoutPrefs(alice);
        assertTrue(inKind);
        assertTrue(toLedger);

        vm.expectEmit(true, false, false, true, address(ch));
        emit IClearinghouse.PayoutPrefsSet(alice, false, true);
        vm.prank(alice);
        ch.setPayoutInKind(false);
    }

    function test_thirdPartyRedeem_defaultAndToggle() public {
        assertTrue(ch.thirdPartyRedeemAllowed(alice), "default allowed");
        vm.expectEmit(true, false, false, true, address(ch));
        emit IClearinghouse.ThirdPartyRedeemSet(alice, false);
        vm.prank(alice);
        ch.setThirdPartyRedeem(false);
        assertFalse(ch.thirdPartyRedeemAllowed(alice));
        (bool inKind, bool toLedger) = ch.payoutPrefs(alice);
        assertFalse(inKind || toLedger, "separate flag");

        vm.prank(alice);
        ch.setThirdPartyRedeem(true);
        assertTrue(ch.thirdPartyRedeemAllowed(alice));
    }
}
