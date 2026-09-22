// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OrderBookBaseTest} from "./OrderBookBase.t.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {IOrderBook} from "../../../src/v2/interfaces/IOrderBook.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MockFundingSource} from "../../../src/v2/mocks/MockFundingSource.sol";

/// @dev MockFundingSource plus ERC-1155 receiver so the RealClearinghouse twin can mint shorts to the source.
contract FundingMaker is MockFundingSource {
    constructor(IClearinghouse ch_) MockFundingSource(ch_) {}

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0x4e2312e0;
    }
}

/// @dev `fundable` answers; `fund` reverts or drains. Shared mock Mode.Revert/GasDrain also breaks
///      the fundable read, which would skip the fund call entirely.
contract FundableThenFail {
    IClearinghouse public ch;
    uint256 public fundableAmount;
    bool public drain;

    constructor(IClearinghouse ch_) {
        ch = ch_;
    }

    function setFundable(uint256 amount) external {
        fundableAmount = amount;
    }

    function setDrain(bool on) external {
        drain = on;
    }

    function setOperator(address operator, bool approved) external {
        ch.setOperator(operator, approved);
    }

    function fundable(address) external view returns (uint256) {
        return fundableAmount;
    }

    function fund(address, uint256) external {
        if (drain) {
            uint256 burn = type(uint256).max;
            while (burn != 0) --burn;
        }
        revert("fund-revert");
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0x4e2312e0;
    }
}

/// @dev `fund` attempts a book reentry then reverts, so the book's `try` emits FundingFailed.
contract RevertAfterReenter {
    IClearinghouse public ch;
    address public book;
    bytes public reenterCalldata;
    uint256 public fundableAmount;

    constructor(IClearinghouse ch_) {
        ch = ch_;
    }

    function setBook(address book_) external {
        book = book_;
    }

    function setReenterCalldata(bytes calldata data) external {
        reenterCalldata = data;
    }

    function setFundable(uint256 amount) external {
        fundableAmount = amount;
    }

    function setOperator(address operator, bool approved) external {
        ch.setOperator(operator, approved);
    }

    function fundable(address) external view returns (uint256) {
        return fundableAmount;
    }

    function fund(address, uint256) external {
        (bool ok,) = book.call(reenterCalldata);
        ok;
        revert("reenter-then-revert");
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0x4e2312e0;
    }
}

/// @dev `fund` SUCCEEDS and deposits nothing: it WITHDRAWS its own free collateral, so the maker's Clearinghouse
///      `free` is strictly LOWER after the call than the `before` the book measured. No {MockFundingSource} mode can
///      do this -- every one of them either deposits or fails, and the shared double is the right shape for the
///      behaviours {IFundingSource} documents. This is the one shape it does NOT document and the book must still
///      survive: the book's reentrancy guard is held for the whole take but covers only the book, so
///      {IClearinghouse.withdraw} is reachable from inside `fund`. A raw `after - before` underflows here, and a
///      panic in a `try`'s SUCCESS clause is not caught by its `catch`, so the whole take reverts -- taking honest
///      makers' fills with it. Source: src/v2/OrderBook.sol `_preFund`, the delta in the success clause.
/// @dev SEC-11's bespoke drainer. The SHARED double now expresses the same input as
///      `MockFundingSource.Mode.Drain` (F-CT3-01, src/v2/mocks/MockFundingSource.sol) -- a test author looking for
///      "can any double lower its own free" should find it there. This one is left exactly as SEC-11 landed it:
///      swapping it out would rewrite a passing test of another row to no behavioural end.
contract SelfDrainingSource {
    IClearinghouse public ch;
    uint256 public fundableAmount;
    uint256 public drainAmount;

    constructor(IClearinghouse ch_) {
        ch = ch_;
    }

    function setFundable(uint256 amount) external {
        fundableAmount = amount;
    }

    /// @notice Base units of the collateral asset `fund` pulls back OUT of the ledger instead of putting in.
    function setDrain(uint256 amount) external {
        drainAmount = amount;
    }

    function setOperator(address operator, bool approved) external {
        ch.setOperator(operator, approved);
    }

    function approveClearinghouse(address asset) external {
        IERC20(asset).approve(address(ch), type(uint256).max);
    }

    function fundable(address) external view returns (uint256) {
        return fundableAmount;
    }

    /// @dev Returns normally, so the book takes the `try`'s success branch with `free` reduced.
    function fund(address asset, uint256) external {
        if (drainAmount != 0) ch.withdraw(asset, drainAmount, address(this));
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0x4e2312e0;
    }
}

