// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EarnVaultTestBase} from "./EarnVault.t.sol";
import {IEarnVault} from "../../../src/v2/interfaces/IEarnVault.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Ids} from "../../../src/v2/interfaces/V2Ids.sol";

/// @title EarnVault written-exposure bound (T-OP-039, docs/V8-SECURITY-SWEEP.md F-1)
/// @notice THE FINDING. `EarnVault._checkSize` bounds ONE order -- MAX_SERIES_UNITS units, MAX_ORDER_NOTIONAL
///         notional -- and nothing summed across the sixteen AskWrites a series may rest or the eight series the
///         vault may track. Sixteen large writes on one series, or spread over series, committed depositor
///         collateral bounded only by TVL, and the NatSpec pointed at MAX_DAILY_OUTFLOW (the Bid-side outflow
///         bucket) as the aggregate guard. It is not: a write moves no asset out.
///
///         THE BOUND. `_checkWritten` runs on every AskWrite before the book is called and refuses, by name, when
///         (a) written units on that series -- live resting AskWrites plus open shorts, net of longs held there --
///         would pass MAX_WRITTEN_UNITS_PER_SERIES (10_000, the sibling's `maxSeriesUnits`), or (b) written
///         notional summed over every series the vault rests a write on or is short would pass
///         MAX_WRITTEN_NOTIONAL (250_000e6, the sibling's `maxTotalNotional`).
///
///         THE NAMED WRONG FIX, AND THE TEST THAT CATCHES IT (criterion 4.iv). The canonical false fix is a
///         ceiling that cannot be reached: `MAX_WRITTEN_NOTIONAL = type(uint256).max`, or
///         `MAX_WRITTEN_UNITS_PER_SERIES = type(uint256).max`, or either equal to MAX_ORDER_NOTIONAL x 16 x 8.
///         Under any of those every test here compiles and the guard never fires. The tests that go RED, by name:
///           - MAX_WRITTEN_NOTIONAL = type(uint256).max
///               -> {test_writesSpreadAcrossSeriesAreRefusedAtTheTotalCeiling}: every series' write rests, the
///                  loop never finds a refusal and the assertion "the ceiling is reached on the sixth series"
///                  fails 0 != 5. RUN ONCE (T-OP-039, scratch): exactly that, the other four green.
///           - MAX_WRITTEN_UNITS_PER_SERIES = type(uint256).max
///               -> {test_sixteenWritesOnOneSeriesAreRefusedAtThePerSeriesCeiling} and
///                  {test_openShortsCountTowardThePerSeriesCeiling}: both read the ceiling to size their writes,
///                  so under this mutation they die on the per-order `CeilingExceeded` while sizing, and
///                  {test_cancelledWritesLeaveTheWrittenCount} cannot even allocate `cap / 1_000` ids. RUN ONCE:
///                  four red, only the control green. Red either way; the point is that nothing here stays green.
///           - either ceiling = MAX_ORDER_NOTIONAL x 16 x 8
///               -> the same two, for the same reason: the fixtures never reach 32_000_000e6 of notional, so a
///                  "bound" at that height is the absence of one.
///         {test_writesUnderBothCeilingsRest} is the control that the guard is not simply refusing everything.
///
///         PRICES. Spot is set to 240; the calls are struck at 475-480 (inside the `strike <= 2 x spot` band the
///         Clearinghouse enforces at creation) and are therefore OUT OF THE MONEY, so the AskWrite floor is zero
///         and WRITE_PRICE (ten ticks) is a legal ask -- the same shape EarnVault.t.sol's put fixtures use. The
///         sizes are chosen so the live-order ceiling (16) and the per-order caps never fire first: every order
///         here is 1_000 or 10_000 units, at most 48_000e6 notional, and at most ten orders rest on one series.
contract EarnVaultExposureTest is EarnVaultTestBase {
    uint128 internal constant WRITE_PRICE = uint128(V2Constants.PRICE_TICK * 10);
    /// @dev The highest strike the spot band allows at spot 240: `strike <= spot * 2`.
    uint128 internal constant TOP_STRIKE = 480_000_000;

    function setUp() public override {
        super.setUp();
        _setSpot(address(nvda), 240_000_000);
    }

    /// @dev An out-of-the-money call the vault can write at WRITE_PRICE. Distinct strikes give distinct series.
    function _otmCall(uint128 strike) internal returns (uint256 longId) {
        longId = ch.createSeries(address(nvda), false, strike, FRI_2026_09_18);
    }

    function _write(uint256 longId, uint64 units) internal returns (uint256 orderId) {
        vm.prank(quoter);
        orderId = earn.place(longId, WRITE, WRITE_PRICE, units, 0);
    }

    /// @dev Criterion 4.i. Ten 1_000-unit writes rest on one series (10_000 written units, exactly the ceiling);
    ///      the eleventh -- itself far under MAX_ORDER_NOTIONAL, and only the eleventh live order against a cap of
    ///      sixteen, so neither per-order guard is what refuses it -- is refused at the per-series ceiling by name.
    function test_sixteenWritesOnOneSeriesAreRefusedAtThePerSeriesCeiling() public {
        uint256 longId = _otmCall(TOP_STRIKE);
        uint64 units = 1_000;
        uint256 perOrderNotional = uint256(units) * TOP_STRIKE / V2Constants.UNITS_PER_SHARE;
        assertLt(perOrderNotional, earn.MAX_ORDER_NOTIONAL(), "fixture precondition: under the per-order cap");
        assertLt(11, earn.MAX_LIVE_ORDERS_PER_SERIES(), "fixture precondition: the live-order cap does not refuse");

        uint256 cap = earn.MAX_WRITTEN_UNITS_PER_SERIES();
        uint256 n = cap / units; // 10
        for (uint256 i; i < n; ++i) {
            _write(longId, units);
        }

        vm.prank(quoter);
        vm.expectRevert(abi.encodeWithSelector(IEarnVault.WrittenUnitsExceeded.selector, cap + units, cap));
        earn.place(longId, WRITE, WRITE_PRICE, units, 0);
    }

    /// @dev Criterion 4.ii. One full-size write per series, each under both per-order caps, spread across series:
    ///      the running written notional passes MAX_WRITTEN_NOTIONAL on the sixth series and that write is refused
    ///      at the total ceiling by name, with the exact sum it would have reached.
    function test_writesSpreadAcrossSeriesAreRefusedAtTheTotalCeiling() public {
        uint64 units = uint64(earn.MAX_WRITTEN_UNITS_PER_SERIES()); // 10_000, also the per-order units cap
        uint256 cap = earn.MAX_WRITTEN_NOTIONAL();
        uint256 total;
        uint256 refusedAt;
        uint128 strike = TOP_STRIKE;
        for (uint256 i; i < earn.MAX_ORDER_SERIES(); ++i) {
            uint256 longId = _otmCall(strike);
            uint256 notional = uint256(units) * strike / V2Constants.UNITS_PER_SHARE;
            assertLe(notional, earn.MAX_ORDER_NOTIONAL(), "fixture precondition: under the per-order cap");
            if (total + notional > cap) {
                refusedAt = i;
                vm.prank(quoter);
                vm.expectRevert(
                    abi.encodeWithSelector(IEarnVault.WrittenNotionalExceeded.selector, total + notional, cap)
                );
                earn.place(longId, WRITE, WRITE_PRICE, units, 0);
                break;
            }
            _write(longId, units);
            total += notional;
            strike -= uint128(STRIKE_TICK); // one strike tick lower: a distinct series, still OTM
        }
        assertEq(refusedAt, 5, "the ceiling is reached on the sixth series, inside the eight-series bound");
        assertLe(total, cap, "everything that rested is under the ceiling");
    }

    /// @dev Criterion 2. A FILLED write is a short, no longer a resting order, and it is still written exposure:
    ///      after carol takes 1_000 units of the vault's put, 9_000 more may rest (10_000 written) and the next unit
    ///      is refused. The shorts are read from {_openShorts} -- the tracker T-184 keeps for {_positionOpen} --
    ///      and the book, not from a second ledger.
    function test_openShortsCountTowardThePerSeriesCeiling() public {
        // Collateral for the fill: the put's 2.10 USDG per unit, 1_000 units.
        _deposit(alice, DEP);
        vm.prank(quoter);
        earn.depositToClearinghouse(address(usdg), DEP);

        uint256 orderId = _write(putId, 1_000);
        _take(carol, _buy(putId, _ids(orderId), 1_000, WRITE_PRICE, carol));
        assertEq(ch.balanceOf(address(earn), V2Ids.shortIdOf(putId)), 1_000, "fixture precondition: vault is short");

        uint256 cap = earn.MAX_WRITTEN_UNITS_PER_SERIES();
        _write(putId, uint64(cap - 1_000)); // rests: 1_000 short + 9_000 resting == the ceiling exactly

        vm.prank(quoter);
        vm.expectRevert(abi.encodeWithSelector(IEarnVault.WrittenUnitsExceeded.selector, cap + 1, cap));
        earn.place(putId, WRITE, WRITE_PRICE, 1, 0);
    }

    /// @dev Criterion 4.iii, the control: writes under both ceilings rest, on one series and across two, and a Bid
    ///      of any size is not written exposure and never consults the bound.
    function test_writesUnderBothCeilingsRest() public {
        uint256 a = _otmCall(TOP_STRIKE);
        uint256 b = _otmCall(TOP_STRIKE - uint128(STRIKE_TICK));
        assertGt(_write(a, 4_000), 0, "a write under the per-series ceiling rests");
        assertGt(_write(a, 4_000), 0, "a second write on the same series rests while the sum is under the ceiling");
        assertGt(_write(b, 4_000), 0, "a write on another series rests while the notional sum is under the ceiling");

        // Bids are the other side: a Bid (1 USDG per whole share, 100 units, escrowed from a depositor's USDG) is
        // bounded by the outflow bucket and the per-order caps, never by the written ceilings.
        _deposit(alice, DEP);
        uint128 bidPrice = uint128(V2Constants.PRICE_TICK * 10_000);
        vm.prank(quoter);
        assertGt(earn.place(a, BID, bidPrice, 100, 0), 0, "a Bid rests regardless of written exposure");
    }

    /// @dev A cancelled write leaves the written count: after the ten writes of the first case are cancelled the
    ///      series is empty again and a fresh write rests. This is what makes the bound a bound on EXPOSURE rather
    ///      than on history, and it is the case a count of order ids (the forbidden fix b) would get wrong.
    function test_cancelledWritesLeaveTheWrittenCount() public {
        uint256 longId = _otmCall(TOP_STRIKE);
        uint256 cap = earn.MAX_WRITTEN_UNITS_PER_SERIES();
        uint256[] memory ids = new uint256[](cap / 1_000);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = _write(longId, 1_000);
        }
        vm.prank(quoter);
        vm.expectRevert(abi.encodeWithSelector(IEarnVault.WrittenUnitsExceeded.selector, cap + 1_000, cap));
        earn.place(longId, WRITE, WRITE_PRICE, 1_000, 0);

        vm.prank(quoter);
        earn.cancel(ids);
        assertGt(_write(longId, uint64(cap)), 0, "with the resting writes cancelled the whole ceiling is free again");
    }
}
