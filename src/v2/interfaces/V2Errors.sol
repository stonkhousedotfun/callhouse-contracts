// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title V2Errors
/// @notice The shared custom errors of every Stonkhouse v2 contract. Custom errors only, no revert strings.
/// @dev A library purely as a namespace: concrete contracts revert with `V2Errors.BadStrike()` and solc puts every
///      error declared here into out/V2Errors.sol/V2Errors.json, which export-abis.sh publishes as
///      ops/abis/v2/V2Errors.json. The frozen interfaces declare no errors of their own, so off-chain decoders merge
///      this ABI's error fragments into each contract ABI (a concrete contract's artifact lists only the errors its
///      own bytecode can raise). Adding an error later changes the exported interface and requires an ABI update.
library V2Errors {
    /// @notice Caller lacks the role, is not the account or its operator, or is not an allowed delegate.
    error NotAuthorized();
    /// @notice The underlying has no enabled market.
    error MarketDisabled();
    /// @notice The guardian paused mints for this market.
    error MintPaused();
    /// @notice The guardian paused series creation.
    error CreatePaused();
    /// @notice The guardian paused placing orders and taking.
    error TradingPaused();
    /// @notice Strike is 0, not a multiple of the market strikeTick, or outside [spot / 2, spot * 2].
    error BadStrike();
    /// @notice Expiry is not a calendar expiry or is outside [now + MIN_SERIES_LEAD, now + MAX_TENOR].
    error BadExpiry();
    /// @notice Price is 0, not a multiple of PRICE_TICK, or outside an allowed band.
    error BadPrice();
    /// @notice Units are 0 or otherwise unusable for the call.
    error BadUnits();
    /// @notice No series exists for the id.
    error UnknownSeries();
    /// @notice The series' mint cutoff (expiry - SETTLEMENT_WINDOW) or trading end has passed.
    error PastCutoff();
    /// @notice The series has not expired yet.
    error NotExpired();
    /// @notice The series is not settled yet.
    error NotSettled();
    /// @notice The series is already settled.
    error AlreadySettled();
    /// @notice Free collateral `have` (asset base units) is below the `need` of the call.
    error InsufficientCollateral(uint256 have, uint256 need);
    /// @notice The asset is neither USDG nor a registered underlying (or is not 18-dp where required).
    error UnsupportedAsset();
    /// @notice A take filled `filled` units (0.01-share), below the taker's `min`.
    error BelowMinUnits(uint64 filled, uint64 min);
    /// @notice The take deadline has passed.
    error DeadlinePassed();
    /// @notice Order `id` is unknown, cancelled, filled or expired.
    error OrderNotLive(uint256 id);
    /// @notice The holder opted out of third-party redemption; only the holder or its operator may redeem.
    error ThirdPartyRedeemDisabled();
    /// @notice An existing series with this id has a different (underlying, isPut, strike, expiry).
    error SeriesIdCollision();
    /// @notice The call is only allowed during 09:30-16:00 New York on a session day.
    error OutsideRegularSession();
    /// @notice Too early; allowed from `notBefore` (unix seconds).
    error TooEarly(uint40 notBefore);
    /// @notice The spot observation from `updatedAt` (unix seconds) is older than the market allows.
    error StaleSpot(uint256 updatedAt);
    /// @notice No price source is configured or ok for the call.
    error NoSource();
    /// @notice The settlement is already final.
    error AlreadyFinal();
    /// @notice The resolved price is outside the band [lo, hi] (USDG 6 dp per share) of the recorded sources.
    error ResolveOutOfBand(uint256 lo, uint256 hi);
    /// @notice A parameter exceeds its compiled ceiling in V2Constants.
    error CeilingExceeded();
    /// @notice The (underlying, expiry) is already pinned, by another caller, to a settlement configuration that differs
    ///         from the current one, so this pin cannot confirm it (INTERFACE_VERSION 6).
    error PinMismatch();
    /// @notice The price source `source` did not pin while the oracle pinned an expiry: it reverted (`reason` holds the
    ///         first four bytes of its revert data, zero when there were none), has no code, or did not answer the
    ///         IPriceSource.pin selector (INTERFACE_VERSION 6).
    error SourceNotPinned(address source, bytes4 reason);
    /// @notice AutoRoller.reprice: the ask's series is at or in the money at spot, so the roller will not move the ask
    ///         instead of withdrawing it (INTERFACE_VERSION 7).
    error InTheMoney();
    /// @notice A MakerVault quoter call would pay out `outflow` USDG base units net, more than the `available` part of
    ///         Limits.maxDailyOutflow (INTERFACE_VERSION 7).
    error OutflowCapExceeded(uint256 available, uint256 outflow);
}
