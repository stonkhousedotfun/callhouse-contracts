// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {BaseV2Test} from "../BaseV2.t.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {ExpiryCalendar} from "../../../src/v2/ExpiryCalendar.sol";
import {OrderBook} from "../../../src/v2/OrderBook.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {IOrderBook} from "../../../src/v2/interfaces/IOrderBook.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Ids} from "../../../src/v2/interfaces/V2Ids.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MockSettlementOracle} from "../../../src/v2/mocks/MockSettlementOracle.sol";
import {MakerRegistry} from "../../../src/v2/mm/MakerRegistry.sol";
import {MakerVault} from "../../../src/v2/mm/MakerVault.sol";

/// @notice Shared fixture of the maker suites (C2-11): the REAL Clearinghouse and OrderBook (no mocks between them),
///         the real ExpiryCalendar, MockSettlementOracle for spot and settlement, a MakerRegistry wired into the book,
///         and a MakerVault funded by the admin with `quoter` holding QUOTER_ROLE.
/// @dev Markets NVDA and TSLA: strikeTick 1.00 USDG, exercise fee 25 bps, spot NVDA 220 / TSLA 358.04. Book fees are the
///      registry defaults (premium 500 bps, resale 0, taker 0.10 USDG flat / 1000 bps cap, rebate 5000 bps). Traders
///      (alice, bob, carol, mm) deposit collateral and give the book every approval; the vault starts with
///      VAULT_USDG and VAULT_SHARES of each Stock Token in its wallet and nothing in the Clearinghouse ledger.
///      Limits: 100 shares per series, 100,000 USDG total notional, 1 % ask tolerance, bids <= 10 % of spot, no
///      lifetime bound, and the launch outflow cap of 2,500 USDG a day (v7 design §5.3) — so every maker suite runs
///      under the cap the launch deploy sets, and the turnover PoCs of {MakerVaultQuoterTest} hit it.
abstract contract MakerTestBase is BaseV2Test {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint128 internal constant CALL_STRIKE = 230_000_000;
    uint128 internal constant PUT_STRIKE = 210_000_000;
    uint128 internal constant TSLA_STRIKE = 360_000_000;

    uint256 internal constant LEDGER_SHARES = 100e18;
    uint256 internal constant LEDGER_USDG = 200_000e6;

    uint256 internal constant VAULT_USDG = 200_000e6;
    uint256 internal constant VAULT_SHARES = 200e18;

    uint64 internal constant MAX_SERIES_UNITS = 10_000;
    uint128 internal constant MAX_TOTAL_NOTIONAL = 100_000e6;
    uint16 internal constant ASK_TOLERANCE_BPS = 100;
    uint16 internal constant MAX_BID_BPS = 1000;
    /// @dev The launch value (v7 design §5.3): the quoter may pay out 2,500 USDG net at once and 5,000 in any 24 h.
    uint128 internal constant MAX_DAILY_OUTFLOW = 2_500e6;
    /// @dev {MakerVault.OUTFLOW_WINDOW}, repeated so the arithmetic in the outflow suite is independent of the contract.
    uint256 internal constant OUTFLOW_WINDOW = 1 days;

    uint16 internal constant PREMIUM_FEE_BPS = 500;
    uint32 internal constant TAKER_FEE_FLAT = 100_000;
    uint16 internal constant TAKER_FEE_CAP_BPS = 1000;
    uint16 internal constant MAKER_REBATE_BPS = 5000;

    uint128 internal constant P2_00 = 2_000_000;
    uint128 internal constant P2_50 = 2_500_000;
    uint128 internal constant P3_00 = 3_000_000;
    uint40 internal constant NO_DEADLINE = type(uint40).max;

    V2Types.OrderKind internal constant BID = V2Types.OrderKind.Bid;
    V2Types.OrderKind internal constant RESALE = V2Types.OrderKind.AskResale;
    V2Types.OrderKind internal constant WRITE = V2Types.OrderKind.AskWrite;

    /*//////////////////////////////////////////////////////////////
                               CONTRACTS
    //////////////////////////////////////////////////////////////*/

    ExpiryCalendar internal calendar;
    MockSettlementOracle internal oracle;
    Clearinghouse internal ch;
    OrderBook internal book;
    MakerRegistry internal registry;
    MakerVault internal vault;

    address internal quoter = makeAddr("quoter");
    address internal stranger = makeAddr("stranger");

    /// @dev NVDA 230 call, weekly FRI_2026_09_18.
    uint256 internal callId;
    /// @dev NVDA 210 put, weekly FRI_2026_09_18.
    uint256 internal putId;
    /// @dev TSLA 360 call, weekly FRI_2026_09_18.
    uint256 internal tslaId;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function _deployCore() internal virtual override {
        calendar = new ExpiryCalendar(admin, new uint32[](0));
        oracle = new MockSettlementOracle();
        ch = new Clearinghouse(admin, address(usdg), address(calendar), treasury, "");
        vm.startPrank(admin);
        ch.registerMarket(address(nvda), _market());
        ch.registerMarket(address(tsla), _market());
        vm.stopPrank();
        oracle.setSpot(address(nvda), true, NVDA_SPOT, START);
        oracle.setSpot(address(tsla), true, TSLA_SPOT, START);

        callId = ch.createSeries(address(nvda), false, CALL_STRIKE, FRI_2026_09_18);
        putId = ch.createSeries(address(nvda), true, PUT_STRIKE, FRI_2026_09_18);
        tslaId = ch.createSeries(address(tsla), false, TSLA_STRIKE, FRI_2026_09_18);

        book = new OrderBook(IClearinghouse(address(ch)), admin, guardian, treasury, _defaultFees());
        registry = new MakerRegistry(admin);
        vm.prank(admin);
        book.setMakerRegistry(registry);
        vault = new MakerVault(IOrderBook(address(book)), admin, quoter, _defaultLimits());
        vm.label(address(ch), "Clearinghouse");
        vm.label(address(book), "OrderBook");
        vm.label(address(registry), "MakerRegistry");
        vm.label(address(vault), "MakerVault");

        _fund(admin, VAULT_USDG, VAULT_SHARES, VAULT_SHARES);
        vm.startPrank(admin);
        usdg.approve(address(vault), type(uint256).max);
        nvda.approve(address(vault), type(uint256).max);
        tsla.approve(address(vault), type(uint256).max);
        vault.deposit(address(usdg), VAULT_USDG);
        vault.deposit(address(nvda), VAULT_SHARES);
        vault.deposit(address(tsla), VAULT_SHARES);
        vm.stopPrank();

        address[4] memory traders = [alice, bob, carol, mm];
        for (uint256 i; i < traders.length; ++i) {
            _onboard(traders[i]);
        }
    }

    function _market() internal view returns (V2Types.MarketConfig memory) {
        return V2Types.MarketConfig({
            enabled: true,
            mintPaused: false,
            strikeTick: STRIKE_TICK,
            exerciseFeeBps: 25,
            oracle: address(oracle),
            mintFeePpm: 0
        });
    }

    function _defaultFees() internal pure returns (V2Types.FeeParams memory) {
        return V2Types.FeeParams({
            premiumFeeBps: PREMIUM_FEE_BPS,
            resaleFeeBps: 0,
            takerFeeFlat: TAKER_FEE_FLAT,
            takerFeeCapBps: TAKER_FEE_CAP_BPS,
            makerRebateBps: MAKER_REBATE_BPS
        });
    }

    function _defaultLimits() internal pure returns (MakerVault.Limits memory) {
        return MakerVault.Limits({
            maxSeriesUnits: MAX_SERIES_UNITS,
            maxTotalNotional: MAX_TOTAL_NOTIONAL,
            askToleranceBps: ASK_TOLERANCE_BPS,
            maxBidBpsOfSpot: MAX_BID_BPS,
            maxOrderLifetime: 0,
            maxDailyOutflow: MAX_DAILY_OUTFLOW
        });
    }

    /// @dev {MakerVault.outflow}'s `used`.
    function _used() internal view returns (uint256 used) {
        (used,) = vault.outflow();
    }

    /// @dev {MakerVault.outflow}'s `available`.
    function _available() internal view returns (uint256 available) {
        (, available) = vault.outflow();
    }

    /// @dev The USDG the outflow cap measures: the vault's wallet plus what the book owes it. Deliberately NOT the
    ///      vault's Clearinghouse ledger (MakerVault NatSpec, OUTFLOW CAP).
    function _cash() internal view returns (uint256) {
        return usdg.balanceOf(address(vault)) + book.owed(address(vault));
    }

    /// @dev Sets one field of the launch limits, leaving the rest at the fixture's values.
    function _setOutflowCap(uint128 cap) internal {
        MakerVault.Limits memory l = _defaultLimits();
        l.maxDailyOutflow = cap;
        vm.prank(admin);
        vault.setLimits(l);
    }

    function _onboard(address who) internal {
        vm.startPrank(who);
        usdg.approve(address(book), type(uint256).max);
        usdg.approve(address(ch), type(uint256).max);
        nvda.approve(address(ch), type(uint256).max);
        tsla.approve(address(ch), type(uint256).max);
        ch.deposit(address(nvda), LEDGER_SHARES, who);
        ch.deposit(address(tsla), LEDGER_SHARES, who);
        ch.deposit(address(usdg), LEDGER_USDG, who);
        ch.setApprovalForAll(address(book), true);
        ch.setOperator(address(book), true);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Quoter moves `amount` of `asset` from the vault wallet into the vault's Clearinghouse ledger.
    function _vaultLedger(address asset, uint256 amount) internal {
        vm.prank(quoter);
        vault.depositToClearinghouse(asset, amount);
    }

    function _vaultPlace(uint256 longId, V2Types.OrderKind kind, uint128 price, uint64 units)
        internal
        returns (uint256 orderId)
    {
        vm.prank(quoter);
        orderId = vault.place(longId, kind, price, units, 0);
    }

    function _place(address maker, uint256 longId, V2Types.OrderKind kind, uint128 price, uint64 units)
        internal
        returns (uint256 orderId)
    {
        vm.prank(maker);
        orderId = book.place(longId, kind, price, units, 0);
    }

    function _buy(uint256 longId, uint256[] memory ids, uint64 units, uint128 limit, address recipient)
        internal
        pure
        returns (V2Types.TakeParams memory)
    {
        return V2Types.TakeParams({
            longId: longId,
            buying: true,
            orderIds: ids,
            units: units,
            minUnits: 0,
            limitPrice: limit,
            writeToSell: false,
            recipient: recipient,
            deadline: NO_DEADLINE
        });
    }

    function _sell(uint256 longId, uint256[] memory ids, uint64 units, uint128 limit, bool writeToSell, address to)
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
            limitPrice: limit,
            writeToSell: writeToSell,
            recipient: to,
            deadline: NO_DEADLINE
        });
    }

    function _take(address taker, V2Types.TakeParams memory p) internal returns (uint64 filled) {
        vm.prank(taker);
        (filled,,) = book.take(p);
    }

    function _vaultTake(V2Types.TakeParams memory p) internal returns (uint64 filled) {
        vm.prank(quoter);
        (filled,,) = vault.take(p);
    }

    function _order(uint256 id) internal view returns (V2Types.Order memory) {
        return book.getOrders(_ids(id))[0];
    }

    function _units(uint256 longId) internal view returns (uint256 units) {
        (units,,) = vault.exposure(longId);
    }

    function _short(uint256 longId) internal pure returns (uint256) {
        return V2Ids.shortIdOf(longId);
    }

    function _premium(uint128 price, uint64 units) internal pure returns (uint256) {
        return uint256(price) * units / 100;
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        (ids[0], ids[1]) = (a, b);
    }

    function _setSpot(address underlying, uint256 spot) internal {
        oracle.setSpot(underlying, true, spot, START);
    }

    /// @dev The OrderFilled logs a recorded call emitted from the book, in order.
    function _filledLogs(Vm.Log[] memory logs) internal view returns (Vm.Log[] memory out) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(book) && logs[i].topics[0] == IOrderBook.OrderFilled.selector) ++n;
        }
        out = new Vm.Log[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(book) && logs[i].topics[0] == IOrderBook.OrderFilled.selector) {
                out[n++] = logs[i];
            }
        }
    }

    /// @dev makerRebate field of an OrderFilled log.
    function _rebateOf(Vm.Log memory log) internal pure returns (uint256 rebate) {
        (,,,,, rebate,,,) =
            abi.decode(log.data, (address, uint64, uint128, uint256, uint256, uint256, bool, bool, address));
    }

    function _makerOf(Vm.Log memory log) internal pure returns (address maker) {
        (maker,,,,,,,,) =
            abi.decode(log.data, (address, uint64, uint128, uint256, uint256, uint256, bool, bool, address));
    }
}
