// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {ExpiryCalendar} from "../../../src/v2/ExpiryCalendar.sol";
import {KeeperRewards} from "../../../src/v2/KeeperRewards.sol";
import {OrderBook} from "../../../src/v2/OrderBook.sol";
import {IOrderBook} from "../../../src/v2/interfaces/IOrderBook.sol";
import {IFeeDiscount} from "../../../src/v2/interfaces/IFeeDiscount.sol";
import {IPriceSource} from "../../../src/v2/interfaces/IPriceSource.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Ids} from "../../../src/v2/interfaces/V2Ids.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {OptionMath} from "../../../src/v2/lib/OptionMath.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../../src/mocks/MockStockToken.sol";
import {MockRoundFeed} from "../../../src/v2/mocks/MockRoundFeed.sol";
import {MockFeeDiscount} from "../../../src/v2/mocks/MockFeeDiscount.sol";
import {MockOraclePriceSource} from "../../../src/v2/mocks/MockOraclePriceSource.sol";
import {MockUniV3Pool} from "../../../src/v2/mocks/MockUniV3Pool.sol";
import {ChainlinkFeedSource} from "../../../src/v2/oracle/ChainlinkFeedSource.sol";
import {SettlementOracle} from "../../../src/v2/oracle/SettlementOracle.sol";
import {UniV3TwapSource} from "../../../src/v2/oracle/UniV3TwapSource.sol";

