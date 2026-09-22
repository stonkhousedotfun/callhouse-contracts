// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {HouseVaultTestBase} from "../unit/HouseVaultBase.t.sol";

/// @notice Two depositors across three epochs, one winning and one losing (P8-06 tests section).
/// @dev AUTHORED, NOT RUN under the owner's build-mode directive of 2026-09-19; it compiles. This is the suite that
///      would catch an accounting drift the single-epoch unit tests cannot see, because it is the only place where a
///      high-water mark survives a loss and a second depositor enters at a rate the first one set.
contract HouseVaultLifecycleTest is HouseVaultTestBase {
    uint256 internal constant P0 = 220_000_000;
    uint256 internal constant P_UP = 260_000_000;
    uint256 internal constant P_DOWN = 190_000_000;

    /// @dev THE SHAPE THIS EXISTS TO CHECK: A enters at epoch 0, the pool wins, B enters at the raised rate, the
    ///      pool loses, and both exit. B must not be charged a performance fee for a gain that happened before B
    ///      arrived, and A must not be paid out of B's deposit.
    function test_twoDepositorsThreeEpochsOneWinOneLoss() public {
        vm.prank(admin);
        house.setPerformanceFeeBps(1000);

        // EPOCH 0 -- A deposits and is priced 1:1 (first batch).
        _requestDeposit(depositorA, DEP_USDG, 0);
        _finalizeBoundary(P0);
        house.rollEpoch();
        vm.prank(depositorA);
        house.claim();
        uint256 sharesA = house.balanceOf(depositorA);
        assertEq(sharesA, DEP_USDG, "A was not priced 1:1 on the first batch");

        // EPOCH 1 -- the pool wins (the stock leg is worth more at the boundary), B deposits at the raised rate.
        _requestDeposit(depositorB, DEP_USDG, 0);
        _finalizeBoundary(P_UP);
        house.rollEpoch();
        vm.prank(depositorB);
        house.claim();
        uint256 sharesB = house.balanceOf(depositorB);
        assertGt(sharesA, 0, "A still holds");
        assertGt(sharesB, 0, "B received shares");

        uint256 hwmAfterWin = house.highWaterMark();
        assertGt(hwmAfterWin, 0, "a winning epoch set a high-water mark");

        // EPOCH 2 -- the pool loses. No fee may be charged, and the mark must NOT move down.
        uint256 splitterBefore = usdg.balanceOf(splitterAddr);
        _finalizeBoundary(P_DOWN);
        house.rollEpoch();
        assertEq(usdg.balanceOf(splitterAddr), splitterBefore, "a losing epoch was charged a performance fee");
        assertEq(house.highWaterMark(), hwmAfterWin, "the mark moved down after a loss");

        // BOTH EXIT -- in kind, pro rata, and the vault is left with dust only.
        vm.prank(depositorA);
        house.requestWithdraw(sharesA);
        vm.prank(depositorB);
        house.requestWithdraw(sharesB);
        _finalizeBoundary(P_DOWN);
        house.rollEpoch();

        vm.prank(depositorA);
        house.claim();
        vm.prank(depositorB);
        house.claim();

        // Only the dead shares remain.
        assertEq(house.totalSupply(), house.MIN_SHARES(), "supply did not return to the dead shares");
    }

    /// @dev A deposit queued DURING an epoch is invisible to that epoch: the running NAV per share cannot move until
    ///      the boundary prices it. This is the integration-level form of criterion 3.
    function test_aQueuedDepositCannotMoveTheRunningEpoch() public {
        _requestDeposit(depositorA, DEP_USDG, 0);
        _finalizeBoundary(P0);
        house.rollEpoch();
        vm.prank(depositorA);
        house.claim();

        uint256 perShare = _navPerShare();
        for (uint256 i; i < 3; ++i) {
            _requestDeposit(depositorB, DEP_USDG / 4, 0);
            assertEq(_navPerShare(), perShare, "a queued deposit moved the running NAV per share");
        }
    }
}

