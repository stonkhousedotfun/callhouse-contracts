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
    /// @dev Protocol fee on harvested PREMIUM, in bps. Launch: 500 (5%). Ceiling 2000.
    ///      Strike proceeds from assignment are principal and never fee'd (Vault._accrueHarvest).
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
///        - `premiumUsdg` is the premium a buyer pays in USDG base units. Every listing has ONE
///          consideration item (USDG to the vault), so gross and net premium are the same figure.
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

    /// @dev Utilization can never exceed 99.85% of the sizing base (AUDIT-FINDINGS F-04, decision D7).
    ///
    ///      WHY NOT 100%. Valorem's engine fee, when switched on, is 15 bps of NOTIONAL charged ON
    ///      TOP of the collateral, and the write gate sizes contracts against `totalAssets()`, which
    ///      already nets out `reservedAssets`. At 100% utilisation with the fee on, a maximum-size
    ///      write pulled collateral + 15 bps from the raw balance, reserved tokens included, and a
    ///      settled redeemer could no longer be paid (ACCOUNTING §7 invariant 6 broken). Capping
    ///      utilisation at 9,985 bps leaves the fee's 15 bps inside the free balance: n lots pass
    ///      only if n × 1e18 <= 0.9985 × free, and Valorem pulls at most n × 1e18 × 1.0015 =
    ///      0.99999775 × free < free. The write-on-fill path adds a post-write
    ///      `balance >= reservedAssets` check as the second line of defence, so a fee rate above
    ///      15 bps cannot slip through either.
    uint16 internal constant MAX_UTILIZATION_CEIL_BPS = 9_985;

    /// @dev Protocol fee can never exceed 20% of harvested premium.
    uint16 internal constant PROTOCOL_FEE_CEIL_BPS = 2_000;

    /// @dev At most three authorised listings per cycle (README "Policy (launch)"). Every
    ///      `approveListing` spends one, cancelled or not: under write-on-fill a listing is a
    ///      standing offer sized to capacity, so a relist is a REPRICE, and three reprices a week
    ///      is the ceiling on how far a keeper can walk the quote before the guardian must act.
    uint8 internal constant MAX_LISTINGS_PER_CYCLE = 3;

    /// @dev One lot of the underlying. Stock Tokens are 18 decimals and every option type the
    ///      vault will arm has `underlyingAmount == LOT`: exactly 1.0000 Stock Token per contract.
    uint256 internal constant LOT = 1e18;

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
            protocolFeeBps: 500,
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

    /// @notice Minimum acceptable premium for `contracts` lots at `spotUsdg`.
    /// @dev Spot notional is spot x contracts because one contract covers exactly one lot. The
    ///      Valorem engine fee, when switched on, is added ON TOP of this by the fill gate
    ///      ({ValoremLib.writeOnFill}), valued at spot.
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

    /// @notice Splits a fee-bearing USDG amount into the protocol fee and the depositors' net.
    /// @dev Fee is charged only on a positive amount. An unfilled week harvests 0 and is
    ///      therefore free. The vault passes premium only: strike proceeds are excluded
    ///      before this is called, so the fee is "5% of premium" and never a cut of principal.
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