/// @notice Drives the real v2 core (Clearinghouse, OrderBook, SettlementOracle over its two real sources, KeeperRewards)
///         through random LEGAL and ILLEGAL sequences for {V2InvariantTest}: ledger deposits and withdrawals, series
///         creation, mints, closes, ERC-1155 transfers, the three order kinds, cancel, replace, takes in both
///         directions, owed claims, prunes, feed prints, time, snapshots, finalizations, settlements, redemptions, fee
///         sweeps, every pause flag, oracle faults (feed and pool reverting, the issuer's oracle pause, sources removed,
///         a reverting oracle for new series), mid-life reconfiguration of the market and both sources, the admin's
///         pinning attacks (taking the oracle off a source's allow-list, and pre-pinning an expiry through its own
///         account set as the Clearinghouse pointer or listed on a source), USDG pause and freezes, payout preferences,
///         veto and admin resolve.
/// @dev EVERY PROTOCOL CALL IS A PREDICTION. Before a call the handler decides from the contracts' public state whether
///      the call must succeed or must revert (the pause flags, the cutoff and expiry, the ledger, the book's quote,
///      USDG blocking), makes it with a raw call, and counts a mismatch either way ({unexpectedReverts},
///      {unexpectedSuccesses}, with {lastSurprise} naming it). So a close, redeem, withdraw or cancel that reverts
///      under some pause flag or oracle fault fails invariant 4, and a mint that succeeds while paused fails it too.
///      The handler itself never reverts (the suite runs with fail-on-revert).
///
///      GHOSTS. {ghostIn} / {ghostOut} per asset: what entered the Clearinghouse (deposits) and what left it
///      (withdrawals, redemption payouts to wallets, fee sweeps), each measured on the RECEIVING side, never read from
///      the Clearinghouse's own books (invariant 2). {lockedAtSettle} and {paidOut} per series: what a series held when
///      it settled and what its redemptions paid, payouts plus exercise fees, measured as holder and fee balance
///      deltas and checked against balance x per-unit amount on every redemption (invariant 3). {ghostPinned} and its
///      siblings per expiry: the configuration the handler itself had set when a series creation first pinned (or
///      confirmed) the expiry (source list, deviation, delay, and whether market, feed and pool were all the honest
///      ones), which the pinning invariant compares with what the oracle settles on (V2InvariantTest, invariant 6).
///      {ghostOraclePinned}, {ghostPinnedBy}, {ghostPinnedMode}, {ghostFeedPin} and {ghostPoolPin} per expiry: the
///      model of every pin, including the admin's pre-pins, from which every createSeries and pre-pin is predicted.
///
///      INVARIANT 5 per call: around every call that can move value, the wallets, ledger balances and ERC-1155
///      balances of every actor other than the caller are snapshotted. A wallet may never fall; a ledger balance may
///      fall only by exactly the collateral of the caller's take filling that actor's write-on-fill asks (the book is
///      that actor's operator); a token balance may fall only for a holder being redeemed, who is paid exactly.
///
///      TIME. A trader action first advances the clock by 0-60 minutes, a keeper action by 0-5 minutes, and {warp}
///      jumps to the cutoff, expiry, snapshot, finalize or post-delay instant of a listed expiry. A background cranker
///      snapshots every listed expiry the clock passes at expiry + 60, as K2-03 does, unless {toggleOracleFault} put it
///      to sleep (then only a timely {snapshot} call records the pool, and settlement usually goes uncorroborated).
///      The clock is kept in {clock} and never read from block.timestamp (via_ir may fold TIMESTAMP reads). The feed
///      prints a heartbeat at least every 6 hours of simulated time so a window is not stale merely because nobody
///      printed.
contract V2Handler is Test {
    /// @dev THIS MAKES THREE RESTRICTED CALLS, SO ONE `vm.prank` IS NOT ENOUGH. A single prank covers the NEXT
    ///      external call only; the second and third then run as whatever contract called this helper, and on a
    ///      `Managed` Clearinghouse that is `NotAuthorized()`. Every caller must hold the prank open across the
    ///      whole helper -- `vm.startPrank` / `vm.stopPrank`, not `vm.prank`. Found by T-INV5 when the handler
    ///      walk finally reached `toggleOracleFault`: the call had been wrong since the v8 setter split and had
    ///      never once executed.
    function _reconfigure(Clearinghouse house, address underlying, V2Types.MarketConfig memory cfg) internal {
        house.setMarketListing(underlying, cfg.enabled, cfg.strikeTick);
        house.setMarketFees(underlying, cfg.exerciseFeeBps, cfg.mintFeePpm);
        house.setMarketOracle(underlying, cfg.oracle);
    }

    struct Deps {
        Clearinghouse ch;
        OrderBook book;
        SettlementOracle oracle;
        ExpiryCalendar calendar;
        KeeperRewards rewards;
        MockRoundFeed feed;
        MockUniV3Pool pool;
        MockERC20 usdg;
        MockStockToken nvda;
        address clSource;
        address poolSource;
        address badOracle;
        MockRoundFeed evilFeed;
        MockUniV3Pool evilPool;
        MockOraclePriceSource evilSource;
        address admin;
        address guardian;
        address keeper;
        address treasury;
        address chFees;
        address[4] actors;
        uint256 start;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant MAX_SERIES = 16;
    uint256 internal constant EXPIRIES = 12;
    uint128 internal constant POOL_LIQUIDITY = 1e19;
    /// @dev The evil pool's liquidity floor. It used to be 0 ("no floor": the evil pool must PRICE, so the campaign
    ///      can check what the oracle does with a manipulated print); T-OP-062 made {UniV3TwapSource.setPool} refuse a
    ///      zero floor (`CeilingExceeded`), which killed every campaign at its first {reconfigure} (T-OP-097 (b)(1)).
    ///      This is the smallest legal floor, the value T-OP-062's own tests chose for the same purpose, and it is
    ///      justified by the fixture: the evil pool sits at POOL_LIQUIDITY (1e19) in-range liquidity, so its
    ///      harmonic-mean liquidity over any window is 1e19 >= 1 and the pool keeps pricing exactly as before.
    uint128 internal constant EVIL_POOL_MIN_LIQUIDITY = 1;
    uint256 internal constant UNIT = V2Constants.UNIT;
    /// @dev Series stages the selectors aim at (see {_seriesIn}).
    uint8 internal constant OPEN = 0;
    uint8 internal constant EXPIRED = 1;
    uint8 internal constant SETTLED = 2;
    /// @dev {marketMode}: the oracle market's source list as the admin last set it.
    uint8 internal constant HONEST = 0;
    uint8 internal constant REMOVED = 1;
    uint8 internal constant EVIL = 2;
    /// @dev {ghostFeedPin} / {ghostPoolPin}: the source has not pinned the expiry, pinned the honest configuration, or
    ///      pinned the evil one.
    uint8 internal constant NO_PIN = 0;
    uint8 internal constant PIN_HONEST = 1;
    uint8 internal constant PIN_EVIL = 2;
    /// @dev What the evil feed, pool and source price NVDA at: 400 USDG, far outside the honest 200-240 grid.
    uint256 internal constant EVIL_PRICE = 400_000_000;
    /// @dev 1e18 / 1.0001^216407 = 399.99 USDG per share (USDG is token0), the evil pool's tick.
    int24 internal constant EVIL_TICK = 216407;

    /*//////////////////////////////////////////////////////////////
                                 WIRING
    //////////////////////////////////////////////////////////////*/

    Clearinghouse internal immutable ch;
    OrderBook internal immutable book;
    SettlementOracle internal immutable oracle;
    ExpiryCalendar internal immutable calendar;
    KeeperRewards internal immutable rewards;
    MockRoundFeed internal immutable feed;
    MockUniV3Pool internal immutable pool;
    MockERC20 internal immutable usdg;
    MockStockToken internal immutable nvda;
    address internal immutable clSource;
    address internal immutable poolSource;
    address internal immutable badOracle;
    MockRoundFeed internal immutable evilFeed;
    MockUniV3Pool internal immutable evilPool;
    MockOraclePriceSource internal immutable evilSource;
    address internal immutable admin;
    address internal immutable guardian;
    address internal immutable keeper;
    address internal immutable treasury;
    address internal immutable chFees;
    address[4] internal actors;

    /*//////////////////////////////////////////////////////////////
                              WORLD STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The simulated now, unix seconds. Mirrors block.timestamp.
    uint256 public clock;
    uint256 internal lastFeedAt;
    uint256 internal lastPoolAt;
    /// @dev Index into the price grid 200, 205, ..., 240 USDG.
    uint256 internal level = 4;
    int24[9] internal ticks = [int24(223338), 223091, 222850, 222615, 222385, 222160, 221941, 221725, 221515];

    uint40[] internal expiries;
    uint256[] internal series;
    mapping(uint256 longId => bool) internal known;

    /// @notice HONEST ([Chainlink, pool], defaults), REMOVED (no sources) or EVIL ([evil source, Chainlink], 1000 bps,
    ///         30 min): the oracle market as the admin last set it.
    uint8 public marketMode;
    /// @notice The Chainlink source currently reads the evil feed (7 days stale bound, 5000 bps jumps).
    bool public evilFeedOn;
    /// @notice The pool source currently reads the evil pool with no liquidity floor.
    bool public evilPoolOn;
    /// @notice The admin took the oracle off the Chainlink source's / the pool source's allow-list.
    bool public clRevoked;
    bool public poolRevoked;
    /// @dev When set, nobody snapshots the pool inside the grace unless the fuzzer calls {snapshot} in time.
    bool public crankerAsleep;
    bool public badOracleOn;
    /// @dev INTERFACE_VERSION 8: the book's discount module and whether it is currently set (10 % while on), so the
    ///      campaign's takes sometimes run discounted and the rebate-vs-fee invariant checks the DISCOUNTED figure.
    MockFeeDiscount public discount;
    bool public discountOn;

    /*//////////////////////////////////////////////////////////////
                                 GHOSTS
    //////////////////////////////////////////////////////////////*/

    mapping(address asset => uint256) public ghostIn;
    mapping(address asset => uint256) public ghostOut;
    mapping(uint256 longId => uint256) public lockedAtSettle;
    mapping(uint256 longId => uint256) public paidOut;
    mapping(uint256 longId => bool) public settleSeen;

    /// @notice Per expiry, set when the handler's createSeries made the real oracle pin it: the model's source list
    ///         (hashed), deviation (bps) and delay (seconds) at that moment, and whether market, feed and pool were all
    ///         honest then.
    mapping(uint40 expiry => bool) public ghostPinned;
    mapping(uint40 expiry => bytes32) public ghostPinnedSources;
    mapping(uint40 expiry => uint16) public ghostPinnedDeviation;
    mapping(uint40 expiry => uint32) public ghostPinnedDelay;
    mapping(uint40 expiry => bool) public ghostPinnedHonest;
    /// @notice The model of every pin of an expiry, the admin's pre-pins included: whether the oracle holds a pin, which
    ///         Clearinghouse pointer made or last confirmed it (the Clearinghouse or the admin's {shadow}), the market
    ///         mode it copied (HONEST or EVIL), and what each real source pinned (NO_PIN, PIN_HONEST, PIN_EVIL).
    mapping(uint40 expiry => bool) public ghostOraclePinned;
    mapping(uint40 expiry => address) public ghostPinnedBy;
    mapping(uint40 expiry => uint8) public ghostPinnedMode;
    mapping(uint40 expiry => uint8) public ghostFeedPin;
    mapping(uint40 expiry => uint8) public ghostPoolPin;

    uint256 public unexpectedReverts;
    uint256 public unexpectedSuccesses;
    string public lastSurprise;
    uint256 public inv5Violations;
    string public lastInv5;
    uint256 public payoutViolations;
    string public lastPayout;
    uint256 public takeViolations;
    string public lastTake;

    /// @notice Coverage counters: calls that did what their name says.
    uint256 public nFills;
    uint256 public nMints;
    uint256 public nCloses;
    uint256 public nCancels;
    uint256 public nPrunes;
    uint256 public nSettles;
    uint256 public nRedeemsPaid;
    uint256 public nCorroborated;
    uint256 public nUncorroborated;
    uint256 public nResolved;
    uint256 public nOwedClaims;
    uint256 public nReconfigured;
    /// @notice Finalizations (not resolutions) of an expiry pinned honest while the current configuration was not.
    uint256 public nPinnedFinalsUnderChange;
    /// @notice New series refused because their expiry's pin could not be made or confirmed, and pre-pins attempted.
    uint256 public nPinRefusals;
    uint256 public nPrePins;

    /// @notice The admin's own account: the Clearinghouse pointer or a source allow-list entry during a pre-pin.
    address public immutable shadow = makeAddr("adminShadow");

    constructor(Deps memory d) {
        ch = d.ch;
        book = d.book;
        oracle = d.oracle;
        calendar = d.calendar;
        rewards = d.rewards;
        feed = d.feed;
        pool = d.pool;
        usdg = d.usdg;
        nvda = d.nvda;
        clSource = d.clSource;
        poolSource = d.poolSource;
        badOracle = d.badOracle;
        evilFeed = d.evilFeed;
        evilPool = d.evilPool;
        evilSource = d.evilSource;
        admin = d.admin;
        guardian = d.guardian;
        keeper = d.keeper;
        treasury = d.treasury;
        chFees = d.chFees;
        actors = d.actors;
        clock = d.start;
        lastFeedAt = d.start;
        lastPoolAt = d.start;
        uint40 t = uint40(d.start);
        for (uint256 i; i < EXPIRIES; ++i) {
            t = calendar.nextExpiry(t, false);
            expiries.push(t);
        }
        // Spot is fresh and the pool agrees with the feed at the start.
        _printFeed();
        _printPool();
        discount = new MockFeeDiscount(0);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function seriesCount() external view returns (uint256) {
        return series.length;
    }

    function seriesAt(uint256 i) external view returns (uint256) {
        return series[i];
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function expiryCount() external view returns (uint256) {
        return expiries.length;
    }

    function expiryAt(uint256 i) external view returns (uint40) {
        return expiries[i];
    }

    /*//////////////////////////////////////////////////////////////
                            LEDGER ACTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint8 a, bool isUsdg, uint256 amount, uint16 dt) external {
        _advance(dt);
        address who = _actor(a);
        address asset = isUsdg ? address(usdg) : address(nvda);
        amount = _bound(amount, 1, isUsdg ? 50_000e6 : 50e18);
        _topUp(who, asset, amount);
        bool expectOk = !(isUsdg && _usdgBlocked(who));
        uint256[] memory before = _snap();
        uint256 chBefore = _bal(asset, address(ch));
        (bool ok, bytes memory ret) = _call(who, address(ch), abi.encodeCall(ch.deposit, (asset, amount, who)));
        _expect("deposit", expectOk, ok, ret);
        if (ok) ghostIn[asset] += _bal(asset, address(ch)) - chBefore;
        _inv5("deposit", who, before, _none(), _none(), 0);
    }

    function withdraw(uint8 a, bool isUsdg, uint256 amount, uint16 dt) external {
        _advance(dt);
        address who = _actor(a);
        address asset = isUsdg ? address(usdg) : address(nvda);
        uint256 have = ch.free(who, asset);
        if (have == 0) return;
        amount = _bound(amount, 1, have);
        bool expectOk = !(isUsdg && _usdgBlocked(who));
        uint256[] memory before = _snap();
        uint256 walletBefore = _bal(asset, who);
        (bool ok, bytes memory ret) = _call(who, address(ch), abi.encodeCall(ch.withdraw, (asset, amount, who)));
        _expect("withdraw", expectOk, ok, ret);
        if (ok) ghostOut[asset] += _bal(asset, who) - walletBefore;
        _inv5("withdraw", who, before, _none(), _none(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                           POSITION ACTIONS
    //////////////////////////////////////////////////////////////*/

    function createSeries(uint8 e, uint8 k, bool isPut, uint16 dt) external {
        _advance(dt);
        uint40 expiry = expiries[e % EXPIRIES];
        uint128 strike = uint128(200_000_000 + uint256(k % 5) * 10_000_000);
        uint256 longId = V2Ids.longIdOf(address(nvda), isPut, strike, expiry);
        bool exists = known[longId];
        if (!exists && series.length >= MAX_SERIES) return;
        // A new series on the real oracle calls pin, which must pin or confirm the expiry (see {_pinWouldSucceed}).
        bool pins = !exists && !badOracleOn;
        bool pinOk = !pins || _pinWouldSucceed(expiry, address(ch));
        bool gatesOk = !ch.createPaused() && expiry >= clock + V2Constants.MIN_SERIES_LEAD
            && expiry <= clock + V2Constants.MAX_TENOR;
        bool expectOk = exists || (gatesOk && pinOk);
        (bool ok, bytes memory ret) =
            _call(keeper, address(ch), abi.encodeCall(ch.createSeries, (address(nvda), isPut, strike, expiry)));
        _expect("createSeries", expectOk, ok, ret);
        if (!exists && gatesOk && !pinOk) ++nPinRefusals;
        if (ok && !exists) {
            known[longId] = true;
            series.push(longId);
            if (pins) {
                _applyPin(expiry, address(ch));
                if (!ghostPinned[expiry]) _ghostPin(expiry);
            }
        }
    }

    /// @dev What the model says the first series creation that pinned (or confirmed) `expiry` fixed. The pin just made
    ///      or confirmed equals the current configuration, so the pinned states are the current ones.
    function _ghostPin(uint40 expiry) internal {
        bool evil = ghostPinnedMode[expiry] == EVIL;
        address[] memory sources = new address[](2);
        (sources[0], sources[1]) = evil ? (address(evilSource), clSource) : (clSource, poolSource);
        ghostPinned[expiry] = true;
        ghostPinnedSources[expiry] = keccak256(abi.encode(sources));
        ghostPinnedDeviation[expiry] = evil ? 1000 : 150;
        ghostPinnedDelay[expiry] = evil ? 30 minutes : 6 hours;
        ghostPinnedHonest[expiry] = !evil && ghostFeedPin[expiry] == PIN_HONEST && ghostPoolPin[expiry] == PIN_HONEST;
    }

    /// @dev Whether SettlementOracle.pin(NVDA, expiry) from `caller` (the Clearinghouse pointer at that moment) succeeds:
    ///      pinned by `caller` already; or pinned by another pointer with the market's current mode and every pinned
    ///      source confirming; or not pinned, the market not empty and every listed source pinning. HONEST lists
    ///      [Chainlink, pool], EVIL [evil source, Chainlink]; the evil source (a mock) always pins.
    function _pinWouldSucceed(uint40 expiry, address caller) internal view returns (bool) {
        if (ghostOraclePinned[expiry]) {
            if (ghostPinnedBy[expiry] == caller) return true;
            if (ghostPinnedMode[expiry] != marketMode) return false;
            return _sourcesWouldPin(expiry, ghostPinnedMode[expiry]);
        }
        if (marketMode == REMOVED) return false;
        return _sourcesWouldPin(expiry, marketMode);
    }

    function _sourcesWouldPin(uint40 expiry, uint8 mode) internal view returns (bool) {
        if (clRevoked || !_sourcePinWouldSucceed(ghostFeedPin[expiry], evilFeedOn)) return false;
        if (mode == EVIL) return true;
        return !poolRevoked && _sourcePinWouldSucceed(ghostPoolPin[expiry], evilPoolOn);
    }

    /// @dev A real source (always configured here) pins an unpinned expiry, and confirms a pin equal to its current
    ///      configuration.
    function _sourcePinWouldSucceed(uint8 pinned, bool evilOn) internal pure returns (bool) {
        return pinned == NO_PIN || (pinned == PIN_EVIL) == evilOn;
    }

    /// @dev The model after a successful pin by `caller`.
    function _applyPin(uint40 expiry, address caller) internal {
        if (ghostOraclePinned[expiry] && ghostPinnedBy[expiry] == caller) return;
        if (!ghostOraclePinned[expiry]) {
            ghostOraclePinned[expiry] = true;
            ghostPinnedMode[expiry] = marketMode;
        }
        ghostPinnedBy[expiry] = caller;
        if (ghostFeedPin[expiry] == NO_PIN) ghostFeedPin[expiry] = evilFeedOn ? PIN_EVIL : PIN_HONEST;
        if (ghostPinnedMode[expiry] == HONEST && ghostPoolPin[expiry] == NO_PIN) {
            ghostPoolPin[expiry] = evilPoolOn ? PIN_EVIL : PIN_HONEST;
        }
    }

    /// @dev INTERFACE_VERSION 8: MINTING GOES THROUGH THE BOOK, never `ch.mint` directly. T-77 made the OrderBook
    ///      the only protocol minter (`Clearinghouse.sol` reverts `NotMinter()` for anyone else), so the v7 shape of
    ///      this function -- `abi.encodeCall(ch.mint, ...)` from an actor -- can no longer succeed and would turn
    ///      every mint into a silent no-op that still counts as a campaign step. The real mint path is: the writer
    ///      rests an AskWrite, a buyer takes it, and the book mints the pair out of the writer's free collateral.
    ///      V8-DESIGN section 12 requires the handler to exercise that path so the invariants see real book-minted
    ///      supply rather than supply the handler conjured behind the book's back.
    function mint(uint8 a, uint8 s, uint64 units, uint8 to, uint16 dt) external {
        _advance(dt);
        if (series.length == 0) return;
        address writer = _actor(a);
        // `(uint256(a) + 1) % 4`, NOT `uint8(a + 1)`. The old form adds in uint8, so a == 255 -- which the fuzzer
        // reaches as soon as it explores this leg at all -- overflows and PANICS 0x11 before a single external
        // call is made. It had never fired because invariant_5's walk died in setUp, so this leg was only ever
        // reached by the shallow stage walk; the first campaign that actually ran found it at runs: 53. The
        // modulo also makes the intent explicit: the buyer is the NEXT actor, wrapping.
        address buyer = to & 1 == 0 ? _actor(uint8(to >> 1)) : _actor(uint8((uint256(a) + 1) % 4));
        if (buyer == writer) return;
        uint256 longId = _seriesIn(s, OPEN);
        V2Types.Series memory sr = ch.series(longId);
        (address asset, uint256 perUnit) = _collateral(sr);
        // The writer still needs the collateral AND the rent out of one free balance, exactly as in v7: the book
        // pulls both when it mints. ceil(u x r) <= u x ceil(r), so sizing on the ceiled per-unit rate is never too
        // large; it can be one unit short, which only makes the handler slightly gentler.
        uint256 costPerUnit = perUnit;
        if (clock < sr.expiry) costPerUnit += OptionMath.mintFee(perUnit, sr.mintFeePpm, sr.expiry - clock);
        uint256 maxUnits = ch.free(writer, asset) / costPerUnit;
        if (maxUnits == 0) return;
        units = uint64(_bound(units, 1, maxUnits < 300 ? maxUnits : 300));

        uint256 mintCutoff = sr.expiry - V2Constants.SETTLEMENT_WINDOW;
        if (book.tradingPaused() || clock >= mintCutoff) return;

        // A price the buyer can actually pay, escrowed up front.
        uint128 price = _price(uint32(uint256(keccak256(abi.encode(longId, units, clock))) % type(uint32).max));
        uint256 premium = uint256(price) * units / V2Constants.UNITS_PER_SHARE;
        // MIRROR, DO NOT RE-REASON: the taker fee is READ from the book, never retyped, so a fee change moves the
        // top-up with it instead of quietly under-funding the buyer and turning every mint into a no-op.
        _topUp(buyer, address(usdg), premium + book.feeParams().takerFeeFlat);
        if (_usdgBlocked(buyer) || _usdgBlocked(writer)) return;

        (bool placed, bytes memory placeRet) = _call(
            writer, address(book), abi.encodeCall(book.place, (longId, V2Types.OrderKind.AskWrite, price, units, 0))
        );
        if (!placed) {
            _expect("mint.place", false, placed, placeRet);
            return;
        }
        uint256 orderId = abi.decode(placeRet, (uint256));

        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        V2Types.TakeParams memory p;
        p.longId = longId;
        p.buying = true;
        p.orderIds = ids;
        p.units = units;
        p.minUnits = 0;
        p.limitPrice = price;
        p.recipient = buyer;
        // casting to 'uint40' is safe because simulated time stays far below 2^40
        // forge-lint: disable-next-line(unsafe-typecast)
        p.deadline = uint40(clock + 1 hours);
        p.maxTotalFee = type(uint128).max;

        uint256[] memory before = _snap();
        vm.recordLogs();
        (bool ok, bytes memory ret) = _call(buyer, address(book), abi.encodeCall(book.take, (p)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (ok) ++nMints;
        // A MINT IS A TWO-PARTY ACTION AND INVARIANT 5 EXEMPTS EXACTLY ONE ACTOR. The book pulls the BUYER's
        // premium and the WRITER's collateral in this single call, so no choice of exempt actor is correct on its
        // own: naming the writer leaves the buyer's legitimate premium reading as a violation, and naming the
        // buyer leaves the writer's legitimate collateral lock reading as one. The exempt actor must therefore be
        // the REAL caller -- `buyer`, the address passed to `_call` on the line above -- and the writer's movement
        // must be DESCRIBED through the allowance vectors rather than excused by an exemption.
        //
        // MIRRORED FROM THE ONE SITE THAT ALREADY DOES THIS, the generic take path at the `usdgDrop`/`nvdaDrop`
        // block below: cost is `units * perUnit` with the mint rent charged on the TOTAL, not the per-unit rate
        // ceiled and then multiplied. The two differ by rounding, and `_inv5` compares the drop with `!=`, so the
        // sizing figure `costPerUnit` computed above is NOT usable here -- it is deliberately conservative for
        // bounding `units` and would be one wei high.
        //
        // WHY THE WRITER'S DROP IS EXACTLY THE COST, with no premium netted against it: the book credits maker
        // proceeds to `owed`, not to the ledger, and they reach the ledger only through a later `claimOwed` --
        // which is its own handler leg with its own `_inv5` call.
        //
        // MEASURED FROM THE FILLS, NOT PREDICTED FROM THE REQUEST. An earlier version of this computed the cost
        // from the `units` ASKED FOR and assumed the fill was primary. invariant_5 -- running for the first time
        // in this campaign's life -- shrank a two-call sequence, togglePause(0) then mint(...), down to
        // "mint: another actor's NVDA ledger moved other than its filled write asks" and was RIGHT: a take can
        // fill PARTIALLY, and it can fill against a resting AskResale that mints nothing at all, and in both
        // cases the writer's collateral movement is not the figure the request implies. Only the `OrderFilled`
        // events say what actually happened, which is exactly why the generic take path decodes them instead of
        // predicting -- this now mirrors that block rather than paraphrasing it.
        uint256[4] memory usdgDrop;
        uint256[4] memory nvdaDrop;
        uint64 primaryUnits;
        if (ok) {
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].emitter != address(book) || logs[i].topics[0] != IOrderBook.OrderFilled.selector) {
                    continue;
                }
                (address maker, uint64 u,,,,, bool primary,,) =
                    abi.decode(logs[i].data, (address, uint64, uint128, uint256, uint256, uint256, bool, bool, address));
                if (!primary) continue;
                primaryUnits += u;
                uint256 cost = uint256(u) * perUnit;
                cost += OptionMath.mintFee(cost, sr.mintFeePpm, sr.expiry - clock);
                uint256 idx = _indexOf(maker);
                if (asset == address(usdg)) usdgDrop[idx] += cost;
                else nvdaDrop[idx] += cost;
            }
        }
        // THE CALL SUCCEEDING AND A MINT HAPPENING ARE DIFFERENT EVENTS, AND CONFLATING THEM FAILED invariant_4.
        // The old prediction was `expectOk = !tradingPaused && !mintPaused && clock < mintCutoff`, compared against
        // whether `book.take` REVERTED. Two of those three are already excluded by the early return at the top of
        // this function, so it reduced to `!mintPaused` -- and `mintPaused` does not make the CALL revert. The book
        // SKIPS a maker it cannot fill and returns normally having filled nothing. So a paused market produced a
        // successful call, the prediction said "revert", and invariant_4 went red at runs: 24 with
        // "mint: succeeded where a revert was predicted" -- against a protocol that had behaved correctly.
        // Verified on the failing seed: the only `OrderFilled` in that trace is the SETUP mint, sixty lines before
        // `setMintPaused(NVDAx, true)`; the failing call emits none. The guardian pause held.
        //
        // SO THE CALL IS EXPECTED TO SUCCEED, and the thing `mintPaused` actually governs -- whether a PRIMARY fill
        // occurred -- is read from the events rather than inferred from the return value.
        _expect("mint", true, ok, ret);

        // ONE DIRECTION ONLY, AND THAT IS DELIBERATE RATHER THAN LAZY. A primary fill WHILE the market mint pause
        // is on would be a guardian pause failing open, which is a safety violation and is asserted here. The
        // converse -- no primary fill while minting is allowed -- is NOT asserted, because a legitimate zero fill
        // has causes this leg does not control (the order can be overtaken, pruned or priced out between place and
        // take) and an invariant that reds on those would be measuring liveness, not safety. The asymmetry is
        // stated so the next reader does not "restore" the missing half and then disable the whole check when it
        // trips on a benign zero fill.
        _expect(
            "mint minted under the market pause", false, primaryUnits != 0 && ch.market(address(nvda)).mintPaused, ""
        );

        _inv5("mint", buyer, before, usdgDrop, nvdaDrop, 0);
    }

    function close(uint8 a, uint8 s, uint64 units, uint16 dt) external {
        _advance(dt);
        if (series.length == 0) return;
        address who = _actor(a);
        uint256 longId = _seriesHeld(who, s, true);
        if (ch.series(longId).settled) return;
        uint256 longs = ch.balanceOf(who, longId);
        uint256 shorts = ch.balanceOf(who, V2Ids.shortIdOf(longId));
        uint256 most = longs < shorts ? longs : shorts;
        if (most == 0) return;
        units = uint64(_bound(units, 1, most));
        uint256[] memory before = _snap();
        (bool ok, bytes memory ret) = _call(who, address(ch), abi.encodeCall(ch.close, (longId, units)));
        _expect("close", true, ok, ret);
        if (ok) ++nCloses;
        _inv5("close", who, before, _none(), _none(), 0);
    }

    function transfer(uint8 from, uint8 to, uint8 s, bool short, uint64 units, uint16 dt) external {
        _advance(dt);
        if (series.length == 0) return;
        address sender = _actor(from);
        uint256 longId = _seriesHeld(sender, s, false);
        uint256 id = short ? V2Ids.shortIdOf(longId) : longId;
        uint256 have = ch.balanceOf(sender, id);
        if (have == 0) return;
        units = uint64(_bound(units, 1, have));
        uint256[] memory before = _snap();
        (bool ok, bytes memory ret) =
            _call(sender, address(ch), abi.encodeCall(ch.safeTransferFrom, (sender, _actor(to), id, units, "")));
        _expect("transfer", true, ok, ret);
        _inv5("transfer", sender, before, _none(), _none(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                             BOOK ACTIONS
    //////////////////////////////////////////////////////////////*/

    function place(uint8 a, uint8 s, uint8 kindSeed, uint32 priceSeed, uint64 units, uint32 validSeed, uint16 dt)
        external
    {
        _advance(dt);
        if (series.length == 0) return;
        address maker = _actor(a);
        uint256 longId = _seriesIn(s, OPEN);
        V2Types.OrderKind kind = V2Types.OrderKind(kindSeed % 3);
        uint128 price = _price(priceSeed);
        V2Types.Series memory sr = ch.series(longId);
        units = uint64(_bound(units, 1, 300));
        if (kind == V2Types.OrderKind.AskResale) {
            uint256 have = ch.balanceOf(maker, longId);
            if (have == 0) return;
            // casting to 'uint64' is safe because have < units, a uint64
            // forge-lint: disable-next-line(unsafe-typecast)
            if (units > have) units = uint64(have);
        }
        uint256 limit = kind == V2Types.OrderKind.AskWrite ? sr.expiry - V2Constants.SETTLEMENT_WINDOW : sr.expiry;
        // casting to 'uint40' is safe because simulated time stays far below 2^40
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 validUntil = validSeed % 3 == 0 ? 0 : uint40(clock + _bound(validSeed, 1, 2 days));
        bool expectOk = !book.tradingPaused() && clock < limit && (validUntil == 0 || validUntil <= limit);
        if (kind == V2Types.OrderKind.Bid) {
            uint256 escrow = uint256(price) * units / 100;
            _topUp(maker, address(usdg), escrow);
            if (_usdgBlocked(maker)) expectOk = false;
        }
        uint256[] memory before = _snap();
        (bool ok, bytes memory ret) =
            _call(maker, address(book), abi.encodeCall(book.place, (longId, kind, price, units, validUntil)));
        _expect("place", expectOk, ok, ret);
        _inv5("place", maker, before, _none(), _none(), 0);
    }

    function cancel(uint256 orderSeed, uint16 dt) external {
        _advance(dt);
        uint256 last = book.lastOrderId();
        if (last == 0) return;
        uint256 id = 1 + orderSeed % last;
        address maker = _order(id).maker;
        uint256[] memory before = _snap();
        (bool ok, bytes memory ret) = _call(maker, address(book), abi.encodeCall(book.cancel, (_one(id))));
        _expect("cancel", true, ok, ret);
        if (ok) ++nCancels;
        _inv5("cancel", maker, before, _none(), _none(), 0);
    }

    function replace(uint256 orderSeed, uint32 priceSeed, uint64 units, uint16 dt) external {
        _advance(dt);
        uint256 last = book.lastOrderId();
        if (last == 0) return;
        uint256 id = 1 + orderSeed % last;
        V2Types.Order memory o = _order(id);
        uint128 price = _price(priceSeed);
        uint64 remaining = o.units - o.filled;
        units = uint64(_bound(units, 1, 300));
        bool expectOk = !book.tradingPaused() && !o.cancelled && remaining > 0 && clock < o.validUntil;
        if (o.kind == V2Types.OrderKind.AskResale) {
            uint256 most = ch.balanceOf(o.maker, o.longId) + remaining;
            // casting to 'uint64' is safe because most < units, a uint64
            // forge-lint: disable-next-line(unsafe-typecast)
            if (units > most) units = uint64(most);
        } else if (o.kind == V2Types.OrderKind.Bid && expectOk) {
            uint256 newEscrow = uint256(price) * units / 100;
            uint256 oldEscrow = uint256(o.price) * remaining / 100;
            if (newEscrow > oldEscrow) {
                _topUp(o.maker, address(usdg), newEscrow - oldEscrow);
                if (_usdgBlocked(o.maker)) expectOk = false;
            }
        }
        uint256[] memory before = _snap();
        (bool ok, bytes memory ret) = _call(o.maker, address(book), abi.encodeCall(book.replace, (id, price, units)));
        _expect("replace", expectOk, ok, ret);
        _inv5("replace", o.maker, before, _none(), _none(), 0);
    }

    /// A buy naming a known order first (so its series has something to hit), then up to four more of its series.
    function takeBuy(uint8 a, uint256 orderSeed, uint64 units, uint256 idsSeed, uint32 limitSeed, uint8 r, uint16 dt)
        external
    {
        _advance(dt);
        uint256 last = book.lastOrderId();
        if (last == 0) return;
        address taker = _actor(a);
        uint256 first = _aimOrder(orderSeed, last, true);
        uint256 longId = _order(first).longId;
        uint256[] memory ids = _pickOrders(longId, first, idsSeed);
        V2Types.TakeParams memory p = _takeParams(longId, true, ids, units, limitSeed, false, _actor(r));
        bool expectOk = !book.tradingPaused();
        if (expectOk) {
            vm.prank(taker);
            (, uint256 premium, uint256 fee,) = book.quoteTake(p);
            if (premium + fee > 0) {
                _topUp(taker, address(usdg), premium + fee);
                if (_usdgBlocked(taker)) expectOk = false;
            }
        }
        _take("takeBuy", taker, p, expectOk);
    }

    /// A sale naming a known order first, then up to four more of its series.
    function takeSell(
        uint8 a,
        uint256 orderSeed,
        uint64 units,
        uint256 idsSeed,
        uint32 limitSeed,
        bool writeToSell,
        uint8 r,
        uint16 dt
    ) external {
        _advance(dt);
        uint256 last = book.lastOrderId();
        if (last == 0) return;
        address taker = _actor(a);
        uint256 first = _aimOrder(orderSeed, last, false);
        uint256 longId = _order(first).longId;
        uint256[] memory ids = _pickOrders(longId, first, idsSeed);
        V2Types.TakeParams memory p = _takeParams(longId, false, ids, units, limitSeed, writeToSell, _actor(r));
        _take("takeSell", taker, p, !book.tradingPaused());
    }

    function claimOwed(uint8 a, uint16 dt) external {
        _advance(dt);
        address who = _actor(a);
        uint256 amount = book.owed(who);
        bool expectOk = amount == 0 || !_usdgBlocked(who);
        uint256[] memory before = _snap();
        (bool ok, bytes memory ret) = _call(who, address(book), abi.encodeCall(book.claimOwed, ()));
        _expect("claimOwed", expectOk, ok, ret);
        if (ok && amount != 0) ++nOwedClaims;
        _inv5("claimOwed", who, before, _none(), _none(), 0);
    }

    function prune(uint256 idsSeed, uint16 dt) external {
        _advanceKeeper(dt);
        uint256 last = book.lastOrderId();
        if (last == 0) return;
        uint256[] memory ids = new uint256[](1 + idsSeed % 5);
        for (uint256 j; j < ids.length; ++j) {
            // one past the last id is an unknown order, which prune must skip
            ids[j] = 1 + (idsSeed >> (8 + 16 * j)) % (last + 1);
        }
        uint256[] memory before = _snap();
        (bool ok, bytes memory ret) = _call(keeper, address(book), abi.encodeCall(book.prune, (ids)));
        _expect("prune", true, ok, ret);
        if (ok && abi.decode(ret, (uint256)) != 0) ++nPrunes;
        _inv5("prune", keeper, before, _none(), _none(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                         SETTLEMENT ACTIONS
    //////////////////////////////////////////////////////////////*/

    function snapshot(uint8 e, uint16 dt) external {
        _advanceKeeper(dt);
        uint40 expiry = _expiryIn(e);
        uint256[] memory before = _snap();
        (bool ok, bytes memory ret) =
            _call(keeper, address(oracle), abi.encodeCall(oracle.snapshot, (address(nvda), expiry)));
        _expect("snapshot", clock >= expiry, ok, ret);
        _inv5("snapshot", keeper, before, _none(), _none(), 0);
    }

    function finalize(uint8 e, uint16 dt) external {
        _advanceKeeper(dt);
        uint40 expiry = _expiryIn(e);
        (V2Types.SettlementStatus was,) = oracle.settlementPrice(address(nvda), expiry);
        uint256[] memory before = _snap();
        (bool ok, bytes memory ret) =
            _call(keeper, address(oracle), abi.encodeCall(oracle.finalize, (address(nvda), expiry)));
        _expect("finalize", clock >= uint256(expiry) + V2Constants.FINALIZE_DELAY, ok, ret);
        if (ok && was != V2Types.SettlementStatus.Finalized) _countFinal(expiry);
        _inv5("finalize", keeper, before, _none(), _none(), 0);
    }

    function settle(uint8 s, uint16 dt) external {
        _advanceKeeper(dt);
        if (series.length == 0) return;
        _settleOne("settle", _seriesIn(s, EXPIRED));
    }

    /// @dev One keeper settle of `longId`, predicted, with the settlement ghosts booked when it advances.
    function _settleOne(string memory action, uint256 longId) internal {
        V2Types.Series memory sr = ch.series(longId);
        (V2Types.SettlementStatus was,) = oracle.settlementPrice(address(nvda), sr.expiry);
        uint256[] memory before = _snap();
        (bool ok, bytes memory ret) = _call(keeper, address(ch), abi.encodeCall(ch.settle, (longId)));
        _expect(action, clock >= sr.expiry, ok, ret);
        if (ok && abi.decode(ret, (bool))) {
            ++nSettles;
            settleSeen[longId] = true;
            lockedAtSettle[longId] = ch.locked(longId);
            if (lockedAtSettle[longId] != ch.totalSupply(longId) * _perUnit(sr)) {
                _payoutViolation("locked at settlement != supply x collateral per unit");
            }
            if (sr.oracle == address(oracle) && was != V2Types.SettlementStatus.Finalized) _countFinal(sr.expiry);
        }
        _inv5(action, keeper, before, _none(), _none(), 0);
    }

    function redeem(uint8 s, bool short, uint8 h, uint8 c, uint16 dt) external {
        _advanceKeeper(dt);
        if (series.length == 0) return;
        uint256 longId = _seriesIn(s, SETTLED);
        uint256 id = short ? V2Ids.shortIdOf(longId) : longId;
        bool bookHolder = h % 5 == 4;
        address holder = bookHolder ? address(book) : _holderOf(id, h);
        // caller: the keeper, the holder itself, or another actor
        address caller = c % 3 == 0 ? keeper : (c % 3 == 1 && !bookHolder ? holder : _actor(c / 3));
        bool settled = ch.series(longId).settled;
        bool mayRedeem = caller == holder || ch.thirdPartyRedeemAllowed(holder) || ch.isOperator(holder, caller);
        bool expectOk = settled && mayRedeem;

        Payout memory pay = _payoutBefore(id, holder);
        uint256 rewardsBefore = usdg.balanceOf(address(rewards));
        uint256[] memory before = _snap();
        (bool ok, bytes memory ret) = _call(caller, address(ch), abi.encodeCall(ch.redeem, (id, holder)));
        _expect("redeem", expectOk, ok, ret);
        uint8 burnMask;
        if (ok) {
            uint256 bounty = caller == holder ? rewardsBefore - usdg.balanceOf(address(rewards)) : 0;
            _checkFees(pay.asset, pay.fees, _payoutAfter(pay, bounty));
            burnMask = _maskOf(holder);
        }
        _inv5("redeem", caller, before, _none(), _none(), burnMask);
    }

    function redeemBatch(uint8 s, bool short, uint8 mask, uint16 dt) external {
        _advanceKeeper(dt);
        if (series.length == 0) return;
        uint256 longId = _seriesIn(s, SETTLED);
        uint256 id = short ? V2Ids.shortIdOf(longId) : longId;
        address[] memory holders = new address[](5);
        uint256 n;
        for (uint256 i; i < 5; ++i) {
            if ((mask >> i) & 1 == 0) continue;
            holders[n++] = i == 4 ? address(book) : actors[i];
        }
        assembly ("memory-safe") {
            mstore(holders, n)
        }
        Payout[] memory pays = new Payout[](n);
        for (uint256 i; i < n; ++i) {
            pays[i] = _payoutBefore(id, holders[i]);
        }
        uint256[] memory before = _snap();
        (bool ok, bytes memory ret) = _call(keeper, address(ch), abi.encodeCall(ch.redeemBatch, (id, holders)));
        _expect("redeemBatch", ch.series(longId).settled, ok, ret);
        uint8 burnMask;
        if (ok && n != 0) {
            uint256 fees;
            for (uint256 i; i < n; ++i) {
                // a holder the keeper may not redeem (opted out, or the book) must be left untouched
                if (!ch.thirdPartyRedeemAllowed(holders[i]) && holders[i] != keeper) {
                    if (ch.balanceOf(holders[i], id) != pays[i].balance) {
                        _payoutViolation("redeemBatch redeemed a holder that opted out");
                    }
                    continue;
                }
                fees += _payoutAfter(pays[i], 0);
                burnMask |= _maskOf(holders[i]);
            }
            _checkFees(pays[0].asset, pays[0].fees, fees);
        }
        _inv5("redeemBatch", keeper, before, _none(), _none(), burnMask);
    }

    function sweepFees(bool isUsdg, uint16 dt) external {
        _advanceKeeper(dt);
        address asset = isUsdg ? address(usdg) : address(nvda);
        uint256 accrued = ch.accruedFees(asset);
        bool expectOk = !(isUsdg && accrued != 0 && usdg.paused());
        // MIRROR, DO NOT RE-REASON: the sweep destination is the Clearinghouse's {feeRecipient}, which the
        // fixture set to the FeeSplitter. Measuring {chFees} here would count every honest sweep as a payout
        // violation the moment C8-09a landed.
        address to = ch.feeRecipient();
        uint256 feesBefore = _bal(asset, to);
        uint256[] memory before = _snap();
        (bool ok, bytes memory ret) = _call(keeper, address(ch), abi.encodeCall(ch.sweepFees, (asset)));
        _expect("sweepFees", expectOk, ok, ret);
        if (ok) {
            uint256 got = _bal(asset, to) - feesBefore;
            if (got != accrued) _payoutViolation("sweep paid other than accrued");
            ghostOut[asset] += got;
        }
        _inv5("sweepFees", keeper, before, _none(), _none(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        WORLD: PRICES AND TIME
    //////////////////////////////////////////////////////////////*/

    /// A feed round one grid step (about 2.3 %) up, down or flat; the pool follows one time in two. When it does not,
    /// the two sources can disagree over a window, which sends the expiry down the candidate path.
    function pushPrice(uint8 move, uint8 follow, uint16 dt) external {
        _advance(dt);
        uint256 m = move % 3;
        if (m == 0 && level > 0) --level;
        else if (m == 2 && level < 8) ++level;
        _printFeed();
        if (follow % 2 == 0) _printPool();
    }

    /// Jumps to an instant that matters for a listed expiry: its cutoff, expiry, snapshot time, finalize time, or the
    /// end of an uncorroborated delay; or just forward by up to 12 hours.
    function warp(uint8 mode, uint8 e, uint32 secondsSeed) external {
        uint256 expiry = expiries[(e >> 1) % EXPIRIES];
        if (e & 1 == 0) {
            // the first expiry that is upcoming or passed less than 7 hours ago
            for (uint256 k; k < EXPIRIES; ++k) {
                if (uint256(expiries[k]) + 7 hours > clock) {
                    expiry = expiries[k];
                    break;
                }
            }
        }
        uint256 target;
        uint256 m = mode % 6;
        if (m == 1) target = expiry - V2Constants.SETTLEMENT_WINDOW;
        else if (m == 2) target = expiry;
        else if (m == 3) target = expiry + 60;
        else if (m == 4) target = expiry + V2Constants.FINALIZE_DELAY;
        else if (m == 5) target = expiry + 6 hours + 180;
        if (target <= clock || target > clock + 4 days) {
            _warpTo(clock + _bound(secondsSeed, 1, 12 hours));
            return;
        }
        _warpTo(target);
    }

    /*//////////////////////////////////////////////////////////////
                      UNAUTHORISED ATTEMPTS (INV. 5)
    //////////////////////////////////////////////////////////////*/

    /// An actor tries to move another actor's value without being its operator or delegate: write on its collateral,
    /// pull its tokens, cancel, replace or place orders for it, or call the Clearinghouse's self-only entry points.
    /// Every attempt must revert, and invariant 5 checks the victim's balances around it.
    function attack(uint8 a, uint8 v, uint8 kind, uint256 seed, uint16 dt) external {
        _advance(dt);
        address attacker = _actor(a);
        address victim = _actor(uint256(a) + 1 + v % 3);
        uint256 k = kind % 7;
        bytes memory data;
        address target = address(ch);
        if (k == 0) {
            if (series.length == 0) return;
            data = abi.encodeCall(ch.mint, (_series(seed), 1, victim, attacker));
        } else if (k == 1) {
            if (series.length == 0) return;
            uint256 id = seed & 1 == 0 ? _series(seed >> 1) : _series(seed >> 1) | 1;
            data = abi.encodeCall(ch.safeTransferFrom, (victim, attacker, id, 1, ""));
        } else if (k == 2 || k == 3) {
            (uint256[] memory ids,) = book.ordersOfMaker(victim, 0, 200);
            if (ids.length == 0) return;
            uint256 id = ids[seed % ids.length];
            target = address(book);
            data = k == 2 ? abi.encodeCall(book.cancel, (_one(id))) : abi.encodeCall(book.replace, (id, 10_000, 1));
        } else if (k == 4) {
            if (series.length == 0) return;
            target = address(book);
            data = abi.encodeCall(book.placeFor, (victim, _series(seed), V2Types.OrderKind(seed % 3), 10_000, 1, 0));
        } else if (k == 5) {
            if (series.length == 0) return;
            data = abi.encodeCall(ch.batchRedeemOne, (_series(seed), victim, attacker));
        } else {
            data = abi.encodeCall(ch.convertPayout, (address(nvda), 1, 0, attacker));
        }
        uint256[] memory before = _snap();
        (bool ok, bytes memory ret) = _call(attacker, target, data);
        _expect("attack", false, ok, ret);
        _inv5("attack", attacker, before, _none(), _none(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                    ROLES: PAUSES, FAULTS, GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    /// Guardian flips one of the three new-risk pauses. Like every toggle, only one call in four acts, so pauses and
    /// faults are on for part of a run rather than most of it.
    function togglePause(uint8 which) external {
        if (which % 4 != 0) return;
        uint256 w = (which / 4) % 3;
        vm.startPrank(guardian);
        if (w == 0) ch.setMintPaused(address(nvda), !ch.market(address(nvda)).mintPaused);
        else if (w == 1) ch.setCreatePaused(!ch.createPaused());
        else book.setTradingPaused(!book.tradingPaused());
        vm.stopPrank();
    }

    /// Oracle faults: the feed reverts, the pool reverts, the issuer pauses its oracle, the admin removes the market's
    /// sources, the admin points NEW series at an oracle that reverts on every call, or the cranker misses snapshots.
    function toggleOracleFault(uint8 which) external {
        if (which % 4 != 0) return;
        uint256 w = (which / 4) % 6;
        if (w == 5) {
            crankerAsleep = !crankerAsleep;
        } else if (w == 0) {
            feed.setReverts(!feed.reverts());
        } else if (w == 1) {
            pool.setObserveReverts(!pool.observeReverts());
        } else if (w == 2) {
            nvda.setOraclePaused(!nvda.oraclePaused());
        } else if (w == 3) {
            _setMarket(marketMode == REMOVED ? HONEST : REMOVED);
        } else {
            badOracleOn = !badOracleOn;
            V2Types.MarketConfig memory m = ch.market(address(nvda));
            m.oracle = badOracleOn ? badOracle : address(oracle);
            // startPrank, NOT prank: _reconfigure makes three restricted calls and one prank covers only the
            // first. See the helper's NatSpec.
            vm.startPrank(admin);
            _reconfigure(ch, address(nvda), m);
            vm.stopPrank();
        }
    }

    /// The admin reconfigures settlement MID-LIFE, which must reach only expiries no series has pinned (owner decision
    /// 2026-09-17): the oracle market flips to or from the evil list ([evil source, Chainlink], 1000 bps, 30 min), the
    /// Chainlink source to or from the evil feed with its loosest bounds, the pool source to or from the evil pool with
    /// the smallest legal floor (EVIL_POOL_MIN_LIQUIDITY; zero is refused since T-OP-062). Everything evil prices NVDA
    /// at 400 USDG. Invariant 6 checks that an expiry keeps what it pinned.
    function reconfigure(uint8 which) external {
        if (which % 4 != 0) return;
        uint256 w = (which / 4) % 4;
        ++nReconfigured;
        if (w == 0) {
            _setMarket(marketMode == EVIL ? HONEST : EVIL);
            return;
        }
        vm.startPrank(admin);
        if (w == 1) {
            evilFeedOn = !evilFeedOn;
            ChainlinkFeedSource cl = ChainlinkFeedSource(clSource);
            if (evilFeedOn) {
                cl.setFeed(address(nvda), address(evilFeed), cl.MAX_MAX_STALE(), cl.MAX_ROUND_JUMP_CEIL_BPS());
            } else {
                cl.setFeed(address(nvda), address(feed), cl.DEFAULT_MAX_STALE(), cl.DEFAULT_MAX_ROUND_JUMP_BPS());
            }
        } else if (w == 2) {
            evilPoolOn = !evilPoolOn;
            UniV3TwapSource ps = UniV3TwapSource(poolSource);
            ps.setPool(
                address(nvda),
                evilPoolOn ? address(evilPool) : address(pool),
                evilPoolOn ? EVIL_POOL_MIN_LIQUIDITY : 1e18,
                ps.DEFAULT_WINDOW()
            );
        } else {
            // INTERFACE_VERSION 8: a 10 % discount module on/off, so takes in the campaign sometimes run discounted
            // and `invariant_book_takesConserveAndRebatesStayUnderTheFee` checks rebates against the DISCOUNTED fee.
            discountOn = !discountOn;
            discount.setBps(discountOn ? 1_000 : 0);
            book.setDiscountModule(IFeeDiscount(discountOn ? address(discount) : address(0)));
        }
        vm.stopPrank();
    }

    /// The admin's pinning attacks, each predicted from the pin model (one call in four acts): take the oracle off (or
    /// back onto) the Chainlink or the pool source's allow-list; point the oracle's Clearinghouse pointer at {shadow},
    /// pin a listed expiry through it and restore the pointer; list {shadow} on the Chainlink or the pool source, pin a
    /// listed expiry directly and delist it. Whatever configuration is current at the time is what gets pinned, so a
    /// later {reconfigure} turns a pre-pin into a hidden one; invariant 6 checks that no series is created on it.
    /// `which / 4` picks the attack (mod 5) and the expiry (the quotient by 5, mod EXPIRIES).
    function pinningAttack(uint8 which) external {
        if (which % 4 != 0) return;
        uint256 seed = which / 4;
        uint256 kind = seed % 5;
        uint40 expiry = expiries[(seed / 5) % EXPIRIES];
        vm.startPrank(admin);
        if (kind == 0) {
            clRevoked = !clRevoked;
            ChainlinkFeedSource(clSource).setOracle(address(oracle), !clRevoked);
        } else if (kind == 1) {
            poolRevoked = !poolRevoked;
            UniV3TwapSource(poolSource).setOracle(address(oracle), !poolRevoked);
        }
        vm.stopPrank();
        if (kind < 2) return;

        ++nPrePins;
        bool expectOk;
        bool ok;
        bytes memory ret;
        if (kind == 2) {
            expectOk = _pinWouldSucceed(expiry, shadow);
            vm.prank(admin);
            oracle.setClearinghouse(shadow);
            (ok, ret) = _call(shadow, address(oracle), abi.encodeCall(oracle.pin, (address(nvda), expiry)));
            vm.prank(admin);
            oracle.setClearinghouse(address(ch));
            _expect("pre-pin through the Clearinghouse pointer", expectOk, ok, ret);
            if (ok) _applyPin(expiry, shadow);
            return;
        }
        address source = kind == 3 ? clSource : poolSource;
        expectOk = kind == 3
            ? _sourcePinWouldSucceed(ghostFeedPin[expiry], evilFeedOn)
            : _sourcePinWouldSucceed(ghostPoolPin[expiry], evilPoolOn);
        vm.prank(admin);
        ChainlinkFeedSource(source).setOracle(shadow, true);
        (ok, ret) = _call(shadow, source, abi.encodeCall(ChainlinkFeedSource.pin, (address(nvda), expiry)));
        vm.prank(admin);
        ChainlinkFeedSource(source).setOracle(shadow, false);
        _expect("pre-pin through a source allow-list", expectOk, ok, ret);
        if (!ok) return;
        if (kind == 3 && ghostFeedPin[expiry] == NO_PIN) ghostFeedPin[expiry] = evilFeedOn ? PIN_EVIL : PIN_HONEST;
        if (kind == 4 && ghostPoolPin[expiry] == NO_PIN) ghostPoolPin[expiry] = evilPoolOn ? PIN_EVIL : PIN_HONEST;
    }

    /// @dev The admin sets the oracle market to `mode`.
    function _setMarket(uint8 mode) internal {
        address[] memory sources;
        uint16 dev;
        uint32 delay;
        if (mode != REMOVED) {
            sources = new address[](2);
            (sources[0], sources[1]) = mode == EVIL ? (address(evilSource), clSource) : (clSource, poolSource);
        }
        if (mode == EVIL) (dev, delay) = (1000, 30 minutes);
        marketMode = mode;
        vm.prank(admin);
        oracle.setMarket(address(nvda), sources, dev, delay, 0);
    }

    /// The USDG issuer pauses the token or freezes an actor.
    function toggleUsdg(uint8 which, uint8 a) external {
        if (which % 4 != 0) return;
        if ((which / 4) % 2 == 0) {
            if (usdg.paused()) usdg.unpause();
            else usdg.pause();
        } else {
            address who = _actor(a);
            if (usdg.isFrozen(who)) usdg.unfreeze(who);
            else usdg.freeze(who);
        }
    }

    /// An actor flips its payout-to-ledger or third-party-redeem preference.
    function setPrefs(uint8 a, uint8 which) external {
        address who = _actor(a);
        if (which % 2 == 0) {
            (, bool toLedger) = ch.payoutPrefs(who);
            vm.prank(who);
            ch.setPayoutToLedger(!toLedger);
        } else {
            bool allowed = ch.thirdPartyRedeemAllowed(who);
            vm.prank(who);
            ch.setThirdPartyRedeem(!allowed);
        }
    }

    /// Guardian veto or unveto, or an admin resolve inside the recorded band after RESOLVE_DELAY (the band the resolve
    /// will check: see {_bandAfterRefresh}).
    function governSettlement(uint8 e, uint8 which, uint16 dt) external {
        _advance(dt);
        uint40 expiry = _expiryIn(e);
        (V2Types.SettlementStatus status,) = oracle.settlementPrice(address(nvda), expiry);
        bool isFinal = status == V2Types.SettlementStatus.Finalized;
        // veto one call in six, unveto one in six, resolve the rest (a resolve only acts after RESOLVE_DELAY)
        uint256 w = which % 6 > 2 ? 2 : which % 6;
        bool ok;
        bytes memory ret;
        if (w == 0) {
            (ok, ret) = _call(guardian, address(oracle), abi.encodeCall(oracle.veto, (address(nvda), expiry)));
            _expect("veto", !isFinal, ok, ret);
        } else if (w == 1) {
            (ok, ret) = _call(guardian, address(oracle), abi.encodeCall(oracle.unveto, (address(nvda), expiry)));
            _expect("unveto", !isFinal, ok, ret);
        } else {
            (bool bounded, uint256 lo, uint256 hi) = _bandAfterRefresh(expiry, status);
            uint256 price = bounded ? (lo + hi) / 2 : 200_000_000 + level * 5_000_000;
            (ok, ret) =
                _call(admin, address(oracle), abi.encodeCall(oracle.adminResolve, (address(nvda), expiry, price)));
            bool early = clock < uint256(expiry) + V2Constants.RESOLVE_DELAY;
            // Unbounded now may become bounded by the capture adminResolve performs first: either outcome is legal.
            if (bounded || early || isFinal) _expect("adminResolve", !early && !isFinal, ok, ret);
            if (ok) ++nResolved;
        }
    }

    /// @dev SettlementOracle.resolveBand as adminResolve will check it: for a captured expiry, a not-ok entry whose source
    ///      answers now counts as the resolve's refresh will record it. Without that the midpoint of the band read before
    ///      the refresh could fall outside the one checked after it: from expiry + 7 days a Held expiry with one ok price
    ///      has the wide band, and a second price recorded by the refresh narrows it (sweep contracts-c12). An expiry not
    ///      captured yet reads the view as before (the capture may bound it either way).
    function _bandAfterRefresh(uint40 expiry, V2Types.SettlementStatus status)
        internal
        view
        returns (bool bounded, uint256 lo, uint256 hi)
    {
        (address[] memory srcs, bool[] memory ok, uint256[] memory prices, uint16 dev) =
            oracle.recordedSources(address(nvda), expiry);
        if (srcs.length == 0) return oracle.resolveBand(address(nvda), expiry);
        uint256 minP = type(uint256).max;
        uint256 maxP;
        uint256 okCount;
        for (uint256 i; i < srcs.length; ++i) {
            uint256 p = prices[i];
            if (!ok[i]) {
                (bool success, bytes memory ret) = srcs[i].staticcall(
                    abi.encodeCall(
                        IPriceSource.windowPrice, (address(nvda), expiry - V2Constants.SETTLEMENT_WINDOW, expiry)
                    )
                );
                if (!success || ret.length < 64) continue;
                (uint256 okWord, uint256 answer) = abi.decode(ret, (uint256, uint256));
                if (okWord != 1 || answer == 0 || answer > type(uint128).max) continue;
                p = answer;
            }
            ++okCount;
            if (p < minP) minP = p;
            if (p > maxP) maxP = p;
        }
        if (okCount == 0) return (false, 0, 0);
        if (okCount == 1 && status == V2Types.SettlementStatus.Held && clock >= uint256(expiry) + 7 days) {
            return (true, minP * 8_000 / 10_000, maxP * 10_000 / 8_000);
        }
        return (true, minP * (10_000 - dev) / 10_000, maxP * (10_000 + dev) / 10_000);
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNALS
    //////////////////////////////////////////////////////////////*/

    struct Payout {
        uint256 id;
        address holder;
        address asset;
        uint256 balance;
        uint256 perUnit;
        uint256 feePerUnit;
        uint256 wallet;
        uint256 ledger;
        uint256 fees;
    }

    function _payoutBefore(uint256 id, address holder) internal view returns (Payout memory p) {
        uint256 longId = id & ~uint256(1);
        V2Types.Series memory sr = ch.series(longId);
        p.id = id;
        p.holder = holder;
        (p.asset,) = _collateral(sr);
        p.balance = ch.balanceOf(holder, id);
        p.perUnit = id == longId ? sr.longPayoutPerUnit : sr.shortPayoutPerUnit;
        p.feePerUnit = id == longId ? sr.feePerUnit : 0;
        p.wallet = _bal(p.asset, holder);
        p.ledger = ch.free(holder, p.asset);
        p.fees = ch.accruedFees(p.asset);
    }

    /// @dev Checks one redeemed holder: the whole balance burned and the holder paid exactly balance x per unit (wallet
    ///      or ledger); books the ghosts. Returns balance x fee per unit, the exercise fee this holder's burn must
    ///      accrue: the caller compares the accrued delta of the whole call ({_checkFees}), which may redeem several.
    function _payoutAfter(Payout memory p, uint256 bountyToHolder) internal returns (uint256 fee) {
        uint256 walletNow = _bal(p.asset, p.holder);
        if (p.asset == address(usdg)) walletNow -= bountyToHolder;
        uint256 walletGain = walletNow - p.wallet;
        uint256 owed = walletGain + (ch.free(p.holder, p.asset) - p.ledger);
        fee = p.balance * p.feePerUnit;
        if (ch.balanceOf(p.holder, p.id) != 0) _payoutViolation("redeem left a balance");
        if (owed != p.balance * p.perUnit) _payoutViolation("holder paid other than balance x per unit");
        ghostOut[p.asset] += walletGain;
        paidOut[p.id & ~uint256(1)] += owed + fee;
        if (owed != 0) ++nRedeemsPaid;
    }

    function _checkFees(address asset, uint256 before, uint256 expected) internal {
        if (ch.accruedFees(asset) - before != expected) {
            _payoutViolation("fees accrued other than balance x fee per unit");
        }
    }

    function _take(string memory action, address taker, V2Types.TakeParams memory p, bool expectOk) internal {
        uint256[] memory before = _snap();
        uint256 bookBefore = usdg.balanceOf(address(book));
        uint256 owedBefore = _owedTotal();
        vm.recordLogs();
        (bool ok, bytes memory ret) = _call(taker, address(book), abi.encodeCall(book.take, (p)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _expect(action, expectOk, ok, ret);
        uint256[4] memory usdgDrop;
        uint256[4] memory nvdaDrop;
        if (ok) {
            (uint64 units, uint256 premium, uint256 takerFee) = abi.decode(ret, (uint64, uint256, uint256));
            V2Types.Series memory sr = ch.series(p.longId);
            (address asset, uint256 perUnit) = _collateral(sr);
            uint256 rebates;
            uint256 premiums;
            uint256 filled;
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].emitter != address(book) || logs[i].topics[0] != IOrderBook.OrderFilled.selector) continue;
                (address maker, uint64 u,, uint256 prem,, uint256 rebate, bool primary,,) =
                    abi.decode(logs[i].data, (address, uint64, uint128, uint256, uint256, uint256, bool, bool, address));
                rebates += rebate;
                premiums += prem;
                filled += u;
                if (p.buying && primary) {
                    uint256 idx = _indexOf(maker);
                    // INTERFACE_VERSION 7: a filled AskWrite costs its maker the collateral AND the mint rent, out of
                    // the same ledger balance, so invariant 5's allowance for "another actor's ledger moved because
                    // its own write ask filled" has to cover both.
                    uint256 cost = u * perUnit;
                    cost += OptionMath.mintFee(cost, sr.mintFeePpm, sr.expiry - clock);
                    if (asset == address(usdg)) usdgDrop[idx] += cost;
                    else nvdaDrop[idx] += cost;
                }
                ++nFills;
            }
            if (rebates > takerFee) _takeViolation(action, "rebates exceed the taker fee");
            if (premiums != premium || filled != units) _takeViolation(action, "fills do not add up to the take");
            uint256 bookAfter = usdg.balanceOf(address(book));
            uint256 owedDelta = _owedTotal() - owedBefore;
            // Buying: everything pulled is paid out or owed. Selling: the bids' escrow pays the premium, all of it
            // paid out or owed. Either way the book never pays out more than it takes in.
            if (p.buying ? bookAfter - bookBefore != owedDelta : bookBefore - bookAfter + owedDelta != premium) {
                _takeViolation(action, "book USDG moved other than escrow and owed");
            }
        }
        _inv5(action, taker, before, usdgDrop, nvdaDrop, 0);
    }

    function _takeParams(
        uint256 longId,
        bool buying,
        uint256[] memory ids,
        uint64 units,
        uint32 limitSeed,
        bool writeToSell,
        address recipient
    ) internal view returns (V2Types.TakeParams memory) {
        uint128 limit = buying ? type(uint128).max : 0;
        if (limitSeed % 4 == 1) limit = _price(limitSeed >> 2);
        return V2Types.TakeParams({
            longId: longId,
            buying: buying,
            orderIds: ids,
            units: uint64(_bound(units, 1, 300)),
            minUnits: 0,
            limitPrice: limit,
            writeToSell: writeToSell,
            recipient: recipient,
            // casting to 'uint40' is safe because simulated time stays far below 2^40
            // forge-lint: disable-next-line(unsafe-typecast)
            deadline: uint40(clock),
            // v8: hard cap on the taker-side fees; the existing cases assert fee behaviour elsewhere, so they opt out
            maxTotalFee: type(uint128).max
        });
    }

    function _countFinal(uint40 expiry) internal {
        (V2Types.SettlementStatus status,,, bool corroborated, bool resolved,) =
            oracle.settlementInfo(address(nvda), expiry);
        if (status != V2Types.SettlementStatus.Finalized || resolved) return;
        if (corroborated) ++nCorroborated;
        else ++nUncorroborated;
        if (ghostPinnedHonest[expiry] && (marketMode != HONEST || evilFeedOn || evilPoolOn)) {
            ++nPinnedFinalsUnderChange;
        }
    }

    /// @dev Invariant 5 around one call (see the contract NatSpec).
    function _inv5(
        string memory action,
        address caller,
        uint256[] memory before,
        uint256[4] memory usdgDrop,
        uint256[4] memory nvdaDrop,
        uint8 burnMask
    ) internal {
        uint256[] memory afterSnap = _snap();
        uint256 n = before.length < afterSnap.length ? before.length : afterSnap.length;
        for (uint256 i; i < 4; ++i) {
            if (actors[i] == caller) continue;
            uint256 o = i * 4;
            if (afterSnap[o] < before[o]) _inv5Violation(action, "another actor's USDG wallet fell");
            if (afterSnap[o + 1] < before[o + 1]) _inv5Violation(action, "another actor's NVDA wallet fell");
            if (_drop(before[o + 2], afterSnap[o + 2]) != usdgDrop[i]) {
                _inv5Violation(action, "another actor's USDG ledger moved other than its filled write asks");
            }
            if (_drop(before[o + 3], afterSnap[o + 3]) != nvdaDrop[i]) {
                _inv5Violation(action, "another actor's NVDA ledger moved other than its filled write asks");
            }
            if ((burnMask >> i) & 1 == 1) continue;
            for (uint256 j = 16 + i; j < n; j += 4) {
                if (afterSnap[j] < before[j]) _inv5Violation(action, "another actor's option tokens fell");
            }
        }
    }

    /// @dev [usdg wallet, nvda wallet, usdg ledger, nvda ledger] per actor, then the long and short balance of every
    ///      series per actor, interleaved actor by actor (index 16 + 4k + actor).
    function _snap() internal view returns (uint256[] memory s) {
        uint256 n = series.length;
        s = new uint256[](16 + 8 * n);
        for (uint256 i; i < 4; ++i) {
            address a = actors[i];
            (s[i * 4], s[i * 4 + 1]) = (usdg.balanceOf(a), nvda.balanceOf(a));
            (s[i * 4 + 2], s[i * 4 + 3]) = (ch.free(a, address(usdg)), ch.free(a, address(nvda)));
        }
        if (n == 0) return s;
        uint256 m = 8 * n;
        address[] memory batchAccounts = new address[](m);
        uint256[] memory batchIds = new uint256[](m);
        for (uint256 k; k < n; ++k) {
            for (uint256 i; i < 4; ++i) {
                (batchAccounts[8 * k + i], batchIds[8 * k + i]) = (actors[i], series[k]);
                (batchAccounts[8 * k + 4 + i], batchIds[8 * k + 4 + i]) = (actors[i], series[k] | 1);
            }
        }
        uint256[] memory balances = ch.balanceOfBatch(batchAccounts, batchIds);
        for (uint256 j; j < m; ++j) {
            s[16 + j] = balances[j];
        }
    }

    /// @dev A trader action happens 0-60 minutes after the previous call.
    function _advance(uint16 dt) internal {
        _warpTo(clock + uint256(dt) % (60 minutes + 1));
    }

    /// @dev A keeper action happens 0-5 minutes after the previous call, so a keeper that was woken for an instant
    ///      (see {warp}) still acts inside the snapshot grace.
    function _advanceKeeper(uint16 dt) internal {
        _warpTo(clock + uint256(dt) % (5 minutes + 1));
    }

    /// @dev Moves the clock forward in steps of at most 12 hours. Unless the cranker is asleep, it stops where K2-03's
    ///      cranker acts on a listed expiry: at expiry + 60 it snapshots (inside the grace, before the first finalize);
    ///      at expiry + FINALIZE_DELAY, and again at a pending candidate's finalizableAt, it finalizes and settles the
    ///      expiry's series. Redemption, pruning and every other retry are left to the fuzzed calls.
    function _warpTo(uint256 target) internal {
        while (target > clock) {
            uint256 next = target > clock + 12 hours ? clock + 12 hours : target;
            if (!crankerAsleep) {
                for (uint256 k; k < EXPIRIES; ++k) {
                    uint256 at = _crankAt(expiries[k]);
                    if (at > clock && at < next) next = at;
                }
            }
            _setClock(next);
            if (!crankerAsleep) _crank();
        }
    }

    /// @dev The next instant after now the cranker acts on `expiry`, or 0.
    function _crankAt(uint40 expiry) internal view returns (uint256) {
        if (clock < uint256(expiry) + 60) return uint256(expiry) + 60;
        if (clock < uint256(expiry) + V2Constants.FINALIZE_DELAY) return uint256(expiry) + V2Constants.FINALIZE_DELAY;
        (V2Types.SettlementStatus status,) = oracle.settlementPrice(address(nvda), expiry);
        if (status != V2Types.SettlementStatus.Pending) return 0;
        (,,, uint40 finalizableAt) = oracle.candidate(address(nvda), expiry);
        return finalizableAt;
    }

    /// @dev The cranker's work at this instant (see {_warpTo}).
    function _crank() internal {
        for (uint256 k; k < EXPIRIES; ++k) {
            uint40 expiry = expiries[k];
            if (uint256(expiry) + 60 == clock) {
                uint256[] memory before = _snap();
                (bool ok, bytes memory ret) =
                    _call(keeper, address(oracle), abi.encodeCall(oracle.snapshot, (address(nvda), expiry)));
                _expect("snapshot (cranker)", true, ok, ret);
                _inv5("snapshot (cranker)", keeper, before, _none(), _none(), 0);
                continue;
            }
            bool due = uint256(expiry) + V2Constants.FINALIZE_DELAY == clock;
            if (!due && clock > uint256(expiry) + V2Constants.FINALIZE_DELAY) {
                (V2Types.SettlementStatus status,) = oracle.settlementPrice(address(nvda), expiry);
                (,,, uint40 finalizableAt) = oracle.candidate(address(nvda), expiry);
                due = status == V2Types.SettlementStatus.Pending && finalizableAt == clock;
            }
            if (!due) continue;
            (V2Types.SettlementStatus was,) = oracle.settlementPrice(address(nvda), expiry);
            uint256[] memory snapBefore = _snap();
            (bool fin, bytes memory finRet) =
                _call(keeper, address(oracle), abi.encodeCall(oracle.finalize, (address(nvda), expiry)));
            _expect("finalize (cranker)", true, fin, finRet);
            if (fin && was != V2Types.SettlementStatus.Finalized) _countFinal(expiry);
            _inv5("finalize (cranker)", keeper, snapBefore, _none(), _none(), 0);
            for (uint256 i; i < series.length; ++i) {
                if (ch.series(series[i]).expiry == expiry) _settleOne("settle (cranker)", series[i]);
            }
        }
    }

    function _setClock(uint256 t) internal {
        if (t != clock) {
            clock = t;
            vm.warp(t);
        }
        if (clock >= lastFeedAt + 6 hours) _printFeed();
    }

    function _printFeed() internal {
        // casting to 'int256' is safe: grid prices are below 2^255 / 100
        // forge-lint: disable-next-line(unsafe-typecast)
        feed.push(int256((200_000_000 + level * 5_000_000) * 100), clock);
        // forge-lint: disable-next-line(unsafe-typecast)
        evilFeed.push(int256(EVIL_PRICE * 100), clock);
        lastFeedAt = clock;
    }

    function _printPool() internal {
        if (clock <= lastPoolAt) return;
        // casting to 'uint40' is safe: simulated time stays far below 2^40
        // forge-lint: disable-next-line(unsafe-typecast)
        pool.pushState(uint40(clock), ticks[level], POOL_LIQUIDITY);
        lastPoolAt = clock;
    }

    function _call(address who, address target, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.prank(who);
        (ok, ret) = target.call(data);
    }

    function _expect(string memory action, bool expectOk, bool ok, bytes memory ret) internal {
        if (ok == expectOk) return;
        if (ok) {
            ++unexpectedSuccesses;
            lastSurprise = string.concat(action, ": succeeded where a revert was predicted");
        } else {
            ++unexpectedReverts;
            lastSurprise = string.concat(action, ": reverted ", vm.toString(ret));
        }
    }

    function _inv5Violation(string memory action, string memory what) internal {
        ++inv5Violations;
        lastInv5 = string.concat(action, ": ", what);
    }

    function _payoutViolation(string memory what) internal {
        ++payoutViolations;
        lastPayout = what;
    }

    function _takeViolation(string memory action, string memory what) internal {
        ++takeViolations;
        lastTake = string.concat(action, ": ", what);
    }

    function _topUp(address who, address asset, uint256 amount) internal {
        uint256 have = _bal(asset, who);
        if (have >= amount) return;
        if (asset == address(usdg)) usdg.mint(who, amount - have);
        else nvda.mint(who, amount - have);
    }

    function _usdgBlocked(address who) internal view returns (bool) {
        return usdg.paused() || usdg.isFrozen(who);
    }

    function _bal(address asset, address who) internal view returns (uint256) {
        return asset == address(usdg) ? usdg.balanceOf(who) : nvda.balanceOf(who);
    }

    function _owedTotal() internal view returns (uint256 total) {
        for (uint256 i; i < 4; ++i) {
            total += book.owed(actors[i]);
        }
        total += book.owed(treasury) + book.owed(keeper) + book.owed(ch.feeRecipient());
    }

    function _collateral(V2Types.Series memory sr) internal view returns (address asset, uint256 perUnit) {
        return sr.isPut ? (address(usdg), uint256(sr.strike) / 100) : (address(nvda), UNIT);
    }

    function _perUnit(V2Types.Series memory sr) internal view returns (uint256 perUnit) {
        (, perUnit) = _collateral(sr);
    }

    /// @dev With the seed's bit 255 clear, the first live order (not cancelled, units left, still valid) on the wanted
    ///      side from a seeded position; otherwise, or when there is none, the seeded order whatever it is.
    function _aimOrder(uint256 seed, uint256 last, bool ask) internal view returns (uint256) {
        uint256 start = seed % last;
        if (seed >> 255 == 1) return 1 + start;
        uint256[] memory ids = new uint256[](last);
        for (uint256 i; i < last; ++i) {
            ids[i] = i + 1;
        }
        V2Types.Order[] memory orders = book.getOrders(ids);
        for (uint256 k; k < last; ++k) {
            V2Types.Order memory o = orders[(start + k) % last];
            if (o.cancelled || o.filled == o.units || clock >= o.validUntil) continue;
            if ((o.kind != V2Types.OrderKind.Bid) == ask) return 1 + (start + k) % last;
        }
        return 1 + start;
    }

    /// @dev `first`, then up to four ids of the same series (repeats are legal: the book tries an id once).
    function _pickOrders(uint256 longId, uint256 first, uint256 seed) internal view returns (uint256[] memory ids) {
        (uint256[] memory all,) = book.ordersOfSeries(longId, 0, 200);
        ids = new uint256[](1 + seed % 5);
        ids[0] = first;
        for (uint256 j = 1; j < ids.length; ++j) {
            ids[j] = all[(seed >> (8 + 16 * j)) % all.length];
        }
    }

    function _order(uint256 id) internal view returns (V2Types.Order memory) {
        return book.getOrders(_one(id))[0];
    }

    function _one(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    /// @dev 0.01 to 30.00 USDG per share, on the 0.01 grid (a multiple of PRICE_TICK).
    function _price(uint256 seed) internal pure returns (uint128) {
        return uint128((1 + seed % 3000) * 10_000);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 4];
    }

    function _series(uint256 seed) internal view returns (uint256) {
        return series[seed % series.length];
    }

    /// @dev With the seed's low bit clear, a series in `stage`, so actions mostly hit series where they can act:
    ///        OPEN: before its cutoff; two times in three the one expiring soonest (positions then concentrate on
    ///              series that settle within a run), else the first from a seeded position;
    ///        EXPIRED: expired and not settled, preferring one with supply;
    ///        SETTLED: settled with tokens left to redeem.
    ///      With the low bit set, or when none is in that stage, any series: the gates are exercised too.
    function _seriesIn(uint256 seed, uint8 stage) internal view returns (uint256) {
        uint256 n = series.length;
        if (seed & 1 == 1) return series[(seed >> 1) % n];
        uint256 pick = type(uint256).max;
        uint256 soonest = type(uint256).max;
        for (uint256 k; k < n; ++k) {
            uint256 id = series[((seed >> 2) + k) % n];
            V2Types.Series memory sr = ch.series(id);
            bool supplied = ch.totalSupply(id) + ch.totalSupply(id | 1) != 0;
            if (stage == OPEN && clock < sr.expiry - V2Constants.SETTLEMENT_WINDOW) {
                if ((seed >> 1) % 3 == 2) return id;
                if (sr.expiry < soonest) (soonest, pick) = (sr.expiry, id);
            } else if (stage == EXPIRED && clock >= sr.expiry && !sr.settled) {
                if (supplied) return id;
                if (pick == type(uint256).max) pick = id;
            } else if (stage == SETTLED && sr.settled && supplied) {
                return id;
            }
        }
        return pick != type(uint256).max ? pick : series[(seed >> 1) % n];
    }

    /// @dev With the seed's low bit clear, the latest listed expiry at or before now (the one a keeper works on), or the
    ///      first listed one before any has passed; with the bit set, any listed expiry.
    function _expiryIn(uint256 seed) internal view returns (uint40 expiry) {
        if (seed & 1 == 1) return expiries[(seed >> 1) % EXPIRIES];
        expiry = expiries[0];
        for (uint256 k; k < EXPIRIES && expiries[k] <= clock; ++k) {
            expiry = expiries[k];
        }
    }

    function _indexOf(address who) internal view returns (uint256) {
        for (uint256 i; i < 4; ++i) {
            if (actors[i] == who) return i;
        }
        revert("not an actor");
    }

    function _maskOf(address who) internal view returns (uint8) {
        for (uint256 i; i < 4; ++i) {
            // casting to 'uint8' is safe because i < 4
            // forge-lint: disable-next-line(unsafe-typecast)
            if (actors[i] == who) return uint8(2 ** i);
        }
        return 0;
    }

    /// @dev With the seed's low bit clear, the first series from a seeded position where `who` holds a long (and a short,
    ///      when `both`); otherwise, or when there is none, any series.
    function _seriesHeld(address who, uint256 seed, bool both) internal view returns (uint256) {
        uint256 n = series.length;
        if (seed & 1 == 0) {
            for (uint256 k; k < n; ++k) {
                uint256 id = series[((seed >> 1) + k) % n];
                bool longs = ch.balanceOf(who, id) != 0;
                bool shorts = ch.balanceOf(who, id | 1) != 0;
                if (both ? longs && shorts : longs || shorts) return id;
            }
        }
        return series[(seed >> 1) % n];
    }

    /// @dev With the seed's bit 7 clear, the first actor from a seeded position holding `id`; otherwise any actor.
    function _holderOf(uint256 id, uint256 seed) internal view returns (address) {
        if (seed & 0x80 == 0) {
            for (uint256 k; k < 4; ++k) {
                address who = actors[(seed + k) % 4];
                if (ch.balanceOf(who, id) != 0) return who;
            }
        }
        return _actor(seed);
    }

    function _drop(uint256 before, uint256 afterValue) internal pure returns (uint256) {
        return before > afterValue ? before - afterValue : 0;
    }

    function _none() internal pure returns (uint256[4] memory) {}
}
