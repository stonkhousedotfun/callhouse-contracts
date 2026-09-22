// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {BaseV2Test} from "../BaseV2.t.sol";
import {ExpiryCalendar} from "../../../src/v2/ExpiryCalendar.sol";
import {OrderBook} from "../../../src/v2/OrderBook.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {IOrderBook} from "../../../src/v2/interfaces/IOrderBook.sol";
import {ISettlementOracle} from "../../../src/v2/interfaces/ISettlementOracle.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MockClearinghouse} from "../../../src/v2/mocks/MockClearinghouse.sol";
import {MockMakerRegistry} from "../../../src/v2/mocks/MockMakerRegistry.sol";

/// @notice The smallest settlement oracle the Clearinghouse's settle path reads: a test sets a final price per
///         (underlying, expiry); until then the expiry reads as not final. trySpot is never ok, so createSeries skips
///         the spot band.
/// @dev Private to the OrderBook suites (C2-05 owns src/v2/mocks/MockSettlementOracle.sol).
contract BookOracleStub is ISettlementOracle {
    /// @dev Raised by every ISettlementOracle member this double does not implement. Declared HERE rather
    ///      than reused from {V2Errors}: an error the real oracle also throws would let a test that catches
    ///      it pass against a path this stub never implemented.
    error StubDoesNotImplement();

    mapping(address underlying => mapping(uint40 expiry => uint256)) public finalPrice;

    function setFinal(address underlying, uint40 expiry, uint256 price) external {
        finalPrice[underlying][expiry] = price;
    }

    function settlementPrice(address underlying, uint40 expiry)
        external
        view
        returns (V2Types.SettlementStatus status, uint256 price)
    {
        price = finalPrice[underlying][expiry];
        status = price == 0 ? V2Types.SettlementStatus.None : V2Types.SettlementStatus.Finalized;
    }

    function finalize(address underlying, uint40 expiry) external view returns (bool finalized, uint256 price) {
        price = finalPrice[underlying][expiry];
        finalized = price != 0;
    }

    function trySpot(address) external pure returns (bool ok, uint256 price, uint256 updatedAt) {
        return (false, 0, 0);
    }

    /// @dev The real Clearinghouse's createSeries pins the expiry's settlement configuration (INTERFACE_VERSION 6);
    ///      the book never depends on it.
    function pin(address, uint40) external pure {}

    /// @dev Since SEC-07 the real Clearinghouse probes this before it accepts an oracle (`_requireSettlementOracle`)
    ///      and refuses one that lacks it, or answers 0, with NoSource. Without it every real-Clearinghouse twin in
    ///      test/v2/integration/OrderBookRealClearinghouse.t.sol failed setUp and ran nothing (T-482). The real
    ///      oracle's value, from the constant SettlementOracle itself uses, never a literal.
    function SETTLEMENT_WINDOW() external pure returns (uint32) {
        return V2Constants.SETTLEMENT_WINDOW;
    }

    /*//////////////////////////////////////////////////////////////
        THE REST OF ISettlementOracle. The book's suites never call these, and a double that answered
        them with a zero would be answerable on paths it has never been exercised on -- so each one
        reverts instead. The declaration above is what makes the compiler, not maintenance, the thing
        that notices when this stub falls behind the interface (T-499; T-482 was that gap reaching
        seven real-Clearinghouse suites as a setUp failure).
    //////////////////////////////////////////////////////////////*/

    function spot(address) external pure returns (uint256, uint256) {
        revert StubDoesNotImplement();
    }

    function snapshot(address, uint40) external pure returns (uint8) {
        revert StubDoesNotImplement();
    }

    function veto(address, uint40) external pure {
        revert StubDoesNotImplement();
    }

    function unveto(address, uint40) external pure {
        revert StubDoesNotImplement();
    }

    function candidate(address, uint40) external pure returns (uint256, uint8, bool, uint40) {
        revert StubDoesNotImplement();
    }

    function adminResolve(address, uint40, uint256) external pure {
        revert StubDoesNotImplement();
    }
}

