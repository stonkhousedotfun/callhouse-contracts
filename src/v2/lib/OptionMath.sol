// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {V2Constants} from "../interfaces/V2Constants.sol";

/// @title OptionMath
/// @notice Premium and settlement arithmetic of a v2 series (architecture §3.1, ADR-04, ADR-08). Pure and internal:
///         no storage, no calls, no custom errors of its own. The Clearinghouse, the OrderBook and the AutoRoller use
///         these rather than re-deriving the formulas, and the web's payoff maths mirrors them value for value.
/// @dev UNITS, stated once (ADR-04, V2Types):
///        - `price`, `strike`: USDG base units (6 dp) per WHOLE share. $231.00 => 231_000_000.
///        - `units`: 0.01-share units. One unit is UNIT = 1e16 base units of the 18-dp underlying.
///        - `*PerUnit`: base units of the series' collateral asset per unit: the underlying (18 dp) for a call,
///          USDG (6 dp) for a put.
///        - `feeBps`: basis points of BPS = 10_000.
///
///      ROUNDING. Every division floors, and each floor lands where it cannot create value:
///        - the gross payout floors against the long, and the short's remainder `collateral - gross` picks up the
///          dust, so the collateral is always paid out in full and never twice;
///        - the exercise fee floors in the long's favour.
///      The identity long + fee + short == collateralPerUnit is therefore EXACT for every input, not "up to
///      rounding": long and short are differences (gross - fee, collateral - gross), not separate divisions. The
///      subtractions cannot underflow because fee <= gross / 10 (the payout-share cap) and gross <= collateral
///      (call: UNIT * (P - K) / P <= UNIT; put: floor((K - P) / 100) <= floor(K / 100)).
///
///      OVERFLOW. Arguments are uint256 so callers pass uint128 strikes and prices, uint64 units and uint16 bps
///      without casts. Inside those stored types nothing here overflows: the largest intermediate is the call's
///      UNIT * (P - K) < 2^54 * 2^128. Every per-unit result is <= collateralPerUnit <= max(UNIT, strike / 100), so it
///      fits the uint128 fields of V2Types.Series. Outside them checked arithmetic reverts (Panic 0x11); it never
///      wraps.
///
///      UNITS x PER-UNIT. {premium} is the only helper that multiplies by a unit count; its bound is
///      price <= type(uint128).max and units <= type(uint64).max, product < 2^192. Collateral to lock
///      (units * collateralPerUnit) and payouts (balance * perUnit) are one multiplication at the call site with the
///      same bound: a uint64 count times a per-unit value <= type(uint128).max is < 2^192.
library OptionMath {
    /*//////////////////////////////////////////////////////////////
                                 PREMIUM
    //////////////////////////////////////////////////////////////*/

    /// @notice USDG paid for `units` at `price`.
    /// @dev price * units / UNITS_PER_SHARE. Exact for every price on the PRICE_TICK grid: PRICE_TICK (100) is a
    ///      multiple of UNITS_PER_SHARE (100), so a unit costs a whole number of USDG base units. That is why the
    ///      book only accepts tick prices ({isPriceTick}); an off-grid price floors here, against the seller.
    ///      Multiplying before dividing keeps that floor to under 1 base unit per call instead of per unit.
    /// @param price USDG base units (6 dp) per whole share; a multiple of PRICE_TICK.
    /// @param units 0.01-share units.
    /// @return USDG base units.
    function premium(uint256 price, uint256 units) internal pure returns (uint256) {
        return price * units / V2Constants.UNITS_PER_SHARE;
    }

    /*//////////////////////////////////////////////////////////////
                    COLLATERAL RENT (INTERFACE_VERSION 7)
    //////////////////////////////////////////////////////////////*/

    /// @notice The rent {Clearinghouse.mint} charges on `collateral` for `remaining` seconds of life, rounded UP.
    /// @dev ceil(collateral * feePpm * remaining / (PPM * MINT_FEE_PERIOD)), and 0 when any input is 0. The rounding
    ///      is the protocol's, and costs under one base unit per call, so that the fee a writer pays is never below
    ///      the refund {mintFeeRefund} would give the same unit back at the same instant.
    ///      OVERFLOW: collateral < 2^192 (a uint64 unit count times a uint128 per-unit value), feePpm < 2^32 and
    ///      remaining <= MAX_TENOR < 2^22, so the product is < 2^246; above that checked arithmetic reverts (Panic
    ///      0x11) and never wraps.
    /// @param collateral Collateral-asset base units the rent is charged on.
    /// @param feePpm Millionths of `collateral` per MINT_FEE_PERIOD; the series' pinned mintFeePpm.
    /// @param remaining Seconds of life left, `expiry - block.timestamp`.
    /// @return Collateral-asset base units.
    function mintFee(uint256 collateral, uint256 feePpm, uint256 remaining) internal pure returns (uint256) {
        uint256 num = collateral * feePpm * remaining;
        return num == 0 ? 0 : (num - 1) / (V2Constants.PPM * V2Constants.MINT_FEE_PERIOD) + 1;
    }

    /// @notice The same product rounded DOWN: the unused rent {Clearinghouse.close} pays back.
    /// @dev mintFeeRefund(x) <= mintFee(x) for equal inputs, and both are non-decreasing in `remaining`. Those two
    ///      facts are what the refund proof rests on (V2-ACCOUNTING §3.3): a unit minted at s <= t was charged the
    ///      ceiled value at s, which is never below the floored value at t this pays back.
    /// @param collateral Collateral-asset base units the rent was charged on.
    /// @param feePpm Millionths of `collateral` per MINT_FEE_PERIOD; the series' pinned mintFeePpm.
    /// @param remaining Seconds of life left, `expiry - block.timestamp`.
    /// @return Collateral-asset base units.
    function mintFeeRefund(uint256 collateral, uint256 feePpm, uint256 remaining) internal pure returns (uint256) {
        return collateral * feePpm * remaining / (V2Constants.PPM * V2Constants.MINT_FEE_PERIOD);
    }

    /*//////////////////////////////////////////////////////////////
                               SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Collateral locked per unit written.
    /// @dev A put locks the strike of 0.01 share in USDG; a call locks the 0.01 share itself. The put division is
    ///      exact for any strike the Clearinghouse accepts (a multiple of the market strikeTick, itself a multiple of
    ///      100); for any other strike it floors, and {grossPayoutPerUnit} can still never exceed the result.
    /// @param isPut True for a put.
    /// @param strike USDG base units (6 dp) per whole share.
    /// @return Put: USDG base units. Call: underlying base units (always UNIT = 1e16).
    function collateralPerUnit(bool isPut, uint256 strike) internal pure returns (uint256) {
        return isPut ? strike / V2Constants.UNITS_PER_SHARE : V2Constants.UNIT;
    }

    /// @notice Intrinsic value of one unit at settlement price `price`, before the exercise fee.
    /// @dev Call: P > K ? UNIT * (P - K) / P : 0. The call is paid IN KIND from its underlying collateral, so the
    ///      value (P - K) USDG per share is turned into shares at the settlement price: (P - K) / P of a share, per
    ///      unit UNIT * (P - K) / P base units. That is below UNIT for every P once K > 0 (equal only at K = 0,
    ///      which createSeries rejects), so a call can never owe more than it locked, however far the price runs.
    ///      Put: P < K ? (K - P) / 100 : 0, USDG per unit, at most collateralPerUnit (P = 0 pays it all).
    ///      Both floor against the long; the short receives the dust.
    /// @param isPut True for a put.
    /// @param strike USDG base units (6 dp) per whole share.
    /// @param price Settlement price, USDG base units (6 dp) per whole share.
    /// @return Collateral-asset base units per unit; 0 at or out of the money.
    function grossPayoutPerUnit(bool isPut, uint256 strike, uint256 price) internal pure returns (uint256) {
        if (isPut) return price < strike ? (strike - price) / V2Constants.UNITS_PER_SHARE : 0;
        return price > strike ? V2Constants.UNIT * (price - strike) / price : 0;
    }

    /// @notice Exercise fee per unit, taken from the long's payout in kind (ADR-08).
    /// @dev gross == 0 ? 0 : min(collPerUnit * feeBps / BPS, gross * EXERCISE_FEE_MAX_PAYOUT_SHARE_BPS / BPS).
    ///      The rate is quoted on the collateral so the fee per contract is known when the series is created (the
    ///      Clearinghouse pins `feeBps`). The second leg caps it at 10 % of the gross payout, so a long that finishes
    ///      barely in the money never loses most of a small payout to a fee sized for the whole contract. The cap holds
    ///      for ANY feeBps, not only under EXERCISE_FEE_CEIL_BPS, so fee <= gross is unconditional. Out of the money
    ///      nothing is charged: the explicit zero branch is the spec's, and the cap leg would give 0 anyway. A gross
    ///      below 10 base units is also fee-free, because the cap leg floors to 0.
    /// @param gross {grossPayoutPerUnit}, collateral-asset base units.
    /// @param collPerUnit {collateralPerUnit}, collateral-asset base units.
    /// @param feeBps The series' pinned exercise fee, bps (<= EXERCISE_FEE_CEIL_BPS in the Clearinghouse).
    /// @return Collateral-asset base units per unit, <= gross / 10.
    function feePerUnit(uint256 gross, uint256 collPerUnit, uint256 feeBps) internal pure returns (uint256) {
        if (gross == 0) return 0;
        uint256 byRate = collPerUnit * feeBps / V2Constants.BPS;
        uint256 byShare = gross * V2Constants.EXERCISE_FEE_MAX_PAYOUT_SHARE_BPS / V2Constants.BPS;
        return byRate < byShare ? byRate : byShare;
    }

    /// @notice What the long receives per unit: gross - fee.
    /// @dev Reverts (Panic 0x11) only if `fee > gross`, which {feePerUnit} never returns.
    /// @param gross {grossPayoutPerUnit}, collateral-asset base units.
    /// @param fee {feePerUnit} of that gross, collateral-asset base units.
    /// @return Collateral-asset base units per unit.
    function longPayoutPerUnit(uint256 gross, uint256 fee) internal pure returns (uint256) {
        return gross - fee;
    }

    /// @notice What the short receives back per unit: collateralPerUnit - gross.
    /// @dev The fee comes out of the long's share, never the short's: the writer's outcome does not depend on the
    ///      fee rate. Reverts (Panic 0x11) only if `gross > collPerUnit`, which {grossPayoutPerUnit} never returns for
    ///      the same (isPut, strike).
    /// @param collPerUnit {collateralPerUnit}, collateral-asset base units.
    /// @param gross {grossPayoutPerUnit}, collateral-asset base units.
    /// @return Collateral-asset base units per unit.
    function shortPayoutPerUnit(uint256 collPerUnit, uint256 gross) internal pure returns (uint256) {
        return collPerUnit - gross;
    }

    /// @notice The three settlement amounts of one unit, composed from the helpers above in the only valid order.
    /// @dev What Clearinghouse.settle stores and previewSettlement returns (same return order). One composition
    ///      keeps a caller from pairing a gross with the fee or collateral of a different input.
    ///      longPayout + fee + shortPayout == collateralPerUnit(isPut, strike), exactly.
    /// @param isPut True for a put.
    /// @param strike USDG base units (6 dp) per whole share.
    /// @param price Settlement price, USDG base units (6 dp) per whole share.
    /// @param feeBps The series' pinned exercise fee, bps.
    /// @return longPayout Collateral-asset base units per unit to the long, net of fee.
    /// @return fee Collateral-asset base units per unit of exercise fee.
    /// @return shortPayout Collateral-asset base units per unit back to the short.
    function settlementPerUnit(bool isPut, uint256 strike, uint256 price, uint256 feeBps)
        internal
        pure
        returns (uint256 longPayout, uint256 fee, uint256 shortPayout)
    {
        uint256 coll = collateralPerUnit(isPut, strike);
        uint256 gross = grossPayoutPerUnit(isPut, strike, price);
        fee = feePerUnit(gross, coll, feeBps);
        longPayout = longPayoutPerUnit(gross, fee);
        shortPayout = shortPayoutPerUnit(coll, gross);
    }

    /*//////////////////////////////////////////////////////////////
                                  TICKS
    //////////////////////////////////////////////////////////////*/

    /// @notice The smallest multiple of `tick` that is >= `x`.
    /// @dev Written as x + (tick - x % tick) rather than (x + tick - 1) / tick * tick: the latter overflows for any
    ///      x within `tick` of type(uint256).max even when x is already on the grid; this form reverts (Panic 0x11)
    ///      only when the rounded result itself does not fit. `tick` must be non-zero (Panic 0x12 otherwise): the
    ///      ticks used are PRICE_TICK and a registered market's strikeTick, which registration must keep > 0.
    /// @param x Value to round, any unit.
    /// @param tick Grid step, same unit as `x`, > 0.
    /// @return x rounded up to the grid.
    function roundUpToTick(uint256 x, uint256 tick) internal pure returns (uint256) {
        uint256 rem = x % tick;
        return rem == 0 ? x : x + (tick - rem);
    }

    /// @notice The largest multiple of `tick` that is <= `x`.
    /// @dev Never overflows. `tick` must be non-zero (Panic 0x12 otherwise).
    /// @param x Value to round, any unit.
    /// @param tick Grid step, same unit as `x`, > 0.
    /// @return x rounded down to the grid.
    function roundDownToTick(uint256 x, uint256 tick) internal pure returns (uint256) {
        return x - x % tick;
    }

    /// @notice Whether `price` lies on the PRICE_TICK grid, so {premium} is exact for it.
    /// @dev Grid membership only: 0 IS on the grid. Callers that need a usable price reject 0 themselves
    ///      (V2Errors.BadPrice covers both cases).
    /// @param price USDG base units (6 dp) per whole share.
    /// @return True when price % PRICE_TICK == 0.
    function isPriceTick(uint256 price) internal pure returns (bool) {
        return price % V2Constants.PRICE_TICK == 0;
    }
}
