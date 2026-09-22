// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMorpho, IMorphoOracle, MarketParams, MorphoMarketId} from "../periphery/lending/MorphoDeps.sol";

/// @title MockMorphoOracle
/// @notice `IMorphoOracle.price()` double. Default 1e36 (1:1 collateral/loan).
contract MockMorphoOracle {
    uint256 public price = 1e36;

    function setPrice(uint256 p) external {
        price = p;
    }
}

/// @title MockMorphoBlue
/// @notice IMorpho double with 1:1 borrow shares. Enough for StockLoanAdapter unit tests.
/// @dev T-OP-069 (from T-OP-049 / docs/V8-MOCK-FIDELITY.md item 2): THE TWO REFUSALS A LOAN IS MADE OF, OPT-IN.
///      The real Morpho Blue refuses a `borrow` (and a `withdrawCollateral`) that would leave the position over
///      the market's LLTV, and a `borrow` the market cannot fund. Until this row the double refused nothing, so
///      every Hedger path under a Morpho refusal was pinned against a lender that never refuses. Both checks are
///      OFF by default and switched on per market by the test that wants them, so no existing test changes.
///      THE ERROR SHAPE IS MORPHO'S, MIRRORED NOT INVENTED: Morpho Blue reverts with `require(cond, ErrorsLib.X)`
///      -- a plain `Error(string)` -- and the two strings are `ErrorsLib.INSUFFICIENT_COLLATERAL` and
///      `ErrorsLib.INSUFFICIENT_LIQUIDITY` (morpho-blue `src/libraries/ErrorsLib.sol`; not vendored here, quoted
///      from the fidelity table at `docs/V8-MOCK-FIDELITY.md:403-404`). A custom error would decode differently
///      from what the adapter sees on 4663 and would make a test pass against a shape production never emits.
///      THE HEALTH RULE IS MORPHO'S `_isHealthy`: `collateral x price / 1e36 x lltv / 1e18 >= borrowed`, with
///      `price` from the market's `oracle` (loan-token units per collateral unit, 1e36-scaled) and `lltv`
///      1e18-scaled -- the same arithmetic {StockLoanAdapter.healthFactorBps} reads, so the two agree by
///      construction. Checked AFTER the position is updated, as Morpho does.
contract MockMorphoBlue is IMorpho {
    using SafeERC20 for IERC20;

    /// @dev Morpho Blue `ErrorsLib.INSUFFICIENT_COLLATERAL`, byte for byte.
    string public constant INSUFFICIENT_COLLATERAL = "insufficient collateral";
    /// @dev Morpho Blue `ErrorsLib.INSUFFICIENT_LIQUIDITY`, byte for byte.
    string public constant INSUFFICIENT_LIQUIDITY = "insufficient liquidity";
    /// @dev Morpho Blue `ORACLE_PRICE_SCALE`.
    uint256 public constant ORACLE_PRICE_SCALE = 1e36;

    /// @notice Per market: whether {borrow} and {withdrawCollateral} enforce the LLTV. Default false (unlimited).
    mapping(bytes32 => bool) public enforceLltv;
    /// @notice Per market: whether {borrow} enforces `totalBorrowAssets <= totalSupplyAssets`. Default false.
    mapping(bytes32 => bool) public enforceLiquidity;

    function setEnforceLltv(MarketParams calldata p, bool on) external {
        enforceLltv[MorphoMarketId.id(p)] = on;
    }

    /// @notice Switches the liquidity check on for `p` and records what the market has to lend. The double never
    ///         tracks supply otherwise (`totalSupplyAssets` was never written), so the cap is set here explicitly.
    function setLiquidity(MarketParams calldata p, uint128 totalSupplyAssets, bool on) external {
        bytes32 id = MorphoMarketId.id(p);
        _markets[id].totalSupplyAssets = totalSupplyAssets;
        enforceLiquidity[id] = on;
    }

    struct Pos {
        uint256 supplyShares;
        uint128 borrowShares;
        uint128 collateral;
    }

    struct Mkt {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint128 lastUpdate;
        uint128 fee;
    }

    /// @dev Per-second borrow rate, 1e18-scaled, for {accrueInterest}. 0 by default: a test that does not set it
    ///      sees the same numbers it always did.
    uint256 public borrowRatePerSecond;

    function setBorrowRatePerSecond(uint256 rate) external {
        borrowRatePerSecond = rate;
    }

    mapping(bytes32 => MarketParams) internal _params;
    mapping(bytes32 => Mkt) internal _markets;
    mapping(bytes32 => mapping(address => Pos)) internal _pos;

    function setMarket(MarketParams calldata p) external {
        _params[MorphoMarketId.id(p)] = p;
    }

    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes calldata)
        external
        override
    {
        bytes32 id = MorphoMarketId.id(marketParams);
        IERC20(marketParams.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
        _pos[id][onBehalf].collateral += uint128(assets);
        _params[id] = marketParams;
    }

    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver)
        external
        override
    {
        bytes32 id = MorphoMarketId.id(marketParams);
        _pos[id][onBehalf].collateral -= uint128(assets);
        // Morpho checks health after the withdrawal, before the transfer: `require(_isHealthy(...), INSUFFICIENT_COLLATERAL)`.
        if (enforceLltv[id]) _requireHealthy(id, marketParams, onBehalf);
        IERC20(marketParams.collateralToken).safeTransfer(receiver, assets);
    }

    function borrow(MarketParams memory marketParams, uint256 assets, uint256, address onBehalf, address receiver)
        external
        override
        returns (uint256, uint256)
    {
        bytes32 id = MorphoMarketId.id(marketParams);
        Pos storage p = _pos[id][onBehalf];
        Mkt storage m = _markets[id];
        // Real Morpho accrues inside `borrow`, which is also what stamps `lastUpdate`. Mirror that, so `elapsed`
        // in {accrueInterest} is measured from the last touch rather than from the epoch.
        m.lastUpdate = uint128(block.timestamp);
        p.borrowShares += uint128(assets);
        m.totalBorrowAssets += uint128(assets);
        m.totalBorrowShares += uint128(assets);
        // Morpho's two `require`s, in its order: health of the position after the borrow, then the market's
        // liquidity (`totalBorrowAssets <= totalSupplyAssets`). Each only when the test switched it on.
        if (enforceLltv[id]) _requireHealthy(id, marketParams, onBehalf);
        if (enforceLiquidity[id]) require(m.totalBorrowAssets <= m.totalSupplyAssets, INSUFFICIENT_LIQUIDITY);
        IERC20(marketParams.loanToken).safeTransfer(receiver, assets);
        return (assets, assets);
    }

    /// @dev Morpho Blue `_isHealthy`, on this double's 1:1 shares: `maxBorrow = collateral x price / 1e36 x lltv
    ///      / 1e18`, healthy iff `maxBorrow >= borrowed`. `borrowShares` ARE the borrowed assets here (1:1), which
    ///      is exact until {accrueInterest} has grown `totalBorrowAssets`; then the real debt is the share's slice
    ///      of the total, read the way {StockLoanAdapter._debt} reads it.
    function _requireHealthy(bytes32 id, MarketParams memory marketParams, address onBehalf) private view {
        Pos storage p = _pos[id][onBehalf];
        Mkt storage m = _markets[id];
        uint256 borrowed = m.totalBorrowShares == 0
            ? 0
            : uint256(p.borrowShares) * uint256(m.totalBorrowAssets) / uint256(m.totalBorrowShares);
        uint256 price = IMorphoOracle(marketParams.oracle).price();
        uint256 maxBorrow = uint256(p.collateral) * price / ORACLE_PRICE_SCALE * marketParams.lltv / 1e18;
        require(maxBorrow >= borrowed, INSUFFICIENT_COLLATERAL);
    }

    function repay(MarketParams memory marketParams, uint256 assets, uint256, address onBehalf, bytes calldata)
        external
        override
        returns (uint256, uint256)
    {
        bytes32 id = MorphoMarketId.id(marketParams);
        Pos storage p = _pos[id][onBehalf];
        Mkt storage m = _markets[id];
        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);
        p.borrowShares -= uint128(assets);
        m.totalBorrowAssets -= uint128(assets);
        m.totalBorrowShares -= uint128(assets);
        return (assets, assets);
    }

    /// @notice Grows `totalBorrowAssets` while `totalBorrowShares` stays put, which is what interest looks like to
    ///         every reader of this market: the same shares come to owe more assets.
    /// @dev A LINEAR STAND-IN, DELIBERATELY NOT Morpho's `taylorCompounded`. This double exists so a caller that
    ///      forgets to accrue can be caught, and a straight-line rate does that exactly as well as a compounding
    ///      one while being obviously not the real thing. Nothing here should be read as Morpho's arithmetic.
    ///      Rate is per second, 1e18-scaled, and defaults to 0 so existing tests are unaffected.
    function accrueInterest(MarketParams memory marketParams) external override {
        bytes32 id = MorphoMarketId.id(marketParams);
        Mkt storage m = _markets[id];
        uint256 elapsed = block.timestamp - m.lastUpdate;
        m.lastUpdate = uint128(block.timestamp);
        if (elapsed == 0 || borrowRatePerSecond == 0 || m.totalBorrowAssets == 0) return;
        m.totalBorrowAssets += uint128(uint256(m.totalBorrowAssets) * borrowRatePerSecond * elapsed / 1e18);
    }

    function position(bytes32 id, address user)
        external
        view
        override
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral)
    {
        Pos storage p = _pos[id][user];
        return (p.supplyShares, p.borrowShares, p.collateral);
    }

    function market(bytes32 id) external view override returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        Mkt storage m = _markets[id];
        return (m.totalSupplyAssets, m.totalSupplyShares, m.totalBorrowAssets, m.totalBorrowShares, m.lastUpdate, m.fee);
    }

    function idToMarketParams(bytes32 id) external view override returns (MarketParams memory) {
        return _params[id];
    }
}
