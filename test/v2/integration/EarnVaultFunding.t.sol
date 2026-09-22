// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Test.sol";
import {EarnVaultTestBase} from "../unit/EarnVault.t.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {IOrderBook} from "../../../src/v2/interfaces/IOrderBook.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MockFundingSource} from "../../../src/v2/mocks/MockFundingSource.sol";
import {MockReentrantVenue} from "../../../src/v2/mocks/MockReentrantVenue.sol";

/// @dev MockFundingSource plus ERC-1155 receiver so the real Clearinghouse can mint shorts to it.
contract FundedPutMaker is MockFundingSource {
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

/// @notice P8-02 acceptance: the Earn vault is a funded maker through the REAL OrderBook pre-fund stage.
/// @dev One file, no shared test edited. Gas ceilings are read from {V2Constants}, never retyped.
///      MakerTestBase already calls `ch.setMinter(book)` (T-77); this suite does not weaken `mint()`.
contract EarnVaultFundingTest is EarnVaultTestBase {
    /// @dev 100 put units = 1 share. Put collateral is strike/100 per unit: 2_100_000 * 100 = 210e6 USDG.
    uint64 internal constant HUNDRED = 100;
    uint256 internal constant PUT_COLLATERAL = 210e6;

    function setUp() public override {
        super.setUp();
        // AC: call setMinter in this suite's setUp, not a DevDeploy-shaped chain (T-77).
        vm.prank(admin);
        ch.setMinter(address(book), true);
    }

    function _arm() internal {
        _setAdapter();
        _deposit(alice, DEP);
        _sweep(DEP);
        _enableFunding();
        vm.prank(admin);
        book.setFundingAllowed(address(earn), true);
        vm.prank(admin);
        earn.setBookFunding(true);
    }

    function _placeEarnWrite(uint64 units) internal returns (uint256 id) {
        vm.prank(quoter);
        id = earn.place(putId, WRITE, P2_00, units, 0);
    }

    function _buyPut(uint256[] memory ids, uint64 units) internal view returns (V2Types.TakeParams memory p) {
        p = _buy(putId, ids, units, type(uint128).max, alice);
        p.minUnits = 0;
    }

    function _aliceTake(V2Types.TakeParams memory p)
        internal
        returns (uint64 filled, uint256 premium, uint256 takerFee)
    {
        vm.prank(alice);
        return book.take(p);
    }

    function _count(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(book) && logs[i].topics[0] == topic) ++n;
        }
    }

    function _first(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(book) && logs[i].topics[0] == topic) return i;
        }
        revert("topic missing");
    }

    function _funded(Vm.Log[] memory logs)
        internal
        view
        returns (address maker, address asset, uint256 requested, uint256 delivered)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(book) && logs[i].topics[0] == IOrderBook.Funded.selector) {
                maker = address(uint160(uint256(logs[i].topics[1])));
                asset = address(uint160(uint256(logs[i].topics[2])));
                (requested, delivered) = abi.decode(logs[i].data, (uint256, uint256));
                return (maker, asset, requested, delivered);
            }
        }
        revert("Funded missing");
    }

    function _extraMaker(uint256 wallet) internal returns (FundedPutMaker src) {
        src = new FundedPutMaker(IClearinghouse(address(ch)));
        src.setFundable(wallet);
        src.setBook(address(book));
        src.approveClearinghouse(address(usdg));
        src.setOperator(address(book), true);
        usdg.mint(address(src), wallet);
        vm.prank(admin);
        book.setFundingAllowed(address(src), true);
        vm.prank(address(src));
        book.setFunding(true);
    }

    /*//////////////////////////////////////////////////////////////
                              OPT-IN
    //////////////////////////////////////////////////////////////*/

    function test_eoaCannotEnableFunding() public {
        vm.prank(admin);
        book.setFundingAllowed(alice, true);
        vm.prank(alice);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        book.setFunding(true);
    }

    function test_twoSidedOptIn_adminThenVault() public {
        _arm();
        (bool allowed, bool on) = book.fundingOf(address(earn));
        assertTrue(allowed);
        assertTrue(on);
        assertTrue(earn.fundingEnabled());
    }

    /*//////////////////////////////////////////////////////////////
                              HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_happyPath_FundedDeltaEqualsFreeAndBalancesMoved() public {
        _arm();
        uint256 id = _placeEarnWrite(HUNDRED);
        assertEq(ch.free(address(earn), address(usdg)), 0, "empty ledger before the take");

        uint256 aliceLongsBefore = ch.balanceOf(alice, putId);
        uint256 venueBefore = usdg.balanceOf(address(venue));
        uint256 walletBefore = usdg.balanceOf(address(earn));
        uint256 lockedBefore = ch.locked(putId);
        vm.recordLogs();
        uint256 beforeFree = ch.free(address(earn), address(usdg));
        (uint64 filled, uint256 premium,) = _aliceTake(_buyPut(_ids(id), HUNDRED));
        uint256 afterFree = ch.free(address(earn), address(usdg));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(filled, HUNDRED, "fill happened");
        assertGt(premium, 0);
        assertEq(ch.balanceOf(alice, putId) - aliceLongsBefore, HUNDRED, "longs moved, not a silent skip");

        (address maker, address asset, uint256 requested, uint256 delivered) = _funded(logs);
        assertEq(maker, address(earn));
        assertEq(asset, address(usdg));
        uint256 venueAfter = usdg.balanceOf(address(venue));
        uint256 lockedAfter = ch.locked(putId);
        // Book measures `delivered` as `free` delta inside `_preFund` (OrderBook.sol:876-878). The
        // AskWrite fill then locks that credit, so post-take `free` is unchanged. Fixture wallet
        // is empty after sweep, so the venue pull is that delta; writer premium later lands in
        // the vault wallet and must not be mixed in.
        assertEq(walletBefore, 0, "fixture swept; fund pulls from the venue");
        assertEq(venueBefore - venueAfter, delivered, "IFundingSource.sol:42-44: delivered is the free delta");
        assertEq(afterFree, beforeFree, "funded credit is consumed as write collateral");
        assertEq(lockedAfter, lockedBefore + PUT_COLLATERAL, "collateral actually locked");
        assertEq(requested, PUT_COLLATERAL, "need is the put collateral, not fundable");
        assertEq(delivered, PUT_COLLATERAL);
        assertEq(_count(logs, IOrderBook.FundingFailed.selector), 0);
        assertLt(_first(logs, IOrderBook.Funded.selector), _first(logs, IOrderBook.OrderFilled.selector));
    }

    function test_quoteTakeParity_sameBlock() public {
        _arm();
        uint256 id = _placeEarnWrite(HUNDRED);
        V2Types.TakeParams memory p = _buyPut(_ids(id), HUNDRED);
        (uint64 qUnits, uint256 qPrem, uint256 qFee, uint256 qSeller) = book.quoteTake(p);
        (uint64 tUnits, uint256 tPrem, uint256 tFee) = _aliceTake(p);
        assertEq(tUnits, qUnits, "IOrderBook.sol:138-139 units");
        assertEq(tPrem, qPrem, "premium");
        assertEq(tFee, qFee, "taker fee");
        assertEq(qSeller, 0, "buying");
        assertEq(tUnits, HUNDRED);
    }

    /*//////////////////////////////////////////////////////////////
                         FREEZE / UNDER-DELIVERY
    //////////////////////////////////////////////////////////////*/

    function test_venueFreeze_skipsVaultOthersFill_depositorsUnchanged() public {
        _arm();
        uint256 vaultId = _placeEarnWrite(HUNDRED);
        uint256 otherId = _place(carol, putId, WRITE, P2_00, HUNDRED);

        uint256 price = earn.convertToAssets(1e18);
        uint256 tvl = earn.totalAssets();
        uint256 aliceShares = earn.balanceOf(alice);

        venue.setFrozen(true);
        assertEq(earn.fundable(address(usdg)), 0);

        vm.recordLogs();
        (uint64 filled,,) = _aliceTake(_buyPut(_ids(vaultId, otherId), 200));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(filled, HUNDRED, "carol filled; vault skipped");
        assertEq(ch.balanceOf(alice, putId), HUNDRED);
        assertEq(earn.convertToAssets(1e18), price, "share price unchanged");
        assertEq(earn.totalAssets(), tvl);
        assertEq(earn.balanceOf(alice), aliceShares);
        assertEq(_count(logs, IOrderBook.Funded.selector), 0);
    }

    function test_underDelivery_takeDoesNotRevert_unfundableSkipped() public {
        _arm();
        venue.setWithdrawableCap(PUT_COLLATERAL / 2);
        uint256 vaultId = _placeEarnWrite(HUNDRED);
        uint256 otherId = _place(carol, putId, WRITE, P2_00, HUNDRED);

        (uint64 filled,,) = _aliceTake(_buyPut(_ids(vaultId, otherId), 200));
        assertEq(filled, HUNDRED, "half-fundable vault skipped; carol filled");
        assertEq(ch.balanceOf(alice, putId), HUNDRED);
    }

    /*//////////////////////////////////////////////////////////////
                                 GAS
    //////////////////////////////////////////////////////////////*/

    function test_fundableAndFund_underV2ConstantsCaps() public {
        _arm();
        uint256 g0 = gasleft();
        uint256 able = earn.fundable(address(usdg));
        uint256 fundableGas = g0 - gasleft();
        assertGt(able, 0);
        assertLt(fundableGas, V2Constants.FUNDABLE_READ_GAS);

        uint256 g1 = gasleft();
        vm.prank(address(book));
        earn.fund(address(usdg), PUT_COLLATERAL);
        uint256 fundGas = g1 - gasleft();
        assertLt(fundGas, V2Constants.FUNDING_GAS);
        assertEq(ch.free(address(earn), address(usdg)), PUT_COLLATERAL);
    }

    /*//////////////////////////////////////////////////////////////
                    MAX_FUNDED_MAKERS / REENTRANCY / LOSS
    //////////////////////////////////////////////////////////////*/

    function test_fifthFundedMaker_plannedWithoutFunding() public {
        _arm();
        uint256 vaultId = _placeEarnWrite(HUNDRED);
        uint256[4] memory extraIds;
        for (uint256 i; i < 4; ++i) {
            FundedPutMaker src = _extraMaker(1_000e6);
            vm.prank(address(src));
            extraIds[i] = book.place(putId, WRITE, P2_00, HUNDRED, 0);
        }
        uint256[] memory ids = new uint256[](5);
        ids[0] = extraIds[0];
        ids[1] = extraIds[1];
        ids[2] = extraIds[2];
        ids[3] = extraIds[3];
        ids[4] = vaultId;

        vm.recordLogs();
        (uint64 filled,,) = _aliceTake(_buyPut(ids, 500));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, IOrderBook.Funded.selector), 4, "V2Constants.MAX_FUNDED_MAKERS_PER_TAKE");
        assertEq(filled, 400, "fifth planned on free alone and skipped");
    }

    function test_reentrantVenue_bookGuardStopsPlaceCancelTake() public {
        MockReentrantVenue evil = new MockReentrantVenue(IERC20(address(usdg)));
        evil.setBook(address(book));
        vm.prank(admin);
        earn.setAdapter(address(evil));
        _deposit(alice, DEP);
        vm.prank(quoter);
        earn.sweepToVenue(DEP);
        _enableFunding();
        vm.prank(admin);
        book.setFundingAllowed(address(earn), true);
        vm.prank(admin);
        earn.setBookFunding(true);

        uint256 id = _placeEarnWrite(HUNDRED);
        evil.setReenterCalldata(abi.encodeCall(book.place, (putId, WRITE, P2_00, HUNDRED, uint40(0))));
        uint256 last = book.lastOrderId();
        vm.recordLogs();
        _aliceTake(_buyPut(_ids(id), HUNDRED));
        assertFalse(evil.lastReenterOk(), "place from inside fund stopped by the book guard");
        assertEq(book.lastOrderId(), last, "no extra order");

        evil.setReenterCalldata(abi.encodeCall(book.cancel, _ids(id)));
        uint256 id2 = _placeEarnWrite(HUNDRED);
        _aliceTake(_buyPut(_ids(id2), HUNDRED));
        assertFalse(evil.lastReenterOk(), "cancel from inside fund stopped");

        V2Types.TakeParams memory inner = _buyPut(_ids(id2), 1);
        evil.setReenterCalldata(abi.encodeCall(book.take, (inner)));
        uint256 id3 = _placeEarnWrite(HUNDRED);
        _aliceTake(_buyPut(_ids(id3), HUNDRED));
        assertFalse(evil.lastReenterOk(), "take from inside fund stopped");
    }

    function test_socialisedVenueLoss_onlySharePrice_lockedUntouched() public {
        _arm();
        uint256 bobShares = _deposit(bob, DEP);
        _sweep(usdg.balanceOf(address(earn)));

        uint256 locked = ch.locked(callId);
        uint256 carolUsdg = usdg.balanceOf(carol);
        uint256 carolFree = ch.free(carol, address(usdg));
        uint256 aliceShares = earn.balanceOf(alice);
        uint256 priceBefore = earn.convertToAssets(1e18);
        uint256 tvlBefore = earn.totalAssets();

        uint256 loss = 1_000e6;
        venue.loseAssets(loss);

        assertEq(ch.locked(callId), locked, "IFundingSource.sol:26-28 locked collateral never leaves");
        assertEq(usdg.balanceOf(carol), carolUsdg);
        assertEq(ch.free(carol, address(usdg)), carolFree);
        assertEq(earn.balanceOf(alice), aliceShares, "share balances unchanged");
        assertEq(earn.balanceOf(bob), bobShares);
        assertEq(earn.totalAssets(), tvlBefore - loss);
        assertLt(earn.convertToAssets(1e18), priceBefore, "loss is the share price");
    }

    function test_queuedWithdrawal_bearsLoss_servedDoNot() public {
        _arm();
        uint256 bobShares = _deposit(bob, DEP);
        _sweep(usdg.balanceOf(address(earn)));

        venue.setFrozen(true);
        vm.prank(bob);
        (uint256 paid, uint256 reqId) = earn.redeem(bobShares, bob);
        assertEq(paid, 0);
        assertGt(reqId, 0, "queued because the venue cannot pay");

        uint256 priceBefore = earn.convertToAssets(1e18);
        venue.setFrozen(false);
        uint256 loss = 2_000e6;
        venue.loseAssets(loss);
        assertLt(earn.convertToAssets(1e18), priceBefore, "queued and staying depositors share the loss");

        uint256 bobQueued = earn.request(reqId).shares;
        assertEq(bobQueued, bobShares, "queued shares still outstanding, priced at service");
        uint256 bobWallet = usdg.balanceOf(bob);
        earn.processQueue(1);
        uint256 bobGot = usdg.balanceOf(bob) - bobWallet;
        assertLt(bobGot, DEP, "queued bob is paid the post-loss share price, not the request-time amount");
        assertGt(earn.balanceOf(alice), 0, "alice was not served from the queue");
    }
}
