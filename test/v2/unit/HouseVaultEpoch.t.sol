// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HouseVaultTestBase} from "./HouseVaultBase.t.sol";
import {HouseVault} from "../../../src/v2/periphery/house/HouseVault.sol";
import {HouseVaultFactory} from "../../../src/v2/periphery/house/HouseVaultFactory.sol";
import {IExpiryCalendar} from "../../../src/v2/interfaces/IExpiryCalendar.sol";
import {IOrderBook} from "../../../src/v2/interfaces/IOrderBook.sol";
import {ISettlementOracle} from "../../../src/v2/interfaces/ISettlementOracle.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {V2Ids} from "../../../src/v2/interfaces/V2Ids.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";

/// @notice The boundary, the queues and the NAV that prices them (P8-06 criteria 1-5, 10, 11).
/// @dev THEY RUN AND THEY PASS. `forge test --match-contract HouseVaultEpochTest` was 39 passed, 0 failed, 0
///      skipped, exit 0 at 50f2e1e7d2a2afe737a010b3e1f4f8f6b11ceb9d, where this line was written; it is 42 at
///      590c0fa6c22f6dbc2b326c0c8d29f4f52ed2069b after T-586 added three tests. The three HouseVault unit suites
///      together were 96 passed, 0 failed at that earlier SHA.
///      T-586 NOTE ON THIS HEADER: a count is only true at a SHA, and this one had already drifted once. Quote
///      the SHA with the number or the next reader inherits a figure with nothing to check it against. This header previously read "AUTHORED, NOT RUN ... They compile", which was true when
///      it was written under the owner's build-mode directive of 2026-09-19 and stopped being true once the suites
///      were first executed in T-492 (91/91 before that row added anything). Corrected in T-559.
///
///      THE CORRECTION MATTERS BECAUSE THE OLD HEADER WAS LOAD-BEARING. A reader deciding whether to trust these
///      tests read "compiling was the only bar these suites ever cleared" and discounted them; the T-248 ledger
///      suspicion this row came from says exactly that, and told the next lane not to go looking for what broke
///      them. Nothing broke them. They had never been executed, and now they are.
contract HouseVaultEpochTest is HouseVaultTestBase {
    uint256 internal constant BOUNDARY_PRICE = 220_000_000; // USDG 6 dp per whole share

    /*//////////////////////////////////////////////////////////////
                  CRITERION 1 -- THE BOUNDARY REFUSES
    //////////////////////////////////////////////////////////////*/

    function test_rollEpoch_revertsBeforeTheEpochEnds() public {
        _finalizeBoundary(BOUNDARY_PRICE);
        vm.warp(house.epochEnd() - 1);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.TooEarly.selector, house.epochEnd()));
        house.rollEpoch();
    }

    /// @dev Permissionless roll may lag the clock. Once the epoch ends, its price can already be public and final;
    ///      a depositor must not choose to join that finished batch with the rate known in advance.
    function test_requestDeposit_revertsAtEpochEndWithFinalPriceKnown() public {
        uint40 end = house.epochEnd();
        _finalizeBoundary(BOUNDARY_PRICE);
        (V2Types.SettlementStatus status, uint256 price) = oracle.settlementPrice(address(nvda), end);
        assertEq(uint8(status), uint8(V2Types.SettlementStatus.Finalized), "boundary price is not final");
        assertEq(price, BOUNDARY_PRICE, "boundary price is not known");

        uint256 pendingBefore = house.pendingDepositUsdg();
        vm.prank(depositorA);
        vm.expectRevert(V2Errors.PastCutoff.selector);
        house.requestDeposit(address(usdg), DEP_USDG);
        assertEq(house.pendingDepositUsdg(), pendingBefore, "late deposit entered the finished batch");
    }

    /// @dev GUARD (b): the boundary price is not Finalized. Deleting this half lets the boundary price the vault off
    ///      a Pending -- i.e. uncorroborated -- number, which is the whole reason the oracle has a status at all.
    function test_rollEpoch_revertsWhileTheBoundaryPriceIsNotFinalized() public {
        _unfinalizedBoundary();
        vm.expectRevert(V2Errors.NotSettled.selector);
        house.rollEpoch();
    }

    /// @dev Held is not Finalized either: a guardian veto must not become a boundary.
    function test_rollEpoch_revertsOnAHeldBoundary() public {
        uint40 end = house.epochEnd();
        oracle.setSettlement(address(nvda), end, V2Types.SettlementStatus.Held, BOUNDARY_PRICE);
        vm.warp(end);
        vm.expectRevert(V2Errors.NotSettled.selector);
        house.rollEpoch();
    }

    /// @dev GUARD (a): the vault still holds an option. THIS IS THE ONE THAT MATTERS. Deleting it lets the boundary
    ///      price a vault holding options using only USDG + Stock balances -- the option would be valued at ZERO and
    ///      every withdrawal in that epoch would be underpaid while the remaining holders pocket the difference. The
    ///      guard is what makes "no option is ever valued" safe instead of wrong.
    function test_rollEpoch_revertsWhileTheVaultStillHoldsAnOption() public {
        _houseTakeOneLong();
        _finalizeBoundary(BOUNDARY_PRICE);
        vm.expectRevert(V2Errors.NotSettled.selector);
        house.rollEpoch();
    }

    /// @dev GUARD (a), the other half: no option held, but a live order is still resting. An unfilled bid is escrowed
    ///      USDG the vault does not control, so NAV would count money that can still turn into an option.
    function test_rollEpoch_revertsWhileALiveOrderRests() public {
        _housePlaceBid();
        _finalizeBoundary(BOUNDARY_PRICE);
        vm.expectRevert(V2Errors.NotSettled.selector);
        house.rollEpoch();
    }

    /// @dev Expiry makes a Bid unfillable but does not return its refundable USDG. The permissionless boundary must
    ///      therefore refuse until the equally permissionless prune has actually cancelled the order and returned
    ///      the escrow; correctness cannot depend on which caller wins that race.
    function test_rollEpoch_revertsWhileExpiredBidEscrowAwaitsPrune() public {
        _housePlaceBid();
        uint256[] memory ids = house.orderIdsOf(callId);
        assertEq(ids.length, 1, "fixture must leave exactly one bid");
        V2Types.Order memory bid = book.getOrders(ids)[0];
        assertEq(uint8(bid.kind), uint8(V2Types.OrderKind.Bid), "tracked order is not a bid");
        assertEq(bid.validUntil, house.epochEnd(), "bid must expire at the boundary");

        _finalizeBoundary(BOUNDARY_PRICE);
        vm.prank(keeper);
        assertTrue(ch.settle(callId), "series did not settle");
        assertGt(usdg.balanceOf(address(book)), 0, "book holds no refundable bid escrow");

        vm.expectRevert(V2Errors.NotSettled.selector);
        house.rollEpoch();

        uint256 vaultCashBefore = usdg.balanceOf(address(house));
        assertEq(book.prune(ids), 1, "permissionless prune did not cancel the expired bid");
        assertGt(usdg.balanceOf(address(house)), vaultCashBefore, "prune did not return the bid escrow");
        house.rollEpoch();
    }

    /// @dev The other half of defect A. {OrderBook.prune} refunds an expired Bid with pay-or-owe: when the USDG
    ///      transfer to the vault fails, the refund is recorded in `orderBook.owed` and the order is still cancelled,
    ///      so {_requireFlat} passes. NAV must count that owed refund, or the boundary prices the vault without the
    ///      escrow after all. Deleting the `orderBook.owed` term from {_nav} brings this test back red.
    function test_nav_countsABidRefundTheBookOwesTheVault() public {
        _housePlaceBid();
        uint256[] memory ids = house.orderIdsOf(callId);
        _finalizeBoundary(BOUNDARY_PRICE);
        vm.prank(keeper);
        assertTrue(ch.settle(callId), "series did not settle");
        uint256 navEscrowOut = house.nav();

        // Only the refund transfer to the vault fails; every other USDG transfer is untouched.
        vm.mockCallRevert(address(usdg), abi.encodeWithSelector(IERC20.transfer.selector, address(house)), "");
        assertEq(book.prune(ids), 1, "prune did not cancel the expired bid");
        vm.clearMockedCalls();

        uint256 owedToVault = book.owed(address(house));
        assertGt(owedToVault, 0, "the refund was not recorded as owed");
        assertEq(house.nav(), navEscrowOut + owedToVault, "NAV omits the refund the book owes the vault");
        house.rollEpoch();
    }

    /// @dev T-BUG-02 F1. A matched long+short pair with no live order nets to zero units and zero notional, but it is
    ///      still two options and collateral locked in the Clearinghouse, outside NAV. The pair is held THROUGH
    ///      settlement -- {Clearinghouse.close} is refused once settled, so a pair closed before expiry would never
    ///      reach the gap -- and a quoter `sync`, which is what the keeper's housekeeping sends, re-measures it on
    ///      the way. Restoring untrack-on-zero-notional in {HouseVault._record} brings this test back red: the pair
    ///      leaves `_tracked`, {_requireFlat} never looks at it, and the boundary rolls.
    /// @notice T-283. The OTHER release path, the one {_record}'s NatSpec names but nothing exercised:
    ///         "a series leaves {_tracked} only when a re-measure finds nothing held: AFTER {close} BEFORE
    ///         SETTLEMENT, or after the pair is redeemed."
    ///         {test_rollEpoch_revertsWhileAMatchedPairIsHeldThroughSettlement} proves the redeem half. This proves
    ///         the close half, which reaches {_record} through a different caller ({close} -> {_refresh}) and, unlike
    ///         redeem, runs while the series is still LIVE -- so `_holds` is the only thing that can release it.
    /// @dev    Why it matters that this is tested and not merely asserted in a comment: keying `_tracked` on what the
    ///         vault HOLDS is a latch. A series that never goes empty never leaves the list, and the permissionless
    ///         {rollEpoch} is then blocked for ever -- a worse failure than the mispricing the key change fixed. Two
    ///         release paths are claimed; both have to work, and only one of them was pinned.
    ///         WHAT THIS ADDS, MEASURED RATHER THAN ASSERTED. Breaking `_holds` to return `true` unconditionally
    ///         reds BOTH this test and the settlement one above, so the generic latch is already covered. What is
    ///         NOT covered without this test is the `close` CALLER: deleting the `_refresh(longId)` call from
    ///         {close} leaves the settlement test PASSING and reds only this one. That is the whole differential --
    ///         the release path that runs while the series is still live, reached through a caller nothing else
    ///         exercises.
    function test_rollEpoch_succeedsOnceAHeldPairIsClosedBeforeSettlement() public {
        _houseHoldsAMatchedPair();

        assertEq(house.seriesNotional(callId), 0, "a matched pair is not net exposure");
        assertEq(house.trackedSeries().length, 1, "but it is held, so it is tracked");

        // close() burns the pair back into collateral and re-measures through _refresh, all before settlement.
        vm.prank(quoter);
        house.close(callId, 10);

        (,, HouseVault.Exposure memory e) = house.exposure(callId);
        assertEq(e.longs, 0, "the longs are burnt");
        assertEq(e.shorts, 0, "and so are the shorts");
        assertEq(house.trackedSeries().length, 0, "nothing is held, so the series is released");

        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch(); // the latch opened: the boundary rolls
    }

    /// @dev The vault ends up holding 10 longs AND 10 shorts of `callId`, with no live order, then a routine keeper
    ///      `sync` re-measures. Same shape as the matched-pair case above, factored out so the two release paths are
    ///      exercised from an identical starting state.
    function _houseHoldsAMatchedPair() internal {
        _houseTakeOneLong(); // the vault holds 10 longs

        vm.prank(quoter);
        house.depositToClearinghouse(address(nvda), 1e18);
        uint256 floor_ = house.askFloorOf(callId, true);
        uint128 ask = uint128(
            floor_ > P3_00
                ? (floor_ + V2Constants.PRICE_TICK - 1) / V2Constants.PRICE_TICK * V2Constants.PRICE_TICK
                : P3_00
        );
        vm.prank(quoter);
        uint256 askId = house.place(callId, WRITE, ask, 10, 0);

        V2Types.TakeParams memory p;
        p.longId = callId;
        p.buying = true;
        p.orderIds = _ids(askId);
        p.units = 10;
        p.limitPrice = ask;
        p.recipient = mm;
        p.deadline = NO_DEADLINE;
        p.maxTotalFee = type(uint128).max;
        assertEq(_take(mm, p), 10, "mm did not take the vault's ask");
        assertEq(ch.balanceOf(address(house), callId), 10, "the vault does not hold the longs");
        assertEq(ch.balanceOf(address(house), V2Ids.shortIdOf(callId)), 10, "the vault does not hold the shorts");

        vm.prank(quoter);
        house.sync(_ids(callId));
    }

    function test_rollEpoch_revertsWhileAMatchedPairIsHeldThroughSettlement() public {
        _houseTakeOneLong(); // the vault holds 10 longs
        uint256 shortId = V2Ids.shortIdOf(callId);

        // The vault writes 10 into its own resting ask, which mm takes: the longs go to mm, the vault keeps the shorts.
        vm.prank(quoter);
        house.depositToClearinghouse(address(nvda), 1e18);
        uint256 floor_ = house.askFloorOf(callId, true);
        uint128 ask = uint128(
            floor_ > P3_00
                ? (floor_ + V2Constants.PRICE_TICK - 1) / V2Constants.PRICE_TICK * V2Constants.PRICE_TICK
                : P3_00
        );
        vm.prank(quoter);
        uint256 askId = house.place(callId, WRITE, ask, 10, 0);
        V2Types.TakeParams memory p;
        p.longId = callId;
        p.buying = true;
        p.orderIds = _ids(askId);
        p.units = 10;
        p.limitPrice = ask;
        p.recipient = mm;
        p.deadline = NO_DEADLINE;
        p.maxTotalFee = type(uint128).max;
        assertEq(_take(mm, p), 10, "mm did not take the vault's ask");
        assertEq(ch.balanceOf(address(house), callId), 10, "the vault does not hold the longs");
        assertEq(ch.balanceOf(address(house), shortId), 10, "the vault does not hold the shorts");

        vm.prank(quoter);
        house.sync(_ids(callId));
        assertEq(house.seriesNotional(callId), 0, "a matched pair is not net exposure");
        assertEq(house.trackedSeries().length, 1, "the held pair dropped out of the tracked set");

        _finalizeBoundary(BOUNDARY_PRICE);
        vm.prank(keeper);
        assertTrue(ch.settle(callId), "series did not settle");

        // CHANGED BY F10, DELIBERATELY. This used to assert that the boundary REVERTS here and only rolled once
        // somebody redeemed both legs by hand. That revert was also what let anyone hold the boundary shut with a
        // one-unit donation (see the donation test below), so {rollEpoch} now redeems the SETTLED legs itself.
        // The F1/T-309 invariant is unchanged and is asserted here as a VALUE rather than as a revert: the pair's
        // worth must land in the vault, not be walked past.
        uint256 cashBefore = usdg.balanceOf(address(house)) + ch.free(address(house), address(usdg));
        uint256 stockBefore = nvda.balanceOf(address(house)) + ch.free(address(house), address(nvda));
        house.rollEpoch();
        assertEq(ch.balanceOf(address(house), callId), 0, "the settled long was not redeemed by the boundary");
        assertEq(ch.balanceOf(address(house), shortId), 0, "the settled short was not redeemed by the boundary");
        uint256 cashAfter = usdg.balanceOf(address(house)) + ch.free(address(house), address(usdg));
        uint256 stockAfter = nvda.balanceOf(address(house)) + ch.free(address(house), address(nvda));
        assertTrue(cashAfter >= cashBefore || stockAfter >= stockBefore, "redeemed collateral left the vault");
    }

    /// @dev F10. ANYONE could hold the permissionless boundary shut by transferring ONE unit of a tracked series
    ///      into the vault after settlement: the ERC-1155 hooks accept any Clearinghouse token from anyone, and
    ///      {_requireFlat} refused while any balance of a tracked series was held. `roles.v8.json` marks
    ///      `HouseVault.rollEpoch` unrestricted precisely so nothing can block it, and a blocked boundary means
    ///      queued deposits and withdrawals sit unpriced for as long as the donor keeps it up.
    function test_rollEpoch_isNotHeldShutByADonationAfterSettlement() public {
        _houseTakeOneLong(); // the vault holds 10 longs of callId, so callId is tracked
        uint256 shortId = V2Ids.shortIdOf(callId);

        _finalizeBoundary(BOUNDARY_PRICE);
        vm.prank(keeper);
        assertTrue(ch.settle(callId), "series did not settle");

        // The vault's OWN legs go first, by the permissionless path that already existed. No {sync} afterwards:
        // the series stays in {_tracked} until a re-measure, which is exactly the window F10 exploits.
        ch.redeem(callId, address(house));
        ch.redeem(shortId, address(house));
        assertEq(ch.balanceOf(address(house), callId), 0, "the vault still holds its own longs");
        assertEq(ch.balanceOf(address(house), shortId), 0, "the vault still holds its own shorts");
        assertEq(house.trackedSeries().length, 1, "the series must still be tracked for this to be the F10 case");

        // A THIRD PARTY donates one unit. `_houseTakeOneLong` has mm WRITE and the vault TAKE, so mm holds the
        // SHORT leg; either leg is a unit of a tracked series and {_requireFlat} checks both.
        assertGt(ch.balanceOf(mm, shortId), 0, "fixture does not leave a third party holding a unit of the series");
        vm.prank(mm);
        ch.safeTransferFrom(mm, address(house), shortId, 1, "");
        assertEq(ch.balanceOf(address(house), shortId), 1, "the donation did not land");

        // THE POINT: the boundary rolls anyway, and the donated unit is REDEEMED rather than ignored.
        house.rollEpoch();
        assertEq(ch.balanceOf(address(house), shortId), 0, "the donated unit still sits in the vault");
    }

    function test_rollEpoch_succeedsOnceFlatAndFinalized() public {
        _finalizeBoundary(BOUNDARY_PRICE);
        uint40 endBefore = house.epochEnd();
        uint64 idBefore = house.epochId();
        house.rollEpoch();
        assertEq(house.epochId(), idBefore + 1, "epoch advanced");
        assertGt(house.epochEnd(), endBefore, "a new boundary was taken from the calendar");
    }

    /// @notice rollEpoch is PERMISSIONLESS: a stranger can close the epoch.
    function test_rollEpoch_isPermissionless() public {
        _finalizeBoundary(BOUNDARY_PRICE);
        vm.prank(stranger);
        house.rollEpoch();
        assertEq(house.epochId(), 1);
    }

    /*//////////////////////////////////////////////////////////////
            CRITERIA 2-3 -- NAV, AND THE QUEUE EXCLUSION
    //////////////////////////////////////////////////////////////*/

    /// @dev CRITERION 3, the one that is easy to get wrong. A queued deposit's assets are already in the contract.
    ///      If NAV counted them, the depositor's own money would raise the NAV that prices their own shares and they
    ///      would pay themselves. The second batch must be priced at the PRE-deposit NAV per share.
    function test_queuedDepositIsExcludedFromTheNavThatPricesIt() public {
        _requestDeposit(depositorA, DEP_USDG, 0);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        vm.prank(depositorA);
        house.claim();

        uint256 perShareBefore = _navPerShare();

        _requestDeposit(depositorB, DEP_USDG, 0);
        // NAV must not have moved: the queued money is excluded.
        assertEq(_navPerShare(), perShareBefore, "a queued deposit moved NAV per share");

        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        vm.prank(depositorB);
        house.claim();

        // B paid the pre-deposit rate, so B's shares are worth what B put in.
        assertApproxEqAbs(
            house.balanceOf(depositorB) * perShareBefore / 1e18, DEP_USDG, 1, "B was priced off an inflated NAV"
        );
    }

    /// @dev F3. A queued depositor's money is in the vault's WALLET from the moment the request lands. Nothing on
    ///      the quoting path used to keep the vault's writes inside its UNRESERVED collateral, so the QUOTER --
    ///      in ordinary operation, and the keeper does this automatically when `depositTokens` is set -- could
    ///      push the whole wallet into the Clearinghouse ledger, where a write LOCKS it. {_payReserved} tops up
    ///      from `clearinghouse.free` only, so {cancelDepositRequest} and {claim} then revert
    ///      `InsufficientCollateral` until the series settles: SEC-15's own statement, a user's money made
    ///      unreachable by a key they do not hold.
    function test_depositToClearinghouse_leavesQueuedDepositsInTheWallet() public {
        // The pool needs money of its OWN as well as the reserve, or there is nothing unreserved to deposit and
        // the clamp correctly refuses instead (that is the sibling test).
        _seedFirstEpoch();
        _requestDeposit(depositorB, DEP_USDG, 0);
        assertEq(house.pendingDepositUsdg(), DEP_USDG, "the queued deposit was not booked");
        uint256 wallet = usdg.balanceOf(address(house));
        assertGt(wallet, DEP_USDG, "the fixture must leave unreserved USDG as well as the reserve");

        // The quoter asks for the WHOLE wallet. It gets only the unreserved part.
        vm.prank(quoter);
        house.depositToClearinghouse(address(usdg), wallet);
        assertGe(
            usdg.balanceOf(address(house)), DEP_USDG, "the reserved USDG was pushed into lockable ledger collateral"
        );

        // And the reserve is still payable, which is the thing the depositor actually cares about.
        vm.prank(depositorB);
        house.cancelDepositRequest(depositorB);
        assertEq(house.pendingDepositUsdg(), 0, "the cancelled request is still booked");
    }

    /// @dev The other half of F3: with nothing unreserved left, the call refuses loudly rather than depositing
    ///      zero and reporting success. Mirrors `EarnVault.sweepToVenue`, which reverts `BadUnits` on an empty
    ///      sweep for the same reason.
    function test_depositToClearinghouse_refusesWhenNothingIsUnreserved() public {
        uint256 wallet = usdg.balanceOf(address(house));
        if (wallet != 0) {
            vm.prank(quoter);
            house.depositToClearinghouse(address(usdg), wallet);
        }
        _requestDeposit(depositorA, DEP_USDG, 0);
        assertEq(usdg.balanceOf(address(house)), DEP_USDG, "the wallet should hold exactly the reserve");
        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadUnits.selector);
        house.depositToClearinghouse(address(usdg), DEP_USDG);
    }

    /// @dev CRITERION 2: nothing on the NAV path prices an option or reads `spot()`. Proven behaviourally: the
    ///      boundary succeeds with the SPOT ORACLE MADE UNREADABLE. If any NAV path touched spot, this reverts.
    function test_navPathNeverReadsSpot() public {
        _requestDeposit(depositorA, DEP_USDG, DEP_STOCK);
        _finalizeBoundary(BOUNDARY_PRICE);
        oracle.setSpot(address(nvda), false, 0, 0); // spot() now reverts NoSource
        house.rollEpoch();
        vm.prank(depositorA);
        house.claim();
        assertGt(house.balanceOf(depositorA), 0, "the boundary needed spot");
    }

    /// @dev A deposit and a withdrawal queued mid-epoch change nothing about the running epoch.
    function test_queuesDoNotDisturbTheRunningEpoch() public {
        _requestDeposit(depositorA, DEP_USDG, 0);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        vm.prank(depositorA);
        house.claim();

        uint256 supplyBefore = house.totalSupply();
        uint256 perShareBefore = _navPerShare();

        _requestDeposit(depositorB, DEP_USDG, 0);
        uint256 halfA = house.balanceOf(depositorA) / 2;
        vm.prank(depositorA);
        house.requestWithdraw(halfA);

        assertEq(house.totalSupply(), supplyBefore, "supply moved mid-epoch");
        assertEq(_navPerShare(), perShareBefore, "NAV per share moved mid-epoch");
    }

    /*//////////////////////////////////////////////////////////////
              CRITERION 4 -- IN-KIND, PRO RATA, DUST RETAINED
    //////////////////////////////////////////////////////////////*/

    function test_withdrawalIsPaidInKindProRataWithDustRetained() public {
        _requestDeposit(depositorA, DEP_USDG, DEP_STOCK);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        vm.prank(depositorA);
        house.claim();

        uint256 shares = house.balanceOf(depositorA);
        uint256 usdgPool = usdg.balanceOf(address(house));
        uint256 stockPool = nvda.balanceOf(address(house));

        vm.prank(depositorA);
        house.requestWithdraw(shares / 3);

        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();

        uint256 usdgBefore = usdg.balanceOf(depositorA);
        uint256 stockBefore = nvda.balanceOf(depositorA);
        vm.prank(depositorA);
        house.claim();

        // BOTH assets move, and neither is swapped for the other.
        assertGt(usdg.balanceOf(depositorA), usdgBefore, "no USDG leg");
        assertGt(nvda.balanceOf(depositorA), stockBefore, "no Stock leg");
        // Floor division: the vault keeps at least as much as the exact share would leave.
        assertGe(usdg.balanceOf(address(house)), usdgPool - usdgPool / 3, "USDG dust was not retained");
        assertGe(nvda.balanceOf(address(house)), stockPool - stockPool / 3, "Stock dust was not retained");
    }

    /*//////////////////////////////////////////////////////////////
              SEC-27 -- CLAIM DUST MUST NOT STRAND IN `owed`
    //////////////////////////////////////////////////////////////*/

    /// @dev Two holders withdraw in one batch, so each slice floor-divides. Before SEC-27 every slice was taken
    ///      from the UNCHANGED batch totals, so a remainder stayed in `owedUsdg` / `owedStock` that nothing could
    ///      reach: {claim} only ever decrements those reserves by what it pays, and {_nav} excludes both, so the
    ///      remainder was neither payable to anyone nor returned to the pool -- stranded once per epoch, forever.
    ///
    ///      THE TEST PROVES THE DUST EXISTS BEFORE IT PROVES IT IS GONE. It recomputes the naive fixed-total split
    ///      from the same three numbers the contract had; if those two halves already summed to the whole reserve
    ///      there would be nothing to strand and the final assertion would pass for the wrong reason, so that case
    ///      is failed explicitly rather than skipped.
    ///
    ///      RED ON THE OLD CODE: `owedUsdg()` finishes at the remainder instead of zero.
    function test_claim_leavesNoWithdrawalDustStrandedInTheOwedReserve() public {
        _requestDeposit(depositorA, DEP_USDG, DEP_STOCK);
        _requestDeposit(depositorB, DEP_USDG, 0);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        vm.prank(depositorA);
        house.claim();
        vm.prank(depositorB);
        house.claim();
        assertEq(house.owedUsdg(), 0, "the fixture started with something already owed");
        assertEq(house.owedStock(), 0, "the fixture started with stock already owed");

        // Deliberately uneven, and neither a whole nor a half of the supply: the slices must floor.
        // The balances are READ BEFORE THE PRANK on purpose: `vm.prank` fences the next CALL, and
        // `house.balanceOf(...)` written inside the argument list IS that call -- it eats the prank and
        // `requestWithdraw` then runs as the test contract, which holds no shares. Same idiom as
        // {test_withdrawalIsPaidInKindProRataWithDustRetained} above.
        uint256 sharesOfA = house.balanceOf(depositorA);
        uint256 sharesOfB = house.balanceOf(depositorB);
        vm.prank(depositorA);
        house.requestWithdraw(sharesOfA / 3);
        vm.prank(depositorB);
        house.requestWithdraw((sharesOfB * 2) / 7);

        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();

        (, uint256 sharesA) = house.withdrawRequestOf(depositorA);
        (, uint256 sharesB) = house.withdrawRequestOf(depositorB);
        uint256 reservedUsdg = house.owedUsdg();
        uint256 reservedStock = house.owedStock();
        assertGt(reservedUsdg, 0, "the batch reserved no USDG");
        assertGt(reservedStock, 0, "the batch reserved no Stock");

        // The dust the old code left behind, computed the way the old code computed the slices.
        uint256 naiveUsdg =
            (reservedUsdg * sharesA) / (sharesA + sharesB) + (reservedUsdg * sharesB) / (sharesA + sharesB);
        assertLt(naiveUsdg, reservedUsdg, "no USDG dust in this fixture -- the assertion below would prove nothing");

        vm.prank(depositorA);
        house.claim();
        vm.prank(depositorB);
        house.claim();

        // Every wei the batch reserved has left the reserve. Nothing is stranded and nothing was overpaid.
        assertEq(house.owedUsdg(), 0, "USDG dust stranded in the owed reserve");
        assertEq(house.owedStock(), 0, "Stock dust stranded in the owed reserve");
    }

    /*//////////////////////////////////////////////////////////////
            SEC-29 -- THE FACTORY'S OWN SOURCES ARE IMMUTABLE
    //////////////////////////////////////////////////////////////*/

    /// @dev `orderBook_` was the one constructor argument with no zero-check, while `calendar_`, `oracle_` and
    ///      `splitter_` all had one. It is immutable and is handed to EVERY vault the factory deploys, and no
    ///      setter exists on either contract, so a zero there is not a bad listing -- it is a factory that can
    ///      only ever produce vaults whose book calls revert.
    ///
    ///      RED ON THE OLD CODE: the constructor returns a live factory instead of reverting.
    function test_factoryConstructor_refusesAZeroOrderBook() public {
        vm.expectRevert(V2Errors.NoSource.selector);
        new HouseVaultFactory(
            IOrderBook(address(0)),
            address(manager),
            IExpiryCalendar(address(calendar)),
            ISettlementOracle(address(oracle)),
            splitterAddr
        );
    }

    /// @dev The positive control for the test above: the same call with a real book still builds, so the revert
    ///      there is the zero address and not the fixture.
    function test_factoryConstructor_acceptsARealOrderBook() public {
        HouseVaultFactory fresh = new HouseVaultFactory(
            IOrderBook(address(book)),
            address(manager),
            IExpiryCalendar(address(calendar)),
            ISettlementOracle(address(oracle)),
            splitterAddr
        );
        assertEq(address(fresh.orderBook()), address(book), "the factory did not keep its book");
    }

    /*//////////////////////////////////////////////////////////////
               CRITERION 5 -- FIRST-DEPOSITOR INFLATION
    //////////////////////////////////////////////////////////////*/

    /// @dev The classic attack is: be the first depositor for 1 wei, donate a large balance directly, and every later
    ///      depositor rounds to zero shares. Here the FIRST batch is priced at a FIXED 1:1 rather than off NAV, so a
    ///      donation before that boundary buys the donor nothing, and MIN_SHARES dead shares blunt the rounding.
    function test_firstBatchIsPricedOneToOneDespiteADonation() public {
        _requestDeposit(depositorA, DEP_USDG, 0);

        // The attacker donates straight into the contract -- anyone can, and it lands in balanceOf.
        vm.prank(depositorB);
        usdg.transfer(address(house), DEP_USDG * 5);

        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        vm.prank(depositorA);
        house.claim();

        assertEq(house.balanceOf(depositorA), DEP_USDG, "first batch was not priced 1 share per 1 USDG");
        // NOT address(0): OZ ERC20 cannot credit the zero address, so this assertion was unsatisfiable in
        // BOTH directions before T-251 -- the mint reverted, and had it somehow succeeded balanceOf(address(0))
        // is always 0. The dead shares live at DEAD_SHARES.
        assertEq(house.balanceOf(house.DEAD_SHARES()), house.MIN_SHARES(), "dead shares were not credited");
        assertEq(house.balanceOf(address(0)), 0, "address(0) can never hold a balance in OZ ERC20");
    }

    /// @dev T-586 / T-255. THE DEAD-SHARE MINT NEEDS A TEST THAT IS NOT ABOUT A DONATION. Until this test the
    ///      only assertion that {MIN_SHARES} is credited to {DEAD_SHARES} lived inside
    ///      {test_firstBatchIsPricedOneToOneDespiteADonation}, whose premise is an attacker transfer. That
    ///      couples a plain accounting fact -- the first roll mints the dead shares -- to a scenario that can
    ///      change for reasons of its own, and the mint sits behind the `dValue != 0` arm of the first-batch
    ///      branch, so a future edit could stop reaching it while the donation test still passed for its own
    ///      reasons. T-255 asked for the direct assertion; this is it, with no donation anywhere in it.
    function test_firstRollCreditsTheDeadSharesWithoutADonation() public {
        assertEq(house.balanceOf(house.DEAD_SHARES()), 0, "precondition: no dead shares before the first roll");

        _requestDeposit(depositorA, DEP_USDG, 0);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();

        assertEq(
            house.balanceOf(house.DEAD_SHARES()),
            house.MIN_SHARES(),
            "the first roll did not credit MIN_SHARES to DEAD_SHARES"
        );
    }

    /*//////////////////////////////////////////////////////////////
              CRITERION 10 -- PERFORMANCE FEE AND THE HWM
    //////////////////////////////////////////////////////////////*/

    function test_performanceFee_isNotChargedOnALosingEpoch() public {
        _seedFirstEpoch();
        vm.prank(admin);
        house.setPerformanceFeeBps(1000);

        uint256 splitterBefore = usdg.balanceOf(splitterAddr);
        // A losing epoch: take value out of the pool by lowering the boundary price of the stock leg.
        _finalizeBoundary(BOUNDARY_PRICE / 2);
        house.rollEpoch();
        assertEq(usdg.balanceOf(splitterAddr), splitterBefore, "a losing epoch was charged");
    }

    function test_performanceFee_recoveryToTheOldMarkIsFree() public {
        _seedFirstEpoch();
        vm.prank(admin);
        house.setPerformanceFeeBps(1000);

        _finalizeBoundary(BOUNDARY_PRICE / 2);
        house.rollEpoch();
        uint256 splitterAfterLoss = usdg.balanceOf(splitterAddr);

        // Back to exactly the old mark: the gain since the mark is zero, so the fee is zero.
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        assertEq(usdg.balanceOf(splitterAddr), splitterAfterLoss, "a recovery to the old mark was charged");
    }

    function test_performanceFee_ceilingIsCompiledIn() public {
        // THE CEILING IS READ FIRST, AND BOTH CHEATCODES ARE THE REASON. Written inline as an argument,
        // `house.PERFORMANCE_FEE_CEIL_BPS()` is evaluated BEFORE the call it belongs to, so it consumed the
        // `vm.prank` AND the `vm.expectRevert` -- the expectation bound to that view, which of course does not
        // revert, and the failure read "next call did not revert as expected". The ceiling was never tested.
        uint16 overCeiling = house.PERFORMANCE_FEE_CEIL_BPS() + 1;
        vm.prank(admin);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        house.setPerformanceFeeBps(overCeiling);
    }

    /// @notice The fee can only ever reach the immutable splitter.
    function test_performanceFee_goesOnlyToTheImmutableSplitter() public view {
        assertEq(house.splitter(), splitterAddr);
    }

    /*//////////////////////////////////////////////////////////////
              CRITERION 11 -- THE GUARDIAN PAUSE IS NARROW
    //////////////////////////////////////////////////////////////*/

    /// @dev A brake that traps depositor money is not a brake. The pause blocks the three entry points that can open
    ///      or grow a position and NOTHING else -- in particular it must never block the boundary or a claim.
    function test_quotingPause_doesNotBlockTheBoundaryOrTheDepositorPaths() public {
        _requestDeposit(depositorA, DEP_USDG, 0);
        vm.prank(guardian);
        house.setQuotingPaused(true);

        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch(); // not blocked
        vm.prank(depositorA);
        house.claim(); // not blocked

        uint256 allA = house.balanceOf(depositorA);
        vm.prank(depositorA);
        house.requestWithdraw(allA); // not blocked

        // and the unwinding lane stays open
        vm.prank(quoter);
        house.sync(new uint256[](0));
        vm.prank(quoter);
        house.claimOwed();
        vm.prank(quoter);
        house.cancel(new uint256[](0));
    }

    function test_quotingPause_blocksPlace() public {
        vm.prank(guardian);
        house.setQuotingPaused(true);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.TradingPaused.selector);
        house.place(callId, BID, P2_00, 1, 0);
    }

    function test_quotingPause_blocksTake() public {
        vm.prank(guardian);
        house.setQuotingPaused(true);
        V2Types.TakeParams memory p;
        p.longId = callId;
        p.recipient = address(house);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.TradingPaused.selector);
        house.take(p);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev One full epoch so the vault has supply and a high-water mark to compare against.
    /// @dev T-586 / T-439 suspicion 1: "measure gas of rollEpoch against a long _tracked before trusting the
    ///      F10 fix under load". {_tracked} only ever SHRINKS through {_refresh}, whose callers -- `cancel`
    ///      (:857), `close` (:904) and `sync` (:915) -- are all `restricted`, so nothing PERMISSIONLESS removes
    ///      an entry while `rollEpoch` is permissionless by design and walks the array three times per boundary:
    ///      {_redeemSettled} (:689), {_requireFlat} (:702) and the NAV path. These two tests measure the
    ///      marginal cost of one tracked series so the growth is a NUMBER rather than an adjective.
    function test_gas_rollEpoch_withOneTrackedSeries() public {
        uint256 used = _measureRollWithTracked(1);
        console2.log("rollEpoch gas, 1 tracked series:", used);
        assertGt(used, 0, "no gas measured");
    }

    function test_gas_rollEpoch_withThreeTrackedSeries() public {
        uint256 used = _measureRollWithTracked(3);
        console2.log("rollEpoch gas, 3 tracked series:", used);
        assertGt(used, 0, "no gas measured");
    }

    /// @dev Builds `n` distinct settled series the vault holds, then measures one {HouseVault.rollEpoch}.
    function _measureRollWithTracked(uint256 n) internal returns (uint256 used) {
        _seedFirstEpoch();
        vm.prank(quoter);
        house.depositToClearinghouse(address(usdg), 5_000e6);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            // Strikes must sit on the market's strikeTick (1.00 USDG) AND inside the spot band around 220,
            // so this steps DOWN from CALL_STRIKE in whole-USDG ticks rather than by PRICE_TICK.
            uint128 strike = uint128(CALL_STRIKE - i * STRIKE_TICK);
            ids[i] = ch.createSeries(address(nvda), false, strike, FRI_2026_09_18);
            uint256 askId = _place(mm, ids[i], WRITE, P3_00, 10);
            V2Types.TakeParams memory p;
            p.longId = ids[i];
            p.buying = true;
            p.orderIds = _ids(askId);
            p.units = 10;
            p.limitPrice = P3_00;
            p.recipient = address(house);
            p.deadline = NO_DEADLINE;
            p.maxTotalFee = type(uint128).max;
            vm.prank(quoter);
            house.take(p);
        }
        vm.prank(quoter);
        house.sync(ids);
        assertEq(house.trackedSeries().length, n, "the fixture did not track n series");

        _finalizeBoundary(BOUNDARY_PRICE);
        for (uint256 i; i < n; ++i) {
            vm.prank(keeper);
            ch.settle(ids[i]);
        }
        uint256 before = gasleft();
        house.rollEpoch();
        used = before - gasleft();
    }

    function _seedFirstEpoch() internal {
        _requestDeposit(depositorA, DEP_USDG, DEP_STOCK);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        vm.prank(depositorA);
        house.claim();
    }

    /*//////////////////////////////////////////////////////////////
       F-CP-04 / F-CP-07 -- RESERVED BALANCES AND THE DUST CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @dev F-CP-04. `rollEpoch` is PERMISSIONLESS on purpose -- roles.v8.json leaves it unrestricted precisely so
    ///      nothing can block the boundary -- and it used to subtract the reserved balances from the bare WALLET
    ///      balance with checked arithmetic. `depositToClearinghouse` is QUOTER-held and has no reserve carve-out,
    ///      so ordinary quoting drops the wallet below what is already owed to a former shareholder and the next
    ///      boundary panics 0x11. No attacker is involved. Deleting the saturating form in either pool expression
    ///      brings this test back red.
    function test_rollEpoch_survivesReservesExceedingTheWallet() public {
        // BOTH holders are seeded in the first epoch. The second withdrawal request below has to come from an
        // account that does NOT already hold a matured one -- see the note at that line.
        _requestDeposit(depositorA, DEP_USDG, DEP_STOCK);
        _requestDeposit(depositorB, DEP_USDG, 0);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        vm.prank(depositorA);
        house.claim();
        vm.prank(depositorB);
        house.claim();

        uint256 shares = house.balanceOf(depositorA);
        vm.prank(depositorA);
        house.requestWithdraw(shares / 2);

        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();

        // The slice is reserved and DELIBERATELY left unclaimed: owed money is still sitting in the wallet.
        uint256 owed = house.owedUsdg();
        assertGt(owed, 0, "no USDG was reserved for the withdrawal");

        // The quoter posts the whole wallet into the ledger. Nothing stops it going below the reserve.
        //
        // THE BALANCE IS READ INTO A LOCAL FIRST, AND THAT IS THE WHOLE FIX. Written inline as an argument,
        // `usdg.balanceOf(address(house))` is evaluated BEFORE the call it is an argument to, so it consumed the
        // `vm.prank` and `depositToClearinghouse` arrived from the TEST CONTRACT instead of `quoter`. The
        // manager then refused it -- `canCall(HouseVaultEpochTest, ...)` -- and the test failed `NotAuthorized`,
        // which reads as the vault refusing an authorised quoter. It was never the contract.
        // F3 CLOSED THE ROUTE THIS TEST USED, SO THE CONDITION IS NOW CONSTRUCTED DIRECTLY.
        // It used to post the whole wallet through `depositToClearinghouse`, which had no reserve carve-out.
        // That call now clamps to the UNRESERVED balance, so it can no longer drive the wallet below `owed` --
        // which is the point of F3. The saturating arithmetic in {_nav} and {rollEpoch} is a SEPARATE defence
        // and must stay proven: reserves can still exceed the wallet by other routes, and a guard that can no
        // longer reach its subject is a false green, not a fixed bug. So the balance is set directly here.
        //
        // The clamp is asserted first, so this test also fails if F3 is deleted -- it does not just stop
        // exercising it.
        uint256 walletBefore = usdg.balanceOf(address(house));
        vm.prank(quoter);
        house.depositToClearinghouse(address(usdg), walletBefore);
        assertGe(usdg.balanceOf(address(house)), owed, "F3: the clamp let the reserve into the ledger");
        deal(address(usdg), address(house), owed / 2);
        assertLt(usdg.balanceOf(address(house)), owed, "the wallet is not actually short of the reserve");

        // A second request so the withdrawal-pool branch is reached at the next boundary. IT COMES FROM
        // depositorB, NOT depositorA, AND THAT IS NOT A DETAIL. `HouseVault.requestWithdraw` refuses a new request
        // from an account that still holds a MATURED, UNCLAIMED one -- `HouseVault.sol:389`,
        // `r.shares != 0 && r.epochId != epochId` -> TooEarly -- and this test deliberately leaves depositorA's
        // request unclaimed, because its whole point is that the owed money is still sitting in the wallet. Asking
        // depositorA again therefore reverts TooEarly by design; the guard is correct and the test was wrong.
        // Claiming first would empty the reserve and destroy the condition under test, so a second holder is the
        // only way to reach the withdrawal-pool branch with the reserve still outstanding.
        // The balance is read into a local first for the same cheatcode reason as above.
        uint256 restB = house.balanceOf(depositorB);
        vm.prank(depositorB);
        house.requestWithdraw(restB);

        // THE PROTECTED FACT: the permissionless boundary still rolls.
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        assertGt(house.epochEnd(), 0, "the boundary did not complete");
    }

    /// @dev F-CP-07. `claim` deleted both priced requests and THEN refused when every output was zero, so the
    ///      refusal reverted its own deletes: the request survived with an epoch id in the past, and deposit,
    ///      withdraw and cancel all then refused it as TooEarly. Sub-one-share dust bricked the account. A matured
    ///      request that prices to zero must be RETIRED, not refused.
    function test_claim_retiresAMaturedRequestThatPricesToZero() public {
        // A USDG-ONLY VAULT, AND THAT IS WHAT MAKES THE PREMISE TRUE. `claim` floors each leg separately --
        // `HouseVault.sol:435-436`, `mulDiv(e.withdrawUsdg, w.shares, e.withdrawShares)` and the same for stock --
        // so a one-unit holder is paid zero of an asset only when that asset's pool is smaller than the share
        // count. With `_seedFirstEpoch`'s DEP_STOCK in the vault the stock pool is 1e19 against ~1.22e10 shares,
        // so the stock leg pays 819672063 wei: correct pro-rata, not a bug, and the assertion below was measuring
        // it. T-251 (`credit dead shares to DEAD_SHARES`) moved the share scale after this test was written, which
        // is when the "zero of BOTH assets" premise stopped holding. Depositing USDG only restores it honestly --
        // the stock pool is empty, so `withdrawStock` is 0 and the leg is genuinely zero rather than merely small.
        _requestDeposit(depositorA, DEP_USDG, 0);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        vm.prank(depositorA);
        house.claim();

        _requestDeposit(depositorB, DEP_USDG, 0);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        vm.prank(depositorB);
        house.claim();

        // A whale withdraws everything and depositorA withdraws ONE share unit, so floor division gives the
        // one-unit holder zero of BOTH assets -- ordinary arithmetic, not a contrived state.
        uint256 allB = house.balanceOf(depositorB);
        vm.prank(depositorB);
        house.requestWithdraw(allB);
        vm.prank(depositorA);
        house.requestWithdraw(1);

        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();

        uint256 usdgBefore = usdg.balanceOf(depositorA);
        uint256 stockBefore = nvda.balanceOf(depositorA);

        // It must SUCCEED while paying nothing.
        vm.prank(depositorA);
        house.claim();
        assertEq(usdg.balanceOf(depositorA), usdgBefore, "a zero-priced claim paid USDG");
        assertEq(nvda.balanceOf(depositorA), stockBefore, "a zero-priced claim paid stock");

        // And the request is GONE, so the account can act again instead of being stuck forever.
        uint256 againA = house.balanceOf(depositorA);
        vm.prank(depositorA);
        house.requestWithdraw(againA);
    }

    /// @dev The other half of the same refusal, kept: a call with NO matured request is still refused. Without this
    ///      the fix above would read as "claim never reverts", which is not what changed.
    function test_claim_stillRefusesWhenNothingMatured() public {
        _seedFirstEpoch();
        vm.expectRevert(V2Errors.BadUnits.selector);
        vm.prank(depositorB);
        house.claim();
    }

    /*//////////////////////////////////////////////////////////////
          SEC-17 -- NO FIXED-RATE REOPENING AGAINST A LIVE SUPPLY
    //////////////////////////////////////////////////////////////*/

    /// @dev SEC-17. A boundary at `navNow == 0` with shares outstanding used to mint the batch at the fixed 1:1 rate,
    ///      so the wiped-out holders -- who keep their full share count -- owned supply/(supply + minted) of the
    ///      newcomer's money. The batch must now be REFUSED: no shares minted, and every request returned in kind.
    ///
    ///      THE WIPE IS A CHEAT, AND THAT IS THE HONEST FORM. No permissionless sequence reaching an exact zero NAV
    ///      is known (the row calls SEC-17 latent, not live), so the vault's own wallet burns its USDG. The seeding
    ///      epoch is USDG-ONLY so that burn is a total loss: the Stock the second depositor queues is reserved and
    ///      excluded from NAV, so the stock leg of NAV is zero too.
    ///
    ///      RED ON THE OLD CODE: `minted = navNow == 0 ? dValue : ...` mints depositorB DEP_USDG + DEP_STOCK-value
    ///      shares, the supply assertion fails, and depositorB's claim returns shares instead of assets.
    function test_rollEpoch_refusesABatchAtTotalLossAndClaimReturnsItInKind() public {
        _requestDeposit(depositorA, DEP_USDG, 0);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        vm.prank(depositorA);
        house.claim();

        // Total loss. Read into a local first: an inline `balanceOf` would consume the prank.
        uint256 wallet = usdg.balanceOf(address(house));
        vm.prank(address(house));
        usdg.burn(wallet);

        _requestDeposit(depositorB, DEP_USDG, DEP_STOCK);
        uint256 supplyBefore = house.totalSupply();
        assertGt(supplyBefore, 0, "premise: shares must be outstanding");

        // THE BOUNDARY STILL ROLLS -- a revert here would let one queued request stop every epoch.
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();

        assertEq(house.totalSupply(), supplyBefore, "a batch was minted against a wiped-out supply");
        assertEq(house.pendingDepositUsdg(), 0, "the refused USDG was left pending");
        assertEq(house.pendingDepositStock(), 0, "the refused Stock was left pending");
        assertEq(house.owedUsdg(), DEP_USDG, "the refused USDG was not moved into the owed reserve");
        assertEq(house.owedStock(), DEP_STOCK, "the refused Stock was not moved into the owed reserve");

        uint256 usdgBefore = usdg.balanceOf(depositorB);
        uint256 stockBefore = nvda.balanceOf(depositorB);
        vm.prank(depositorB);
        house.claim();

        assertEq(house.balanceOf(depositorB), 0, "a refused batch paid out shares");
        assertEq(usdg.balanceOf(depositorB) - usdgBefore, DEP_USDG, "the USDG was not returned in full");
        assertEq(nvda.balanceOf(depositorB) - stockBefore, DEP_STOCK, "the Stock was not returned in full");
        assertEq(house.owedUsdg(), 0, "the owed USDG reserve was not released");
        assertEq(house.owedStock(), 0, "the owed Stock reserve was not released");
    }

    /// @dev The other side of the same line, so the refusal cannot pass by refusing everything: an ordinary batch
    ///      at a non-zero NAV is still minted, and its claim still pays shares and no assets.
    function test_rollEpoch_stillMintsABatchAtANonZeroNav() public {
        _seedFirstEpoch();
        _requestDeposit(depositorB, DEP_USDG, 0);
        uint256 supplyBefore = house.totalSupply();

        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        assertGt(house.totalSupply(), supplyBefore, "an ordinary batch was refused");
        assertEq(house.owedUsdg(), 0, "an ordinary batch was moved into the owed reserve");

        uint256 usdgBefore = usdg.balanceOf(depositorB);
        vm.prank(depositorB);
        house.claim();
        assertGt(house.balanceOf(depositorB), 0, "an ordinary batch paid no shares");
        assertEq(usdg.balanceOf(depositorB), usdgBefore, "an ordinary batch was refunded");
    }

    /*//////////////////////////////////////////////////////////////
       T-492 / T-OP-064 -- THE SEC-14 RESIDUAL: MEASURED REAL, THEN CLOSED
    //////////////////////////////////////////////////////////////*/

    /// @dev A series expiring after {epochEnd} can reach this vault only by transfer -- {place}/{replace}/{take}
    ///      refuse it BadExpiry and the receipt hooks accept any Clearinghouse token from anyone. `mm` writes one
    ///      unit against its own ledger collateral and sends the long leg here. The operator grant is FIXTURE
    ///      AUTHORIZATION, not part of the scenario: `Clearinghouse.mint` needs both an allowlisted minter and the
    ///      writer's consent (`Clearinghouse.sol:634-635`), and this test contract is the minter.
    function _transferInALateLong() internal returns (uint256 lateId, uint40 later) {
        uint40 end = house.epochEnd();
        later = calendar.nextExpiry(end + 1, true);
        assertGt(later, end, "fixture did not produce an expiry beyond the boundary");
        lateId = ch.createSeries(address(nvda), false, CALL_STRIKE, later);
        vm.prank(mm);
        ch.setOperator(address(this), true);
        ch.mint(lateId, 1, mm, mm);
        vm.prank(mm);
        ch.safeTransferFrom(mm, address(house), lateId, 1, "");
        assertEq(ch.balanceOf(address(house), lateId), 1, "the transfer did not land");
        assertEq(house.trackedSeries().length, 0, "a bare transfer must not track anything by itself");
    }

    /// @notice SEC-14 launch-phase action (b), first written by T-492 as the scenario that decided whether the
    ///         residual was real. It was: a QUOTER {sync} on the transferred series put it into {_tracked} and
    ///         {_requireFlat} then held the boundary until THAT series settled (the T-492 shape of this test asserted
    ///         exactly that). T-OP-064 closed it: {sync} now consults the epoch guard exactly as {place} does.
    /// @dev    THE SCENARIO IS UNCHANGED, only the verdict. Same two doors -- the receipt hook still accepts the
    ///         token, and sync is still the QUOTER's re-measure -- but the second door refuses by name, so the
    ///         boundary that was due at `end` rolls on time with the donated unit still sitting here, untracked.
    ///         PROVE BY BREAKING: delete `_seriesInEpoch(longIds[i]);` from {HouseVault.sync} and this reds at the
    ///         `expectRevert`, and would red again at `rollEpoch` with NotSettled.
    function test_rollEpoch_whenASeriesExpiringAfterTheBoundaryIsTransferredIn_syncRefusesAndTheBoundaryRolls()
        public
    {
        _seedFirstEpoch();
        (uint256 lateId, uint40 later) = _transferInALateLong();

        // THE SECOND DOOR IS SHUT. The whole batch reverts and nothing is re-measured.
        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadExpiry.selector);
        house.sync(_ids(lateId));
        assertEq(house.trackedSeries().length, 0, "a refused sync must not track");

        // THE BOUNDARY. The epoch's own price is Finalized; the donated series is unexpired and unsettled, and it
        // does not matter: `_requireFlat` walks {_tracked}, and the series never entered it.
        _finalizeBoundary(BOUNDARY_PRICE);
        assertLt(block.timestamp, later, "the transferred series must still be unexpired at the boundary");
        uint64 idBefore = house.epochId();
        vm.prank(stranger);
        house.rollEpoch();
        assertEq(house.epochId(), idBefore + 1, "the boundary did not roll on time");
        assertEq(ch.balanceOf(address(house), lateId), 1, "the donated unit is still held, and still untracked");
        assertEq(house.trackedSeries().length, 0, "rolling did not track it either");
    }

    /// @notice T-492 asked whether {sync} could UNTRACK the donated series once it was tracked (it could not, so the
    ///         residual was a delay, not a lock). Post-fix the question is moot: {sync} never tracks it, and a second
    ///         sync is refused the same way. What remains true, and is pinned here, is that nothing about the
    ///         refusal moves the unit -- it stays in the vault until the series settles and someone redeems it.
    function test_syncNeverTracksATransferredSeries_soThereIsNothingToUntrack() public {
        _seedFirstEpoch();
        (uint256 lateId,) = _transferInALateLong();

        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadExpiry.selector);
        house.sync(_ids(lateId));
        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadExpiry.selector);
        house.sync(_ids(lateId));
        assertEq(house.trackedSeries().length, 0, "two refusals, nothing tracked");
        assertEq(ch.balanceOf(address(house), lateId), 1, "the unit left the vault by itself");
    }

    /// @notice LOCK OR DELAY became NEITHER. T-492 showed the boundary recovering only once the donated series
    ///         itself settled, a whole extra expiry cycle late. Post-fix the boundary never waited; what the
    ///         settlement path is now for is the CLEANUP of the donated unit, and it needs no QUOTER: once the late
    ///         series settles, `Clearinghouse.redeem` is permissionless for any holder that has not opted out of
    ///         third-party redemption (`Clearinghouse.sol:762-764`, `_mayRedeem`), and this vault has not.
    /// @dev    Note WHICH boundary rolls, and when: the epoch that was due at `end` closes AT `end`, with every
    ///         depositor and withdrawer queued for it served on time. That was the cost of the residual, and it is gone.
    function test_aDonatedSeriesNeverHoldsTheBoundary_andIsRedeemedByAnyoneOnceItSettles() public {
        _seedFirstEpoch();
        uint40 end = house.epochEnd();
        (uint256 lateId, uint40 later) = _transferInALateLong();

        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadExpiry.selector);
        house.sync(_ids(lateId));

        // THE BOUNDARY ROLLS AT `end`, not at `later`.
        _finalizeBoundary(BOUNDARY_PRICE);
        uint64 idBefore = house.epochId();
        vm.prank(stranger);
        house.rollEpoch();
        assertEq(house.epochId(), idBefore + 1, "the boundary waited for the donated series");
        assertEq(block.timestamp, end, "the boundary rolled at its own end, not the donated series' expiry");

        // TIME PASSES and the donated series settles by the permissionless path -- and is redeemed by a stranger,
        // to the vault, with no QUOTER call anywhere. `_redeemSettled` never sees it (untracked); it does not need to.
        oracle.setSettlement(address(nvda), later, V2Types.SettlementStatus.Finalized, BOUNDARY_PRICE);
        vm.warp(later + 1);
        vm.prank(keeper);
        assertTrue(ch.settle(lateId), "the transferred series did not settle");
        vm.prank(stranger);
        ch.redeem(lateId, address(house));
        assertEq(ch.balanceOf(address(house), lateId), 0, "the donated unit was not redeemed");
        assertEq(house.trackedSeries().length, 0, "still nothing tracked, start to finish");
    }

    /// @notice SEC-14 launch-phase action (c): prune + settle ALONE, with NO QUOTER call anywhere, on an in-epoch
    ///         series the vault has a live Bid on.
    /// @dev    {test_rollEpoch_revertsWhileExpiredBidEscrowAwaitsPrune} already shows the boundary passing after a
    ///         permissionless prune. What that test does NOT say, and what (c) is really asking, is whether
    ///         {_tracked} has to be cleaned for the boundary to pass. It does not: {_requireFlat} RE-SCANS live
    ///         state for every tracked id, so a series that stays tracked forever is harmless as long as the scan
    ///         finds nothing. That is the difference between this row's two halves -- (c) is fine precisely
    ///         because the check does not trust {_tracked}, and (b) is not fine because the check trusts it to
    ///         contain only series the epoch guard would have allowed.
    function test_rollEpoch_passesOnPruneAndSettleAloneWithNoQuoterCall() public {
        _housePlaceBid();
        uint256[] memory orderIds = house.orderIdsOf(callId);
        assertEq(orderIds.length, 1, "fixture must leave exactly one bid");
        assertEq(house.trackedSeries().length, 1, "the bid must have tracked its series");

        _finalizeBoundary(BOUNDARY_PRICE);
        vm.prank(keeper);
        assertTrue(ch.settle(callId), "series did not settle");

        // BOTH PERMISSIONLESS, AND NEITHER IS A QUOTER CALL. `prune` is called by a stranger on purpose.
        vm.prank(stranger);
        assertEq(book.prune(orderIds), 1, "permissionless prune did not cancel the expired bid");

        // THE POINT: the series is STILL TRACKED -- nothing re-measured it, because no {sync}, {close}, {cancel},
        // {place} or {take} ran after the prune -- and the boundary rolls anyway.
        assertEq(house.trackedSeries().length, 1, "precondition for this test: nothing untracked the series");
        assertEq(house.trackedSeries()[0], callId, "the wrong series is tracked");

        uint64 idBefore = house.epochId();
        vm.prank(stranger);
        house.rollEpoch();
        assertEq(house.epochId(), idBefore + 1, "the boundary did not roll on prune and settle alone");
    }

    /// @dev Leaves the vault holding a long, so guard (a) must refuse the boundary.
    function _houseTakeOneLong() internal {
        _seedFirstEpoch();
        vm.prank(quoter);
        house.depositToClearinghouse(address(usdg), 5_000e6);
        uint256 askId = _place(mm, callId, WRITE, P3_00, 10);
        V2Types.TakeParams memory p;
        p.longId = callId;
        p.buying = true;
        p.orderIds = _ids(askId);
        p.units = 10;
        p.limitPrice = P3_00;
        p.recipient = address(house);
        p.deadline = NO_DEADLINE;
        p.maxTotalFee = type(uint128).max;
        vm.prank(quoter);
        house.take(p);
    }

    /// @dev Leaves the vault with a live resting bid, so guard (a) must refuse the boundary.
    function _housePlaceBid() internal {
        _seedFirstEpoch();
        vm.prank(quoter);
        house.depositToClearinghouse(address(usdg), 5_000e6);
        vm.prank(quoter);
        house.place(callId, BID, P2_00, 10, 0);
    }

    /*//////////////////////////////////////////////////////////////
       T-573 -- THE SATURATIONS, ENTERED IN THE UNDERFLOW CONDITION
    //////////////////////////////////////////////////////////////*/

    /// @dev T-573, from T-CV-HOUSEVAULT executing C8/T-174's launch-phase action.
    ///
    ///      WHAT WAS WRONG, AND IT WAS THE TESTS AND NOT THE CONTRACT.
    ///      `test_rollEpoch_survivesReservesExceedingTheWallet` is named for the reserves exceeding the wallet, and
    ///      the originating lane measured that it CANNOT FAIL for that reason: mutating the saturation at
    ///      `HouseVault.sol:594` or `:790` to a raw `-` left it GREEN, and `:568` was not reached at all by any of
    ///      the three HouseVault unit suites (gas unchanged at the baseline 2234149, which is how the lane knew).
    ///
    ///      REACHED IS NOT EXERCISED, and that distinction is the whole row. Those ternaries executed; they simply
    ///      always took their first branch, because the fixture never drove the subtrahend above the minuend on
    ///      those paths. A guard that executes without ever being load-bearing is a false green, which is this
    ///      build's dominant defect class.
    ///
    ///      EACH TEST BELOW NAMES THE LINE IT ENTERS AND ASSERTS THE UNDERFLOW PREMISE BEFORE THE CALL, so the test
    ///      fails loudly if a later change stops it reaching its subject rather than silently going vacuous again.
    ///      THE CONTRACT IS NOT ALLEGED TO BE BROKEN and nothing here changes it.

    /// @dev `HouseVault.sol:568`, the performance fee. Enters the saturation with `walletUsdg < reservedUsdg`.
    ///      The gain is REAL -- the premise is asserted -- so the branch at `:556` is taken and a fee is genuinely
    ///      owed; the wallet is simply short of its reserves, so `payable_` saturates to 0 and the fee clamps to 0
    ///      rather than panicking 0x11 and taking the PERMISSIONLESS boundary down with it.
    ///      Its sibling `test_performanceFee_isChargedWhenTheWalletCoversTheReserve` is the CONTROL that keeps this
    ///      test honest: without it, "the splitter received nothing" would also pass on a fixture that never
    ///      produced a fee at all.
    ///
    ///      T-OP-004: THIS IS THAT ROW'S AC1 FIXTURE. DO NOT REBUILD IT. T-OP-004 was raised believing the fee
    ///      branch was reached by exactly one test and that no test asserted a fee is charged on a gain; both were
    ///      true of the tree it measured and neither is true now. It asks for "a gain AND reservedUsdg >
    ///      walletUsdg at the same moment": that is this fixture -- an unclaimed withdrawal creates `owedUsdg`,
    ///      the wallet is driven strictly below it, and the gain comes from the STOCK leg. Both premises are
    ///      ASSERTED rather than assumed, which is the only reason this test is worth anything: see the note below
    ///      recording that the obvious construction FAILED ITS OWN PREMISE ASSERTION rather than passing vacuously.
    function test_rollEpoch_performanceFeeSaturationIsEnteredWhenTheWalletIsShortOfReserves() public {
        _seedFirstEpoch();
        vm.prank(admin);
        house.setPerformanceFeeBps(1000);

        // A matured, DELIBERATELY UNCLAIMED withdrawal: its USDG stays reserved in `owedUsdg`.
        uint256 shares = house.balanceOf(depositorA);
        vm.prank(depositorA);
        house.requestWithdraw(shares / 2);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();

        uint256 reserved = house.pendingDepositUsdg() + house.owedUsdg();
        assertGt(reserved, 0, "nothing is reserved, so the underflow condition cannot be constructed");

        // THE UNDERFLOW CONDITION for :568, set directly. The wallet is driven strictly below the reserve; the
        // stock leg is left untouched so the gain below comes from price, not from cash.
        deal(address(usdg), address(house), reserved - 1);
        assertLt(usdg.balanceOf(address(house)), reserved, ":568 premise: the wallet is not short of the reserve");

        // A REAL GAIN, so `perShare > highWaterMark` at :556 and the fee branch is actually entered.
        //
        // THE GAIN HAS TO COME FROM THE STOCK LEG, AND THAT IS FORCED BY THE CONDITION UNDER TEST, not a
        // convenience. Pinning the wallet one unit below `reserved` is what puts :568 in the underflow branch --
        // but it also drives `_nav`'s own saturation at :730 to zero the cash leg, so NAV afterwards is the stock
        // leg alone. MEASURED: with the cash leg pinned, a 4x price rise still left perShare at 180327854044614091
        // against a high-water mark of 999999918032800322, and this test failed its own premise assertion rather
        // than passing vacuously -- which is the entire point of asserting the premise.
        // So the stock leg is grown directly. That is the vault having earned stock, and it is the only gain a
        // vault whose cash is fully spoken for can actually show.
        uint256 stockNow = nvda.balanceOf(address(house));
        deal(address(nvda), address(house), stockNow * 20 + DEP_STOCK);
        _finalizeBoundary(BOUNDARY_PRICE);
        uint256 perShare = _navPerShare();
        assertGt(perShare, house.highWaterMark(), ":568 premise: no gain, so the fee branch is never entered");

        uint256 splitterBefore = usdg.balanceOf(splitterAddr);
        house.rollEpoch();

        // THE PROTECTED FACT: the permissionless boundary still rolled, and no reserved USDG left the vault.
        assertEq(usdg.balanceOf(splitterAddr), splitterBefore, "a fee was paid out of a wallet short of its reserve");
        assertGe(house.epochEnd(), 0, "the boundary did not complete");
    }

    /// @dev THE CONTROL for the test above. Same shape, but the wallet COVERS the reserve, so the fee is actually
    ///      charged. Without this, the assertion "the splitter received nothing" would pass just as happily on a
    ///      fixture that never produced a fee -- which is precisely the failure this row exists to correct.
    ///
    ///      T-OP-004: THIS IS THAT ROW'S AC2, AND ITS assertGt IS ALSO THE REACHABILITY PROOF. DO NOT REBUILD IT.
    ///      AC2 asks for a test where the splitter balance INCREASES on a gain rather than merely changes -- that
    ///      is the `assertGt` below. AND the same assertion establishes what T-OP-004's AC3a probe exists to
    ///      establish, by a stronger and cheaper route: A SPLITTER BALANCE CANNOT INCREASE WITHOUT THE FEE
    ///      SUBTRACTION HAVING EXECUTED, so a passing `assertGt` IS proof the branch was entered. An unconditional
    ///      `revert` probe run against this suite agrees -- it fires for THREE tests, this one, its sibling above,
    ///      and `test_rollEpoch_isNotHeldShutByADonationAfterSettlement` -- but the probe was never needed.
    ///      NOTE THE INSTRUMENT DISTINCTION, because it is easy to get wrong: a mutation going red proves the
    ///      mutated LINE executed; it does NOT prove a given test enters the branch. Only the probe, or an
    ///      assertion like this one whose success requires the branch, does that.
    function test_performanceFee_isChargedWhenTheWalletCoversTheReserve() public {
        _seedFirstEpoch();
        vm.prank(admin);
        house.setPerformanceFeeBps(1000);

        uint256 shares = house.balanceOf(depositorA);
        vm.prank(depositorA);
        house.requestWithdraw(shares / 2);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();

        uint256 reserved = house.pendingDepositUsdg() + house.owedUsdg();
        assertGt(reserved, 0, "nothing is reserved");

        // The ONLY difference from the test above: the wallet is comfortably ABOVE the reserve.
        deal(address(usdg), address(house), reserved * 10);
        assertGt(usdg.balanceOf(address(house)), reserved, "control premise: the wallet does not cover the reserve");

        // The gain is produced EXACTLY as the sibling test produces it, so the only difference between the two
        // remains the wallet balance. A control that reached its gain by a different route would not be a control.
        uint256 stockNow = nvda.balanceOf(address(house));
        deal(address(nvda), address(house), stockNow * 20 + DEP_STOCK);
        _finalizeBoundary(BOUNDARY_PRICE);
        uint256 perShare = _navPerShare();
        assertGt(perShare, house.highWaterMark(), "control premise: no gain, so no fee could ever be charged");

        uint256 splitterBefore = usdg.balanceOf(splitterAddr);
        house.rollEpoch();
        assertGt(
            usdg.balanceOf(splitterAddr),
            splitterBefore,
            "control: no fee was charged even with the wallet covering the reserve, so the sibling test is vacuous"
        );
    }

    /// @dev `HouseVault.sol:594` AND `:595`, the withdrawal pool, both entered in the underflow condition. The
    ///      reserve is driven ABOVE
    ///      the whole pool, not merely above the wallet -- the pool is wallet + Clearinghouse free + book owed, so
    ///      emptying the wallet alone is not enough and is exactly why the original fixture never got here.
    function test_rollEpoch_withdrawalPoolSaturationIsEnteredWhenReservesExceedThePool() public {
        // Two holders: A leaves a matured unclaimed withdrawal (the reserve), B queues one so the pool branch at
        // :592 is REACHED at the next boundary. It must be B and not A -- `HouseVault.sol:389` refuses a second
        // request from an account still holding a matured one, and claiming A first would destroy the reserve.
        // BOTH LEGS ARE DEPOSITED, and that is what makes :595 load-bearing as well as :594. With a USDG-only
        // fixture `reservedStock` is 0 and `stockPool` is 0, so `0 > 0` is false, the else branch is taken, and a
        // raw `-` there computes 0 - 0 without underflowing. MEASURED: mutating :595 to a raw minus against a
        // USDG-only version of this test left it GREEN at gas 1945422 -- reached, never exercised, which is the
        // exact defect this row exists to remove. Depositing stock gives the stock leg a real reserve to go short of.
        _requestDeposit(depositorA, DEP_USDG, DEP_STOCK);
        _requestDeposit(depositorB, DEP_USDG, DEP_STOCK);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        vm.prank(depositorA);
        house.claim();
        vm.prank(depositorB);
        house.claim();

        uint256 sharesA = house.balanceOf(depositorA);
        vm.prank(depositorA);
        house.requestWithdraw(sharesA);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();

        uint256 owed = house.owedUsdg();
        assertGt(owed, 0, "no USDG was reserved for the withdrawal");

        uint256 sharesB = house.balanceOf(depositorB);
        assertGt(sharesB, 0, ":594 premise: no second holder, so the withdrawal-pool branch is never reached");
        vm.prank(depositorB);
        house.requestWithdraw(sharesB);

        // THE UNDERFLOW CONDITION for :594: the ENTIRE pool below the reserve, asserted leg by leg so this test
        // fails rather than going quiet if a future change starts parking value in the ledger or the book.
        uint256 owedStock_ = house.owedStock();
        assertGt(owedStock_, 0, ":595 premise: no stock is reserved, so the stock leg cannot go short");

        deal(address(usdg), address(house), 0);
        deal(address(nvda), address(house), 0);
        assertEq(ch.free(address(house), address(usdg)), 0, ":594 premise: the ledger still holds USDG");
        assertEq(ch.free(address(house), address(nvda)), 0, ":595 premise: the ledger still holds Stock");
        assertEq(book.owed(address(house)), 0, ":594 premise: the book still owes USDG");
        assertLt(usdg.balanceOf(address(house)), owed, ":594 premise: the pool is not short of the reserve");
        assertLt(nvda.balanceOf(address(house)), owedStock_, ":595 premise: the stock pool is not short of the reserve");

        // THE PROTECTED FACT: the permissionless boundary still rolls with the pool short of its reserve.
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        assertGt(house.epochEnd(), 0, "the boundary did not complete");
    }

    /// @dev `HouseVault.sol:790`, `_unreservedWallet`. Reached only through {depositToClearinghouse} (`:774`), and
    ///      entered here with `wallet < reserved` so the saturation returns 0 and the clamp refuses `BadUnits`.
    ///      THE ASSERTION IS THE ERROR AND NOT MERELY "IT REVERTED": with a raw `-` the call still reverts, but as
    ///      a 0x11 panic. A test that only required a revert would stay green under the mutation.
    function test_depositToClearinghouse_unreservedWalletSaturationIsEnteredWhenReservesExceedTheWallet() public {
        _seedFirstEpoch();

        uint256 shares = house.balanceOf(depositorA);
        vm.prank(depositorA);
        house.requestWithdraw(shares / 2);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();

        uint256 reserved = house.pendingDepositUsdg() + house.owedUsdg();
        assertGt(reserved, 0, "nothing is reserved, so the underflow condition cannot be constructed");

        deal(address(usdg), address(house), reserved - 1);
        assertLt(usdg.balanceOf(address(house)), reserved, ":790 premise: the wallet is not short of the reserve");

        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadUnits.selector);
        house.depositToClearinghouse(address(usdg), 1);
    }

    /*//////////////////////////////////////////////////////////////
          T-594 -- THE TWO {_nav} SATURATIONS, :730 AND :731
    //////////////////////////////////////////////////////////////*/

    // CITATIONS RE-DERIVED AT c851f8f3c48a61315314bf0abd266358fd03d786 (HouseVault.sol, 1370 lines):
    //   :728  uint256 excludedUsdg = pendingDepositUsdg + owedUsdg;
    //   :729  uint256 excludedStock = pendingDepositStock + owedStock;
    //   :730  cashUsdg = cashUsdg > excludedUsdg ? cashUsdg - excludedUsdg : 0;
    //   :731  heldStock = heldStock > excludedStock ? heldStock - excludedStock : 0;
    //   :732  return cashUsdg + Math.mulDiv(heldStock, price, 1e18);
    // where `cashUsdg` is wallet + `clearinghouse.free` + `orderBook.owed` (:725-726) and `heldStock` is wallet +
    // `clearinghouse.free` (:727). {_nav} is read at :549 (`navBefore`) and :653 (`navAfter`) inside the
    // PERMISSIONLESS {rollEpoch}, and by the {nav} view at :746.
    //
    // WHY SATURATING HERE IS CORRECT, AND WHAT DECIDES IT -- three citations, not a guess:
    //
    //   (1) IT MUST NOT REVERT. `rollEpoch` is unrestricted on purpose (contract NatSpec :56-57, `:539`), and a raw
    //       `-` at :730/:731 would panic 0x11 inside it and stop every epoch from rolling. The contract says so of
    //       every sibling form: :560-565 (the fee, "taking the PERMISSIONLESS boundary down with it ... Same
    //       saturating form as {_nav}"), :581-585 (the withdrawal pools, "bricks the permissionless boundary"), and
    //       :782-784 (`_unreservedWallet`, "Saturating, in the same form {_nav} and {rollEpoch} use"). So the
    //       ONLY question is what number the non-reverting form should produce.
    //
    //   (2) THE STATE IS AN ACCOUNTING HOLE, BY THE CONTRACT'S OWN WORDS. At the boundary the ledger has nothing
    //       locked (:74-76: guard (a) proved there is no open position), so `cashUsdg < excludedUsdg` there means
    //       a REALISED LOSS has eaten into money that belongs to queued depositors and former shareholders
    //       (:65-70). `_payReserved` names exactly that state at :1188-1190: "the reserve is not covered by
    //       wallet + ledger at all, which is an accounting hole rather than a placement problem; paying part of
    //       it would hide that" -- and it FAILS CLOSED with `InsufficientCollateral`. The pool's residual claim
    //       on a leg that is entirely spoken for is genuinely zero; zero is the right number for that leg.
    //
    //   (3) PER-LEG, NOT NETTED, BECAUSE THE RESERVES ARE PAID STRICTLY IN KIND. `_payReserved` (:1183-1194)
    //       pays USDG only from USDG wallet + USDG ledger, and Stock only from Stock wallet + Stock ledger.
    //       Nothing anywhere in the contract converts one leg to cover the other's shortfall. So a USDG deficit
    //       is NOT a claim against the Stock the pool still holds, and the value the pool actually keeps is
    //       "the un-short leg in full net of its own reserve, and nothing from the short leg" -- which is
    //       precisely what :730 and :731 compute. SEC-17 (:623-636) then treats the fully saturated case,
    //       `navNow == 0` with shares outstanding, as a MODELLED state ("TOTAL LOSS") rather than an accident.
    //
    // THE ARITHMETIC, STATED SO NOBODY INHERITS THE WRONG DIRECTION. With cash leg C, stock leg S (already
    // valued at price), reserves X and Y: per-leg gives max(C-X,0) + max(S-Y,0); a netted form would give
    // max((C+S)-(X+Y), 0). Whenever exactly one leg is short by d, per-leg is LARGER than netted by d. The row
    // text's "returns a smaller number ... wrong in the safe-looking direction" is true against the UNEXCLUDED
    // sum C+S (every pin below asserts that too) but false against the netted form. Per-leg overstates nothing
    // the pool cannot keep, by citation (3); it does mean the owed claimant, not the pool, absorbs the deficit,
    // and that ordering is the contract's deliberate fail-closed choice at :1188-1190, not this row's to change.
    //
    // WHY THE PINS ARE EQUALITIES. `assertGe(nav, 0)` and "does not revert" are both satisfied BY THE SATURATION
    // ITSELF, so a test shaped that way passes exactly when the defect fires. Each pin below constructs
    // `excluded > held` on a named leg, asserts that premise, pins NAV to the exact value citation (3) demands,
    // and asserts separately that NAV is strictly below the unexcluded arithmetic -- so no pin is met by a
    // {_nav} that quietly stopped excluding anything. The two-legged control makes "saturated" mean saturated
    // rather than merely "small".
    //
    // REACHABILITY (T-594 AC4). :730 IS ENTERED by the existing fixture at
    // {test_rollEpoch_performanceFeeSaturationIsEnteredWhenTheWalletIsShortOfReserves}: it deals the wallet to
    // `reserved - 1` with no ledger balance and nothing book-owed, so `cashUsdg == reserved - 1 < excludedUsdg`
    // at :549 and :653 -- confirmed by reading, and nothing there asserts the value. :731 IS ALSO REACHED by an
    // existing test, one T-573 did not list for it:
    // {test_rollEpoch_withdrawalPoolSaturationIsEnteredWhenReservesExceedThePool} deals BOTH wallets to zero
    // with `owedUsdg > 0` AND `owedStock > 0` asserted, so its final `rollEpoch` evaluates {_nav} at :549 with
    // `heldStock == 0 < excludedStock` and takes the `: 0` arm at :731 as well as :730. It asserts only that the
    // boundary completed. Neither line was pinned before this section; both are now. No existing test reaches
    // either arm through the contract's own loss path (a written call settling in the money against ledger
    // collateral); every fixture, these included, constructs the shortfall with `deal`.

    /// @dev Builds the state both pins below start from: a matured, DELIBERATELY UNCLAIMED withdrawal, which is
    ///      what puts a non-zero reserve in `owedUsdg` AND `owedStock` at once. Paid in kind pro rata, so both
    ///      legs carry a reserve and each leg's saturation can be driven independently of the other.
    function _seedAnUnclaimedWithdrawalReserve() internal {
        _seedFirstEpoch();
        uint256 shares = house.balanceOf(depositorA);
        vm.prank(depositorA);
        house.requestWithdraw(shares / 2);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        assertGt(house.owedUsdg(), 0, "premise: no USDG reserve, so :730 cannot be driven");
        assertGt(house.owedStock(), 0, "premise: no Stock reserve, so :731 cannot be driven");
    }

    /// @dev The cash leg of {_nav} as the contract computes it at `:725-726`, mirrored rather than re-reasoned.
    function _navCashLeg() internal view returns (uint256) {
        return usdg.balanceOf(address(house)) + ch.free(address(house), address(usdg)) + book.owed(address(house));
    }

    /// @dev The stock leg of {_nav} as the contract computes it at `:727`, mirrored rather than re-reasoned.
    function _navStockLeg() internal view returns (uint256) {
        return nvda.balanceOf(address(house)) + ch.free(address(house), address(nvda));
    }

    /// @dev `HouseVault.sol:730`, the CASH leg. T-573 established this branch is ENTERED by
    ///      `test_rollEpoch_performanceFeeSaturationIsEnteredWhenTheWalletIsShortOfReserves` -- pinning the wallet
    ///      one unit below `reserved` zeroes the cash leg, which is precisely why that test's gain had to come
    ///      from the stock leg -- but NOTHING ASSERTED THE VALUE IT PRODUCES. Entered is not covered.
    ///
    ///      THE PIN is NAV == the stock leg alone, net of its own reserve. A netted {_nav} would return one unit
    ///      less (the cash shortfall is exactly 1); a {_nav} that stopped excluding would return strictly more.
    ///      Both are caught, by the equality and by the strict upper bound respectively.
    function test_nav_cashLegSaturatesToZeroAndPricesTheStockLegAlone() public {
        _seedAnUnclaimedWithdrawalReserve();

        uint256 excludedUsdg = house.pendingDepositUsdg() + house.owedUsdg();
        uint256 excludedStock = house.pendingDepositStock() + house.owedStock();

        // THE UNDERFLOW CONDITION for :730, set directly and then ASSERTED. The stock leg is left untouched, so
        // this fixture drives :730 into its saturating arm and leaves :731 in its subtracting arm.
        deal(address(usdg), address(house), excludedUsdg - 1);
        uint256 cash = _navCashLeg();
        uint256 held = _navStockLeg();
        assertLt(cash, excludedUsdg, ":730 premise: the cash leg is not short of its exclusions");
        assertGt(held, excludedStock, ":731 must NOT saturate here, or this pin stops isolating :730");

        uint256 price = house.lastSettlementPrice();
        assertGt(price, 0, "premise: no settled price, so nav() would revert for a different reason");

        // THE PIN: the cash leg contributes EXACTLY ZERO and the stock leg is valued in full net of its reserve.
        assertEq(
            house.nav(), Math.mulDiv(held - excludedStock, price, 1e18), ":730 did not saturate the cash leg to zero"
        );

        // AND THE PIN IS NOT MET BY DOING NOTHING: a {_nav} that excluded nothing would be strictly larger.
        assertLt(
            house.nav(),
            cash + Math.mulDiv(held, price, 1e18),
            ":730 pin is vacuous -- NAV equals the unexcluded arithmetic"
        );
    }

    /// @dev `HouseVault.sol:731`, the STOCK leg -- the one T-573 recorded it had NOT investigated at all. Same
    ///      shape as the test above with the legs swapped: the stock leg is driven strictly below `excludedStock`
    ///      while the cash leg is left comfortably above `excludedUsdg`, so :731 takes its saturating arm and
    ///      :730 takes its subtracting arm. NAV is then pinned to the CASH leg alone, net of its own reserve.
    ///
    ///      THE ROUTE IS THE SAME ONE `:782-784` DESCRIBES, and it is not USDG-specific: Stock Tokens are posted
    ///      as write collateral through {depositToClearinghouse} exactly as USDG is, `clearinghouse.free` excludes
    ///      what a series locked, and `owedStock` is reserved for a withdrawer who has not claimed. A vault that
    ///      has written covered calls against its stock therefore holds less FREE stock than it owes.
    function test_nav_stockLegSaturatesToZeroAndPricesTheCashLegAlone() public {
        _seedAnUnclaimedWithdrawalReserve();

        uint256 excludedUsdg = house.pendingDepositUsdg() + house.owedUsdg();
        uint256 excludedStock = house.pendingDepositStock() + house.owedStock();

        // THE UNDERFLOW CONDITION for :731, and the cash leg is deliberately lifted clear of its own exclusion so
        // the two branches are exercised in opposite directions in one call.
        deal(address(nvda), address(house), excludedStock - 1);
        deal(address(usdg), address(house), excludedUsdg * 10 + 1);
        uint256 cash = _navCashLeg();
        uint256 held = _navStockLeg();
        assertLt(held, excludedStock, ":731 premise: the stock leg is not short of its exclusions");
        assertGt(cash, excludedUsdg, ":730 must NOT saturate here, or this pin stops isolating :731");

        uint256 price = house.lastSettlementPrice();
        assertGt(price, 0, "premise: no settled price, so nav() would revert for a different reason");

        // THE PIN: the stock leg contributes EXACTLY ZERO and the cash leg is counted net of its exclusion.
        assertEq(house.nav(), cash - excludedUsdg, ":731 did not saturate the stock leg to zero");

        // AND THE PIN IS NOT MET BY DOING NOTHING.
        assertLt(
            house.nav(),
            cash + Math.mulDiv(held, price, 1e18),
            ":731 pin is vacuous -- NAV equals the unexcluded arithmetic"
        );
    }

    /// @dev BOTH `:730` AND `:731` IN THEIR SATURATING ARMS AT ONCE, which is the state
    ///      {test_rollEpoch_withdrawalPoolSaturationIsEnteredWhenReservesExceedThePool} rolls through unasserted
    ///      (it deals both wallets to zero). This pin keeps both legs STRICTLY POSITIVE but below their reserves,
    ///      and that is not cosmetic: with both wallets at zero the unexcluded sum is also zero, so `nav() == 0`
    ///      would be satisfied by a {_nav} that excludes nothing. Here the unexcluded sum is asserted positive, so
    ///      zero can only come from both arms saturating. This is also SEC-17's `navNow == 0` state (:623-636),
    ///      reached from a live view rather than assumed.
    function test_nav_isExactlyZeroWhenBothLegsSaturate() public {
        _seedAnUnclaimedWithdrawalReserve();

        uint256 excludedUsdg = house.pendingDepositUsdg() + house.owedUsdg();
        uint256 excludedStock = house.pendingDepositStock() + house.owedStock();
        assertGt(excludedUsdg, 1, "premise: the USDG reserve is too small to halve");
        assertGt(excludedStock, 1, "premise: the Stock reserve is too small to halve");

        // BOTH UNDERFLOW CONDITIONS at once, each leg left with half its reserve so neither leg is empty.
        deal(address(usdg), address(house), excludedUsdg / 2);
        deal(address(nvda), address(house), excludedStock / 2);
        uint256 cash = _navCashLeg();
        uint256 held = _navStockLeg();
        assertLt(cash, excludedUsdg, ":730 premise: the cash leg is not short of its exclusions");
        assertLt(held, excludedStock, ":731 premise: the stock leg is not short of its exclusions");
        assertGt(cash, 0, "premise: the cash leg is empty, so zero NAV would not prove saturation");
        assertGt(held, 0, "premise: the stock leg is empty, so zero NAV would not prove saturation");

        uint256 price = house.lastSettlementPrice();
        assertGt(price, 0, "premise: no settled price, so nav() would revert for a different reason");
        uint256 unexcluded = cash + Math.mulDiv(held, price, 1e18);
        assertGt(unexcluded, 0, "premise: nothing is held, so zero NAV would not prove saturation");

        // THE PIN: both arms saturate and NAV is exactly zero while the vault demonstrably holds value.
        assertEq(house.nav(), 0, "both legs are short of their reserves and NAV is not zero");
        assertLt(house.nav(), unexcluded, "vacuous: NAV equals the unexcluded arithmetic");
    }

    /// @dev THE CONTROL for the pins above, and it is the assertion that makes them mean "saturated" rather than
    ///      merely "small". Same fixture, both legs left ABOVE their exclusions, so :730 and :731 each take their
    ///      SUBTRACTING arm -- and NAV is then the full two-legged sum net of the reserves. Without this, a
    ///      {_nav} that returned the stock leg alone under every condition would satisfy the :730 pin, and one
    ///      that returned the cash leg alone would satisfy the :731 pin, and one that returned zero always would
    ///      satisfy the both-legs pin.
    function test_nav_countsBothLegsNetOfReservesWhenNeitherSaturates() public {
        _seedAnUnclaimedWithdrawalReserve();

        uint256 excludedUsdg = house.pendingDepositUsdg() + house.owedUsdg();
        uint256 excludedStock = house.pendingDepositStock() + house.owedStock();

        deal(address(usdg), address(house), excludedUsdg * 10 + 1);
        deal(address(nvda), address(house), excludedStock * 10 + 1);
        uint256 cash = _navCashLeg();
        uint256 held = _navStockLeg();
        assertGt(cash, excludedUsdg, "control premise: the cash leg is short, so :730 saturates after all");
        assertGt(held, excludedStock, "control premise: the stock leg is short, so :731 saturates after all");

        uint256 price = house.lastSettlementPrice();
        assertEq(
            house.nav(),
            (cash - excludedUsdg) + Math.mulDiv(held - excludedStock, price, 1e18),
            "control: NAV is not the two legs net of their reserves, so the saturation pins prove nothing"
        );
    }

    /*//////////////////////////////////////////////////////////////
       T-OP-032 -- THE {rollEpoch} POOL SATURATIONS, :594 AND :595, AND :603
    //////////////////////////////////////////////////////////////*/

    // CITATIONS RE-DERIVED AT 86f9c25c4983b23553bee5bbdf11cbec212808c6 (HouseVault.sol byte-identical to
    // c851f8f3, the base T-594 read):
    //   :588-591  usdgPool = wallet + clearinghouse.free + orderBook.owed;  stockPool = wallet + clearinghouse.free
    //   :592-593  reservedUsdg = pendingDepositUsdg + owedUsdg;  reservedStock = pendingDepositStock + owedStock
    //   :594      usdgPool  = usdgPool  > reservedUsdg  ? usdgPool  - reservedUsdg  : 0;
    //   :595      stockPool = stockPool > reservedStock ? stockPool - reservedStock : 0;
    //   :596-597  wUsdg = mulDiv(usdgPool, wShares, supply);  wStock = mulDiv(stockPool, wShares, supply)
    //   :598-599  owedUsdg += wUsdg;  owedStock += wStock
    //   :600-601  _burn(address(this), wShares);  pendingWithdrawShares = 0
    //   :602      outValue = wUsdg + mulDiv(wStock, price, 1e18)
    //   :603      navNow = navNow > outValue ? navNow - outValue : 0;
    //   :642-649  _rates[epochId] = EpochRates({ ..., withdrawShares: wShares, withdrawUsdg: wUsdg, withdrawStock: wStock })
    //
    // WHAT WAS UNASSERTED. T-594 measured that {test_rollEpoch_withdrawalPoolSaturationIsEnteredWhenReservesExceedThePool}
    // enters BOTH `: 0` arms at :594 and :595 (both wallets dealt to zero, both reserves asserted non-zero) and
    // asserts only that the boundary completed. Nothing pinned the VALUE the arms produce. The pins below do, by
    // EQUALITY, and each is paired with the thing that would otherwise let it pass for the wrong reason:
    //   - `owedUsdg`/`owedStock` UNCHANGED across the roll pins `wUsdg == 0` / `wStock == 0` at :598-599 -- but a
    //     withdrawal branch that was never ENTERED leaves them unchanged too, so every test also asserts the burn
    //     at :600 (`totalSupply` and the vault's own share balance both fall by exactly the requested shares) and
    //     the queue reset at :601. Entered, then zero.
    //   - `_rates[epoch].withdrawUsdg == 0` / `.withdrawStock == 0` (:647-648) are PRIVATE; they are read back
    //     through the one path that consumes them, {claim} at :466-472: with the withdrawer holding the WHOLE
    //     batch (`w.shares == e.withdrawShares`), `payUsdg = mulDiv(e.withdrawUsdg, w.shares, e.withdrawShares)`
    //     is `e.withdrawUsdg` EXACTLY, so `Claimed(withdrawer, 0, usdgOut, stockOut)` carries the recorded rates
    //     verbatim and the claimant's balances move by exactly them. The rates are pinned through the event and
    //     the balances together.
    //   - THE CONTROL leaves both pools ABOVE their reserves and pins the NON-ZERO increments to the mirrored
    //     arithmetic, so a fixture that simply withdraws nothing cannot satisfy the saturation pins.
    // THE FORBIDDEN SHAPE, named so it is not re-invented: `assertLe(wUsdg, usdgPool)` / `assertGe(x, 0)`. A
    // saturating subtraction can never violate a bound like that; only equality with the saturated value, and
    // equality of the reserve counters before and after, separates "subtracted" from "saturated".
    //
    // :603, DECIDED (T-OP-032 AC3): THE STRICT UNDERFLOW ARM IS UNREACHABLE FROM ANY LEGAL STATE; THE EQUALITY
    // CASE IS REACHABLE AND IS PINNED BELOW. The argument, with the reads it rests on:
    //   Let C = wallet + free + owed (USDG, :725-726) and S = wallet + free (Stock, :727) as {_nav} reads them at
    //   :549, X = reservedUsdg, Y = reservedStock, p = price. Then navBefore = C' + floor(S'·p/1e18) with
    //   C' = max(C-X, 0), S' = max(S-Y, 0) (:730-732).
    //   THE FEE (:553-572) is the ONLY state change between :549 and :588 -- a `usdg.safeTransfer(splitter, fee)`
    //   to an immutable address under `nonReentrant`, which moves wallet USDG and nothing else -- and it is capped
    //   at :568-569 by `payable_ = max(wallet - X, 0)`. Since wallet <= C, `fee <= max(C-X, 0) = C'`.
    //   navNow = navBefore - fee (:574).
    //   The pools at :588-595 are read AFTER the fee left the wallet: usdgPool_net = max(C - fee - X, 0), and this
    //   equals C' - fee in both cases (if C >= X then fee <= C-X so C-fee-X >= 0; if C < X then wallet < X so
    //   fee = 0 and both sides are 0). stockPool_net = S' unchanged.
    //   wShares <= supply (the request escrowed its shares into the vault at :416, and supply is `totalSupply()`
    //   read at :548, which includes them), so wUsdg = floor(usdgPool_net·w/supply) <= C' - fee and
    //   wStock = floor(S'·w/supply) <= S'. Hence
    //     outValue = wUsdg + floor(wStock·p/1e18) <= (C' - fee) + floor(S'·p/1e18) = navBefore - fee = navNow.
    //   So `navNow > outValue` is false ONLY when outValue == navNow, and in that case the `: 0` arm returns
    //   exactly what `navNow - outValue` would have -- the saturation never changes the result. The strict case
    //   `outValue > navNow` cannot be entered: the same `price` local is used at :549 and :602, and no read
    //   between them can move. This is also the "wrong fix (c)" the row forbids -- the arm is reachable only if
    //   an oracle read between :549 and :602 disagreed with itself, and there is no second read.
    //   THE EQUALITY CASE IS LEGAL AND REACHED: with both pools saturated, navBefore = 0 = navNow = outValue, the
    //   `: 0` arm is taken, and navNow == 0 is OBSERVABLE through SEC-17 (:623-636): a batch queued for that
    //   boundary is REFUSED (minted == 0, moved to the owed reserve, returned in kind by {claim} at :450-455).
    //   {test_rollEpoch_bothPoolsSaturated_navNowIsZeroAndTheDepositBatchIsRefused} pins that.

    /// @dev The T-573 fixture up to the moment the pools are about to be measured short: A and B both deposit
    ///      both legs and are seeded; A withdraws everything and leaves it UNCLAIMED (that is the reserve, on
    ///      both legs); B requests everything, so the withdrawal branch at :580 is REACHED at the next boundary.
    ///      Returns B's escrowed share count. The caller then sets the wallets, finalizes and rolls.
    function _seedAWithdrawerBehindAnUnclaimedReserve() internal returns (uint256 sharesB) {
        _requestDeposit(depositorA, DEP_USDG, DEP_STOCK);
        _requestDeposit(depositorB, DEP_USDG, DEP_STOCK);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        vm.prank(depositorA);
        house.claim();
        vm.prank(depositorB);
        house.claim();

        uint256 sharesA = house.balanceOf(depositorA);
        vm.prank(depositorA);
        house.requestWithdraw(sharesA);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        assertGt(house.owedUsdg(), 0, "premise: no USDG is reserved, so :594 cannot be driven");
        assertGt(house.owedStock(), 0, "premise: no Stock is reserved, so :595 cannot be driven");

        sharesB = house.balanceOf(depositorB);
        assertGt(sharesB, 0, "premise: no second holder, so the withdrawal branch is never reached");
        vm.prank(depositorB);
        house.requestWithdraw(sharesB);
        assertEq(house.pendingWithdrawShares(), sharesB, "premise: B's shares are not queued");
        // Nothing is parked in the ledger or the book in this fixture, so the wallet IS the pool on each leg.
        assertEq(ch.free(address(house), address(usdg)), 0, "premise: the ledger holds USDG");
        assertEq(ch.free(address(house), address(nvda)), 0, "premise: the ledger holds Stock");
        assertEq(book.owed(address(house)), 0, "premise: the book owes USDG");
    }

    /// @dev The two pools NET of their reserves, mirrored from `:588-595` rather than re-reasoned, read at the
    ///      moment the caller is about to roll. Correct only while the fee is zero (nothing leaves the wallet
    ///      between {_nav} and the pool reads); every test below asserts the splitter received nothing.
    function _poolsNetOfReserves() internal view returns (uint256 usdgNet, uint256 stockNet) {
        uint256 usdgPool =
            usdg.balanceOf(address(house)) + ch.free(address(house), address(usdg)) + book.owed(address(house));
        uint256 stockPool = nvda.balanceOf(address(house)) + ch.free(address(house), address(nvda));
        uint256 reservedUsdg = house.pendingDepositUsdg() + house.owedUsdg();
        uint256 reservedStock = house.pendingDepositStock() + house.owedStock();
        usdgNet = usdgPool > reservedUsdg ? usdgPool - reservedUsdg : 0;
        stockNet = stockPool > reservedStock ? stockPool - reservedStock : 0;
    }

    /// @dev Rolls and pins everything the withdrawal branch decided for B, given what each leg MUST pay.
    ///      `expectUsdg` / `expectStock` are the values :596-597 must produce; zero means the leg saturated.
    function _rollAndPinTheWithdrawalBatch(uint256 sharesB, uint256 expectUsdg, uint256 expectStock) internal {
        uint256 owedUsdgBefore = house.owedUsdg();
        uint256 owedStockBefore = house.owedStock();
        uint256 supplyBefore = house.totalSupply();
        uint256 escrowBefore = house.balanceOf(address(house));
        uint256 splitterBefore = usdg.balanceOf(splitterAddr);

        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();

        // ENTERED: the burn at :600 and the reset at :601 happened, so the pins below are about the arms, not
        // about a branch that was skipped.
        assertEq(house.totalSupply(), supplyBefore - sharesB, "the withdrawal branch did not burn B's shares");
        assertEq(house.balanceOf(address(house)), escrowBefore - sharesB, "B's escrow was not burned");
        assertEq(house.pendingWithdrawShares(), 0, "the withdrawal queue was not reset");
        assertEq(usdg.balanceOf(splitterAddr), splitterBefore, "a fee moved the wallet between :549 and :588");

        // THE PINS ON :598-599: the reserve counters moved by EXACTLY what each arm produced.
        assertEq(house.owedUsdg(), owedUsdgBefore + expectUsdg, ":594/:598 owedUsdg did not move by wUsdg");
        assertEq(house.owedStock(), owedStockBefore + expectStock, ":595/:599 owedStock did not move by wStock");

        // THE PINS ON :647-648 THROUGH {claim}: B holds the whole batch, so the payout IS the recorded rate.
        uint256 usdgB = usdg.balanceOf(depositorB);
        uint256 stockB = nvda.balanceOf(depositorB);
        vm.expectEmit(true, false, false, true, address(house));
        emit HouseVault.Claimed(depositorB, 0, expectUsdg, expectStock);
        vm.prank(depositorB);
        house.claim();
        assertEq(usdg.balanceOf(depositorB), usdgB + expectUsdg, "B was not paid the recorded USDG rate");
        assertEq(nvda.balanceOf(depositorB), stockB + expectStock, "B was not paid the recorded Stock rate");
        assertEq(house.owedUsdg(), owedUsdgBefore, "the claim did not return owedUsdg to its pre-roll value");
        assertEq(house.owedStock(), owedStockBefore, "the claim did not return owedStock to its pre-roll value");
        // And the request was RETIRED (F-CP-07), whether or not it paid anything.
        vm.prank(depositorB);
        vm.expectRevert(V2Errors.BadUnits.selector);
        house.claim();
    }

    /// @dev `:594` AND `:595` BOTH SATURATED -- the exact state the T-573 fixture rolls through unasserted. The
    ///      wallets are driven strictly below the reserves but NOT to zero: with both at zero the "no reserve was
    ///      subtracted" arithmetic also pays zero, and the pin would not know the difference. Here a {rollEpoch}
    ///      that stopped excluding the reserves would pay B a non-zero slice of each leg, and the equality catches it.
    function test_rollEpoch_bothPoolsSaturated_withdrawerIsOwedExactlyZeroOnBothLegs() public {
        uint256 sharesB = _seedAWithdrawerBehindAnUnclaimedReserve();
        deal(address(usdg), address(house), house.owedUsdg() / 2);
        deal(address(nvda), address(house), house.owedStock() / 2);
        (uint256 usdgNet, uint256 stockNet) = _poolsNetOfReserves();
        assertEq(usdgNet, 0, ":594 premise: the USDG pool is not short of its reserve");
        assertEq(stockNet, 0, ":595 premise: the Stock pool is not short of its reserve");
        assertGt(usdg.balanceOf(address(house)), 0, "premise: an empty wallet would make the zero pin vacuous");
        assertGt(nvda.balanceOf(address(house)), 0, "premise: an empty wallet would make the zero pin vacuous");

        _rollAndPinTheWithdrawalBatch(sharesB, 0, 0);
    }

    /// @dev `:594` SATURATED ALONE: the USDG leg is short of its reserve and the Stock leg is left comfortably
    ///      above its own, so wUsdg == 0 while wStock is the real pro-rata slice of the net Stock pool. The
    ///      non-zero leg is what shows :595 took its SUBTRACTING arm in the same roll.
    function test_rollEpoch_usdgPoolSaturated_withdrawerIsOwedZeroUsdgAndTheFullStockSlice() public {
        uint256 sharesB = _seedAWithdrawerBehindAnUnclaimedReserve();
        deal(address(usdg), address(house), house.owedUsdg() / 2);
        deal(address(nvda), address(house), house.owedStock() * 10 + 1);
        (uint256 usdgNet, uint256 stockNet) = _poolsNetOfReserves();
        assertEq(usdgNet, 0, ":594 premise: the USDG pool is not short of its reserve");
        assertGt(stockNet, 0, ":595 must NOT saturate here, or this pin stops isolating :594");
        uint256 expectStock = Math.mulDiv(stockNet, sharesB, house.totalSupply());
        assertGt(expectStock, 0, "premise: the Stock slice rounds to nothing, so the leg cannot be told apart");

        _rollAndPinTheWithdrawalBatch(sharesB, 0, expectStock);
    }

    /// @dev `:595` SATURATED ALONE, the mirror image: wStock == 0 while wUsdg is the real slice of the net USDG pool.
    function test_rollEpoch_stockPoolSaturated_withdrawerIsOwedZeroStockAndTheFullUsdgSlice() public {
        uint256 sharesB = _seedAWithdrawerBehindAnUnclaimedReserve();
        deal(address(nvda), address(house), house.owedStock() / 2);
        deal(address(usdg), address(house), house.owedUsdg() * 10 + 1);
        (uint256 usdgNet, uint256 stockNet) = _poolsNetOfReserves();
        assertEq(stockNet, 0, ":595 premise: the Stock pool is not short of its reserve");
        assertGt(usdgNet, 0, ":594 must NOT saturate here, or this pin stops isolating :595");
        uint256 expectUsdg = Math.mulDiv(usdgNet, sharesB, house.totalSupply());
        assertGt(expectUsdg, 0, "premise: the USDG slice rounds to nothing, so the leg cannot be told apart");

        _rollAndPinTheWithdrawalBatch(sharesB, expectUsdg, 0);
    }

    /// @dev THE CONTROL: neither pool saturates, so :594 and :595 both take their SUBTRACTING arms and B is owed the
    ///      pro-rata slice of each leg NET of the reserve. Without this, the three pins above would be satisfied
    ///      by a {rollEpoch} that never pays a withdrawer anything at all.
    function test_rollEpoch_neitherPoolSaturated_withdrawerIsOwedTheProRataSliceNetOfReserves() public {
        uint256 sharesB = _seedAWithdrawerBehindAnUnclaimedReserve();
        deal(address(usdg), address(house), house.owedUsdg() * 10 + 1);
        deal(address(nvda), address(house), house.owedStock() * 10 + 1);
        (uint256 usdgNet, uint256 stockNet) = _poolsNetOfReserves();
        assertGt(usdgNet, 0, "control premise: the USDG pool is short, so :594 saturates after all");
        assertGt(stockNet, 0, "control premise: the Stock pool is short, so :595 saturates after all");
        uint256 supply = house.totalSupply();
        uint256 expectUsdg = Math.mulDiv(usdgNet, sharesB, supply);
        uint256 expectStock = Math.mulDiv(stockNet, sharesB, supply);
        assertGt(expectUsdg, 0, "control premise: the USDG slice is zero, so this is not a control");
        assertGt(expectStock, 0, "control premise: the Stock slice is zero, so this is not a control");
        // And NET of the reserve, not the bare pool: the unexcluded slice would be strictly larger.
        assertLt(expectUsdg, Math.mulDiv(usdg.balanceOf(address(house)), sharesB, supply), "control: reserve not excluded");

        _rollAndPinTheWithdrawalBatch(sharesB, expectUsdg, expectStock);
    }

    /// @dev `:603`, THE EQUALITY CASE, PINNED. With both pools saturated navBefore is 0 (:730-731), the fee is 0,
    ///      outValue is 0, and :603 evaluates `0 > 0 ? ... : 0`: the `: 0` arm is taken and navNow == 0. That
    ///      value is private, so it is read through the one thing it decides: a deposit batch queued for this
    ///      boundary. SEC-17 (:623-636) REFUSES a batch when `navNow == 0` with shares outstanding -- nothing is
    ///      minted, the batch moves to the owed reserve, and {claim} returns it in kind (:450-455). A navNow
    ///      that were positive would MINT (:629-632) and C would receive shares instead. The section header
    ///      argues the STRICT arm (`outValue > navNow`) cannot be entered; this is the reachable half.
    ///
    ///      THE WALLETS ARE LEFT AT EXACTLY THE QUEUED DEPOSIT, not zero: C's money is reserved in
    ///      `pendingDeposit*` (:592-593 count it), so the pools are still strictly short of their reserves by the
    ///      whole of A's unclaimed withdrawal, both arms at :594-595 saturate, and yet {claim} can pay C back in
    ///      kind from the wallet without tripping `_payReserved` (:1183-1194).
    function test_rollEpoch_bothPoolsSaturated_navNowIsZeroAndTheDepositBatchIsRefused() public {
        uint256 sharesB = _seedAWithdrawerBehindAnUnclaimedReserve();
        address depositorC = makeAddr("depositorC");
        _fundDepositor(depositorC);
        _requestDeposit(depositorC, DEP_USDG, DEP_STOCK);
        assertEq(house.pendingDepositUsdg(), DEP_USDG, "premise: C's USDG is not queued");
        assertEq(house.pendingDepositStock(), DEP_STOCK, "premise: C's Stock is not queued");

        deal(address(usdg), address(house), DEP_USDG);
        deal(address(nvda), address(house), DEP_STOCK);
        (uint256 usdgNet, uint256 stockNet) = _poolsNetOfReserves();
        assertEq(usdgNet, 0, ":594 premise: the USDG pool is not short of its reserve");
        assertEq(stockNet, 0, ":595 premise: the Stock pool is not short of its reserve");
        assertEq(house.nav(), 0, "premise: navBefore is not zero, so :603 will not evaluate 0 > 0");

        uint256 owedUsdgBefore = house.owedUsdg();
        uint256 owedStockBefore = house.owedStock();
        uint256 supplyBefore = house.totalSupply();
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();

        // THE PIN ON :603 THROUGH SEC-17: nothing was minted for C's batch, and the whole batch moved to the owed
        // reserve. B's withdrawal contributed exactly zero to the same counters (:594/:595, pinned separately above).
        assertEq(house.totalSupply(), supplyBefore - sharesB, "shares were minted, so navNow was not zero at :629");
        assertEq(house.owedUsdg(), owedUsdgBefore + DEP_USDG, "the refused batch did not move to the owed reserve");
        assertEq(house.owedStock(), owedStockBefore + DEP_STOCK, "the refused batch did not move to the owed reserve");
        assertEq(house.pendingDepositUsdg(), 0, "the deposit queue was not cleared");
        assertEq(house.pendingDepositStock(), 0, "the deposit queue was not cleared");

        // C gets the batch back in kind, share-less; B gets nothing, retired.
        uint256 usdgC = usdg.balanceOf(depositorC);
        uint256 stockC = nvda.balanceOf(depositorC);
        vm.expectEmit(true, false, false, true, address(house));
        emit HouseVault.Claimed(depositorC, 0, DEP_USDG, DEP_STOCK);
        vm.prank(depositorC);
        house.claim();
        assertEq(house.balanceOf(depositorC), 0, "C received shares from a batch priced at navNow == 0");
        assertEq(usdg.balanceOf(depositorC), usdgC + DEP_USDG, "C's USDG did not come back in kind");
        assertEq(nvda.balanceOf(depositorC), stockC + DEP_STOCK, "C's Stock did not come back in kind");

        vm.expectEmit(true, false, false, true, address(house));
        emit HouseVault.Claimed(depositorB, 0, 0, 0);
        vm.prank(depositorB);
        house.claim();
        assertEq(house.owedUsdg(), owedUsdgBefore, "after both claims owedUsdg is not back at its pre-roll value");
        assertEq(house.owedStock(), owedStockBefore, "after both claims owedStock is not back at its pre-roll value");
    }
}
