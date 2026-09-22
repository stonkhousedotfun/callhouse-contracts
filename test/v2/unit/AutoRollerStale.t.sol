// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2, Vm} from "forge-std/Test.sol";
import {AutoRollerTestBase} from "./AutoRollerBase.t.sol";
import {AutoRoller} from "../../../src/v2/AutoRoller.sol";
import {IAutoRoller} from "../../../src/v2/interfaces/IAutoRoller.sol";
import {IKeeperRewards} from "../../../src/v2/interfaces/IKeeperRewards.sol";
import {IOrderBook} from "../../../src/v2/interfaces/IOrderBook.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MockSettlementOracle} from "../../../src/v2/mocks/MockSettlementOracle.sol";

/// @notice Exposes {AutoRoller._overtaken}. v2.0 writes calls only, so the put branch has no series to reach it with.
contract AutoRollerHarness is AutoRoller {
    constructor(IOrderBook book_, address authority_) AutoRoller(book_, authority_) {}

    function overtaken(bool isPut, uint256 strike, uint256 spotPrice) external pure returns (bool) {
        return _overtaken(isPut, strike, spotPrice);
    }
}

/// @notice {AutoRoller.cancelStale} (INTERFACE_VERSION 7, sweep contracts-c16): the permissionless withdrawal of an ask
///         the spot has reached, its trigger, its gate, its bounty, what it leaves behind, and {AutoRoller.reprice}'s
///         matching InTheMoney refusal.
/// @dev The fixture's oracle keeps its 1 h spotMaxAge; the tests that need the launch registry's 25 h raise it with
///      {AutoRollerTestBase._setSpotMaxAge}. Alice is the writer, 10 NVDA in the ledger, strategy 5 % out of the money
///      at 1.5 %, so the Thursday 10:00 roll at spot 220.00 writes the 231.00 strike and asks 3.30 for 1,000 units.
contract AutoRollerStaleTest is AutoRollerTestBase {
    uint256 internal constant SESSION = 6 hours + 30 minutes;

    /// @dev The Thursday 10:00 roll every test starts from: strike 231.00, ask 3.30, 1,000 units, expiry Friday 09-11.
    function _rolled() internal returns (Rolled memory r) {
        _setStrategy(alice, _weekly(500, 150));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        r = _mustRoll(alice);
        assertEq(r.strike, K_231, "strike 231");
        assertEq(r.units, 1000, "1,000 units");
    }

    /// @dev A feed print of `answer` (8 dp) at `t`, pushed twice so the head round and its predecessor agree and the
    ///      source's round-jump guard never fires however far the price moved.
    function _printAt(uint256 t, int256 answer) internal {
        vm.warp(t - 1);
        feed.push(answer, t - 1);
        _spotAt(t, answer);
    }

    function _cancelStale(address caller) internal returns (bool) {
        vm.prank(caller);
        return roller.cancelStale(alice, address(nvda));
    }

    /// @dev cancelStale must do nothing at all: no cancel, no position change, no bounty, no order state change.
    function _noCancel(string memory why) internal {
        (uint256 longBefore, uint256 orderBefore, uint40 expiryBefore) = roller.position(alice, address(nvda));
        uint256 keeperBefore = usdg.balanceOf(keeper);
        bool cancelled = _cancelStale(keeper);
        assertFalse(cancelled, why);
        (uint256 longAfter, uint256 orderAfter, uint40 expiryAfter) = roller.position(alice, address(nvda));
        assertEq(longAfter, longBefore, "position long unchanged");
        assertEq(orderAfter, orderBefore, "position order unchanged");
        assertEq(expiryAfter, expiryBefore, "position expiry unchanged");
        assertEq(usdg.balanceOf(keeper), keeperBefore, "no bounty");
    }

    /*//////////////////////////////////////////////////////////////
                                TRIGGER
    //////////////////////////////////////////////////////////////*/

    /// No margin: the strike itself is already reached.
    function test_trigger_spotExactlyAtTheStrike_cancels() public {
        Rolled memory r = _rolled();
        uint256 t = _ny(THU_0910, 11, 0, 0);
        _printAt(t, 231_00000000);

        vm.expectEmit(address(roller));
        emit IAutoRoller.StaleAskCancelled(alice, address(nvda), r.longId, r.orderId, K_231, t);
        assertTrue(_cancelStale(keeper), "spot == strike cancels");
        assertTrue(_order(r.orderId).cancelled, "ask withdrawn");
    }

    function test_trigger_oneBaseUnitBelowTheStrike_doesNothing() public {
        _rolled();
        _printAt(_ny(THU_0910, 11, 0, 0), 230_99999900); // 230.999999 USDG
        _noCancel("one base unit below the strike");
    }

    /// The withdrawal moves no collateral and no option tokens, and pays only the caller's bounty.
    function test_cancel_movesNoCollateral() public {
        Rolled memory r = _rolled();
        uint256 freeBefore = _free(alice);
        _printAt(_ny(THU_0910, 11, 0, 0), 260_00000000);

        assertTrue(_cancelStale(keeper), "cancelled");
        assertEq(_free(alice), freeBefore, "the ledger never moves");
        assertEq(nvda.balanceOf(alice), ACTOR_SHARES - WRITER_SHARES, "the wallet never moves");
        assertEq(ch.balanceOf(alice, r.longId), 0, "no longs minted");
        assertEq(ch.balanceOf(alice, r.longId | 1), 0, "no shorts minted");
        _assertRollerEmpty(r.longId);
    }

    /// OrderCancelled (the book), then StaleAskCancelled, then the bounty's logs.
    function test_cancel_logOrder() public {
        Rolled memory r = _rolled();
        _printAt(_ny(THU_0910, 11, 0, 0), 240_00000000);

        vm.recordLogs();
        vm.prank(keeper);
        roller.cancelStale(alice, address(nvda));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 cancelIdx = type(uint256).max;
        uint256 staleIdx = type(uint256).max;
        uint256 rewardIdx = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(book) && logs[i].topics[0] == IOrderBook.OrderCancelled.selector) {
                cancelIdx = i;
            }
            if (logs[i].emitter == address(roller) && logs[i].topics[0] == IAutoRoller.StaleAskCancelled.selector) {
                staleIdx = i;
            }
            if (
                logs[i].emitter == address(rewards) && logs[i].topics[0] == IKeeperRewards.Rewarded.selector
                    && logs[i].topics[2] == V2Constants.ACTION_CANCEL_STALE
            ) rewardIdx = i;
        }
        assertLt(cancelIdx, staleIdx, "OrderCancelled before StaleAskCancelled");
        assertLt(staleIdx, rewardIdx, "StaleAskCancelled before the bounty");
    }

    /*//////////////////////////////////////////////////////////////
                              NOTHING TO DO
    //////////////////////////////////////////////////////////////*/

    function test_noPosition_doesNothing() public {
        _setStrategy(alice, _weekly(500, 150));
        _printAt(_ny(THU_0910, 11, 0, 0), 260_00000000);
        _noCancel("never rolled");
    }

    function test_afterStop_doesNothing() public {
        _rolled();
        vm.prank(alice);
        roller.stop(address(nvda));
        _printAt(_ny(THU_0910, 11, 0, 0), 260_00000000);
        _noCancel("stop already cancelled the ask");
    }

    function test_fullyFilled_doesNothing() public {
        Rolled memory r = _rolled();
        vm.warp(_ny(THU_0910, 10, 30, 0));
        assertEq(_buy(bob, r.longId, r.orderId, 1000), 1000, "bob bought it all");
        _printAt(_ny(THU_0910, 11, 0, 0), 260_00000000);
        _noCancel("nothing left to withdraw");
    }

    function test_writerCancelledItself_doesNothing() public {
        Rolled memory r = _rolled();
        uint256[] memory ids = new uint256[](1);
        ids[0] = r.orderId;
        vm.prank(alice);
        book.cancel(ids);
        _printAt(_ny(THU_0910, 11, 0, 0), 260_00000000);
        _noCancel("already cancelled by its maker");
    }

    function test_pastTheMintCutoff_doesNothing() public {
        Rolled memory r = _rolled();
        _printAt(uint256(_order(r.orderId).validUntil), 260_00000000);
        _noCancel("at validUntil the ask is already dead");
    }

    function test_afterExpiry_doesNothing() public {
        _rolled();
        _printAt(uint256(FRI_2026_09_11) + 1, 260_00000000);
        _noCancel("the period is over");
    }

    function test_spotBelowTheStrike_doesNothing() public {
        _rolled();
        _printAt(_ny(THU_0910, 11, 0, 0), 225_00000000);
        _noCancel("still out of the money");
    }

    /*//////////////////////////////////////////////////////////////
                               FRESHNESS
    //////////////////////////////////////////////////////////////*/

    /// The fixture's 1 h spotMaxAge: a crossing print is actionable for exactly an hour.
    function test_freshness_oneHour() public {
        _rolled();
        uint256 t = _ny(THU_0910, 11, 0, 0);
        _printAt(t, 240_00000000);
        vm.warp(t + 1 hours + 1);
        _noCancel("one second too old");
        vm.warp(t + 1 hours);
        assertTrue(_cancelStale(keeper), "exactly spotMaxAge old is fresh");
    }

    /// With the launch registry's 25 h a crossing print from the previous session still withdraws the ask overnight,
    /// when the book trades and no session is open. Freshness is trySpot and nothing more, deliberately: a
    /// session-only bound would leave the ask live exactly where nobody can withdraw it.
    function test_freshness_previousSessionPrintCancelsOvernight() public {
        _setSpotMaxAge(SPOT_MAX_AGE_25H);
        Rolled memory r = _rolled();
        _printAt(_ny(THU_0910, 15, 59, 0), 240_00000000);

        vm.warp(_ny(THU_0910, 22, 0, 0)); // after hours, no session, the same print
        assertTrue(_cancelStale(keeper), "no session needed");
        assertTrue(_order(r.orderId).cancelled, "withdrawn overnight");
    }

    /// The market's own spotMaxAge is the whole freshness rule: exactly 25 h old still cancels, one second more does
    /// not. The position runs to next week's weekly so a full day can pass inside it.
    function test_freshness_pastSpotMaxAge_doesNothing() public {
        _setSpotMaxAge(SPOT_MAX_AGE_25H);
        _setStrategy(alice, _weekly(500, 150));
        _spotAt(_ny(FRI_0911, 10, 0, 0), 220_00000000);
        Rolled memory r = _mustRoll(alice);
        assertEq(r.expiry, FRI_2026_09_18, "next week's weekly");

        uint256 t = _ny(FRI_0911, 11, 0, 0);
        _printAt(t, 240_00000000);
        vm.warp(t + 25 hours);
        uint256 snap = vm.snapshotState();
        assertTrue(_cancelStale(keeper), "exactly spotMaxAge old is fresh");
        vm.revertToState(snap);

        vm.warp(t + 25 hours + 1);
        _noCancel("25 h + 1 s is past spotMaxAge");
    }

    /// An old reading below the strike never triggers, however fresh a later crossing was not printed.
    function test_freshness_oldReadingBelowTheStrikeNeverTriggers() public {
        _setSpotMaxAge(SPOT_MAX_AGE_25H);
        _rolled();
        _printAt(_ny(THU_0910, 15, 59, 0), 225_00000000);
        vm.warp(_ny(FRI_0911, 9, 0, 0));
        _noCancel("the last print is below the strike");
    }

    function test_oraclePaused_doesNothing_thenWorks() public {
        _rolled();
        _printAt(_ny(THU_0910, 11, 0, 0), 260_00000000);
        nvda.setOraclePaused(true);
        _noCancel("issuer oracle pause");
        nvda.setOraclePaused(false);
        assertTrue(_cancelStale(keeper), "works once cleared");
    }

    function test_feedReverting_doesNothing_thenWorks() public {
        _rolled();
        _printAt(_ny(THU_0910, 11, 0, 0), 260_00000000);
        feed.setReverts(true);
        _noCancel("source 0 down");
        feed.setReverts(false);
        assertTrue(_cancelStale(keeper), "works once the feed is back");
    }

    /*//////////////////////////////////////////////////////////////
                          PAUSES AND APPROVALS
    //////////////////////////////////////////////////////////////*/

    /// Withdrawing an ask only reduces risk, so every pause and a disabled market leave it working.
    function test_runsUnderEveryPauseAndOnADisabledMarket() public {
        Rolled memory r = _rolled();
        _printAt(_ny(THU_0910, 11, 0, 0), 260_00000000);

        vm.startPrank(guardian);
        book.setTradingPaused(true);
        ch.setMintPaused(address(nvda), true);
        ch.setCreatePaused(true);
        vm.stopPrank();
        V2Types.MarketConfig memory m = ch.market(address(nvda));
        m.enabled = false;
        vm.prank(admin);
        _reconfigure(ch, address(nvda), m);

        assertTrue(_cancelStale(keeper), "cancel is never pausable");
        assertTrue(_order(r.orderId).cancelled, "withdrawn");
    }

    /// The cancel is a direct call: a writer who revoked the roller as delegate makes it revert, rather than reporting
    /// a withdrawal that did not happen. The writer is the maker and can cancel the ask itself.
    function test_delegateRevoked_reverts() public {
        Rolled memory r = _rolled();
        _printAt(_ny(THU_0910, 11, 0, 0), 260_00000000);
        vm.prank(alice);
        book.setDelegate(address(roller), false);

        vm.prank(keeper);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        roller.cancelStale(alice, address(nvda));
        (, uint256 orderId,) = roller.position(alice, address(nvda));
        assertEq(orderId, r.orderId, "still tracked");
        assertFalse(_order(r.orderId).cancelled, "still live");

        vm.prank(alice);
        book.setDelegate(address(roller), true);
        assertTrue(_cancelStale(keeper), "resumes");
    }

    /// A cancelStale sent with too little gas reverts; it never returns true with the ask still live (sweep
    /// contracts-c20, the same property {AutoRoller.stop} is held to).
    function test_withTooLittleGas_neverReportsAWithdrawalThatDidNotHappen() public {
        Rolled memory r = _rolled();
        _printAt(_ny(THU_0910, 11, 0, 0), 260_00000000);

        uint256 succeeded;
        for (uint256 g = 30_000; g <= 260_000; g += 500) {
            uint256 snap = vm.snapshotState();
            vm.prank(keeper);
            (bool ok, bytes memory ret) =
                address(roller).call{gas: g}(abi.encodeCall(AutoRoller.cancelStale, (alice, address(nvda))));
            if (ok && ret.length == 32 && abi.decode(ret, (bool))) {
                ++succeeded;
                assertTrue(
                    _order(r.orderId).cancelled,
                    string.concat("returned true with the ask live at gas ", vm.toString(g))
                );
                (, uint256 orderId,) = roller.position(alice, address(nvda));
                assertEq(orderId, 0, "no ask tracked");
            }
            vm.revertToState(snap);
        }
        assertGt(succeeded, 0, "the range reaches a full cancel");
    }

    /*//////////////////////////////////////////////////////////////
                             WHAT IT LEAVES
    //////////////////////////////////////////////////////////////*/

    /// No re-roll inside the period: the position keeps its series and expiry with no ask, stop returns early, reprice
    /// reverts OrderNotLive(0), a new strategy changes nothing, and the close-out after expiry still runs.
    function test_afterCancel_noReRollInThePeriod() public {
        Rolled memory r = _rolled();
        _printAt(_ny(THU_0910, 11, 0, 0), 260_00000000);
        assertTrue(_cancelStale(keeper), "cancelled");

        (uint256 longId, uint256 orderId, uint40 expiry) = roller.position(alice, address(nvda));
        assertEq(longId, r.longId, "series kept");
        assertEq(orderId, 0, "no ask tracked");
        assertEq(expiry, FRI_2026_09_11, "expiry kept");

        _noCancel("idempotent");
        _noRoll(alice, "no re-roll inside the period");
        _setStrategy(alice, _weekly(1000, 300));
        _noRoll(alice, "a new strategy does not re-roll either");

        // stop returns early: there is no tracked ask left for it to cancel.
        vm.prank(alice);
        roller.stop(address(nvda));
        assertFalse(roller.strategy(alice, address(nvda)).active, "stopped");
        assertTrue(_order(r.orderId).cancelled, "the ask was already withdrawn");

        _setStrategy(alice, _smart(50, 150, 500));
        vm.prank(pricer);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.OrderNotLive.selector, uint256(0)));
        roller.reprice(alice, address(nvda), 4_000_000);

        // The next period rolls normally.
        _finalizeAt(FRI_2026_09_11, 262_00000000);
        (bool advanced, uint256 count,) = _roll(keeper, alice);
        assertTrue(advanced && count == 0, "closed out");
        _spotAt(_ny(MON_0914, 10, 0, 0), 262_00000000);
        assertEq(_mustRoll(alice).expiry, FRI_2026_09_18, "next period");
    }

    /// A partial fill keeps its shorts; the remainder is withdrawn and the close-out still settles and redeems. Exactly
    /// one Rolled and one ROLL bounty for the period.
    function test_partialFill_remainderWithdrawn_closeOutStillRedeems() public {
        Rolled memory r = _rolled();
        vm.warp(_ny(THU_0910, 10, 30, 0));
        assertEq(_buy(bob, r.longId, r.orderId, 400), 400, "bob buys 4 shares");

        _printAt(_ny(THU_0910, 11, 0, 0), 260_00000000);
        assertTrue(_cancelStale(keeper), "the remaining 600 are withdrawn");
        V2Types.Order memory o = _order(r.orderId);
        assertTrue(o.cancelled, "cancelled");
        assertEq(o.filled, 400, "the 400 that filled stay filled");
        assertEq(ch.balanceOf(alice, r.longId | 1), 400, "alice is short 400");
        assertEq(_free(alice), 600e16, "600 units never written");

        _finalizeAt(FRI_2026_09_11, 260_00000000);
        (bool advanced,,) = _roll(keeper, alice);
        assertTrue(advanced, "closed out");
        assertTrue(ch.series(r.longId).settled, "settled");
        assertEq(ch.balanceOf(alice, r.longId | 1), 0, "shorts redeemed");
        (uint256 longId,, uint40 expiry) = roller.position(alice, address(nvda));
        assertEq(longId + expiry, 0, "position cleared");
    }

    /*//////////////////////////////////////////////////////////////
                                BOUNTY
    //////////////////////////////////////////////////////////////*/

    function test_bounty_oncePerPosition_toTheCaller() public {
        _rolled();
        _printAt(_ny(THU_0910, 11, 0, 0), 260_00000000);
        uint256 before = usdg.balanceOf(carol);
        assertTrue(_cancelStale(carol), "cancelled");
        assertEq(usdg.balanceOf(carol) - before, CANCEL_STALE_BOUNTY, "to whoever called");
        _noCancel("a second call pays nothing");
    }

    function test_bounty_belowMinRollUnits_withdrawsWithoutBounty() public {
        V2Types.Strategy memory s = _weekly(500, 150);
        s.maxUnits = 99;
        _setStrategy(alice, s);
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        Rolled memory r = _mustRoll(alice);
        assertEq(r.units, 99, "below minRollUnits");
        uint256 before = usdg.balanceOf(keeper);

        _printAt(_ny(THU_0910, 11, 0, 0), 260_00000000);
        assertTrue(_cancelStale(keeper), "still withdrawn");
        assertEq(usdg.balanceOf(keeper), before, "no bounty for dust");
    }

    /// The remainder, not the original size, is what the gate looks at.
    function test_bounty_remainderBelowMinRollUnits_withdrawsWithoutBounty() public {
        Rolled memory r = _rolled();
        vm.warp(_ny(THU_0910, 10, 30, 0));
        _buy(bob, r.longId, r.orderId, 950);
        uint256 before = usdg.balanceOf(keeper);

        _printAt(_ny(THU_0910, 11, 0, 0), 260_00000000);
        assertTrue(_cancelStale(keeper), "50 units withdrawn");
        assertEq(usdg.balanceOf(keeper), before, "50 < minRollUnits: no bounty");
    }

    function test_bounty_payerFailures_neverBlockACancel() public {
        Rolled memory r = _rolled();
        uint256 before = usdg.balanceOf(keeper);
        vm.prank(admin);
        rewards.setCaller(address(roller), false);
        _printAt(_ny(THU_0910, 11, 0, 0), 260_00000000);
        assertTrue(_cancelStale(keeper), "unregistered caller: the reward reverts, the cancel does not");
        assertTrue(_order(r.orderId).cancelled, "withdrawn");
        assertEq(usdg.balanceOf(keeper), before, "nothing paid");

        _setStrategy(bob, _weekly(500, 150));
        _onboardWriter(bob, WRITER_SHARES);
        vm.prank(admin);
        roller.setKeeperRewards(address(0));
        _spotAt(_ny(THU_0910, 11, 30, 0), 220_00000000);
        (bool advanced,, Rolled memory rb) = _roll(keeper, bob);
        assertTrue(advanced, "bob rolled");
        _printAt(_ny(THU_0910, 12, 0, 0), 260_00000000);
        vm.prank(keeper);
        assertTrue(roller.cancelStale(bob, address(nvda)), "no payer set");
        assertTrue(_order(rb.orderId).cancelled, "withdrawn");
    }

    /*//////////////////////////////////////////////////////////////
                                REPRICE
    //////////////////////////////////////////////////////////////*/

    /// InTheMoney is checked after the spot read and before the band, so a price the band would accept is still
    /// refused; one base unit below the strike the pricer still works.
    function test_reprice_inTheMoney_beforeTheBand() public {
        _setStrategy(alice, _smart(50, 150, 1000));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        _mustRoll(alice);

        _printAt(_ny(THU_0910, 11, 0, 0), 230_99999900); // one base unit below 231
        vm.prank(pricer);
        roller.reprice(alice, address(nvda), 3_400_000);
        (, uint256 orderId,) = roller.position(alice, address(nvda));
        assertEq(_order(orderId).price, 3_400_000, "just below the strike still reprices");

        _printAt(_ny(THU_0910, 12, 0, 0), 231_00000000);
        vm.startPrank(pricer);
        vm.expectRevert(V2Errors.InTheMoney.selector);
        roller.reprice(alice, address(nvda), 3_500_000); // well inside [0.5 %, 10 %] of 231
        vm.expectRevert(V2Errors.InTheMoney.selector);
        roller.reprice(alice, address(nvda), 1); // off the tick AND outside the band: InTheMoney comes first
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           RESIDUAL AND HARNESS
    //////////////////////////////////////////////////////////////*/

    /// Residual (v7 design §10.5): the cancel is a transaction after the fact. A taker who gets there first — backrunning
    /// the crossing print, or trading on an off-chain price before the feed prints — still fills below intrinsic.
    /// Nothing cancels unless somebody calls, so keeper liveness is what bounds this.
    function test_ask_rallyBeforeTheCancel_stillFills() public {
        Rolled memory r = _rolled();
        _printAt(_ny(THU_0910, 11, 0, 0), 260_00000000);
        assertEq(_buy(bob, r.longId, r.orderId, 1000), 1000, "the taker was first");
        _noCancel("nothing left to withdraw");
        assertEq(ch.balanceOf(bob, r.longId), 1000, "bob holds the longs");
    }

    /// The put branch of the trigger, which v2.0 has no series to reach: puts are overtaken from above.
    function test_overtaken_putBranch() public {
        // C8-05: AutoRoller is Managed, so the second argument is the AccessManager. `admin` is an EOA and
        // Managed's constructor reverts NoSource on a code-less authority (src/v2/access/Managed.sol:48).
        AutoRollerHarness h = new AutoRollerHarness(IOrderBook(address(book)), address(manager));
        assertTrue(h.overtaken(true, 231_000_000, 231_000_000), "put: spot == strike");
        assertTrue(h.overtaken(true, 231_000_000, 230_999_999), "put: spot below strike");
        assertFalse(h.overtaken(true, 231_000_000, 231_000_001), "put: spot above strike");
        assertTrue(h.overtaken(false, 231_000_000, 231_000_000), "call: spot == strike");
        assertTrue(h.overtaken(false, 231_000_000, 231_000_001), "call: spot above strike");
        assertFalse(h.overtaken(false, 231_000_000, 230_999_999), "call: spot below strike");
    }

    function test_gas_cancelStale() public {
        Rolled memory r = _rolled();
        _printAt(_ny(THU_0910, 11, 0, 0), 260_00000000);

        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        uint256 g = gasleft();
        roller.cancelStale(alice, address(nvda));
        uint256 withBounty = g - gasleft();
        vm.revertToState(snap);

        vm.prank(admin);
        roller.setKeeperRewards(address(0));
        snap = vm.snapshotState();
        vm.prank(keeper);
        g = gasleft();
        roller.cancelStale(alice, address(nvda));
        uint256 withoutBounty = g - gasleft();
        vm.revertToState(snap);

        vm.prank(keeper);
        g = gasleft();
        roller.cancelStale(bob, address(nvda)); // no position: the early false
        uint256 earlyFalse = g - gasleft();

        console2.log("cancelStale, cancel + bounty:", withBounty);
        console2.log("cancelStale, cancel without bounty:", withoutBounty);
        console2.log("cancelStale, no position (early false):", earlyFalse);
        assertLt(withBounty, 350_000, "inside the keeper's gas limit");
        assertLt(earlyFalse, 45_000, "a keeper loop over writers is cheap");
        assertEq(_order(r.orderId).cancelled, false, "the measurements were reverted");
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// Permissionless: whoever calls gets the bounty, and the result never depends on who called.
    function testFuzz_cancelStale_anyCaller(address caller) public {
        vm.assume(
            caller != address(0) && caller != address(roller) && caller != address(rewards) && caller != address(book)
                && caller != address(ch)
        );
        Rolled memory r = _rolled();
        _printAt(_ny(THU_0910, 11, 0, 0), 260_00000000);
        uint256 before = usdg.balanceOf(caller);

        assertTrue(_cancelStale(caller), "anyone withdraws it");
        assertTrue(_order(r.orderId).cancelled, "withdrawn");
        assertEq(usdg.balanceOf(caller) - before, CANCEL_STALE_BOUNTY, "bounty to the caller");
    }

    /// The trigger is exactly "a fresh spot has reached the strike", for any spot around it.
    function testFuzz_cancelStale_iffSpotReachedStrike(uint256 answer) public {
        // 8-dp answers from 200.00 to 280.00, so both sides of the 231.00 strike are reachable.
        answer = bound(answer, 200_00000000, 280_00000000);
        Rolled memory r = _rolled();
        _printAt(_ny(THU_0910, 11, 0, 0), int256(answer));

        bool reached = answer / 100 >= K_231;
        assertEq(_cancelStale(keeper), reached, "cancels exactly when the spot reached the strike");
        assertEq(_order(r.orderId).cancelled, reached, "and only then is the ask withdrawn");
    }

    /// NO GRIEFING. Whatever the spot, the strategy and the moment inside a session, a roll never places an ask that
    /// {cancelStale} could withdraw at that same reading: `strike >= ceil(spot x (1 + otmBps))` with otmBps at least
    /// MIN_OTM_BPS, so a fresh ask is always strictly out of the money.
    function testFuzz_roll_neverPlacesWhatCancelStaleCancels(uint256 answer, uint256 otm, uint256 ask, uint256 offset)
        public
    {
        answer = bound(answer, 10_00000000, 5000_00000000);
        uint16 otmBps = uint16(bound(otm, 100, 2500));
        // T-OP-063 / SEC-13: the compiled ask floor is MIN_ASK_BPS = 50; a fuzzed ask in [5, 49] would revert
        // CeilingExceeded in setStrategy and this property would never reach its roll. The bound mirrors the constant.
        uint16 askBps = uint16(bound(ask, 50, 1000));
        _setStrategy(alice, _weekly(otmBps, askBps));
        _printAt(_ny(TUE_0915, 9, 30, 0) + bound(offset, 0, SESSION - 1), int256(answer));

        Rolled memory r = _mustRoll(alice);
        _noCancel("a roll never places an ask its own reading could withdraw");
        assertFalse(_order(r.orderId).cancelled, "ask live");
        assertGt(uint256(r.strike), answer / 100, "strictly out of the money");
    }
}

/// @notice T-OP-070. The roller's freshness paths driven by MockSettlementOracle's staleness model instead of the real
///         oracle's feed clock. Before this row the mock's spot was fresh for ever, so every roller test that needed a
///         stale reading had to build one on the real SettlementOracle; the mock now mirrors that oracle's three-step
///         rule (T-OP-061) and offers a blunt switch, and these tests hold the roller to the same answers against it.
///         The market is migrated to the mock BEFORE the roll, so the series is pinned to it and both `_plan`
///         (market oracle) and `cancelStale` / `reprice` (pinned oracle) read the mock.
contract AutoRollerMockStaleTest is AutoRollerTestBase {
    MockSettlementOracle internal mock;

    function _migrateToMock() internal {
        mock = new MockSettlementOracle();
        vm.label(address(mock), "mock oracle");
        vm.prank(admin);
        ch.setMarketOracle(address(nvda), address(mock));
        assertEq(ch.market(address(nvda)).oracle, address(mock), "the market reads the mock");
    }

    /// @dev The Thursday 10:00 roll on the mock: strike 231.00, ask 3.30, series pinned to the mock.
    function _rolledOnMock(V2Types.Strategy memory strategy) internal returns (Rolled memory r) {
        _setStrategy(alice, strategy);
        uint256 t0 = _ny(THU_0910, 10, 0, 0);
        vm.warp(t0);
        mock.setSpot(address(nvda), true, 220_000_000, t0);
        r = _mustRoll(alice);
        assertEq(r.strike, K_231, "strike 231");
        assertEq(ch.series(r.longId).oracle, address(mock), "the series is pinned to the mock");
    }

    function _cancelStale(address caller) internal returns (bool) {
        vm.prank(caller);
        return roller.cancelStale(alice, address(nvda));
    }

    /// THE SWITCH. A crossing print the mock reports STALE is not actionable: cancelStale does nothing (trySpot is
    /// not ok) and reprice reverts StaleSpot with the print's timestamp, exactly the real oracle's answers. Flip
    /// the switch back and the same print withdraws the ask. PROVE-BY-BREAKING: with the pre-T-OP-070 mock (spot
    /// fresh for ever) the first cancelStale here returns TRUE and this test is red at "stale: cancelStale acted".
    function test_mockStale_switch_freezesCancelStaleAndReprice() public {
        _migrateToMock();
        Rolled memory r = _rolledOnMock(_smart(50, 150, 1000));
        uint256 t = _ny(THU_0910, 11, 0, 0);
        vm.warp(t);
        mock.setSpot(address(nvda), true, 240_000_000, t); // past the 231 strike
        mock.setSpotStale(address(nvda), true);

        (bool ok, uint256 p, uint256 at) = mock.trySpot(address(nvda));
        assertFalse(ok, "premise: the mock does not report the spot stale");
        assertEq(p + at, 0, "a stale trySpot answers all zero, as the real oracle does");

        assertFalse(_cancelStale(keeper), "stale: cancelStale acted on a reading the oracle refuses");
        assertFalse(_order(r.orderId).cancelled, "ask still live");
        vm.prank(pricer);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.StaleSpot.selector, t));
        roller.reprice(alice, address(nvda), 3_400_000);

        mock.setSpotStale(address(nvda), false);
        assertTrue(_cancelStale(keeper), "fresh again: the crossing print withdraws the ask");
        assertTrue(_order(r.orderId).cancelled, "withdrawn");
    }

    /// THE THREE-STEP RULE (SettlementOracle._spot after T-OP-061, mirrored by the mock). A print older than 30
    /// minutes needs the modelled witness to agree within the market's band: agreeing, the print is fresh and the
    /// ask is withdrawn; disagreeing, it is stale (trySpot not ok, spot reverts StaleSpot) and nothing happens. Under
    /// 30 minutes no witness is asked, and past spotMaxAge the witness cannot help. Each branch runs from the same
    /// snapshot so only the clock and the witness differ.
    function test_mockStale_threeStepRule_anOldPrintNeedsAnAgreeingWitness() public {
        _migrateToMock();
        Rolled memory r = _rolledOnMock(_weekly(500, 150));
        mock.setSpotRule(address(nvda), 25 hours, 100); // the launch rows: 25 h outer bound, 1 % band
        uint256 t = _ny(THU_0910, 11, 0, 0);
        vm.warp(t);
        mock.setSpot(address(nvda), true, 240_000_000, t);
        uint256 snap = vm.snapshotState();

        // 1. Under SPOT_CORROBORATION_AGE: fresh, whatever the witness says.
        mock.setSpotWitness(address(nvda), true, 260_000_000);
        vm.warp(t + 29 minutes);
        assertTrue(_cancelStale(keeper), "a 29-minute-old print needs no witness");
        vm.revertToState(snap);

        // 2a. Over it, witness agrees (240.50 within 1 % of 240.00): corroborated, fresh.
        mock.setSpotWitness(address(nvda), true, 240_500_000);
        vm.warp(t + 31 minutes);
        (bool ok, uint256 p, uint256 at) = mock.trySpot(address(nvda));
        assertTrue(ok && p == 240_000_000 && at == t, "corroborated: the print, not the witness, is the answer");
        assertTrue(_cancelStale(keeper), "an old print the pool agrees with withdraws the ask");
        assertTrue(_order(r.orderId).cancelled, "withdrawn");
        vm.revertToState(snap);

        // 2b. Over it, witness disagrees (260.00 is 8.3 % away): the market has moved, the print is stale.
        mock.setSpotWitness(address(nvda), true, 260_000_000);
        vm.warp(t + 31 minutes);
        (ok, p, at) = mock.trySpot(address(nvda));
        assertFalse(ok, "premise: the disagreeing witness did not make the print stale");
        vm.expectRevert(abi.encodeWithSelector(V2Errors.StaleSpot.selector, t));
        mock.spot(address(nvda));
        assertFalse(_cancelStale(keeper), "stale: the roller must not act on a print the market left behind");
        assertFalse(_order(r.orderId).cancelled, "ask still live");
        vm.revertToState(snap);

        // 3. Over it, no witness (single-source market): the outer bound alone decides, as before T-OP-061.
        mock.setSpotWitness(address(nvda), false, 0);
        vm.warp(t + 25 hours);
        assertTrue(_cancelStale(keeper), "exactly spotMaxAge old is fresh");
        vm.revertToState(snap);
        vm.warp(t + 25 hours + 1);
        assertFalse(_cancelStale(keeper), "past spotMaxAge: stale");

        // Past spotMaxAge an agreeing witness cannot rescue the print: the outer bound holds in every step.
        mock.setSpotWitness(address(nvda), true, 240_000_000);
        assertFalse(_cancelStale(keeper), "spotMaxAge is the outer bound whatever the witness says");
    }

    /// THE ROLL WAITS ON A STALE SPOT. `_plan` reads trySpot from the market oracle and returns "not due" when it is
    /// not ok; with the mock reporting stale nothing is written, and the same call rolls once the spot is fresh.
    function test_mockStale_rollWaitsForAFreshSpot() public {
        _migrateToMock();
        _setStrategy(alice, _weekly(500, 150));
        uint256 t0 = _ny(THU_0910, 10, 0, 0);
        vm.warp(t0);
        mock.setSpot(address(nvda), true, 220_000_000, t0);
        mock.setSpotStale(address(nvda), true);
        _noRoll(alice, "stale spot: the roll waits");
        mock.setSpotStale(address(nvda), false);
        Rolled memory r = _mustRoll(alice);
        assertEq(r.strike, K_231, "rolled on the fresh reading");
    }
}
