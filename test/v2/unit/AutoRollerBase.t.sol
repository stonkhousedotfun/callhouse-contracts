// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseV2Test} from "../BaseV2.t.sol";
import {AutoRoller} from "../../../src/v2/AutoRoller.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {ExpiryCalendar} from "../../../src/v2/ExpiryCalendar.sol";
import {KeeperRewards} from "../../../src/v2/KeeperRewards.sol";
import {OrderBook} from "../../../src/v2/OrderBook.sol";
import {IAutoRoller} from "../../../src/v2/interfaces/IAutoRoller.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {IOrderBook} from "../../../src/v2/interfaces/IOrderBook.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MockOraclePriceSource} from "../../../src/v2/mocks/MockOraclePriceSource.sol";
import {MockRoundFeed} from "../../../src/v2/mocks/MockRoundFeed.sol";
import {ChainlinkFeedSource} from "../../../src/v2/oracle/ChainlinkFeedSource.sol";
import {SettlementOracle} from "../../../src/v2/oracle/SettlementOracle.sol";

/// @notice Shared fixture of the AutoRoller suites (C2-09): every contract a roll touches is the real one.
/// @dev Wiring, as a deployment would have it:
///        - ExpiryCalendar with no holidays (a test adds one where it needs it);
///        - SettlementOracle for NVDA with sources [ChainlinkFeedSource over a MockRoundFeed, a scriptable
///          MockOraclePriceSource], uncorroboratedDelay 30 min, spotMaxAge 1 h (default). Spot is the feed's latest
///          round; a settlement corroborates when the test also scripts the second source ({_finalizeAt});
///        - Clearinghouse with NVDA registered (strikeTick 1.00 USDG, exercise fee 25 bps); TSLA is NOT registered;
///        - OrderBook at the registry's default fees;
///        - KeeperRewards registered for the Clearinghouse and the roller, paying SETTLE, REDEEM and ROLL bounties;
///        - AutoRoller with `pricer` holding PRICER_ROLE and KeeperRewards set.
///      `alice` is the writer: 10 NVDA in the ledger (1,000 units), payouts to the ledger, and the three approvals
///      (roller operator, book operator, roller as book delegate). `bob` and `carol` are buyers with a USDG allowance
///      for the book. Lifecycle calls are made by `keeper`, so bounties show up as its whole balance.
///      Time is carried in constants and locals and set with vm.warp, never read back from block.timestamp inside a
///      test (via_ir may fold repeated timestamp reads in one function).
abstract contract AutoRollerTestBase is BaseV2Test {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Day indexes (floor(16:00 New York / 86400)) of the September 2026 dates the suites use. All EDT.
    uint32 internal constant THU_0910 = 20_706;
    uint32 internal constant FRI_0911 = 20_707;
    uint32 internal constant SAT_0912 = 20_708;
    uint32 internal constant MON_0914 = 20_710;
    uint32 internal constant TUE_0915 = 20_711;
    uint32 internal constant WED_0916 = 20_712;
    uint32 internal constant THU_0917 = 20_713;
    uint32 internal constant FRI_0918 = 20_714;
    uint32 internal constant MON_0921 = 20_717;
    uint32 internal constant FRI_0925 = 20_721;

    /// @dev Friday 2026-09-25 16:00 EDT.
    uint40 internal constant FRI_2026_09_25 = 1_790_366_400;

    uint128 internal constant K_231 = 231_000_000;
    uint128 internal constant P_3_30 = 3_300_000;

    uint256 internal constant WRITER_SHARES = 10e18;
    uint256 internal constant SETTLE_BOUNTY = 50_000;
    uint256 internal constant REDEEM_BOUNTY = 20_000;
    uint256 internal constant ROLL_BOUNTY = 30_000;
    uint256 internal constant REWARDS_BUDGET = 1_000e6;
    uint32 internal constant UNCORROBORATED_DELAY = 30 minutes;

    uint16 internal constant PREMIUM_FEE_BPS = 500;
    uint40 internal constant NO_DEADLINE = type(uint40).max;

    /// @dev CANCEL_STALE bounty (v7 design §5.2), the same 0.02 USDG as REDEEM.
    uint256 internal constant CANCEL_STALE_BOUNTY = 20_000;
    /// @dev The launch registry's spotMaxAge, 25 h: long enough that yesterday's closing print is still fresh at
    ///      today's open, which is what {AutoRoller.ROLL_OPEN_GRACE} and the overnight {AutoRoller.cancelStale} tests
    ///      need. The fixture itself keeps the oracle's 1 h default.
    uint32 internal constant SPOT_MAX_AGE_25H = 90_000;

    /*//////////////////////////////////////////////////////////////
                               CONTRACTS
    //////////////////////////////////////////////////////////////*/

    ExpiryCalendar internal calendar;
    MockRoundFeed internal feed;
    ChainlinkFeedSource internal cl;
    MockOraclePriceSource internal second;
    SettlementOracle internal oracle;
    Clearinghouse internal ch;
    OrderBook internal book;
    KeeperRewards internal rewards;
    AutoRoller internal roller;

    address internal pricer = makeAddr("pricer");

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    /// @dev Two rounds before START, so the head round has a predecessor (ChainlinkFeedSource.latest needs one).
    function _deployFeeds() internal virtual override {
        feed = new MockRoundFeed(8, "RHNVDA / USD");
        feed.push(219_50000000, START - 2 hours);
        feed.push(NVDA_FEED_ANSWER, START - 1 hours);
    }

    function _deployCore() internal virtual override {
        calendar = new ExpiryCalendar(admin, new uint32[](0));
        cl = new ChainlinkFeedSource(admin);
        second = new MockOraclePriceSource();
        oracle = new SettlementOracle(admin, guardian);
        ch = new Clearinghouse(admin, address(usdg), address(calendar), treasury, "");
        rewards = new KeeperRewards(IERC20(address(usdg)), admin);
        book = new OrderBook(IClearinghouse(address(ch)), admin, guardian, treasury, _fees());
        roller = new AutoRoller(IOrderBook(address(book)), admin);
        vm.label(address(ch), "Clearinghouse");
        vm.label(address(book), "OrderBook");
        vm.label(address(roller), "AutoRoller");
        vm.label(address(oracle), "SettlementOracle");
        vm.label(address(rewards), "KeeperRewards");

        address[] memory sources = new address[](2);
        (sources[0], sources[1]) = (address(cl), address(second));
        vm.startPrank(admin);
        cl.setFeed(address(nvda), address(feed), cl.DEFAULT_MAX_STALE(), cl.DEFAULT_MAX_ROUND_JUMP_BPS());
        cl.setOracle(address(oracle), true);
        oracle.setMarket(address(nvda), sources, 0, UNCORROBORATED_DELAY, 0);
        oracle.setClearinghouse(address(ch));
        ch.grantRole(V2Constants.GUARDIAN_ROLE, guardian);
        ch.registerMarket(
            address(nvda),
            V2Types.MarketConfig({
                enabled: true,
                mintPaused: false,
                strikeTick: STRIKE_TICK,
                exerciseFeeBps: 25,
                oracle: address(oracle),
                mintFeePpm: 0
            })
        );
        ch.setKeeperRewards(address(rewards));
        rewards.setCaller(address(ch), true);
        rewards.setCaller(address(roller), true);
        rewards.setBounty(V2Constants.ACTION_SETTLE, SETTLE_BOUNTY);
        rewards.setBounty(V2Constants.ACTION_REDEEM, REDEEM_BOUNTY);
        rewards.setBounty(V2Constants.ACTION_ROLL, ROLL_BOUNTY);
        rewards.setBounty(V2Constants.ACTION_CANCEL_STALE, CANCEL_STALE_BOUNTY);
        rewards.setDailyCap(100e6);
        roller.setKeeperRewards(address(rewards));
        roller.grantRole(V2Constants.PRICER_ROLE, pricer);
        vm.stopPrank();
        usdg.mint(address(rewards), REWARDS_BUDGET);

        _onboardWriter(alice, WRITER_SHARES);
        address[2] memory buyers = [bob, carol];
        for (uint256 i; i < buyers.length; ++i) {
            vm.prank(buyers[i]);
            usdg.approve(address(book), type(uint256).max);
        }
    }

    function _fees() internal pure returns (V2Types.FeeParams memory) {
        return V2Types.FeeParams({
            premiumFeeBps: PREMIUM_FEE_BPS,
            resaleFeeBps: 0,
            takerFeeFlat: 100_000,
            takerFeeCapBps: 1000,
            makerRebateBps: 5000
        });
    }

    /// @dev The writer setup W2-07 walks a user through: deposit, payouts to the ledger, three approvals.
    function _onboardWriter(address writer, uint256 shares) internal {
        vm.startPrank(writer);
        nvda.approve(address(ch), type(uint256).max);
        ch.deposit(address(nvda), shares, writer);
        ch.setPayoutToLedger(true);
        ch.setOperator(address(roller), true);
        ch.setOperator(address(book), true);
        book.setDelegate(address(roller), true);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                 CLOCK
    //////////////////////////////////////////////////////////////*/

    /// @dev Unix time of `hh:mm:ss` New York on the date with day index `day` (DST resolved by the calendar).
    function _ny(uint32 day, uint256 hh, uint256 mm, uint256 ss) internal view returns (uint256) {
        return calendar.closeOf(day) - 16 hours + hh * 1 hours + mm * 1 minutes + ss;
    }

    /// @dev The 16:00 New York close of the date with day index `day`, as the uint40 expiries use.
    function _close(uint32 day) internal view returns (uint40) {
        // casting to uint40 is safe: every close in these suites is in 2026
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint40(calendar.closeOf(day));
    }

    /// @dev Warps to `t` and prints a feed round at `t`, so spot is fresh at `answer` (8 dp).
    function _spotAt(uint256 t, int256 answer) internal {
        vm.warp(t);
        feed.push(answer, t);
    }

    /// @dev Re-sets NVDA's oracle market with a different spotMaxAge, leaving the sources, deviation and delay as the
    ///      fixture wired them. Expiries already pinned keep the copy they pinned; {ISettlementOracle.spot} and
    ///      {ISettlementOracle.trySpot} always read the current value.
    function _setSpotMaxAge(uint32 spotMaxAge) internal {
        address[] memory sources = new address[](2);
        (sources[0], sources[1]) = (address(cl), address(second));
        vm.prank(admin);
        oracle.setMarket(address(nvda), sources, 0, UNCORROBORATED_DELAY, spotMaxAge);
    }

    /// @dev Makes `expiry` settle at `answer` (8 dp): a round one hour before expiry (in force over the whole window),
    ///      the second source agreeing, then a warp to expiry + FINALIZE_DELAY.
    function _finalizeAt(uint40 expiry, int256 answer) internal {
        uint256 t = uint256(expiry) - 1 hours;
        vm.warp(t);
        feed.push(answer, t);
        // forge-lint: disable-next-line(unsafe-typecast)
        second.setWindow(true, uint256(answer) / 100);
        vm.warp(uint256(expiry) + V2Constants.FINALIZE_DELAY);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _weekly(uint16 otmBps, uint16 askBps) internal pure returns (V2Types.Strategy memory s) {
        s = V2Types.Strategy({
            active: true,
            weekly: true,
            smartPricing: false,
            otmBps: otmBps,
            askBps: askBps,
            minAskBps: 0,
            maxAskBps: 0,
            maxUnits: 0
        });
    }

    function _daily(uint16 otmBps, uint16 askBps) internal pure returns (V2Types.Strategy memory s) {
        s = _weekly(otmBps, askBps);
        s.weekly = false;
    }

    function _smart(uint16 minAskBps, uint16 askBps, uint16 maxAskBps)
        internal
        pure
        returns (V2Types.Strategy memory s)
    {
        s = _weekly(500, askBps);
        (s.smartPricing, s.minAskBps, s.maxAskBps) = (true, minAskBps, maxAskBps);
    }

    function _setStrategy(address writer, V2Types.Strategy memory s) internal {
        vm.prank(writer);
        roller.setStrategy(address(nvda), s);
    }

    /// @dev The non-indexed fields of a Rolled log.
    struct Rolled {
        uint256 longId;
        uint256 orderId;
        uint128 strike;
        uint40 expiry;
        uint128 price;
        uint64 units;
    }

    /// @dev Calls roll as `caller` and returns its result and the Rolled logs it emitted (0 or 1).
    function _roll(address caller, address writer) internal returns (bool advanced, uint256 count, Rolled memory r) {
        vm.recordLogs();
        vm.prank(caller);
        advanced = roller.roll(writer, address(nvda));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(roller) || logs[i].topics[0] != IAutoRoller.Rolled.selector) continue;
            ++count;
            (r.longId, r.orderId, r.strike, r.expiry, r.price, r.units) =
                abi.decode(logs[i].data, (uint256, uint256, uint128, uint40, uint128, uint64));
        }
    }

    /// @dev A keeper roll that must place, returning what it placed.
    function _mustRoll(address writer) internal returns (Rolled memory r) {
        bool advanced;
        uint256 count;
        (advanced, count, r) = _roll(keeper, writer);
        assertTrue(advanced, "roll advanced");
        assertEq(count, 1, "one Rolled");
    }

    /// @dev A keeper roll that must do nothing at all.
    function _noRoll(address writer, string memory why) internal {
        (uint256 longBefore, uint256 orderBefore, uint40 expiryBefore) = roller.position(writer, address(nvda));
        uint256 lastOrder = book.lastOrderId();
        (bool advanced, uint256 count,) = _roll(keeper, writer);
        assertFalse(advanced, why);
        assertEq(count, 0, why);
        (uint256 longAfter, uint256 orderAfter, uint40 expiryAfter) = roller.position(writer, address(nvda));
        assertEq(longAfter, longBefore, "position long unchanged");
        assertEq(orderAfter, orderBefore, "position order unchanged");
        assertEq(expiryAfter, expiryBefore, "position expiry unchanged");
        assertEq(book.lastOrderId(), lastOrder, "no order placed");
    }

    /// @dev `buyer` takes `units` from `orderId` at any price.
    function _buy(address buyer, uint256 longId, uint256 orderId, uint64 units) internal returns (uint64 filled) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        vm.prank(buyer);
        (filled,,) = book.take(
            V2Types.TakeParams({
                longId: longId,
                buying: true,
                orderIds: ids,
                units: units,
                minUnits: 0,
                limitPrice: type(uint128).max,
                writeToSell: false,
                recipient: buyer,
                deadline: NO_DEADLINE
            })
        );
    }

    function _order(uint256 orderId) internal view returns (V2Types.Order memory) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        return book.getOrders(ids)[0];
    }

    function _free(address writer) internal view returns (uint256) {
        return ch.free(writer, address(nvda));
    }

    /// @dev The roller holds nothing, ever: no USDG, no Stock Tokens, no option tokens of `longId`.
    function _assertRollerEmpty(uint256 longId) internal view {
        assertEq(usdg.balanceOf(address(roller)), 0, "roller holds no USDG");
        assertEq(nvda.balanceOf(address(roller)), 0, "roller holds no NVDA");
        if (longId != 0) {
            assertEq(ch.balanceOf(address(roller), longId), 0, "roller holds no longs");
            assertEq(ch.balanceOf(address(roller), longId | 1), 0, "roller holds no shorts");
        }
    }

    /// @dev Independent strike / price formulas: exact rational value rounded up to the grid.
    function _expectedStrike(uint256 spot, uint256 otmBps) internal pure returns (uint256) {
        uint256 exact = (spot * (10_000 + otmBps) + 9999) / 10_000;
        return (exact + STRIKE_TICK - 1) / STRIKE_TICK * STRIKE_TICK;
    }

    function _expectedPrice(uint256 spot, uint256 askBps) internal pure returns (uint256) {
        uint256 exact = (spot * askBps + 9999) / 10_000;
        return (exact + 99) / 100 * 100;
    }
}
