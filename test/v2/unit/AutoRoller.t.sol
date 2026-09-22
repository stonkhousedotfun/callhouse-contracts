// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AutoRollerTestBase} from "./AutoRollerBase.t.sol";
import {AutoRoller} from "../../../src/v2/AutoRoller.sol";
import {IAutoRoller} from "../../../src/v2/interfaces/IAutoRoller.sol";
import {ISettlementOracle} from "../../../src/v2/interfaces/ISettlementOracle.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MockSettlementOracle} from "../../../src/v2/mocks/MockSettlementOracle.sol";

/// @notice The ROLL bounty's eligibility floor (T-313). {AutoRoller.setMinRollUnits} must refuse any threshold below
///         DEFAULT_MIN_ROLL_UNITS: every successful roll places at least one unit, so 0 or 1 would pay every roll and
///         erase the anti-dust guard the threshold exists for. Stopping payments is the payer's job, not the floor's.
contract AutoRollerMinRollUnitsTest is AutoRollerTestBase {
    uint64 internal constant FLOOR = 100;

    function test_minRollUnits_floorIsOneShare() public view {
        assertEq(roller.DEFAULT_MIN_ROLL_UNITS(), FLOOR, "floor is one whole share");
        assertEq(roller.minRollUnits(), FLOOR, "deployed at the floor");
    }

    function test_setMinRollUnits_belowFloor_reverts() public {
        vm.startPrank(admin);
        vm.expectRevert(V2Errors.BadUnits.selector);
        roller.setMinRollUnits(0);
        vm.expectRevert(V2Errors.BadUnits.selector);
        roller.setMinRollUnits(1);
        vm.expectRevert(V2Errors.BadUnits.selector);
        roller.setMinRollUnits(FLOOR - 1);
        vm.stopPrank();
        assertEq(roller.minRollUnits(), FLOOR, "a refused value is not stored");
    }

    function testFuzz_setMinRollUnits_belowFloor_reverts(uint64 units) public {
        units = uint64(bound(units, 0, FLOOR - 1));
        vm.prank(admin);
        vm.expectRevert(V2Errors.BadUnits.selector);
        roller.setMinRollUnits(units);
    }

    function test_setMinRollUnits_atAndAboveFloor_accepts() public {
        vm.startPrank(admin);
        vm.expectEmit(address(roller));
        emit AutoRoller.MinRollUnitsSet(FLOOR + 1);
        roller.setMinRollUnits(FLOOR + 1);
        assertEq(roller.minRollUnits(), FLOOR + 1, "above the floor");

        vm.expectEmit(address(roller));
        emit AutoRoller.MinRollUnitsSet(FLOOR);
        roller.setMinRollUnits(FLOOR);
        assertEq(roller.minRollUnits(), FLOOR, "exactly the floor");

        roller.setMinRollUnits(type(uint64).max);
        assertEq(roller.minRollUnits(), type(uint64).max, "no ceiling");
        vm.stopPrank();
    }

    /// @dev The floor as a roll sees it, with no setter call: 99 units pays nothing, 100 pays the bounty.
    function test_roll_belowFloorUnpaid_atFloorPaid() public {
        V2Types.Strategy memory s = _weekly(500, 150);
        s.maxUnits = FLOOR - 1;
        _setStrategy(alice, s);
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        assertEq(_mustRoll(alice).units, FLOOR - 1, "placed below the floor");
        assertEq(usdg.balanceOf(keeper), 0, "below the floor: no bounty");

        s.maxUnits = FLOOR;
        _setStrategy(bob, s);
        _onboardWriter(bob, WRITER_SHARES);
        assertEq(_mustRoll(bob).units, FLOOR, "placed at the floor");
        assertEq(usdg.balanceOf(keeper), ROLL_BOUNTY, "at the floor: bounty");
    }
}

