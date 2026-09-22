// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {ERC1155Utils} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Utils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IClearinghouse} from "../interfaces/IClearinghouse.sol";
import {IExpiryCalendar} from "../interfaces/IExpiryCalendar.sol";
import {ISettlementOracle} from "../interfaces/ISettlementOracle.sol";
import {V2Constants} from "../interfaces/V2Constants.sol";
import {V2Errors} from "../interfaces/V2Errors.sol";
import {V2Ids} from "../interfaces/V2Ids.sol";
import {V2Types} from "../interfaces/V2Types.sol";
import {OptionMath} from "../lib/OptionMath.sol";
import {Managed} from "../access/Managed.sol";

/// @title MockClearinghouse
/// @notice A behaviour-faithful IClearinghouse for the OrderBook suites (C2-06), written before the real Clearinghouse
///         (C2-05) merged. C2-08 replaces it with the real contract; the constructor has the real one's signature so
///         that swap is a one-line change in a test base.
/// @dev Faithful on every path the book touches, because the book's correctness is argued against them:
///        - OZ ERC1155 + ERC1155Supply balances, approvals and safeTransferFrom with receiver hooks; the transfer and
///          approval entry points hold the reentrancy guard, as the real ones do, so a receiver callback cannot move
///          tokens mid-call;
///        - ids from V2Ids; {series} / {market} of an unknown key are all zero; {seriesExists}; {mintCutoff} =
///          expiry - SETTLEMENT_WINDOW; {collateralAsset} and {collateralPerUnit} from OptionMath (UnknownSeries for an
///          id never created);
///        - the free ledger (balance-delta deposits), operators, and {mint} with the real checks in the real order:
///          writer or operator (NotAuthorized), UnknownSeries, MarketDisabled, MintPaused, PastCutoff, BadUnits,
///          non-zero longTo, InsufficientCollateral(have, need);
///        - {mint}'s log order (02-interfaces §1.8): TransferSingle(long -> longTo), TransferSingle(short -> writer),
///          Minted, and only then the two acceptance callbacks (long receiver first), so a rejecting receiver reverts
///          the whole mint;
///        - {setThirdPartyRedeem} and the redeem rule: holder, holder's operator, or anyone when the holder allows it
///          (ThirdPartyRedeemDisabled otherwise); {redeemBatch} skips holders its caller may not redeem;
///        - {settle} reading the series' pinned oracle (settlementPrice, then finalize, both try/catch) and storing
///          OptionMath.settlementPerUnit; {redeem} burning the whole balance; tokens stay transferable after settlement.
///      Simplified, because the book never depends on it: no PayoutAdapter conversion (ITM call longs are paid in kind),
///      no keeper bounties, no metadata URI setter, and the payout-to-ledger preference is honoured but payout-in-kind
///      is only stored.
contract MockClearinghouse is IClearinghouse, ERC1155Supply, Managed, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IClearinghouse
    address public immutable usdg;
    /// @inheritdoc IClearinghouse
    address public calendar;
    /// @inheritdoc IClearinghouse
    address public feeRecipient;
    /// @notice GUARDIAN_ROLE switch over {createSeries} for new ids.
    bool public createPaused;

    /// @inheritdoc IClearinghouse
    mapping(uint256 longId => uint256) public locked;
    /// @inheritdoc IClearinghouse
    mapping(address underlying => mapping(uint40 expiry => uint256)) public openInterest;
    /// @inheritdoc IClearinghouse
    mapping(address account => mapping(address asset => uint256)) public free;
    /// @inheritdoc IClearinghouse
    mapping(address asset => uint256) public accruedFees;
    /// @inheritdoc IClearinghouse
    mapping(address account => mapping(address operator => bool)) public isOperator;

    struct Prefs {
        bool inKind;
        bool toLedger;
        bool noThirdPartyRedeem;
    }

    mapping(address underlying => V2Types.MarketConfig) private _markets;
    mapping(uint256 longId => V2Types.Series) private _series;
    mapping(address account => Prefs) private _prefs;

    /// @inheritdoc IClearinghouse
    /// @dev INTERFACE_VERSION 8, mirroring the real Clearinghouse. `OrderBookRealClearinghouse.t.sol` re-runs the
    ///      book suites against both, so the mock must carry the same v8 surface with the same behaviour.
    mapping(address minter => bool) public isMinter;
    /// @inheritdoc IClearinghouse
    address public defaultOracle;
    uint16 private _defaultExerciseFeeBps;
    uint32 private _defaultMintFeePpm;

    constructor(address authority_, address usdg_, address calendar_, address feeRecipient_, string memory baseUri_)
        ERC1155(baseUri_)
        Managed(authority_)
    {
        if (feeRecipient_ == address(0)) revert V2Errors.NotAuthorized();
        usdg = usdg_;
        calendar = calendar_;
        feeRecipient = feeRecipient_;
    }

    /*//////////////////////////////////////////////////////////////
                             ADMIN / GUARDIAN
    //////////////////////////////////////////////////////////////*/

    /// @notice Registers a market. DEFAULT_ADMIN_ROLE. UnsupportedAsset when already registered or not 18 dp.
    function registerMarket(address underlying, V2Types.MarketConfig calldata cfg) external nonReentrant restricted {
        if (_markets[underlying].strikeTick != 0) revert V2Errors.UnsupportedAsset();
        if (IERC20Metadata(underlying).decimals() != 18) revert V2Errors.UnsupportedAsset();
        _checkConfig(cfg);
        _markets[underlying] = cfg;
        emit MarketRegistered(underlying, cfg);
    }

    /*//////////////////////////////////////////////////////////////
          MARKETS, INTERFACE_VERSION 8 -- mirrors the real contract
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IClearinghouse
    function registerMarket(address underlying, uint64 strikeTick, bool enabled) external nonReentrant restricted {
        if (_markets[underlying].strikeTick != 0) revert V2Errors.UnsupportedAsset();
        if (IERC20Metadata(underlying).decimals() != 18) revert V2Errors.UnsupportedAsset();
        V2Types.MarketConfig memory cfg = V2Types.MarketConfig({
            enabled: enabled,
            mintPaused: false,
            strikeTick: strikeTick,
            exerciseFeeBps: _defaultExerciseFeeBps,
            oracle: defaultOracle,
            mintFeePpm: _defaultMintFeePpm
        });
        if (cfg.strikeTick == 0 || cfg.strikeTick % V2Constants.PRICE_TICK != 0) revert V2Errors.BadStrike();
        _checkFees(cfg.exerciseFeeBps, cfg.mintFeePpm);
        if (cfg.oracle.code.length == 0) revert V2Errors.NoSource();
        _markets[underlying] = cfg;
        emit MarketRegistered(underlying, cfg);
    }

    /// @inheritdoc IClearinghouse
    function setMarketListing(address underlying, bool enabled, uint64 strikeTick) external nonReentrant restricted {
        V2Types.MarketConfig storage m = _registered(underlying);
        if (strikeTick == 0 || strikeTick % V2Constants.PRICE_TICK != 0) revert V2Errors.BadStrike();
        m.enabled = enabled;
        m.strikeTick = strikeTick;
        emit MarketConfigSet(underlying, m);
    }

    /// @inheritdoc IClearinghouse
    function setMarketFees(address underlying, uint16 exerciseFeeBps, uint32 mintFeePpm)
        external
        nonReentrant
        // v8-stub: C8-02 -> restricted (MARKET_FEE_MANAGER)
        restricted
    {
        V2Types.MarketConfig storage m = _registered(underlying);
        _checkFees(exerciseFeeBps, mintFeePpm);
        m.exerciseFeeBps = exerciseFeeBps;
        m.mintFeePpm = mintFeePpm;
        emit MarketConfigSet(underlying, m);
    }

    /// @inheritdoc IClearinghouse
    function setMarketOracle(address underlying, address oracle)
        external
        nonReentrant
        // v8-stub: C8-02 -> restricted (CONFIG_ADMIN)
        restricted
    {
        V2Types.MarketConfig storage m = _registered(underlying);
        if (oracle.code.length == 0) revert V2Errors.NoSource();
        m.oracle = oracle;
        emit MarketConfigSet(underlying, m);
    }

    /// @inheritdoc IClearinghouse
    function setDefaultMarketFees(uint16 exerciseFeeBps, uint32 mintFeePpm)
        external
        nonReentrant
        // v8-stub: C8-02 -> restricted (MARKET_FEE_MANAGER)
        restricted
    {
        _checkFees(exerciseFeeBps, mintFeePpm);
        _defaultExerciseFeeBps = exerciseFeeBps;
        _defaultMintFeePpm = mintFeePpm;
        emit DefaultMarketFeesSet(exerciseFeeBps, mintFeePpm);
    }

    /// @inheritdoc IClearinghouse
    function setDefaultOracle(address oracle)
        external
        nonReentrant
        // v8-stub: C8-02 -> restricted (CONFIG_ADMIN)
        restricted
    {
        if (oracle.code.length == 0) revert V2Errors.NoSource();
        defaultOracle = oracle;
        emit DefaultOracleSet(oracle);
    }

    /// @inheritdoc IClearinghouse
    function setMinter(address minter, bool allowed)
        external
        nonReentrant
        // v8-stub: C8-02 -> restricted (CONFIG_ADMIN)
        restricted
    {
        isMinter[minter] = allowed;
        emit MinterSet(minter, allowed);
    }

    /// @inheritdoc IClearinghouse
    function defaultMarketFees() external view returns (uint16 exerciseFeeBps, uint32 mintFeePpm) {
        return (_defaultExerciseFeeBps, _defaultMintFeePpm);
    }

    /// @dev The market row of a registered underlying (UnsupportedAsset otherwise).
    function _registered(address underlying) private view returns (V2Types.MarketConfig storage m) {
        m = _markets[underlying];
        if (m.strikeTick == 0) revert V2Errors.UnsupportedAsset();
    }

    /// @dev The fee half of {_checkConfig}.
    function _checkFees(uint16 exerciseFeeBps, uint32 mintFeePpm) private pure {
        if (exerciseFeeBps > V2Constants.EXERCISE_FEE_CEIL_BPS) revert V2Errors.CeilingExceeded();
        if (mintFeePpm > V2Constants.MINT_FEE_CEIL_PPM) revert V2Errors.CeilingExceeded();
    }

    /// @notice Pauses or resumes {mint} for one market. GUARDIAN_ROLE.
    function setMintPaused(address underlying, bool paused) external nonReentrant restricted {
        V2Types.MarketConfig storage m = _markets[underlying];
        if (m.strikeTick == 0) revert V2Errors.UnsupportedAsset();
        m.mintPaused = paused;
        emit MintPausedSet(underlying, paused);
    }

    /// @notice Pauses or resumes {createSeries} for new ids. GUARDIAN_ROLE.
    function setCreatePaused(bool paused) external nonReentrant restricted {
        createPaused = paused;
        emit CreatePausedSet(paused);
    }

    /// @notice Sets the fee recipient. DEFAULT_ADMIN_ROLE.
    function setFeeRecipient(address recipient) external nonReentrant restricted {
        if (recipient == address(0)) revert V2Errors.NotAuthorized();
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    /*//////////////////////////////////////////////////////////////
                                 SERIES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IClearinghouse
    function createSeries(address underlying, bool isPut, uint128 strike, uint40 expiry)
        external
        nonReentrant
        returns (uint256 longId)
    {
        longId = V2Ids.longIdOf(underlying, isPut, strike, expiry);
        V2Types.Series storage s = _series[longId];
        if (s.underlying != address(0)) {
            if (s.underlying != underlying || s.isPut != isPut || s.strike != strike || s.expiry != expiry) {
                revert V2Errors.SeriesIdCollision();
            }
            return longId;
        }
        V2Types.MarketConfig memory m = _markets[underlying];
        if (!m.enabled) revert V2Errors.MarketDisabled();
        if (createPaused) revert V2Errors.CreatePaused();
        if (strike == 0 || strike % m.strikeTick != 0) revert V2Errors.BadStrike();
        if (
            expiry < block.timestamp + V2Constants.MIN_SERIES_LEAD || expiry > block.timestamp + V2Constants.MAX_TENOR
                || !IExpiryCalendar(calendar).isValidExpiry(expiry)
        ) revert V2Errors.BadExpiry();
        try ISettlementOracle(m.oracle).trySpot(underlying) returns (bool ok, uint256 spot, uint256) {
            if (ok && spot != 0 && (strike < spot / 2 || strike > spot * 2)) revert V2Errors.BadStrike();
        } catch {}
        s.underlying = underlying;
        s.isPut = isPut;
        s.expiry = expiry;
        s.strike = strike;
        s.oracle = m.oracle;
        s.exerciseFeeBps = m.exerciseFeeBps;
        s.mintFeePpm = m.mintFeePpm;
        emit SeriesCreated(longId, underlying, isPut, strike, expiry, m.oracle, m.exerciseFeeBps, m.mintFeePpm);
    }

    /*//////////////////////////////////////////////////////////////
                                 LEDGER
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IClearinghouse
    function deposit(address asset, uint256 amount, address to) external nonReentrant {
        if (asset != usdg && _markets[asset].strikeTick == 0) revert V2Errors.UnsupportedAsset();
        IERC20 token = IERC20(asset);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        free[to][asset] += received;
        emit Deposited(to, asset, received, msg.sender);
    }

    /// @inheritdoc IClearinghouse
    function withdraw(address asset, uint256 amount, address to) external nonReentrant {
        uint256 have = free[msg.sender][asset];
        if (amount > have) revert V2Errors.InsufficientCollateral(have, amount);
        free[msg.sender][asset] = have - amount;
        emit Withdrawn(msg.sender, asset, amount, to);
        IERC20(asset).safeTransfer(to, amount);
    }

    /// @inheritdoc IClearinghouse
    function setOperator(address operator, bool approved) external nonReentrant {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
    }

    /// @inheritdoc IClearinghouse
    function setPayoutInKind(bool inKind) external nonReentrant {
        Prefs storage p = _prefs[msg.sender];
        p.inKind = inKind;
        emit PayoutPrefsSet(msg.sender, inKind, p.toLedger);
    }

    /// @inheritdoc IClearinghouse
    function setPayoutToLedger(bool toLedger) external nonReentrant {
        Prefs storage p = _prefs[msg.sender];
        p.toLedger = toLedger;
        emit PayoutPrefsSet(msg.sender, p.inKind, toLedger);
    }

    /// @inheritdoc IClearinghouse
    function setThirdPartyRedeem(bool allowed) external nonReentrant {
        _prefs[msg.sender].noThirdPartyRedeem = !allowed;
        emit ThirdPartyRedeemSet(msg.sender, allowed);
    }

    /*//////////////////////////////////////////////////////////////
                               POSITIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IClearinghouse
    function mint(uint256 longId, uint64 units, address writer, address longTo) external nonReentrant {
        if (!isMinter[msg.sender]) revert V2Errors.NotMinter();
        if (msg.sender != writer && !isOperator[writer][msg.sender]) revert V2Errors.NotAuthorized();
        V2Types.Series storage s = _series[longId];
        address underlying = s.underlying;
        if (underlying == address(0)) revert V2Errors.UnknownSeries();
        V2Types.MarketConfig storage m = _markets[underlying];
        if (!m.enabled) revert V2Errors.MarketDisabled();
        if (m.mintPaused) revert V2Errors.MintPaused();
        if (block.timestamp >= s.expiry - V2Constants.SETTLEMENT_WINDOW) revert V2Errors.PastCutoff();
        if (units == 0) revert V2Errors.BadUnits();
        if (longTo == address(0)) revert ERC1155InvalidReceiver(address(0));

        address asset = s.isPut ? usdg : underlying;
        uint256 need = units * OptionMath.collateralPerUnit(s.isPut, s.strike);
        // INTERFACE_VERSION 7 (c05): the same collateral rent the real Clearinghouse charges, so an OrderBook suite
        // running on this mock sees the same budget, the same InsufficientCollateral and the same Minted.fee.
        uint256 fee = OptionMath.mintFee(need, s.mintFeePpm, s.expiry - block.timestamp);
        uint256 have = free[writer][asset];
        if (have < need + fee) revert V2Errors.InsufficientCollateral(have, need + fee);
        free[writer][asset] = have - need - fee;
        locked[longId] += need;
        // casting to 'uint128' is safe because the mock's series never hold more rent than a real one could
        // forge-lint: disable-next-line(unsafe-typecast)
        if (fee != 0) s.mintFeesHeld = uint128(uint256(s.mintFeesHeld) + fee);
        openInterest[underlying][s.expiry] += units;

        uint256 shortId = V2Ids.shortIdOf(longId);
        _update(address(0), longTo, _single(longId), _single(units));
        _update(address(0), writer, _single(shortId), _single(units));
        emit Minted(longId, writer, longTo, units, need, fee);
        ERC1155Utils.checkOnERC1155Received(msg.sender, address(0), longTo, longId, units, "");
        ERC1155Utils.checkOnERC1155Received(msg.sender, address(0), writer, shortId, units, "");
    }

    /// @inheritdoc IClearinghouse
    function close(uint256 longId, uint64 units) external nonReentrant {
        V2Types.Series storage s = _known(longId);
        if (s.settled) revert V2Errors.AlreadySettled();
        if (units == 0) revert V2Errors.BadUnits();
        uint256 freed = units * OptionMath.collateralPerUnit(s.isPut, s.strike);
        uint256 refund;
        if (s.mintFeePpm != 0 && block.timestamp < s.expiry) {
            refund = OptionMath.mintFeeRefund(freed, s.mintFeePpm, s.expiry - block.timestamp);
            if (refund > s.mintFeesHeld) refund = s.mintFeesHeld;
            // casting to 'uint128' is safe because refund was just clamped to the uint128 mintFeesHeld
            // forge-lint: disable-next-line(unsafe-typecast)
            s.mintFeesHeld -= uint128(refund);
        }
        _burn(msg.sender, longId, units);
        _burn(msg.sender, V2Ids.shortIdOf(longId), units);
        locked[longId] -= freed;
        openInterest[s.underlying][s.expiry] -= units;
        free[msg.sender][s.isPut ? usdg : s.underlying] += freed + refund;
        emit Closed(longId, msg.sender, units, freed, refund);
    }

    /*//////////////////////////////////////////////////////////////
                               SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IClearinghouse
    function settle(uint256 longId) external nonReentrant returns (bool advanced) {
        V2Types.Series storage s = _known(longId);
        if (s.settled) return false;
        if (block.timestamp < s.expiry) revert V2Errors.NotExpired();
        (bool isFinal, uint256 price) = _finalPrice(ISettlementOracle(s.oracle), s.underlying, s.expiry);
        if (!isFinal) return false;
        if (price > type(uint128).max) revert V2Errors.BadPrice();
        (uint256 longPer, uint256 feePer, uint256 shortPer) =
            OptionMath.settlementPerUnit(s.isPut, s.strike, price, s.exerciseFeeBps);
        s.settled = true;
        // casting to 'uint128' is safe: price is bounded above and every per-unit amount is <= collateralPerUnit
        // forge-lint: disable-next-line(unsafe-typecast)
        s.settlementPrice = uint128(price);
        // forge-lint: disable-next-line(unsafe-typecast)
        s.longPayoutPerUnit = uint128(longPer);
        // forge-lint: disable-next-line(unsafe-typecast)
        s.feePerUnit = uint128(feePer);
        // forge-lint: disable-next-line(unsafe-typecast)
        s.shortPayoutPerUnit = uint128(shortPer);
        emit SeriesSettled(longId, price, longPer, feePer, shortPer);
        // INTERFACE_VERSION 7 (c05): rent still held is no longer refundable, so it accrues here, after SeriesSettled.
        uint256 held = s.mintFeesHeld;
        if (held != 0) {
            s.mintFeesHeld = 0;
            address feeAsset = s.isPut ? usdg : s.underlying;
            accruedFees[feeAsset] += held;
            emit MintFeesAccrued(longId, feeAsset, held);
        }
        return true;
    }

    /// @inheritdoc IClearinghouse
    function redeem(uint256 tokenId, address holder) external nonReentrant returns (uint256 paid, bool inUsdg) {
        if (!_mayRedeem(holder, msg.sender)) revert V2Errors.ThirdPartyRedeemDisabled();
        return _redeem(tokenId, holder);
    }

    /// @inheritdoc IClearinghouse
    function redeemBatch(uint256 tokenId, address[] calldata holders) external nonReentrant returns (uint256 redeemed) {
        V2Types.Series storage s = _known(tokenId & ~uint256(1));
        if (!s.settled) revert V2Errors.NotSettled();
        for (uint256 i; i < holders.length; ++i) {
            address holder = holders[i];
            if (!_mayRedeem(holder, msg.sender) || balanceOf(holder, tokenId) == 0) continue;
            try this.batchRedeemOne(tokenId, holder) {
                ++redeemed;
            } catch {}
        }
    }

    /// @notice One holder of {redeemBatch}; callable only by this contract. Not guarded: the batch holds the guard.
    function batchRedeemOne(uint256 tokenId, address holder) external returns (uint256 paid, bool inUsdg) {
        if (msg.sender != address(this)) revert V2Errors.NotAuthorized();
        return _redeem(tokenId, holder);
    }

    /// @inheritdoc IClearinghouse
    function sweepFees(address asset) external nonReentrant {
        uint256 amount = accruedFees[asset];
        if (amount == 0) return;
        accruedFees[asset] = 0;
        emit FeesSwept(asset, feeRecipient, amount);
        IERC20(asset).safeTransfer(feeRecipient, amount);
    }

    /*//////////////////////////////////////////////////////////////
                           ERC-1155 ENTRY POINTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Guarded, as in the real Clearinghouse.
    function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes memory data)
        public
        override(ERC1155, IERC1155)
        nonReentrant
    {
        super.safeTransferFrom(from, to, id, value, data);
    }

    /// @dev Guarded, as in the real Clearinghouse.
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    ) public override(ERC1155, IERC1155) nonReentrant {
        super.safeBatchTransferFrom(from, to, ids, values, data);
    }

    /// @dev Guarded, as in the real Clearinghouse.
    function setApprovalForAll(address operator, bool approved) public override(ERC1155, IERC1155) nonReentrant {
        super.setApprovalForAll(operator, approved);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IClearinghouse
    function longIdOf(address underlying, bool isPut, uint128 strike, uint40 expiry) external pure returns (uint256) {
        return V2Ids.longIdOf(underlying, isPut, strike, expiry);
    }

    /// @inheritdoc IClearinghouse
    function shortIdOf(uint256 longId) external pure returns (uint256) {
        return V2Ids.shortIdOf(longId);
    }

    /// @inheritdoc IClearinghouse
    function isShortId(uint256 id) external pure returns (bool) {
        return V2Ids.isShortId(id);
    }

    /// @inheritdoc IClearinghouse
    function market(address underlying) external view returns (V2Types.MarketConfig memory) {
        return _markets[underlying];
    }

    /// @inheritdoc IClearinghouse
    function series(uint256 longId) external view returns (V2Types.Series memory) {
        return _series[longId];
    }

    /// @inheritdoc IClearinghouse
    function seriesExists(uint256 longId) external view returns (bool) {
        return _series[longId].underlying != address(0);
    }

    /// @inheritdoc IClearinghouse
    function collateralAsset(uint256 longId) external view returns (address) {
        V2Types.Series storage s = _known(longId);
        return s.isPut ? usdg : s.underlying;
    }

    /// @inheritdoc IClearinghouse
    function collateralPerUnit(uint256 longId) external view returns (uint256) {
        V2Types.Series storage s = _known(longId);
        return OptionMath.collateralPerUnit(s.isPut, s.strike);
    }

    /// @inheritdoc IClearinghouse
    function mintCutoff(uint256 longId) external view returns (uint40) {
        return _known(longId).expiry - V2Constants.SETTLEMENT_WINDOW;
    }

    /// @inheritdoc IClearinghouse
    function previewSettlement(uint256 longId, uint256 price)
        external
        view
        returns (uint256 longPerUnit, uint256 feePerUnit, uint256 shortPerUnit)
    {
        V2Types.Series storage s = _known(longId);
        return OptionMath.settlementPerUnit(s.isPut, s.strike, price, s.exerciseFeeBps);
    }

    /// @inheritdoc IClearinghouse
    function mintFee(uint256 longId, uint64 units) external view returns (uint256 fee) {
        V2Types.Series storage s = _known(longId);
        if (block.timestamp >= s.expiry) return 0;
        uint256 perUnit = OptionMath.collateralPerUnit(s.isPut, s.strike);
        return OptionMath.mintFee(uint256(units) * perUnit, s.mintFeePpm, s.expiry - block.timestamp);
    }

    /// @inheritdoc IClearinghouse
    function closeRefund(uint256 longId, uint64 units) external view returns (uint256 refund) {
        V2Types.Series storage s = _known(longId);
        if (s.settled || block.timestamp >= s.expiry) return 0;
        uint256 perUnit = OptionMath.collateralPerUnit(s.isPut, s.strike);
        refund = OptionMath.mintFeeRefund(uint256(units) * perUnit, s.mintFeePpm, s.expiry - block.timestamp);
        uint256 held = s.mintFeesHeld;
        if (refund > held) refund = held;
    }

    /// @inheritdoc IClearinghouse
    function thirdPartyRedeemAllowed(address account) external view returns (bool) {
        return !_prefs[account].noThirdPartyRedeem;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, IERC165) returns (bool) {
        return interfaceId == type(IClearinghouse).interfaceId || super.supportsInterface(interfaceId);
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Burns the holder's whole balance and pays it in kind (to the ledger when preferred or when the transfer
    ///      fails). A zero balance returns (0, isPut) with no log, as in the real contract.
    function _redeem(uint256 tokenId, address holder) private returns (uint256 paid, bool inUsdg) {
        uint256 longId = tokenId & ~uint256(1);
        V2Types.Series storage s = _known(longId);
        if (!s.settled) revert V2Errors.NotSettled();
        inUsdg = s.isPut;
        uint256 balance = balanceOf(holder, tokenId);
        if (balance == 0) return (0, inUsdg);
        // casting to 'uint64' is safe because the value is capped first
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 units = balance > type(uint64).max ? type(uint64).max : uint64(balance);
        address asset = s.isPut ? usdg : s.underlying;
        if (tokenId == longId) {
            paid = uint256(units) * s.longPayoutPerUnit;
            uint256 fee = uint256(units) * s.feePerUnit;
            accruedFees[asset] += fee;
            locked[longId] -= paid + fee;
            openInterest[s.underlying][s.expiry] -= units;
        } else {
            paid = uint256(units) * s.shortPayoutPerUnit;
            locked[longId] -= paid;
        }
        _burn(holder, tokenId, units);
        bool toLedger = _prefs[holder].toLedger;
        if (paid != 0 && (toLedger || !_tryTransfer(asset, holder, paid))) {
            toLedger = true;
            free[holder][asset] += paid;
        }
        emit Redeemed(tokenId, holder, toLedger ? address(this) : holder, units, asset, paid, paid, toLedger);
    }

    function _finalPrice(ISettlementOracle oracle, address underlying, uint40 expiry)
        private
        returns (bool isFinal, uint256 price)
    {
        try oracle.settlementPrice(underlying, expiry) returns (V2Types.SettlementStatus status, uint256 p) {
            if (status == V2Types.SettlementStatus.Finalized) return (true, p);
        } catch {}
        try oracle.finalize(underlying, expiry) returns (bool finalized, uint256 p) {
            if (finalized) return (true, p);
        } catch {}
        return (false, 0);
    }

    function _mayRedeem(address holder, address caller) private view returns (bool) {
        return caller == holder || !_prefs[holder].noThirdPartyRedeem || isOperator[holder][caller];
    }

    function _known(uint256 longId) private view returns (V2Types.Series storage s) {
        s = _series[longId];
        if (s.underlying == address(0)) revert V2Errors.UnknownSeries();
    }

    function _checkConfig(V2Types.MarketConfig calldata cfg) private view {
        if (cfg.strikeTick == 0 || cfg.strikeTick % V2Constants.PRICE_TICK != 0) revert V2Errors.BadStrike();
        if (cfg.exerciseFeeBps > V2Constants.EXERCISE_FEE_CEIL_BPS) revert V2Errors.CeilingExceeded();
        if (cfg.mintFeePpm > V2Constants.MINT_FEE_CEIL_PPM) revert V2Errors.CeilingExceeded();
        if (cfg.oracle.code.length == 0) revert V2Errors.NoSource();
    }

    function _tryTransfer(address asset, address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = asset.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (uint256)) == 1));
    }

    function _single(uint256 value) private pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = value;
    }
}
