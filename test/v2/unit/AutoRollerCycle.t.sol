// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {AutoRollerTestBase} from "./AutoRollerBase.t.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MockSettlementOracle} from "../../../src/v2/mocks/MockSettlementOracle.sol";

/// @notice AutoRoller over whole periods: roll, fill, expiry, settlement, close-out and the next roll, for weekly and
///         daily strategies, with the real Clearinghouse, OrderBook, ExpiryCalendar, KeeperRewards and SettlementOracle.
contract AutoRollerCycleTest is AutoRollerTestBase {
    /// @dev Short payout of `units` of an ITM call at strike `k`, price `p` (both USDG 6 dp): collateral less the floored
    ///      gross, computed independently of OptionMath.
    function _shortPayout(uint256 units, uint256 k, uint256 p) internal pure returns (uint256) {
        uint256 gross = p > k ? 1e16 * (p - k) / p : 0;
        return units * (1e16 - gross);
    }

    /// Three consecutive weekly periods: an OTM week with a partial fill, an ITM week filled in full (the short's
    /// collateral comes back smaller), and a third week whose size is what came back. Bounties go to the keeper, the
    /// roller never holds anything.
    function test_weekly_threePeriods_itmWeekShrinksNextSize() public {
        _setStrategy(alice, _weekly(500, 150));

        // Week 1: Thursday 10:00, spot 220.00.
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        Rolled memory w1 = _mustRoll(alice);
        assertEq(w1.strike, K_231, "w1 strike: 220 x 1.05 = 231");
        assertEq(w1.price, P_3_30, "w1 price: 220 x 1.5 % = 3.30");
        assertEq(w1.units, 1000, "w1 size: all 10 shares");
        assertEq(w1.expiry, FRI_2026_09_11, "w1 expiry: this Friday");
        (uint256 longId, uint256 orderId, uint40 expiry) = roller.position(alice, address(nvda));
        assertEq(longId, w1.longId, "position long");
        assertEq(orderId, w1.orderId, "position order");
        assertEq(expiry, FRI_2026_09_11, "position expiry");
        V2Types.Order memory o = _order(w1.orderId);
        assertEq(o.maker, alice, "maker is the writer");
        assertEq(uint8(o.kind), uint8(V2Types.OrderKind.AskWrite), "write-on-fill ask");
        assertEq(o.validUntil, FRI_2026_09_11 - V2Constants.SETTLEMENT_WINDOW, "valid until the mint cutoff");
        assertEq(usdg.balanceOf(keeper), ROLL_BOUNTY, "ROLL bounty to the caller");
        _assertRollerEmpty(w1.longId);

        vm.warp(_ny(THU_0910, 11, 0, 0));
        assertEq(_buy(bob, w1.longId, w1.orderId, 400), 400, "bob buys 4 shares");
        assertEq(ch.balanceOf(alice, w1.longId | 1), 400, "alice is short 400");
        assertEq(_free(alice), 600e16, "600 units still free");

        // Expiry at 225.00: OTM. The roller settles, redeems the shorts, prunes the ask, clears the position.
        _finalizeAt(FRI_2026_09_11, 225_00000000);
        (bool advanced, uint256 count,) = _roll(keeper, alice);
        assertTrue(advanced, "close-out advanced");
        assertEq(count, 0, "Friday 16:02 is outside the session: no new roll");
        assertTrue(ch.series(w1.longId).settled, "settled through the roller");
        assertEq(ch.balanceOf(alice, w1.longId | 1), 0, "shorts redeemed");
        assertEq(_free(alice), WRITER_SHARES, "OTM: all collateral back in the ledger");
        assertTrue(_order(w1.orderId).cancelled, "stale ask pruned");
        (longId, orderId, expiry) = roller.position(alice, address(nvda));
        assertEq(longId + orderId + expiry, 0, "position cleared");
        assertEq(
            usdg.balanceOf(keeper), ROLL_BOUNTY + SETTLE_BOUNTY + REDEEM_BOUNTY, "settle + redeem bounties forwarded"
        );
        _assertRollerEmpty(w1.longId);

        // Week 2: Monday 10:00, spot 230.00.
        _spotAt(_ny(MON_0914, 10, 0, 0), 230_00000000);
        Rolled memory w2 = _mustRoll(alice);
        assertEq(w2.strike, 242_000_000, "w2 strike: 241.50 rounds up to 242");
        assertEq(w2.price, 3_450_000, "w2 price: 3.45");
        assertEq(w2.units, 1000, "w2 size");
        assertEq(w2.expiry, FRI_2026_09_18, "w2 expiry");
        vm.warp(_ny(MON_0914, 11, 0, 0));
        assertEq(_buy(bob, w2.longId, w2.orderId, 1000), 1000, "bob buys everything");
        assertEq(_free(alice), 0, "fully written");

        // Expiry at 260.00: ITM. The short gets back its collateral less (260 - 242) / 260 of a share per share.
        _finalizeAt(FRI_2026_09_18, 260_00000000);
        (advanced,,) = _roll(keeper, alice);
        assertTrue(advanced, "ITM close-out");
        uint256 back = _shortPayout(1000, w2.strike, 260_000_000);
        assertEq(_free(alice), back, "ITM: shrunken collateral back in the ledger");
        assertLt(back, WRITER_SHARES, "collateral shrank");

        // Week 3: the size is what came back.
        _spotAt(_ny(MON_0921, 10, 0, 0), 262_00000000);
        Rolled memory w3 = _mustRoll(alice);
        assertEq(w3.units, back / 1e16, "w3 size adapts to the smaller ledger");
        assertEq(w3.units, 930, "9.307... shares -> 930 units");
        assertEq(w3.strike, 276_000_000, "w3 strike: 275.10 rounds up to 276");
        assertEq(w3.price, 3_930_000, "w3 price: 3.93");
        assertEq(w3.expiry, FRI_2026_09_25, "w3 expiry");
        assertEq(
            usdg.balanceOf(keeper), 3 * ROLL_BOUNTY + 2 * SETTLE_BOUNTY + 2 * REDEEM_BOUNTY, "every bounty to keeper"
        );
        _assertRollerEmpty(w3.longId);

        // Week 3 is not filled: the close-out does not wait for its settlement.
        vm.warp(uint256(FRI_2026_09_25) + 1);
        (advanced,,) = _roll(keeper, alice);
        assertTrue(advanced, "unfilled week closes at expiry");
        assertFalse(ch.series(w3.longId).settled, "without waiting for the price");
        assertTrue(_order(w3.orderId).cancelled, "ask pruned");
        (longId,,) = roller.position(alice, address(nvda));
        assertEq(longId, 0, "cleared");
        assertEq(_free(alice), back, "ledger untouched");
    }

    /// A daily strategy writes the same day's 16:00 expiry in the morning and the next session's after close-out.
    function test_daily_rollsEverySession() public {
        _setStrategy(alice, _daily(200, 50));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        Rolled memory d1 = _mustRoll(alice);
        assertEq(d1.expiry, THU_2026_09_10, "today's close");
        assertEq(d1.strike, 225_000_000, "224.40 rounds up to 225");
        assertEq(d1.price, 1_100_000, "0.5 % of 220 = 1.10");
        vm.warp(_ny(THU_0910, 11, 0, 0));
        _buy(bob, d1.longId, d1.orderId, 100);

        _finalizeAt(THU_2026_09_10, 226_00000000);
        (bool advanced,,) = _roll(keeper, alice);
        assertTrue(advanced, "Thursday close-out");
        uint256 back = _shortPayout(100, d1.strike, 226_000_000);
        assertEq(_free(alice), 900e16 + back, "900 untouched + the ITM short's remainder");

        _spotAt(_ny(FRI_0911, 9, 30, 0), 226_00000000);
        Rolled memory d2 = _mustRoll(alice);
        assertEq(d2.expiry, FRI_2026_09_11, "Friday's close");
        assertEq(d2.strike, 231_000_000, "230.52 rounds up to 231");
        assertEq(d2.units, (900e16 + back) / 1e16, "sized from the ledger");
    }

    /// The previous series has shorts outstanding and is not settled: roll returns false and changes nothing, through
    /// finalize's TooEarly, an uncorroborated candidate inside its delay, and a guardian veto; it closes out once final.
    function test_unsettled_returnsFalseUntilFinal() public {
        _setStrategy(alice, _weekly(500, 150));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        Rolled memory r = _mustRoll(alice);
        vm.warp(_ny(THU_0910, 11, 0, 0));
        _buy(bob, r.longId, r.orderId, 100);

        // A settlement print, but the second source never answers: Chainlink alone is a 30 min candidate.
        uint256 t = uint256(FRI_2026_09_11) - 1 hours;
        vm.warp(t);
        feed.push(224_00000000, t);

        vm.warp(FRI_2026_09_11);
        _noRoll(alice, "at expiry: finalize is TooEarly");
        vm.warp(uint256(FRI_2026_09_11) + V2Constants.FINALIZE_DELAY);
        _noRoll(alice, "candidate inside its delay");
        assertEq(ch.balanceOf(alice, r.longId | 1), 100, "shorts untouched");

        // THE REAL ORACLE HOLDS THIS ROLL (T-OP-070 re-derived it): `oracle` here is the fixture's SettlementOracle,
        // whose `_advance` returns false for a Held, uncorroborated expiry (SettlementOracle.sol:751), so
        // Clearinghouse.settle sees (false, 0) and the roller has nothing to close out. The mock is not on this path;
        // its Held gap (fixed in T-OP-070) is pinned by {test_unsettled_heldOnTheMockOracle_blocksUntilUnveto}.
        vm.prank(guardian);
        oracle.veto(address(nvda), FRI_2026_09_11);
        vm.warp(uint256(FRI_2026_09_11) + 3 hours);
        _noRoll(alice, "held");

        vm.prank(guardian);
        oracle.unveto(address(nvda), FRI_2026_09_11);
        vm.warp(uint256(FRI_2026_09_11) + 3 hours + UNCORROBORATED_DELAY);
        (bool advanced,,) = _roll(keeper, alice);
        assertTrue(advanced, "final: closes out");
        assertTrue(ch.series(r.longId).settled, "settled");
        assertEq(ch.balanceOf(alice, r.longId | 1), 0, "shorts redeemed");
        assertEq(_free(alice), WRITER_SHARES, "OTM at 224");
    }

    /// T-OP-070. The same veto block, THROUGH THE MOCK. The market is migrated to a MockSettlementOracle before the
    /// roll, so the series is pinned to it and Clearinghouse.settle calls ITS finalize. In FinalizeOnCall mode the
    /// pre-T-OP-070 mock finalized a Held expiry anyway (T-OP-049's "the veto does not block"), so the "held"
    /// assertion below would FAIL against it -- the roll would close out through a finalized settlement. The mock
    /// now mirrors SettlementOracle._advance: a Held, uncorroborated expiry reports (false, 0), and the roller has
    /// nothing to close out; `finalizeCalls` proves the roller did ask. Unveto, and the same call finalizes.
    function test_unsettled_heldOnTheMockOracle_blocksUntilUnveto() public {
        MockSettlementOracle mock = new MockSettlementOracle();
        vm.prank(admin);
        ch.setMarketOracle(address(nvda), address(mock));
        assertEq(ch.market(address(nvda)).oracle, address(mock), "the market reads the mock");

        _setStrategy(alice, _weekly(500, 150));
        uint256 t0 = _ny(THU_0910, 10, 0, 0);
        vm.warp(t0);
        mock.setSpot(address(nvda), true, 220_000_000, t0);
        Rolled memory r = _mustRoll(alice);
        assertEq(ch.series(r.longId).oracle, address(mock), "the series is pinned to the mock");
        vm.warp(_ny(THU_0910, 11, 0, 0));
        _buy(bob, r.longId, r.orderId, 100);

        // The mock will finalize at 224.00 on call -- but only once it is not Held.
        mock.setFinalizeMode(
            address(nvda), FRI_2026_09_11, MockSettlementOracle.FinalizeMode.FinalizeOnCall, 224_000_000
        );
        vm.prank(guardian);
        mock.veto(address(nvda), FRI_2026_09_11);
        (V2Types.SettlementStatus st,) = mock.settlementPrice(address(nvda), FRI_2026_09_11);
        assertEq(uint8(st), uint8(V2Types.SettlementStatus.Held), "premise: vetoed");

        // The same clock as the real-oracle test above: a 224.00 print an hour before expiry, the held check three
        // hours after it (past FINALIZE_DELAY, so the mock's own TooEarly is out of the way).
        uint256 t = uint256(FRI_2026_09_11) - 1 hours;
        vm.warp(t);
        mock.setSpot(address(nvda), true, 224_000_000, t);
        vm.warp(uint256(FRI_2026_09_11) + 3 hours);
        uint256 asked = mock.finalizeCalls();
        _noRoll(alice, "held on the mock");
        assertGt(mock.finalizeCalls(), asked, "the roller did call finalize: the block is Held, not TooEarly");
        (st,) = mock.settlementPrice(address(nvda), FRI_2026_09_11);
        assertEq(uint8(st), uint8(V2Types.SettlementStatus.Held), "FinalizeOnCall finalized a Held expiry");
        assertFalse(ch.series(r.longId).settled, "not settled while Held");
        assertEq(ch.balanceOf(alice, r.longId | 1), 100, "shorts untouched");

        vm.prank(guardian);
        mock.unveto(address(nvda), FRI_2026_09_11);
        vm.warp(uint256(FRI_2026_09_11) + 3 hours + UNCORROBORATED_DELAY);
        (bool advanced,,) = _roll(keeper, alice);
        assertTrue(advanced, "unvetoed: the same call finalizes and closes out");
        assertTrue(ch.series(r.longId).settled, "settled");
        assertEq(ch.balanceOf(alice, r.longId | 1), 0, "shorts redeemed");
        assertEq(_free(alice), WRITER_SHARES, "OTM at 224");
    }

    /// The cranker settled and redeemed the writer first: the roller only prunes and clears.
    function test_closeOut_afterCrankerRedeemed() public {
        _setStrategy(alice, _weekly(500, 150));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        Rolled memory r = _mustRoll(alice);
        vm.warp(_ny(THU_0910, 11, 0, 0));
        _buy(bob, r.longId, r.orderId, 300);

        _finalizeAt(FRI_2026_09_11, 240_00000000);
        vm.startPrank(carol);
        assertTrue(ch.settle(r.longId), "cranker settles");
        ch.redeem(r.longId | 1, alice);
        vm.stopPrank();
        uint256 keeperBefore = usdg.balanceOf(keeper);

        (bool advanced,,) = _roll(keeper, alice);
        assertTrue(advanced, "cleared");
        assertEq(usdg.balanceOf(keeper), keeperBefore, "nothing to forward: the cranker earned those bounties");
        assertTrue(_order(r.orderId).cancelled, "pruned");
        assertEq(_free(alice), 700e16 + _shortPayout(300, K_231, 240_000_000), "ledger as the cranker left it");
    }

    /// A writer that opted out of third-party redemption is still redeemed by the roller, its operator.
    function test_closeOut_optedOutWriter_redeemedAsOperator() public {
        vm.prank(alice);
        ch.setThirdPartyRedeem(false);
        _setStrategy(alice, _weekly(500, 150));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        Rolled memory r = _mustRoll(alice);
        vm.warp(_ny(THU_0910, 11, 0, 0));
        _buy(bob, r.longId, r.orderId, 500);

        _finalizeAt(FRI_2026_09_11, 221_00000000);
        vm.prank(carol);
        vm.expectRevert(V2Errors.ThirdPartyRedeemDisabled.selector);
        ch.redeem(r.longId | 1, alice);

        (bool advanced,,) = _roll(keeper, alice);
        assertTrue(advanced, "closed out");
        assertEq(ch.balanceOf(alice, r.longId | 1), 0, "redeemed by the roller");
        assertEq(_free(alice), WRITER_SHARES, "OTM");
    }

    /// Opted out AND the roller revoked: the close-out cannot redeem, so roll reverts cleanly; re-approving resumes.
    function test_closeOut_optedOutAndRevoked_revertsThenResumes() public {
        vm.prank(alice);
        ch.setThirdPartyRedeem(false);
        _setStrategy(alice, _weekly(500, 150));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        Rolled memory r = _mustRoll(alice);
        vm.warp(_ny(THU_0910, 11, 0, 0));
        _buy(bob, r.longId, r.orderId, 500);
        vm.prank(alice);
        ch.setOperator(address(roller), false);

        _finalizeAt(FRI_2026_09_11, 221_00000000);
        vm.prank(keeper);
        vm.expectRevert(V2Errors.ThirdPartyRedeemDisabled.selector);
        roller.roll(alice, address(nvda));
        (uint256 longId,,) = roller.position(alice, address(nvda));
        assertEq(longId, r.longId, "position kept");
        assertFalse(ch.series(r.longId).settled, "the settle inside the reverted call is undone too");

        vm.prank(alice);
        ch.setOperator(address(roller), true);
        (bool advanced,,) = _roll(keeper, alice);
        assertTrue(advanced, "resumes");
        assertEq(ch.balanceOf(alice, r.longId | 1), 0, "redeemed");
    }

    /// A close-out is a call of its own, also inside the session: it never goes on to place, so nothing that would make
    /// a placement revert (here the guardian's mint pause) can undo the settle and the redeem with it. The writer opted
    /// out of third-party redemption, so the roller is the only keeper path that frees its collateral. The next call
    /// rolls (sweep contracts-c18).
    function test_closeOut_inSession_isItsOwnCall_soAPauseCannotUndoIt() public {
        vm.prank(alice);
        ch.setThirdPartyRedeem(false);
        _setStrategy(alice, _weekly(500, 150));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        Rolled memory r = _mustRoll(alice);
        vm.warp(_ny(THU_0910, 11, 0, 0));
        _buy(bob, r.longId, r.orderId, 500);
        _finalizeAt(FRI_2026_09_11, 225_00000000);

        // Nobody called until Monday 10:00, inside the session. Nothing blocks: the close-out still does not place.
        _spotAt(_ny(MON_0914, 10, 0, 0), 220_00000000);
        uint256 snap = vm.snapshotState();
        (bool advanced, uint256 count,) = _roll(keeper, alice);
        assertTrue(advanced && count == 0, "closed out, not rolled");
        assertEq(_mustRoll(alice).expiry, FRI_2026_09_18, "the next call rolls");
        vm.revertToState(snap);

        // The guardian paused mints: the close-out is kept instead of reverting MintPaused.
        vm.prank(guardian);
        ch.setMintPaused(address(nvda), true);
        (advanced, count,) = _roll(keeper, alice);
        assertTrue(advanced, "closed out under the pause");
        assertEq(count, 0, "nothing placed");
        assertTrue(ch.series(r.longId).settled, "settled");
        assertEq(ch.balanceOf(alice, r.longId | 1), 0, "shorts redeemed by the roller");
        assertEq(_free(alice), WRITER_SHARES, "OTM: all collateral back in the ledger");
        (uint256 longId, uint256 orderId, uint40 expiry) = roller.position(alice, address(nvda));
        assertEq(longId + orderId + expiry, 0, "position cleared");
        assertEq(usdg.balanceOf(keeper), ROLL_BOUNTY + SETTLE_BOUNTY + REDEEM_BOUNTY, "close-out bounties forwarded");

        vm.prank(keeper);
        vm.expectRevert(V2Errors.MintPaused.selector);
        roller.roll(alice, address(nvda));
        vm.prank(guardian);
        ch.setMintPaused(address(nvda), false);
        assertEq(_mustRoll(alice).expiry, FRI_2026_09_18, "rolls once the pause is lifted");
    }

    /// A keeper whose USDG is frozen cannot take the forwarded bounties; the next close-out's caller gets them.
    function test_forward_frozenKeeper_nextCallerCollects() public {
        _setStrategy(alice, _weekly(500, 150));
        _setStrategy(bob, _weekly(500, 150));
        _onboardWriter(bob, WRITER_SHARES);
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        Rolled memory ra = _mustRoll(alice);
        Rolled memory rb = _mustRoll(bob);
        vm.warp(_ny(THU_0910, 11, 0, 0));
        _buy(carol, ra.longId, ra.orderId, 100);
        _buy(carol, rb.longId, rb.orderId, 100);

        _finalizeAt(FRI_2026_09_11, 222_00000000);
        usdg.freeze(keeper);
        (bool advanced,,) = _roll(keeper, alice);
        assertTrue(advanced, "close-out still works");
        assertEq(usdg.balanceOf(address(roller)), SETTLE_BOUNTY + REDEEM_BOUNTY, "stuck while the keeper is frozen");

        // Bob's series is the same (strike, expiry): already settled, so only his REDEEM bounty is new.
        uint256 carolBefore = usdg.balanceOf(carol);
        vm.prank(carol);
        assertTrue(roller.roll(bob, address(nvda)), "bob closes out");
        assertEq(usdg.balanceOf(carol) - carolBefore, SETTLE_BOUNTY + 2 * REDEEM_BOUNTY, "carol collects everything");
        _assertRollerEmpty(ra.longId);
    }

    /// Gas of a first roll and of a close-out plus the next roll, printed for the task report (forge test -vv).
    function test_gas_rollAndCloseOut() public {
        _setStrategy(alice, _weekly(500, 150));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        vm.prank(keeper);
        uint256 g = gasleft();
        roller.roll(alice, address(nvda));
        uint256 firstRoll = g - gasleft();
        (uint256 longId, uint256 orderId,) = roller.position(alice, address(nvda));
        vm.warp(_ny(THU_0910, 11, 0, 0));
        _buy(bob, longId, orderId, 400);

        _finalizeAt(FRI_2026_09_11, 225_00000000);
        vm.prank(keeper);
        g = gasleft();
        roller.roll(alice, address(nvda));
        uint256 closeOut = g - gasleft();

        _spotAt(_ny(MON_0914, 10, 0, 0), 230_00000000);
        vm.prank(keeper);
        g = gasleft();
        roller.roll(alice, address(nvda));
        uint256 secondRoll = g - gasleft();

        vm.prank(keeper);
        g = gasleft();
        roller.roll(alice, address(nvda));
        uint256 noop = g - gasleft();

        console2.log("roll, first (new series + ask + bounty):", firstRoll);
        console2.log("close-out (settle + redeem + prune + forward):", closeOut);
        console2.log("roll, next period:", secondRoll);
        console2.log("roll, no-op in period:", noop);
        // the first roll creates the first series of its expiry, which pins the settlement configuration on the oracle
        // and both sources (INTERFACE_VERSION 6)
        assertLt(firstRoll, 800_000, "first roll");
        assertLt(closeOut, 600_000, "close-out");
        assertLt(noop, 30_000, "no-op");
    }
}
