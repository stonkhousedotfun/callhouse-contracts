// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title V2Constants
/// @notice Compiled constants of the Stonkhouse v2 contracts: units, time bounds, fee ceilings, roles and bounty
///         actions. Identical names everywhere; off-chain code mirrors these values.
/// @dev Types are chosen so use sites need no casts:
///        - amounts, unit sizes and math divisors are uint256 (they multiply uint256 collateral and premium);
///        - time offsets are uint40 like `expiry`, so `expiry + FINALIZE_DELAY` stays uint40 and still widens
///          implicitly against block.timestamp; SETTLEMENT_WINDOW is uint32 because ISettlementOracle returns it as
///          uint32, and `expiry - SETTLEMENT_WINDOW` is uint40;
///        - ceilings that bound a V2Types / event field share that field's type (uint16 bps, uint32 takerFeeFlat), so a
///          ceiling can be assigned to the field and compared with it directly.
///
///      Deliberately NOT constants, because they are per-series or per-market state:
///        - the mint cutoff, `expiry - SETTLEMENT_WINDOW` (IClearinghouse.mintCutoff);
///        - the oracle's spotMaxAge (default 1 h, <= 4 d), maxDeviationBps (default 150, <= 1000) and
///          uncorroboratedDelay (default 6 h, 30 min <= x <= 24 h);
///        - fee defaults (premium 500 bps, taker 100_000 flat / 1000 bps cap, rebate 5000 bps, exercise 25 bps) and
///          bounty amounts, which are admin-set under the ceilings below (an OrderBook fee change takes effect
///          FEE_CHANGE_DELAY after it is scheduled).
library V2Constants {
    /*//////////////////////////////////////////////////////////////
                                 UNITS (ADR-04)
    //////////////////////////////////////////////////////////////*/

    /// @dev One unit = 0.01 share = 1e16 base units of an 18-dp underlying. ERC-1155 amounts are units.
    uint256 internal constant UNIT = 1e16;
    /// @dev Units per whole share. premium(price, units) = price * units / UNITS_PER_SHARE.
    uint256 internal constant UNITS_PER_SHARE = 100;
    /// @dev Order prices and strikes (USDG 6 dp per share) are multiples of this, so price / 100 per unit is exact.
    uint256 internal constant PRICE_TICK = 100;
    /// @dev Basis-point denominator.
    uint256 internal constant BPS = 10_000;
    /// @dev Parts-per-million denominator: the denominator of MarketConfig.mintFeePpm and Series.mintFeePpm
    ///      (INTERFACE_VERSION 7). uint256: it only ever divides a uint256 collateral product.
    uint256 internal constant PPM = 1_000_000;

    /*//////////////////////////////////////////////////////////////
                           TIME (seconds, ADR-05/07)
    //////////////////////////////////////////////////////////////*/

    /// @dev Settlement TWAP window before expiry, 30 minutes. uint32: ISettlementOracle.SETTLEMENT_WINDOW() type.
    uint32 internal constant SETTLEMENT_WINDOW = 1800;
    /// @dev SettlementOracle.finalize reverts TooEarly before expiry + FINALIZE_DELAY.
    uint40 internal constant FINALIZE_DELAY = 120;
    /// @dev UniV3TwapSource.record works only in [expiry, expiry + SNAPSHOT_GRACE].
    uint40 internal constant SNAPSHOT_GRACE = 600;
    /// @dev SettlementOracle.adminResolve is allowed from expiry + RESOLVE_DELAY.
    uint40 internal constant RESOLVE_DELAY = 48 hours;
    /// @dev createSeries: expiry <= now + MAX_TENOR.
    uint40 internal constant MAX_TENOR = 45 days;
    /// @dev createSeries: now + MIN_SERIES_LEAD <= expiry.
    uint40 internal constant MIN_SERIES_LEAD = 1 hours;
    /// @dev OrderBook.setFeeParams schedules new fee parameters; they take effect once block.timestamp >= the
    ///      scheduling call's timestamp + FEE_CHANGE_DELAY.
    uint40 internal constant FEE_CHANGE_DELAY = 24 hours;
    /// @dev The period the collateral rent of {Clearinghouse.mint} is quoted per: a series' mintFeePpm is millionths
    ///      of the locked collateral per this much REMAINING life, charged pro rata over the time left to expiry and
    ///      refunded pro rata by {Clearinghouse.close} (INTERFACE_VERSION 7). uint40 like `expiry`, so
    ///      `PPM * MINT_FEE_PERIOD` widens implicitly against a uint256 numerator.
    uint40 internal constant MINT_FEE_PERIOD = 7 days;

    /*//////////////////////////////////////////////////////////////
                           FEE CEILINGS (ADR-08)
    //////////////////////////////////////////////////////////////*/

    /// @dev Ceiling of FeeParams.premiumFeeBps and FeeParams.resaleFeeBps.
    uint16 internal constant PREMIUM_FEE_CEIL_BPS = 1000;
    /// @dev Ceiling of MarketConfig.exerciseFeeBps (and so of every pinned Series.exerciseFeeBps).
    uint16 internal constant EXERCISE_FEE_CEIL_BPS = 200;
    /// @dev The exercise fee is never more than this share of the gross payout: min(coll * bps / BPS, gross * 1000 /
    ///      BPS). uint256: it only ever multiplies the uint256 gross payout.
    uint256 internal constant EXERCISE_FEE_MAX_PAYOUT_SHARE_BPS = 1000;
    /// @dev Ceiling of FeeParams.takerFeeFlat, USDG base units (1 USDG).
    uint32 internal constant TAKER_FEE_FLAT_CEIL = 1_000_000;
    /// @dev Ceiling of FeeParams.takerFeeCapBps.
    uint16 internal constant TAKER_FEE_CAP_CEIL_BPS = 1000;
    /// @dev Ceiling of every KeeperRewards bounty, USDG base units (1 USDG). uint256 like IKeeperRewards.bounty.
    uint256 internal constant MAX_BOUNTY = 1_000_000;
    /// @dev Ceiling of the Clearinghouse's maxPayoutSlippageBps (PayoutAdapterSet.maxSlippageBps is uint16).
    uint16 internal constant MAX_PAYOUT_SLIPPAGE_CEIL_BPS = 300;
    /// @dev Largest route fee (IPayoutAdapter.routeFeeBps) the Clearinghouse adds to maxPayoutSlippageBps when it sets
    ///      a conversion floor: the 1 % Uniswap fee tier. A larger answer is clamped to it (INTERFACE_VERSION 6).
    uint16 internal constant MAX_ROUTE_FEE_BPS = 100;
    /// @dev Highest Uniswap v3 fee tier (hundredths of a bip) UniV3PayoutAdapter.setRoute accepts: MAX_ROUTE_FEE_BPS
    ///      expressed as a tier. A costlier route would miss the conversion floor on every ordinary payout and pay in
    ///      kind, so the adapter refuses it (CeilingExceeded) and the deploy scripts refuse such a registry pool.
    uint24 internal constant MAX_ROUTE_FEE_TIER = 10_000;
    /// @dev Ceiling of MarketConfig.mintFeePpm (and so of every pinned Series.mintFeePpm): 0.5 % of the locked
    ///      collateral per MINT_FEE_PERIOD, about 3.3x the highest launch rate (INTERFACE_VERSION 7). uint32 like the
    ///      field it bounds, so a ceiling check compares the two directly.
    uint32 internal constant MINT_FEE_CEIL_PPM = 5_000;

    /*//////////////////////////////////////////////////////////////
                          PRICE SOURCES (ADR-05)
    //////////////////////////////////////////////////////////////*/

    /// @dev Fewest observations a Uniswap v3 pool's ring must hold before it may be configured as a price source:
    ///      SETTLEMENT_WINDOW + SNAPSHOT_GRACE + 1 = 2401. UniV3TwapSource.record reads back up to
    ///      SETTLEMENT_WINDOW + SNAPSHOT_GRACE seconds and a pool can be given one observation per second, so a
    ///      shallower ring can be flooded past a snapshot's window inside the grace (UniV3TwapSource NatSpec, THE RING
    ///      MUST OUTLAST THE GRACE). Named here, not only inside the source, because the deploy and register
    ///      preflights and VerifyV2 must refuse a registry univ3 source whose pool is shallower BEFORE anything is
    ///      broadcast (owner sign-off c10, DECISIONS-2026-09-17 §7: every launch pool except NVDA and SPCX is below
    ///      this and is registered Chainlink-only). uint256, like the two time constants it is derived from, so the
    ///      uint16 a pool reports widens into the comparison and nothing is cast.
    uint256 internal constant MIN_POOL_OBSERVATION_CARDINALITY = uint256(SETTLEMENT_WINDOW) + SNAPSHOT_GRACE + 1;

    /*//////////////////////////////////////////////////////////////
                               ROLES (ADR-09)
    //////////////////////////////////////////////////////////////*/

    /// @dev OpenZeppelin AccessControl's admin role (0x00): markets, fee params, fee recipient, pointers for NEW
    ///      series, KeeperRewards funding, adminResolve.
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    /// @dev Pauses new risk only (series creation, mints, new orders) and vetoes uncorroborated settlements.
    bytes32 internal constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    /// @dev AutoRoller.reprice for smart-pricing strategies.
    bytes32 internal constant PRICER_ROLE = keccak256("PRICER_ROLE");
    /// @dev MakerVault quoting bot: place/replace/cancel/take within limits, the vault always the recipient. Trades
    ///      can still move value out: round trips with a counterparty can drain the vault's USDG (MakerVault NatSpec).
    bytes32 internal constant QUOTER_ROLE = keccak256("QUOTER_ROLE");

    /*//////////////////////////////////////////////////////////////
                      KEEPER BOUNTY ACTIONS (ADR-06)
    //////////////////////////////////////////////////////////////*/

    /// @dev SettlementOracle.snapshot recorded a source for the first time, with open interest.
    bytes32 internal constant ACTION_SNAPSHOT = keccak256("SNAPSHOT");
    /// @dev SettlementOracle.finalize advanced the expiry's state, with open interest.
    bytes32 internal constant ACTION_FINALIZE = keccak256("FINALIZE");
    /// @dev Clearinghouse.settle settled a series with long supply.
    bytes32 internal constant ACTION_SETTLE = keccak256("SETTLE");
    /// @dev Clearinghouse.redeem paid a holder at least the minimum payout.
    bytes32 internal constant ACTION_REDEEM = keccak256("REDEEM");
    /// @dev AutoRoller.roll placed at least the minimum roll size.
    bytes32 internal constant ACTION_ROLL = keccak256("ROLL");
    /// @dev AutoRoller.cancelStale withdrew a tracked ask the spot had reached, with at least minRollUnits left
    ///      (INTERFACE_VERSION 7). 0x7bf1982cc047ace888325e61ec5f1e6f173a1d0d7f3d38fc1a42c4776bd35d2b.
    bytes32 internal constant ACTION_CANCEL_STALE = keccak256("CANCEL_STALE");
}
