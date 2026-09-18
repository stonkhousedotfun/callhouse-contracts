// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AutoRoller} from "../../../src/v2/AutoRoller.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {ExpiryCalendar} from "../../../src/v2/ExpiryCalendar.sol";
import {OrderBook} from "../../../src/v2/OrderBook.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../../src/mocks/MockStockToken.sol";
import {MockRoundFeed} from "../../../src/v2/mocks/MockRoundFeed.sol";
import {MockOraclePriceSource} from "../../../src/v2/mocks/MockOraclePriceSource.sol";
import {SettlementOracle} from "../../../src/v2/oracle/SettlementOracle.sol";

/// @notice Drives the real AutoRoller, OrderBook, Clearinghouse and SettlementOracle through random sequences for
///         {AutoRollerStaleInvariantTest}: rolls, prints that move the spot by up to 8 % a step, takes, stops,
///         strategy changes, reprices, {AutoRoller.cancelStale} by an arbitrary caller, a cranker that sweeps every
///         writer, delegate revocations, the issuer's oracle pause, every protocol pause, and time that jumps through
///         nights and weekends to expiry, settlement and the next period.
/// @dev THE CANCEL IS MEASURED, NOT TRUSTED. {cancelStale} snapshots every actor's wallet, ledger balance and option
///      tokens around the call and records a violation ({movedValue}) if anything moved other than the caller's own
///      USDG rising by at most the CANCEL_STALE bounty. It also records whether the call reverted and whether the
///      writer's delegate was revoked at that moment, so the suite can pin "it reverts only for a revoked delegate".
///
///      GHOSTS. {staleCancels} counts {AutoRoller.StaleAskCancelled} per (writer, longId) — the suite pins at most
///      one, because a cancelled position is never re-rolled inside its period. {badRoll} counts rolls that placed an
///      ask already at or past its own strike at the reading they used, or that were made inside
///      {AutoRoller.ROLL_OPEN_GRACE} on a reading not observed in session that day. {delegateOff} is the model of who
///      has revoked the roller.
///
///      The handler never reverts (the suite runs with fail-on-revert): every protocol call is a try/catch and every
///      disagreement becomes a counter the suite asserts on.
///
///      TIME is carried in {clock} and never read back from block.timestamp (via_ir folds repeated TIMESTAMP reads).
///      The feed prints a heartbeat whenever the clock moves more than 12 hours, so a reading is never stale merely
///      because nobody printed; the market's spotMaxAge is the launch registry's 25 h, so an overnight print stays
///      actionable and {cancelStale} is exercised outside sessions too.
contract AutoRollerStaleHandler is Test {
    struct Deps {
        AutoRoller roller;
        OrderBook book;
        Clearinghouse ch;
        SettlementOracle oracle;
        ExpiryCalendar calendar;
        MockRoundFeed feed;
        MockOraclePriceSource second;
        MockERC20 usdg;
        MockStockToken nvda;
        address admin;
        address guardian;
        address pricer;
        address[3] writers;
        address[2] buyers;
        uint256 start;
    }

    uint256 internal constant CANCEL_STALE_BOUNTY = 20_000;
    uint40 internal constant NO_DEADLINE = type(uint40).max;

    AutoRoller internal roller;
    OrderBook internal book;
    Clearinghouse internal ch;
    SettlementOracle internal oracle;
    ExpiryCalendar internal calendar;
    MockRoundFeed internal feed;
    MockOraclePriceSource internal second;
    MockERC20 internal usdg;
    MockStockToken internal nvda;
    address internal admin;
    address internal guardian;
    address internal pricer;
    address[3] internal writers;
    address[2] internal buyers;

    /// @notice Simulated unix time; every action warps to it first.
    uint256 public clock;
    /// @notice Last feed answer, 8 dp.
    int256 public answer;
    /// @notice Last time the feed printed.
    uint256 public lastPrint;

    /// @notice cancelStale calls that moved value other than the caller's bounty.
    uint256 public movedValue;
    /// @notice cancelStale calls that reverted although the roller was still the writer's delegate.
    uint256 public revertedWithDelegate;
    /// @notice Rolls that placed an ask already overtaken at their own reading, or inside the grace on a pre-session
    ///         reading.
    uint256 public badRoll;
    /// @notice Rolls that placed, cancels that withdrew, and cranker sweeps: campaign coverage.
    uint256 public rolls;
    uint256 public cancels;
    /// @notice StaleAskCancelled events seen per (writer, longId), and the largest such count.
    mapping(address writer => mapping(uint256 longId => uint256)) public staleCancels;
    uint256 public maxStaleCancels;
    /// @notice Cranker sweeps that left a tracked live ask overtaken at an ok spot with the delegate still in place.
    uint256 public crankLeftOvertaken;
    /// @notice Model of who revoked the roller as OrderBook delegate.
    mapping(address writer => bool) public delegateOff;
    /// @notice Names the last violation, for the failure message.
    string public lastSurprise;

    constructor(Deps memory d) {
        roller = d.roller;
        book = d.book;
        ch = d.ch;
        oracle = d.oracle;
        calendar = d.calendar;
        feed = d.feed;
        second = d.second;
        usdg = d.usdg;
        nvda = d.nvda;
        admin = d.admin;
        guardian = d.guardian;
        pricer = d.pricer;
        writers = d.writers;
        buyers = d.buyers;
        clock = d.start;
        lastPrint = d.start;
        answer = 220_00000000;
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _writer(uint256 seed) internal view returns (address) {
        return writers[seed % writers.length];
    }

    function _tick(uint256 seconds_) internal {
        clock += seconds_;
        vm.warp(clock);
        // A heartbeat at least every 12 h, so freshness is a property of the market's spotMaxAge and not of the fuzz.
        if (clock - lastPrint >= 12 hours) _print(answer);
    }

    function _print(int256 a) internal {
        feed.push(a, clock);
        (answer, lastPrint) = (a, clock);
    }

    function _single(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _order(uint256 orderId) internal view returns (V2Types.Order memory) {
        return book.getOrders(_single(orderId))[0];
    }

    /// @dev Actors whose value the handler watches around a cancel.
    function _actors() internal view returns (address[6] memory a) {
        a = [writers[0], writers[1], writers[2], buyers[0], buyers[1], address(roller)];
    }

    /*//////////////////////////////////////////////////////////////
                               THE CANCEL
    //////////////////////////////////////////////////////////////*/

    /// @notice cancelStale by an arbitrary caller, with every actor's value measured across the call.
    function cancelStale(uint256 seed, uint256 callerSeed, uint256 dt) external {
        _tick(dt % 90 minutes);
        address writer = _writer(seed);
        address caller = address(uint160(uint256(keccak256(abi.encode("caller", callerSeed)))));
        if (caller == address(0) || caller == address(roller) || caller.code.length != 0) caller = buyers[0];

        (uint256 longId,,) = roller.position(writer, address(nvda));
        address[6] memory a = _actors();
        uint256[6] memory usdgBefore;
        uint256[6] memory nvdaBefore;
        uint256[6] memory freeBefore;
        uint256[6] memory longBefore;
        uint256[6] memory shortBefore;
        for (uint256 i; i < a.length; ++i) {
            usdgBefore[i] = usdg.balanceOf(a[i]);
            nvdaBefore[i] = nvda.balanceOf(a[i]);
            freeBefore[i] = ch.free(a[i], address(nvda));
            if (longId != 0) {
                longBefore[i] = ch.balanceOf(a[i], longId);
                shortBefore[i] = ch.balanceOf(a[i], longId | 1);
            }
        }
        uint256 callerUsdgBefore = usdg.balanceOf(caller);
        uint256 lockedBefore = longId == 0 ? 0 : ch.locked(longId);

        vm.recordLogs();
        vm.prank(caller);
        try roller.cancelStale(writer, address(nvda)) returns (bool cancelled) {
            if (cancelled) _recordCancel(writer, longId);
        } catch {
            if (!delegateOff[writer]) {
                ++revertedWithDelegate;
                lastSurprise = "cancelStale reverted with the delegate in place";
            }
            return;
        }

        if (longId != 0 && ch.locked(longId) != lockedBefore) {
            ++movedValue;
            lastSurprise = "cancelStale moved locked collateral";
        }
        for (uint256 i; i < a.length; ++i) {
            bool isCaller = a[i] == caller;
            uint256 usdgAfter = usdg.balanceOf(a[i]);
            if (isCaller
                    ? usdgAfter > usdgBefore[i] + CANCEL_STALE_BOUNTY || usdgAfter < usdgBefore[i]
                    : usdgAfter != usdgBefore[i]) {
                ++movedValue;
                lastSurprise = "cancelStale moved USDG";
            }
            if (nvda.balanceOf(a[i]) != nvdaBefore[i]) {
                ++movedValue;
                lastSurprise = "cancelStale moved a wallet";
            }
            if (ch.free(a[i], address(nvda)) != freeBefore[i]) {
                ++movedValue;
                lastSurprise = "cancelStale moved the ledger";
            }
            if (longId != 0) {
                if (ch.balanceOf(a[i], longId) != longBefore[i] || ch.balanceOf(a[i], longId | 1) != shortBefore[i]) {
                    ++movedValue;
                    lastSurprise = "cancelStale moved option tokens";
                }
            }
        }
        if (caller != writer && usdg.balanceOf(caller) < callerUsdgBefore) {
            ++movedValue;
            lastSurprise = "the caller paid for the cancel";
        }
    }

    /// @notice The cranker's sweep: cancelStale for every writer, as the keeper's `stale` step does each tick. After
    ///         it, no tracked live ask may still be overtaken at an ok spot unless its writer revoked the delegate.
    function crankStale(uint256 dt) external {
        _tick(dt % 30 minutes);
        for (uint256 i; i < writers.length; ++i) {
            (uint256 longId,,) = roller.position(writers[i], address(nvda));
            vm.prank(buyers[1]);
            try roller.cancelStale(writers[i], address(nvda)) returns (bool cancelled) {
                if (cancelled) _recordCancel(writers[i], longId);
            } catch {}
        }
        (bool ok, uint256 spot,) = oracle.trySpot(address(nvda));
        if (!ok) return;
        for (uint256 i; i < writers.length; ++i) {
            if (delegateOff[writers[i]]) continue;
            (uint256 longId, uint256 orderId, uint40 expiry) = roller.position(writers[i], address(nvda));
            if (orderId == 0 || clock >= expiry) continue;
            V2Types.Order memory o = _order(orderId);
            if (o.cancelled || o.units == o.filled || clock >= o.validUntil) continue;
            if (spot >= ch.series(longId).strike) {
                ++crankLeftOvertaken;
                lastSurprise = "a crank left an overtaken ask live";
            }
        }
    }

    function _recordCancel(address writer, uint256 longId) internal {
        ++cancels;
        uint256 n = ++staleCancels[writer][longId];
        if (n > maxStaleCancels) maxStaleCancels = n;
    }

    /*//////////////////////////////////////////////////////////////
                                 ROLL
    //////////////////////////////////////////////////////////////*/

    /// @notice A roll, checked against the two properties the placement must have.
    function roll(uint256 seed, uint256 dt) external {
        _tick(dt % 4 hours);
        address writer = _writer(seed);
        (uint256 longBefore,,) = roller.position(writer, address(nvda));
        try roller.roll(writer, address(nvda)) returns (bool) {}
        catch {
            return;
        }
        (uint256 longId, uint256 orderId,) = roller.position(writer, address(nvda));
        if (longId == 0 || longId == longBefore || orderId == 0) return;
        ++rolls;

        (bool ok, uint256 spot, uint256 updatedAt) = oracle.trySpot(address(nvda));
        if (!ok) return; // cannot have placed without a reading; nothing to check against
        uint128 strike = ch.series(longId).strike;
        if (spot >= strike) {
            ++badRoll;
            lastSurprise = "a roll placed an ask already at its strike";
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 nowTs = uint40(clock);
        if (!calendar.isRegularSession(nowTs - roller.ROLL_OPEN_GRACE())) {
            // forge-lint: disable-next-line(unsafe-typecast)
            bool inSession = updatedAt / 1 days == clock / 1 days && calendar.isRegularSession(uint40(updatedAt));
            if (!inSession) {
                ++badRoll;
                lastSurprise = "a roll inside the open grace used a pre-session reading";
            }
        }
    }

    /// @notice A close-out after expiry: finalize the expiry the position sits on, then let {roll} clear it.
    function closeOut(uint256 seed, uint256 dt) external {
        _tick(dt % 6 hours);
        address writer = _writer(seed);
        (,, uint40 expiry) = roller.position(writer, address(nvda));
        if (expiry == 0 || clock < expiry) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        second.setWindow(true, uint256(answer) / 100);
        try oracle.snapshot(address(nvda), expiry) returns (uint8) {} catch {}
        try oracle.finalize(address(nvda), expiry) returns (bool, uint256) {} catch {}
        try roller.roll(writer, address(nvda)) returns (bool) {} catch {}
    }

    /*//////////////////////////////////////////////////////////////
                              THE MARKET
    //////////////////////////////////////////////////////////////*/

    /// @notice A print up to 8 % either way, which is inside the source's round-jump guard.
    function print(uint256 move, bool up, uint256 dt) external {
        _tick(dt % 3 hours);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 step = int256(bound(move, 0, 800));
        int256 next = up ? answer + answer * step / 10_000 : answer - answer * step / 10_000;
        if (next < 1_00000000) next = 1_00000000;
        _print(next);
    }

    /// @notice A jump over a night, a weekend or a whole session.
    function warp(uint256 seed) external {
        uint256 pick = seed % 4;
        _tick(pick == 0 ? 45 minutes : pick == 1 ? 8 hours : pick == 2 ? 26 hours : 3 days);
    }

    /// @notice A buyer takes part of a writer's live ask.
    function take(uint256 seed, uint64 units, uint256 dt) external {
        _tick(dt % 2 hours);
        address writer = _writer(seed);
        (uint256 longId, uint256 orderId,) = roller.position(writer, address(nvda));
        if (longId == 0 || orderId == 0) return;
        V2Types.Order memory o = _order(orderId);
        if (o.cancelled || o.units == o.filled) return;
        uint64 want = uint64(bound(units, 1, o.units - o.filled));
        vm.prank(buyers[seed % buyers.length]);
        try book.take(
            V2Types.TakeParams({
                longId: longId,
                buying: true,
                orderIds: _single(orderId),
                units: want,
                minUnits: 0,
                limitPrice: type(uint128).max,
                writeToSell: false,
                recipient: buyers[seed % buyers.length],
                deadline: NO_DEADLINE
            })
        ) returns (
            uint64, uint256, uint256
        ) {}
            catch {}
    }

    /*//////////////////////////////////////////////////////////////
                           WRITER AND ADMIN
    //////////////////////////////////////////////////////////////*/

    function setStrategy(uint256 seed, uint256 otm, uint256 ask, bool weekly) external {
        _tick(30 minutes);
        address writer = _writer(seed);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 otmBps = uint16(bound(otm, 100, 2500));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 askBps = uint16(bound(ask, 5, 1000));
        V2Types.Strategy memory s = V2Types.Strategy({
            active: true,
            weekly: weekly,
            smartPricing: true,
            otmBps: otmBps,
            askBps: askBps,
            minAskBps: 5,
            maxAskBps: 1000,
            maxUnits: 0
        });
        vm.prank(writer);
        try roller.setStrategy(address(nvda), s) {} catch {}
    }

    function stop(uint256 seed) external {
        _tick(20 minutes);
        address writer = _writer(seed);
        vm.prank(writer);
        try roller.stop(address(nvda)) {} catch {}
    }

    function reprice(uint256 seed, uint256 price) external {
        _tick(15 minutes);
        address writer = _writer(seed);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 p = uint128(bound(price, 1, 100) * 100_000);
        vm.prank(pricer);
        try roller.reprice(writer, address(nvda), p) {} catch {}
    }

    function toggleDelegate(uint256 seed) external {
        _tick(10 minutes);
        address writer = _writer(seed);
        bool next = !delegateOff[writer];
        vm.prank(writer);
        book.setDelegate(address(roller), !next);
        delegateOff[writer] = next;
    }

    function toggleOraclePause() external {
        _tick(10 minutes);
        nvda.setOraclePaused(!nvda.oraclePaused());
    }

    function togglePauses(uint256 seed) external {
        _tick(10 minutes);
        uint256 pick = seed % 3;
        vm.startPrank(guardian);
        if (pick == 0) book.setTradingPaused(!book.tradingPaused());
        if (pick == 1) ch.setMintPaused(address(nvda), !ch.market(address(nvda)).mintPaused);
        if (pick == 2) ch.setCreatePaused(!ch.createPaused());
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              SUITE READS
    //////////////////////////////////////////////////////////////*/

    function writerAt(uint256 i) external view returns (address) {
        return writers[i];
    }

    function writerCount() external view returns (uint256) {
        return writers.length;
    }
}
