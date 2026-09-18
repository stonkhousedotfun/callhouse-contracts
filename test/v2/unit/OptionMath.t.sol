// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, stdError} from "forge-std/Test.sol";
import {OptionMath} from "../../../src/v2/lib/OptionMath.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";

/// @dev External wrapper so the library's panics are catchable by vm.expectRevert (an internal call that reverts
///      reverts the test frame itself).
contract OptionMathHarness {
    function premium(uint256 price, uint256 units) external pure returns (uint256) {
        return OptionMath.premium(price, units);
    }

    function longPayoutPerUnit(uint256 gross, uint256 fee) external pure returns (uint256) {
        return OptionMath.longPayoutPerUnit(gross, fee);
    }

    function shortPayoutPerUnit(uint256 coll, uint256 gross) external pure returns (uint256) {
        return OptionMath.shortPayoutPerUnit(coll, gross);
    }

    function roundUpToTick(uint256 x, uint256 tick) external pure returns (uint256) {
        return OptionMath.roundUpToTick(x, tick);
    }

    function roundDownToTick(uint256 x, uint256 tick) external pure returns (uint256) {
        return OptionMath.roundDownToTick(x, tick);
    }

    function mintFee(uint256 collateral, uint256 feePpm, uint256 remaining) external pure returns (uint256) {
        return OptionMath.mintFee(collateral, feePpm, remaining);
    }

    function mintFeeRefund(uint256 collateral, uint256 feePpm, uint256 remaining) external pure returns (uint256) {
        return OptionMath.mintFeeRefund(collateral, feePpm, remaining);
    }
}