/// @notice T-310: after a legitimate market-oracle migration, the AutoRoller judges every series that already exists by
///         the oracle that series is PINNED to, the one {Clearinghouse.settle} settles it on, and never by the market's
///         current oracle: {AutoRoller.cancelStale}'s trigger, {AutoRoller.reprice}'s InTheMoney test and band, and
///         {AutoRoller.roll}'s out-of-the-money check when it lands on a series created before the migration.
/// @dev O1 is the fixture's real SettlementOracle, pinned into every series created before the migration. O2 is a
///      MockSettlementOracle the market is then pointed at with `setMarketOracle` (CONFIG_ADMIN, the fixture's admin),
///      a valid oracle and a legitimate admin action: nothing here is misuse.
///      O1 AND O2 ALWAYS DISAGREE, and in both directions. A test in which the two return the same spot passes
///      whichever oracle the roller reads, so it would prove nothing. Each case asserts, separately, which oracle was
///      read (O2 is never asked for a spot where the series is O1's), what cancelStale / reprice / roll did, and, for
///      the cancel, what the series eventually settles on.
///      Alice is the writer, 10 NVDA in the ledger, strategy 5 % out of the money at 1.5 %, so the Thursday 10:00 roll
///      at 220.00 writes the 231.00 strike, expiry Friday 09-11, and asks 3.30.
contract AutoRollerSeriesOracleTest is AutoRollerTestBase {
    MockSettlementOracle internal o2;

    /// @dev The Thursday 10:00 roll at O1 spot 220.00: strike 231.00, ask 3.30, 1,000 units, expiry Friday 09-11.
    function _rolledOnO1(V2Types.Strategy memory s) internal returns (Rolled memory r) {
        _setStrategy(alice, s);
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        r = _mustRoll(alice);
        assertEq(r.strike, K_231, "strike 231");
        assertEq(r.price, P_3_30, "ask 3.30");
        assertEq(ch.series(r.longId).oracle, address(oracle), "the series is pinned to O1");
    }

    /// @dev The legitimate migration: CONFIG_ADMIN points NVDA at O2. Series created before it keep O1.
    function _migrateToO2() internal {
        o2 = new MockSettlementOracle();
        vm.label(address(o2), "O2");
        vm.prank(admin);
        ch.setMarketOracle(address(nvda), address(o2));
        assertEq(ch.market(address(nvda)).oracle, address(o2), "the market now reads O2");
    }

    /// @dev A feed print of `answer` (8 dp) at `t`, pushed twice so the head round and its predecessor agree and the
    ///      source's round-jump guard never fires however far the price moved (as in AutoRollerStaleTest).
    function _printAt(uint256 t, int256 answer) internal {
        vm.warp(t - 1);
        feed.push(answer, t - 1);
        _spotAt(t, answer);
    }

    /// @dev At `t`, both fresh: O1 prints `o1Answer` (8 dp) and O2 answers `o2Price` (6 dp).
    function _quotes(uint256 t, int256 o1Answer, uint256 o2Price) internal {
        _printAt(t, o1Answer);
        o2.setSpot(address(nvda), true, o2Price, t);
    }

    /// @dev From here to the end of the test, nothing asks O2 for a spot.
    function _expectO2NeverPriced() internal {
        vm.expectCall(address(o2), abi.encodeWithSelector(ISettlementOracle.trySpot.selector), 0);
        vm.expectCall(address(o2), abi.encodeWithSelector(ISettlementOracle.spot.selector), 0);
    }

    /*//////////////////////////////////////////////////////////////
                               CANCELSTALE
    //////////////////////////////////////////////////////////////*/

    /// O1 (pinned) has reached the strike and O2 (the market's) has not. The ask is in the money on the price it settles
    /// on, so cancelStale withdraws it and reports O1's reading. Reading the market's oracle returned false here and left
    /// a taker free to fill an O1-settled series below its O1 intrinsic value.
    function test_cancelStale_pinnedInTheMoney_marketOutOfTheMoney_withdraws() public {
        Rolled memory r = _rolledOnO1(_weekly(500, 150));
        _migrateToO2();
        uint256 t = _ny(THU_0910, 11, 0, 0);
        _quotes(t, 260_00000000, 220_000_000);

        _expectO2NeverPriced();
        vm.expectCall(address(oracle), abi.encodeCall(ISettlementOracle.trySpot, (address(nvda))));
        vm.expectEmit(address(roller));
        emit IAutoRoller.StaleAskCancelled(alice, address(nvda), r.longId, r.orderId, 260_000_000, t);
        vm.prank(keeper);
        assertTrue(roller.cancelStale(alice, address(nvda)), "withdrawn on the pinned oracle's spot");
        assertTrue(_order(r.orderId).cancelled, "ask withdrawn");
        (, uint256 orderId,) = roller.position(alice, address(nvda));
        assertEq(orderId, 0, "position no longer tracks an ask");

        // THE EVENTUAL SETTLEMENT SOURCE is O1 as well, the oracle cancelStale read: the series settles in the money at
        // O1's price. O2 is primed with a different, out-of-the-money settlement it would report if it were asked.
        o2.setSettlement(address(nvda), r.expiry, V2Types.SettlementStatus.Finalized, 220_000_000);
        _finalizeAt(r.expiry, 260_00000000);
        vm.prank(keeper);
        ch.settle(r.longId);
        V2Types.Series memory s = ch.series(r.longId);
        assertTrue(s.settled, "settled");
        assertEq(s.oracle, address(oracle), "still pinned to O1");
        assertEq(s.settlementPrice, 260_000_000, "settled on O1, in the money");
        assertEq(o2.finalizeCalls(), 0, "O2 never asked to settle it");
    }

    /// The reverse divergence: O1 (pinned) is short of the strike and O2 (the market's) is past it. The ask is still out
    /// of the money on the price it settles on, so nobody may withdraw it. Reading the market's oracle withdrew it here.
    function test_cancelStale_pinnedOutOfTheMoney_marketInTheMoney_doesNothing() public {
        Rolled memory r = _rolledOnO1(_weekly(500, 150));
        _migrateToO2();
        _quotes(_ny(THU_0910, 11, 0, 0), 225_00000000, 260_000_000);
        uint256 keeperBefore = usdg.balanceOf(keeper);

        _expectO2NeverPriced();
        vm.expectCall(address(oracle), abi.encodeCall(ISettlementOracle.trySpot, (address(nvda))));
        vm.prank(keeper);
        assertFalse(roller.cancelStale(alice, address(nvda)), "out of the money on the pinned oracle");
        assertFalse(_order(r.orderId).cancelled, "ask still live");
        (, uint256 orderId,) = roller.position(alice, address(nvda));
        assertEq(orderId, r.orderId, "position still tracks the ask");
        assertEq(usdg.balanceOf(keeper), keeperBefore, "no bounty");
    }

    /*//////////////////////////////////////////////////////////////
                                 REPRICE
    //////////////////////////////////////////////////////////////*/

    /// O1 (pinned) past the strike, O2 (the market's) short of it: reprice refuses InTheMoney. 3.40 is inside the
    /// [0.5 %, 10 %] band of both 225.00 and 260.00, so only the choice of oracle decides the outcome: reading the
    /// market's oracle repriced it.
    function test_reprice_pinnedInTheMoney_marketOutOfTheMoney_revertsInTheMoney() public {
        Rolled memory r = _rolledOnO1(_smart(50, 150, 1000));
        _migrateToO2();
        _quotes(_ny(THU_0910, 11, 0, 0), 260_00000000, 225_000_000);

        vm.startPrank(pricer);
        vm.expectRevert(V2Errors.InTheMoney.selector);
        roller.reprice(alice, address(nvda), 3_400_000);
        vm.stopPrank();
        (, uint256 orderId,) = roller.position(alice, address(nvda));
        assertEq(orderId, r.orderId, "same ask");
        assertEq(_order(orderId).price, P_3_30, "the ask keeps its roll price");
    }

    /// O1 (pinned) short of the strike, O2 (the market's) past it: the pricer may still reprice. Reading the market's
    /// oracle reverted InTheMoney on an ask that is out of the money for its own settlement.
    function test_reprice_pinnedOutOfTheMoney_marketInTheMoney_reprices() public {
        Rolled memory r = _rolledOnO1(_smart(50, 150, 1000));
        _migrateToO2();
        _quotes(_ny(THU_0910, 11, 0, 0), 225_00000000, 260_000_000);

        _expectO2NeverPriced();
        vm.expectCall(address(oracle), abi.encodeCall(ISettlementOracle.spot, (address(nvda))));
        vm.prank(pricer);
        roller.reprice(alice, address(nvda), 3_400_000);
        (, uint256 orderId,) = roller.position(alice, address(nvda));
        assertTrue(orderId != r.orderId, "replaced");
        assertEq(_order(orderId).price, 3_400_000, "repriced on the pinned oracle's spot");
    }

    /// The band is the pinned oracle's band too. O1 at 225.00 allows [1.125, 22.50]; O2 at 200.00 would allow
    /// [1.00, 20.00]. 1.10 is inside O2's band and outside O1's, 21.00 the other way round; both oracles are short of
    /// the strike, so InTheMoney is out of the way and only the band decides.
    function test_reprice_bandIsMeasuredOnThePinnedOracle() public {
        _rolledOnO1(_smart(50, 150, 1000));
        _migrateToO2();
        _quotes(_ny(THU_0910, 11, 0, 0), 225_00000000, 200_000_000);

        vm.startPrank(pricer);
        vm.expectRevert(V2Errors.BadPrice.selector);
        roller.reprice(alice, address(nvda), 1_100_000);
        roller.reprice(alice, address(nvda), 21_000_000);
        vm.stopPrank();
        (, uint256 orderId,) = roller.position(alice, address(nvda));
        assertEq(_order(orderId).price, 21_000_000, "above O2's ceiling, inside O1's");
    }

    /*//////////////////////////////////////////////////////////////
                                   ROLL
    //////////////////////////////////////////////////////////////*/

    /// A roll after the migration plans on O2, the market's oracle; when the series it lands on was created before the
    /// migration, that series settles on O1, so the roll places only while O1 also has the strike out of the money.
    /// Without the check the roll rested an ask already in the money for its own settlement, and the corrected
    /// cancelStale would then withdraw what the roll had just placed.
    function test_roll_intoASeriesPinnedToTheOldOracle_needsItOutOfTheMoneyThere() public {
        _setStrategy(alice, _weekly(500, 150));
        // Before the migration somebody (createSeries is permissionless) creates the series the roll will land on.
        _spotAt(_ny(THU_0910, 9, 45, 0), 220_00000000);
        uint256 longId = ch.createSeries(address(nvda), false, K_231, FRI_2026_09_11);
        assertEq(ch.series(longId).oracle, address(oracle), "pinned to O1");
        _migrateToO2();

        // O2 at 220.00 plans the 231.00 strike, into that series; O1 already prints 240.00, past it.
        _quotes(_ny(THU_0910, 10, 0, 0), 240_00000000, 220_000_000);
        _noRoll(alice, "the pinned oracle has the strike in the money");

        // O1 falls back under the strike: the ask is out of the money on both, and the roll writes into O1's series.
        _quotes(_ny(THU_0910, 10, 30, 0), 225_00000000, 220_000_000);
        Rolled memory r = _mustRoll(alice);
        assertEq(r.longId, longId, "the pre-migration series");
        assertEq(r.strike, K_231, "strike planned on O2");
        assertEq(ch.series(r.longId).oracle, address(oracle), "and it still settles on O1");
        vm.prank(keeper);
        assertFalse(roller.cancelStale(alice, address(nvda)), "cancelStale cannot withdraw what the roll just placed");
        assertFalse(_order(r.orderId).cancelled, "ask live");
    }

    /// The same check with a pinned oracle that has no fresh spot: the roll waits rather than guess.
    function test_roll_intoASeriesPinnedToTheOldOracle_waitsWhileItHasNoSpot() public {
        _setStrategy(alice, _weekly(500, 150));
        _spotAt(_ny(THU_0910, 9, 45, 0), 220_00000000);
        ch.createSeries(address(nvda), false, K_231, FRI_2026_09_11);
        _migrateToO2();

        // O2 fresh at 220.00; O1's last print is 09:45, past the fixture's 1 h spotMaxAge by 11:00.
        vm.warp(_ny(THU_0910, 11, 0, 0));
        o2.setSpot(address(nvda), true, 220_000_000, _ny(THU_0910, 11, 0, 0));
        _noRoll(alice, "the pinned oracle has no fresh spot");
    }

    /// The site that is right as it was: a series the roll CREATES after the migration is pinned to O2, the oracle it
    /// was planned on, so O1 is never consulted, however far it has drifted.
    function test_roll_newSeriesAfterTheMigration_isPlannedAndPinnedOnTheMarketOracle() public {
        _setStrategy(alice, _weekly(500, 150));
        _migrateToO2();
        _quotes(_ny(THU_0910, 10, 0, 0), 300_00000000, 220_000_000);

        vm.expectCall(address(oracle), abi.encodeWithSelector(ISettlementOracle.trySpot.selector), 0);
        vm.expectCall(address(oracle), abi.encodeWithSelector(ISettlementOracle.spot.selector), 0);
        Rolled memory r = _mustRoll(alice);
        assertEq(r.strike, K_231, "planned on O2's 220.00");
        assertEq(ch.series(r.longId).oracle, address(o2), "pinned to O2");
    }
}

