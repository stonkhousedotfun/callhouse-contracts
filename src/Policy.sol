// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Governance-settable policy bounds for one Callhouse vault.
/// @dev All fields are basis points except `maxContractsCap`, which is a whole number of
///      1e18 lots. Every field is bounded by a hard cap in {Policy} that governance cannot
///      exceed — see {Policy.validate}.
struct PolicyParams {
    /// @dev Minimum distance above spot for a strike to be eligible, in bps. Launch: 300 (3%).
    ///      Has a FLOOR, not a ceiling: admin may not set this below MIN_OTM_FLOOR_BPS, which
    ///      is what stops an admin from selling at-the-money calls against depositors.
    uint16 minOtmBps;
    /// @dev Maximum distance above spot, in bps. Launch: 1200 (12%). Ceiling 2500.
    uint16 maxOtmBps;
    /// @dev Minimum acceptable gross list premium as bps of spot notional. Launch: 40 (0.40%/week).
    uint16 minPremiumBps;
    /// @dev Share of idle asset that may be locked into a write, in bps. Launch: 9500 (95%).
    uint16 maxUtilizationBps;
    /// @dev Protocol fee taken from harvested USDG, in bps. Launch: 1000 (10%). Ceiling 2000.
    uint16 protocolFeeBps;
    /// @dev Absolute cap on contracts written per cycle, in whole 1e18 lots. Launch: 50.
    uint64 maxContractsCap;
}