/// @notice `src/v2/lib/OptionMath.sol` against hand-computed tables and the properties architecture §3.1 promises.
/// @dev Every expected value in the tables was worked out by hand from the formulas in §3.1 (and re-checked with node
///      BigInt), never by calling the library. The fuzz properties check results against independent definitions
///      (floor bounds, min of the two fee legs written as gross / 10), not against a copy of the implementation.
///
///      Units: strike and price are USDG base units (6 dp) per whole share; per-unit amounts are base units of the
///      collateral asset, the 18-dp underlying for calls (UNIT = 1e16 = 0.01 share) and USDG for puts.
contract OptionMathTest is Test {
    OptionMathHarness internal h;

    uint256 internal constant UNIT = V2Constants.UNIT;
    uint256 internal constant K231 = 231_000_000; // $231.00
    /// @dev Put collateral at K = 231: 231_000_000 / 100 = 2.31 USDG per 0.01 share.
    uint256 internal constant PUT_COLL_231 = 2_310_000;

    /// @dev Bounds of the conservation fuzz: K, P in [1e4, 1e12] ($0.01 to $1,000,000 per share) and fee bps up
    ///      to the compiled ceiling.
    uint256 internal constant FUZZ_MIN_PRICE = 1e4;
    uint256 internal constant FUZZ_MAX_PRICE = 1e12;

    function setUp() public {
        h = new OptionMathHarness();
    }

    /*//////////////////////////////////////////////////////////////
                                 PREMIUM
    //////////////////////////////////////////////////////////////*/

    function test_premium_table() public pure {
        assertEq(OptionMath.premium(1_900_000, 1), 19_000, "1.90/share x 0.01 share = 0.019 USDG");
        assertEq(OptionMath.premium(1_900_000, 13), 247_000, "0.13 share = 0.247 USDG");
        assertEq(OptionMath.premium(1_900_000, 100), 1_900_000, "a whole share costs the price");
        assertEq(OptionMath.premium(240_000_000, 10), 24_000_000, "0.1 share at $240 = 24 USDG");
        assertEq(OptionMath.premium(100, 1), 1, "smallest tick, smallest size: 1 base unit, exact");
        assertEq(OptionMath.premium(0, 500), 0, "zero price");
        assertEq(OptionMath.premium(1_900_000, 0), 0, "zero units");
    }

    /// @dev Off the grid the result floors, and because the multiplication comes first the floor is per call, not
    ///      per unit: 1.5 base units per unit over 2 units is 3, not 2.
    function test_premium_offGridFloorsOncePerCall() public pure {
        assertEq(OptionMath.premium(150, 1), 1, "1.5 floors to 1");
        assertEq(OptionMath.premium(199, 1), 1, "1.99 floors to 1");
        assertEq(OptionMath.premium(150, 2), 3, "multiply before divide");
    }

    function testFuzz_premium_exactOnTickGrid(uint256 ticks, uint64 units) public pure {
        ticks = bound(ticks, 0, type(uint128).max / V2Constants.PRICE_TICK);
        uint256 price = ticks * V2Constants.PRICE_TICK;
        assertTrue(OptionMath.isPriceTick(price), "grid price");
        uint256 p = OptionMath.premium(price, units);
        assertEq(p * V2Constants.UNITS_PER_SHARE, price * units, "no remainder on the grid");
        assertEq(p, ticks * units, "a unit costs exactly price / 100");
    }

    /// @dev premium is the helper that multiplies by a unit count. Its bound: price <= type(uint128).max (the
    ///      V2Types.Order.price type) and units <= type(uint64).max give a product < 2^192.
    function test_premium_noOverflowAtUint128PriceAndUint64Units() public pure {
        uint256 maxPrice = type(uint128).max;
        uint256 maxUnits = type(uint64).max;
        assertEq(OptionMath.premium(maxPrice, maxUnits), maxPrice * maxUnits / 100, "top of both types");
        uint256 gridMax = OptionMath.roundDownToTick(maxPrice, V2Constants.PRICE_TICK);
        assertEq(OptionMath.premium(gridMax, maxUnits) * 100, gridMax * maxUnits, "exact at the top of the grid");
    }

    function test_premium_beyondUint256Reverts() public {
        vm.expectRevert(stdError.arithmeticError);
        h.premium(type(uint256).max, 2);
    }

    /*//////////////////////////////////////////////////////////////
                               COLLATERAL
    //////////////////////////////////////////////////////////////*/

    function test_collateralPerUnit_table() public pure {
        assertEq(OptionMath.collateralPerUnit(false, K231), UNIT, "a call locks 0.01 share");
        assertEq(OptionMath.collateralPerUnit(false, 0), UNIT, "whatever the strike");
        assertEq(OptionMath.collateralPerUnit(false, type(uint128).max), UNIT, "whatever the strike");
        assertEq(OptionMath.collateralPerUnit(true, K231), PUT_COLL_231, "a put locks strike / 100 USDG");
        assertEq(OptionMath.collateralPerUnit(true, 1_000_000), 10_000, "$1 strike: 0.01 USDG");
        assertEq(OptionMath.collateralPerUnit(true, 100), 1, "smallest tick strike: 1 base unit");
    }

    /*//////////////////////////////////////////////////////////////
                    COLLATERAL RENT (INTERFACE_VERSION 7)
    //////////////////////////////////////////////////////////////*/

    /// @notice The rent table of c05, hand-computed: ceil / floor of `collateral x ppm x remaining / (1e6 x 7 days)`.
    /// @dev The two 80 ppm rows are the design's §5.1 worked numbers. 1e16 x 80 x 368100 = 2.94480e23, and
    ///      1e6 x 604800 = 6.048e11, so the exact quotient is 486_904_761_904.76..., which ceils to ...905 and floors
    ///      to ...904. A whole MINT_FEE_PERIOD of a 1e18 collateral at 80 ppm is exactly 80e12, with no rounding at
    ///      all, so ceil and floor agree there.
    function test_mintFee_table() public pure {
        // Exactly one period: the rate is the definition, and nothing rounds.
        assertEq(OptionMath.mintFee(1e18, 80, 7 days), 80_000_000_000_000, "80 ppm of 1e18 for one full period");
        assertEq(OptionMath.mintFeeRefund(1e18, 80, 7 days), 80_000_000_000_000, "and the floor agrees");

        // The design's weekly roll distance, one unit and a hundred.
        assertEq(OptionMath.mintFee(UNIT, 80, 368_100), 486_904_761_905, "one unit, ceiled");
        assertEq(OptionMath.mintFeeRefund(UNIT, 80, 368_100), 486_904_761_904, "one unit, floored");
        assertEq(OptionMath.mintFee(100 * UNIT, 80, 368_100), 48_690_476_190_477, "a hundred units, ceiled");
        assertEq(OptionMath.mintFeeRefund(100 * UNIT, 80, 368_100), 48_690_476_190_476, "a hundred units, floored");

        // A 1-unit put at strike 230: collateral 2_300_000 USDG base units, exact quotient 111.99...
        assertEq(OptionMath.mintFee(2_300_000, 80, 368_100), 112, "put, ceiled");
        assertEq(OptionMath.mintFeeRefund(2_300_000, 80, 368_100), 111, "put, floored");

        // A daily rung: 22_500 s left at the ceiling rate.
        assertEq(
            OptionMath.mintFee(UNIT, V2Constants.MINT_FEE_CEIL_PPM, 22_500),
            1_860_119_047_620,
            "the ceiling rate on a daily"
        );
    }

    /// @notice Anything times zero is zero, on both roundings: no rate, no time and no collateral each cost nothing.
    /// @dev The ceiling would otherwise return 1 for a zero product, charging rent on a market that set none.
    function test_mintFee_zeroInputsCostNothing() public pure {
        assertEq(OptionMath.mintFee(0, 80, 7 days), 0, "no collateral");
        assertEq(OptionMath.mintFee(1e18, 0, 7 days), 0, "no rate");
        assertEq(OptionMath.mintFee(1e18, 80, 0), 0, "no time left");
        assertEq(OptionMath.mintFeeRefund(0, 80, 7 days), 0);
        assertEq(OptionMath.mintFeeRefund(1e18, 0, 7 days), 0);
        assertEq(OptionMath.mintFeeRefund(1e18, 80, 0), 0);
    }

    /// @notice The smallest non-zero product still costs one base unit: rent is never free where it is owed.
    function test_mintFee_ceilsAnyNonZeroProductToAtLeastOne() public pure {
        assertEq(OptionMath.mintFee(1, 1, 1), 1, "one base unit, one ppm, one second");
        assertEq(OptionMath.mintFeeRefund(1, 1, 1), 0, "and the refund of it floors to nothing");
    }

    /// @notice The two facts the refund proof rests on (V2-ACCOUNTING §3.3), over the whole reachable input range.
    /// @dev (1) floor <= ceil <= floor + 1 for equal inputs, so a unit's ceiled fee always covers its floored refund
    ///      at the same instant; (2) both are non-decreasing in `remaining`, so a refund taken LATER is never larger.
    ///      Bounds are the reachable ones: collateral < 2^192, ppm <= MINT_FEE_CEIL_PPM, remaining <= MAX_TENOR.
    function testFuzz_mintFee_ceilCoversFloorAndFallsWithTime(uint256 collateral, uint32 ppm, uint32 remaining)
        public
        pure
    {
        collateral = bound(collateral, 0, type(uint192).max);
        ppm = uint32(bound(ppm, 0, V2Constants.MINT_FEE_CEIL_PPM));
        remaining = uint32(bound(remaining, 0, V2Constants.MAX_TENOR));

        uint256 ceiled = OptionMath.mintFee(collateral, ppm, remaining);
        uint256 floored = OptionMath.mintFeeRefund(collateral, ppm, remaining);
        assertLe(floored, ceiled, "the refund never exceeds the fee at the same instant");
        assertLe(ceiled - floored, 1, "and is at most one base unit below it");
        assertEq(floored, collateral * ppm * remaining / (V2Constants.PPM * V2Constants.MINT_FEE_PERIOD), "floor");

        uint256 less = remaining / 2;
        assertLe(OptionMath.mintFee(collateral, ppm, less), ceiled, "rent falls as the life runs out");
        assertLe(OptionMath.mintFeeRefund(collateral, ppm, less), floored, "and so does the refund");
    }

    /// @notice Inside the reachable bounds nothing overflows; above them checked arithmetic reverts, never wraps.
    /// @dev The largest reachable product is collateral < 2^192 times ppm < 2^32 times remaining < 2^22, under 2^246.
    ///      The harness makes the panic catchable: an internal call that reverts would revert the test frame itself.
    function test_mintFee_overflowBounds() public {
        uint256 maxColl = type(uint192).max;
        uint256 top = OptionMath.mintFee(maxColl, V2Constants.MINT_FEE_CEIL_PPM, V2Constants.MAX_TENOR);
        assertGt(top, 0, "the largest reachable input is computable");
        assertLe(top, maxColl, "and rent never exceeds the collateral it is charged on at these rates");

        vm.expectRevert(stdError.arithmeticError);
        h.mintFee(type(uint256).max, 2, 1);
        vm.expectRevert(stdError.arithmeticError);
        h.mintFeeRefund(type(uint256).max, 2, 1);
    }

    /*//////////////////////////////////////////////////////////////
                           SETTLEMENT TABLES
    //////////////////////////////////////////////////////////////*/

    struct Row {
        string label;
        bool isPut;
        uint256 strike;
        uint256 price;
        uint256 feeBps;
        uint256 gross;
        uint256 fee;
        uint256 longPayout;
        uint256 shortPayout;
    }

    /// @dev Checks every helper on its own and through settlementPerUnit, then the identity.
    function _assertRow(Row memory r) internal pure {
        uint256 coll = OptionMath.collateralPerUnit(r.isPut, r.strike);
        uint256 gross = OptionMath.grossPayoutPerUnit(r.isPut, r.strike, r.price);
        uint256 fee = OptionMath.feePerUnit(gross, coll, r.feeBps);
        assertEq(gross, r.gross, string.concat(r.label, ": gross"));
        assertEq(fee, r.fee, string.concat(r.label, ": fee"));
        assertEq(OptionMath.longPayoutPerUnit(gross, fee), r.longPayout, string.concat(r.label, ": long"));
        assertEq(OptionMath.shortPayoutPerUnit(coll, gross), r.shortPayout, string.concat(r.label, ": short"));

        (uint256 l, uint256 f, uint256 s) = OptionMath.settlementPerUnit(r.isPut, r.strike, r.price, r.feeBps);
        assertEq(l, r.longPayout, string.concat(r.label, ": settlementPerUnit long"));
        assertEq(f, r.fee, string.concat(r.label, ": settlementPerUnit fee"));
        assertEq(s, r.shortPayout, string.concat(r.label, ": settlementPerUnit short"));
        assertEq(l + f + s, coll, string.concat(r.label, ": long + fee + short == collateralPerUnit"));
    }

    /// @dev Calls: collateral is UNIT = 1e16 underlying base units; gross = UNIT * (P - K) / P.
    function test_settlement_callTable() public pure {
        Row[] memory rows = new Row[](9);
        // NVDA K=231, P=240: gross = 1e16 * 9 / 240 = 3.75e14 (0.0375 of a 0.01 share = $9 at $240).
        // fee 25 bps: min(1e16 * 25 / 1e4 = 2.5e13, 3.75e14 / 10 = 3.75e13) = 2.5e13, the rate leg.
        rows[0] = Row({
            label: "call K231 P240 25bps",
            isPut: false,
            strike: K231,
            price: 240_000_000,
            feeBps: 25,
            gross: 375_000_000_000_000,
            fee: 25_000_000_000_000,
            longPayout: 350_000_000_000_000,
            shortPayout: 9_625_000_000_000_000
        });
        // Same at the 200 bps ceiling: rate leg 2e14 > share cap 3.75e13, so the 10 % cap binds.
        rows[1] = Row({
            label: "call K231 P240 200bps share cap binds",
            isPut: false,
            strike: K231,
            price: 240_000_000,
            feeBps: 200,
            gross: 375_000_000_000_000,
            fee: 37_500_000_000_000,
            longPayout: 337_500_000_000_000,
            shortPayout: 9_625_000_000_000_000
        });
        rows[2] = Row({
            label: "call K231 P240 0bps",
            isPut: false,
            strike: K231,
            price: 240_000_000,
            feeBps: 0,
            gross: 375_000_000_000_000,
            fee: 0,
            longPayout: 375_000_000_000_000,
            shortPayout: 9_625_000_000_000_000
        });
        // At the money: nothing to the long, no fee, the writer keeps the whole unit.
        rows[3] = Row({
            label: "call ATM",
            isPut: false,
            strike: K231,
            price: K231,
            feeBps: 200,
            gross: 0,
            fee: 0,
            longPayout: 0,
            shortPayout: UNIT
        });
        rows[4] = Row({
            label: "call OTM P220",
            isPut: false,
            strike: K231,
            price: 220_000_000,
            feeBps: 200,
            gross: 0,
            fee: 0,
            longPayout: 0,
            shortPayout: UNIT
        });
        // Off-grid TWAP P=233.333333: 1e16 * 2_333_333 / 233_333_333 = 99_999_985_857_142.83 -> floors against the
        // long. Share cap 9_999_998_585_714 < rate leg 2.5e13, so the cap binds even at 25 bps.
        rows[5] = Row({
            label: "call off-grid TWAP floors",
            isPut: false,
            strike: K231,
            price: 233_333_333,
            feeBps: 25,
            gross: 99_999_985_857_142,
            fee: 9_999_998_585_714,
            longPayout: 89_999_987_271_428,
            shortPayout: 9_900_000_014_142_858
        });
        // P = 2K: half the unit. 200 bps rate leg 2e14 < share cap 5e14: the rate leg binds.
        rows[6] = Row({
            label: "call P=2K 200bps rate leg binds",
            isPut: false,
            strike: K231,
            price: 462_000_000,
            feeBps: 200,
            gross: 5_000_000_000_000_000,
            fee: 200_000_000_000_000,
            longPayout: 4_800_000_000_000_000,
            shortPayout: 5_000_000_000_000_000
        });
        // K=195, P=200: gross = 1e16 * 5 / 200 = 2.5e14; both legs are exactly 2.5e13 at 25 bps.
        rows[7] = Row({
            label: "call both fee legs equal",
            isPut: false,
            strike: 195_000_000,
            price: 200_000_000,
            feeBps: 25,
            gross: 250_000_000_000_000,
            fee: 25_000_000_000_000,
            longPayout: 225_000_000_000_000,
            shortPayout: 9_750_000_000_000_000
        });
        // Fuzz-range corner K=1e4, P=1e12: gross = 1e16 - 1e8; the long never gets the whole unit.
        rows[8] = Row({
            label: "call far ITM corner",
            isPut: false,
            strike: 1e4,
            price: 1e12,
            feeBps: 25,
            gross: 9_999_999_900_000_000,
            fee: 25_000_000_000_000,
            longPayout: 9_974_999_900_000_000,
            shortPayout: 100_000_000
        });
        for (uint256 i; i < rows.length; ++i) {
            _assertRow(rows[i]);
        }
    }

    /// @dev Puts: collateral is strike / 100 USDG base units (2_310_000 at K=231); gross = (K - P) / 100.
    function test_settlement_putTable() public pure {
        Row[] memory rows = new Row[](9);
        // K=231, P=220: gross = 11_000_000 / 100 = 110_000 (0.11 USDG per 0.01 share).
        // fee 25 bps: min(2_310_000 * 25 / 1e4 = 5_775, 110_000 / 10 = 11_000) = 5_775.
        rows[0] = Row({
            label: "put K231 P220 25bps",
            isPut: true,
            strike: K231,
            price: 220_000_000,
            feeBps: 25,
            gross: 110_000,
            fee: 5_775,
            longPayout: 104_225,
            shortPayout: 2_200_000
        });
        // 200 bps: rate leg 46_200 > share cap 11_000.
        rows[1] = Row({
            label: "put K231 P220 200bps share cap binds",
            isPut: true,
            strike: K231,
            price: 220_000_000,
            feeBps: 200,
            gross: 110_000,
            fee: 11_000,
            longPayout: 99_000,
            shortPayout: 2_200_000
        });
        rows[2] = Row({
            label: "put ATM",
            isPut: true,
            strike: K231,
            price: K231,
            feeBps: 200,
            gross: 0,
            fee: 0,
            longPayout: 0,
            shortPayout: PUT_COLL_231
        });
        rows[3] = Row({
            label: "put OTM P240",
            isPut: true,
            strike: K231,
            price: 240_000_000,
            feeBps: 200,
            gross: 0,
            fee: 0,
            longPayout: 0,
            shortPayout: PUT_COLL_231
        });
        // P = 0: the long is owed the whole collateral; the writer gets nothing back.
        rows[4] = Row({
            label: "put P=0 pays all collateral",
            isPut: true,
            strike: K231,
            price: 0,
            feeBps: 25,
            gross: PUT_COLL_231,
            fee: 5_775,
            longPayout: 2_304_225,
            shortPayout: 0
        });
        // In the money by 50 base units per share: less than 1 base unit per 0.01 share floors to 0.
        rows[5] = Row({
            label: "put ITM below one base unit per unit",
            isPut: true,
            strike: K231,
            price: 230_999_950,
            feeBps: 200,
            gross: 0,
            fee: 0,
            longPayout: 0,
            shortPayout: PUT_COLL_231
        });
        // K - P = 876_544: gross = 8_765 (8_765.44 floored); share cap 876 (876.5 floored) < rate leg 5_775.
        rows[6] = Row({
            label: "put off-grid TWAP floors",
            isPut: true,
            strike: K231,
            price: 230_123_456,
            feeBps: 25,
            gross: 8_765,
            fee: 876,
            longPayout: 7_889,
            shortPayout: 2_301_235
        });
        // K - P = 500: gross 5 < 10, the share cap floors to 0, so no fee although the rate leg is 5_775.
        rows[7] = Row({
            label: "put gross below 10 is fee-free",
            isPut: true,
            strike: K231,
            price: 230_999_500,
            feeBps: 200,
            gross: 5,
            fee: 0,
            longPayout: 5,
            shortPayout: 2_309_995
        });
        // K - P = 1_000: gross 10, share cap 1.
        rows[8] = Row({
            label: "put gross 10 pays 1",
            isPut: true,
            strike: K231,
            price: 230_999_000,
            feeBps: 200,
            gross: 10,
            fee: 1,
            longPayout: 9,
            shortPayout: 2_309_990
        });
        for (uint256 i; i < rows.length; ++i) {
            _assertRow(rows[i]);
        }
    }

    /// @dev The two subtractions panic when handed amounts no helper produces; nothing clamps silently.
    function test_payoutSubtractions_panicOnInconsistentInputs() public {
        vm.expectRevert(stdError.arithmeticError);
        h.longPayoutPerUnit(10, 11);
        vm.expectRevert(stdError.arithmeticError);
        h.shortPayoutPerUnit(UNIT, UNIT + 1);
    }

    /*//////////////////////////////////////////////////////////////
                             FUZZ PROPERTIES
    //////////////////////////////////////////////////////////////*/

    /// @dev Helper-by-helper, as the spec composes them, and checks settlementPerUnit agrees.
    function _settle(bool isPut, uint256 strike, uint256 price, uint256 feeBps)
        internal
        pure
        returns (uint256 coll, uint256 gross, uint256 fee, uint256 longPayout, uint256 shortPayout)
    {
        coll = OptionMath.collateralPerUnit(isPut, strike);
        gross = OptionMath.grossPayoutPerUnit(isPut, strike, price);
        fee = OptionMath.feePerUnit(gross, coll, feeBps);
        longPayout = OptionMath.longPayoutPerUnit(gross, fee);
        shortPayout = OptionMath.shortPayoutPerUnit(coll, gross);
        (uint256 l, uint256 f, uint256 s) = OptionMath.settlementPerUnit(isPut, strike, price, feeBps);
        assertEq(l, longPayout, "settlementPerUnit long");
        assertEq(f, fee, "settlementPerUnit fee");
        assertEq(s, shortPayout, "settlementPerUnit short");
    }

    function testFuzz_conservation_call(uint256 strike, uint256 price, uint256 feeBps) public pure {
        strike = bound(strike, FUZZ_MIN_PRICE, FUZZ_MAX_PRICE);
        price = bound(price, FUZZ_MIN_PRICE, FUZZ_MAX_PRICE);
        feeBps = bound(feeBps, 0, V2Constants.EXERCISE_FEE_CEIL_BPS);
        (uint256 coll, uint256 gross, uint256 fee, uint256 longPayout, uint256 shortPayout) =
            _settle(false, strike, price, feeBps);

        assertEq(coll, UNIT, "call collateral");
        assertEq(longPayout + fee + shortPayout, coll, "long + fee + short == collateralPerUnit");
        assertLt(gross, UNIT, "a call never owes the whole unit");
        if (price > strike) {
            // gross is the floor of UNIT * (P - K) / P: gross * P <= UNIT * (P - K) < (gross + 1) * P.
            assertLe(gross * price, UNIT * (price - strike), "gross not above the exact value");
            assertGt((gross + 1) * price, UNIT * (price - strike), "gross is the floor");
        } else {
            assertEq(gross, 0, "no value at or below the strike");
        }
    }

    function testFuzz_conservation_put(uint256 strike, uint256 price, uint256 feeBps) public pure {
        strike = bound(strike, FUZZ_MIN_PRICE, FUZZ_MAX_PRICE);
        price = bound(price, FUZZ_MIN_PRICE, FUZZ_MAX_PRICE);
        feeBps = bound(feeBps, 0, V2Constants.EXERCISE_FEE_CEIL_BPS);
        (uint256 coll, uint256 gross, uint256 fee, uint256 longPayout, uint256 shortPayout) =
            _settle(true, strike, price, feeBps);

        assertEq(coll, strike / 100, "put collateral");
        assertEq(longPayout + fee + shortPayout, coll, "long + fee + short == collateralPerUnit");
        assertLe(gross, coll, "a put never owes more than it locked");
        if (price < strike) {
            // gross is the floor of (K - P) / 100: gross * 100 <= K - P < (gross + 1) * 100.
            assertLe(gross * 100, strike - price, "gross not above the exact value");
            assertGt((gross + 1) * 100, strike - price, "gross is the floor");
        } else {
            assertEq(gross, 0, "no value at or above the strike");
        }
    }

    function testFuzz_feeZeroAtOrOutOfTheMoney(bool isPut, uint256 a, uint256 b, uint256 feeBps) public pure {
        a = bound(a, FUZZ_MIN_PRICE, FUZZ_MAX_PRICE);
        b = bound(b, FUZZ_MIN_PRICE, FUZZ_MAX_PRICE);
        feeBps = bound(feeBps, 0, V2Constants.EXERCISE_FEE_CEIL_BPS);
        // Call OTM/ATM: P <= K. Put OTM/ATM: P >= K.
        (uint256 lo, uint256 hi) = a < b ? (a, b) : (b, a);
        (uint256 strike, uint256 price) = isPut ? (lo, hi) : (hi, lo);

        (uint256 coll, uint256 gross, uint256 fee, uint256 longPayout, uint256 shortPayout) =
            _settle(isPut, strike, price, feeBps);
        assertEq(gross, 0, "no intrinsic value");
        assertEq(fee, 0, "no fee out of the money");
        assertEq(longPayout, 0, "long gets nothing");
        assertEq(shortPayout, coll, "writer gets the whole collateral back");
    }

    /// @dev fee bps over the whole uint16 range, far past EXERCISE_FEE_CEIL_BPS: the 10 % payout-share cap does not
    ///      rely on the ceiling. The reference is written independently: min(rate leg, gross / 10).
    function testFuzz_feeAtMostTenPercentOfGross(bool isPut, uint256 strike, uint256 price, uint16 feeBps) public pure {
        strike = bound(strike, FUZZ_MIN_PRICE, FUZZ_MAX_PRICE);
        price = bound(price, FUZZ_MIN_PRICE, FUZZ_MAX_PRICE);
        (uint256 coll, uint256 gross, uint256 fee,,) = _settle(isPut, strike, price, feeBps);

        assertLe(fee * 10, gross, "fee <= 10% of gross");
        assertLe(fee, coll * feeBps / 10_000, "fee <= collateral * bps");
        uint256 byRate = coll * feeBps / 10_000;
        uint256 byShare = gross / 10;
        assertEq(fee, gross == 0 ? 0 : (byRate < byShare ? byRate : byShare), "fee == min of the two legs");
    }

    /// @dev Whole uint128 range for strike and price (V2Types.Series.strike / settlementPrice), whole uint16 for bps.
    ///      Every per-unit result must fit the uint128 fields of V2Types.Series, and a uint64 unit count times any of
    ///      them must not overflow (the call-site multiplication the Clearinghouse does for collateral and payouts).
    function testFuzz_noOverflowAtUint128Extremes(bool isPut, uint128 strike, uint128 price, uint16 feeBps)
        public
        pure
    {
        (uint256 coll, uint256 gross, uint256 fee, uint256 longPayout, uint256 shortPayout) =
            _settle(isPut, strike, price, feeBps);
        _assertFitsAndScales(coll, gross, fee, longPayout, shortPayout);
    }

    /// @dev The corners the fuzzer is unlikely to hit exactly.
    function test_noOverflowAtUint128Corners() public pure {
        uint128 max = type(uint128).max;
        uint256[4] memory strikes = [uint256(0), 100, K231, max];
        uint256[5] memory prices = [uint256(0), 1, K231, max - 1, max];
        uint16[3] memory bps = [uint16(0), V2Constants.EXERCISE_FEE_CEIL_BPS, type(uint16).max];
        for (uint256 i; i < strikes.length; ++i) {
            for (uint256 j; j < prices.length; ++j) {
                for (uint256 k; k < bps.length; ++k) {
                    for (uint256 t; t < 2; ++t) {
                        (uint256 coll, uint256 gross, uint256 fee, uint256 longPayout, uint256 shortPayout) =
                            _settle(t == 1, strikes[i], prices[j], bps[k]);
                        _assertFitsAndScales(coll, gross, fee, longPayout, shortPayout);
                    }
                }
            }
        }
        // Put K = max, P = 0: the largest put payout there is, the whole collateral.
        (uint256 l,, uint256 s) = OptionMath.settlementPerUnit(true, max, 0, 0);
        assertEq(l, uint256(max) / 100, "put pays all collateral at P = 0");
        assertEq(s, 0);
        // Call K = 0, P = max: gross is the whole unit, the one case it reaches UNIT.
        (l,, s) = OptionMath.settlementPerUnit(false, 0, max, 0);
        assertEq(l, UNIT, "call with zero strike pays the whole unit");
        assertEq(s, 0);
    }

    function _assertFitsAndScales(uint256 coll, uint256 gross, uint256 fee, uint256 longPayout, uint256 shortPayout)
        internal
        pure
    {
        uint256 units = type(uint64).max;
        assertEq(longPayout + fee + shortPayout, coll, "long + fee + short == collateralPerUnit");
        assertLe(gross, coll, "gross <= collateral");
        assertLe(coll, type(uint128).max, "collateral per unit fits uint128");
        assertLe(longPayout, type(uint128).max, "long fits uint128");
        assertLe(fee, type(uint128).max, "fee fits uint128");
        assertLe(shortPayout, type(uint128).max, "short fits uint128");
        // Checked arithmetic would revert here on overflow; the division proves the product is the true one.
        assertEq(coll * units / units, coll, "units * collateral");
        assertEq((longPayout * units + fee * units + shortPayout * units), coll * units, "conservation x units");
    }

    /*//////////////////////////////////////////////////////////////
                                  TICKS
    //////////////////////////////////////////////////////////////*/

    function test_roundToTick_table() public pure {
        assertEq(OptionMath.roundUpToTick(231_000_001, 1_000_000), 232_000_000, "up past the grid");
        assertEq(OptionMath.roundUpToTick(231_000_000, 1_000_000), 231_000_000, "on the grid stays");
        assertEq(OptionMath.roundUpToTick(0, 100), 0, "zero stays");
        assertEq(OptionMath.roundUpToTick(1, 100), 100);
        assertEq(OptionMath.roundUpToTick(99, 100), 100);
        assertEq(OptionMath.roundUpToTick(101, 100), 200);
        assertEq(OptionMath.roundDownToTick(231_999_999, 1_000_000), 231_000_000, "down to the grid");
        assertEq(OptionMath.roundDownToTick(231_000_000, 1_000_000), 231_000_000, "on the grid stays");
        assertEq(OptionMath.roundDownToTick(99, 100), 0);
        assertEq(OptionMath.roundDownToTick(1_893_061, 100), 1_893_000, "an ask price onto PRICE_TICK");
        assertEq(OptionMath.roundUpToTick(7, 1), 7, "tick 1 is the identity");
        assertEq(OptionMath.roundDownToTick(7, 1), 7, "tick 1 is the identity");
        // ADR-12 card target: roundUp(strike * (1 + 400 bps), strikeTick) = roundUp(240_240_000, 1e6).
        assertEq(OptionMath.roundUpToTick(K231 * 10_400 / 10_000, 1_000_000), 241_000_000, "card target example");
    }

    /// @dev On-grid values within a tick of type(uint256).max round to themselves; the (x + tick - 1) / tick form
    ///      would overflow on them.
    function test_roundToTick_nearUint256Max() public pure {
        uint256 max = type(uint256).max; // ...935
        assertEq(OptionMath.roundDownToTick(max, 100), max - 35, "down never overflows");
        assertEq(OptionMath.roundUpToTick(max - 35, 100), max - 35, "on the grid at the top");
        assertEq(OptionMath.roundUpToTick(max - 50, 100), max - 35, "rounds up to the top grid point");
    }

    function test_roundUpToTick_revertsWhenResultDoesNotFit() public {
        vm.expectRevert(stdError.arithmeticError);
        h.roundUpToTick(type(uint256).max, 100);
    }

    function test_roundToTick_zeroTickPanics() public {
        vm.expectRevert(stdError.divisionError);
        h.roundUpToTick(1, 0);
        vm.expectRevert(stdError.divisionError);
        h.roundDownToTick(1, 0);
    }

    function testFuzz_roundToTick(uint256 x, uint256 tick) public pure {
        tick = bound(tick, 1, type(uint128).max);
        x = bound(x, 0, type(uint256).max - tick);
        uint256 up = OptionMath.roundUpToTick(x, tick);
        uint256 down = OptionMath.roundDownToTick(x, tick);

        assertEq(down % tick, 0, "down on the grid");
        assertLe(down, x, "down <= x");
        assertLt(x - down, tick, "down within a tick");
        assertEq(up % tick, 0, "up on the grid");
        assertGe(up, x, "up >= x");
        assertLt(up - x, tick, "up within a tick");
        if (x % tick == 0) {
            assertEq(up, x, "on-grid up is identity");
            assertEq(down, x, "on-grid down is identity");
        } else {
            assertEq(up, down + tick, "off-grid: adjacent grid points");
        }
        assertEq(OptionMath.roundUpToTick(up, tick), up, "idempotent up");
        assertEq(OptionMath.roundDownToTick(down, tick), down, "idempotent down");
    }

    function test_isPriceTick_table() public pure {
        assertTrue(OptionMath.isPriceTick(0), "0 is on the grid; callers reject it separately");
        assertTrue(OptionMath.isPriceTick(100), "one tick");
        assertTrue(OptionMath.isPriceTick(1_900_000), "1.90");
        assertTrue(OptionMath.isPriceTick(K231), "strikes on a 1.00 grid are price ticks");
        assertFalse(OptionMath.isPriceTick(1), "1 base unit");
        assertFalse(OptionMath.isPriceTick(99), "just below a tick");
        assertFalse(OptionMath.isPriceTick(1_900_050), "half a tick");
    }

    function testFuzz_isPriceTick(uint256 price) public pure {
        assertEq(OptionMath.isPriceTick(price), price % 100 == 0, "grid membership");
        assertTrue(OptionMath.isPriceTick(OptionMath.roundDownToTick(price, V2Constants.PRICE_TICK)), "rounded");
    }
}
