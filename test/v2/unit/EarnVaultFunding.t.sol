// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EarnVaultTestBase} from "./EarnVault.t.sol";
import {IEarnVault} from "../../../src/v2/interfaces/IEarnVault.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";

/// @notice T-OP-068 (from T-OP-049 next-three item 1). `EarnVault.fund` has one caller gate and five silent-zero
///         arms, and until this file none of them had a test on either side. The gate reverts `NotAuthorized` for
///         any caller but the book; the arms EMIT `Funded(asset, amount, 0)` AND RETURN, because the book must never
///         revert on a funded maker (IFundingSource property 4). A refactor that deleted the gate, or turned an arm
///         into a revert -- which WOULD break the book's take path -- stayed green before this file.
///
/// @dev THE TWO SETS, compared at the landed T-OP-042 shape (`src/v2/periphery/earn/EarnVault.sol`):
///        `fund`'s early-return arms (`:708-711`): wrong asset | funding off | withdrawal owed | amount == 0; plus a
///        fifth silent zero at the clamp (`:743-746`): nothing deliverable after escrow.
///        `fundable`'s zero set (`:688-690`): wrong asset | funding off | withdrawal owed; plus `_deliverable` (`:1244`)
///        saturating to 0 when the wallet holds no more than the escrow and the venue offers nothing.
///      They AGREE on every state condition. `amount == 0` has no view analogue -- a view takes no amount -- so
///      the four conditions the row names are three state conditions plus one argument condition, and this file
///      pins all of them and the fifth arm besides. Every silent-zero test asserts THREE things, never one: the
///      event's third argument is 0, no balance moved (wallet, ledger, venue, escrow), and the call returned.
contract EarnVaultFundingGateTest is EarnVaultTestBase {
    /// @dev Snapshot of every balance a `fund` could move, taken before and compared after a silent arm.
    struct Balances {
        uint256 wallet;
        uint256 ledger;
        uint256 venue;
        uint256 escrow;
        uint256 bookAllowance;
    }

    function _balances() internal view returns (Balances memory b) {
        b.wallet = usdg.balanceOf(address(earn));
        b.ledger = ch.free(address(earn), address(usdg));
        b.venue = address(earn.adapter()) == address(0) ? 0 : venue.totalAssets();
        b.escrow = earn.escrowedAssets();
        b.bookAllowance = usdg.allowance(address(earn), address(ch));
    }

    function _assertUnmoved(Balances memory before, string memory arm) internal view {
        Balances memory after_ = _balances();
        assertEq(after_.wallet, before.wallet, string.concat(arm, ": the wallet moved"));
        assertEq(after_.ledger, before.ledger, string.concat(arm, ": the ledger moved"));
        assertEq(after_.venue, before.venue, string.concat(arm, ": the venue moved"));
        assertEq(after_.escrow, before.escrow, string.concat(arm, ": the escrow moved"));
        assertEq(after_.bookAllowance, before.bookAllowance, string.concat(arm, ": an approval was left behind"));
    }

    /// @dev A silent-zero arm, exercised as the book would: the call MUST return (a revert here fails the test at
    ///      the call), MUST emit `Funded(asset_, amount, 0)` with all three arguments checked, and MUST move nothing.
    function _expectSilentZero(address asset_, uint256 amount, string memory arm) internal {
        Balances memory before = _balances();
        vm.expectEmit(true, false, false, true, address(earn));
        emit IEarnVault.Funded(asset_, amount, 0);
        vm.prank(address(book));
        earn.fund(asset_, amount);
        _assertUnmoved(before, arm);
    }

    /// @dev A funded vault with funding on and cash in the wallet, so that the ONLY thing standing between the
    ///      book and a delivery in each arm below is the condition under test.
    function _fundedAndOn() internal {
        _setAdapter();
        _enableFunding();
        _deposit(alice, DEP);
        _sweep(DEP / 2);
        assertGt(earn.fundable(address(usdg)), 0, "premise: with nothing wrong the vault offers funding");
    }

    /*//////////////////////////////////////////////////////////////
                             (i) THE CALLER GATE
    //////////////////////////////////////////////////////////////*/

    /// @dev `EarnVault.sol:707` (`msg.sender != address(orderBook)` -> `NotAuthorized`). By selector, for an EOA,
    ///      the QUOTER, and the admin -- the three callers a refactor would most plausibly let through. The book
    ///      itself is the control, in the last block: same arguments, and it is allowed in.
    function test_fund_refusesEveryCallerButTheBookBySelector() public {
        _fundedAndOn();
        address[3] memory outsiders = [alice, quoter, admin];
        for (uint256 i; i < 3; ++i) {
            vm.prank(outsiders[i]);
            vm.expectRevert(V2Errors.NotAuthorized.selector);
            earn.fund(address(usdg), 1e6);
        }
        uint256 ledgerBefore = ch.free(address(earn), address(usdg));
        vm.prank(address(book));
        earn.fund(address(usdg), 1e6);
        assertEq(ch.free(address(earn), address(usdg)) - ledgerBefore, 1e6, "control: the book is let in and funded");
    }

    /*//////////////////////////////////////////////////////////////
                     (ii) ONE TEST PER SILENT-ZERO ARM
    //////////////////////////////////////////////////////////////*/

    /// @dev Arm 1, `asset_ != _asset`. NVDA is a registered underlying the vault could hold, so this is the
    ///      plausible wrong asset, not a random address.
    function test_fund_wrongAssetEmitsZeroAndMovesNothing() public {
        _fundedAndOn();
        _expectSilentZero(address(nvda), 1e18, "wrong asset");
    }

    /// @dev Arm 2, `!fundingEnabled`. The vault's own switch, off.
    function test_fund_fundingOffEmitsZeroAndMovesNothing() public {
        _fundedAndOn();
        vm.prank(admin);
        earn.setFundingEnabled(false);
        _expectSilentZero(address(usdg), 1e6, "funding off");
    }

    /// @dev Arm 3, `_owesWithdrawal()`. A redemption the vault could not pay is queued, so it owes a withdrawal
    ///      (`_openWithdrawals != 0`) -- the state F5 kept as the funding gate.
    function test_fund_owedWithdrawalEmitsZeroAndMovesNothing() public {
        _fundedAndOn();
        // Freeze the venue so alice's exit cannot be raised and queues instead of paying.
        venue.setFrozen(true);
        uint256 shares = earn.balanceOf(alice);
        vm.prank(alice);
        (uint256 paid, uint256 id) = earn.redeem(shares, alice);
        assertEq(paid, 0, "premise: the exit queued");
        assertGt(id, 0, "premise: with an id");
        venue.setFrozen(false);
        assertEq(earn.fundable(address(usdg)), 0, "premise: the view already answers 0 while a withdrawal is owed");
        _expectSilentZero(address(usdg), 1e6, "owed withdrawal");
    }

    /// @dev Arm 4, `amount == 0`. The one condition with no view analogue.
    function test_fund_zeroAmountEmitsZeroAndMovesNothing() public {
        _fundedAndOn();
        _expectSilentZero(address(usdg), 0, "zero amount");
    }

    /// @dev Arm 5, the clamp's silent zero (`:743-746`): every base unit in the wallet is a queued depositor's
    ///      escrow, there is no venue, so `_deliverable` is 0 and the book is told so without a revert. This is
    ///      the arm T-OP-042 made honest on the view side; here the fund side is pinned.
    function test_fund_nothingDeliverableAfterEscrowEmitsZeroAndMovesNothing() public {
        _enableFunding();
        _deposit(alice, DEP);
        vm.prank(quoter);
        earn.depositToClearinghouse(address(usdg), DEP);
        _setSpot(address(nvda), 240_000_000);
        vm.prank(quoter);
        uint256 orderId = earn.place(putId, WRITE, uint128(V2Constants.PRICE_TICK * 10), 10, 0);
        _take(carol, _buy(putId, _ids(orderId), 10, uint128(V2Constants.PRICE_TICK * 10), carol));
        // Sweep the premium to the ledger too, so the wallet is escrow and nothing else once bob queues. The
        // balance is read into a local FIRST: `vm.prank` binds to the next call, and a `balanceOf` written inline
        // as the argument is that call -- the first draft's deposit then ran as the test contract, `NotAuthorized`.
        uint256 premium = usdg.balanceOf(address(earn));
        vm.prank(quoter);
        earn.depositToClearinghouse(address(usdg), premium);
        _deposit(bob, DEP);
        assertEq(earn.escrowedAssets(), DEP, "premise: bob's deposit is escrowed");
        assertEq(usdg.balanceOf(address(earn)), DEP, "premise: the wallet holds the escrow and nothing else");
        assertEq(earn.fundable(address(usdg)), 0, "premise: the view answers 0");
        _expectSilentZero(address(usdg), 1e6, "nothing deliverable");
    }

    /*//////////////////////////////////////////////////////////////
                (iii) fundable's ZERO SET IS THE SAME SET
    //////////////////////////////////////////////////////////////*/

    /// @dev `EarnVault.sol:688-690`, one condition at a time from a state where it answers > 0, so each zero is
    ///      attributable. The amount arm has no view analogue and is not here.
    function test_fundable_isZeroUnderExactlyTheConditionsFundReturnsZero() public {
        _fundedAndOn();
        uint256 offered = earn.fundable(address(usdg));
        assertGt(offered, 0, "control: nothing wrong, funding offered");

        assertEq(earn.fundable(address(nvda)), 0, "wrong asset");

        vm.prank(admin);
        earn.setFundingEnabled(false);
        assertEq(earn.fundable(address(usdg)), 0, "funding off");
        vm.prank(admin);
        earn.setFundingEnabled(true);
        assertEq(earn.fundable(address(usdg)), offered, "and back on: the same answer, so the switch is the cause");

        venue.setFrozen(true);
        uint256 aliceShares = earn.balanceOf(alice); // read before the prank, for the same reason as above
        vm.prank(alice);
        (, uint256 id) = earn.redeem(aliceShares, alice);
        venue.setFrozen(false);
        assertEq(earn.fundable(address(usdg)), 0, "owed withdrawal");
        vm.prank(alice);
        earn.cancelQueued(id);
        assertEq(earn.fundable(address(usdg)), offered, "and withdrawn: the same answer, so the debt was the cause");
    }

    /*//////////////////////////////////////////////////////////////
                    (iv) CONTROL: the book funds for real
    //////////////////////////////////////////////////////////////*/

    /// @dev With nothing wrong, `fundable` before == `Funded.delivered` == the ledger delta, for the whole quote.
    ///      This is the arm every silent zero is the negation of; without it the five tests above could pass
    ///      against a vault that never funds anyone.
    function test_fund_controlDeliversExactlyWhatFundableOffered() public {
        _fundedAndOn();
        uint256 offered = earn.fundable(address(usdg));
        uint256 ledgerBefore = ch.free(address(earn), address(usdg));
        vm.expectEmit(true, false, false, true, address(earn));
        emit IEarnVault.Funded(address(usdg), offered, offered);
        vm.prank(address(book));
        earn.fund(address(usdg), offered);
        assertEq(ch.free(address(earn), address(usdg)) - ledgerBefore, offered, "the ledger received the offer");
        assertEq(earn.fundable(address(usdg)), 0, "and the offer is spent: nothing left in the wallet or the venue");
    }
}
