// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {StockLoanAdapter} from "../../../src/v2/periphery/lending/StockLoanAdapter.sol";
import {MarketParams, MorphoMarketId} from "../../../src/v2/periphery/lending/MorphoDeps.sol";
import {MockMorphoBlue, MockMorphoOracle} from "../../../src/v2/mocks/MockMorphoBlue.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";

/// @notice StockLoanAdapter + MorphoMarketId pin. Pinned-artifact exception: MorphoMarketId.id.
contract StockLoanAdapterTest is Test {
    MockERC20 internal usdg;
    MockERC20 internal nvda;
    MockMorphoOracle internal oracle;
    MockMorphoBlue internal morpho;
    StubIrm internal irm;
    StockLoanAdapter internal adapter;

    address internal hedger = makeAddr("hedger");
    address internal stranger = makeAddr("stranger");

    /// @dev 4663 Morpho Blue (recon:11,247). Tests/NatSpec only — never compiled into the adapter.
    address internal constant MORPHO_4663 = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;

    uint256 internal constant COLLATERAL = 10_000e6;
    uint256 internal constant BORROW = 1e18;

    function setUp() public {
        usdg = new MockERC20("USDG", "USDG", 6);
        nvda = new MockERC20("NVDA", "NVDA", 18);
        oracle = new MockMorphoOracle();
        morpho = new MockMorphoBlue();
        irm = new StubIrm();
        adapter = new StockLoanAdapter(address(morpho), address(usdg), hedger);

        nvda.mint(address(morpho), 1_000e18);
        usdg.mint(hedger, COLLATERAL * 10);
        nvda.mint(hedger, BORROW * 10);
        vm.startPrank(hedger);
        usdg.approve(address(adapter), type(uint256).max);
        nvda.approve(address(adapter), type(uint256).max);
        vm.stopPrank();
        assertTrue(MORPHO_4663 != address(0));
    }

    function _params() internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: address(nvda),
            collateralToken: address(usdg),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.86e18
        });
    }

    /*//////////////////////////////////////////////////////////////
                    PINNED: MorphoMarketId.id
    //////////////////////////////////////////////////////////////*/

    /// @dev Morpho Blue MarketParamsLib.id = keccak256 of the five static words. Must match abi.encode.
    function test_morphoMarketId_matchesAbiEncode() public view {
        MarketParams memory p = _params();
        bytes32 fromLib = MorphoMarketId.id(p);
        bytes32 fromEncode = keccak256(abi.encode(p));
        assertEq(fromLib, fromEncode, "MorphoMarketId.id != keccak256(abi.encode(MarketParams))");
    }

    function test_morphoMarketId_fiveWordLength() public pure {
        assertEq(MorphoMarketId.MARKET_PARAMS_BYTES_LENGTH, 5 * 32);
    }

    function test_morphoMarketId_changesWhenAnyFieldChanges() public view {
        MarketParams memory p = _params();
        bytes32 base = MorphoMarketId.id(p);
        p.lltv = 0.77e18;
        assertTrue(MorphoMarketId.id(p) != base);
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR / ACCESS
    //////////////////////////////////////////////////////////////*/

    function test_constructor_rejectsCodelessMorpho() public {
        vm.expectRevert(V2Errors.NoSource.selector);
        new StockLoanAdapter(makeAddr("noCode"), address(usdg), hedger);
    }

    function test_constructor_rejectsCodelessUsdg() public {
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        new StockLoanAdapter(address(morpho), makeAddr("noCode"), hedger);
    }

    function test_strangerCannotMutate() public {
        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        adapter.setMarket(_params());
    }

    /*//////////////////////////////////////////////////////////////
                              VIEWS
    //////////////////////////////////////////////////////////////*/

    function test_views_returnZeroWhenUnconfigured() public view {
        address unknown = address(0xabc);
        assertEq(adapter.healthFactorBps(unknown), 0);
        assertEq(adapter.borrowed(unknown), 0);
        assertEq(adapter.collateral(unknown), 0);
    }

    function test_borrowCycle_andHealthFactor() public {
        MarketParams memory p = _params();
        vm.startPrank(hedger);
        adapter.setMarket(p);
        adapter.postCollateral(address(nvda), COLLATERAL);
        adapter.borrow(address(nvda), BORROW, hedger);
        vm.stopPrank();

        assertEq(adapter.collateral(address(nvda)), COLLATERAL);
        assertEq(adapter.borrowed(address(nvda)), BORROW);
        // 10_000e6 USDG collateral valued at 2e18 NVDA-units (2x the 1e18 borrow).
        oracle.setPrice(2e18 * 1e36 / COLLATERAL);
        assertEq(adapter.healthFactorBps(address(nvda)), 2 * V2Constants.BPS);
        assertEq(nvda.balanceOf(hedger), BORROW * 10 + BORROW);

        vm.startPrank(hedger);
        adapter.repay(address(nvda), BORROW);
        adapter.withdrawCollateral(address(nvda), COLLATERAL, hedger);
        vm.stopPrank();
        assertEq(adapter.borrowed(address(nvda)), 0);
        assertEq(adapter.collateral(address(nvda)), 0);
    }

    /*//////////////////////////////////////////////////////////////
          T-OP-088 (T-OP-076 F-7): setMarket cannot re-pin over a position
    //////////////////////////////////////////////////////////////*/

    /// @dev The same asset on a DIFFERENT Morpho market: a fresh IRM changes the id and nothing else, which is
    ///      exactly the re-pin the finding describes (a config nudge, not a change of asset).
    function _otherMarket() internal returns (MarketParams memory p) {
        p = _params();
        p.irm = address(new StubIrm());
        assertTrue(MorphoMarketId.id(p) != MorphoMarketId.id(_params()), "premise: a different market id");
    }

    /// @dev Pins the fixture market and opens a position on it: collateral posted, `BORROW` borrowed.
    function _openPosition() internal {
        vm.startPrank(hedger);
        adapter.setMarket(_params());
        adapter.postCollateral(address(nvda), COLLATERAL);
        adapter.borrow(address(nvda), BORROW, hedger);
        vm.stopPrank();
    }

    /// @notice THE FINDING, refused by name. With collateral and debt on the pinned market, re-pinning the asset
    ///         to another market is refused with what is still there; the pointer, the views and the old
    ///         position are all exactly as they were. RED before T-OP-088: the pin moved and both views read 0.
    function test_setMarket_refusesToRepinOverAnOpenPosition() public {
        _openPosition();
        MarketParams memory other = _otherMarket();
        bytes32 before = MorphoMarketId.id(adapter.market(address(nvda)));

        vm.prank(hedger);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InsufficientCollateral.selector, 0, COLLATERAL));
        adapter.setMarket(other);

        assertEq(MorphoMarketId.id(adapter.market(address(nvda))), before, "the pointer moved");
        assertEq(adapter.collateral(address(nvda)), COLLATERAL, "the collateral view went blind");
        assertEq(adapter.borrowed(address(nvda)), BORROW, "the debt view went blind");
    }

    /// @notice The debt leg of the guard, on its own. Collateral withdrawn with the debt still open (possible
    ///         because the double's LLTV rule is off here, impossible on the real Morpho) is the state where the
    ///         first check passes and only the second can refuse -- and it names the debt in loan-token units.
    function test_setMarket_refusesToRepinOverABareDebt() public {
        _openPosition();
        vm.prank(hedger);
        adapter.withdrawCollateral(address(nvda), COLLATERAL, hedger);
        assertEq(adapter.collateral(address(nvda)), 0, "premise: no collateral left");
        assertEq(adapter.borrowed(address(nvda)), BORROW, "premise: the debt is still open");
        MarketParams memory other = _otherMarket();

        vm.prank(hedger);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InsufficientCollateral.selector, 0, BORROW));
        adapter.setMarket(other);
    }

    /// @notice Flat again -- repaid and withdrawn -- and the same re-pin goes through, with both ids in the event
    ///         and the pointer moved. This is the control that makes the refusal above the guard's and not a
    ///         broken setter.
    function test_setMarket_repinsOnceFlatAndNamesBothIds() public {
        _openPosition();
        vm.startPrank(hedger);
        adapter.repay(address(nvda), BORROW);
        adapter.withdrawCollateral(address(nvda), COLLATERAL, hedger);
        vm.stopPrank();
        MarketParams memory other = _otherMarket();
        bytes32 oldId = MorphoMarketId.id(_params());
        bytes32 newId = MorphoMarketId.id(other);

        vm.expectEmit(true, false, false, true, address(adapter));
        emit StockLoanAdapter.MarketRepinned(address(nvda), oldId, newId);
        vm.expectEmit(true, false, false, true, address(adapter));
        emit StockLoanAdapter.MarketSet(address(nvda), newId);
        vm.prank(hedger);
        adapter.setMarket(other);

        assertEq(MorphoMarketId.id(adapter.market(address(nvda))), newId, "the pointer did not move");
    }

    /// @notice Re-pinning the SAME market with a position open is allowed: nothing loses reach, so a
    ///         configuration script re-running its wiring is not refused. No `MarketRepinned` (nothing moved).
    function test_setMarket_samePinWithAPositionOpenIsNotAMove() public {
        _openPosition();
        vm.recordLogs();
        vm.prank(hedger);
        adapter.setMarket(_params());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != StockLoanAdapter.MarketRepinned.selector, "a same-id pin is not a move");
        }
        assertEq(adapter.collateral(address(nvda)), COLLATERAL, "the position is still in reach");
    }

    /// @notice The FIRST pin has nothing to leave, so it neither reads Morpho nor emits `MarketRepinned`.
    function test_setMarket_firstPinEmitsOnlyMarketSet() public {
        vm.recordLogs();
        vm.prank(hedger);
        adapter.setMarket(_params());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "exactly one event on a first pin");
        assertEq(logs[0].topics[0], StockLoanAdapter.MarketSet.selector, "and it is MarketSet");
    }
}

