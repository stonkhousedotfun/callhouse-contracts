// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {V2Constants} from "../../interfaces/V2Constants.sol";
import {V2Errors} from "../../interfaces/V2Errors.sol";
import {IMorpho, IMorphoOracle, MarketParams, MorphoMarketId} from "./MorphoDeps.sol";

/// @title StockLoanAdapter
/// @notice Thin borrow-side Morpho Blue wrapper the v8 hedger owns: post USDG collateral, borrow `asset`, repay,
///         withdraw leftover collateral. INTERFACE_VERSION 8, v8 design P8-03.
/// @dev `morpho` is a constructor argument. On chain 4663 it is `0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010`
///      (v8-plan/LENDING-RECON-2026-09-19.md:11,247; 06-QUIRKS.md §H). The canonical Morpho address has no code
///      on 4663 and is not compiled in. A `code.length == 0` morpho reverts `V2Errors.NoSource()` (same shape as
///      PayoutRouter.sol:56-60).
///
///      Not AccessManaged: the hedger is the immutable {owner}; there is no `restricted` selector and
///      `roles.v8.json` is not touched.
///
///      Views never revert on an unconfigured asset — they return 0 — so the hedger can read them inside a
///      guard without try/catch.
contract StockLoanAdapter is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Morpho Blue `ORACLE_PRICE_SCALE` (morpho-blue `src/libraries/ConstantsLib.sol`).
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;

    IMorpho public immutable morpho;
    address public immutable usdg;
    address public immutable owner;

    mapping(address asset => MarketParams) private _markets;

    event MarketSet(address indexed asset, bytes32 id);
    /// @notice A market pointer moved from one Morpho market to another for `asset`. Emitted on a re-pin only
    ///         (never on the first pin), alongside {MarketSet}, so an indexer can see both ids of the move.
    event MarketRepinned(address indexed asset, bytes32 oldId, bytes32 newId);
    event CollateralPosted(address indexed asset, uint256 assets);
    event CollateralWithdrawn(address indexed asset, uint256 assets, address receiver);
    event Borrowed(address indexed asset, uint256 assets, address receiver);
    event Repaid(address indexed asset, uint256 assets);

    /// @notice No Morpho market is configured for `asset`.
    error UnknownMarket(address asset);

    modifier onlyOwner() {
        if (msg.sender != owner) revert V2Errors.NotAuthorized();
        _;
    }

    constructor(address morpho_, address usdg_, address owner_) {
        if (morpho_.code.length == 0) revert V2Errors.NoSource();
        if (usdg_.code.length == 0) revert V2Errors.UnsupportedAsset();
        if (owner_ == address(0)) revert V2Errors.NotAuthorized();
        morpho = IMorpho(morpho_);
        usdg = usdg_;
        owner = owner_;
    }

    function market(address asset) external view returns (MarketParams memory) {
        return _markets[asset];
    }

    /// @notice Pin the Morpho market used to borrow `params.loanToken` against USDG collateral.
    /// @dev T-OP-088 (T-OP-076 F-7). REFUSES TO MOVE WHILE THIS CONTRACT HOLDS A POSITION ON THE MARKET IT IS
    ///      LEAVING. Every view and every exit here reads `_markets[asset]`: re-pinning `asset` to a different
    ///      Morpho market while collateral or debt sits on the old one leaves that position owned by this
    ///      contract and reachable by nothing -- {collateral}, {borrowed} and {healthFactorBps} all answer for the
    ///      NEW market, {repay} and {withdrawCollateral} address the new market, and the old one keeps accruing
    ///      interest against collateral no one can withdraw until the market is pinned back. So a re-pin is
    ///      only possible on a flat position. MIRRORED from `EarnVault.setAdapter`, the shape this repository
    ///      uses for "never lose reach to a position you own": the refusal is `InsufficientCollateral(0, left)`
    ///      -- zero may be carried across, `left` is what is still there -- collateral first, then the debt in
    ///      loan-token units when the collateral is already gone. Re-pinning to the SAME market id is a no-op on
    ///      reach and is allowed with a position open (a configuration script re-running is not a move). NO
    ///      migration inside this function: moving the position is a second money path and is out of scope here.
    function setMarket(MarketParams calldata params) external onlyOwner {
        if (params.loanToken == address(0) || params.collateralToken != usdg) revert V2Errors.UnsupportedAsset();
        // SEC-32. CODE-BEARING, NOT MERELY NON-ZERO. A non-zero address with no code passes every check here and
        // then fails later inside Morpho, where the revert says nothing about which pointer was wrong. The row
        // notes the health-factor guard makes {Hedger.hedge} fail closed afterwards, so this is hygiene rather
        // than a live hole -- but "it fails somewhere else eventually" is not the same as refusing a bad pointer
        // at the moment it is set, which is the only moment the operator is looking. Same shape as
        // `Clearinghouse._requireSettlementOracle` (SEC-07), minus the interface probe: Morpho's oracle and IRM
        // surfaces belong to Morpho, so this bounds code presence only and says so rather than implying more.
        if (params.oracle.code.length == 0 || params.irm.code.length == 0) revert V2Errors.NoSource();
        bytes32 newId = MorphoMarketId.id(params);
        MarketParams memory old = _markets[params.loanToken];
        if (old.loanToken != address(0)) {
            bytes32 oldId = MorphoMarketId.id(old);
            if (oldId != newId) {
                (, uint128 borrowShares, uint128 collat) = morpho.position(oldId, address(this));
                if (collat != 0) revert V2Errors.InsufficientCollateral(0, collat);
                if (borrowShares != 0) revert V2Errors.InsufficientCollateral(0, _debt(oldId, borrowShares));
                emit MarketRepinned(params.loanToken, oldId, newId);
            }
        }
        _markets[params.loanToken] = params;
        emit MarketSet(params.loanToken, newId);
    }

    function postCollateral(address asset, uint256 assets) external nonReentrant onlyOwner {
        MarketParams memory p = _requireMarket(asset);
        if (assets == 0) revert V2Errors.BadUnits();
        IERC20(usdg).safeTransferFrom(msg.sender, address(this), assets);
        IERC20(usdg).forceApprove(address(morpho), assets);
        morpho.supplyCollateral(p, assets, address(this), "");
        IERC20(usdg).forceApprove(address(morpho), 0);
        emit CollateralPosted(asset, assets);
    }

    function withdrawCollateral(address asset, uint256 assets, address receiver) external nonReentrant onlyOwner {
        MarketParams memory p = _requireMarket(asset);
        if (assets == 0 || receiver == address(0)) revert V2Errors.BadUnits();
        morpho.withdrawCollateral(p, assets, address(this), receiver);
        emit CollateralWithdrawn(asset, assets, receiver);
    }

    function borrow(address asset, uint256 assets, address receiver) external nonReentrant onlyOwner {
        MarketParams memory p = _requireMarket(asset);
        if (assets == 0 || receiver == address(0)) revert V2Errors.BadUnits();
        morpho.borrow(p, assets, 0, address(this), receiver);
        emit Borrowed(asset, assets, receiver);
    }

    function repay(address asset, uint256 assets) external nonReentrant onlyOwner {
        MarketParams memory p = _requireMarket(asset);
        if (assets == 0) revert V2Errors.BadUnits();
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        IERC20(asset).forceApprove(address(morpho), assets);
        morpho.repay(p, assets, 0, address(this), "");
        IERC20(asset).forceApprove(address(morpho), 0);
        emit Repaid(asset, assets);
    }

    /// @notice Brings `asset`'s Morpho market up to date so the debt the views below report is current.
    /// @dev F-CP-08. Morpho stores `totalBorrowAssets` as of the last time anything touched the market, so
    ///      {borrowed} and {healthFactorBps} read an UNDERSTATED debt until this runs. Understated debt makes the
    ///      hedger's borrow ceiling too generous and its health factor too flattering -- both fail OPEN.
    ///
    ///      IT HAS TO BE A SEPARATE, NON-VIEW CALL. Accruing writes to Morpho, so a `view` cannot do it; that is
    ///      why the fix is a call the caller makes BEFORE it reads, rather than a change inside `_debt`.
    ///
    ///      Silent on an unconfigured asset, matching the views: they return 0 rather than reverting so the hedger
    ///      can read them inside a guard, and an accrue that reverted where the read does not would be a new way
    ///      for a guard to fail.
    function accrue(address asset) external nonReentrant onlyOwner {
        MarketParams memory p = _markets[asset];
        if (p.loanToken == address(0)) return;
        morpho.accrueInterest(p);
    }

    /// @notice Collateral / debt in bps. 0 if `asset` has no market or no collateral. `type(uint256).max` if
    ///         configured with collateral and zero debt.
    /// @dev READS STORED TOTALS. Call {accrue} first if the number has to be current; see {_debt}.
    function healthFactorBps(address asset) external view returns (uint256) {
        MarketParams memory p = _markets[asset];
        if (p.loanToken == address(0)) return 0;
        bytes32 id = MorphoMarketId.id(p);
        (, uint128 borrowShares, uint128 collat) = morpho.position(id, address(this));
        if (collat == 0) return 0;
        uint256 debt = _debt(id, borrowShares);
        if (debt == 0) return type(uint256).max;
        uint256 price = IMorphoOracle(p.oracle).price();
        uint256 collatValue = Math.mulDiv(collat, price, ORACLE_PRICE_SCALE);
        return Math.mulDiv(collatValue, V2Constants.BPS, debt);
    }

    /// @notice Assets owed on `asset`. Stored, not accrued -- call {accrue} first if it must be current.
    function borrowed(address asset) external view returns (uint256) {
        MarketParams memory p = _markets[asset];
        if (p.loanToken == address(0)) return 0;
        bytes32 id = MorphoMarketId.id(p);
        (, uint128 borrowShares,) = morpho.position(id, address(this));
        return _debt(id, borrowShares);
    }

    function collateral(address asset) external view returns (uint256) {
        MarketParams memory p = _markets[asset];
        if (p.loanToken == address(0)) return 0;
        (,, uint128 collat) = morpho.position(MorphoMarketId.id(p), address(this));
        return collat;
    }

    function _requireMarket(address asset) private view returns (MarketParams memory p) {
        p = _markets[asset];
        if (p.loanToken == address(0)) revert UnknownMarket(asset);
    }

    /// @dev Morpho's own share-to-asset conversion against the market's STORED totals. F-CP-08: those totals are
    ///      only current as of the last touch of the market, so every caller that needs a true figure calls
    ///      {accrue} in the same transaction first. Deliberately not "fixed" here -- a view cannot accrue, and
    ///      re-implementing Morpho's `taylorCompounded` against an `IIrm` this repository does not declare would
    ///      substitute a confidently wrong number for a knowably conservative one.
    function _debt(bytes32 id, uint128 borrowShares) private view returns (uint256) {
        if (borrowShares == 0) return 0;
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = morpho.market(id);
        if (totalBorrowShares == 0) return 0;
        return Math.mulDiv(borrowShares, totalBorrowAssets, totalBorrowShares);
    }
}