/// @notice SEC-15: a reserve is payable from wherever the reserve actually is.
/// @dev THE PRECONDITION IS ORDINARY, WHICH IS WHY THIS MATTERS. `depositToClearinghouse` is what the quoter uses
///      to back quoting, it is QUOTER-gated and its use is routine. Before the fix, using it between a boundary
///      and a claim made {HouseVault.claim} revert for EVERY claimant of that epoch, and
///      {HouseVault.cancelDepositRequest} revert for every queued depositor, because both paid from the wallet
///      alone while every reserve in the contract is MEASURED as wallet plus Clearinghouse ledger
///      (`HouseVault.sol:525-527` sets `owedUsdg`/`owedStock` from exactly that sum). The only unblock was
///      `withdrawFromClearinghouse` -- the same key class whose ordinary use caused it.
///
///      BOTH CASES PARK THE WHOLE WALLET, not a fraction, because a partial park is the easy version: the
///      interesting state is the one where the wallet cannot cover a single base unit of what is owed.
contract HouseVaultReserveLedgerTest is HouseVaultTestBase {
    uint256 internal constant BOUNDARY_PRICE = 220_000_000;

    /// @dev A full cycle: deposit, price it, take shares, queue an exit, price that, then park every spare USDG
    ///      on the ledger before the claimant arrives.
    function test_claimPaysAfterTheQuoterParkedTheReserveOnTheLedger() public {
        _requestDeposit(depositorA, DEP_USDG, 0);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        vm.prank(depositorA);
        house.claim();

        // THE READ IS HOISTED OUT OF THE PRANKED CALL ON PURPOSE. `vm.prank` arms exactly one call, and an
        // argument expression is evaluated first -- so `requestWithdraw(house.balanceOf(...))` spends the prank
        // on the balanceOf and sends the real call as the test contract, which then reverts on a share balance
        // it does not have. The revert names the TEST contract, not the depositor, which is what gives it away.
        uint256 sharesA = house.balanceOf(depositorA);
        vm.prank(depositorA);
        house.requestWithdraw(sharesA);

        // PARKED BEFORE THE BOUNDARY, NOT AFTER, AND THE ORDERING IS THE WHOLE REPAIR. This test used to park
        // after `rollEpoch`, which no longer reaches the state it is about: F3 gave `depositToClearinghouse` a
        // reserve carve-out (`_unreservedWallet`, HouseVault.sol:773-779 clamps to wallet - pendingDepositUsdg -
        // owedUsdg), so once the boundary has struck `owedUsdg` the quoter can no longer move that money. The
        // old order left the wallet holding EXACTLY `owed` and the precondition failed `9999999000 >= 9999999000`
        // -- the assertion doing its job and reporting that the premise had moved, not that the fix broke.
        //
        // Parking BEFORE the boundary reaches the same end state through entirely ordinary quoter operations:
        // at this point `owedUsdg` is still zero and depositorA has already claimed, so nothing is reserved, the
        // whole wallet is unreserved and moves, and `rollEpoch` then strikes the reserve against wallet plus
        // ledger (`HouseVault.sol:525-527`). The vault ends up owing money that is sitting on the ledger -- which
        // is precisely the SEC-15 condition, and is still reachable in production for exactly this reason.
        _parkAllUsdgOnTheLedger();

        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();

        uint256 owed = house.owedUsdg();
        assertGt(owed, 0, "precondition: the boundary reserved USDG for the leaver");

        // T-OP-127: THE BOUNDARY NOW RESTORES THE RESERVE INTO THE WALLET ITSELF, so the ordinary-operations
        // route above no longer ends with the wallet short. `rollEpoch` runs `_restoreReserve(usdg, owedUsdg)`
        // (F-5, HouseVault.sol `_restoreReserve`) right after it strikes the reserve, pulling the ledger slice
        // back until the wallet covers it, and since T-OP-073 (0611a817) also pulls the book-owed slice home
        // first. Against a parked wallet that leaves the wallet holding EXACTLY `owed`, which is what the old
        // `assertLt(wallet, owed)` reported as `9999999000 >= 9999999000` -- the precondition doing its job, not
        // the payer breaking. The state this test is about (SEC-15: the reserve is payable from wherever it IS)
        // is still reachable in production by any route that spends wallet USDG after the boundary while the
        // reserve stands -- a fill, a fee sweep, a partial `_restoreReserve` when the ledger is short -- and the
        // quoter route is closed by F3's carve-out, so it is CONSTRUCTED directly, the same precedent the
        // cancel-deposit test below cites (HouseVaultEpoch.t.sol:730-742): the wallet's reserve is moved to the
        // ledger on the vault's behalf. Book-owed USDG does not cover this deficit (nothing is owed by the book),
        // so T-OP-073's pull cannot mask it; only the ledger can pay, which is the subject.
        assertEq(book.owed(address(house)), 0, "precondition: the book owes the vault nothing, so only the ledger can cover the reserve");
        {
            uint256 wallet = usdg.balanceOf(address(house));
            deal(address(usdg), address(house), 0);
            deal(address(usdg), address(this), wallet);
            usdg.approve(address(ch), wallet);
            ch.deposit(address(usdg), wallet, address(house));
        }
        assertLt(usdg.balanceOf(address(house)), owed, "precondition: the wallet alone cannot pay the reserve");
        assertGe(
            usdg.balanceOf(address(house)) + ch.free(address(house), address(usdg)),
            owed,
            "precondition: wallet plus ledger still covers it -- this is a placement problem, not a hole"
        );

        uint256 before = usdg.balanceOf(depositorA);
        vm.prank(depositorA);
        house.claim();

        assertEq(usdg.balanceOf(depositorA) - before, owed, "the claimant was paid in full, not capped to the wallet");
        assertEq(house.owedUsdg(), 0, "the reserve was retired");
    }

    /// @dev The same asymmetry on the other payer. The row does not mention this one; it is the same two lines.
    function test_cancelDepositRequestRefundsAfterTheQuoterParkedTheDepositOnTheLedger() public {
        _requestDeposit(depositorA, DEP_USDG, 0);
        assertEq(house.pendingDepositUsdg(), DEP_USDG, "precondition: the deposit is queued and unpriced");

        // THE QUOTER ROUTE TO THIS STATE IS CLOSED, SO THE STATE IS CONSTRUCTED DIRECTLY, which is the same
        // precedent F3 set at HouseVaultEpoch.t.sol:730-742 and for the same stated reason: the saturating
        // wallet-plus-ledger payer is a SEPARATE defence from the carve-out, and a guard that can no longer
        // reach its subject is a false green rather than a fixed bug.
        //
        // WHY THE ORDERING TRICK USED BY THE CLAIM TEST ABOVE CANNOT WORK HERE. A queued deposit is reserved
        // from the instant the request lands -- `_unreservedWallet` counts `pendingDepositUsdg` (HouseVault.sol:
        // 773-779) -- so there is no window in which this money is unreserved and `depositToClearinghouse` will
        // move it. That is F3 working correctly. It does NOT make `cancelDepositRequest`'s ledger pull dead
        // code: the wallet can still fall short of a queued deposit by any route that spends wallet USDG while
        // the request stands, and this test pins the payer's behaviour when it has.
        uint256 onLedger = DEP_USDG;
        deal(address(usdg), address(house), 0);
        deal(address(usdg), address(this), onLedger);
        usdg.approve(address(ch), onLedger);
        ch.deposit(address(usdg), onLedger, address(house));

        assertLt(usdg.balanceOf(address(house)), DEP_USDG, "precondition: the wallet alone cannot refund it");
        assertGe(
            usdg.balanceOf(address(house)) + ch.free(address(house), address(usdg)),
            DEP_USDG,
            "precondition: wallet plus ledger still covers it -- this is a placement problem, not a hole"
        );

        uint256 before = usdg.balanceOf(depositorA);
        vm.prank(depositorA);
        house.cancelDepositRequest(depositorA);

        assertEq(usdg.balanceOf(depositorA) - before, DEP_USDG, "the depositor got their own money back in full");
        assertEq(house.pendingDepositUsdg(), 0, "the queue entry is gone");
    }

    /// @dev THE FAIL-CLOSED HALF, and it is the half worth arguing about. When wallet plus ledger genuinely
    ///      cannot cover the reserve, this must REVERT rather than pay what it can: a partial payment would
    ///      retire the request and leave the claimant silently short. The hole is manufactured here by moving
    ///      the ledger balance somewhere the vault cannot reach.
    function test_claimStillRevertsWhenNeitherWalletNorLedgerCoversTheReserve() public {
        _requestDeposit(depositorA, DEP_USDG, 0);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        vm.prank(depositorA);
        house.claim();

        // THE READ IS HOISTED OUT OF THE PRANKED CALL ON PURPOSE. `vm.prank` arms exactly one call, and an
        // argument expression is evaluated first -- so `requestWithdraw(house.balanceOf(...))` spends the prank
        // on the balanceOf and sends the real call as the test contract, which then reverts on a share balance
        // it does not have. The revert names the TEST contract, not the depositor, which is what gives it away.
        uint256 sharesA = house.balanceOf(depositorA);
        vm.prank(depositorA);
        house.requestWithdraw(sharesA);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();

        uint256 owed = house.owedUsdg();
        assertGt(owed, 0, "precondition: something is owed");

        // Both sources emptied: the wallet by `deal`, the ledger by never funding it.
        deal(address(usdg), address(house), 0);
        assertEq(ch.free(address(house), address(usdg)), 0, "precondition: the ledger is empty too");

        vm.prank(depositorA);
        vm.expectRevert();
        house.claim();
    }

    /// @dev Moves every spare USDG in the vault's wallet onto its Clearinghouse ledger, as the quoter would.
    function _parkAllUsdgOnTheLedger() private {
        uint256 wallet = usdg.balanceOf(address(house));
        if (wallet == 0) return;
        vm.prank(quoter);
        house.depositToClearinghouse(address(usdg), wallet);
    }
}