/// @title Policy
/// @notice Pure bounds math for the weekly roll. No storage, no external calls.
/// @dev Everything here is `pure` on purpose. The vault calls into it to decide whether a
///      keeper-proposed (optionId, contracts, listPremium) triple is acceptable. Keeping it
///      pure means the rules are auditable in isolation and testable without a fork.
///
///      UNITS, stated once and relied on everywhere below:
///        - `spotUsdg` is the spot price of ONE lot (1e18 of the asset) expressed in USDG
///          base units, i.e. 6 decimals. $180.00 => 180_000_000.
///        - `strikeUsdg` is Valorem's `exerciseAmount` for ONE lot, also USDG 6 decimals.
///        - `contracts` is a whole number of lots. One lot = 1e18 asset base units.
///        - `premiumUsdg` is gross premium in USDG base units, before Overcall's 5% cut.
library Policy {
    /*//////////////////////////////////////////////////////////////
                              HARD CAPS
        Compiled into the bytecode. Governance cannot move these.
    //////////////////////////////////////////////////////////////*/

    uint16 internal constant BPS = 10_000;

    /// @dev Admin may not set minOtmBps below this. Prevents selling ATM calls.
    ///      TECHSPEC 10 lists "Admin sets minOtmBps = 0 and sells ATM" as a threat; this is the cap.
    uint16 internal constant MIN_OTM_FLOOR_BPS = 100;

    /// @dev Admin may not set maxOtmBps above this. A 25%-OTM weekly call earns nothing.
    uint16 internal constant MAX_OTM_CEIL_BPS = 2_500;

    /// @dev Admin may not set minPremiumBps below this. Stops listing for dust.
    uint16 internal constant MIN_PREMIUM_FLOOR_BPS = 10;

    /// @dev Utilization can never exceed 100% of idle.
    uint16 internal constant MAX_UTILIZATION_CEIL_BPS = BPS;

    /// @dev Protocol fee can never exceed 20% of harvested USDG.
    uint16 internal constant PROTOCOL_FEE_CEIL_BPS = 2_000;

    /// @dev At most three signed listings per cycle (README "Policy (launch)").
    uint8 internal constant MAX_LISTINGS_PER_CYCLE = 3;

    /// @dev Overcall's cut of gross premium, in bps. Their fee is the second Seaport
    ///      consideration item in the same fill; the vault receives the remainder.
    uint16 internal constant OVERCALL_FEE_BPS = 500;

    /// @dev One lot of the underlying. Stock Tokens are 18 decimals and Overcall's lot size
    ///      is exactly 1.0000 Stock Token per contract.
    uint256 internal constant LOT = 1e18;

    /// @dev USDG base units per whole USDG.
    uint256 internal constant USDG_ONE = 1e6;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error MinOtmBelowFloor(uint16 got, uint16 floorBps);
    error MaxOtmAboveCeiling(uint16 got, uint16 ceilBps);
    error OtmBandInverted(uint16 minOtmBps, uint16 maxOtmBps);
    error MinPremiumBelowFloor(uint16 got, uint16 floorBps);
    error UtilizationAboveCeiling(uint16 got, uint16 ceilBps);
    error ProtocolFeeAboveCeiling(uint16 got, uint16 ceilBps);
    error ContractsCapZero();

    error SpotZero();
    error StrikeBelowBand(uint256 strikeUsdg, uint256 minStrikeUsdg);
    error StrikeAboveBand(uint256 strikeUsdg, uint256 maxStrikeUsdg);
    error PremiumBelowMinimum(uint256 premiumUsdg, uint256 minPremiumUsdg);
    error ContractsZero();
    error ContractsAboveCap(uint256 contractsRequested, uint256 cap);
    error ContractsAboveUtilization(uint256 contractsRequested, uint256 maxByUtilization);

    /*//////////////////////////////////////////////////////////////
                          PARAMETER VALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Reverts unless every field of `p` sits inside the hard caps above.
    /// @dev Called on construction and on every admin update. This is the only thing standing
    ///      between a compromised or careless admin Safe and a policy that sells ATM calls or
    ///      takes a 100% fee.
    function validate(PolicyParams memory p) internal pure {
        if (p.minOtmBps < MIN_OTM_FLOOR_BPS) revert MinOtmBelowFloor(p.minOtmBps, MIN_OTM_FLOOR_BPS);
        if (p.maxOtmBps > MAX_OTM_CEIL_BPS) revert MaxOtmAboveCeiling(p.maxOtmBps, MAX_OTM_CEIL_BPS);
        if (p.minOtmBps > p.maxOtmBps) revert OtmBandInverted(p.minOtmBps, p.maxOtmBps);
        if (p.minPremiumBps < MIN_PREMIUM_FLOOR_BPS) {
            revert MinPremiumBelowFloor(p.minPremiumBps, MIN_PREMIUM_FLOOR_BPS);
        }
        if (p.maxUtilizationBps > MAX_UTILIZATION_CEIL_BPS) {
            revert UtilizationAboveCeiling(p.maxUtilizationBps, MAX_UTILIZATION_CEIL_BPS);
        }
        if (p.protocolFeeBps > PROTOCOL_FEE_CEIL_BPS) {
            revert ProtocolFeeAboveCeiling(p.protocolFeeBps, PROTOCOL_FEE_CEIL_BPS);
        }
        if (p.maxContractsCap == 0) revert ContractsCapZero();
    }

    /// @notice The launch policy from README "Policy (launch)".
    function launchDefaults() internal pure returns (PolicyParams memory p) {
        p = PolicyParams({
            minOtmBps: 300,
            maxOtmBps: 1_200,
            minPremiumBps: 40,
            maxUtilizationBps: 9_500,
            protocolFeeBps: 1_000,
            maxContractsCap: 50
        });
    }

    /*//////////////////////////////////////////////////////////////
                             STRIKE BAND
    //////////////////////////////////////////////////////////////*/

    /// @notice The inclusive [min, max] strike window for a given spot, in USDG base units.
    /// @param spotUsdg Spot price of one lot, USDG 6 decimals.
    function strikeBand(uint256 spotUsdg, PolicyParams memory p)
        internal
        pure
        returns (uint256 minStrikeUsdg, uint256 maxStrikeUsdg)
    {
        if (spotUsdg == 0) revert SpotZero();
        minStrikeUsdg = (spotUsdg * (uint256(BPS) + p.minOtmBps)) / BPS;
        maxStrikeUsdg = (spotUsdg * (uint256(BPS) + p.maxOtmBps)) / BPS;
    }

    /// @notice Reverts unless `strikeUsdg` sits inside the OTM band for `spotUsdg`.
    function checkStrike(uint256 strikeUsdg, uint256 spotUsdg, PolicyParams memory p) internal pure {
        (uint256 lo, uint256 hi) = strikeBand(spotUsdg, p);
        if (strikeUsdg < lo) revert StrikeBelowBand(strikeUsdg, lo);
        if (strikeUsdg > hi) revert StrikeAboveBand(strikeUsdg, hi);
    }

    /*//////////////////////////////////////////////////////////////
                               PREMIUM
    //////////////////////////////////////////////////////////////*/

    /// @notice Minimum acceptable GROSS premium for `contracts` lots at `spotUsdg`.
    /// @dev Gross, i.e. before Overcall's 5% cut. Spot notional is spot x contracts because
    ///      one contract covers exactly one lot.
    function minPremium(uint256 spotUsdg, uint256 contractsCount, PolicyParams memory p)
        internal
        pure
        returns (uint256 minPremiumUsdg)
    {
        if (spotUsdg == 0) revert SpotZero();
        minPremiumUsdg = (spotUsdg * contractsCount * p.minPremiumBps) / BPS;
    }

    /// @notice Reverts unless `premiumUsdg` clears the minimum for this size and spot.
    function checkPremium(uint256 premiumUsdg, uint256 spotUsdg, uint256 contractsCount, PolicyParams memory p)
        internal
        pure
    {
        uint256 floorUsdg = minPremium(spotUsdg, contractsCount, p);
        if (premiumUsdg < floorUsdg) revert PremiumBelowMinimum(premiumUsdg, floorUsdg);
    }

    /// @notice Splits a listing premium into the vault's consideration item and Overcall's 5%.
    /// @param unitPriceUsdg Premium asked for ONE contract, in USDG base units.
    /// @param contractsCount Number of contracts offered.
    /// @return toVault Amount for consideration[0], paid to the vault.
    /// @return toOvercall Amount for consideration[1], paid to Overcall's fee recipient.
    /// @return grossUsdg unitPrice * contracts, i.e. what a full fill costs the buyer.
    ///
    /// @dev THE ROUNDING HERE IS NOT A STYLE CHOICE. Overcall's order builder computes the
    ///      fee PER CONTRACT and then multiplies, not on the total:
    ///
    ///          feePerContract    = unitPrice * 500 / 10_000     (integer division)
    ///          writerPerContract = unitPrice - feePerContract
    ///          consideration[1]  = feePerContract    * N
    ///          consideration[0]  = writerPerContract * N
    ///
    ///      Rounding on the total instead produces amounts that still sign and still pass
    ///      `validate`, but Seaport then rejects a partial fill with `InexactFraction`
    ///      because the consideration is no longer divisible by the order size. Since every
    ///      Overcall listing is PARTIAL_OPEN, that would quietly make the listing fillable
    ///      only in full, and an order the buyer's UI cannot fill is an unfilled week.
    ///      Confirmed against Overcall's live client bundle; see ops/recon/R3-overcall-api.md.
    function splitPremium(uint256 unitPriceUsdg, uint256 contractsCount)
        internal
        pure
        returns (uint256 toVault, uint256 toOvercall, uint256 grossUsdg)
    {
        uint256 feePerContract = (unitPriceUsdg * OVERCALL_FEE_BPS) / BPS;
        uint256 writerPerContract = unitPriceUsdg - feePerContract;
        toOvercall = feePerContract * contractsCount;
        toVault = writerPerContract * contractsCount;
        grossUsdg = unitPriceUsdg * contractsCount;
    }

    /// @notice The smallest per-contract premium whose 5% fee does not round away to nothing.
    /// @dev Overcall's schema rejects a zero-amount second consideration item, so a unit price
    ///      below this is unlistable however well it clears the policy floor.
    function minListableUnitPrice() internal pure returns (uint256) {
        return BPS / OVERCALL_FEE_BPS;
    }

    /*//////////////////////////////////////////////////////////////
                             POSITION SIZE
    //////////////////////////////////////////////////////////////*/

    /// @notice The largest number of whole lots that may be written against `idleAssets`.
    /// @param idleAssets Raw asset base units sitting idle in the vault (18 decimals).
    function maxContracts(uint256 idleAssets, PolicyParams memory p) internal pure returns (uint256) {
        uint256 byUtilization = (idleAssets * p.maxUtilizationBps) / BPS / LOT;
        uint256 cap = p.maxContractsCap;
        return byUtilization < cap ? byUtilization : cap;
    }

    /// @notice Reverts unless `contractsCount` is a legal write size right now.
    function checkContracts(uint256 contractsCount, uint256 idleAssets, PolicyParams memory p) internal pure {
        if (contractsCount == 0) revert ContractsZero();
        if (contractsCount > p.maxContractsCap) revert ContractsAboveCap(contractsCount, p.maxContractsCap);
        uint256 byUtilization = (idleAssets * p.maxUtilizationBps) / BPS / LOT;
        if (contractsCount > byUtilization) revert ContractsAboveUtilization(contractsCount, byUtilization);
    }

    /*//////////////////////////////////////////////////////////////
                                FEES
    //////////////////////////////////////////////////////////////*/

    /// @notice Splits harvested USDG into the protocol fee and the depositors' net.
    /// @dev Fee is charged only on a positive harvest. An unfilled week harvests 0 and is
    ///      therefore free, which is the behaviour README promises: "10% of USDG harvested
    ///      (filled weeks only)".
    function splitHarvest(uint256 grossUsdg, PolicyParams memory p)
        internal
        pure
        returns (uint256 feeUsdg, uint256 netUsdg)
    {
        if (grossUsdg == 0) return (0, 0);
        feeUsdg = (grossUsdg * p.protocolFeeBps) / BPS;
        netUsdg = grossUsdg - feeUsdg;
    }

    /*//////////////////////////////////////////////////////////////
                           PRICE NORMALISATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Converts a raw oracle answer into USDG base units per lot.
    /// @param answer Raw oracle answer. Must be positive.
    /// @param feedDecimals The oracle's `decimals()`.
    /// @dev Chainlink-style feeds quote USD with 8 decimals; USDG has 6. This rescales either
    ///      direction so the rest of the library can assume one unit convention.
    function normalizeSpot(int256 answer, uint8 feedDecimals) internal pure returns (uint256 spotUsdg) {
        if (answer <= 0) revert SpotZero();
        // casting to 'uint256' is safe because the line above reverts on answer <= 0
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 a = uint256(answer);
        if (feedDecimals >= 6) {
            spotUsdg = a / (10 ** (uint256(feedDecimals) - 6));
        } else {
            spotUsdg = a * (10 ** (6 - uint256(feedDecimals)));
        }
        if (spotUsdg == 0) revert SpotZero();
    }
}