/// @notice A contract account (a vault, a multisig, a buggy integration) that forwards arbitrary calls and can be
///         switched to refuse ERC-1155 tokens, for the "receiver rejects" paths of the book, or to spend gas in its
///         acceptance hook (a heavy wallet, or a hostile maker burning whatever gas the hook is given).
contract BookActor {
    bool public acceptTokens = true;
    /// @dev Gas each acceptance hook spends before it answers; type(uint256).max spends all it is given.
    uint256 public hookGas;

    error Rejected();

    function setAcceptTokens(bool on) external {
        acceptTokens = on;
    }

    function setHookGas(uint256 amount) external {
        hookGas = amount;
    }

    /// @dev Forwards `data` to `target` and bubbles up any revert unchanged.
    function exec(address target, bytes calldata data) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external view returns (bytes4) {
        _spendHookGas();
        if (!acceptTokens) revert Rejected();
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        _spendHookGas();
        if (!acceptTokens) revert Rejected();
        return this.onERC1155BatchReceived.selector;
    }

    function _spendHookGas() private view {
        uint256 amount = hookGas;
        if (amount == 0) return;
        uint256 start = gasleft();
        while (start - gasleft() < amount) {}
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

/// @notice Shared fixture of the OrderBook suites (task C2-06): the real ExpiryCalendar, a MockClearinghouse with NVDA
///         and TSLA registered, four series, the OrderBook at the registry's default fees, and traders who have
///         deposited collateral and approved the book for everything it can do (USDG allowance, ERC-1155 approval,
///         Clearinghouse operator).
/// @dev The Clearinghouse comes from {_newClearinghouse}, the MockClearinghouse here. C2-08's integration variants
///      (test/v2/integration/OrderBookRealClearinghouse.t.sol) override that hook to run every OrderBook suite against
///      the real Clearinghouse, typed as the mock: the two share the constructor and every selector the suites call.
///      Time is carried in constants and local variables and set with vm.warp, never read back from block.timestamp
///      inside a test (via_ir may fold repeated timestamp reads in one function).
abstract contract OrderBookBaseTest is BaseV2Test {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Strikes, USDG base units (6 dp) per share.
    uint128 internal constant CALL_STRIKE = 230_000_000;
    uint128 internal constant PUT_STRIKE = 210_000_000;
    uint128 internal constant TSLA_STRIKE = 360_000_000;

    /// @dev Collateral each trader deposits into the Clearinghouse ledger: 100 shares of each Stock Token (10,000 call
    ///      units) and 200,000 USDG.
    uint256 internal constant LEDGER_SHARES = 100e18;
    uint256 internal constant LEDGER_USDG = 200_000e6;

    /// @dev Order prices used across the suites, USDG base units per share.
    uint128 internal constant P2_00 = 2_000_000;
    uint128 internal constant P2_50 = 2_500_000;
    uint128 internal constant P3_00 = 3_000_000;

    uint40 internal constant NO_DEADLINE = type(uint40).max;
    /// @dev BaseV2Test.START as the uint40 the book's time fields use (a literal, so no narrowing cast).
    uint40 internal constant START40 = 1_789_000_000;

    /// @dev The registry defaults (02-interfaces §3 "fees").
    uint16 internal constant PREMIUM_FEE_BPS = 500;
    uint16 internal constant RESALE_FEE_BPS = 0;
    uint32 internal constant TAKER_FEE_FLAT = 100_000;
    uint16 internal constant TAKER_FEE_CAP_BPS = 1000;
    uint16 internal constant MAKER_REBATE_BPS = 5000;

    V2Types.OrderKind internal constant BID = V2Types.OrderKind.Bid;
    V2Types.OrderKind internal constant RESALE = V2Types.OrderKind.AskResale;
    V2Types.OrderKind internal constant WRITE = V2Types.OrderKind.AskWrite;

    /*//////////////////////////////////////////////////////////////
                               CONTRACTS
    //////////////////////////////////////////////////////////////*/

    ExpiryCalendar internal calendar;
    BookOracleStub internal oracle;
    MockClearinghouse internal ch;
    OrderBook internal book;
    MockMakerRegistry internal registry;

    /// @dev NVDA 230 call, weekly FRI_2026_09_18.
    uint256 internal callId;
    /// @dev NVDA 210 put, weekly FRI_2026_09_18.
    uint256 internal putId;
    /// @dev NVDA 230 call, daily THU_2026_09_10.
    uint256 internal dailyId;
    /// @dev TSLA 360 call, weekly FRI_2026_09_18.
    uint256 internal tslaId;

    address internal chFees = makeAddr("chFees");
    address internal stranger = makeAddr("stranger");

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function _deployCore() internal virtual override {
        calendar = _newCalendar(new uint32[](0), admin);
        oracle = new BookOracleStub();
        ch = _newClearinghouse();
        registry = new MockMakerRegistry();

        vm.startPrank(admin);
        ch.setMinter(address(this), true);
        ch.setDefaultOracle(address(oracle));
        ch.setDefaultMarketFees(25, 0);
        ch.registerMarket(address(nvda), STRIKE_TICK, true);
        ch.registerMarket(address(tsla), STRIKE_TICK, true);
        vm.stopPrank();

        callId = ch.createSeries(address(nvda), false, CALL_STRIKE, FRI_2026_09_18);
        putId = ch.createSeries(address(nvda), true, PUT_STRIKE, FRI_2026_09_18);
        dailyId = ch.createSeries(address(nvda), false, CALL_STRIKE, THU_2026_09_10);
        tslaId = ch.createSeries(address(tsla), false, TSLA_STRIKE, FRI_2026_09_18);

        book = new OrderBook(IClearinghouse(address(ch)), address(manager), treasury, _defaultFees());
        _wire(address(book), "OrderBook", admin, 0);
        // INTERFACE_VERSION 8: write fills plan against `isMinter(book)` now, so the fixture opts the book in
        // exactly as the v8 deploy will.
        vm.prank(admin);
        ch.setMinter(address(book), true);
        vm.label(address(ch), "Clearinghouse");
        vm.label(address(book), "OrderBook");

        address[4] memory traders = [alice, bob, carol, mm];
        for (uint256 i; i < traders.length; ++i) {
            _onboard(traders[i]);
        }
    }

    /// @dev The Clearinghouse under test, deployed with (admin, usdg, calendar, chFees, ""). `calendar` is set first.
    function _newClearinghouse() internal virtual returns (MockClearinghouse) {
        _deployManager();
        MockClearinghouse house = _deployClearinghouse();
        _wire(address(house), "Clearinghouse", admin, 0);
        _grant(V8Roles.GUARDIAN, guardian, 0);
        return house;
    }

    /// @dev Override to swap in the real Clearinghouse; keep `_newClearinghouse` so `_wire` still runs.
    function _deployClearinghouse() internal virtual returns (MockClearinghouse) {
        return new MockClearinghouse(address(manager), address(usdg), address(calendar), chFees, "");
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
            resaleFeeBps: RESALE_FEE_BPS,
            takerFeeFlat: TAKER_FEE_FLAT,
            takerFeeCapBps: TAKER_FEE_CAP_BPS,
            makerRebateBps: MAKER_REBATE_BPS
        });
    }

    /// @dev Default fees with field `field` (0 premium, 1 resale, 2 flat, 3 cap, 4 rebate) one above its ceiling.
    function _feesAbove(uint256 field) internal pure returns (V2Types.FeeParams memory f) {
        f = _defaultFees();
        if (field == 0) f.premiumFeeBps = V2Constants.PREMIUM_FEE_CEIL_BPS + 1;
        if (field == 1) f.resaleFeeBps = V2Constants.PREMIUM_FEE_CEIL_BPS + 1;
        if (field == 2) f.takerFeeFlat = V2Constants.TAKER_FEE_FLAT_CEIL + 1;
        if (field == 3) f.takerFeeCapBps = V2Constants.TAKER_FEE_CAP_CEIL_BPS + 1;
        if (field == 4) f.makerRebateBps = 10_001;
    }

    /// @dev Deposits ledger collateral and grants the book every approval a trader can give it.
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

    /// @dev A funded, onboarded contract trader. It accepts ERC-1155 tokens until told otherwise.
    function _newActor() internal returns (BookActor actor) {
        actor = new BookActor();
        _fund(address(actor), ACTOR_USDG, ACTOR_SHARES, ACTOR_SHARES);
        _onboard(address(actor));
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Direct mint() requires isMinter[msg.sender] (Clearinghouse.sol:565). The fixture grants
    ///      address(this) and the OrderBook; EOAs are not minters. Mirror ClearinghouseBase._write:
    ///      writer names this as operator, then this mints.
    function _mintLongs(address who, uint256 longId, uint64 units) internal {
        if (!ch.isOperator(who, address(this))) {
            vm.prank(who);
            ch.setOperator(address(this), true);
        }
        ch.mint(longId, units, who, who);
    }

    function _place(address maker, uint256 longId, V2Types.OrderKind kind, uint128 price, uint64 units)
        internal
        returns (uint256 orderId)
    {
        vm.prank(maker);
        orderId = book.place(longId, kind, price, units, 0);
    }

    /// @dev Buying take: any price, no minimum, no deadline.
    function _buy(uint256 longId, uint256[] memory ids, uint64 units, address recipient)
        internal
        pure
        returns (V2Types.TakeParams memory p)
    {
        p = V2Types.TakeParams({
            longId: longId,
            buying: true,
            orderIds: ids,
            units: units,
            minUnits: 0,
            limitPrice: type(uint128).max,
            writeToSell: false,
            recipient: recipient,
            deadline: NO_DEADLINE,
            // v8: hard cap on the taker-side fees; the existing cases assert fee behaviour elsewhere, so they opt out
            maxTotalFee: type(uint128).max
        });
    }

    /// @dev Selling take: any price, no minimum, no deadline.
    function _sell(uint256 longId, uint256[] memory ids, uint64 units, bool writeToSell, address recipient)
        internal
        pure
        returns (V2Types.TakeParams memory p)
    {
        p = V2Types.TakeParams({
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

    function _take(address taker, V2Types.TakeParams memory p)
        internal
        returns (uint64 unitsFilled, uint256 premium, uint256 takerFee)
    {
        vm.prank(taker);
        return book.take(p);
    }

    function _order(uint256 id) internal view returns (V2Types.Order memory) {
        return book.getOrders(_ids(id))[0];
    }

    function _premium(uint128 price, uint64 units) internal pure returns (uint256) {
        return uint256(price) * units / 100;
    }

    /// @dev min(flat, premium * cap / 1e4) at the book's current fee parameters.
    function _takerFee(uint256 premium) internal view returns (uint256) {
        V2Types.FeeParams memory f = book.feeParams();
        uint256 byCap = premium * f.takerFeeCapBps / 10_000;
        return byCap < f.takerFeeFlat ? byCap : f.takerFeeFlat;
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        (ids[0], ids[1]) = (a, b);
    }

    function _ids(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (a, b, c);
    }

    function _ids(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](4);
        (ids[0], ids[1], ids[2], ids[3]) = (a, b, c, d);
    }

    function _ids(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](5);
        (ids[0], ids[1], ids[2], ids[3], ids[4]) = (a, b, c, d, e);
    }

    /// @dev The OrderFilled logs of a recorded call, in log order.
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

    /// @dev The non-indexed fields of an OrderFilled log.
    struct Filled {
        address maker;
        uint64 units;
        uint128 price;
        uint256 premium;
        uint256 sellerFee;
        uint256 makerRebate;
        bool primary;
        bool takerIsBuyer;
        address recipient;
    }

    function _decodeFilled(Vm.Log memory log) internal pure returns (Filled memory f) {
        (f.maker, f.units, f.price, f.premium, f.sellerFee, f.makerRebate, f.primary, f.takerIsBuyer, f.recipient) =
            abi.decode(log.data, (address, uint64, uint128, uint256, uint256, uint256, bool, bool, address));
    }
}