/// @notice A code-bearing interest-rate model placeholder.
/// @dev T-CV-OTHER-CONTRACTS epoch 4 (claude-824720) PROVED THIS REPAIR IS LOAD-BEARING rather than assuming it,
///      after a rebase moved it onto a base it was not written against. Restoring the code-less IRM
///      (`StubIrm(address(1))`) reproduces `[FAIL: NoSource()] test_borrowCycle_andHealthFactor`, exactly the
///      failure this repair exists to remove; restored byte-identical and the suite returns 8/8.
///
///      TWO LANES FOUND THIS INDEPENDENTLY AND THAT IS THE USEFUL PART. T-591 landed `baea30bd` with `StubIrm`
///      and `605d2789` (claude-894318, T-CV-OTHER-CONTRACTS epochs 2-3) landed the same repair with a `MockIrm`,
///      both tracing it to `StockLoanAdapter.sol:74` / `V2Errors.NoSource`, the SEC-32 guard added by `6e1d659f`
///      after this file was last touched. The rebase surfaced them as a conflict; the agreed resolution keeps
///      `StubIrm` because it already exists and carries a `rate` field, and drops the duplicate -- which rebased
///      to empty and dropped itself. Recorded so the next reader does not mistake a settled duplicate for a
///      disagreement.
/// @dev T-591, mirroring `StubIrm` at `test/v2/unit/Hedger.t.sol:149` rather than inventing a second name for
///      one idea. SEC-32 makes `StockLoanAdapter.setMarket` refuse a code-less `irm` (`StockLoanAdapter.sol:74`,
///      `V2Errors.NoSource`), and this fixture still passed `address(1)`. SEC-32 converted the two live sites in
///      `Hedger.t.sol` (:214, :598) and correctly left its negative control at :388 alone; this file one
///      directory over was never touched, so `test_borrowCycle_andHealthFactor` reverted in its FIRST statement
///      and the whole borrow cycle had not executed since `6e1d659f`.
///      The argument is Hedger's and it is the right one: a real Morpho market's IRM is always a contract, so
///      this makes the fixture MORE FAITHFUL rather than working around the new check. The check found a fixture
///      that could not have existed on chain.
contract StubIrm {
    uint256 public rate;
}
