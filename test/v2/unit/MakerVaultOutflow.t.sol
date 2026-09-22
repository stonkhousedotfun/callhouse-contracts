// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {MakerTestBase} from "./MakerBase.t.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";

/// @notice The MakerVault's daily net USDG outflow cap (sweep contracts-c21, INTERFACE_VERSION 7, v7 design §4.6):
///         what is booked, what is deliberately not, how the leaky bucket refills, and the two bounds it buys —
///         at most `maxDailyOutflow` out at once and at most twice that in any 24 h.
/// @dev The fixture's cap is the launch value, 2,500 USDG a day ({MakerTestBase.MAX_DAILY_OUTFLOW}). The numbers below
///      are exact Solidity arithmetic on that fixture: NVDA spot 220 (bid cap 22.00 a share), the 230 call and the 210
///      put, premium fee 500 bps, resale fee 0, taker fee 0.10 USDG flat, maker rebate 50 % of the taker fee.
///
///      WHAT THE MEASURE IS. `cash = usdg.balanceOf(vault) + orderBook.owed(vault)`, read immediately before a booked
///      call reaches the book and again after it, with the difference charged or credited. It is NOT the vault's
///      Clearinghouse ledger, and that exclusion is the whole point: a put's collateral is locked by a fill that
///      happens between vault calls and freed by `close` inside one, so a measure that counted `clearinghouse.free`
///      would credit collateral nobody ever charged. {test_outflowCap_putCollateralFreedByCloseIsNotACredit} is that
///      proof, and it is the reason the sweep's own proposed measure was not used.
contract MakerVaultOutflowTest is MakerTestBase {
    /// @dev 10,000 units of the 210 put: 10,000 x 210_000_000 / 100 USDG base units of collateral.
    uint256 internal constant PUT_COLLATERAL = 21_000e6;
    /// @dev A bid price under the 22.00 bid cap that makes 10,000 units escrow exactly 2,000 USDG.
    uint128 internal constant P20_00 = 20_000_000;

    /// @dev NVDA's launch collateral-rent rate (v7 design 5.1), for the rent round trips at the end of this suite.
    ///      The fixture itself registers both markets at 0 (v7 design §3.8), so every other number in the maker
    ///      suites is the one it was before c05.
    uint32 internal constant NVDA_MINT_FEE_PPM = 80;
    /// @dev Out-of-the-money either side of the 220 spot, so the vault's ask floor is 0 and the rent, not the price,
    ///      is what these tests are about.
    uint128 internal constant RENT_CALL_STRIKE = 240_000_000;
    uint128 internal constant RENT_PUT_STRIKE = 200_000_000;
    uint64 internal constant RENT_UNITS = 500;

    /*//////////////////////////////////////////////////////////////
                   THE MEASURE: WHY NOT THE LEDGER
    //////////////////////////////////////////////////////////////*/

    /// @dev The hole in a measure that counts `clearinghouse.free`, and the proof this one does not have it. The vault
    ///      writes puts, an outsider buys them (between vault calls, so nothing is booked and 21,000 USDG of ledger
    ///      collateral is locked), the vault buys the longs back at the bid cap for 2,200.10 USDG, and `close` frees
    ///      the 21,000 again. A ledger-aware measure would see a 21,000 credit there and hand the loop a fresh budget
    ///      every round; this one books nothing, so the second round is refused at the same `available` the first one
    ///      left behind (v7 design §4.6.4, §6.4).
    function test_outflowCap_putCollateralFreedByCloseIsNotACredit() public {
        _armQuoterEoa();
        _vaultLedger(address(usdg), PUT_COLLATERAL);
        uint128 cap = uint128(vault.bidCap(putId));
        assertEq(cap, 22_000_000, "bid cap: 10 % of the 220 spot");

        uint256 ask = _vaultPlace(putId, WRITE, P2_00, 10_000);
        assertEq(_used(), 0, "an ask escrows no USDG, so it is never booked");

        _take(quoter, _buy(putId, _ids(ask), 10_000, P2_00, quoter));
        assertEq(ch.free(address(vault), address(usdg)), 0, "a fill between vault calls locked the collateral");
        assertEq(_used(), 0, "and booked nothing, because the vault was not called");

        uint256 resale = _place(quoter, putId, RESALE, cap, 10_000);
        _vaultTake(_buy(putId, _ids(resale), 10_000, cap, address(vault)));
        assertEq(_used(), 2_200_100_000, "22.00 a share plus the 0.10 taker fee");
        assertEq(_available(), 299_900_000);

        vm.prank(quoter);
        vault.close(putId, 10_000);
        assertEq(ch.free(address(vault), address(usdg)), PUT_COLLATERAL, "close freed the collateral");
        assertEq(_used(), 2_200_100_000, "into the LEDGER, which this measure excludes: not a credit");
        assertEq(_available(), 299_900_000, "so the budget is exactly where the buy-back left it");

        uint256 ask2 = _vaultPlace(putId, WRITE, P2_00, 10_000);
        _take(quoter, _buy(putId, _ids(ask2), 10_000, P2_00, quoter));
        uint256 resale2 = _place(quoter, putId, RESALE, cap, 10_000);
        vm.prank(quoter);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.OutflowCapExceeded.selector, 299_900_000, 2_200_100_000));
        vault.take(_buy(putId, _ids(resale2), 10_000, cap, address(vault)));
    }

    /*//////////////////////////////////////////////////////////////
                         WHAT IS BOOKED, WHEN
    //////////////////////////////////////////////////////////////*/

    /// @dev A resting bid is charged the moment it is placed, not when it fills: between vault calls anyone may take
    ///      it at the quoter's price, so the escrow is already spent as far as the cap is concerned.
    function test_outflowCap_restingBidChargedAtPlacement() public {
        uint256 bid = _vaultPlace(callId, BID, P2_00, 1_000);
        assertEq(_used(), 20_000_000, "escrow = 2.00 x 1,000 / 100 = 20 USDG");
        assertEq(_available(), MAX_DAILY_OUTFLOW - 20_000_000);
        assertEq(_order(bid).filled, 0, "and nothing has filled: anyone could still take it between calls");
        assertEq(usdg.balanceOf(address(vault)), VAULT_USDG - 20_000_000, "the USDG really left the vault");
    }

    /// @dev Escrow that comes back is credited: a replace down, a replace up and a cancel each book their NET change,
    ///      and the bucket never goes below empty, so credits never build a budget for tomorrow.
    function test_outflowCap_replaceAndCancelCreditEscrow_neverBelowZero() public {
        uint256 bid = _vaultPlace(callId, BID, P2_00, 1_000);
        assertEq(_used(), 20_000_000);

        vm.prank(quoter);
        uint256 smaller = vault.replace(bid, P2_00, 400);
        assertEq(_used(), 8_000_000, "a replace down credits the difference");

        vm.prank(quoter);
        uint256 bigger = vault.replace(smaller, P3_00, 1_000);
        assertEq(_used(), 30_000_000, "a replace up charges the difference");

        vm.prank(quoter);
        vault.cancel(_ids(bigger));
        assertEq(_used(), 0, "and a cancel gives all of it back");

        _vaultLedger(address(nvda), 10e18);
        uint256 aliceBid = _place(alice, callId, BID, P2_00, 100);
        _vaultTake(_sell(callId, _ids(aliceBid), 100, P2_00, true, address(vault)));
        assertEq(_used(), 0, "a credit on an empty bucket stays empty");
        assertEq(_available(), MAX_DAILY_OUTFLOW, "never above the cap");
    }

    /// @dev Both fuzzed facts of the guarantee in one place: a booked call reverts exactly when its net spend exceeds
    ///      `available`, a refused call books nothing, and an allowed one books exactly what it spent.
    function testFuzz_outflowCap_revertsIffAboveAvailable(uint64 preUnits, uint64 units, uint32 elapsed) public {
        preUnits = uint64(bound(preUnits, 0, 10_000));
        units = uint64(bound(units, 1, 10_000));
        elapsed = uint32(bound(elapsed, 0, 2 days));
        if (preUnits != 0) _vaultPlace(callId, BID, P20_00, preUnits);
        vm.warp(block.timestamp + elapsed);

        (uint256 used, uint256 available) = vault.outflow();
        uint256 escrow = uint256(P20_00) * units / 100;
        vm.prank(quoter);
        if (escrow > available) {
            vm.expectRevert(abi.encodeWithSelector(V2Errors.OutflowCapExceeded.selector, available, escrow));
            vault.place(tslaId, BID, P20_00, units, 0);
            assertEq(_used(), used, "a refused call books nothing");
            assertEq(usdg.balanceOf(address(vault)) + book.owed(address(vault)), _cash(), "and moves no USDG");
        } else {
            vault.place(tslaId, BID, P20_00, units, 0);
            assertEq(_used(), used + escrow, "an allowed call books exactly its spend");
        }
    }

    /*//////////////////////////////////////////////////////////////
                    WHAT IS NEVER BOOKED, AND WHY
    //////////////////////////////////////////////////////////////*/

    /// @dev Everything that reaches the vault without the vault being called is invisible to the cap: an admin
    ///      deposit, a plain transfer, a stranger filling one of the vault's asks, and a keeper pruning an expired
    ///      vault bid. None of them can be told apart from USDG anyone chooses to send in, so crediting them would let
    ///      an attacker fund the next leg of a loop with the proceeds of the last one.
    function test_outflowCap_betweenCallInflowsNeverRaiseTheBudget() public {
        _vaultLedger(address(tsla), 20e18);
        _vaultPlace(callId, BID, P20_00, 10_000);
        assertEq(_used(), 2_000e6, "2,000 USDG of bid escrow");

        _fund(admin, 5_000e6, 0, 0);
        vm.startPrank(admin);
        usdg.approve(address(vault), type(uint256).max);
        vault.deposit(address(usdg), 5_000e6);
        vm.stopPrank();
        assertEq(_used(), 2_000e6, "an admin deposit is not the quoter's budget");

        usdg.mint(address(this), 5_000e6);
        usdg.transfer(address(vault), 5_000e6);
        assertEq(_used(), 2_000e6, "nor is USDG anyone sends in");

        uint256 ask = _vaultPlace(tslaId, WRITE, P3_00, 1_000);
        _take(alice, _buy(tslaId, _ids(ask), 1_000, P3_00, alice));
        assertEq(_used(), 2_000e6, "nor income from a fill the vault was not called for");

        vm.prank(quoter);
        uint256 shortBid = vault.place(putId, BID, P2_00, 100, uint40(block.timestamp + 100));
        assertEq(_used(), 2_002e6, "that bid is charged like any other");
        vm.warp(block.timestamp + 101);
        uint256 usedBeforePrune = _used();
        vm.prank(keeper);
        assertEq(book.prune(_ids(shortBid)), 1, "the keeper prunes the expired bid and refunds the escrow");
        assertEq(_used(), usedBeforePrune, "and the refund is not credited either");
    }

    /// @dev Writing a put through {MakerVault.take} spends LEDGER collateral, which the measure excludes, and brings
    ///      the premium into the wallet, which it counts. So the whole call is a credit: selling options can never be
    ///      throttled by a cap meant for buying them back.
    function test_outflowCap_putWriteToSellCollateralIsNeutral() public {
        _vaultLedger(address(usdg), PUT_COLLATERAL);
        uint256 buyerBid = _place(alice, putId, BID, P2_00, 10_000);
        uint256 cashBefore = _cash();

        _vaultTake(_sell(putId, _ids(buyerBid), 10_000, P2_00, true, address(vault)));

        assertEq(ch.free(address(vault), address(usdg)), 0, "21,000 USDG of ledger collateral is now locked");
        assertGt(_cash(), cashBefore, "but the measured cash only went up, by the premium");
        assertEq(_used(), 0, "so a put written from the ledger never charges the cap");
    }

    /// @dev A refund the vault cannot receive is credited to `orderBook.owed`, which the measure counts, so a cancel
    ///      still gives the budget back while USDG has the vault frozen; claiming it later moves cash inside the
    ///      measure and books nothing.
    function test_outflowCap_frozenVaultRefundCreditsThroughOwed() public {
        uint256 bid = _vaultPlace(callId, BID, P2_00, 1_000);
        assertEq(_used(), 20_000_000);

        usdg.freeze(address(vault));
        vm.prank(quoter);
        vault.cancel(_ids(bid));
        assertEq(usdg.balanceOf(address(vault)), VAULT_USDG - 20_000_000, "the refund could not be transferred");
        assertEq(book.owed(address(vault)), 20_000_000, "it is owed instead");
        assertEq(_used(), 0, "and owed is inside the measure, so the cancel still credits");

        usdg.unfreeze(address(vault));
        vm.prank(quoter);
        vault.claimOwed();
        assertEq(_used(), 0, "claiming owed moves cash within the measure: nothing to book");
        assertEq(usdg.balanceOf(address(vault)), VAULT_USDG);
    }

    /*//////////////////////////////////////////////////////////////
                          REFILL AND THE CAP
    //////////////////////////////////////////////////////////////*/

    /// @dev The bucket refills linearly at `maxDailyOutflow` per {MakerVault.OUTFLOW_WINDOW}, `used` is rounded UP so
    ///      `available` is never overstated, and it never refills past empty.
    function test_outflowCap_refillsLinearly() public {
        _vaultPlace(callId, BID, P20_00, 10_000);
        assertEq(_used(), 2_000e6, "2,000 USDG charged");

        _skip(12 hours);
        assertEq(_used(), 750e6, "2,000 less half a day of the 2,500/day refill");
        assertEq(_available(), 1_750e6);

        _skip(1);
        assertEq(_used(), 749_971_065, "one more second, rounded UP from 749,971,064.81");

        _skip(13 hours - 1); // 25 h since the charge
        assertEq(_used(), 0, "more than the 19.2 h this charge needs");
        assertEq(_available(), MAX_DAILY_OUTFLOW, "and the bucket never refills past the cap");
    }

    /// @dev A cap change settles the bucket against the OLD cap first: raising it never back-dates the faster refill,
    ///      and lowering it to 0 freezes what is used instead of wiping it. Cap 0 is the on-chain spend freeze.
    function test_outflowCap_setLimitsNeverRefillsRetroactively() public {
        _vaultPlace(callId, BID, P20_00, 10_000);
        _skip(12 hours);
        assertEq(_used(), 750e6);

        _setOutflowCap(5_000e6);
        assertEq(_used(), 750e6, "the level is settled against the 2,500 cap that was in force");
        assertEq(_available(), 4_250e6);
        _skip(3 hours);
        assertEq(_used(), 125e6, "and only then refills, at the new 5,000/day rate");
        _skip(1 hours);
        assertEq(_used(), 0);

        _vaultPlace(tslaId, BID, P20_00, 10_000);
        assertEq(_used(), 2_000e6);
        _setOutflowCap(0);
        assertEq(_used(), 2_000e6, "a zero cap freezes what is used");
        _skip(10 days);
        assertEq(_used(), 2_000e6, "and never refills it");
        assertEq(_available(), 0);
    }

    /// @dev Cap 0 is a spend freeze, not a lock-up: placing a bid, a buying take and a replace UP are refused with
    ///      OutflowCapExceeded(0, x) before any USDG moves, while cancels, replaces DOWN, asks, selling takes, closes,
    ///      both ledger moves, {MakerVault.claimOwed} and {MakerVault.sync} all keep working.
    function test_outflowCap_zeroCapFreezesSpendingNotUnwinding() public {
        _vaultLedger(address(nvda), 20e18);
        _vaultLedger(address(usdg), 1_000e6);
        uint256 bid = _vaultPlace(callId, BID, P2_00, 500);
        uint256 aliceAsk = _place(alice, callId, WRITE, P2_00, 400);
        _vaultTake(_buy(callId, _ids(aliceAsk), 400, P2_00, address(vault)));
        uint256 carolBid = _place(carol, callId, BID, P2_00, 200);
        _vaultTake(_sell(callId, _ids(carolBid), 200, P2_00, true, address(vault)));
        uint256 liveAsk = _place(alice, callId, WRITE, P2_00, 100);
        uint256 liveBid = _place(carol, callId, BID, P2_00, 100);

        _setOutflowCap(0);
        assertEq(_available(), 0, "a zero cap makes every spend unaffordable");
        uint256 frozenAt = _used();

        vm.startPrank(quoter);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.OutflowCapExceeded.selector, 0, 10_000_000));
        vault.place(callId, BID, P2_00, 500, 0);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.OutflowCapExceeded.selector, 0, 2_100_000));
        vault.take(_buy(callId, _ids(liveAsk), 100, P2_00, address(vault)));
        vm.expectRevert(abi.encodeWithSelector(V2Errors.OutflowCapExceeded.selector, 0, 5_000_000));
        vault.replace(bid, P3_00, 500);
        vm.stopPrank();
        assertEq(_used(), frozenAt, "a refused call books nothing");

        vm.startPrank(quoter);
        uint256 smaller = vault.replace(bid, P2_00, 100);
        vault.place(callId, WRITE, P3_00, 100, 0);
        vault.take(_sell(callId, _ids(liveBid), 100, P2_00, false, address(vault)));
        vault.place(callId, RESALE, P3_00, 100, 0);
        vault.cancel(_ids(smaller));
        vault.close(callId, 200);
        vault.withdrawFromClearinghouse(address(usdg), 1_000e6);
        vault.depositToClearinghouse(address(usdg), 500e6);
        vault.claimOwed();
        vault.sync(_ids(callId));
        vm.stopPrank();
        assertLe(_used(), frozenAt, "unwinding only ever credits");
    }

    /// @dev INTERFACE_VERSION 8: THE CAP APPLIES TO EVERY CALLER. v7 booked the admin's calls and never checked
    ///      them, which was only safe while the mm-bot key never held DEFAULT_ADMIN_ROLE -- a property a deploy check
    ///      had to keep asserting about a key rather than one the contract held. The exemption is gone, and the
    ///      Admin Safe is itself a QUOTER member (roles.v8.json `holders`), so the caller v7 exempted is exactly the
    ///      caller this now bounds. Unwinding is still never blocked, because unwinding only ever CREDITS.
    function test_outflowCap_appliesToEveryCallerIncludingTheAdminSafe() public {
        vm.prank(admin);
        uint256 a = vault.place(callId, BID, P20_00, 10_000, 0);
        assertEq(_used(), 2_000e6, "the Admin Safe's bid is charged like anyone else's");
        assertEq(_available(), 500e6);

        // The second bid would take the Safe past the cap, and is refused -- in v7 it was allowed.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.OutflowCapExceeded.selector, 500e6, 2_000e6));
        vault.place(tslaId, BID, P20_00, 10_000, 0);

        // The quoter shares one bucket with it: there is no per-caller budget to split.
        vm.prank(quoter);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.OutflowCapExceeded.selector, 500e6, 1_000e6));
        vault.place(putId, BID, P20_00, 5_000, 0);

        // Cancelling gives back exactly what it took, from either lane, and never builds a budget.
        vm.prank(quoter);
        vault.cancel(_ids(a));
        assertEq(_used(), 0, "the cancel credits back exactly what the Safe's bid charged");
        assertEq(_available(), MAX_DAILY_OUTFLOW, "and no more");
    }

    /// @dev The treasury lane is not the quoting lane: a TREASURY_ADMIN withdrawal is not booked at all, so an
    ///      exhausted cap never traps protocol money in the vault, and a withdrawal never eats the quoter's budget.
    ///      It cannot be used as an escape either -- {MakerVault.withdraw} pays {treasury} and takes no recipient.
    function test_outflowCap_treasuryWithdrawalIsNotBooked() public {
        _vaultPlace(callId, BID, P20_00, 10_000);
        assertEq(_used(), 2_000e6, "the cap is nearly spent");

        uint256 before = usdg.balanceOf(treasury);
        vm.prank(admin);
        vault.withdraw(address(usdg), 50_000e6);
        assertEq(usdg.balanceOf(treasury) - before, 50_000e6, "the treasury got it");
        assertEq(_used(), 2_000e6, "and the bucket did not move");
    }

    /// @dev The guarantee of v7 design §4.6.4, fuzzed: whatever order and timing a compromised quoter picks, the net
    ///      USDG it moves out of the vault over an interval of length `t` is at most cap x (1 + t / OUTFLOW_WINDOW).
    function testFuzz_outflowCap_roundTripLossBoundedByCapAndRefill(uint32[6] memory gaps, uint64[6] memory sizes)
        public
    {
        uint128 cap = uint128(vault.bidCap(callId));
        uint256 start = vm.getBlockTimestamp();
        uint256 cashStart = _cash();

        for (uint256 i; i < gaps.length; ++i) {
            _skip(bound(gaps[i], 0, 8 hours));
            uint64 units = uint64(bound(sizes[i], 1, 2_000));
            uint256 ask = _tryPlace(carol, callId, WRITE, cap, units);
            if (ask != 0) {
                vm.prank(quoter);
                try vault.take(_buy(callId, _ids(ask), units, cap, address(vault))) {} catch {}
            }
            uint256 partnerBid = _tryPlace(carol, callId, BID, 100, units);
            if (partnerBid != 0) {
                vm.prank(quoter);
                try vault.take(_sell(callId, _ids(partnerBid), units, 100, false, address(vault))) {} catch {}
            }
            uint256 longs = ch.balanceOf(carol, callId);
            uint256 shorts = ch.balanceOf(carol, _short(callId));
            uint256 pair = longs < shorts ? longs : shorts;
            if (pair != 0) {
                vm.prank(carol);
                ch.close(callId, uint64(pair));
            }
        }

        uint256 cashNow = _cash();
        // T-OP-046: a sequence that left the vault no poorer has no net outflow to bound; forge counts it as a
        // rejected input rather than a pass that asserted nothing.
        vm.assume(cashNow < cashStart);
        uint256 elapsed = vm.getBlockTimestamp() - start;
        uint256 limit = uint256(MAX_DAILY_OUTFLOW) + uint256(MAX_DAILY_OUTFLOW) * elapsed / OUTFLOW_WINDOW;
        assertLe(cashStart - cashNow, limit, "net USDG out <= cap x (1 + t / OUTFLOW_WINDOW)");
    }

    /*//////////////////////////////////////////////////////////////
               COLLATERAL RENT (c05) AND THE CAP (c21)
    //////////////////////////////////////////////////////////////*/

    /// @dev A call written into an AskWrite fill. The rent is NVDA, outside a USDG measure altogether.
    function test_outflowCap_rentOn_call_askWriteFill() public {
        _rentRoundTrip(false, false);
    }

    /// @dev The same call written through {MakerVault.take} with `writeToSell`, where the vault IS the caller, so its
    ///      cash change is booked -- the premium it took in, and not one base unit of the rent it paid.
    function test_outflowCap_rentOn_call_writeToSell() public {
        _rentRoundTrip(false, true);
    }

    /// @dev A put, whose rent is USDG: it leaves the vault's CLEARINGHOUSE ledger, which the measure excludes, so it
    ///      is invisible to the cap exactly like the put collateral beside it.
    function test_outflowCap_rentOn_put_askWriteFill() public {
        _rentRoundTrip(true, false);
    }

    function test_outflowCap_rentOn_put_writeToSell() public {
        _rentRoundTrip(true, true);
    }

    /// @notice The rent a vault write actually pays at the launch rate, in the collateral asset of each side, and what
    ///         `close` pays back six hours later. Exact Solidity arithmetic, so a changed rate or rounding is a failure
    ///         here and not a silent shift in the round trips above.
    /// @dev NVDA at 80 ppm (v7 design 5.1), 500 units, 761,600 s from the fixture's clock to the 2026-09-18 weekly.
    ///      Call collateral 5e18 NVDA base units, put collateral 1,000 USDG (500 x the 200.00 strike / 100).
    function test_outflowCap_rentOn_launchRateFigures() public {
        uint256 call_ = _rentSeries(false);
        assertEq(ch.mintFee(call_, RENT_UNITS), 503_703_703_703_704, "call rent, NVDA base units, rounded up");
        uint256 put_ = _rentSeries(true);
        assertEq(ch.mintFee(put_, RENT_UNITS), 100_741, "put rent, USDG base units, rounded up");

        // `closeRefund` is clamped to the rent the series actually holds, so a refund needs a mint to have paid one.
        if (!ch.isOperator(alice, address(this))) {
            vm.prank(alice);
            ch.setOperator(address(this), true);
        }
        ch.mint(call_, RENT_UNITS, alice, alice);
        ch.mint(put_, RENT_UNITS, alice, alice);

        _skip(6 hours);
        assertEq(ch.closeRefund(call_, RENT_UNITS), 489_417_989_417_989, "call refund, rounded down");
        assertEq(ch.closeRefund(put_, RENT_UNITS), 97_883, "put refund, rounded down");
    }

    /// @dev One vault round trip on a series that charges rent: write (on either path), buy the longs back, close.
    ///      The four facts, in order: the rent debits the vault's Clearinghouse FREE balance, the cap never sees it,
    ///      the buy-back is charged to the cap as it always was, and `close` credits the unused rent back to the
    ///      ledger while `outflow().used` does not move. The bucket is seeded with a real bid first, so "unchanged"
    ///      means unchanged at a non-zero level rather than pinned at the floor.
    function _rentRoundTrip(bool isPut, bool writeToSell) private {
        uint256 id = _rentSeries(isPut);
        address asset = isPut ? address(usdg) : address(nvda);
        uint256 collateral = isPut ? uint256(RENT_UNITS) * RENT_PUT_STRIKE / 100 : uint256(RENT_UNITS) * 1e16;
        _vaultLedger(asset, collateral * 2); // collateral plus room for the rent
        uint256 freeBefore = ch.free(address(vault), asset);
        uint256 fee = ch.mintFee(id, RENT_UNITS);
        assertGt(fee, 0, "the series charges rent");

        _vaultPlace(tslaId, BID, P20_00, 5_000);
        assertEq(_used(), 1_000e6, "seed: 1,000 USDG of bid escrow, so the bucket is not sitting on its floor");

        uint256 cashBefore = _cash();
        if (writeToSell) {
            uint256 buyerBid = _place(alice, id, BID, P2_00, RENT_UNITS);
            _vaultTake(_sell(id, _ids(buyerBid), RENT_UNITS, P2_00, true, address(vault)));
            assertEq(
                _used(),
                1_000e6 - (_cash() - cashBefore),
                "the vault's own call booked its cash change and nothing else"
            );
        } else {
            uint256 ask = _vaultPlace(id, WRITE, P2_00, RENT_UNITS);
            assertEq(_used(), 1_000e6, "an ask escrows no USDG, rent or no rent");
            _take(alice, _buy(id, _ids(ask), RENT_UNITS, P2_00, alice));
            assertGt(_cash(), cashBefore, "the premium arrived");
            assertEq(_used(), 1_000e6, "a fill the vault was not called for books neither the premium nor the rent");
        }
        assertEq(
            ch.free(address(vault), asset),
            freeBefore - collateral - fee,
            "the rent debited the vault's Clearinghouse free balance, beside the locked collateral"
        );

        // the buy-back: USDG out of the wallet, charged like any other
        uint256 resale = _place(alice, id, RESALE, P2_00, RENT_UNITS);
        uint256 usedBeforeBuy = _used();
        cashBefore = _cash();
        _vaultTake(_buy(id, _ids(resale), RENT_UNITS, P2_00, address(vault)));
        uint256 spent = cashBefore - _cash();
        assertEq(spent, 10_100_000, "10 USDG of premium and the 0.10 taker fee");
        assertEq(_used(), usedBeforeBuy + spent, "and the cap charged every base unit of it");

        // the close: the unused rent comes back to the ledger and the cap does not move
        _skip(6 hours);
        uint256 refund = ch.closeRefund(id, RENT_UNITS);
        assertGt(refund, 0, "six hours in, most of the rent is still unused");
        assertLt(refund, fee, "but not all of it");
        uint256 freeBeforeClose = ch.free(address(vault), asset);
        uint256 usedBeforeClose = _used();
        assertGt(usedBeforeClose, 0, "the bucket still holds the seed and the buy-back");

        vm.prank(quoter);
        vault.close(id, RENT_UNITS);
        assertEq(
            ch.free(address(vault), asset),
            freeBeforeClose + collateral + refund,
            "close freed the collateral and credited the unused rent back to the ledger"
        );
        assertEq(_used(), usedBeforeClose, "and booked nothing: a close is not a quoter spend");
    }

    /// @dev Turns the launch rent rate on for NVDA and creates a NEW series at an out-of-the-money strike. The
    ///      fixture's own series keep the 0 they were created with (v7 design §3.8: only the rent suites move), because
    ///      `setMarketConfig` reaches series created AFTER it and nothing else.
    function _rentSeries(bool isPut) private returns (uint256 longId) {
        V2Types.MarketConfig memory cfg = ch.market(address(nvda));
        cfg.mintFeePpm = NVDA_MINT_FEE_PPM;
        vm.prank(admin);
        _reconfigure(ch, address(nvda), cfg);
        longId = ch.createSeries(address(nvda), isPut, isPut ? RENT_PUT_STRIKE : RENT_CALL_STRIKE, FRI_2026_09_18);
        assertEq(ch.series(longId).mintFeePpm, NVDA_MINT_FEE_PPM, "the new series pinned the rate");
        assertEq(ch.series(callId).mintFeePpm, 0, "and the fixture's own series still charge nothing");
    }

    /*//////////////////////////////////////////////////////////////
                                  GAS
    //////////////////////////////////////////////////////////////*/

    /// @dev The absolute cost of the four quoter calls the cap touches, for `docs/V2-GAS.md`. These are NOT four
    ///      measurements of the booking: a `place(Bid)` escrows USDG and a `place(AskWrite)` does not, so most of the
    ///      difference between them is the escrow, not `_bookOutflow`. What the booking itself adds to a booked call
    ///      is two `_cash()` reads (`usdg.balanceOf` + `orderBook.owed`) plus the one slot the level and its timestamp
    ///      share -- roughly 18-25k. The figures here are what a caller actually pays. An unbooked call (`close`, the
    ///      ledger moves, `claimOwed`, `sync`, and every ask) pays nothing for the cap at all, which is why the
    ///      unwinding path is never slowed by it.
    function test_gas_outflowBookedCalls() public {
        _vaultLedger(address(usdg), 5_000e6);
        uint256 g = gasleft();
        uint256 bid = _vaultPlace(putId, BID, P20_00, 100);
        uint256 placeBid = g - gasleft();

        g = gasleft();
        uint256 ask = _vaultPlace(putId, WRITE, P2_00, 100);
        uint256 placeAsk = g - gasleft();

        vm.prank(quoter);
        g = gasleft();
        vault.cancel(_ids(bid));
        uint256 cancelBid = g - gasleft();

        vm.prank(quoter);
        g = gasleft();
        vault.cancel(_ids(ask));
        uint256 cancelAsk = g - gasleft();

        console2.log("vault place(Bid), booked and enforced:", placeBid);
        console2.log("vault place(AskWrite), not booked:", placeAsk);
        console2.log("vault cancel(Bid), booked, never enforced:", cancelBid);
        console2.log("vault cancel(Ask), not booked:", cancelAsk);
        assertLt(placeBid, 600_000, "a booked place stays well inside the bot's gas limit");
        assertLt(cancelBid, 200_000, "and so does the cancel that credits it back");
        assertEq(_used(), 0, "the cancel credited the whole escrow");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Moves the clock forward by `seconds_`. Always through {Vm.getBlockTimestamp}: via_ir folds a later
    ///      `block.timestamp` read in the same frame to its first value, which {Vm.warp} then silently invalidates.
    function _skip(uint256 seconds_) private {
        vm.warp(vm.getBlockTimestamp() + seconds_);
    }

    /// @dev Funds and approves the quoter's own wallet so it can trade on the book beside the vault (the compromised
    ///      key holder of the c21 PoC).
    function _armQuoterEoa() private {
        usdg.mint(quoter, 10_000e6);
        vm.startPrank(quoter);
        usdg.approve(address(book), type(uint256).max);
        ch.setApprovalForAll(address(book), true);
        vm.stopPrank();
    }

    /// @dev {MakerTestBase._place} that returns 0 instead of reverting, for the fuzz driver.
    function _tryPlace(address maker, uint256 longId, V2Types.OrderKind kind, uint128 price, uint64 units)
        private
        returns (uint256)
    {
        vm.prank(maker);
        try book.place(longId, kind, price, units, 0) returns (uint256 id) {
            return id;
        } catch {
            return 0;
        }
    }
}
