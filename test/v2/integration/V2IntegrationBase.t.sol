// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseV2Test} from "../BaseV2.t.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {ExpiryCalendar} from "../../../src/v2/ExpiryCalendar.sol";
import {KeeperRewards} from "../../../src/v2/KeeperRewards.sol";
import {OrderBook} from "../../../src/v2/OrderBook.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MockRoundFeed} from "../../../src/v2/mocks/MockRoundFeed.sol";
import {MockUniV3Pool} from "../../../src/v2/mocks/MockUniV3Pool.sol";
import {ChainlinkFeedSource} from "../../../src/v2/oracle/ChainlinkFeedSource.sol";
import {FeeSplitter} from "../../../src/v2/periphery/FeeSplitter.sol";
import {SettlementOracle} from "../../../src/v2/oracle/SettlementOracle.sol";
import {UniV3TwapSource} from "../../../src/v2/oracle/UniV3TwapSource.sol";

/// @notice The whole v2 core, real contracts only, over mock tokens and mock price feeds: ExpiryCalendar, the two
///         settlement sources (ChainlinkFeedSource over a MockRoundFeed, UniV3TwapSource over a MockUniV3Pool),
///         SettlementOracle, KeeperRewards, Clearinghouse and OrderBook, wired the way C2-13 will deploy them.
/// @dev Shared by the lifecycle, gas and invariant suites (task C2-08).
///
///      WIRING (INTERFACE_VERSION 8). No contract holds a role table: each is {Managed} and one `AccessManager`
///      maps (target, selector) to a role per `script/v2/roles.v8.json`. `admin` holds the mapped roles, granted by
///      {_wire}; `guardian` holds GUARDIAN on the manager, which is the pause brake the book and the oracle used to
///      take as a constructor argument. NVDA's oracle sources are [Chainlink, UniV3] at the default deviation (150 bps),
///      uncorroborated delay (6 h) and spot age (1 h); both sources list the oracle ({setOracle}), and the oracle names
///      the Clearinghouse, so createSeries pins the settlement configuration of each expiry. The oracle reads the
///      Clearinghouse's open interest for its bounty gate; both pay bounties from one KeeperRewards (SNAPSHOT 0.05,
///      FINALIZE 0.10, SETTLE 0.05, REDEEM 0.02 USDG, 100 USDG daily cap, 1,000 USDG budget). INTERFACE_VERSION 8:
///      exercise fees AND book fees both go to the one real {FeeSplitter}; no EOA is a fee recipient anywhere, at the
///      registry defaults (premium 500 bps, resale 0, taker 0.10 USDG flat capped at 1000 bps, rebate 5000 bps). No
///      payout adapter: ITM call longs are paid in kind (C2-10 adds the adapter).
///      The NVDA market is NOT registered here: {_registerNvda} does it, so a story can start from registration.
///
///      PRICES. The feed (8 dp) prints 219.50 at START - 2 h and 220.00 at START - 10 min, so spot is fresh at START
///      and the strike band applies to series created then. The pool (USDG is token0) sits at tick 222385 (220.0012
///      USDG per share) with 1e19 in-range liquidity from START - 2 h; the liquidity floor is 1e18.
///
///      TIME. Suites carry the clock in variables and warp explicitly; they never read block.timestamp back inside a
///      function (via_ir may fold repeated TIMESTAMP reads, BaseV2Test / OrderBookBaseTest note).
abstract contract V2IntegrationBase is BaseV2Test {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    string internal constant BASE_URI = "https://app.stonkhouse.fun/api/token/";

    /// @dev Pool liquidity (L units) and the source's harmonic-mean floor.
    uint128 internal constant POOL_LIQUIDITY = 1e19;
    uint128 internal constant POOL_MIN_LIQUIDITY = 1e18;
    /// @dev 1e18 / 1.0001^222385 = 220.0012 USDG per share.
    int24 internal constant TICK_220 = 222385;

    /// @dev Series exercise fee, bps (registry default).
    uint16 internal constant EXERCISE_FEE_BPS = 25;
    /// @dev The launch 50/50 burn/treasury split. Source: `src/v2/periphery/FeeSplitter.sol` NatSpec and owner
    ///      decision V3-D; the constructor takes it as `burnBps_`, so the fixture states it once rather than
    ///      letting each suite retype it.
    uint16 internal constant SPLITTER_BURN_BPS = 5_000;

    /// @dev Book fees, the registry defaults (02-interfaces §3).
    uint16 internal constant PREMIUM_FEE_BPS = 500;
    uint16 internal constant RESALE_FEE_BPS = 0;
    uint32 internal constant TAKER_FEE_FLAT = 100_000;
    uint16 internal constant TAKER_FEE_CAP_BPS = 1000;
    uint16 internal constant MAKER_REBATE_BPS = 5000;

    /// @dev Bounties and budget, USDG base units.
    uint256 internal constant SNAPSHOT_BOUNTY = 50_000;
    uint256 internal constant FINALIZE_BOUNTY = 100_000;
    uint256 internal constant SETTLE_BOUNTY = 50_000;
    uint256 internal constant REDEEM_BOUNTY = 20_000;
    uint256 internal constant DAILY_CAP = 100e6;
    uint256 internal constant REWARDS_BUDGET = 1_000e6;

    uint40 internal constant NO_DEADLINE = type(uint40).max;

    V2Types.OrderKind internal constant BID = V2Types.OrderKind.Bid;
    V2Types.OrderKind internal constant RESALE = V2Types.OrderKind.AskResale;
    V2Types.OrderKind internal constant WRITE = V2Types.OrderKind.AskWrite;

    /*//////////////////////////////////////////////////////////////
                               CONTRACTS
    //////////////////////////////////////////////////////////////*/

    MockRoundFeed internal feed;
    MockUniV3Pool internal pool;

    ExpiryCalendar internal calendar;
    ChainlinkFeedSource internal clSource;
    UniV3TwapSource internal poolSource;
    SettlementOracle internal oracle;
    KeeperRewards internal rewards;
    Clearinghouse internal ch;
    OrderBook internal book;

    /// @dev INTERFACE_VERSION 8: kept only so a test can assert NOTHING pays it any more. Both fee lanes go to
    ///      {splitter}; an EOA fee recipient is a v7 shape.
    address internal chFees = makeAddr("chFees");
    /// @notice The one fee recipient of v8: exercise fees from the Clearinghouse AND premium/taker fees from the
    ///         book both land here.
    FeeSplitter internal splitter;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function _deployFeeds() internal virtual override {
        feed = new MockRoundFeed(8, "RHNVDA / USD");
        feed.push(219_50000000, START - 2 hours);
        feed.push(NVDA_FEED_ANSWER, START - 10 minutes);
        pool = new MockUniV3Pool(address(usdg), address(nvda), 500);
        // casting to 'uint40' is safe because START is a 2026 timestamp
        // forge-lint: disable-next-line(unsafe-typecast)
        pool.pushState(uint40(START - 2 hours), TICK_220, POOL_LIQUIDITY);
        vm.label(address(feed), "MockRoundFeed");
        vm.label(address(pool), "MockUniV3Pool");
    }

    function _deployCore() internal virtual override {
        calendar = _newCalendar(new uint32[](0), admin);
        _deployManager();
        clSource = new ChainlinkFeedSource(address(manager));
        _wire(address(clSource), "ChainlinkFeedSource", admin, 0);
        poolSource = new UniV3TwapSource(address(manager), address(usdg));
        _wire(address(poolSource), "UniV3TwapSource", admin, 0);
        oracle = new SettlementOracle(address(manager));
        _wire(address(oracle), "SettlementOracle", admin, 0);
        _grant(V8Roles.GUARDIAN, guardian, 0);
        rewards = new KeeperRewards(IERC20(address(usdg)), address(manager), treasury);
        _wire(address(rewards), "KeeperRewards", admin, 0);
        // INTERFACE_VERSION 8: ONE fee recipient, and it is a contract. Both lanes -- the Clearinghouse's exercise
        // fee and the book's premium/taker fees -- pay the splitter, which is what makes the flywheel reachable from
        // an integration story at all. Constructor shape copied from test/v2/unit/AccessMatrix.t.sol:40-41:
        // (authority, usdg, treasury, burnBps). SPLITTER_BURN_BPS mirrors the launch 50/50 split.
        splitter = new FeeSplitter(address(manager), address(usdg), treasury, SPLITTER_BURN_BPS);
        _wire(address(splitter), "FeeSplitter", admin, 0);
        ch = _newClearinghouse(address(usdg), address(calendar), address(splitter), BASE_URI, admin);
        book = new OrderBook(IClearinghouse(address(ch)), address(manager), address(splitter), _defaultFees());
        _wire(address(book), "OrderBook", admin, 0);
        // The splitter needs to know the book to accept its fees; the router/executor/token pointers stay unset
        // because no integration story routes a buyback, and setting them to mocks would assert behaviour the
        // flywheel suites own (C3-6xx), not this fixture.
        vm.prank(admin);
        splitter.setOrderBook(address(book));
        vm.label(address(calendar), "ExpiryCalendar");
        vm.label(address(clSource), "ChainlinkFeedSource");
        vm.label(address(poolSource), "UniV3TwapSource");
        vm.label(address(oracle), "SettlementOracle");
        vm.label(address(rewards), "KeeperRewards");
        vm.label(address(ch), "Clearinghouse");
        vm.label(address(book), "OrderBook");
        vm.label(address(splitter), "FeeSplitter");

        address[] memory sources = new address[](2);
        (sources[0], sources[1]) = (address(clSource), address(poolSource));
        vm.startPrank(admin);
        clSource.setFeed(
            address(nvda), address(feed), clSource.DEFAULT_MAX_STALE(), clSource.DEFAULT_MAX_ROUND_JUMP_BPS()
        );
        poolSource.setPool(address(nvda), address(pool), POOL_MIN_LIQUIDITY, poolSource.DEFAULT_WINDOW());
        clSource.setOracle(address(oracle), true);
        poolSource.setOracle(address(oracle), true);
        oracle.setMarket(address(nvda), sources, 0, 0, 0);
        oracle.setClearinghouse(address(ch));
        oracle.setKeeperRewards(address(rewards));
        ch.setMinter(address(this), true);
        ch.setMinter(address(book), true);
        ch.setDefaultOracle(address(oracle));
        ch.setDefaultMarketFees(EXERCISE_FEE_BPS, 0);
        ch.setKeeperRewards(address(rewards));
        rewards.setCaller(address(oracle), true);
        rewards.setCaller(address(ch), true);
        rewards.setBounty(V2Constants.ACTION_SNAPSHOT, SNAPSHOT_BOUNTY);
        rewards.setBounty(V2Constants.ACTION_FINALIZE, FINALIZE_BOUNTY);
        rewards.setBounty(V2Constants.ACTION_SETTLE, SETTLE_BOUNTY);
        rewards.setBounty(V2Constants.ACTION_REDEEM, REDEEM_BOUNTY);
        rewards.setDailyCap(DAILY_CAP);
        vm.stopPrank();
        usdg.mint(address(rewards), REWARDS_BUDGET);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _defaultFees() internal pure returns (V2Types.FeeParams memory) {
        return V2Types.FeeParams({
            premiumFeeBps: PREMIUM_FEE_BPS,
            resaleFeeBps: RESALE_FEE_BPS,
            takerFeeFlat: TAKER_FEE_FLAT,
            takerFeeCapBps: TAKER_FEE_CAP_BPS,
            makerRebateBps: MAKER_REBATE_BPS
        });
    }

    function _nvdaMarket() internal view returns (V2Types.MarketConfig memory) {
        return V2Types.MarketConfig({
            enabled: true,
            mintPaused: false,
            strikeTick: STRIKE_TICK,
            exerciseFeeBps: EXERCISE_FEE_BPS,
            oracle: address(oracle),
            mintFeePpm: 0
        });
    }

    /// @dev LISTING (INTERFACE_VERSION 8; `admin` holds it through {_wire}) registers NVDA with a 1.00 USDG strike
    ///      grid, 25 bps exercise fee and the oracle. There is no DEFAULT_ADMIN_ROLE on any v8 contract.
    function _registerNvda() internal {
        vm.startPrank(admin);
        ch.registerMarket(address(nvda), STRIKE_TICK, true);
        ch.setMarketOracle(address(nvda), address(oracle));
        ch.setMarketFees(address(nvda), EXERCISE_FEE_BPS, 0);
        vm.stopPrank();
    }

    /// @dev Every approval a trader gives: USDG to the book and the Clearinghouse, NVDA to the Clearinghouse, ERC-1155
    ///      approval of the book (resale escrow, sales from inventory) and the book as Clearinghouse operator
    ///      (write-on-fill asks, writeToSell).
    function _onboard(address who) internal {
        vm.startPrank(who);
        usdg.approve(address(book), type(uint256).max);
        usdg.approve(address(ch), type(uint256).max);
        nvda.approve(address(ch), type(uint256).max);
        ch.setApprovalForAll(address(book), true);
        ch.setOperator(address(book), true);
        vm.stopPrank();
    }

    function _deposit(address who, address asset, uint256 amount) internal {
        vm.prank(who);
        ch.deposit(asset, amount, who);
    }

    /// @dev Direct mint() requires isMinter[msg.sender]. The fixture grants address(this) and the
    ///      OrderBook; EOAs are not minters. Writer names this as operator, then this mints.
    function _mintAs(address writer, uint256 longId, uint64 units, address longTo) internal {
        if (!ch.isOperator(writer, address(this))) {
            vm.prank(writer);
            ch.setOperator(address(this), true);
        }
        ch.mint(longId, units, writer, longTo);
    }

    function _place(address maker, uint256 longId, V2Types.OrderKind kind, uint128 price, uint64 units)
        internal
        returns (uint256 orderId)
    {
        vm.prank(maker);
        orderId = book.place(longId, kind, price, units, 0);
    }

    /// @dev Buying take: any price, `minUnits` as given, no deadline.
    function _buyParams(uint256 longId, uint256[] memory ids, uint64 units, uint64 minUnits, address recipient)
        internal
        pure
        returns (V2Types.TakeParams memory)
    {
        return V2Types.TakeParams({
            longId: longId,
            buying: true,
            orderIds: ids,
            units: units,
            minUnits: minUnits,
            limitPrice: type(uint128).max,
            writeToSell: false,
            recipient: recipient,
            deadline: NO_DEADLINE,
            // v8: hard cap on the taker-side fees; the existing cases assert fee behaviour elsewhere, so they opt out
            maxTotalFee: type(uint128).max
        });
    }

    /// @dev Selling take: any price, no minimum, no deadline.
    function _sellParams(uint256 longId, uint256[] memory ids, uint64 units, bool writeToSell, address recipient)
        internal
        pure
        returns (V2Types.TakeParams memory)
    {
        return V2Types.TakeParams({
            longId: longId,
            buying: false,
            orderIds: ids,
            units: units,
            minUnits: 0,
            limitPrice: 0,
            writeToSell: writeToSell,
            recipient: recipient,
            deadline: NO_DEADLINE,
            // v8: hard cap on the taker-side fees; the existing cases assert fee behaviour elsewhere, so they opt out
            maxTotalFee: type(uint128).max
        });
    }

    /// @dev Pushes a feed round of `price` (USDG 6 dp per share) stamped `at`, and moves the pool to `tick` from `at`.
    function _print(uint256 price, int24 tick, uint256 at) internal {
        // casting to 'int256' is safe because test prices are far below 2^255 / 100
        // forge-lint: disable-next-line(unsafe-typecast)
        feed.push(int256(price * 100), at);
        // casting to 'uint40' is safe because test timestamps are far below 2^40
        // forge-lint: disable-next-line(unsafe-typecast)
        pool.pushState(uint40(at), tick, POOL_LIQUIDITY);
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        (ids[0], ids[1]) = (a, b);
    }

    function _ids(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](5);
        (ids[0], ids[1], ids[2], ids[3], ids[4]) = (a, b, c, d, e);
    }

    function _holders() internal view returns (address[] memory holders) {
        holders = new address[](4);
        (holders[0], holders[1], holders[2], holders[3]) = (alice, bob, carol, mm);
    }
}