/// @notice T-OP-063 / SEC-13: the two compiled guards on {AutoRoller.reprice}. MIN_ASK_BPS is 50 (0.5 % of spot), so
///         no smart-pricing band can reach lower, and MAX_REPRICE_DROP_BPS is 2,500, so one call may lower an ask by
///         at most a quarter of itself; raising is not bounded. Both are constants of the contract, not of the writer:
///         the finding was a leaked 0-delay PRICER key, and a per-writer default would leave the key exactly where
///         it was. Alice rolls at Thursday 10:00 on a 220.00 spot with the [50, 150, 1000] band: ask 3.30, the band of
///         spot [1.10, 22.00], and the first call's floor 2.475 = 3.30 x 0.75.
contract AutoRollerRepriceGuardsTest is AutoRollerTestBase {
    uint256 internal constant BPS = 10_000;

    /// @dev Alice's ask is live at 3.30 on the 231.00 strike; spot is 220.00 and fresh, so only the guards decide.
    function _rolled() internal returns (Rolled memory r) {
        _setStrategy(alice, _smart(50, 150, 1000));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        r = _mustRoll(alice);
        assertEq(r.price, P_3_30, "ask 3.30");
    }

    function _ask() internal view returns (uint128) {
        (, uint256 orderId,) = roller.position(alice, address(nvda));
        return _order(orderId).price;
    }

    /// @dev The floor the contract reports for the ask `current`: 75 % of it, rounded up to the price tick.
    function _dropFloor(uint128 current) internal pure returns (uint256) {
        uint256 raw = (uint256(current) * (BPS - 2500) + BPS - 1) / BPS;
        return ((raw + 99) / 100) * 100;
    }

    /// (i) THE COMPILED FLOOR. The band's floor is MIN_ASK_BPS of spot -- 1.10 at 220.00 -- and it is reached only
    /// through several capped steps (3.30 -> 2.475 -> 1.8563 -> 1.3923 -> 1.10, each at or above 75 % of the last);
    /// one tick below it is BadPrice. The steps are real reprices, asserted on the order, so the refusal at the
    /// end is the floor's and not the drop cap's.
    function test_reprice_belowTheCompiledFloor_revertsBadPrice_andTheFloorTakesFourCappedSteps() public {
        _rolled();
        uint128[4] memory steps = [uint128(2_475_000), 1_856_300, 1_392_300, 1_100_000];
        vm.startPrank(pricer);
        for (uint256 i; i < 4; ++i) {
            uint128 before = _ask();
            assertGe(uint256(steps[i]) * BPS, uint256(before) * (BPS - 2500), "a step below the cap is not a step");
            roller.reprice(alice, address(nvda), steps[i]);
            assertEq(_ask(), steps[i], "the ask did not move to the step");
        }
        assertEq(_ask(), 1_100_000, "the band floor, MIN_ASK_BPS of spot");
        // One tick below MIN_ASK_BPS of spot: the band refuses. The drop cap would have allowed 0.825, so this is
        // the compiled floor speaking, not the cap.
        vm.expectRevert(V2Errors.BadPrice.selector);
        roller.reprice(alice, address(nvda), 1_099_900);
        vm.stopPrank();
        assertEq(_ask(), 1_100_000, "the refused call left the ask where it was");
    }

    /// (ii) THE DROP CAP. From 3.30, a single call to 2.31 (70 %) is refused by name, with the current ask, the
    /// proposed price and the exact floor (2.475) in the error; 2.64 (80 %) is accepted. The floor is INCLUSIVE:
    /// 2.475 itself is accepted from 3.30, and one tick under it is not.
    function test_reprice_dropOfMoreThanAQuarter_revertsRepriceDropExceeded() public {
        _rolled();
        uint256 floor = _dropFloor(P_3_30);
        assertEq(floor, 2_475_000, "premise: the floor of 3.30 is 2.475");

        vm.startPrank(pricer);
        vm.expectRevert(
            abi.encodeWithSelector(AutoRoller.RepriceDropExceeded.selector, P_3_30, uint128(2_310_000), floor)
        );
        roller.reprice(alice, address(nvda), 2_310_000);
        assertEq(_ask(), P_3_30, "the refused call left the ask where it was");

        vm.expectRevert(
            abi.encodeWithSelector(AutoRoller.RepriceDropExceeded.selector, P_3_30, uint128(2_474_900), floor)
        );
        roller.reprice(alice, address(nvda), 2_474_900);

        roller.reprice(alice, address(nvda), 2_640_000);
        assertEq(_ask(), 2_640_000, "80 % of the ask is inside the cap");
        vm.stopPrank();
    }

    /// (ii, inclusive edge) exactly 75 % is accepted; the cap is measured against the ask AS IT IS NOW, so after a
    /// raise the next drop is a quarter of the raised price, not of the roll price.
    function test_reprice_dropCapIsInclusiveAndMeasuredOnTheCurrentAsk() public {
        _rolled();
        vm.startPrank(pricer);
        roller.reprice(alice, address(nvda), 2_475_000);
        assertEq(_ask(), 2_475_000, "exactly 75 % is accepted");

        roller.reprice(alice, address(nvda), 20_000_000);
        assertEq(_ask(), 20_000_000, "raised");
        // 15.00 is 75 % of 20.00: accepted. 14.9999 would be refused against 20.00 even though it is far above the
        // roll price -- the cap reads the order, not the strategy or the history.
        roller.reprice(alice, address(nvda), 15_000_000);
        assertEq(_ask(), 15_000_000, "75 % of the raised ask");
        vm.expectRevert(
            abi.encodeWithSelector(
                AutoRoller.RepriceDropExceeded.selector, uint128(15_000_000), uint128(11_000_000), _dropFloor(15_000_000)
            )
        );
        roller.reprice(alice, address(nvda), 11_000_000);
        vm.stopPrank();
    }

    /// (iii) RAISING IS NOT BOUNDED: 3.30 -> 22.00 (the band ceiling, MAX_ASK_BPS of spot, a 567 % raise) in one call.
    /// Only the band's ceiling refuses above it.
    function test_reprice_raiseIsUnbounded_upToTheBandCeiling() public {
        _rolled();
        vm.startPrank(pricer);
        roller.reprice(alice, address(nvda), 22_000_000);
        assertEq(_ask(), 22_000_000, "raised to the band ceiling in one call");
        vm.expectRevert(V2Errors.BadPrice.selector);
        roller.reprice(alice, address(nvda), 22_000_100);
        vm.stopPrank();
    }
}
