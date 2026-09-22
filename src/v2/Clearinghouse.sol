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
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IClearinghouse} from "./interfaces/IClearinghouse.sol";
import {IExpiryCalendar} from "./interfaces/IExpiryCalendar.sol";
import {IKeeperRewards} from "./interfaces/IKeeperRewards.sol";
import {IPayoutAdapter} from "./interfaces/IPayoutAdapter.sol";
import {ISettlementOracle} from "./interfaces/ISettlementOracle.sol";
import {V2Constants} from "./interfaces/V2Constants.sol";
import {V2Errors} from "./interfaces/V2Errors.sol";
import {V2Ids} from "./interfaces/V2Ids.sol";
import {V2Types} from "./interfaces/V2Types.sol";
import {OptionMath} from "./lib/OptionMath.sol";
import {Managed} from "./access/Managed.sol";

/// @title Clearinghouse
/// @notice The v2 options clearinghouse: one ERC-1155 for every market (ADR-01, ADR-02, architecture §3.5). Writers
///         lock collateral from an internal ledger and mint fungible long and short tokens of a shared series; at
///         expiry the series settles on the SettlementOracle's price, and anyone can push every holder's payout.
/// @dev UNITS (ADR-04). ERC-1155 amounts are 0.01-share units. Prices and strikes are USDG base units (6 dp) per whole
///      share. Ledger, locked and fee amounts are base units of the asset they are keyed by. A call locks UNIT = 1e16
///      underlying base units per unit; a put locks strike / 100 USDG base units per unit.
///
///      COLLATERAL RENT IS A REGISTERED DIAL AND v8 LAUNCHES IT AT ZERO ON EVERY MARKET (c05). It is not removed:
///      the whole path below is compiled and live and `mintFeePpm` is per market, but a non-zero rate is REFUSED AT
///      REGISTRATION unless an operator sets the allow-rent flag (RegisterMarkets.s.sol `preflightMarket` and
///      VerifyV8.s.sol `_market`, both `ppm == 0 || rentAllowed(...)`); the shipped registry sets it false. That is a
///      deploy-time gate, not a contract invariant: `setMarketFees` can still raise the rate on chain later, on the
///      MARKET_FEE_MANAGER lane's 72 h delay. When it IS non-zero: {mint} charges the writer rent on the collateral
///      the pair locks, for the time left to expiry, at the series' pinned `mintFeePpm`; {close} pays back the part
///      that was not used; {settle} accrues what a series still holds to `accruedFees`. The fee is charged wherever a
///      mint comes from, so it cannot be avoided by minting outside the book, and it is a per-asset liability of this
///      contract while it is held: per asset, `balance == SUM free + SUM locked + SUM mintFeesHeld (unsettled series)
///      + accruedFees` (invariant I2', V2-ACCOUNTING §10). Because rent comes out of FREE collateral and never out of
///      the locked collateral, `locked`, the settlement identity and every payout below are exactly what they were in
///      v6, at any rate.
///
///      SETTLEMENT IS CASH VALUE PAID FROM THE COLLATERAL, WITH NO ASSIGNMENT. Every unit of a series settles
///      identically (OptionMath.settlementPerUnit): the long gets gross - fee, the exercise fee goes to accruedFees, the
///      short gets collateral - gross, and the three add up to collateralPerUnit exactly. Since the long and short
///      supplies are equal at settlement (both are only minted and burned in pairs before it), redeeming every holder
///      pays out `locked` to the base unit, whatever order the redemptions come in.
///
///      TRUST MODEL (ADR-09, INTERFACE_VERSION 8). Roles live on one AccessManager, not here. LISTING registers and
///      lists markets; MARKET_FEE_MANAGER moves fee dials; CONFIG_ADMIN moves oracle/calendar/adapter/minter pointers;
///      TREASURY_ADMIN moves the fee recipient; GUARDIAN pauses series creation and mints. Nothing those roles can do
///      moves, freezes or seizes collateral or tokens: close, redeem, withdraw, settle and ERC-1155 transfers have no
///      pause, and a series pins its oracle and exercise fee at creation, and has the oracle pin the settlement
///      configuration of its expiry ({createSeries}).
///      The payout adapter is the one pointer that touches payouts, and the Clearinghouse verifies what it delivers
///      (see {convertPayout}), so a bad adapter can cost a holder at most min(maxPayoutSlippageBps + MAX_ROUTE_FEE_BPS,
///      MAX_PAYOUT_SLIPPAGE_CEIL_BPS) of one payout ({_conversionFloor}).
///
///      REENTRANCY. Every state-changing external, including the inherited ERC-1155 transfer and approval entry points,
///      holds the transient guard. The two external functions only this contract may call ({batchRedeemOne},
///      {convertPayout}) deliberately do not: they exist so {redeemBatch} and the USDG conversion can run under
///      try/catch while the outer call already holds the guard; a guarded inner call would always revert and silently
///      turn every conversion into an in-kind payout (the regression tests pin this).
///
///      LOG ORDER (02-interfaces §1.8, v3). {mint} emits TransferSingle(long), TransferSingle(short), then Minted, and
///      runs the ERC-1155 acceptance callbacks only after all three. No path here emits TransferBatch; only a caller's
///      own safeBatchTransferFrom does. The `operator` of a TransferSingle is the frame's msg.sender: the keeper for a
///      direct {redeem}, this contract for a redemption inside {redeemBatch}.
contract Clearinghouse is IClearinghouse, ERC1155Supply, Managed, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice {minRedeemPayout} at deploy: 1.00 USDG of value, USDG base units.
    /// @dev Bounties are sized near gas cost (~0.05 USDG); paying one for pushing a smaller payout would make dust
    ///      positions worth farming.
    uint96 public constant DEFAULT_MIN_REDEEM_PAYOUT = 1_000_000;

    /// @dev Base units of one whole share of an 18-dp underlying: UNIT * UNITS_PER_SHARE.
    uint256 private constant SHARE = V2Constants.UNIT * V2Constants.UNITS_PER_SHARE;

    /// @dev Gas forwarded to the payout adapter's routeFeeBps read ({_conversionFloor}). UniV3PayoutAdapter answers
    ///      from one storage slot; an adapter that needs more reads as a zero route fee (the tighter floor).
    uint256 private constant ROUTE_FEE_READ_GAS = 30_000;

    /// @dev Gas forwarded to the series oracle's trySpot read ({_floorPrice}); a read that needs more counts as no
    ///      spot. SIZED BY MEASUREMENT, NOT BY REASONING (T-OP-080). The first value, 150_000, was measured when
    ///      `trySpot` read ONE source (under 60k Chainlink-first, under 120k pool-first, cold, on a 4663 fork).
    ///      T-OP-061 made an old Chainlink print -- the state every launch redemption after the close is in -- ALSO
    ///      read the pool source's `latest`, and that two-source read measured within 1 % of the old cap. Re-measured
    ///      COLD (every account cooled first) on a fork of 4663 at block 69266235, contracts `b77280a5`, from
    ///      `V2ForkTest.test_fork_spotReadGas_*`, caller-side delta / callee frame (`vm.lastCallGas`):
    ///        - young print, one source read ................ 61_100 / 58_054
    ///        - single-source market, old print ............. 61_117 / 58_071
    ///        - old print, pool agrees (the launch state) ... 154_388 / 151_341
    ///        - old print, pool disagrees ................... 154_400 / 151_353
    ///      Rule: max measured x 1.5, rounded up to 10_000: 154_400 x 1.5 = 231_600 -> 240_000. The cap stays -- it
    ///      is the bounded-trust guard, not a budget; only its size follows the read it guards.
    uint256 private constant SPOT_READ_GAS = 240_000;

    /// @dev How long after expiry a redemption by a third party may still convert on the settlement price alone when
    ///      no ok spot can be read. Inside the grace "no ok spot" means the market's own spotMaxAge has passed with
    ///      nothing printed, which is already far longer than STALE_SPOT_GRACE + SETTLEMENT_WINDOW.
    uint256 private constant STALE_SPOT_GRACE = 30 minutes;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IClearinghouse
    address public immutable usdg;

    /// @inheritdoc IClearinghouse
    address public calendar;

    /// @inheritdoc IClearinghouse
    address public feeRecipient;

    /// @notice The PayoutAdapter that converts ITM call payouts to USDG; address(0) pays every call in kind.
    address public payoutAdapter;
    /// @notice The largest shortfall below value at the floor price (the settlement price, or an ok spot above it) a
    ///         conversion may have beyond the route's pool fee, bps (<= MAX_PAYOUT_SLIPPAGE_CEIL_BPS; the fee-inclusive
    ///         total is capped there too, INTERFACE_VERSION 6). Packed with {payoutAdapter}: redeem reads both in one
    ///         slot.
    uint16 public maxPayoutSlippageBps;
    /// @notice GUARDIAN lane switch ({setCreatePaused}, no delay): true blocks {createSeries} for new ids in every
    ///         market.
    bool public createPaused;

    /// @notice Bounty payer for SETTLE and REDEEM; address(0) pays nothing.
    IKeeperRewards public keeperRewards;

    /// @notice A redemption pays its caller the REDEEM bounty only when the payout is worth at least this much at the
    ///         settlement price, USDG base units (and never for a zero payout); {settle} pays the SETTLE bounty only
    ///         when the series' collateral is worth at least this much at the settlement price. uint96 so it shares {keeperRewards}'s
    ///         slot: every redemption that may pay a bounty reads both.
    uint96 public minRedeemPayout;

    /// @dev ERC-1155 metadata base; {uri} appends the decimal id. The web app serves the JSON.
    string private _baseUri;

    /// @dev Market rows. A market is registered iff strikeTick != 0 (registration and every config change require it).
    mapping(address underlying => V2Types.MarketConfig) private _markets;

    /// @dev Series by long id. A series exists iff underlying != address(0) (a market's underlying is never zero).
    mapping(uint256 longId => V2Types.Series) private _series;

    /// @inheritdoc IClearinghouse
    /// @dev Maintained on every long mint and burn, so it always equals the sum of totalSupply(longId) over the series
    ///      of (underlying, expiry).
    mapping(address underlying => mapping(uint40 expiry => uint256)) public openInterest;

    /// @inheritdoc IClearinghouse
    mapping(address account => mapping(address asset => uint256)) public free;

    /// @inheritdoc IClearinghouse
    mapping(address asset => uint256) public accruedFees;

    /// @inheritdoc IClearinghouse
    mapping(address account => mapping(address operator => bool)) public isOperator;

    /// @dev Per-account payout preferences, one slot. `noThirdPartyRedeem` is stored inverted so the default (all
    ///      false) is the documented default: convert, pay the wallet, anyone may redeem.
    struct Prefs {
        bool inKind;
        bool toLedger;
        bool noThirdPartyRedeem;
    }

    mapping(address account => Prefs) private _prefs;

    /// @inheritdoc IClearinghouse
    /// @dev INTERFACE_VERSION 8. Declared AFTER `_series`, like every other v8 addition, so the slot the tests pin
    ///      (`SERIES_SLOT = 12`) and every slot the v7 monitor reads keep their positions.
    mapping(address minter => bool) public isMinter;

    /// @inheritdoc IClearinghouse
    /// @dev INTERFACE_VERSION 8. Copied into every market at {registerMarket}; zero makes registration revert
    ///      `NoSource`. Packed with the two default fee dials below: registration reads all three in one slot.
    address public defaultOracle;
    /// @dev INTERFACE_VERSION 8. Default MarketConfig.exerciseFeeBps of a newly registered market.
    uint16 private _defaultExerciseFeeBps;
    /// @dev INTERFACE_VERSION 8. Default MarketConfig.mintFeePpm of a newly registered market; 0 at launch on every
    ///      market (owner decision V3-D18: no writer rent, the dial stays).
    uint32 private _defaultMintFeePpm;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice The CONFIG_ADMIN lane pointed NEW series at `calendar` (existing series keep their expiry).
    event CalendarSet(address indexed calendar);
    /// @notice The CONFIG_ADMIN lane set the bounty payer (address(0) disables bounties).
    event KeeperRewardsSet(address indexed keeperRewards);
    /// @notice The LISTING lane set the REDEEM and SETTLE bounty threshold, USDG base units of value.
    event MinRedeemPayoutSet(uint256 amount);
    /// @notice The LISTING lane set the ERC-1155 metadata base URI.
    event BaseUriSet(string baseUri);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param authority_ AccessManager that gates every `restricted` setter. Code-less reverts `NoSource`.
    /// @param usdg_ USDG: must be a contract reporting 6 decimals (UnsupportedAsset).
    /// @param calendar_ IExpiryCalendar for new series: must be a contract (BadExpiry).
    /// @param feeRecipient_ Receiver of swept exercise fees, non-zero (NotAuthorized). At v8 deploy this is the
    ///        FeeSplitter; the constructor does not type-check it.
    /// @param baseUri_ ERC-1155 metadata base; {uri} appends the decimal token id.
    constructor(address authority_, address usdg_, address calendar_, address feeRecipient_, string memory baseUri_)
        ERC1155("")
        Managed(authority_)
    {
        // Same refusal as {setFeeRecipient} (SEC-22): the field has one meaning, so it gets one rule. Reaching
        // this with the contract's own address takes a CREATE2 preimage, but an asymmetric guard is the kind a
        // later reader trusts in the wrong direction.
        if (feeRecipient_ == address(0) || feeRecipient_ == address(this)) revert V2Errors.NotAuthorized();
        (bool ok, uint256 dec) = _decimalsOf(usdg_);
        if (!ok || dec != 6) revert V2Errors.UnsupportedAsset();
        if (calendar_.code.length == 0) revert V2Errors.BadExpiry();
        usdg = usdg_;
        calendar = calendar_;
        feeRecipient = feeRecipient_;
        minRedeemPayout = DEFAULT_MIN_REDEEM_PAYOUT;
        _baseUri = baseUri_;
        emit CalendarSet(calendar_);
        emit FeeRecipientSet(feeRecipient_);
        emit MinRedeemPayoutSet(DEFAULT_MIN_REDEEM_PAYOUT);
        emit BaseUriSet(baseUri_);
    }

    /*//////////////////////////////////////////////////////////////
               MARKETS, INTERFACE_VERSION 8 (03-INTERFACES §2.1)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IClearinghouse
    /// @dev THE ONLY TOKEN CHECK IS `decimals() == 18`; NOTHING HERE PROVES THE TOKEN TRANSFERS EXACTLY. Every outflow
    ///      ({withdraw}, a redemption's transfer, {sweepFees}) books exactly `amount`, and only {deposit} and
    ///      {convertPayout} measure a balance, so invariant I2' holds for a market only while a transfer of its
    ///      underlying debits this contract exactly the amount sent and its balance never moves on its own. A fee the
    ///      RECIPIENT absorbs does not break it: the debit here is still `amount`. A token that charges the SENDER on
    ///      top, rebases down, or lets its issuer burn from this address does, and the shortfall is then paid out of
    ///      other holders' collateral of that token. That is a LISTING trust assumption, not an enforced one. The
    ///      contract cannot probe at registration: it holds none of the token yet ({deposit} refuses it until now),
    ///      and on the delayed LISTING lane the caller may be the AccessManager itself (`execute`), which holds
    ///      nothing either. No probe here could see a later rebase, wipe or upgrade of an issuer proxy anyway. The
    ///      gate is off chain: script/v2/RegisterMarkets.s.sol `probeTransfers` simulates a deposit and a withdrawal
    ///      on a fork before it sends anything and refuses a token that does not move exactly the amount. A LISTING
    ///      call made outside that script skips it. ClearinghouseMarkets.t.sol pins both halves of this paragraph.
    function registerMarket(address underlying, uint64 strikeTick, bool enabled) external nonReentrant restricted {
        if (_markets[underlying].strikeTick != 0) revert V2Errors.UnsupportedAsset();
        (bool ok, uint256 dec) = _decimalsOf(underlying);
        if (!ok || dec != 18) revert V2Errors.UnsupportedAsset();
        V2Types.MarketConfig memory cfg = V2Types.MarketConfig({
            enabled: enabled,
            mintPaused: false, // a v8 market always registers unpaused; only the guardian pauses
            strikeTick: strikeTick,
            exerciseFeeBps: _defaultExerciseFeeBps,
            oracle: defaultOracle,
            mintFeePpm: _defaultMintFeePpm
        });
        _checkConfigMemory(cfg);
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
        restricted
    {
        V2Types.MarketConfig storage m = _registered(underlying);
        _checkFees(exerciseFeeBps, mintFeePpm);
        m.exerciseFeeBps = exerciseFeeBps;
        m.mintFeePpm = mintFeePpm;
        emit MarketConfigSet(underlying, m);
    }

    /// @inheritdoc IClearinghouse
    function setMarketOracle(address underlying, address oracle) external nonReentrant restricted {
        V2Types.MarketConfig storage m = _registered(underlying);
        _requireSettlementOracle(oracle);
        m.oracle = oracle;
        emit MarketConfigSet(underlying, m);
    }

    /// @inheritdoc IClearinghouse
    function setDefaultMarketFees(uint16 exerciseFeeBps, uint32 mintFeePpm) external nonReentrant restricted {
        _checkFees(exerciseFeeBps, mintFeePpm);
        _defaultExerciseFeeBps = exerciseFeeBps;
        _defaultMintFeePpm = mintFeePpm;
        emit DefaultMarketFeesSet(exerciseFeeBps, mintFeePpm);
    }

    /// @inheritdoc IClearinghouse
    function setDefaultOracle(address oracle) external nonReentrant restricted {
        _requireSettlementOracle(oracle);
        defaultOracle = oracle;
        emit DefaultOracleSet(oracle);
    }

    /// @inheritdoc IClearinghouse
    function setMinter(address minter, bool allowed) external nonReentrant restricted {
        isMinter[minter] = allowed;
        emit MinterSet(minter, allowed);
    }

    /// @inheritdoc IClearinghouse
    function defaultMarketFees() external view returns (uint16 exerciseFeeBps, uint32 mintFeePpm) {
        return (_defaultExerciseFeeBps, _defaultMintFeePpm);
    }

    /// @dev The market row of a REGISTERED underlying (`UnsupportedAsset` otherwise). Shared by the three per-market
    ///      v8 setters, each of which writes only its own fields and never touches the guardian's `mintPaused`.
    function _registered(address underlying) private view returns (V2Types.MarketConfig storage m) {
        m = _markets[underlying];
        if (m.strikeTick == 0) revert V2Errors.UnsupportedAsset();
    }

    /// @dev The fee half of {_checkConfig}, shared by the per-market and the default fee setters.
    function _checkFees(uint16 exerciseFeeBps, uint32 mintFeePpm) private pure {
        if (exerciseFeeBps > V2Constants.EXERCISE_FEE_CEIL_BPS) revert V2Errors.CeilingExceeded();
        if (mintFeePpm > V2Constants.MINT_FEE_CEIL_PPM) revert V2Errors.CeilingExceeded();
    }

    /// @dev {_checkConfig} over a memory tuple, for the composed configuration {registerMarket} stores. Identical
    ///      bounds, identical errors, identical order.
    function _checkConfigMemory(V2Types.MarketConfig memory cfg) private view {
        if (cfg.strikeTick == 0 || cfg.strikeTick % V2Constants.PRICE_TICK != 0) revert V2Errors.BadStrike();
        _checkFees(cfg.exerciseFeeBps, cfg.mintFeePpm);
        _requireSettlementOracle(cfg.oracle);
    }

    /// @dev THE ONLY IN-CONTRACT BOUND ON "THIS ADDRESS IS THE SETTLEMENT ORACLE", and it is worth being exact
    ///      about what it does and does not buy (SEC-07).
    ///
    ///      WHAT IT CATCHES: a pointer that is not an oracle at all -- the zero address, an EOA, a token, the
    ///      book, a Safe, a mistyped address that happens to hold code. `code.length` alone caught only the
    ///      first two of those. The probe additionally requires the candidate to ANSWER the oracle's own
    ///      surface with a sane value, which no unrelated contract does by accident.
    ///
    ///      WHAT IT DOES NOT CATCH, stated plainly because the row this comes from is really about this case:
    ///      A CONTRACT THAT IMPLEMENTS {ISettlementOracle} AND LIES. A compromised CONFIG_ADMIN can still point
    ///      a market at a hostile oracle that answers every call correctly and returns attacker-chosen
    ///      settlement prices. No check inside this contract can distinguish that from the real oracle --
    ///      the published address is not knowable here, there is no registry to consult, and
    ///      {SettlementOracle} implements no ERC-165, so an `interfaceId` check would fail closed against
    ///      the REAL oracle and make this setter uncallable. The controls that actually bound that case are
    ///      external and deliberate: the AccessManager's 24 h delay on the role, guardian cancellation
    ///      within it, and series-level pinning (`createSeries` copies `m.oracle` into the series and
    ///      {settle} reads `s.oracle`), which confines any switch to series created AFTER it.
    ///
    ///      THE PROBE IS A STATICCALL AND FAILS CLOSED. `SETTLEMENT_WINDOW` is a constant on the real oracle
    ///      and on the doubles that stand in for one: {MockSettlementOracle}, `BookOracleStub`
    ///      (test/v2/unit/OrderBookBase.t.sol) and `RevertingOracle` (test/v2/invariant/V2Invariant.t.sol).
    ///      It is NOT on every double in this repo, and two kinds deliberately lack it. The negative doubles
    ///      exist to pin this probe's failing half: `NotAnOracle` answers nothing and `ZeroWindowOracle`
    ///      answers zero (both test/v2/unit/ClearinghouseMarkets.t.sol). And doubles that are not settlement
    ///      oracles at all never declare it -- `MockSpot` in test/v2/unit/FeeSplitter.t.sol and
    ///      test/v2/unit/Hedger.t.sol, {MockMorphoOracle} -- which is correct, because none of them is ever
    ///      handed to this setter. So a candidate that reverts, returns nothing, returns zero, or is not a
    ///      contract is refused with the same `NoSource` these setters already used.
    function _requireSettlementOracle(address oracle) private view {
        if (oracle.code.length == 0) revert V2Errors.NoSource();
        try ISettlementOracle(oracle).SETTLEMENT_WINDOW() returns (uint32 window) {
            if (window == 0) revert V2Errors.NoSource();
        } catch {
            revert V2Errors.NoSource();
        }
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSES (GUARDIAN)
    //////////////////////////////////////////////////////////////*/

    /// @notice Pauses or resumes {mint} for one market. GUARDIAN lane, no delay. New risk only: close and redeem are
    ///         unaffected.
    /// @param underlying Registered underlying (UnsupportedAsset otherwise).
    /// @param paused True to pause.
    function setMintPaused(address underlying, bool paused) external nonReentrant restricted {
        V2Types.MarketConfig storage m = _markets[underlying];
        if (m.strikeTick == 0) revert V2Errors.UnsupportedAsset();
        m.mintPaused = paused;
        emit MintPausedSet(underlying, paused);
    }

    /// @notice Pauses or resumes {createSeries} for new ids in every market. GUARDIAN lane, no delay.
    /// @param paused True to pause.
    function setCreatePaused(bool paused) external nonReentrant restricted {
        createPaused = paused;
        emit CreatePausedSet(paused);
    }

    /*//////////////////////////////////////////////////////////////
            POINTERS (CONFIG_ADMIN, TREASURY_ADMIN, LISTING)
    //////////////////////////////////////////////////////////////*/

    /// @notice Points NEW series at another calendar. CONFIG_ADMIN lane, 24 h delay.
    /// @param calendar_ IExpiryCalendar contract (BadExpiry when it has no code).
    function setCalendar(address calendar_) external nonReentrant restricted {
        if (calendar_.code.length == 0) revert V2Errors.BadExpiry();
        calendar = calendar_;
        emit CalendarSet(calendar_);
    }

    /// @notice Sets the receiver of swept exercise fees. TREASURY_ADMIN lane, 24 h delay.
    /// @dev SEC-22. THIS CONTRACT IS REFUSED AS WELL AS ZERO. {sweepFees} zeroes `accruedFees[asset]` and then
    ///      transfers to the recipient; with the recipient set here, that transfer is a self-transfer that moves
    ///      nothing, so one sweep strands every accrued fee permanently -- the tokens stay in the contract with
    ///      nothing left to claim them, and invariant I2' silently flips from balance == sum of claims to
    ///      balance > sum of claims. Zero fails loudly on the next sweep; this one fails SILENTLY, which is worse.
    /// @param recipient Non-zero, and not this contract (NotAuthorized).
    function setFeeRecipient(address recipient) external nonReentrant restricted {
        if (recipient == address(0) || recipient == address(this)) revert V2Errors.NotAuthorized();
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    /// @notice Sets the PayoutAdapter and the conversion slippage bound. CONFIG_ADMIN lane, 24 h delay.
    /// @dev CeilingExceeded above MAX_PAYOUT_SLIPPAGE_CEIL_BPS. address(0) turns conversion off (every ITM call long is
    ///      paid in kind). An adapter is not trusted with more than one payout at a time: see {convertPayout}. The
    ///      bound is measured above each route's pool fee: a conversion floor is value at the floor price (the
    ///      settlement price, or an ok spot above it: {_floorPrice}) less min(maxSlippageBps + the adapter's
    ///      routeFeeBps (<= MAX_ROUTE_FEE_BPS), MAX_PAYOUT_SLIPPAGE_CEIL_BPS) (INTERFACE_VERSION 6, {_conversionFloor}).
    /// @param adapter IPayoutAdapter, or address(0).
    /// @param maxSlippageBps Largest accepted shortfall below value at the floor price beyond the route's pool fee,
    ///        bps.
    function setPayoutAdapter(address adapter, uint16 maxSlippageBps) external nonReentrant restricted {
        if (maxSlippageBps > V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS) revert V2Errors.CeilingExceeded();
        payoutAdapter = adapter;
        maxPayoutSlippageBps = maxSlippageBps;
        emit PayoutAdapterSet(adapter, maxSlippageBps);
    }

    /// @notice Sets the bounty payer. CONFIG_ADMIN lane, 24 h delay. This contract must be registered there as a
    ///         caller.
    /// @param rewards KeeperRewards contract (NoSource when non-zero without code), or address(0) to pay nothing.
    function setKeeperRewards(address rewards) external nonReentrant restricted {
        if (rewards != address(0) && rewards.code.length == 0) revert V2Errors.NoSource();
        keeperRewards = IKeeperRewards(rewards);
        emit KeeperRewardsSet(rewards);
    }

    /// @notice Sets the REDEEM and SETTLE bounty threshold. LISTING lane, 1 h delay.
    /// @param amount USDG base units of value at the settlement price: of the payout for REDEEM, of the series'
    ///        collateral for SETTLE.
    function setMinRedeemPayout(uint96 amount) external nonReentrant restricted {
        minRedeemPayout = amount;
        emit MinRedeemPayoutSet(amount);
    }

    /// @notice Sets the ERC-1155 metadata base URI. LISTING lane, 1 h delay.
    /// @param baseUri_ Base; {uri} returns it followed by the decimal token id.
    function setBaseUri(string calldata baseUri_) external nonReentrant restricted {
        _baseUri = baseUri_;
        emit BaseUriSet(baseUri_);
    }

    /*//////////////////////////////////////////////////////////////
                                 SERIES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IClearinghouse
    /// @dev An existing id returns before any pause, market or time check: re-creating a live series adds no risk, and
    ///      the AutoRoller and cranker call this blindly. Checks, in order: MarketDisabled, CreatePaused, BadStrike (zero
    ///      or off the market tick), BadExpiry (lead and tenor first, then the calendar), BadStrike (spot band). A
    ///      trySpot that reverts or reports not ok, or a zero spot, skips the band: the band is a fat-finger check,
    ///      not a dependency, and the calendar and strike grid still apply.
    ///      Then the series is stored and `oracle.pin(underlying, expiry)` fixes the settlement configuration of the
    ///      expiry (INTERFACE_VERSION 6): the oracle copies it on the first series and returns at once after that. Unlike
    ///      the spot band, pin is a dependency: it is a typed call and its revert (NoSource on a market without
    ///      sources, NotAuthorized when the oracle does not name this Clearinghouse, SourceNotPinned when a source
    ///      cannot pin, PinMismatch when the expiry was pinned through another Clearinghouse pointer to something
    ///      other than the current configuration) reverts the creation, because a series on an unpinned or hidden
    ///      configuration is the one the admin could re-price. The guard is held, so the oracle and its sources cannot
    ///      re-enter. LOG ORDER: the oracle's SettlementConfigPinned and each source's pin log (first series of the
    ///      expiry only), then SeriesCreated.
    function createSeries(address underlying, bool isPut, uint128 strike, uint40 expiry)
        external
        nonReentrant
        returns (uint256 longId)
    {
        longId = V2Ids.longIdOf(underlying, isPut, strike, expiry);
        V2Types.Series storage s = _series[longId];
        if (s.underlying != address(0)) {
            // The id drops the hash's low bit, so two tuples share an id with probability 2^-255. One compare removes
            // the question instead of arguing about it.
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
            if (ok && spot != 0) {
                // strike <= spot * 2, written so a spot beyond uint128 (where it always holds) cannot overflow.
                bool aboveBand = spot <= type(uint128).max && strike > spot * 2;
                if (strike < spot / 2 || aboveBand) revert V2Errors.BadStrike();
            }
        } catch {}

        s.underlying = underlying;
        s.isPut = isPut;
        s.expiry = expiry;
        s.strike = strike;
        s.oracle = m.oracle;
        s.exerciseFeeBps = m.exerciseFeeBps;
        s.mintFeePpm = m.mintFeePpm;
        ISettlementOracle(m.oracle).pin(underlying, expiry);
        emit SeriesCreated(longId, underlying, isPut, strike, expiry, m.oracle, m.exerciseFeeBps, m.mintFeePpm);
    }

    /*//////////////////////////////////////////////////////////////
                                 LEDGER
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IClearinghouse
    /// @dev Credits the measured balance delta, so a token that delivers less than `amount` credits what arrived. An
    ///      asset is supported iff it is USDG or a registered underlying, including one whose market is disabled.
    /// @dev SEC-49. `to` MAY NOT BE THIS CONTRACT. The ledger is withdrawn by `msg.sender` only ({withdraw}), and
    ///      this contract never calls {withdraw} on itself, so a credit to `free[address(this)]` can never be spent
    ///      by anyone: it is bricked dust that also overstates the ledger against the balance. Refusing it costs a
    ///      caller nothing -- there is no reason to credit the house -- and it is the only recovery path there is,
    ///      because there is none after the fact. NOT DECLARED ON {IClearinghouse.deposit}, whose NatSpec is
    ///      outside this task's scope_paths; the interface currently under-describes this guard.
    function deposit(address asset, uint256 amount, address to) external nonReentrant {
        if (to == address(this)) revert V2Errors.NotAuthorized();
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
        unchecked {
            free[msg.sender][asset] = have - amount;
        }
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
    /// @dev With toLedger a converted call payout is credited as USDG and an in-kind one as the underlying; a ledger
    ///      credit never fails, so no transfer is attempted.
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
    /// @dev `longTo` must be non-zero (ERC1155InvalidReceiver). Every state change and all three logs happen before
    ///      the acceptance callbacks (long receiver first, then the writer), and a callback that re-enters this
    ///      contract hits the guard.
    ///      COLLATERAL RENT (INTERFACE_VERSION 7, c05). On top of the collateral the pair locks, the writer pays
    ///      `ceil(collateral x series.mintFeePpm x (expiry - now) / (PPM x MINT_FEE_PERIOD))` out of the SAME free
    ///      ledger balance, and the series holds it in `mintFeesHeld` until {close} refunds it pro rata or {settle}
    ///      accrues it. The base contains nothing the writer chooses except size and tenor and no fill price, so every
    ///      route to a mint pays exactly the same for the same units in the same block. Mint is gated by the
    ///      {setMinter} allowlist (`isMinter`, checked first below), so which routes exist is a deployment fact, not
    ///      something this contract fixes: the allowlist is set by script/v2/DeployV8.s.sol (`setMinter` in its
    ///      wiring). With only the book allowlisted, every mint happens inside a fill -- an AskWrite hit or a
    ///      `writeToSell`, including AutoRoller and MakerVault asks. Rent never touches the LOCKED
    ///      collateral, so {locked}, the settlement identity and every payout are as they were in v6. The cutoff check
    ///      above guarantees `expiry - block.timestamp > SETTLEMENT_WINDOW`, so the subtraction cannot underflow and
    ///      the rent of a live mint is never 0 while the rate is not.
    function mint(uint256 longId, uint64 units, address writer, address longTo) external nonReentrant {
        if (!isMinter[msg.sender]) revert V2Errors.NotMinter();
        if (msg.sender != writer && !isOperator[writer][msg.sender]) revert V2Errors.NotAuthorized();
        V2Types.Series storage s = _series[longId];
        address underlying = s.underlying;
        if (underlying == address(0)) revert V2Errors.UnknownSeries();
        V2Types.MarketConfig storage m = _markets[underlying];
        if (!m.enabled) revert V2Errors.MarketDisabled();
        if (m.mintPaused) revert V2Errors.MintPaused();
        uint40 expiry = s.expiry;
        if (block.timestamp >= expiry - V2Constants.SETTLEMENT_WINDOW) revert V2Errors.PastCutoff();
        if (units == 0) revert V2Errors.BadUnits();
        if (longTo == address(0)) revert ERC1155InvalidReceiver(address(0));

        (address asset, uint256 perUnit) = _collateral(s, underlying);
        uint256 need = units * perUnit;
        uint256 fee = OptionMath.mintFee(need, s.mintFeePpm, expiry - block.timestamp);
        uint256 have = free[writer][asset];
        if (have < need + fee) revert V2Errors.InsufficientCollateral(have, need + fee);
        unchecked {
            free[writer][asset] = have - need - fee;
        }
        if (fee != 0) {
            // `mintFeesHeld` is a uint128 and a truncating add would strand rent outside every claim (I2'), so the
            // add is bounded rather than cast blind. CeilingExceeded here means "this series' rent pot is full": it
            // is unreachable with any real collateral asset -- the rate is at most MINT_FEE_CEIL_PPM of collateral a
            // writer had to hold -- and is a revert rather than a silent loss if a token ever makes it reachable.
            uint256 nextHeld = uint256(s.mintFeesHeld) + fee;
            if (nextHeld > type(uint128).max) revert V2Errors.CeilingExceeded();
            // casting to uint128 is safe because nextHeld was just bounded
            // forge-lint: disable-next-line(unsafe-typecast)
            s.mintFeesHeld = uint128(nextHeld);
        }
        openInterest[underlying][expiry] += units;

        uint256 shortId = V2Ids.shortIdOf(longId);
        (uint256[] memory ids, uint256[] memory values) = _singletons(longId, units);
        _update(address(0), longTo, ids, values);
        ids[0] = shortId;
        _update(address(0), writer, ids, values);
        emit Minted(longId, writer, longTo, units, need, fee);

        ERC1155Utils.checkOnERC1155Received(msg.sender, address(0), longTo, longId, units, "");
        ERC1155Utils.checkOnERC1155Received(msg.sender, address(0), writer, shortId, units, "");
    }

    /// @inheritdoc IClearinghouse
    /// @dev Works after expiry until {settle} succeeds, under every pause flag and whatever the oracle does: it reads
    ///      nothing outside this contract. Burning more than the caller holds reverts ERC1155InsufficientBalance.
    ///      THE RENT REFUND (INTERFACE_VERSION 7, c05). The unused part of the rent those units paid at {mint} --
    ///      `floor(freed x mintFeePpm x (expiry - now) / (PPM x MINT_FEE_PERIOD))`, the same product {mint} ceiled --
    ///      is credited, in the collateral asset, to WHOEVER CLOSES, beside the collateral itself. Net of it the fee
    ///      is rent on open interest x time, so a market maker's write -> buy back -> close round trip costs only the
    ///      seconds the pair was open and two-sided quoting stays viable. At or after expiry, and at rate 0, the
    ///      refund is 0. The clamp to `mintFeesHeld` is unreachable (V2-ACCOUNTING §3.3: every closed unit matches a
    ///      distinct earlier-minted one whose ceiled fee is at least this floored refund) and is kept only so that no
    ///      arithmetic here can ever block a close.
    function close(uint256 longId, uint64 units) external nonReentrant {
        V2Types.Series storage s = _series[longId];
        address underlying = s.underlying;
        if (underlying == address(0)) revert V2Errors.UnknownSeries();
        if (s.settled) revert V2Errors.AlreadySettled();
        if (units == 0) revert V2Errors.BadUnits();

        (address asset, uint256 perUnit) = _collateral(s, underlying);
        uint256 freed = units * perUnit;
        uint256 refund;
        uint32 ppm = s.mintFeePpm;
        uint40 expiry = s.expiry;
        if (ppm != 0 && block.timestamp < expiry) {
            refund = OptionMath.mintFeeRefund(freed, ppm, expiry - block.timestamp);
            uint128 held = s.mintFeesHeld;
            if (refund > held) refund = held;
            // casting to 'uint128' is safe because refund was just clamped to the uint128 `held`
            // forge-lint: disable-next-line(unsafe-typecast)
            if (refund != 0) s.mintFeesHeld = held - uint128(refund);
        }
        _burn(msg.sender, longId, units);
        _burn(msg.sender, V2Ids.shortIdOf(longId), units);
        openInterest[underlying][expiry] -= units;
        free[msg.sender][asset] += freed + refund;
        emit Closed(longId, msg.sender, units, freed, refund);
    }

    /*//////////////////////////////////////////////////////////////
                               SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IClearinghouse
    /// @dev UnknownSeries, then an already settled series returns false before the expiry check. A settlementPrice read
    ///      or finalize that reverts counts as "not final" (returns false). A final price above type(uint128).max is
    ///      clamped to it before anything is computed: a revert here would strand every holder of the series forever
    ///      (the oracle cannot change a final price), while at such a price a call is worth its whole collateral and a
    ///      put nothing either way. When finalize runs here the oracle pays no FINALIZE bounty to this contract and none
    ///      is forwarded. The SETTLE bounty goes to msg.sender only when the long supply is > 0 and its collateral, valued
    ///      at the settlement price, is non-zero and worth at least {minRedeemPayout}.
    function settle(uint256 longId) external nonReentrant returns (bool advanced) {
        V2Types.Series storage s = _series[longId];
        address underlying = s.underlying;
        if (underlying == address(0)) revert V2Errors.UnknownSeries();
        if (s.settled) return false;
        uint40 expiry = s.expiry;
        if (block.timestamp < expiry) revert V2Errors.NotExpired();

        (bool isFinal, uint256 price) = _finalPrice(ISettlementOracle(s.oracle), underlying, expiry);
        if (!isFinal) return false;
        if (price > type(uint128).max) price = type(uint128).max;

        (uint256 longPer, uint256 feePer, uint256 shortPer) =
            OptionMath.settlementPerUnit(s.isPut, s.strike, price, s.exerciseFeeBps);
        s.settled = true;
        // casting to 'uint128' is safe: price was clamped above, and every per-unit amount is <= collateralPerUnit <=
        // max(UNIT, strike / 100), which fits uint128 (OptionMath OVERFLOW note)
        // forge-lint: disable-next-line(unsafe-typecast)
        s.settlementPrice = uint128(price);
        // forge-lint: disable-next-line(unsafe-typecast)
        s.longPayoutPerUnit = uint128(longPer);
        // forge-lint: disable-next-line(unsafe-typecast)
        s.feePerUnit = uint128(feePer);
        // forge-lint: disable-next-line(unsafe-typecast)
        s.shortPayoutPerUnit = uint128(shortPer);
        emit SeriesSettled(longId, price, longPer, feePer, shortPer);

        // INTERFACE_VERSION 7 (c05): whatever rent this series still holds is no longer refundable -- {close} is
        // closed to it from here on (AlreadySettled) -- so it becomes protocol revenue now, in the series' collateral
        // asset, and leaves with the exercise fees on the next {sweepFees}. Log order (02-interfaces §1.8):
        // SeriesSettled, then MintFeesAccrued when there is anything to accrue, then the bounty's logs.
        uint256 held = s.mintFeesHeld;
        if (held != 0) {
            s.mintFeesHeld = 0;
            address feeAsset = s.isPut ? usdg : underlying;
            accruedFees[feeAsset] += held;
            emit MintFeesAccrued(longId, feeAsset, held);
        }

        // The SETTLE bounty needs the series' collateral, valued at the settlement price, to be non-zero and worth at
        // least minRedeemPayout, the REDEEM threshold: a dust series would otherwise earn the full bounty and farm the
        // shared daily cap. `supply >= threshold` settles it without the product (every per-unit value here is >= 1),
        // and otherwise supply < threshold <= 2^96 and perUnit <= 2^128, so the product cannot overflow.
        uint256 supply = totalSupply(longId);
        uint256 perUnit = s.isPut ? OptionMath.collateralPerUnit(true, s.strike) : price / V2Constants.UNITS_PER_SHARE;
        uint256 threshold = minRedeemPayout;
        if (supply != 0 && perUnit != 0 && (supply >= threshold || supply * perUnit >= threshold)) {
            _reward(V2Constants.ACTION_SETTLE, msg.sender);
        }
        return true;
    }

    /// @inheritdoc IClearinghouse
    /// @dev A holder with no balance returns (0, isPut) with no log: pushing an already redeemed holder is a no-op.
    function redeem(uint256 tokenId, address holder) external nonReentrant returns (uint256 paid, bool inUsdg) {
        if (!_mayRedeem(holder, msg.sender)) revert V2Errors.ThirdPartyRedeemDisabled();
        return _redeem(tokenId, holder, msg.sender);
    }

    /// @inheritdoc IClearinghouse
    /// @dev Reverts only for the whole id (UnknownSeries, NotSettled). Holders the caller may not redeem (opted out of
    ///      third-party redemption) and holders with no balance are skipped silently; each remaining holder runs in
    ///      its own try/catch frame ({batchRedeemOne}), so a revert there undoes only that holder's burn and payout.
    ///      Duplicates in `holders` are harmless: the second one has no balance.
    function redeemBatch(uint256 tokenId, address[] calldata holders) external nonReentrant returns (uint256 redeemed) {
        V2Types.Series storage s = _series[tokenId & ~uint256(1)];
        if (s.underlying == address(0)) revert V2Errors.UnknownSeries();
        if (!s.settled) revert V2Errors.NotSettled();
        for (uint256 i; i < holders.length; ++i) {
            address holder = holders[i];
            if (!_mayRedeem(holder, msg.sender) || balanceOf(holder, tokenId) == 0) continue;
            try this.batchRedeemOne(tokenId, holder, msg.sender) {
                ++redeemed;
            } catch {}
        }
    }

    /// @notice One holder of {redeemBatch}. Callable only by this contract (NotAuthorized).
    /// @dev External so the batch can wrap it in try/catch; NOT guarded, because {redeemBatch} already holds the guard.
    ///      Authorisation was checked by the batch against its own caller.
    /// @param tokenId Long or short id.
    /// @param holder Account redeemed.
    /// @param keeper The batch caller, who earns the REDEEM bounty.
    /// @return paid Base units delivered (USDG when inUsdg, else the collateral asset).
    /// @return inUsdg True when paid in USDG.
    function batchRedeemOne(uint256 tokenId, address holder, address keeper)
        external
        returns (uint256 paid, bool inUsdg)
    {
        if (msg.sender != address(this)) revert V2Errors.NotAuthorized();
        return _redeem(tokenId, holder, keeper);
    }

    /// @notice Converts one ITM call payout to USDG through the PayoutAdapter. Callable only by this contract
    ///         (NotAuthorized).
    /// @dev External so {redeem} can run it under try/catch: any revert here, including this function's own checks,
    ///      rolls back the approval and whatever the adapter did, and the payout falls back to in kind. NOT guarded:
    ///      the redemption that calls it holds the guard, and a guarded inner call would always revert. While it runs,
    ///      every other state-changing entry point stays locked, so the adapter cannot re-enter anything.
    ///      The adapter is approved for exactly `amount` and the approval is zeroed afterwards. The result is judged by
    ///      balances, never by the adapter's return value: this contract's USDG balance must rise by >= `minOut` and
    ///      its `asset` balance must fall by exactly `amount` (a partial pull would strand the rest). The swap always
    ///      pays this contract, even for a wallet holder, who is then sent `out`: the holder's own balance is no
    ///      measure, since contracts the guard does not cover let anyone push the holder's own USDG to the holder
    ///      during the swap (OrderBook.prune refunding an expired bid, RewardsDistributor.claim), which would let an
    ///      adapter keep the whole payout (sweep contracts-c30). A transfer to the holder that fails reverts here too.
    /// @param asset The call's underlying, 18 dp.
    /// @param amount Underlying base units owed to the holder.
    /// @param minOut USDG base units: value at the floor price ({_floorPrice}) less maxPayoutSlippageBps plus the route
    ///        fee, capped at MAX_PAYOUT_SLIPPAGE_CEIL_BPS ({_conversionFloor}).
    /// @param recipient The holder's wallet, or this contract when the holder is paid to the ledger.
    /// @return out USDG base units the recipient received.
    function convertPayout(address asset, uint256 amount, uint256 minOut, address recipient)
        external
        returns (uint256 out)
    {
        if (msg.sender != address(this)) revert V2Errors.NotAuthorized();
        address adapter = payoutAdapter;
        IERC20 stock = IERC20(asset);
        IERC20 dollar = IERC20(usdg);
        uint256 stockBefore = stock.balanceOf(address(this));
        uint256 usdgBefore = dollar.balanceOf(address(this));

        stock.forceApprove(adapter, amount);
        IPayoutAdapter(adapter).swapToUsdg(asset, amount, minOut, address(this));
        stock.forceApprove(adapter, 0);

        // Checked subtraction: a balance that fell reverts, and so falls back to in kind.
        out = dollar.balanceOf(address(this)) - usdgBefore;
        if (out < minOut) revert V2Errors.BadPrice();
        if (stockBefore - stock.balanceOf(address(this)) != amount) revert V2Errors.BadUnits();
        if (recipient != address(this)) dollar.safeTransfer(recipient, out);
    }

    /*//////////////////////////////////////////////////////////////
                                  FEES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IClearinghouse
    /// @dev Nothing accrued returns without a log. Reverts if the transfer to the recipient fails; the fees then stay
    ///      accrued.
    function sweepFees(address asset) external nonReentrant {
        uint256 amount = accruedFees[asset];
        if (amount == 0) return;
        address to = feeRecipient;
        accruedFees[asset] = 0;
        emit FeesSwept(asset, to, amount);
        IERC20(asset).safeTransfer(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                           ERC-1155 ENTRY POINTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Guarded like every other state-changing entry point: a receiver callback cannot move tokens mid-call.
    function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes memory data)
        public
        override(ERC1155, IERC1155)
        nonReentrant
    {
        super.safeTransferFrom(from, to, id, value, data);
    }

    /// @dev Guarded; see {safeTransferFrom}.
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    ) public override(ERC1155, IERC1155) nonReentrant {
        super.safeBatchTransferFrom(from, to, ids, values, data);
    }

    /// @dev Guarded; see {safeTransferFrom}.
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
    /// @dev UnknownSeries for an id that was never created (including any short id).
    function collateralAsset(uint256 longId) external view returns (address asset) {
        V2Types.Series storage s = _known(longId);
        (asset,) = _collateral(s, s.underlying);
    }

    /// @inheritdoc IClearinghouse
    /// @dev UnknownSeries for an id that was never created.
    function collateralPerUnit(uint256 longId) external view returns (uint256 perUnit) {
        V2Types.Series storage s = _known(longId);
        (, perUnit) = _collateral(s, s.underlying);
    }

    /// @inheritdoc IClearinghouse
    /// @dev UnknownSeries for an id that was never created.
    function mintCutoff(uint256 longId) external view returns (uint40) {
        return _known(longId).expiry - V2Constants.SETTLEMENT_WINDOW;
    }

    /// @inheritdoc IClearinghouse
    /// @dev Derived, not stored. Tokens of a series are only ever minted and burned in long/short pairs before
    ///      settlement ({mint}, {close}) and burned only by redemption after it, so what the series still holds is:
    ///        unsettled: totalSupply(longId) * collateralPerUnit;
    ///        settled:   totalSupply(longId) * (longPayoutPerUnit + feePerUnit) + totalSupply(shortId) * shortPayoutPerUnit,
    ///      i.e. what the unredeemed balances are still owed, which reaches 0 exactly when every holder is redeemed. A
    ///      counter would cost one more SSTORE in every mint, close and redemption to restate those two lines.
    ///      0 for a series that does not exist.
    function locked(uint256 longId) external view returns (uint256) {
        V2Types.Series storage s = _series[longId];
        address underlying = s.underlying;
        if (underlying == address(0)) return 0;
        uint256 longSupply = totalSupply(longId);
        if (!s.settled) {
            (, uint256 perUnit) = _collateral(s, underlying);
            return longSupply * perUnit;
        }
        return longSupply * (uint256(s.longPayoutPerUnit) + s.feePerUnit) + totalSupply(V2Ids.shortIdOf(longId))
            * s.shortPayoutPerUnit;
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
    /// @dev Mirrors {mint} exactly: the same collateral base, the same pinned rate and the same `expiry - now`, ceiled
    ///      the same way. {mint} cannot run at or after the cutoff, so the 0 returned from expiry onwards is only ever
    ///      read by off-chain callers.
    function mintFee(uint256 longId, uint64 units) external view returns (uint256 fee) {
        V2Types.Series storage s = _known(longId);
        uint40 expiry = s.expiry;
        if (block.timestamp >= expiry) return 0;
        (, uint256 perUnit) = _collateral(s, s.underlying);
        return OptionMath.mintFee(uint256(units) * perUnit, s.mintFeePpm, expiry - block.timestamp);
    }

    /// @inheritdoc IClearinghouse
    /// @dev Mirrors {close} exactly, including its clamp to the rent the series still holds: floored, 0 once settled
    ///      or at expiry.
    function closeRefund(uint256 longId, uint64 units) external view returns (uint256 refund) {
        V2Types.Series storage s = _known(longId);
        uint40 expiry = s.expiry;
        if (s.settled || block.timestamp >= expiry) return 0;
        (, uint256 perUnit) = _collateral(s, s.underlying);
        refund = OptionMath.mintFeeRefund(uint256(units) * perUnit, s.mintFeePpm, expiry - block.timestamp);
        uint256 held = s.mintFeesHeld;
        if (refund > held) refund = held;
    }

    /// @inheritdoc IClearinghouse
    function thirdPartyRedeemAllowed(address account) external view returns (bool) {
        return !_prefs[account].noThirdPartyRedeem;
    }

    /// @notice Payout preferences of `account` (see {setPayoutInKind}, {setPayoutToLedger}).
    /// @param account Holder.
    /// @return inKind True when ITM call payouts skip the USDG conversion.
    /// @return toLedger True when payouts are credited to the free ledger.
    function payoutPrefs(address account) external view returns (bool inKind, bool toLedger) {
        Prefs memory p = _prefs[account];
        return (p.inKind, p.toLedger);
    }

    /// @notice The ERC-1155 metadata base URI.
    function baseUri() external view returns (string memory) {
        return _baseUri;
    }

    /// @notice Metadata URI of `id`: the base URI followed by the decimal id (no `{id}` substitution).
    /// @param id Any token id.
    /// @return The URI.
    function uri(uint256 id) public view override returns (string memory) {
        return string.concat(_baseUri, Strings.toString(id));
    }

    /// @notice ERC-165: IClearinghouse, IERC1155, IERC1155MetadataURI, IERC165. No IAccessControl: roles are on the
    ///         manager, not this target.
    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, IERC165) returns (bool) {
        return interfaceId == type(IClearinghouse).interfaceId || super.supportsInterface(interfaceId);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev The redemption of one holder's whole balance (capped at type(uint64).max units per call, the width of the
    ///      Redeemed log; a larger balance simply needs a second call). Authorisation is the caller's job.
    ///
    ///      Effects first: fees, open interest and the burn (which is what lowers {locked}) are written before any
    ///      external call. Then the payout, in this order:
    ///        1. an ITM call long whose holder has not chosen in kind, with an adapter set, a floor price
    ///           ({_floorPrice}, which reads the oracle's spot with a gas-capped staticcall) and a non-zero minOut
    ///           ({_conversionFloor}, which reads the adapter's route fee with a gas-capped staticcall), tries
    ///           {convertPayout} under try/catch (to the wallet, or to this contract for a ledger holder);
    ///        2. otherwise, or when that failed, the collateral asset in kind: a ledger holder is credited, a wallet
    ///           holder gets a raw transfer, and a transfer that fails (paused USDG, blocklisted holder) is credited
    ///           to the ledger instead. The ledger credits after a call are the only writes that follow an
    ///           interaction, and they cannot fail.
    ///      Redeemed.to is where the value went: `holder`, or this contract when credited to the holder's ledger.
    ///      The REDEEM bounty needs a payout worth >= minRedeemPayout at the settlement price, and > 0.
    function _redeem(uint256 tokenId, address holder, address keeper) private returns (uint256 paid, bool inUsdg) {
        uint256 longId = tokenId & ~uint256(1);
        V2Types.Series storage s = _series[longId];
        address underlying = s.underlying;
        if (underlying == address(0)) revert V2Errors.UnknownSeries();
        if (!s.settled) revert V2Errors.NotSettled();
        bool isPut = s.isPut;
        uint256 amount = balanceOf(holder, tokenId);
        if (amount == 0) return (0, isPut);
        if (amount > type(uint64).max) amount = type(uint64).max;
        // casting to 'uint64' is safe because the amount is capped at type(uint64).max above
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 units = uint64(amount);

        address asset = isPut ? usdg : underlying;
        bool isLong = tokenId == longId;
        uint256 owed;
        if (isLong) {
            // uint256 operands: uint64 * uint128 would be evaluated, and overflow, in uint128.
            owed = amount * s.longPayoutPerUnit;
            uint256 fee = amount * s.feePerUnit;
            if (fee != 0) accruedFees[asset] += fee;
            openInterest[underlying][s.expiry] -= units;
        } else {
            owed = amount * s.shortPayoutPerUnit;
        }
        _burn(holder, tokenId, units);

        if (owed == 0) {
            emit Redeemed(tokenId, holder, holder, units, asset, 0, 0, false);
            return (0, isPut);
        }

        Prefs memory prefs = _prefs[holder];
        uint256 value = isPut ? owed : owed * s.settlementPrice / SHARE;
        bool toLedger = prefs.toLedger;
        address delivered = asset;
        paid = owed;
        inUsdg = isPut;

        bool converted;
        if (isLong && !isPut && !prefs.inKind) {
            address adapter = payoutAdapter;
            uint256 minOut;
            if (adapter != address(0)) {
                uint256 floorPrice = _floorPrice(s, underlying, holder, keeper);
                if (floorPrice != 0) minOut = _conversionFloor(adapter, asset, owed * floorPrice / SHARE);
            }
            if (minOut != 0) {
                try this.convertPayout(asset, owed, minOut, toLedger ? address(this) : holder) returns (uint256 out) {
                    converted = true;
                    paid = out;
                    inUsdg = true;
                    delivered = usdg;
                    if (toLedger) free[holder][usdg] += out;
                } catch {}
            }
        }
        if (!converted && (toLedger || !_tryTransfer(asset, holder, owed))) {
            toLedger = true;
            free[holder][asset] += owed;
        }
        emit Redeemed(tokenId, holder, toLedger ? address(this) : holder, units, delivered, paid, owed, toLedger);

        if (value != 0 && value >= minRedeemPayout) _reward(V2Constants.ACTION_REDEEM, keeper);
    }

    /// @dev The price per whole share a conversion floor values the payout at, or 0 when the payout must not convert.
    ///      A pool moved inside the redeeming transaction must not set it, and the settlement price alone does not
    ///      bound a third party's capture once the market has moved since the window: anyone can redeem a default
    ///      holder, push the pool down to the floor, convert and buy back, keeping the move as well as the bound. So:
    ///        - with an ok spot (the series oracle's trySpot ok and non-zero, so observed within the market's own
    ///          spotMaxAge and the oracle not paused), the higher of the settlement price and that spot. INTERFACE_
    ///          VERSION 7 dropped the extra one-hour bound this used to apply on top (owner sign-off c01,
    ///          DECISIONS-2026-09-17 §7): the real feed cadence rarely prints within an hour, so the hour made
    ///          automated redemptions pay in kind, and the market's spotMaxAge is the age the oracle itself settles
    ///          and quotes on. NO TIGHT BOUND holds on the price error a stale-but-ok reading admits: the feed's
    ///          deviation threshold is the condition under which it prints, not a limit on when that print lands on
    ///          chain, and nothing here waits for it, so for up to spotMaxAge the floor can trail the market by
    ///          whatever move the oracle has not yet seen (SEC-10, docs/V8-ACCEPTED-RISKS.md). The floor is never
    ///          below the settlement price, which guards the holder against a lower price only;
    ///        - without one, the settlement price when the caller is the holder or its operator (nobody else can
    ///          sandwich the holder's own call) or it is still within STALE_SPOT_GRACE of expiry (source 0 printed
    ///          nothing since the window began, which does NOT bound the market's move from the settlement price:
    ///          the print the deviation threshold triggers can land after the grace ends, so a third party converts
    ///          at the settlement price and keeps the unseen move, an accepted risk, SEC-10 in
    ///          docs/V8-ACCEPTED-RISKS.md), and otherwise 0: a later third-party redemption pays in kind.
    ///      BOUNDED TRUST, as for the route fee: trySpot is a raw staticcall capped at SPOT_READ_GAS, and a revert, short
    ///      return data, a malformed answer or running out of gas count as no spot, so the oracle can neither revert a
    ///      redemption nor cost it more than the cap. A spot above uint128 is clamped to it, like a settlement price.
    function _floorPrice(V2Types.Series storage s, address underlying, address holder, address caller)
        private
        view
        returns (uint256 price)
    {
        price = s.settlementPrice;
        (bool ok, bytes memory ret) =
            s.oracle.staticcall{gas: SPOT_READ_GAS}(abi.encodeCall(ISettlementOracle.trySpot, (underlying)));
        if (ok && ret.length >= 96) {
            (uint256 okWord, uint256 spot,) = abi.decode(ret, (uint256, uint256, uint256));
            if (okWord == 1 && spot != 0) {
                if (spot > type(uint128).max) spot = type(uint128).max;
                return spot > price ? spot : price;
            }
        }
        if (caller == holder || block.timestamp <= uint256(s.expiry) + STALE_SPOT_GRACE || isOperator[holder][caller]) {
            return price;
        }
        return 0;
    }

    /// @dev The USDG floor of converting a payout worth `value` (USDG base units at the price {_floorPrice} chose)
    ///      through `adapter`: value * (BPS - min(maxPayoutSlippageBps + routeFee, MAX_PAYOUT_SLIPPAGE_CEIL_BPS)) / BPS
    ///      (INTERFACE_VERSION 6). The bound is measured above the route's own pool fee, so what a redeemer can capture
    ///      by moving the pool stays maxPayoutSlippageBps beyond the swap's cost on every fee tier.
    ///      BOUNDED TRUST. routeFee is `adapter.routeFeeBps(asset)` read with a raw staticcall capped at
    ///      ROUTE_FEE_READ_GAS and decoded as uint256, so the read can neither revert the redemption nor cost it more
    ///      than the cap: a revert, short return data or running out of gas reads as 0 (the tighter floor, which fails
    ///      toward in kind), and an answer above MAX_ROUTE_FEE_BPS is clamped to it.
    function _conversionFloor(address adapter, address asset, uint256 value) private view returns (uint256) {
        uint256 routeFee;
        (bool ok, bytes memory ret) =
            adapter.staticcall{gas: ROUTE_FEE_READ_GAS}(abi.encodeCall(IPayoutAdapter.routeFeeBps, (asset)));
        if (ok && ret.length >= 32) {
            routeFee = abi.decode(ret, (uint256));
            if (routeFee > V2Constants.MAX_ROUTE_FEE_BPS) routeFee = V2Constants.MAX_ROUTE_FEE_BPS;
        }
        uint256 slippageBps = maxPayoutSlippageBps + routeFee;
        if (slippageBps > V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS) {
            slippageBps = V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS;
        }
        return value * (V2Constants.BPS - slippageBps) / V2Constants.BPS;
    }

    /// @dev The oracle's final price for (underlying, expiry): the settlementPrice view first, then finalize. Both run
    ///      under try/catch so an oracle that reverts reads as "not final yet".
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

    /// @dev `caller` may redeem `holder` when it is the holder, the holder allows third parties, or it is the
    ///      holder's operator.
    function _mayRedeem(address holder, address caller) private view returns (bool) {
        return caller == holder || !_prefs[holder].noThirdPartyRedeem || isOperator[holder][caller];
    }

    /// @dev Collateral asset and collateral per unit of `s`, whose underlying the caller already read.
    function _collateral(V2Types.Series storage s, address underlying)
        private
        view
        returns (address asset, uint256 perUnit)
    {
        if (s.isPut) return (usdg, OptionMath.collateralPerUnit(true, s.strike));
        return (underlying, V2Constants.UNIT);
    }

    /// @dev The stored series of `longId`, or UnknownSeries.
    function _known(uint256 longId) private view returns (V2Types.Series storage s) {
        s = _series[longId];
        if (s.underlying == address(0)) revert V2Errors.UnknownSeries();
    }

    /// @dev `decimals()` of `token` without reverting: ok = false for a code-less address, a revert or short return
    ///      data (a staticcall to an empty account "succeeds" with no data, which is how address(0) is rejected).
    function _decimalsOf(address token) private view returns (bool ok, uint256 dec) {
        bytes memory ret;
        (ok, ret) = token.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        if (!ok || ret.length < 32) return (false, 0);
        dec = abi.decode(ret, (uint256));
    }

    /// @dev Best-effort ERC-20 transfer that never reverts the caller (the raw call of KeeperRewards._tryTransfer): a
    ///      paused USDG or a blocklisted holder must turn into a ledger credit, not a failed redemption. Empty return
    ///      data counts as success; every asset here has code (USDG checked at deploy, underlyings by their decimals
    ///      read at registration). The return word is compared with 1 so a dirty bool cannot revert the decode.
    function _tryTransfer(address asset, address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = asset.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (uint256)) == 1));
    }

    /// @dev Asks KeeperRewards to pay `keeper` the bounty of `action`. A raw call with no return data copied: whatever
    ///      the payer does, including reverting, cannot revert a settlement or a redemption. Eligibility was checked by
    ///      the caller (KeeperRewards trusts its registered callers for that).
    function _reward(bytes32 action, address keeper) private {
        address rewards = address(keeperRewards);
        if (rewards == address(0)) return;
        bytes memory data = abi.encodeCall(IKeeperRewards.reward, (keeper, action));
        assembly ("memory-safe") {
            pop(call(gas(), rewards, 0, add(data, 0x20), mload(data), 0, 0))
        }
    }

    /// @dev Two one-element arrays for ERC1155._update, laid out like OpenZeppelin's private _asSingletonArrays.
    function _singletons(uint256 id, uint256 value)
        private
        pure
        returns (uint256[] memory ids, uint256[] memory values)
    {
        assembly ("memory-safe") {
            ids := mload(0x40)
            mstore(ids, 1)
            mstore(add(ids, 0x20), id)
            values := add(ids, 0x40)
            mstore(values, 1)
            mstore(add(values, 0x20), value)
            mstore(0x40, add(values, 0x40))
        }
    }
}
