// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Policy, PolicyParams} from "../../src/Policy.sol";

/// @dev Thin wrapper so the internal library functions are externally callable and their
///      reverts are catchable by vm.expectRevert.
contract PolicyHarness {
    function validate(PolicyParams memory p) external pure {
        Policy.validate(p);
    }

    function launchDefaults() external pure returns (PolicyParams memory) {
        return Policy.launchDefaults();
    }

    function strikeBand(uint256 spot, PolicyParams memory p) external pure returns (uint256, uint256) {
        return Policy.strikeBand(spot, p);
    }

    function checkStrike(uint256 strike, uint256 spot, PolicyParams memory p) external pure {
        Policy.checkStrike(strike, spot, p);
    }

    function minPremium(uint256 spot, uint256 n, PolicyParams memory p) external pure returns (uint256) {
        return Policy.minPremium(spot, n, p);
    }

    function checkPremium(uint256 prem, uint256 spot, uint256 n, PolicyParams memory p) external pure {
        Policy.checkPremium(prem, spot, n, p);
    }

    function splitPremium(uint256 unitPrice, uint256 n) external pure returns (uint256, uint256, uint256) {
        return Policy.splitPremium(unitPrice, n);
    }

    function minListableUnitPrice() external pure returns (uint256) {
        return Policy.minListableUnitPrice();
    }

    function maxContracts(uint256 idle, PolicyParams memory p) external pure returns (uint256) {
        return Policy.maxContracts(idle, p);
    }

    function checkContracts(uint256 n, uint256 idle, PolicyParams memory p) external pure {
        Policy.checkContracts(n, idle, p);
    }

    function splitHarvest(uint256 gross, PolicyParams memory p) external pure returns (uint256, uint256) {
        return Policy.splitHarvest(gross, p);
    }

    function normalizeSpot(int256 a, uint8 d) external pure returns (uint256) {
        return Policy.normalizeSpot(a, d);
    }
}

