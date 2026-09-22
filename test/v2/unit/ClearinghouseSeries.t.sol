// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {ClearinghouseTestBase} from "./ClearinghouseBase.t.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Ids} from "../../../src/v2/interfaces/V2Ids.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {OptionMath} from "../../../src/v2/lib/OptionMath.sol";
import {MockSettlementOracle} from "../../../src/v2/mocks/MockSettlementOracle.sol";
import {MockStockToken} from "../../../src/mocks/MockStockToken.sol";

/// @notice Clearinghouse.createSeries: tick, calendar, lead, tenor, spot band with and without spot, idempotency, the
///         id formula, pinning of oracle and fee, the SeriesIdCollision guard, and the per-series views.
contract ClearinghouseSeriesTest is ClearinghouseTestBase {
    /// @dev Friday 2026-10-23 16:00 EDT and Friday 2026-10-30 16:00 EDT: inside and just beyond 45 days of START.
    uint40 internal constant FRI_2026_10_23 = 1_792_785_600;
    uint40 internal constant FRI_2026_10_30 = 1_793_390_400;

    function test_createSeries_storesPinsAndEmits() public {
        uint256 expectedId = V2Ids.longIdOf(address(nvda), false, K_240, FRI_2026_09_18);
        vm.expectEmit(true, true, false, true, address(ch));
        emit IClearinghouse.SeriesCreated(
            expectedId, address(nvda), false, K_240, FRI_2026_09_18, address(oracle), FEE_BPS, 0
        );
        vm.prank(keeper);
        uint256 longId = ch.createSeries(address(nvda), false, K_240, FRI_2026_09_18);
        assertEq(longId, expectedId, "id = V2Ids.longIdOf");
        assertEq(longId, ch.longIdOf(address(nvda), false, K_240, FRI_2026_09_18));
        assertEq(longId & 1, 0);

        V2Types.Series memory s = ch.series(longId);
        assertEq(s.underlying, address(nvda));
        assertFalse(s.isPut);
        assertEq(s.expiry, FRI_2026_09_18);
        assertEq(s.strike, K_240);
        assertEq(s.oracle, address(oracle), "oracle pinned");
        assertEq(s.exerciseFeeBps, FEE_BPS, "fee pinned");
        assertFalse(s.settled);
        assertEq(s.settlementPrice, 0);
        assertTrue(ch.seriesExists(longId));
        assertFalse(ch.seriesExists(_short(longId)), "a short id is not a series key");

        assertEq(ch.collateralAsset(longId), address(nvda), "call collateral is the underlying");
        assertEq(ch.collateralPerUnit(longId), V2Constants.UNIT);
        assertEq(ch.mintCutoff(longId), FRI_2026_09_18 - V2Constants.SETTLEMENT_WINDOW);
        assertEq(ch.locked(longId), 0);
    }

    function test_createSeries_put() public {
        uint256 longId = _put(K_200, FRI_2026_09_11);
        assertTrue(ch.series(longId).isPut);
        assertEq(ch.collateralAsset(longId), address(usdg), "put collateral is USDG");
        assertEq(ch.collateralPerUnit(longId), K_200 / 100, "strike / 100 USDG base units per unit");
        assertTrue(longId != _call(K_200, FRI_2026_09_11), "call and put are different series");
    }

    function test_createSeries_idempotentEvenWhenPausedOrDisabled() public {
        uint256 longId = _call(K_220, FRI_2026_09_11);

        vm.recordLogs();
        assertEq(_call(K_220, FRI_2026_09_11), longId);
        assertEq(vm.getRecordedLogs().length, 0, "no second SeriesCreated");

        vm.prank(guardian);
        ch.setCreatePaused(true);
        V2Types.MarketConfig memory off = _cfg(address(oracle));
        off.enabled = false;
        vm.prank(admin);
        _reconfigure(ch, address(nvda), off);
        assertEq(_call(K_220, FRI_2026_09_11), longId, "existing id returns before pause and market checks");

        vm.warp(FRI_2026_09_11 + 1 days);
        assertEq(_call(K_220, FRI_2026_09_11), longId, "and before the time checks");
    }

    function test_createSeries_marketDisabled() public {
        MockStockToken amzn = new MockStockToken("AMZN Stock Token", "AMZNx");
        vm.expectRevert(V2Errors.MarketDisabled.selector);
        ch.createSeries(address(amzn), false, K_220, FRI_2026_09_18);

        V2Types.MarketConfig memory off = _cfg(address(oracle));
        off.enabled = false;
        vm.prank(admin);
        _reconfigure(ch, address(nvda), off);
        vm.expectRevert(V2Errors.MarketDisabled.selector);
        _call(K_220, FRI_2026_09_18);
    }

    function test_createSeries_createPaused() public {
        vm.prank(guardian);
        ch.setCreatePaused(true);
        vm.expectRevert(V2Errors.CreatePaused.selector);
        _call(K_220, FRI_2026_09_18);
        vm.expectRevert(V2Errors.CreatePaused.selector);
        _put(K_220, FRI_2026_09_18);

        vm.prank(guardian);
        ch.setCreatePaused(false);
        _call(K_220, FRI_2026_09_18);
    }

    function test_createSeries_strikeTick() public {
        vm.expectRevert(V2Errors.BadStrike.selector);
        _call(0, FRI_2026_09_18);
        vm.expectRevert(V2Errors.BadStrike.selector);
        _call(220_500_000, FRI_2026_09_18);
        vm.expectRevert(V2Errors.BadStrike.selector);
        _put(220_000_100, FRI_2026_09_18);
    }

    function test_createSeries_calendar() public {
        vm.expectRevert(V2Errors.BadExpiry.selector);
        _call(K_220, FRI_2026_09_18 + 1);
        vm.expectRevert(V2Errors.BadExpiry.selector);
        _call(K_220, FRI_2026_09_18 - 1 hours);
        vm.expectRevert(V2Errors.BadExpiry.selector);
        _call(K_220, FRI_2026_09_18 + 1 days); // Saturday 16:00

        uint32[] memory day = new uint32[](1);
        // casting to uint32 is safe: a day index of 2026 is ~20k
        // forge-lint: disable-next-line(unsafe-typecast)
        day[0] = uint32(FRI_2026_09_18 / 1 days);
        vm.prank(admin);
        calendar.setHolidays(day, true);
        vm.expectRevert(V2Errors.BadExpiry.selector);
        _call(K_220, FRI_2026_09_18);

        // T-479: Thursday 15:00, inside a session. Friday 17:00 is now refused by the calendar (Friday is a holiday
        // here and 17:00 is after the close), and this row checks that createSeries accepts a whitelisted instant.
        uint40 special = FRI_2026_09_18 - 1 days - 1 hours;
        vm.prank(admin);
        calendar.setSpecialExpiry(special, true);
        uint256 longId = _call(K_220, special);
        assertEq(ch.series(longId).expiry, special, "a special expiry is accepted");
    }

    function test_createSeries_minimumLead() public {
        vm.warp(THU_2026_09_10 - V2Constants.MIN_SERIES_LEAD + 1);
        vm.expectRevert(V2Errors.BadExpiry.selector);
        _call(K_220, THU_2026_09_10);

        vm.warp(THU_2026_09_10 - V2Constants.MIN_SERIES_LEAD);
        uint256 longId = _call(K_220, THU_2026_09_10);
        assertEq(ch.mintCutoff(longId), THU_2026_09_10 - 1800, "cutoff 30 minutes later than creation");

        vm.warp(THU_2026_09_10);
        vm.expectRevert(V2Errors.BadExpiry.selector);
        _put(K_220, THU_2026_09_10);
    }

    function test_createSeries_maximumTenor() public {
        _call(K_220, FRI_2026_10_23);
        vm.expectRevert(V2Errors.BadExpiry.selector);
        _call(K_220, FRI_2026_10_30);

        vm.warp(FRI_2026_10_30 - V2Constants.MAX_TENOR - 1);
        vm.expectRevert(V2Errors.BadExpiry.selector);
        _call(K_220, FRI_2026_10_30);

        vm.warp(FRI_2026_10_30 - V2Constants.MAX_TENOR);
        _call(K_220, FRI_2026_10_30);
    }

    /// @dev NVDA spot 220.00: the band is [110.00, 440.00], both ends inclusive.
    function test_createSeries_spotBand() public {
        _call(110_000_000, FRI_2026_09_18);
        _put(440_000_000, FRI_2026_09_18);
        vm.expectRevert(V2Errors.BadStrike.selector);
        _call(109_000_000, FRI_2026_09_18);
        vm.expectRevert(V2Errors.BadStrike.selector);
        _put(441_000_000, FRI_2026_09_18);
    }

    function test_createSeries_bandSkippedWithoutSpot() public {
        oracle.setSpot(address(nvda), false, NVDA_SPOT, START);
        _call(1_000_000, FRI_2026_09_18);
        _call(5_000_000_000, FRI_2026_09_18);

        oracle.setSpot(address(nvda), true, 0, START);
        _put(2_000_000, FRI_2026_09_18);

        oracle.setSpot(address(nvda), true, NVDA_SPOT, START);
        oracle.setTrySpotReverts(true);
        _put(3_000_000, FRI_2026_09_18);
        _call(9_000_000_000, FRI_2026_09_18);
    }

    function test_createSeries_hugeSpotCannotOverflowBand() public {
        oracle.setSpot(address(nvda), true, type(uint256).max, START);
        vm.expectRevert(V2Errors.BadStrike.selector);
        _call(K_220, FRI_2026_09_18); // below spot / 2
        oracle.setSpot(address(nvda), true, uint256(type(uint128).max) + 1, START);
        _call(uint128(type(uint128).max / 1e6 * 1e6), FRI_2026_09_18);
    }

    /// @dev Series keep the oracle and fee of their creation; a market change applies to later series only.
    function test_createSeries_pinsOracleAndFeeAtCreation() public {
        uint256 before = _call(K_220, FRI_2026_09_18);
        MockSettlementOracle other = new MockSettlementOracle();
        V2Types.MarketConfig memory cfg = _cfg(address(other));
        cfg.exerciseFeeBps = 200;
        vm.prank(admin);
        _reconfigure(ch, address(nvda), cfg);

        uint256 afterId = _call(K_240, FRI_2026_09_18);
        assertEq(ch.series(before).oracle, address(oracle));
        assertEq(ch.series(before).exerciseFeeBps, FEE_BPS);
        assertEq(ch.series(afterId).oracle, address(other));
        assertEq(ch.series(afterId).exerciseFeeBps, 200);
    }

    /// @dev INTERFACE_VERSION 6: every new series has its oracle pin the expiry's settlement configuration; the
    ///      existing-id path calls nothing; a pin that reverts reverts the creation.
    function test_createSeries_pinsTheExpiryOnItsOracle() public {
        uint256 longId = _call(K_220, FRI_2026_09_18);
        assertTrue(oracle.pinned(address(nvda), FRI_2026_09_18), "expiry pinned");
        assertEq(oracle.pinCalls(), 1, "one pin");
        _put(K_220, FRI_2026_09_18);
        assertEq(oracle.pinCalls(), 2, "every new series calls pin (the real oracle returns at once after the first)");
        assertEq(_call(K_220, FRI_2026_09_18), longId, "existing id");
        assertEq(oracle.pinCalls(), 2, "the existing-id path does not call pin");

        oracle.setPinReverts(true);
        vm.expectRevert(V2Errors.NoSource.selector);
        _call(K_240, FRI_2026_09_18);
        assertFalse(ch.seriesExists(ch.longIdOf(address(nvda), false, K_240, FRI_2026_09_18)), "not created");
        assertEq(_call(K_220, FRI_2026_09_18), longId, "an existing series still resolves");
    }

    /// @dev The pin goes to the oracle the market points at now, the one pinned into the series.
    function test_createSeries_pinsOnTheOracleItPinsIntoTheSeries() public {
        MockSettlementOracle other = new MockSettlementOracle();
        vm.prank(admin);
        _reconfigure(ch, address(nvda), _cfg(address(other)));
        uint256 longId = _call(K_220, FRI_2026_09_18);
        assertEq(ch.series(longId).oracle, address(other), "series oracle");
        assertTrue(other.pinned(address(nvda), FRI_2026_09_18), "pinned there");
        assertFalse(oracle.pinned(address(nvda), FRI_2026_09_18), "not on the previous oracle");
    }

    function test_createSeries_newCalendarAppliesToNewSeries() public {
        uint256 longId = _call(K_220, FRI_2026_09_18);
        ExpiryCalendarRejectAll strict = new ExpiryCalendarRejectAll();
        vm.prank(admin);
        ch.setCalendar(address(strict));
        vm.expectRevert(V2Errors.BadExpiry.selector);
        _call(K_240, FRI_2026_09_18);
        assertEq(_call(K_220, FRI_2026_09_18), longId, "existing series unaffected");
    }

    /// @dev Forces an id collision: series B's storage is overwritten with series A's tuple, so B's id now holds a
    ///      different (strike) tuple than the arguments that hash to it.
    function test_createSeries_idCollisionReverts() public {
        uint256 idA = _call(K_220, FRI_2026_09_18);
        uint256 idB = ch.longIdOf(address(nvda), false, K_240, FRI_2026_09_18);
        bytes32 baseA = keccak256(abi.encode(idA, SERIES_SLOT));
        bytes32 baseB = keccak256(abi.encode(idB, SERIES_SLOT));
        assertEq(address(uint160(uint256(vm.load(address(ch), baseA)))), address(nvda), "SERIES_SLOT is _series");
        for (uint256 i; i < 5; ++i) {
            vm.store(address(ch), bytes32(uint256(baseB) + i), vm.load(address(ch), bytes32(uint256(baseA) + i)));
        }
        assertTrue(ch.seriesExists(idB));
        assertEq(ch.series(idB).strike, K_220);

        vm.expectRevert(V2Errors.SeriesIdCollision.selector);
        _call(K_240, FRI_2026_09_18);
        assertEq(_call(K_220, FRI_2026_09_18), idA, "the true tuple of A still resolves");
    }

    function test_views_unknownSeries() public {
        uint256 unknown = ch.longIdOf(address(nvda), false, K_220, FRI_2026_09_18);
        V2Types.Series memory s = ch.series(unknown);
        assertEq(s.underlying, address(0));
        assertFalse(ch.seriesExists(unknown));

        vm.expectRevert(V2Errors.UnknownSeries.selector);
        ch.collateralAsset(unknown);
        vm.expectRevert(V2Errors.UnknownSeries.selector);
        ch.collateralPerUnit(unknown);
        vm.expectRevert(V2Errors.UnknownSeries.selector);
        ch.mintCutoff(unknown);
        vm.expectRevert(V2Errors.UnknownSeries.selector);
        ch.previewSettlement(unknown, NVDA_SPOT);

        uint256 longId = _call(K_220, FRI_2026_09_18);
        vm.expectRevert(V2Errors.UnknownSeries.selector);
        ch.collateralPerUnit(_short(longId));
    }

    function testFuzz_previewSettlement_matchesOptionMath(bool isPut, uint256 k, uint256 price) public {
        k = bound(k, 110, 440);
        price = bound(price, 0, 1e15);
        // casting to uint128 is safe: k is bounded to [110, 440]
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 strike = uint128(k * 1e6);
        uint256 longId = ch.createSeries(address(nvda), isPut, strike, FRI_2026_09_18);
        (uint256 l, uint256 f, uint256 sh) = ch.previewSettlement(longId, price);
        (uint256 el, uint256 ef, uint256 esh) = OptionMath.settlementPerUnit(isPut, strike, price, FEE_BPS);
        assertEq(l, el);
        assertEq(f, ef);
        assertEq(sh, esh);
        assertEq(l + f + sh, ch.collateralPerUnit(longId), "conservation");
    }

    function testFuzz_createSeries_gridStrikesInBand(bool isPut, uint256 k, uint8 which) public {
        k = bound(k, 110, 440);
        uint40[3] memory expiries = [THU_2026_09_10, FRI_2026_09_11, FRI_2026_09_18];
        uint40 expiry = expiries[which % 3];
        // casting to uint128 is safe: k is bounded to [110, 440]
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 strike = uint128(k * 1e6);

        vm.recordLogs();
        uint256 longId = ch.createSeries(address(nvda), isPut, strike, expiry);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IClearinghouse.SeriesCreated.selector);
        assertEq(uint256(logs[0].topics[1]), longId);
        assertEq(longId, V2Ids.longIdOf(address(nvda), isPut, strike, expiry));
        assertEq(ch.createSeries(address(nvda), isPut, strike, expiry), longId, "idempotent");
    }
}

/// @dev A calendar that accepts nothing, to show a new calendar pointer only affects new series.
contract ExpiryCalendarRejectAll {
    function isValidExpiry(uint40) external pure returns (bool) {
        return false;
    }
}
