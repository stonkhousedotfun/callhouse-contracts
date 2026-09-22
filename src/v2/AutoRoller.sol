// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Managed} from "./access/Managed.sol";
import {IAutoRoller} from "./interfaces/IAutoRoller.sol";
import {IClearinghouse} from "./interfaces/IClearinghouse.sol";
import {IExpiryCalendar} from "./interfaces/IExpiryCalendar.sol";
import {IKeeperRewards} from "./interfaces/IKeeperRewards.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {ISettlementOracle} from "./interfaces/ISettlementOracle.sol";
import {V2Constants} from "./interfaces/V2Constants.sol";
import {V2Errors} from "./interfaces/V2Errors.sol";
import {V2Ids} from "./interfaces/V2Ids.sol";
import {V2Types} from "./interfaces/V2Types.sol";
import {OptionMath} from "./lib/OptionMath.sol";

/// @title AutoRoller
/// @notice Set-and-forget covered calls (roadmap 5.3, architecture §3.8): each period the roller writes a new call
///         series for a writer from the writer's stored strategy and the oracle's spot, and rests a write-on-fill ask
///         for it on the OrderBook. Anyone may call {roll}; nothing the caller passes or chooses sets a strike, a
///         price or a size.
/// @dev UNITS (ADR-04). Prices and strikes are USDG base units (6 dp) per whole share; `units` are 0.01-share units
///      (UNIT = 1e16 underlying base units); strategy rates are basis points of BPS = 10_000; times are unix seconds.
///
///      WHAT THE WRITER APPROVES, AND WHY EACH. Setup is: deposit the underlying into the Clearinghouse ledger,
///      `setPayoutToLedger(true)` (so a settled short's collateral comes back to the ledger and the next period can
///      write it), and three approvals. The roller never holds or moves collateral itself:
///        - OrderBook `setDelegate(roller, true)`: lets the roller place, replace and cancel the writer's AskWrite
///          orders, and nothing else (the book refuses a delegate's Bid or AskResale);
///        - Clearinghouse `setOperator(book, true)`: the BOOK mints the options from the writer's free collateral when
///          a buyer fills the ask. Without it the ask could never fill, so a roll refuses to place one;
///        - Clearinghouse `setOperator(roller, true)`: the writer's consent to be rolled, and what lets the roller
///          redeem the writer's shorts when the writer opted out of third-party redemption. The roller has no code
///          path that mints, so the operator power it is given is never used for anything else.
///      {roll} checks both operator approvals before it places (NotAuthorized) and the book checks the delegate, so a
///      writer who revokes any of them makes the next roll revert without changing anything, and re-approving resumes.
///
///      ONE POSITION PER PERIOD. `position(writer, underlying)` is the series of the current period and its ask. A roll
///      writes a position only when there is none; the position is cleared only once `now >= expiry` and the writer's
///      shorts of that series are settled and redeemed. The next roll's expiry is `nextExpiry(now + minLead)`, strictly
///      after a `now` that is already past the old expiry, so every position of a (writer, underlying) has a strictly
///      later expiry than the one before: at most one roll, one {Rolled} and one ROLL bounty per period, however often
///      and by whomever {roll} is called. {stop}, {setStrategy} and {cancelStale} keep the position: a strategy paused
///      and resumed inside a period, or an ask withdrawn inside it, rolls again in the next period, never twice in one.
///
///      WHEN THE MARKET OVERTAKES THE ASK (INTERFACE_VERSION 7, sweep contracts-c16). The ask keeps its roll-time
///      price until the mint cutoff, so a rally past the strike leaves it below intrinsic value. {cancelStale}
///      withdraws it, permissionlessly, once a fresh spot has reached the strike; {reprice} refuses to move an ask
///      whose spot has reached the strike (InTheMoney), because every price its band allows is below intrinsic; and
///      inside the first {ROLL_OPEN_GRACE} of a session {roll} waits unless the reading it holds was itself observed
///      in session that day, so a gap at the open is not written on yesterday's close. None of the three moves
///      collateral, and none of them re-rolls inside the period: a rally costs the writer the rest of the period's
///      premium and leaves it holding the stock.
///
///      WHICH ORACLE JUDGES A SERIES THAT EXISTS (T-310). `createSeries` pins the market's oracle of the moment into
///      the series (`Series.oracle`) and {Clearinghouse.settle} settles it on that one, so a CONFIG_ADMIN
///      `setMarketOracle` only ever reaches series created after it. Every check this contract makes on a series that
///      already exists therefore reads the SERIES' PINNED ORACLE, resolved in one place ({_pinned}): {cancelStale}'s
///      trigger, {reprice}'s InTheMoney test and band, and {roll}'s out-of-the-money check when the series it plans
///      was created earlier by someone else. Only the plan itself (spot, strike, price) reads the market's current
///      oracle, because a series the roll creates is pinned to exactly that oracle. Reading
///      `clearinghouse.market(underlying).oracle` for an existing series would judge it against a price it never
///      settles on: whenever the two oracles disagree, that either keeps an in-the-money ask resting and repriceable
///      or withdraws one that is still out of the money.
///
///      WHAT A CALLER CAN AND CANNOT CHOOSE. strike, price and expiry are functions of the strategy, the market's
///      strikeTick and the oracle's spot at the moment of the call; size is the writer's free collateral (capped by
///      maxUnits). A caller chooses only WHEN inside a regular session to call, which moves the result only as far as
///      spot moves, and (for a daily strategy) whether a call after 14:00 New York writes tomorrow's expiry. Rolling is
///      restricted to 09:30-16:00 New York because Chainlink advises against opening positions on overnight prints
///      (architecture §3.2). The only way a third party changes a size is by donating collateral to the writer's
///      ledger (`deposit(asset, amount, writer)`), which cannot leave the writer worse off.
///
///      ROUNDING. strike = spot x (BPS + otmBps) / BPS rounded UP to the market's strikeTick, so the strike is never
///      closer to spot than the strategy asks; price = spot x askBps / BPS rounded UP to PRICE_TICK, so the ask is
///      never below the strategy's rate. Both round the exact rational value (ceilDiv first), not a floored one.
///
///      RETURN VALUE VS REVERT. {roll} returns false for "nothing to do now", which a keeper loop hits routinely: the
///      period is already rolled, the previous series is not settled yet, outside the regular session, inside the first
///      {ROLL_OPEN_GRACE} of a session on a spot observed before the session opened, spot not fresh
///      (SettlementOracle.trySpot not ok), no expiry found, nothing to write, or a planned series that already exists
///      on another oracle which does not have it fresh and out of the money. It reverts for states only the writer,
///      the admin or the guardian can change: a missing approval (NotAuthorized), a disabled or mint-paused market
///      (MarketDisabled, MintPaused), book trading or series creation paused (TradingPaused, CreatePaused), or a writer
///      who opted out of third-party redemption and revoked the roller (ThirdPartyRedeemDisabled). A keeper simulates
///      first and skips reverting writers. A call that closes out a position only closes out, so the placement
///      reverts can never undo a close-out; the next call places (sweep contracts-c18).
///
///      BOUNTIES PASS THROUGH. The roller calls Clearinghouse.settle and redeem, which pay their SETTLE and REDEEM
///      bounties to their caller, the roller. {roll} forwards any USDG this contract holds to its own caller right
///      after those calls, so the keeper who paid the gas gets them and the roller holds no funds between calls. The
///      ROLL bounty is paid by KeeperRewards straight to the caller, only for a roll that places at least
///      {minRollUnits} (architecture §3.7), through a raw call that cannot revert the roll.
///
///      TRUST (ADR-09, INTERFACE_VERSION 8). The roller is {Managed}: it holds no role table of its own and grants
///      nothing. One `AccessManager` maps (this contract, selector) to a role id, per `script/v2/roles.v8.json`:
///      `setKeeperRewards` is CONFIG_ADMIN (24 h), `setMinRollUnits` is LISTING (1 h) and {reprice} is PRICER (0).
///      PRICER can only replace a smart-pricing writer's live ask at a price inside the writer's own
///      [minAskBps, maxAskBps] band of spot -- never below MIN_ASK_BPS of spot, and never more than
///      MAX_REPRICE_DROP_BPS below the ask it replaces in one call (SEC-13) -- keeping its size and expiry. No role
///      can roll a writer into anything the strategy does not say, or touch collateral. {setStrategy}, {stop}, {roll}
///      and {cancelStale} carry no role at all: the first two are the writer's own, the last two are permissionless
///      keeper calls. Calls only in v2.0.
contract AutoRoller is IAutoRoller, Managed, ReentrancyGuardTransient {
    /// @notice {reprice} asked for `proposed` against a live ask at `current`, below the lowest price one call may
    ///         reach, `floor = current x (BPS - MAX_REPRICE_DROP_BPS) / BPS`, rounded up to the price tick.
    /// @dev Declared here rather than in `V2Errors` / `IAutoRoller` (both outside T-OP-063's fence); moving it is a
    ///      one-line follow-up that does not change its selector.
    error RepriceDropExceeded(uint128 current, uint128 proposed, uint256 floor);

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Strategy bounds, bps of spot: strike distance above spot and ask price (architecture §3.8).
    uint16 public constant MIN_OTM_BPS = 100;
    uint16 public constant MAX_OTM_BPS = 2500;
    /// @dev SEC-13, owner ruling 2026-09-22 (T-OP-063): the compiled floor under every ask, including the floor of a
    ///      smart-pricing writer's [minAskBps, maxAskBps] band. Was 5 (0.05 % of spot), which let a leaked 0-delay
    ///      PRICER key reprice a live ask to a twentieth of a percent of spot in one call for any writer who never
    ///      raised `minAskBps` -- premium gone, principal safe. 50 (0.5 %) is the coordinator's number and the owner
    ///      may retune it; it is a compiled floor rather than a per-writer default because the finding is the key,
    ///      not the writer. Consumers that pin the value: `script/v2/VerifyV8.s.sol`, `V2DocsNumbersTest`.
    uint16 public constant MIN_ASK_BPS = 50;
    uint16 public constant MAX_ASK_BPS = 1000;
    /// @notice The most a single {reprice} may LOWER an ask, bps of the ask it replaces: the new price must be at least
    ///         `(BPS - MAX_REPRICE_DROP_BPS) / BPS` of the current one. Raising is not bounded.
    /// @dev SEC-13, owner ruling 2026-09-22 (T-OP-063). With the band alone a leaked PRICER key reaches a writer's
    ///      floor in ONE call; with this cap it takes several, each a `Repriced` event the monitor pages on (ops/
    ///      alerts.md §V62: `v2_mon_reprice_floorward` and `v2_mon_reprice_foreign_sender` error, `v2_mon_repriced`
    ///      warn; T-OP-090), so the key can be revoked (OPS_ADMIN, delay 0) before the ask is at the floor. 2_500 (a
    ///      quarter per call) is the coordinator's number; the owner may retune it. NOT a cooldown: a key can wait.
    uint16 public constant MAX_REPRICE_DROP_BPS = 2_500;

    /// @notice Shortest time from a roll to the expiry it writes, seconds. A daily roll keeps at least 1.5 h of
    ///         trading before the mint cutoff (expiry - SETTLEMENT_WINDOW); a weekly roll on the weekly's own day
    ///         writes next week's.
    uint40 public constant DAILY_MIN_LEAD = 2 hours;
    uint40 public constant WEEKLY_MIN_LEAD = 24 hours;

    /// @notice How long after a regular session opens {roll} still wants a spot observed in session that same day
    ///         (INTERFACE_VERSION 7).
    /// @dev A feed that has not printed since yesterday's close would otherwise let the first roll of the day write a
    ///      strike and an ask around a price the open has already gapped away from. 30 minutes costs a quiet open a
    ///      roll at 10:00 instead of 09:30, which still leaves a daily roll 6 h of lead (>= DAILY_MIN_LEAD) and 3 h on
    ///      a 13:00 early close.
    uint40 public constant ROLL_OPEN_GRACE = 30 minutes;

    /// @notice {minRollUnits} at deploy, and the lowest value {setMinRollUnits} accepts: one whole share, 0.01-share
    ///         units.
    /// @dev The ROLL bounty is sized near gas cost; paying it for dust rolls would make one-unit strategies worth
    ///      farming. A floor, not only a default: every successful roll places at least one unit, so a threshold of
    ///      0 or 1 would pay every roll and erase the guard. Stopping ROLL or CANCEL_STALE payments is done at the
    ///      payer instead: KeeperRewards.setBounty(action, 0), setCaller(roller, false), or {setKeeperRewards}(0).
    uint64 public constant DEFAULT_MIN_ROLL_UNITS = 100;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @dev The current period of a (writer, underlying). Two slots: an order id is a counter of placed orders, which
    ///      cannot reach 2^64 on any chain, so it packs with the expiry.
    struct Position {
        uint256 longId; // 0 = no position
        uint64 orderId; // 0 = no live ask tracked (stopped, or never placed)
        uint40 expiry; // unix seconds
    }

    /// @dev What a roll would write now.
    struct Plan {
        uint128 strike; // USDG 6 dp per share
        uint40 expiry; // unix seconds
        uint128 price; // USDG 6 dp per share
        uint64 units; // 0.01-share units
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The OrderBook the asks rest on.
    IOrderBook public immutable orderBook;
    /// @notice The OrderBook's Clearinghouse: series, collateral, settlement, the calendar and each market's oracle.
    IClearinghouse public immutable clearinghouse;
    /// @notice USDG (6 dp), the bounty token forwarded to keepers.
    address public immutable usdg;

    /// @notice ROLL bounty payer; address(0) pays nothing.
    IKeeperRewards public keeperRewards;
    /// @notice A roll pays the ROLL bounty only when it places at least this many 0.01-share units. Packed with
    ///         {keeperRewards}: the bounty path reads both.
    uint64 public minRollUnits;

    mapping(address writer => mapping(address underlying => V2Types.Strategy)) private _strategies;
    mapping(address writer => mapping(address underlying => Position)) private _positions;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice CONFIG_ADMIN set the ROLL bounty payer (address(0) disables the bounty).
    event KeeperRewardsSet(address indexed keeperRewards);
    /// @notice LISTING set the ROLL bounty threshold, 0.01-share units.
    event MinRollUnitsSet(uint256 units);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param orderBook_ The OrderBook; its `clearinghouse()` becomes {clearinghouse}, so the two can never disagree.
    /// @param authority_ The `AccessManager` that gates the three privileged selectors (`NoSource` when it has no
    ///        code). INTERFACE_VERSION 8: no role is granted here and none is held here.
    constructor(IOrderBook orderBook_, address authority_) Managed(authority_) {
        IClearinghouse ch = IClearinghouse(orderBook_.clearinghouse());
        orderBook = orderBook_;
        clearinghouse = ch;
        usdg = ch.usdg();
        minRollUnits = DEFAULT_MIN_ROLL_UNITS;
        emit MinRollUnitsSet(DEFAULT_MIN_ROLL_UNITS);
    }

    /*//////////////////////////////////////////////////////////////
                                STRATEGY
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAutoRoller
    /// @dev Setting a strategy activates it: `s.active` is ignored and stored as true ({stop} deactivates). Reverts
    ///      UnsupportedAsset for an underlying that is not a registered market, and CeilingExceeded when otmBps is
    ///      outside [MIN_OTM_BPS, MAX_OTM_BPS], askBps outside [MIN_ASK_BPS, MAX_ASK_BPS], or, with smartPricing,
    ///      unless MIN_ASK_BPS <= minAskBps <= askBps <= maxAskBps <= MAX_ASK_BPS (the band a pricer moves in must
    ///      contain the price the roll starts at). Without smartPricing the band is never read and not checked. The
    ///      live position and its ask are kept; the new terms apply from the next roll (and the band from the next
    ///      reprice).
    function setStrategy(address underlying, V2Types.Strategy calldata s) external nonReentrant {
        if (clearinghouse.market(underlying).strikeTick == 0) revert V2Errors.UnsupportedAsset();
        if (s.otmBps < MIN_OTM_BPS || s.otmBps > MAX_OTM_BPS || s.askBps < MIN_ASK_BPS || s.askBps > MAX_ASK_BPS) {
            revert V2Errors.CeilingExceeded();
        }
        if (
            s.smartPricing
                && (s.minAskBps < MIN_ASK_BPS
                    || s.minAskBps > s.askBps
                    || s.maxAskBps < s.askBps
                    || s.maxAskBps > MAX_ASK_BPS)
        ) revert V2Errors.CeilingExceeded();
        V2Types.Strategy memory stored = s;
        stored.active = true;
        _strategies[msg.sender][underlying] = stored;
        emit StrategySet(msg.sender, underlying, stored);
    }

    /// @inheritdoc IAutoRoller
    /// @dev Deactivates and emits. The tracked ask is cancelled through the book; when the book refuses with
    ///      NotAuthorized (the writer already revoked the roller as delegate) the stop still succeeds, the ask stays as
    ///      it is and stays tracked, and the writer, who is its maker, can cancel it directly. Any other failure of the
    ///      cancel reverts the whole stop, above all a cancel that ran out of gas (it reverts with no data): swallowing
    ///      that would let a stop sent with too little gas, which is exactly what a minimum-gas estimator sends, report
    ///      success while the ask stays live (sweep contracts-c20). The position is kept so {roll} still clears it
    ///      after settlement.
    function stop(address underlying) external nonReentrant {
        _strategies[msg.sender][underlying].active = false;
        Position storage pos = _positions[msg.sender][underlying];
        uint256 orderId = pos.orderId;
        emit StrategyStopped(msg.sender, underlying);
        if (orderId == 0) return;
        try orderBook.cancel(_single(orderId)) {
            pos.orderId = 0;
        } catch (bytes memory reason) {
            if (bytes4(reason) != V2Errors.NotAuthorized.selector) {
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  ROLL
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAutoRoller
    /// @dev One of two steps per call; see the contract NatSpec for what returns false and what reverts.
    ///      (1) CLOSE OUT. With a position and `now >= expiry`: when the writer still holds shorts of that series, settle
    ///      it (under try/catch; any failure reads as not settled) and return false unless it is settled, then redeem
    ///      the shorts. A writer holding none (nothing filled, or already redeemed by the cranker) has nothing locked
    ///      in the series, so its settlement is not waited for: an unfilled week is never held up by a slow settlement.
    ///      The ask is pruned (dead since the mint cutoff; pruning needs no delegate) and the position cleared.
    ///      Bounties the settle and redeem paid to this contract are forwarded to the caller. A call that closes out
    ///      returns true there and never goes on to step 2, even inside the session: a placement revert (a pause, a
    ///      revoked approval, a series the Clearinghouse refuses) would otherwise undo the close-out with it, and a
    ///      keeper that simulates first would skip the writer, leaving its collateral in settled shorts for as long
    ///      as the pause or missing approval lasts (sweep contracts-c18). The next call rolls.
    ///      (2) ROLL. With an active strategy and no position: inside the regular session, past the open grace or on a
    ///      reading observed in session that day, with a fresh spot, an expiry `nextExpiry(now + minLead, weekly)`, and
    ///      at least one unit of free collateral NET OF RENT, create the series and place
    ///      `placeFor(writer, longId, AskWrite, price, units, 0)` (valid until the mint cutoff). The plan reads the
    ///      market's current oracle; when the planned series already exists on a different oracle (created before a
    ///      `setMarketOracle`), that pinned oracle must also have a fresh spot short of the strike, or the roll waits
    ///      (T-310), so the ask is out of the money on the price it settles on. Emits {Rolled}; pays
    ///      the ROLL bounty when units >= minRollUnits. Size is `free / (UNIT + rent per unit)` (INTERFACE_VERSION 7),
    ///      so a writer who deposits exactly N shares writes `N x 100 - 1` units unless the deposit carries rent
    ///      headroom, and the whole ask can always fill.
    /// @return advanced True when step 1 cleared a position or step 2 placed an ask.
    function roll(address writer, address underlying) external nonReentrant returns (bool advanced) {
        Position memory pos = _positions[writer][underlying];
        if (pos.longId != 0) {
            // This period is rolled: one position per period.
            if (block.timestamp < pos.expiry) return false;
            return _closeOut(writer, underlying, pos);
        }

        V2Types.Strategy memory s = _strategies[writer][underlying];
        if (!s.active) return false;
        V2Types.MarketConfig memory m = clearinghouse.market(underlying);
        (bool due, Plan memory p) = _plan(writer, underlying, s, m);
        if (!due) return false;

        // Checked only once a roll would place, so a keeper probing outside the session never sees these reverts.
        if (!m.enabled) revert V2Errors.MarketDisabled();
        if (m.mintPaused) revert V2Errors.MintPaused();
        if (!clearinghouse.isOperator(writer, address(this)) || !clearinghouse.isOperator(writer, address(orderBook))) {
            revert V2Errors.NotAuthorized();
        }

        // The ids come back from the calls, so the position is written after them; the guard holds meanwhile and
        // neither call can reach this contract.
        uint256 longId = clearinghouse.createSeries(underlying, false, p.strike, p.expiry);
        uint256 orderId = orderBook.placeFor(writer, longId, V2Types.OrderKind.AskWrite, p.price, p.units, 0);
        _positions[writer][underlying] =
            Position({longId: longId, orderId: SafeCast.toUint64(orderId), expiry: p.expiry});
        emit Rolled(writer, underlying, longId, orderId, p.strike, p.expiry, p.price, p.units);

        if (p.units >= minRollUnits) _reward(msg.sender, V2Constants.ACTION_ROLL);
        return true;
    }

    /// @inheritdoc IAutoRoller
    /// @dev INTERFACE_VERSION 7 (v7 design §4.5.1, sweep contracts-c16). The ask a roll places keeps its roll-time
    ///      price until the mint cutoff; nothing re-prices it against spot, {roll} does nothing inside the period, and
    ///      {reprice} cannot lift it above the writer's own maxAskBps of spot. After a rally past the strike the ask is
    ///      therefore worth less than intrinsic value and a taker collects the difference from the writer. This
    ///      withdraws it, permissionlessly, so the cranker (or the pricer, or anyone) can end that exposure.
    ///
    ///      GATE, in this order, each of them a plain `return false` so a keeper loop can call it blindly: a tracked
    ///      ask (`orderId != 0`), the position's own expiry still ahead, the order live (not cancelled, not fully
    ///      filled, not past its validUntil), a fresh spot FROM THE SERIES' PINNED ORACLE ({_pinned}, then {_trySpot}
    ///      ok: source 0 answered, the observation is within that oracle's spotMaxAge for the underlying, the issuer's
    ///      oracle is not paused and the price is non-zero) and that spot at or past the strike ({_overtaken}, no
    ///      margin).
    ///
    ///      THE PINNED ORACLE, NOT THE MARKET'S (T-310): the series settles on the oracle `createSeries` pinned into
    ///      it, so that is the price that decides whether the ask is in the money. After a `setMarketOracle` the
    ///      market's current oracle is one this series never settles on, and it is not read here at all.
    ///
    ///      FRESHNESS IS {_trySpot} AND NOTHING MORE, deliberately. Source 0's `updatedAt` never goes backwards, so
    ///      any reading that triggers was observed after the roll placed the ask; a session-only bound would refuse to
    ///      cancel overnight and at weekends, when the book still trades. A reading older than the pinned oracle's
    ///      spotMaxAge is not ok and does not count.
    ///
    ///      NO MARGIN, and placement can never trigger it: a roll places at `strike >= ceil(spot x (1 + otmBps))` with
    ///      otmBps at least {MIN_OTM_BPS}, and when the series it lands on is pinned to another oracle it places only
    ///      while that oracle's spot is short of the strike too, so a freshly placed ask is always strictly out of the
    ///      money on the oracle read here.
    ///
    ///      EFFECTS BEFORE THE INTERACTION: `orderId` is cleared before the book is called. The cancel is a DIRECT
    ///      call, not a try/catch: a writer who revoked the roller as delegate makes this revert NotAuthorized (the
    ///      writer, who is the maker, can cancel it directly) and a cancel that ran out of gas reverts the whole call
    ///      rather than reporting a withdrawal that did not happen (sweep contracts-c20).
    ///
    ///      AFTER A CANCEL the position keeps `longId` and `expiry` with `orderId` 0: no re-roll inside the period
    ///      (owner decision, v7 design §12.4), so there is still one position, one {Rolled} and one ROLL bounty per
    ///      period; {stop} returns early, {reprice} reverts `OrderNotLive(0)`, and the close-out after expiry still
    ///      settles and redeems a partial fill and skips the prune.
    ///
    ///      PAUSES: this runs under the trading, mint and create pauses and on a disabled market, because
    ///      OrderBook.cancel is never pausable and withdrawing an ask only ever reduces risk. It returns false while
    ///      the series' pinned oracle is paused or reverting. It moves no collateral and no USDG but the bounty.
    function cancelStale(address writer, address underlying) external nonReentrant returns (bool) {
        Position storage pos = _positions[writer][underlying];
        uint256 orderId = pos.orderId;
        if (orderId == 0 || block.timestamp >= pos.expiry) return false;

        V2Types.Order memory o = orderBook.getOrders(_single(orderId))[0];
        uint64 remaining = o.units - o.filled;
        if (o.cancelled || remaining == 0 || block.timestamp >= o.validUntil) return false;

        uint256 longId = pos.longId;
        (V2Types.Series memory s, address pinnedOracle) = _pinned(longId);
        (bool ok, uint256 spotPrice, uint256 updatedAt) = _trySpot(pinnedOracle, underlying);
        if (!ok || !_overtaken(s.isPut, s.strike, spotPrice)) return false;

        pos.orderId = 0;
        orderBook.cancel(_single(orderId));
        emit StaleAskCancelled(writer, underlying, longId, orderId, spotPrice, updatedAt);

        // Same gate as the ROLL bounty: dust withdrawals are not worth farming.
        if (remaining >= minRollUnits) _reward(msg.sender, V2Constants.ACTION_CANCEL_STALE);
        return true;
    }

    /// @inheritdoc IAutoRoller
    /// @dev Checks in order: PRICER through the manager, strategy active with smartPricing (both NotAuthorized), a
    ///      tracked ask (OrderNotLive(0)), spot from the series' pinned oracle ({_pinned}; `spot`: NoSource /
    ///      StaleSpot), the band `minAskBps x spot <= newPrice x BPS <= maxAskBps x spot` (BadPrice, inclusive,
    ///      exact), then SEC-13's per-call drop cap against the live ask's own price:
    ///      `newPrice x BPS >= o.price x (BPS - MAX_REPRICE_DROP_BPS)` (RepriceDropExceeded, inclusive; a raise is
    ///      never bounded). The book then replaces the ask with the same remaining units and validUntil (OrderNotLive
    ///      when it is filled, cancelled or past its cutoff; BadPrice off the PRICE_TICK grid; TradingPaused;
    ///      NotAuthorized once the writer revoked the delegate).
    ///      THE CAP READS THE ORDER, NOT THE STRATEGY. The band is the writer's; the cap is relative to whatever the
    ///      ask is NOW, so reaching a band floor from the initial ask takes `ceil(log(floor/ask) / log(0.75))` calls
    ///      -- for the default 150 -> 50 bps that is four -- each of them an event.
    ///      INTERFACE_VERSION 7: InTheMoney sits between the spot read and the band (v7 design §4.5.2). The band is
    ///      `newPrice <= maxAskBps` of spot, at most 10 %, so once the spot has reached the strike every price the band
    ///      allows is below intrinsic value; repricing there would only make the loss cheaper to take. The ask is
    ///      withdrawn instead, with {cancelStale}, which anyone may call.
    ///      THE PINNED ORACLE, NOT THE MARKET'S (T-310), for both the InTheMoney test and the band: they judge an ask on
    ///      an existing series, which settles on the oracle `createSeries` pinned into it. It is the same spot
    ///      {cancelStale} reads, so the two can never disagree about whether an ask is in the money.
    function reprice(address writer, address underlying, uint128 newPrice) external nonReentrant restricted {
        V2Types.Strategy memory s = _strategies[writer][underlying];
        if (!s.active || !s.smartPricing) revert V2Errors.NotAuthorized();
        Position storage pos = _positions[writer][underlying];
        uint256 oldOrderId = pos.orderId;
        if (oldOrderId == 0) revert V2Errors.OrderNotLive(0);

        (V2Types.Series memory series, address pinnedOracle) = _pinned(pos.longId);
        (uint256 spotPrice,) = ISettlementOracle(pinnedOracle).spot(underlying);
        if (_overtaken(series.isPut, series.strike, spotPrice)) revert V2Errors.InTheMoney();
        uint256 scaled = uint256(newPrice) * V2Constants.BPS;
        if (scaled < spotPrice * s.minAskBps || scaled > spotPrice * s.maxAskBps) revert V2Errors.BadPrice();

        V2Types.Order memory o = orderBook.getOrders(_single(oldOrderId))[0];
        if (uint256(newPrice) * V2Constants.BPS < uint256(o.price) * (V2Constants.BPS - MAX_REPRICE_DROP_BPS)) {
            revert RepriceDropExceeded(
                o.price,
                newPrice,
                OptionMath.roundUpToTick(
                    Math.ceilDiv(uint256(o.price) * (V2Constants.BPS - MAX_REPRICE_DROP_BPS), V2Constants.BPS),
                    V2Constants.PRICE_TICK
                )
            );
        }
        uint256 newOrderId = orderBook.replace(oldOrderId, newPrice, o.units - o.filled);
        pos.orderId = SafeCast.toUint64(newOrderId);
        emit Repriced(writer, underlying, oldOrderId, newOrderId, newPrice);
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the ROLL bounty payer. CONFIG_ADMIN (24 h). This contract must be registered there as a caller.
    /// @param rewards KeeperRewards contract (NoSource when non-zero without code), or address(0) to pay nothing.
    function setKeeperRewards(address rewards) external nonReentrant restricted {
        if (rewards != address(0) && rewards.code.length == 0) revert V2Errors.NoSource();
        keeperRewards = IKeeperRewards(rewards);
        emit KeeperRewardsSet(rewards);
    }

    /// @notice Sets the ROLL bounty threshold. LISTING (1 h).
    /// @param units 0.01-share units a roll must place to pay the bounty (BadUnits below DEFAULT_MIN_ROLL_UNITS).
    function setMinRollUnits(uint64 units) external nonReentrant restricted {
        if (units < DEFAULT_MIN_ROLL_UNITS) revert V2Errors.BadUnits();
        minRollUnits = units;
        emit MinRollUnitsSet(units);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAutoRoller
    function strategy(address writer, address underlying) external view returns (V2Types.Strategy memory) {
        return _strategies[writer][underlying];
    }

    /// @inheritdoc IAutoRoller
    /// @dev `orderId` is the ask the roller placed or last repriced to, 0 after {stop} cancelled it. It is not
    ///      re-checked here: an ask the writer cancelled or a buyer filled still shows (read it with getOrders).
    function position(address writer, address underlying)
        external
        view
        returns (uint256 longId, uint256 orderId, uint40 expiry)
    {
        Position memory pos = _positions[writer][underlying];
        return (pos.longId, pos.orderId, pos.expiry);
    }

    /// @notice ERC-165: IAutoRoller and IERC165 only.
    /// @dev INTERFACE_VERSION 8: {Managed} declares no `supportsInterface`, so the roller no longer reports
    ///      `type(IAccessControl).interfaceId`. That is deliberate -- roles are not on this target any more, and a
    ///      consumer that feature-detected AccessControl to find the admin must read the manager instead.
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == type(IAutoRoller).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Step 1 of {roll} for an expired position. False (and nothing changed here) while the writer holds shorts of
    ///      a series that is not settled. Settle is called first because its result decides everything else; after it
    ///      the position is cleared before the redeem and prune calls (checks-effects-interactions).
    function _closeOut(address writer, address underlying, Position memory pos) private returns (bool) {
        uint256 shortId = V2Ids.shortIdOf(pos.longId);
        bool holdsShorts = clearinghouse.balanceOf(writer, shortId) != 0;
        if (holdsShorts) {
            try clearinghouse.settle(pos.longId) {} catch {}
            if (!clearinghouse.series(pos.longId).settled) return false;
        }
        delete _positions[writer][underlying];
        // Direct call: it reverts only for a writer who opted out of third-party redemption and revoked the roller,
        // which the writer fixes, and swallowing it would clear a position whose collateral never came back.
        if (holdsShorts) clearinghouse.redeem(shortId, writer);
        // Never reverts; skips an ask that is already filled or cancelled.
        if (pos.orderId != 0) orderBook.prune(_single(pos.orderId));
        _forwardUsdg();
        return true;
    }

    /// @dev What a roll would write now, or due = false for every "not now" condition (see {roll}). Reads only the
    ///      strategy, the market, the calendar, the market's oracle, the series and its pinned oracle (when it already
    ///      exists) and the writer's free collateral, and stays a view: a roll never creates a series and then finds
    ///      nothing to write.
    function _plan(address writer, address underlying, V2Types.Strategy memory s, V2Types.MarketConfig memory m)
        private
        view
        returns (bool due, Plan memory p)
    {
        IExpiryCalendar cal = IExpiryCalendar(clearinghouse.calendar());
        // casting to 'uint40' is safe: a unix time below 2^40 until the year 36812
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 nowTs = uint40(block.timestamp);
        if (m.strikeTick == 0 || !cal.isRegularSession(nowTs)) return (false, p);

        (bool ok, uint256 spotPrice, uint256 updatedAt) = _trySpot(m.oracle, underlying);
        if (!ok) return (false, p);

        // OPEN GRACE (INTERFACE_VERSION 7, v7 design §4.5.3). A feed that has not printed since yesterday's close is
        // still fresh under a spotMaxAge of a day or more, so without this the first roll of the day would write a
        // strike and an ask around a price the open has already gapped away from. Inside the first ROLL_OPEN_GRACE of
        // a session the roll therefore waits unless the reading it holds was itself observed in a regular session on
        // the same date. Inside a regular session the New York date equals the UTC date, so the day compare is exact.
        // casting to 'uint40' is safe: `updatedAt <= block.timestamp` for an ok reading, and nowTs is a uint40
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 observedAt = uint40(updatedAt);
        if (
            !cal.isRegularSession(nowTs - ROLL_OPEN_GRACE)
                && !(updatedAt / 1 days == uint256(nowTs) / 1 days && cal.isRegularSession(observedAt))
        ) return (false, p);

        uint40 lead = s.weekly ? WEEKLY_MIN_LEAD : DAILY_MIN_LEAD;
        try cal.nextExpiry(nowTs + lead, s.weekly) returns (uint40 expiry) {
            p.expiry = expiry;
        } catch {
            return (false, p);
        }

        uint256 strike = OptionMath.roundUpToTick(
            Math.ceilDiv(spotPrice * (V2Constants.BPS + s.otmBps), V2Constants.BPS), m.strikeTick
        );
        uint256 price =
            OptionMath.roundUpToTick(Math.ceilDiv(spotPrice * s.askBps, V2Constants.BPS), V2Constants.PRICE_TICK);
        if (strike > type(uint128).max || price > type(uint128).max) return (false, p);

        // SIZE IS FREE COLLATERAL NET OF RENT (INTERFACE_VERSION 7, v7 design §4.5.4). Clearinghouse.mint charges the
        // writer rent on the collateral it locks, out of the same free balance, so an ask sized at `free / UNIT` could
        // not fill its last unit. The rate is the series' pinned one when the series already exists (anyone may have
        // created it earlier, at a different market rate) and the market's current one otherwise. Every later fill
        // pays at most this much per unit - less time is left, and ceil(u * x) <= u * ceil(x) - so the whole ask can
        // always fill.
        // casting to 'uint128' is safe: bounded by type(uint128).max just above
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 longId = V2Ids.longIdOf(underlying, false, uint128(strike), p.expiry);
        bool exists = clearinghouse.seriesExists(longId);

        // A SERIES SOMEONE CREATED EARLIER MAY SETTLE ON ANOTHER ORACLE (T-310). `createSeries` returns an existing id
        // as it is, pinned to whatever oracle the market had when it was created; a `setMarketOracle` since then means
        // the strike above was planned on a price this series never settles on. The ask must be out of the money on
        // the price it DOES settle on, so the pinned oracle must also have a fresh spot short of the strike, or the
        // roll waits. Without this the roll could rest an ask that is already in the money for its own settlement,
        // and {cancelStale}, which reads the pinned oracle, could withdraw what the roll had just placed.
        if (exists) {
            (, address pinnedOracle) = _pinned(longId);
            if (pinnedOracle != m.oracle) {
                (bool pinnedOk, uint256 pinnedSpot,) = _trySpot(pinnedOracle, underlying);
                if (!pinnedOk || _overtaken(false, strike, pinnedSpot)) return (false, p);
            }
        }

        uint256 feePerUnit = exists
            ? clearinghouse.mintFee(longId, 1)
            : OptionMath.mintFee(V2Constants.UNIT, m.mintFeePpm, p.expiry - nowTs);
        uint256 units = clearinghouse.free(writer, underlying) / (V2Constants.UNIT + feePerUnit);
        if (s.maxUnits != 0 && units > s.maxUnits) units = s.maxUnits;
        if (units > type(uint64).max) units = type(uint64).max;
        if (units == 0) return (false, p);

        // casting is safe: each value was bounded by its type's maximum above
        // forge-lint: disable-next-line(unsafe-typecast)
        (p.strike, p.price, p.units) = (uint128(strike), uint128(price), uint64(units));
        return (true, p);
    }

    /// @dev THE ONE PLACE THE ORACLE OF A SERIES THAT EXISTS IS RESOLVED (T-310): the series, and the oracle
    ///      `createSeries` pinned into it, which is the oracle {Clearinghouse.settle} settles it on. {cancelStale},
    ///      {reprice} and {_plan} (for a series created earlier) all resolve it here, so "which price judges this ask"
    ///      has one answer and a later change cannot fix one call site and leave another behind.
    ///      NEVER `clearinghouse.market(underlying).oracle` for a series that exists: `setMarketOracle` moves the
    ///      market's pointer and leaves every series created before it on the old oracle (Clearinghouse
    ///      `_requireSettlementOracle` NatSpec), so the market's current oracle may be one this series never settles on.
    function _pinned(uint256 longId) private view returns (V2Types.Series memory s, address oracle) {
        s = clearinghouse.series(longId);
        oracle = s.oracle;
    }

    /// @dev A non-reverting {ISettlementOracle.trySpot}: ok only when the oracle answered, said ok (source 0 is ok,
    ///      the observation is within the market's spotMaxAge and the issuer's oracle is not paused) and the price is
    ///      non-zero. An oracle without code, one that reverts and one that answers garbage all read as "no spot now",
    ///      which is a `return false` everywhere this is used, never a revert (INTERFACE_VERSION 7).
    function _trySpot(address oracle, address underlying)
        private
        view
        returns (bool ok, uint256 price, uint256 updatedAt)
    {
        try ISettlementOracle(oracle).trySpot(underlying) returns (bool k, uint256 p, uint256 t) {
            if (k && p != 0) return (true, p, t);
        } catch {}
    }

    /// @dev Has `spotPrice` reached `strike`? Calls are overtaken at or above it, puts at or below it: with no margin,
    ///      because a roll places at least MIN_OTM_BPS away, so placement can never be overtaken by its own reading
    ///      (INTERFACE_VERSION 7). v2.0 writes calls only; the put branch is what {cancelStale} and {reprice} would do
    ///      for a put series the roller was later taught to write.
    function _overtaken(bool isPut, uint256 strike, uint256 spotPrice) internal pure returns (bool) {
        return isPut ? spotPrice <= strike : spotPrice >= strike;
    }

    /// @dev Asks KeeperRewards to pay `keeper` the bounty of `action` (ACTION_ROLL, or ACTION_CANCEL_STALE from
    ///      INTERFACE_VERSION 7). A raw call with no return data copied: a payer that reverts, has no code or answers
    ///      garbage cannot revert the call that earned it.
    function _reward(address keeper, bytes32 action) private {
        address rewards = address(keeperRewards);
        if (rewards == address(0)) return;
        bytes memory data = abi.encodeCall(IKeeperRewards.reward, (keeper, action));
        assembly ("memory-safe") {
            pop(call(gas(), rewards, 0, add(data, 0x20), mload(data), 0, 0))
        }
    }

    /// @dev Sends this contract's whole USDG balance to the caller of {roll}: the SETTLE and REDEEM bounties the
    ///      Clearinghouse just paid here (see BOUNTIES PASS THROUGH), plus anything sent here by mistake. Best effort,
    ///      like KeeperRewards._tryTransfer: a frozen keeper leaves the balance for the next close-out's caller.
    function _forwardUsdg() private {
        (bool ok, bytes memory ret) = usdg.staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        if (!ok || ret.length < 32) return;
        uint256 balance = abi.decode(ret, (uint256));
        if (balance == 0) return;
        (ok,) = usdg.call(abi.encodeCall(IERC20.transfer, (msg.sender, balance)));
    }

    /// @dev A one-element id array for the book's batch entry points.
    function _single(uint256 id) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }
}
