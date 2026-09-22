// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Morpho Blue's `MarketParams`, ABI-identical to morpho-blue `src/interfaces/IMorpho.sol`.
/// @dev Declared ONCE in this file. Two structurally identical structs in two files would be two Solidity types
///      and two `internalType` strings in the exported ABIs (src/v2/periphery/v4/V4Types.sol:6-13). P8-02 Earn
///      supply-side code imports this rather than redeclaring it.
///
///      Field order and types are Morpho Blue's: `loanToken`, `collateralToken`, `oracle`, `irm`, `lltv`.
///      `lltv` is 1e18-scaled (e.g. 86% = 0.86e18). Source: morpho-blue `src/interfaces/IMorpho.sol` `MarketParams`.
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

/// @notice Morpho Blue oracle: collateral in loan-token units, scaled `ORACLE_PRICE_SCALE` = 1e36.
/// @dev Source: morpho-blue `src/interfaces/IOracle.sol` `price()`.
interface IMorphoOracle {
    function price() external view returns (uint256);
}

/// @notice The Morpho Blue surface the v8 hedger's borrow adapter needs.
/// @dev Selectors and argument order are morpho-blue `src/interfaces/IMorpho.sol`. `Id` is Morpho's user-defined
///      value type over `bytes32`; it encodes as `bytes32`. `borrow`/`repay` take exactly one of `assets` or
///      `shares` non-zero.
interface IMorpho {
    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes calldata data)
        external;

    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver)
        external;

    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);

    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256 assetsRepaid, uint256 sharesRepaid);

    /// @notice Brings the market's stored totals up to `block.timestamp`.
    /// @dev Source: morpho-blue `src/interfaces/IMorpho.sol` `accrueInterest`. MIRRORED FROM THE DEPENDENCY, NOT
    ///      RE-DERIVED. Morpho's own accrual is `taylorCompounded` against the market's IRM, and neither that
    ///      library nor `IIrm` is declared in this repository; reimplementing the maths here would produce a number
    ///      that LOOKS authoritative and is subtly wrong, which is worse than the understatement it replaces.
    ///
    ///      IT IS NOT A VIEW, AND THAT IS THE WHOLE POINT. `market(id)` returns the totals as of the last time
    ///      anything touched the market, so `totalBorrowAssets` -- and therefore every debt and health number
    ///      derived from it -- UNDERSTATES what is owed until this is called. A caller that needs a current figure
    ///      must accrue first, in its own transaction. See {StockLoanAdapter.accrue}.
    function accrueInterest(MarketParams memory marketParams) external;

    function position(bytes32 id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);

    function market(bytes32 id)
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );

    function idToMarketParams(bytes32 id) external view returns (MarketParams memory);
}

/// @notice Morpho Blue market id: `keccak256` of the five static `MarketParams` words.
/// @dev Source: morpho-blue `src/libraries/MarketParamsLib.sol` `id`, which does
///      `keccak256(marketParams, 5 * 32)` over the in-memory struct. That is ABI-identical to
///      `keccak256(abi.encode(marketParams))` for this five-word struct. Do not invent a different hash.
library MorphoMarketId {
    /// @dev morpho-blue `MarketParamsLib.MARKET_PARAMS_BYTES_LENGTH` = 5 * 32.
    uint256 internal constant MARKET_PARAMS_BYTES_LENGTH = 5 * 32;

    function id(MarketParams memory marketParams) internal pure returns (bytes32 marketParamsId) {
        assembly ("memory-safe") {
            marketParamsId := keccak256(marketParams, MARKET_PARAMS_BYTES_LENGTH)
        }
    }
}