/// @dev A source that answers {IFundingSource.fundable} PER ASSET. Every shared double answers the same amount for
///      every asset ("named for signature parity with the interface", MockFundingSource.sol:95), which is exactly the
///      distinction T-SEC-P4 has to draw: `setFunding` probes USDG and a CALL series asks for the underlying. This one
///      answers only for the assets it was told about and 0 for the rest, and funds honestly when it does answer.
contract AssetPickySource {
    IClearinghouse public ch;
    mapping(address => uint256) public answer;

    constructor(IClearinghouse ch_) {
        ch = ch_;
    }

    function setAnswerFor(address asset, uint256 amount) external {
        answer[asset] = amount;
    }

    function setOperator(address operator, bool approved) external {
        ch.setOperator(operator, approved);
    }

    function approveClearinghouse(address asset) external {
        IERC20(asset).approve(address(ch), type(uint256).max);
    }

    function fundable(address asset) external view returns (uint256) {
        return answer[asset];
    }

    function fund(address asset, uint256 amount) external {
        uint256 give = amount > answer[asset] ? answer[asset] : amount;
        if (give == 0) return;
        ch.deposit(asset, give, address(this));
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0x4e2312e0;
    }
}

/// @notice C8-13 pre-fund stage: dry plan -> fund -> real plan, quoteTake fundable budget, setFunding EOA probe.
contract OrderBookPreFundTest is OrderBookBaseTest {
    /// @dev 100 call units = 1 share = 1e18 NVDA. Source: V2Constants.UNIT * 100.
    uint64 internal constant HUNDRED = 100;
    uint256 internal constant ONE_SHARE = 100 * V2Constants.UNIT;

    function _enable(FundingMaker src) internal {
        vm.prank(admin);
        book.setFundingAllowed(address(src), true);
        vm.prank(address(src));
        book.setFunding(true);
    }

    function _source(uint256 fundableAmount, uint256 walletNvda) internal returns (FundingMaker src) {
        src = new FundingMaker(IClearinghouse(address(ch)));
        src.setFundable(fundableAmount);
        src.setBook(address(book));
        src.approveClearinghouse(address(nvda));
        src.approveClearinghouse(address(usdg));
        src.setOperator(address(book), true);
        if (walletNvda != 0) nvda.mint(address(src), walletNvda);
        _enable(src);
    }

    function _placeWrite(address maker, uint64 units) internal returns (uint256) {
        vm.prank(maker);
        return book.place(callId, WRITE, P2_00, units, 0);
    }

    function _count(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(book) && logs[i].topics[0] == topic) ++n;
        }
    }

    function _firstTopicIndex(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(book) && logs[i].topics[0] == topic) return i;
        }
        revert("topic missing");
    }

    /*//////////////////////////////////////////////////////////////
                              setFunding
    //////////////////////////////////////////////////////////////*/

    function test_setFunding_eoaCannotEnable() public {
        vm.prank(admin);
        book.setFundingAllowed(alice, true);
        vm.prank(alice);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.setFunding(true);
    }

    function test_setFunding_sourceAnsweringZeroCanEnable() public {
        FundingMaker src = new FundingMaker(IClearinghouse(address(ch)));
        src.setFundable(0);
        vm.prank(admin);
        book.setFundingAllowed(address(src), true);
        vm.prank(address(src));
        book.setFunding(true);
        (bool allowed, bool on) = book.fundingOf(address(src));
        assertTrue(allowed);
        assertTrue(on);
    }

    function test_setFunding_notAllowedReverts() public {
        FundingMaker src = new FundingMaker(IClearinghouse(address(ch)));
        src.setFundable(ONE_SHARE);
        vm.prank(address(src));
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.setFunding(true);
    }

    function test_setFundingAllowed_falseClearsOn() public {
        FundingMaker src = _source(ONE_SHARE, 0);
        (, bool on) = book.fundingOf(address(src));
        assertTrue(on);
        vm.prank(admin);
        book.setFundingAllowed(address(src), false);
        (bool allowed, bool stillOn) = book.fundingOf(address(src));
        assertFalse(allowed);
        assertFalse(stillOn);
    }

    function test_setFunding_offNeverProbes() public {
        FundingMaker src = _source(ONE_SHARE, 0);
        src.setMode(MockFundingSource.Mode.Revert);
        vm.prank(address(src));
        book.setFunding(false);
        (, bool on) = book.fundingOf(address(src));
        assertFalse(on);
    }

    /*//////////////////////////////////////////////////////////////
                           honest / quote parity
    //////////////////////////////////////////////////////////////*/

    function test_preFund_honest_quoteTakeEqualsTake() public {
        FundingMaker src = _source(10 * ONE_SHARE, 10 * ONE_SHARE);
        uint256 id = _placeWrite(address(src), HUNDRED);
        V2Types.TakeParams memory p = _buy(callId, _ids(id), HUNDRED, alice);
        (uint64 qUnits, uint256 qPrem, uint256 qFee, uint256 qSeller) = book.quoteTake(p);
        vm.recordLogs();
        (uint64 tUnits, uint256 tPrem, uint256 tFee) = _take(alice, p);
        assertEq(tUnits, qUnits);
        assertEq(tPrem, qPrem);
        assertEq(tFee, qFee);
        assertEq(qSeller, 0, "buying: quote sellerFees is 0");
        assertEq(tUnits, HUNDRED);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, IOrderBook.Funded.selector), 1);
        assertEq(_count(logs, IOrderBook.FundingFailed.selector), 0);
        assertLt(
            _firstTopicIndex(logs, IOrderBook.Funded.selector), _firstTopicIndex(logs, IOrderBook.OrderFilled.selector)
        );
    }

    function test_preFund_needEqualsDryPlanShortfallNotFundable() public {
        // Dry-plan fill is 1 share; fundable is 10 shares; free is 0 => need = 1 share, not fundable.
        FundingMaker src = _source(10 * ONE_SHARE, 10 * ONE_SHARE);
        uint256 id = _placeWrite(address(src), HUNDRED);
        vm.recordLogs();
        _take(alice, _buy(callId, _ids(id), HUNDRED, alice));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 requested;
        uint256 delivered;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(book) && logs[i].topics[0] == IOrderBook.Funded.selector) {
                (requested, delivered) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        assertEq(requested, ONE_SHARE, "fund argument is the need, not fundable");
        assertEq(delivered, ONE_SHARE, "honest source delivers the need");
    }

    function test_preFund_enoughFree_noCallNoEvent() public {
        FundingMaker src = _source(10 * ONE_SHARE, 10 * ONE_SHARE);
        // Park 1 share on the ledger so the dry plan consumes free and need is 0.
        vm.prank(address(src));
        ch.deposit(address(nvda), ONE_SHARE, address(src));
        uint256 id = _placeWrite(address(src), HUNDRED);
        vm.recordLogs();
        _take(alice, _buy(callId, _ids(id), HUNDRED, alice));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, IOrderBook.Funded.selector), 0);
        assertEq(_count(logs, IOrderBook.FundingFailed.selector), 0);
        assertEq(ch.balanceOf(alice, callId), HUNDRED);
    }

    function test_preFund_twoOrdersOneMaker_oneFundCallForTheSum() public {
        FundingMaker src = _source(10 * ONE_SHARE, 10 * ONE_SHARE);
        uint256 a = _placeWrite(address(src), HUNDRED);
        uint256 b = _placeWrite(address(src), HUNDRED);
        vm.recordLogs();
        _take(alice, _buy(callId, _ids(a, b), 200, alice));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, IOrderBook.Funded.selector), 1);
        uint256 requested;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(book) && logs[i].topics[0] == IOrderBook.Funded.selector) {
                (requested,) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        assertEq(requested, 2 * ONE_SHARE);
        assertEq(ch.balanceOf(alice, callId), 200);
    }

    /*//////////////////////////////////////////////////////////////
                          partial / fail modes
    //////////////////////////////////////////////////////////////*/

    function test_preFund_partial_skipsThatMakerFillsTheOthers() public {
        FundingMaker weak = _source(10 * ONE_SHARE, 10 * ONE_SHARE);
        weak.setMode(MockFundingSource.Mode.Partial);
        weak.setDeliverBps(0);
        FundingMaker strong = _source(10 * ONE_SHARE, 10 * ONE_SHARE);
        uint256 weakId = _placeWrite(address(weak), HUNDRED);
        uint256 strongId = _placeWrite(address(strong), HUNDRED);
        (uint64 filled,,) = _take(alice, _buy(callId, _ids(weakId, strongId), 200, alice));
        assertEq(filled, HUNDRED, "weak maker skipped; strong filled");
        assertEq(ch.balanceOf(alice, callId), HUNDRED);
        assertEq(ch.balanceOf(address(strong), callId | 1), HUNDRED);
    }

    function test_preFund_partial_minUnitsStillReverts() public {
        FundingMaker weak = _source(10 * ONE_SHARE, 10 * ONE_SHARE);
        weak.setMode(MockFundingSource.Mode.Partial);
        weak.setDeliverBps(0);
        uint256 id = _placeWrite(address(weak), HUNDRED);
        V2Types.TakeParams memory p = _buy(callId, _ids(id), HUNDRED, alice);
        p.minUnits = HUNDRED;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.BelowMinUnits.selector, uint64(0), HUNDRED));
        book.take(p);
    }

    function _failingSource(bool drain) internal returns (FundableThenFail src) {
        src = new FundableThenFail(IClearinghouse(address(ch)));
        src.setFundable(10 * ONE_SHARE);
        src.setDrain(drain);
        src.setOperator(address(book), true);
        vm.prank(admin);
        book.setFundingAllowed(address(src), true);
        vm.prank(address(src));
        book.setFunding(true);
    }

    function test_preFund_revert_emitsFundingFailedAndContinues() public {
        FundableThenFail bad = _failingSource(false);
        FundingMaker good = _source(10 * ONE_SHARE, 10 * ONE_SHARE);
        uint256 badId = _placeWrite(address(bad), HUNDRED);
        uint256 goodId = _placeWrite(address(good), HUNDRED);
        vm.recordLogs();
        (uint64 filled,,) = _take(alice, _buy(callId, _ids(badId, goodId), 200, alice));
        assertEq(filled, HUNDRED);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, IOrderBook.FundingFailed.selector), 1);
        assertEq(_count(logs, IOrderBook.Funded.selector), 1);
    }

    function test_preFund_gasDrain_emitsFundingFailed() public {
        FundableThenFail bad = _failingSource(true);
        uint256 id = _placeWrite(address(bad), HUNDRED);
        vm.recordLogs();
        V2Types.TakeParams memory p = _buy(callId, _ids(id), HUNDRED, alice);
        p.minUnits = 0;
        (uint64 filled,,) = _take(alice, p);
        assertEq(filled, 0);
        assertEq(_count(vm.getRecordedLogs(), IOrderBook.FundingFailed.selector), 1);
    }

    function test_preFund_over_deliveredGreaterThanRequestedNoRevert() public {
        FundingMaker src = _source(10 * ONE_SHARE, 10 * ONE_SHARE);
        uint256 id = _placeWrite(address(src), HUNDRED);
        src.setMode(MockFundingSource.Mode.Over);
        vm.recordLogs();
        _take(alice, _buy(callId, _ids(id), HUNDRED, alice));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 requested;
        uint256 delivered;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(book) && logs[i].topics[0] == IOrderBook.Funded.selector) {
                (requested, delivered) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        assertEq(requested, ONE_SHARE);
        assertGt(delivered, requested);
        assertEq(ch.balanceOf(alice, callId), HUNDRED);
    }

    function test_preFund_reenterPlace_fundingFailed() public {
        RevertAfterReenter src = new RevertAfterReenter(IClearinghouse(address(ch)));
        src.setBook(address(book));
        src.setFundable(10 * ONE_SHARE);
        src.setOperator(address(book), true);
        nvda.mint(address(src), 10 * ONE_SHARE);
        vm.prank(address(src));
        nvda.approve(address(ch), type(uint256).max);
        vm.prank(admin);
        book.setFundingAllowed(address(src), true);
        vm.prank(address(src));
        book.setFunding(true);
        src.setReenterCalldata(abi.encodeCall(book.place, (callId, WRITE, P2_00, HUNDRED, uint40(0))));
        uint256 id = _placeWrite(address(src), HUNDRED);
        vm.recordLogs();
        V2Types.TakeParams memory p = _buy(callId, _ids(id), HUNDRED, alice);
        p.minUnits = 0;
        _take(alice, p);
        assertEq(_count(vm.getRecordedLogs(), IOrderBook.FundingFailed.selector), 1);
    }

    /// @dev The property (IFundingSource.sol:18-21; OrderBook._preFund's SATURATING comment): the book's reentrancy
    ///      guard is held for the whole take but does NOT cover the Clearinghouse, so a source that re-enters
    ///      `Clearinghouse.deposit` from inside {fund} is not refused -- and the book still accounts it, because
    ///      delivery is the source's `free` delta, which then includes the re-entrant deposit. Until T-470 the double
    ///      could only fire at the book, so this deposit calldata reverted ON THE ORDERBOOK as an unknown selector,
    ///      the double swallowed it, and `Funded == 1` passed without anything re-entering the Clearinghouse.
    function test_preFund_reenterDeposit_stillFunds() public {
        FundingMaker src = _source(10 * ONE_SHARE, 10 * ONE_SHARE);
        bytes memory reenter = abi.encodeCall(ch.deposit, (address(nvda), uint256(1), address(src)));
        src.setReenterCalldata(reenter);
        src.setReenterTarget(address(ch));
        src.setMode(MockFundingSource.Mode.Reenter);
        uint256 id = _placeWrite(address(src), HUNDRED);
        // The re-entrant deposit must REACH the Clearinghouse. Aimed at the book, it never does.
        vm.expectCall(address(ch), reenter);
        vm.recordLogs();
        _take(alice, _buy(callId, _ids(id), HUNDRED, alice));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, IOrderBook.Funded.selector), 1);
        assertEq(_count(logs, IOrderBook.FundingFailed.selector), 0);
        uint256 requested;
        uint256 delivered;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(book) && logs[i].topics[0] == IOrderBook.Funded.selector) {
                (requested, delivered) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        assertEq(requested, ONE_SHARE);
        // expectCall alone would also be met by the Reenter probe in {fundable}, which fires the same calldata inside
        // the book's staticcall and cannot land. The extra 1 wei in the delta is what proves the call from {fund}
        // actually deposited, outside the book's guard, and that the book counted it.
        assertEq(delivered, requested + 1, "re-entrant Clearinghouse.deposit(nvda, 1, src) from fund() did not land");
        assertEq(ch.balanceOf(alice, callId), HUNDRED, "and the take still fills");
    }

    function test_preFund_fifthFundedMaker_noCallPlannedOnFree() public {
        FundingMaker[5] memory srcs;
        uint256[5] memory ids;
        for (uint256 i; i < 5; ++i) {
            srcs[i] = _source(10 * ONE_SHARE, 10 * ONE_SHARE);
            ids[i] = _placeWrite(address(srcs[i]), HUNDRED);
        }
        vm.recordLogs();
        (uint64 filled,,) = _take(alice, _buy(callId, _ids(ids[0], ids[1], ids[2], ids[3], ids[4]), 500, alice));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, IOrderBook.Funded.selector), 4, "cap is MAX_FUNDED_MAKERS_PER_TAKE");
        assertEq(filled, 400, "fifth maker has no free and was not funded");
    }

    function test_preFund_sellingIntoFundedBid_noFundEvents() public {
        FundingMaker src = _source(10 * ONE_SHARE, 0);
        usdg.mint(address(src), 10_000e6);
        vm.prank(address(src));
        usdg.approve(address(book), type(uint256).max);
        vm.prank(address(src));
        uint256 bid = book.place(putId, BID, P2_00, HUNDRED, 0);
        _mintLongs(alice, putId, HUNDRED);
        vm.recordLogs();
        _take(alice, _sell(putId, _ids(bid), HUNDRED, false, alice));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, IOrderBook.Funded.selector), 0);
        assertEq(_count(logs, IOrderBook.FundingFailed.selector), 0);
    }

    /*//////////////////////////////////////////////////////////////
                    SEC-11: negative free delta
    //////////////////////////////////////////////////////////////*/

    /// @dev Stands up a source whose dry-plan `need` is positive AND whose `free` falls during `fund`.
    ///      `need` is the dry plan's consumed collateral minus `free` (OrderBook.sol `_preFund`), so the source parks
    ///      HALF a share on the ledger -- enough to make `free` non-zero and therefore drainable, not enough to make
    ///      `need` zero -- and then withdraws exactly that half inside `fund`.
    function _drainingSource() internal returns (SelfDrainingSource src) {
        src = new SelfDrainingSource(IClearinghouse(address(ch)));
        src.setFundable(10 * ONE_SHARE);
        src.setOperator(address(book), true);
        nvda.mint(address(src), 10 * ONE_SHARE);
        src.approveClearinghouse(address(nvda));
        vm.prank(address(src));
        ch.deposit(address(nvda), ONE_SHARE / 2, address(src));
        src.setDrain(ONE_SHARE / 2);
        vm.prank(admin);
        book.setFundingAllowed(address(src), true);
        vm.prank(address(src));
        book.setFunding(true);
    }

    /// @notice SEC-11. A funding source that lowers its own `free` must not revert the take.
    /// @dev PROVE BY BREAKING: with the raw `_ch.free(b.account, asset) - before` restored, `take` reverts with
    ///      panic 0x11 (arithmetic underflow) and the honest maker's 100 units are lost with it, so every assertion
    ///      below is unreachable. The saturating delta is the only reason this test can run at all.
    function test_preFund_sourceLowersItsOwnFree_takeSurvivesAndHonestMakerFills() public {
        SelfDrainingSource drainer = _drainingSource();
        FundingMaker honest = _source(10 * ONE_SHARE, 10 * ONE_SHARE);

        uint256 drainerId = _placeWrite(address(drainer), HUNDRED);
        uint256 honestId = _placeWrite(address(honest), HUNDRED);

        uint256 freeBefore = ch.free(address(drainer), address(nvda));
        assertEq(freeBefore, ONE_SHARE / 2, "drainer has drainable free, so its delta can go negative");

        vm.recordLogs();
        V2Types.TakeParams memory p = _buy(callId, _ids(drainerId, honestId), 200, alice);
        p.minUnits = 0;
        (uint64 filled,,) = _take(alice, p);

        assertEq(filled, HUNDRED, "the honest maker's fill survives the draining source");
        assertEq(ch.balanceOf(alice, callId), HUNDRED);
        assertEq(ch.balanceOf(address(honest), callId | 1), HUNDRED, "honest maker is short 100 units");
        assertEq(ch.balanceOf(address(drainer), callId | 1), 0, "the draining maker is skipped, not filled");
        assertEq(ch.free(address(drainer), address(nvda)), 0, "the drain really happened inside fund()");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, IOrderBook.Funded.selector), 2, "both funded makers report; neither reverts");
        assertEq(
            _count(logs, IOrderBook.FundingFailed.selector), 0, "fund() returned normally, so this is not a failure"
        );

        uint256 drainerDelivered = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(book) && logs[i].topics[0] == IOrderBook.Funded.selector
                    && address(uint160(uint256(logs[i].topics[1]))) == address(drainer)
            ) {
                (, drainerDelivered) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        assertEq(drainerDelivered, 0, "a net-negative delivery is reported as 0, not as an underflowed delta");
    }

    /*//////////////////////////////////////////////////////////////
                    T-SEC-P4: the funding seam's two edges
    //////////////////////////////////////////////////////////////*/

    /// @dev SEC-34. {quoteTake} plans with `assumeFunding = true` (OrderBook.sol:493) and budgets a funded maker its
    ///      source's `fundable` ANSWER; {take} pre-funds and then plans its executing round with `assumeFunding =
    ///      false` (OrderBook.sol:452), on what the source actually DELIVERED. `_preFund` saturates a short delivery
    ///      at 0 and never reverts, so the quote is an UPPER BOUND on a funded maker rather than the equality the
    ///      docs used to promise. This pins the gap itself: same parameters, same block, two different answers.
    function test_quoteTake_isAnUpperBound_whenTheSourceDeliversLessThanItAnswers() public {
        FundingMaker weak = _source(10 * ONE_SHARE, 10 * ONE_SHARE);
        weak.setMode(MockFundingSource.Mode.Partial);
        weak.setDeliverBps(0); // answers for ten shares, delivers none of them
        uint256 id = _placeWrite(address(weak), HUNDRED);
        V2Types.TakeParams memory p = _buy(callId, _ids(id), HUNDRED, alice);

        (uint64 quoted,,,) = book.quoteTake(p);
        (uint64 filled,,) = _take(alice, p);

        assertEq(quoted, HUNDRED, "the quote budgets the source's fundable answer");
        assertEq(filled, 0, "take fills on the delivery, and there was none");
        assertGt(quoted, filled, "quoteTake is an upper bound on a funded maker, not an equality");
    }

    /// @dev SEC-34, the other half. With an honest source the two agree, so the assertion above is measuring the
    ///      delivery gap and not some constant difference between the two paths.
    function test_quoteTake_equalsTake_whenTheSourceDeliversWhatItAnswers() public {
        FundingMaker honest = _source(10 * ONE_SHARE, 10 * ONE_SHARE);
        uint256 id = _placeWrite(address(honest), HUNDRED);
        V2Types.TakeParams memory p = _buy(callId, _ids(id), HUNDRED, alice);
        (uint64 quoted,,,) = book.quoteTake(p);
        (uint64 filled,,) = _take(alice, p);
        assertEq(quoted, filled, "an honest source closes the gap");
        assertEq(filled, HUNDRED);
    }

    /// @dev SEC-35. {setFunding} requires an answer to `fundable(usdg)` (OrderBook.sol:664); `_preFund` reads
    ///      `fundable(plan.collateralAsset)`, and a CALL collateralises in the UNDERLYING (OrderBook.sol:1084,
    ///      :1100). A source that answers only for USDG therefore passes the opt-in and contributes nothing to a
    ///      call series. The second half of this test is its positive control: the SAME source, once it answers for
    ///      the underlying too, funds and fills - so the first half is measuring the asset seam and not a broken
    ///      double.
    function test_setFunding_probesUsdg_whileACallSeriesAsksTheUnderlying() public {
        AssetPickySource src = new AssetPickySource(IClearinghouse(address(ch)));
        src.setAnswerFor(address(usdg), 10 * ONE_SHARE);
        src.setOperator(address(book), true);
        src.approveClearinghouse(address(nvda));
        nvda.mint(address(src), 10 * ONE_SHARE);

        vm.prank(admin);
        book.setFundingAllowed(address(src), true);
        vm.prank(address(src));
        book.setFunding(true); // the probe asks about USDG, and the source answers
        (, bool on) = book.fundingOf(address(src));
        assertTrue(on, "a USDG-only source passes the opt-in");

        uint256 id = _placeWrite(address(src), HUNDRED);
        vm.recordLogs();
        (uint64 filled,,) = _take(alice, _buy(callId, _ids(id), HUNDRED, alice));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(filled, 0, "the call series asks fundable(nvda), which this source answers 0");
        assertEq(_count(logs, IOrderBook.Funded.selector), 0, "no fund() call is made for a zero fundable answer");
        assertEq(_count(logs, IOrderBook.FundingFailed.selector), 0, "and it is not a failure either: it is silence");

        // POSITIVE CONTROL: the same source, the same order, now answering for the asset the series actually uses.
        src.setAnswerFor(address(nvda), 10 * ONE_SHARE);
        uint256 id2 = _placeWrite(address(src), HUNDRED);
        vm.recordLogs();
        (uint64 filled2,,) = _take(alice, _buy(callId, _ids(id2), HUNDRED, alice));
        assertEq(filled2, HUNDRED, "answering for the underlying is what makes the seam work");
        assertEq(_count(vm.getRecordedLogs(), IOrderBook.Funded.selector), 1, "and now it funds");
    }
}
