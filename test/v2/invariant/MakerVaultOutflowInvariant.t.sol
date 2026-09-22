// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MakerTestBase} from "../unit/MakerBase.t.sol";
import {MakerVaultOutflowHandler} from "./MakerVaultOutflowHandler.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";

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
///        2. `used` never exceeds the cap, and `available` is exactly what is left of it, FOR EVERY CALLER. In v7
///           this invariant was `…ForANonAdmin` and held only because the handler kept the admin out of the quoting
///           actions: the admin was booked but never checked. C8-05 removed that exemption, the handler's Admin Safe
///           now rests bids of its own ({MakerVaultOutflowHandler.safeBid}) into the same bucket, and the invariant
///           is renamed to say what it now claims. The unit twin is
///           `MakerVaultOutflowTest.test_outflowCap_appliesToEveryCallerIncludingTheAdminSafe`.
///        3. Credits never build a budget: `available` is never above the cap, however much USDG comes back in.
///
///      WHY BEFORE EXPIRY. The handler's clock never reaches the series' expiry, so nothing settles and no redemption
///      pays anyone. After settlement a put short's locked collateral is split between the writer and the holder, and
///      the part that goes to the holder is an option payout, not an outflow the quoter caused; invariant 1 would
///      then be measuring the wrong thing.
///
///      NON-VACUITY lives in {test_handlerExercisesEveryLeg}, not in an `afterInvariant`: an invariant run's state is
///      rolled back between runs, so a per-run coverage assertion would be a coin toss over 256 runs.
///
///      T-OP-011: CAN THESE THREE FAIL AT ALL? Asked of all three, first at
///      25de038b6fc699ebd0ad0c6449eec58993d52ef1 and again at 6b0a4e7c4091becac8180b83f8c00feab889e1a5 (the numbers
///      below are the second measurement; the first agreed in every verdict), because 256 runs / 16,384 calls /
///      0 reverts is the same green whether the campaign entered the protected state 16,384 times or never.
///      Measured, not argued -- every mutation was a single-anchor edit, grepped back before the run, restored
///      byte-identical to HEAD after it, and followed by a clean rerun that was 4 of 4 green:
///        - REACHABILITY, by planting an unconditional revert in the branch and watching exactly that invariant go
///          red. `revert` after invariant 1's `if (back >= left) return;` reddened invariant 1 (shrunk to one call,
///          `quoterDrainRoundTrip`) while 2 and 3 stayed green: the bound's ASSERTION branch is entered, not
///          skipped. `revert` when `used != 0` in invariant 2 reddened invariant 2 alone (shrunk from 17 calls to one
///          `quoterBid`): the bucket is charged while the invariants look at it. `revert` when
///          `available < MAX_DAILY_OUTFLOW` in invariant 3 reddened invariant 3 alone (one `safeBid`): it reads a
///          partly spent budget, so it is not looking at an untouched cap either. Each probe also reddened
///          {test_handlerExercisesEveryLeg}, which calls all three at its end -- that is the positive control that
///          the edit was live.
///        - FAILABILITY, by breaking the property rather than the assertion: `enforce` was disabled in
///          {MakerVault._bookOutflow} (`if (false && enforce && ...)`, MakerVault.sol:666), so the quoter could
///          drain past the cap. Invariant 1 failed naming itself (3,918.86 USDG out against a 3,357.64 limit) and
///          invariant 2 failed naming itself (used 3,840.74 against a 2,500.00 cap), both shrunk from 41 calls to
///          two `quoterDrainRoundTrip`s; the scripted leg failed at `capReverts` as its own control. Both have
///          teeth.
///        - INVARIANT 3 STAYED GREEN THROUGH THAT SAME RUN. For the property it is NAMED for -- credits never build
///          a budget -- it is VACUOUS BY CONSTRUCTION rather than by poor coverage. {MakerVault.outflow} returns
///          `available = cap > used ? cap - used : 0` with `cap = _limits.maxDailyOutflow` (MakerVault.sol:546-549),
///          and nothing in this campaign calls {MakerVault.setLimits}, so `available <= MAX_DAILY_OUTFLOW` holds
///          for EVERY state the fuzzer can build, including states that violate the cap outright. It is also
///          strictly implied by invariant 2's `assertEq(available, MAX_DAILY_OUTFLOW - used)`. What it CAN catch
///          is the view lying: with `available = cap + 1` planted at MakerVault.sol:549 it went red naming itself
///          (`2500000001 > 2500000000`) before the first call, as did invariant 2. So it is a live pin on the clamp
///          at :549 and nothing more. It is left in place deliberately -- deleting it is a design decision, not a
///          test fix -- but it is NOT evidence that credits cannot build a budget. That property lives in
///          {MakerVault._bookOutflow}'s credit arm flooring the bucket at 0 (MakerVault.sol:672-673), and the thing
///          that actually pins it is `MakerVaultOutflowTest.test_outflowCap_*`. Credits ARE exercised here --
///          {MakerVaultOutflowHandler.creditCalls} moves -- so this is not a coverage gap that more runs would fix.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract MakerVaultOutflowInvariantTest is MakerTestBase {
    MakerVaultOutflowHandler internal handler;

    /// @dev The vault's USDG cash when the campaign starts (wallet plus owed, which is 0 then).
    uint256 internal initialCash;

    /// @dev T-OP-046. How many times invariant 1 asserted its bound and how many times it had nothing to bound
    ///      (the vault could recover at least what it paid out). `vm.assume` has no meaning inside an invariant
    ///      body, so the honest shape is this pair plus the floor in {test_handlerExercisesEveryLeg}: a campaign
    ///      that never entered the assertion arm would otherwise be the same green as one that did. The campaign
    ///      itself rolls state back between runs, so only the scripted pass can read these.
    uint256 public boundChecked;
    uint256 public boundSkipped;

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
            FRI_2026_09_18 - 2 days,
            initialCash
        );
        vm.label(address(handler), "OutflowHandler");
        targetContract(address(handler));
    }

    /// @dev Invariant 1: the guarantee the cap exists to buy.
    function invariant_netOutflowIsBoundedByTheCapAndItsRefill() public {
        uint256 left = initialCash + handler.outsideInflow();
        uint256 back = handler.recoverable();
        if (back >= left) {
            // Nothing to bound: the vault can get back at least what it paid out. Counted, not returned (T-OP-046).
            ++boundSkipped;
        } else {
            ++boundChecked;
            uint256 limit =
                uint256(MAX_DAILY_OUTFLOW) + uint256(MAX_DAILY_OUTFLOW) * handler.elapsed() / vault.OUTFLOW_WINDOW();
            assertLe(left - back, limit, "net USDG out <= maxDailyOutflow x (1 + elapsed / OUTFLOW_WINDOW)");
        }
    }

    /// @dev Invariant 2: no booked call by ANY caller ever leaves the bucket above the cap, and the view agrees
    ///      with itself. The campaign quotes from two different QUOTER members, the mm-bot key and the Admin Safe,
    ///      and they share one bucket -- there is no per-caller budget and no exempt caller.
    function invariant_usedNeverAboveTheCapForEveryCaller() public view {
        (uint256 used, uint256 available) = vault.outflow();
        assertLe(used, MAX_DAILY_OUTFLOW, "used <= cap for every caller, bot key or Admin Safe");
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
        // The caller v7 exempted rests one too, into the same bucket.
        handler.safeBid(0, 0, 2_000_000, 500, 0);
        assertGt(handler.safeBidsPlaced(), 0, "the Admin Safe rested a bid of its own");
        handler.quoterAsk(0, 0, false, 3_000_000, 500, 0);
        assertGt(handler.asksPlaced(), 0, "the vault rested an ask");
        handler.quoterReplace(0, 0, 1_000_000, 400);
        assertGt(handler.replaces(), 0, "the vault replaced one");
        handler.outsiderFillsVaultOrder(0, 2, 1, 100);
        // T-OP-010. The message carries the handler's own diagnosis, so a red here says WHICH of the two zero
        // causes fired -- `returnedZero=1` is T-583's shape (no long to sell), `reverted=1 lastRevert=0x...` is a
        // refused take with its selector -- instead of the bare `0 <= 0` both used to print.
        assertGt(
            handler.vaultOrdersFilledByOutsiders(),
            0,
            string.concat("an outsider filled a vault order between vault calls: ", handler.outsiderTakeDiagnosis())
        );

        // The c14/c21 round trip on TSLA, whole (5,000 units at the 35.80 bid cap is 1,790 USDG of the 2,500 cap),
        // and the refusal that follows when the second one asks for the same again.
        handler.quoterDrainRoundTrip(0, 2, 2, 5_000);
        assertGt(handler.peakUsed(), 1_700e6, "one round trip spent most of the cap");
        handler.quoterDrainRoundTrip(0, 2, 2, 5_000);
        assertGt(handler.capReverts(), 0, "the outflow cap refused the second round trip's buy leg");

        // Unwinding, and the keeper cleaning up after an expired quote.
        // T-583. THE VAULT MUST HOLD A PAIR BEFORE IT CAN CLOSE ONE, and nothing above this line ever gave it a
        // short. Measured at this point before this line existed: 600 longs, 0 SHORTS, so `quoterClose` took its
        // `if (pair == 0) return;` path and `closes` never moved -- a second control that could not fire, sitting
        // directly behind the one this row was opened for. It had never been observed because the run failed at
        // the outsider-fill assertion eleven lines above and never reached here. `preferWrite: true` makes the
        // vault WRITE the pair it then closes: it mints a long and a short, sells the long into a resting
        // outsider bid, and keeps the short. Measured after: 600 longs, 100 shorts.
        handler.quoterSell(0, 0, 100, true);
        handler.quoterClose(0, 0, 100);
        assertGt(handler.closes(), 0, "the vault closed a pair");
        handler.quoterCancel(0, 0);
        assertGt(handler.cancels(), 0, "the vault cancelled an order");
        handler.safeCancel(0, 0);
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

        // T-OP-011. The three states the three invariants are ABOUT, pinned deterministically: without these a
        // green campaign says only that nothing broke in states nobody showed it ever reached.
        assertGt(handler.netOutPositiveCalls(), 0, "the vault was measured having paid out more than it can recover");
        assertGt(handler.peakNetOut(), 0, "the bound was asserted against a real net payout, not an early return");
        assertGt(handler.usedNonZeroCalls(), 0, "the outflow bucket held a charge while the invariants read it");
        assertGt(handler.creditCalls(), 0, "budget came back, which is what invariant 3 is named for");

        invariant_netOutflowIsBoundedByTheCapAndItsRefill();
        invariant_usedNeverAboveTheCapForEveryCaller();
        invariant_creditsNeverBuildABudget();
        // T-OP-046: the scripted pass ends in a net-payout state, so invariant 1 must have taken its assertion
        // arm here, not the nothing-to-bound arm; this is the floor the campaign's counter pair reports against.
        assertGt(boundChecked, 0, "invariant 1 asserted its bound at least once in the scripted pass");
        assertEq(boundSkipped, 0, "the scripted pass never reached invariant 1 with nothing to bound");
    }

    /// @notice T-OP-010, PROVE BY BREAKING. Force the outsider's `take` to REVERT -- the shape the old bare `catch {}`
    ///         swallowed -- and show the handler now says so. Before this row, this exact state left
    ///         `vaultOrdersFilledByOutsiders == 0` with nothing to distinguish it from T-583's `(0,0,0)` return; the
    ///         three assertions below are the distinction. The pause is the GUARDIAN's own lever, so the revert is
    ///         the real `TradingPaused()` from `OrderBook._whenTrading`, not a mock's.
    function test_T_OP_010_aRevertedOutsiderTakeIsReportedNotSwallowed() public {
        // The same set-up as the scripted pass, up to a live vault order an outsider could fill.
        handler.outsiderQuote(0, 0, 0, 0, 2_000_000, 2_000); // alice: Bid 2.00
        handler.outsiderQuote(0, 1, 0, 2, 2_000_000, 2_000); // bob: AskWrite 2.00
        handler.quoterBuy(0, 0, 1_000);
        handler.quoterBid(0, 0, 2_000_000, 500, 0);
        assertGt(handler.bidsPlaced(), 0, "positive control: the vault rested a bid for the outsider to fill");

        // NEGATIVE CONTROL first: with the book open the same call fills, so the counters below are not zero for
        // a reason unrelated to the pause.
        handler.outsiderFillsVaultOrder(0, 2, 1, 100);
        assertGt(handler.vaultOrdersFilledByOutsiders(), 0, "control: the outsider filled while the book was open");
        assertEq(handler.outsiderTakeReverts(), 0, "control: no revert while the book was open");

        // THE BREAK: the GUARDIAN lane pauses trading, so `OrderBook.take` reverts `TradingPaused()` before it
        // plans. In this fixture `_wire(address(book), "OrderBook", admin, 0)` (MakerBase.t.sol) granted every book
        // role to `admin`, GUARDIAN included; `guardian` holds nothing here, so `admin` is the pauser.
        uint256 filledBefore = handler.vaultOrdersFilledByOutsiders();
        vm.prank(admin);
        book.setTradingPaused(true);
        handler.outsiderFillsVaultOrder(0, 2, 1, 100);

        // THE DISTINCTION. A reader of `outsiderTakeDiagnosis()` sees `reverted=1 lastRevert=0x<TradingPaused>`,
        // not a bare zero; and the fill counter did not move, so the old symptom is reproduced WITH its cause.
        assertEq(handler.vaultOrdersFilledByOutsiders(), filledBefore, "a refused take fills nothing");
        assertEq(handler.outsiderTakeReverts(), 1, "the revert was counted, not swallowed");
        assertEq(
            handler.lastOutsiderTakeRevert(),
            abi.encodeWithSelector(V2Errors.TradingPaused.selector),
            "the revert reason was kept, and it is the book's own TradingPaused()"
        );
        assertEq(
            handler.outsiderTakesReturnedZero(), 0, "the paused take did not take the (0,0,0) branch: the two causes differ"
        );
    }
}
