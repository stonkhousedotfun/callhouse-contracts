// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MarketParams} from "../periphery/lending/MorphoDeps.sol";

/// @title IHedger
/// @notice Delta-hedge policy for maker vaults. Shipped DISABLED. Own errors (T-78 owns abi-manifest).
interface IHedger {
    struct Limits {
        uint128 maxBorrowPerAsset;
        uint128 maxUsdgCollateral;
        uint16 healthFactorFloorBps;
        uint16 slippageBps;
        uint128 maxDailyNotional;
    }

    error Disabled();
    error Paused();
    error WeekendBrake();
    error LimitExceeded();
    error Slippage();
    error NothingBorrowed();
    error CeilingExceeded();

    event EnabledSet(address indexed asset, bool on);
    event PausedSet(bool on);
    event LimitsSet(Limits limits);
    event FreshnessSet(uint256 seconds_);
    event Hedged(address indexed asset, uint256 borrowed, uint256 collateral, uint256 usdgOut);
    event Unwound(address indexed asset, uint256 usdgIn, uint256 assetIn);
    event TreasuryCost(address indexed asset, uint256 interestUsdg);

    function enabled(address asset) external view returns (bool);
    function paused() external view returns (bool);
    function limits() external view returns (Limits memory);
    /// @notice Raw-age brake on {hedge} ONLY (`_requireFresh`, new shorts). Since T-OP-066 `unwind` does not read
    ///         it: an exit needs a spot the oracle stands behind (`trySpot` ok), which since T-OP-061 means "at most
    ///         thirty minutes old, or pool-corroborated within the market's band" -- not a young print.
    function freshnessSeconds() external view returns (uint256);
    function setEnabled(address asset, bool on) external;
    function pause(bool on) external;
    function setLimits(Limits calldata next) external;
    function setFreshnessSeconds(uint256 seconds_) external;
    function setStockLoanMarket(MarketParams calldata params) external;
    function fund(uint256 usdgAmount) external;
    /// @notice The immutable single exit. Both money-out paths pay here and nowhere else.
    function treasury() external view returns (address);
    /// @dev NO recipient parameter: v8's exit is a property of the contract, not of the call.
    function withdraw(uint256 usdgAmount) external;
    /// @dev F-CP-02. Without this the collateral posted by {hedge} can never leave the loan market.
    function withdrawCollateral(address asset, uint256 assets) external;
    function hedge(address asset, uint256 borrowAssets, uint256 collateralUsdg, uint256 minUsdgOut) external;
    function unwind(address asset, uint256 usdgIn, uint256 minAssetOut, uint24 fee, int24 tickSpacing) external;
    function repay(address asset, uint256 assets) external;
}
