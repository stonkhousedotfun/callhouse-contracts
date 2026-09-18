// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MakerTestBase} from "../unit/MakerBase.t.sol";
import {MakerVaultOutflowHandler} from "./MakerVaultOutflowHandler.sol";

/// @notice Stateful invariants of the MakerVault's daily net USDG outflow cap (sweep contracts-c21,
///         INTERFACE_VERSION 7, v7 design §4.6, §6.4), asserted after every call of {MakerVaultOutflowHandler} on the
///         real MakerVault, OrderBook and Clearinghouse.
/// @dev CONFIG. runs = 256, depth = 64, set inline like {V2InvariantTest}. fail-on-revert is on: the handler bounds
///      every argument into the legal range and swallows the protocol's own refusals, so a revert reaching the fuzzer
///      is a bug in the handler, not a finding.
///
///      THE INVARIANTS.
///        1. THE BOUND (v7 design §4.6.4). The net USDG the quoter has moved out of the vault, measured as
///           `initialCash + outsideInflow - recoverable`, never exceeds `maxDailyOutflow x (1 + elapsed / 24 h)`.
///           `recoverable` is the vault's wallet, what the book owes it, its free USDG ledger balance, the escrow the
///           book still holds for its live bids, and the USDG its put shorts have locked — everything it can still
///           get back without anyone's permission. Long tokens it bought are deliberately NOT in that sum: a
///           compromised quoter buying worthless options at the bid cap is exactly the loss being bounded.
///        2. `used` never exceeds the cap, and `available` is exactly what is left of it. The handler's admin never
///           quotes, so the admin exemption cannot lift this (it is pinned separately by
///           `MakerVaultOutflowTest.test_outflowCap_adminBookedNotChecked`).
///        3. Credits never build a budget: `available` is never above the cap, however much USDG comes back in.
///
///      WHY BEFORE EXPIRY. The handler's clock never reaches the series' expiry, so nothing settles and no redemption
///      pays anyone. After settlement a put short's locked collateral is split between the writer and the holder, and
///      the part that goes to the holder is an option payout, not an outflow the quoter caused; invariant 1 would
///      then be measuring the wrong thing.
///
///      NON-VACUITY lives in {test_handlerExercisesEveryLeg}, not in an `afterInvariant`: an invariant run's state is
///      rolled back between runs, so a per-run coverage assertion would be a coin toss over 256 runs.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract MakerVaultOutflowInvariantTest is MakerTestBase {
    MakerVaultOutflowHandler internal handler;

    /// @dev The vault's USDG cash when the campaign starts (wallet plus owed, which is 0 then).
    uint256 internal initialCash;

    function setUp() public override {
        super.setUp();
        initialCash = _cash();

        // Write collateral for both sides, as a funded launch vault holds. A ledger move is never booked and stays
        // inside the recoverable side of the measure, so it does not move the bound.
        vm.startPrank(quoter);
        vault.depositToClearinghouse(address(nvda), 100e18);
        vault.depositToClearinghouse(address(tsla), 100e18);
        vault.depositToClearinghouse(address(usdg), 50_000e6);
        vm.stopPrank();

        handler = new MakerVaultOutflowHandler(
            ch,
            book,
            vault,
            usdg,
            oracle,
            address(nvda),
            [quoter, admin, keeper, makeAddr("funder")],
            [alice, bob, carol],
            [callId, putId, tslaId],
            FRI_2026_09_18 - 2 days
        );
        vm.label(address(handler), "OutflowHandler");
        targetContract(address(handler));
    }

    /// @dev Invariant 1: the guarantee the cap exists to buy.
    function invariant_netOutflowIsBoundedByTheCapAndItsRefill() public view {
        uint256 left = initialCash + handler.outsideInflow();
        uint256 back = handler.recoverable();
        if (back >= left) return;
        uint256 limit =
            uint256(MAX_DAILY_OUTFLOW) + uint256(MAX_DAILY_OUTFLOW) * handler.elapsed() / vault.OUTFLOW_WINDOW();
        assertLe(left - back, limit, "net USDG out <= maxDailyOutflow x (1 + elapsed / OUTFLOW_WINDOW)");
    }

    /// @dev Invariant 2: no quoter call ever leaves the bucket above the cap, and the view agrees with itself.
    function invariant_usedNeverAboveTheCapForANonAdmin() public view {
        (uint256 used, uint256 available) = vault.outflow();
        assertLe(used, MAX_DAILY_OUTFLOW, "used <= cap while only the quoter trades");
        assertEq(available, MAX_DAILY_OUTFLOW - used, "available is exactly the rest of the cap");
    }

    /// @dev Invariant 3: escrow coming back, income and outside USDG never make tomorrow's budget bigger.
    function invariant_creditsNeverBuildABudget() public view {
        (, uint256 available) = vault.outflow();
        assertLe(available, MAX_DAILY_OUTFLOW, "available never above the cap");
    }

    /// @dev NON-VACUITY, deterministically. One scripted pass through the handler moves every counter the campaign
    ///      relies on: the vault rests a bid and an ask, buys, sells, gets filled by an outsider between its own
    ///      calls, replaces, cancels, closes a pair, has an expired order pruned by a keeper, and receives USDG from
    ///      outside. A green campaign is therefore evidence about the cap and not about a handler that does nothing.
    function test_handlerExercisesEveryLeg() public {
        // Outsiders rest both sides of the NVDA call, and the vault trades against them.
        handler.outsiderQuote(0, 0, 0, 0, 2_000_000, 2_000); // alice: Bid 2.00
        handler.outsiderQuote(0, 1, 0, 2, 2_000_000, 2_000); // bob: AskWrite 2.00
        handler.quoterBuy(0, 0, 1_000);
        assertGt(handler.buysFilled(), 0, "the vault bought");
        handler.quoterSell(0, 0, 500, false);
        assertGt(handler.salesFilled(), 0, "the vault sold");

        // The vault rests its own quotes, and an outsider fills one between vault calls.
        handler.quoterBid(0, 0, 2_000_000, 500, 0);
        assertGt(handler.bidsPlaced(), 0, "the vault rested a bid");
        handler.quoterAsk(0, 0, false, 3_000_000, 500, 0);
        assertGt(handler.asksPlaced(), 0, "the vault rested an ask");
        handler.quoterReplace(0, 0, 1_000_000, 400);
        assertGt(handler.replaces(), 0, "the vault replaced one");
        handler.outsiderFillsVaultOrder(0, 2, 1, 100);
        assertGt(handler.vaultOrdersFilledByOutsiders(), 0, "an outsider filled a vault order between vault calls");

        // The c14/c21 round trip on TSLA, whole (5,000 units at the 35.80 bid cap is 1,790 USDG of the 2,500 cap),
        // and the refusal that follows when the second one asks for the same again.
        handler.quoterDrainRoundTrip(0, 2, 2, 5_000);
        assertGt(handler.peakUsed(), 1_700e6, "one round trip spent most of the cap");
        handler.quoterDrainRoundTrip(0, 2, 2, 5_000);
        assertGt(handler.capReverts(), 0, "the outflow cap refused the second round trip's buy leg");

        // Unwinding, and the keeper cleaning up after an expired quote.
        handler.quoterClose(0, 0, 100);
        assertGt(handler.closes(), 0, "the vault closed a pair");
        handler.quoterCancel(0, 0);
        assertGt(handler.cancels(), 0, "the vault cancelled an order");
        // Each call advances the clock by at most 30 minutes, and a scripted order lives exactly that long.
        handler.keeperPrunes(uint32(29 minutes));
        handler.keeperPrunes(uint32(29 minutes));
        handler.keeperPrunes(uint32(29 minutes));
        assertGt(handler.prunes(), 0, "a keeper pruned an expired vault order");

        // USDG from outside, and the ledger moves that must stay invisible to the cap.
        handler.usdgArrivesFromOutside(0, false, 1_000e6);
        handler.usdgArrivesFromOutside(0, true, 1_000e6);
        assertEq(handler.outsideInflow(), 2_000e6, "both routes counted");
        handler.quoterLedger(0, 0, true, false, 100e6);
        handler.quoterLedger(0, 0, true, true, 100e6);

        assertGt(handler.peakUsed(), 0, "the cap was exercised");
        invariant_netOutflowIsBoundedByTheCapAndItsRefill();
        invariant_usedNeverAboveTheCapForANonAdmin();
        invariant_creditsNeverBuildABudget();
    }
}