contract PolicyTest is Test {
    PolicyHarness internal h;

    /// @dev $180.00 per lot, in USDG base units (6 dp).
    uint256 internal constant SPOT = 180_000_000;

    function setUp() public {
        h = new PolicyHarness();
    }

    function _p() internal view returns (PolicyParams memory) {
        return h.launchDefaults();
    }

    /*//////////////////////////////////////////////////////////////
                          LAUNCH DEFAULTS
    //////////////////////////////////////////////////////////////*/

    function test_launchDefaults_matchReadme() public view {
        PolicyParams memory p = _p();
        assertEq(p.minOtmBps, 300, "min OTM 3%");
        assertEq(p.maxOtmBps, 1_200, "max OTM 12%");
        assertEq(p.minPremiumBps, 40, "min premium 0.40%/wk");
        assertEq(p.maxUtilizationBps, 9_500, "95% utilization");
        assertEq(p.protocolFeeBps, 500, "5% protocol fee on premium");
        assertEq(p.maxContractsCap, 50, "50 contract cap");
    }

    function test_launchDefaults_validate() public view {
        h.validate(_p());
    }

    /*//////////////////////////////////////////////////////////////
                    HARD CAPS  (fork-test 14 equivalent)
    //////////////////////////////////////////////////////////////*/

    function test_validate_revertsWhenMinOtmBelowFloor() public {
        PolicyParams memory p = _p();
        p.minOtmBps = 99;
        vm.expectRevert(abi.encodeWithSelector(Policy.MinOtmBelowFloor.selector, uint16(99), uint16(100)));
        h.validate(p);
    }

    /// @dev The headline admin threat from TECHSPEC 10: set minOtm to 0 and sell ATM.
    function test_validate_adminCannotSellAtTheMoney() public {
        PolicyParams memory p = _p();
        p.minOtmBps = 0;
        vm.expectRevert(abi.encodeWithSelector(Policy.MinOtmBelowFloor.selector, uint16(0), uint16(100)));
        h.validate(p);
    }

    function test_validate_minOtmAtFloorIsAllowed() public view {
        PolicyParams memory p = _p();
        p.minOtmBps = 100;
        h.validate(p);
    }

    function test_validate_revertsWhenMaxOtmAboveCeiling() public {
        PolicyParams memory p = _p();
        p.maxOtmBps = 2_501;
        vm.expectRevert(abi.encodeWithSelector(Policy.MaxOtmAboveCeiling.selector, uint16(2_501), uint16(2_500)));
        h.validate(p);
    }

    function test_validate_revertsWhenBandInverted() public {
        PolicyParams memory p = _p();
        p.minOtmBps = 900;
        p.maxOtmBps = 800;
        vm.expectRevert(abi.encodeWithSelector(Policy.OtmBandInverted.selector, uint16(900), uint16(800)));
        h.validate(p);
    }

    function test_validate_revertsWhenMinPremiumBelowFloor() public {
        PolicyParams memory p = _p();
        p.minPremiumBps = 9;
        vm.expectRevert(abi.encodeWithSelector(Policy.MinPremiumBelowFloor.selector, uint16(9), uint16(10)));
        h.validate(p);
    }

    function test_validate_revertsWhenUtilizationAboveCeiling() public {
        PolicyParams memory p = _p();
        p.maxUtilizationBps = 10_001;
        vm.expectRevert(abi.encodeWithSelector(Policy.UtilizationAboveCeiling.selector, uint16(10_001), uint16(10_000)));
        h.validate(p);
    }

    function test_validate_revertsWhenFeeAboveCeiling() public {
        PolicyParams memory p = _p();
        p.protocolFeeBps = 2_001;
        vm.expectRevert(abi.encodeWithSelector(Policy.ProtocolFeeAboveCeiling.selector, uint16(2_001), uint16(2_000)));
        h.validate(p);
    }

    function test_validate_revertsWhenCapZero() public {
        PolicyParams memory p = _p();
        p.maxContractsCap = 0;
        vm.expectRevert(Policy.ContractsCapZero.selector);
        h.validate(p);
    }

    /*//////////////////////////////////////////////////////////////
                             STRIKE BAND
    //////////////////////////////////////////////////////////////*/

    function test_strikeBand_launchNumbers() public view {
        (uint256 lo, uint256 hi) = h.strikeBand(SPOT, _p());
        assertEq(lo, 185_400_000, "3% OTM on $180 = $185.40");
        assertEq(hi, 201_600_000, "12% OTM on $180 = $201.60");
    }

    function test_checkStrike_acceptsInsideBand() public view {
        h.checkStrike(190_000_000, SPOT, _p());
    }

    function test_checkStrike_acceptsExactlyAtBothEdges() public view {
        h.checkStrike(185_400_000, SPOT, _p());
        h.checkStrike(201_600_000, SPOT, _p());
    }

    function test_checkStrike_rejectsAtTheMoney() public {
        PolicyParams memory p = _p();
        vm.expectRevert(abi.encodeWithSelector(Policy.StrikeBelowBand.selector, SPOT, uint256(185_400_000)));
        h.checkStrike(SPOT, SPOT, p);
    }

    function test_checkStrike_rejectsTooFarOut() public {
        PolicyParams memory p = _p();
        vm.expectRevert(
            abi.encodeWithSelector(Policy.StrikeAboveBand.selector, uint256(250_000_000), uint256(201_600_000))
        );
        h.checkStrike(250_000_000, SPOT, p);
    }

    function test_strikeBand_revertsOnZeroSpot() public {
        PolicyParams memory p = _p();
        vm.expectRevert(Policy.SpotZero.selector);
        h.strikeBand(0, p);
    }

    /*//////////////////////////////////////////////////////////////
                               PREMIUM
    //////////////////////////////////////////////////////////////*/

    function test_minPremium_launchNumbers() public view {
        // 0.40% of $180 = $0.72 per contract; 10 contracts = $7.20.
        assertEq(h.minPremium(SPOT, 10, _p()), 7_200_000);
    }

    function test_checkPremium_acceptsAtFloor() public view {
        h.checkPremium(7_200_000, SPOT, 10, _p());
    }

    function test_checkPremium_rejectsBelowFloor() public {
        PolicyParams memory p = _p();
        vm.expectRevert(
            abi.encodeWithSelector(Policy.PremiumBelowMinimum.selector, uint256(7_199_999), uint256(7_200_000))
        );
        h.checkPremium(7_199_999, SPOT, 10, p);
    }

    /// @dev An unfilled week is 0 premium, but a LISTING at 0 must never be signable.
    function test_checkPremium_rejectsZeroListing() public {
        PolicyParams memory p = _p();
        vm.expectRevert(abi.encodeWithSelector(Policy.PremiumBelowMinimum.selector, uint256(0), uint256(7_200_000)));
        h.checkPremium(0, SPOT, 10, p);
    }

    /*//////////////////////////////////////////////////////////////
                          OVERCALL 5% SPLIT
    //////////////////////////////////////////////////////////////*/

    function test_splitPremium_95_5() public view {
        // $10.00 per contract, 10 contracts.
        (uint256 toVault, uint256 toOvercall, uint256 gross) = h.splitPremium(10_000_000, 10);
        assertEq(gross, 100_000_000, "gross is unit * n");
        assertEq(toOvercall, 5_000_000, "Overcall takes 5%");
        assertEq(toVault, 95_000_000, "vault keeps 95%");
    }

    /// @dev The exact rounding Overcall's client uses. A unit price whose 5% does not divide
    ///      evenly must still produce per-contract-rounded amounts, or Seaport rejects the
    ///      partial fill with InexactFraction. See ops/recon/R3-overcall-api.md (leekzor/callhouse).
    function test_splitPremium_roundsPerContractNotOnTotal() public view {
        // unit price 1_000_019: 5% is 50_000.95, which floors to 50_000 PER CONTRACT.
        (uint256 toVault, uint256 toOvercall, uint256 gross) = h.splitPremium(1_000_019, 3);
        assertEq(toOvercall, 50_000 * 3, "fee floors per contract, then multiplies");
        assertEq(toVault, (1_000_019 - 50_000) * 3, "writer gets the per-contract remainder");
        assertEq(gross, 1_000_019 * 3);

        // Rounding on the TOTAL would have given a different, unfillable number.
        // Rounding on the total gives 150_002 here, two base units more than the
        // per-contract split. That order signs fine and then cannot be partially filled.
        uint256 totalRounded = (gross * 500) / 10_000;
        assertEq(totalRounded, 150_002, "total-rounding overshoots");
        assertEq(toOvercall, 150_000, "per-contract rounding is what Overcall expects");
        assertTrue(totalRounded != toOvercall, "the two roundings really do differ here");
        assertTrue((gross - totalRounded) % 3 != 0, "and the total-rounded writer amount is not divisible by N");
    }

    /// @dev Every consideration amount must be an exact multiple of the order size, which is
    ///      what makes a PARTIAL_OPEN order fillable in fractions.
    function testFuzz_splitPremium_amountsDivideByOrderSize(uint256 unitPrice, uint256 n) public view {
        unitPrice = bound(unitPrice, 20, 1e12);
        n = bound(n, 1, 1_000);
        (uint256 toVault, uint256 toOvercall,) = h.splitPremium(unitPrice, n);
        assertEq(toVault % n, 0, "consideration[0] must divide by N");
        assertEq(toOvercall % n, 0, "consideration[1] must divide by N");
    }

    function testFuzz_splitPremium_alwaysSumsToGross(uint256 unitPrice, uint256 n) public view {
        unitPrice = bound(unitPrice, 0, type(uint64).max);
        n = bound(n, 0, 10_000);
        (uint256 toVault, uint256 toOvercall, uint256 gross) = h.splitPremium(unitPrice, n);
        assertEq(toVault + toOvercall, gross, "split must be lossless");
    }

    function testFuzz_splitPremium_roundingFavoursVault(uint256 unitPrice, uint256 n) public view {
        unitPrice = bound(unitPrice, 0, type(uint64).max);
        n = bound(n, 0, 10_000);
        (uint256 toVault, uint256 toOvercall, uint256 gross) = h.splitPremium(unitPrice, n);
        assertGe(toVault * 500, toOvercall * 9_500, "vault never short-changed by rounding");
        assertLe(toOvercall * 10_000, gross * 500, "Overcall never takes more than 5%");
    }

    /// @dev Below this unit price the 5% fee floors to zero and Overcall's schema rejects the
    ///      order outright, so a policy that permits it would produce unlistable weeks.
    function test_minListableUnitPrice() public view {
        assertEq(h.minListableUnitPrice(), 20, "5% of 20 base units is the smallest non-zero fee");
        (, uint256 feeAtFloor,) = h.splitPremium(20, 1);
        assertEq(feeAtFloor, 1, "fee is exactly 1 base unit at the floor");
        (, uint256 feeBelow,) = h.splitPremium(19, 1);
        assertEq(feeBelow, 0, "one below the floor the fee rounds away entirely");
    }

    /*//////////////////////////////////////////////////////////////
                            POSITION SIZE
    //////////////////////////////////////////////////////////////*/

    function test_maxContracts_utilizationBinds() public view {
        // 20 NVDA idle at 95% = 19 whole lots.
        assertEq(h.maxContracts(20e18, _p()), 19);
    }

    function test_maxContracts_capBinds() public view {
        // 1000 NVDA idle at 95% = 950 lots, but the cap is 50.
        assertEq(h.maxContracts(1_000e18, _p()), 50);
    }

    function test_maxContracts_floorsToWholeLots() public view {
        // 1.5 NVDA at 95% = 1.425 lots -> 1 whole lot.
        assertEq(h.maxContracts(1.5e18, _p()), 1);
    }

    function test_maxContracts_dustIsZero() public view {
        assertEq(h.maxContracts(0.5e18, _p()), 0);
    }

    function test_checkContracts_acceptsAtUtilizationEdge() public view {
        h.checkContracts(19, 20e18, _p());
    }

    function test_checkContracts_rejectsOneOverUtilization() public {
        PolicyParams memory p = _p();
        vm.expectRevert(abi.encodeWithSelector(Policy.ContractsAboveUtilization.selector, uint256(20), uint256(19)));
        h.checkContracts(20, 20e18, p);
    }

    function test_checkContracts_rejectsZero() public {
        PolicyParams memory p = _p();
        vm.expectRevert(Policy.ContractsZero.selector);
        h.checkContracts(0, 20e18, p);
    }

    function test_checkContracts_rejectsAboveCap() public {
        PolicyParams memory p = _p();
        vm.expectRevert(abi.encodeWithSelector(Policy.ContractsAboveCap.selector, uint256(51), uint256(50)));
        h.checkContracts(51, 1_000e18, p);
    }

    /*//////////////////////////////////////////////////////////////
                                FEES
    //////////////////////////////////////////////////////////////*/

    /// @dev splitHarvest is handed premium only (the vault strips strike proceeds first), so
    ///      at launch this is "5% of premium": 100_000_000 * 500 / 10_000 = 5_000_000.
    function test_splitHarvest_fivePercent() public view {
        (uint256 fee, uint256 net) = h.splitHarvest(100_000_000, _p());
        assertEq(fee, 5_000_000);
        assertEq(net, 95_000_000);
    }

    /// @dev The fee is 5% of premium (filled weeks only). An unfilled week is free.
    function test_splitHarvest_unfilledWeekIsFree() public view {
        (uint256 fee, uint256 net) = h.splitHarvest(0, _p());
        assertEq(fee, 0, "no fee on an unfilled week");
        assertEq(net, 0);
    }

    function testFuzz_splitHarvest_lossless(uint256 gross) public view {
        gross = bound(gross, 0, type(uint128).max);
        (uint256 fee, uint256 net) = h.splitHarvest(gross, _p());
        assertEq(fee + net, gross);
    }

    function testFuzz_splitHarvest_feeNeverExceedsCeiling(uint256 gross, uint16 feeBps) public view {
        gross = bound(gross, 0, type(uint128).max);
        PolicyParams memory p = _p();
        p.protocolFeeBps = uint16(bound(feeBps, 0, 2_000));
        (uint256 fee,) = h.splitHarvest(gross, p);
        assertLe(fee * 10_000, gross * 2_000, "fee can never exceed the 20% hard ceiling");
    }

    /*//////////////////////////////////////////////////////////////
                         PRICE NORMALISATION
    //////////////////////////////////////////////////////////////*/

    function test_normalizeSpot_from8Decimals() public view {
        // Chainlink-style: $180.00 at 8 dp.
        assertEq(h.normalizeSpot(180_00000000, 8), 180_000_000);
    }

    function test_normalizeSpot_from6Decimals() public view {
        assertEq(h.normalizeSpot(180_000_000, 6), 180_000_000);
    }

    function test_normalizeSpot_from18Decimals() public view {
        assertEq(h.normalizeSpot(180e18, 18), 180_000_000);
    }

    function test_normalizeSpot_from2Decimals() public view {
        assertEq(h.normalizeSpot(18_000, 2), 180_000_000);
    }

    function test_normalizeSpot_revertsOnZero() public {
        vm.expectRevert(Policy.SpotZero.selector);
        h.normalizeSpot(0, 8);
    }

    function test_normalizeSpot_revertsOnNegative() public {
        vm.expectRevert(Policy.SpotZero.selector);
        h.normalizeSpot(-1, 8);
    }

    /// @dev A feed answer so small it rounds to zero USDG must revert, not silently pass 0
    ///      into the band math where it would make every strike look infinitely OTM.
    function test_normalizeSpot_revertsWhenRoundsToZero() public {
        vm.expectRevert(Policy.SpotZero.selector);
        h.normalizeSpot(99, 8);
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_strikeBand_alwaysStrictlyAboveSpot(uint256 spot, uint16 minOtm, uint16 maxOtm) public view {
        spot = bound(spot, 1_000_000, 1e15);
        PolicyParams memory p = _p();
        p.minOtmBps = uint16(bound(minOtm, 100, 2_500));
        p.maxOtmBps = uint16(bound(maxOtm, p.minOtmBps, 2_500));
        (uint256 lo, uint256 hi) = h.strikeBand(spot, p);
        assertGt(lo, spot, "the floor of the band is always above spot, so we never sell ATM");
        assertGe(hi, lo, "band is never inverted");
    }

    function testFuzz_maxContracts_neverExceedsIdle(uint256 idle) public view {
        idle = bound(idle, 0, 1e30);
        uint256 n = h.maxContracts(idle, _p());
        assertLe(n * 1e18, idle, "never lock more than we hold");
    }
}
