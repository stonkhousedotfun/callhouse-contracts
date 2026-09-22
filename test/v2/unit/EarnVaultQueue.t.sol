// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EarnVaultTestBase} from "./EarnVault.t.sol";
import {IEarnVault} from "../../../src/v2/interfaces/IEarnVault.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";

/// @notice Withdrawal queue: disclose rather than revert, FIFO, priced when served.
contract EarnVaultQueueTest is EarnVaultTestBase {
    function test_redeem_queuesWhenVenueCannotCoverAndDiscloses() public {
        _setAdapter();
        _enableFunding();
        _deposit(alice, DEP);
        _sweep(DEP);
        venue.setFrozen(true);

        uint256 aliceShares = earn.balanceOf(alice);
        vm.prank(alice);
        (uint256 paid, uint256 id) = earn.redeem(aliceShares, alice);
        assertEq(paid, 0, "nothing paid now");
        assertEq(id, 1, "first queue id is 1");
        (uint256 head, uint256 tail) = earn.queue();
        assertEq(head, 1);
        assertEq(tail, 1);
        IEarnVault.Request memory r = earn.request(id);
        assertEq(r.owner, alice);
        assertEq(r.receiver, alice);
        assertEq(r.shares, DEP);
        assertEq(earn.balanceOf(address(earn)), DEP, "shares stay in totalSupply, escrowed here");
        assertEq(earn.fundable(address(usdg)), 0, "a vault that owes is invisible to the book");
    }

    /// @dev T-OP-057 (F-CT5B-03). Named for what the body observes: a THIRD PARTY (this test contract, neither
    ///      depositor) serves the queue, and both payouts carry the loss that landed while the entries waited.
    ///      FIFO is not observable here -- `processQueue(2)` serves both entries in one call and every assertion
    ///      below holds in either order -- so the name no longer claims it; the sibling
    ///      {test_processQueue_stopsAtTheHeadOnAPartial} is the FIFO pin (one partial service, head asserted).
    function test_processQueue_isPermissionlessAndPricesAtService() public {
        _setAdapter();
        _deposit(alice, DEP);
        _deposit(bob, DEP);
        _sweep(DEP * 2);
        venue.setFrozen(true);

        uint256 aliceShares = earn.balanceOf(alice);
        uint256 bobShares = earn.balanceOf(bob);
        vm.prank(alice);
        (, uint256 aliceId) = earn.redeem(aliceShares, alice);
        vm.prank(bob);
        (, uint256 bobId) = earn.redeem(bobShares, bob);
        assertEq(aliceId, 1);
        assertEq(bobId, 2);

        // Loss while they wait: priced at SERVICE, so the queued holders bear it.
        venue.setFrozen(false);
        venue.loseAssets(DEP);

        uint256 aliceUsdgBefore = usdg.balanceOf(alice);
        uint256 bobUsdgBefore = usdg.balanceOf(bob);
        // Anyone may crank.
        uint256 served = earn.processQueue(2);
        assertEq(served, 2, "both entries paid");
        uint256 alicePaid = usdg.balanceOf(alice) - aliceUsdgBefore;
        uint256 bobPaid = usdg.balanceOf(bob) - bobUsdgBefore;
        assertGt(alicePaid, 0);
        assertGt(bobPaid, 0);
        // Priced at SERVICE: the DEP loss that landed while they waited is in the payout, not escaped.
        assertLt(alicePaid, DEP, "alice bore the in-flight loss");
        assertLt(bobPaid, DEP, "bob bore the in-flight loss");
        IEarnVault.Request memory a = earn.request(aliceId);
        IEarnVault.Request memory b = earn.request(bobId);
        assertEq(a.owner, address(0), "alice entry deleted");
        assertEq(b.owner, address(0), "bob entry deleted");
    }

    function test_processQueue_stopsAtTheHeadOnAPartial() public {
        _setAdapter();
        _deposit(alice, DEP);
        _deposit(bob, DEP);
        _sweep(DEP * 2);
        venue.setFrozen(true);
        uint256 aliceShares = earn.balanceOf(alice);
        uint256 bobShares = earn.balanceOf(bob);
        vm.prank(alice);
        earn.redeem(aliceShares, alice);
        vm.prank(bob);
        earn.redeem(bobShares, bob);

        venue.setFrozen(false);
        venue.setWithdrawableCap(1_000e6);

        uint256 served = earn.processQueue(2);
        assertEq(served, 0, "head not fully paid, so it is not counted as served");
        (uint256 head,) = earn.queue();
        assertEq(head, 1, "head stays alice");
        IEarnVault.Request memory r = earn.request(1);
        assertLt(r.shares, DEP, "alice was partially paid");
        assertGt(r.shares, 0, "alice still owed");
        IEarnVault.Request memory b = earn.request(2);
        assertEq(b.shares, bobShares, "bob was not stepped over");
    }

    function test_cancelQueued_returnsSharesToOwnerOnly() public {
        _setAdapter();
        _deposit(alice, DEP);
        _sweep(DEP);
        venue.setFrozen(true);
        vm.prank(alice);
        (, uint256 id) = earn.redeem(DEP, alice);

        vm.prank(bob);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        earn.cancelQueued(id);

        vm.prank(alice);
        earn.cancelQueued(id);
        assertEq(earn.balanceOf(alice), DEP, "escrowed shares returned");
        IEarnVault.Request memory r = earn.request(id);
        assertEq(r.shares, 0, "entry zeroed");
    }
}
