// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {OrderBookBaseTest} from "./OrderBookBase.t.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {OptionMath} from "../../../src/v2/lib/OptionMath.sol";

/// @notice The book's collateral budget after c05: a write-on-fill order needs its collateral AND the Clearinghouse's
///         mint rent, and the amount reserved is base unit for base unit what the mint will charge in that block
///         (v7 design §4.4, §6.2).
/// @dev WHY IT MATTERS. The book plans a take before it delivers it, and a planned AskWrite fill that cannot mint is
///      SKIPPED, not reverted (architecture §3.6). Before v7 the plan reserved `units x collateralPerUnit`; if the
///      Clearinghouse now wants rent on top, a maker holding exactly that much would be planned in, the mint would
///      revert InsufficientCollateral, and the delivery would be caught and skipped at execution -- the fill would
///      still not happen, but every unit after it in the same take would have been mis-planned and {quoteTake} would
///      have lied. Reserving collateral + rent keeps the plan exact.
///      THE FIXTURE keeps the base's markets at `mintFeePpm` 0 (design §3.8) and gives TSLA a rate of its own, so the
///      numbers every other OrderBook suite asserts do not move.
contract OrderBookMintFeeTest is OrderBookBaseTest {
    /// @dev The design's §5.1 launch rate for NVDA, carried here by TSLA so no other suite's numbers move.
    uint32 internal constant PPM = 80;
    uint128 internal constant RENT_STRIKE = 350_000_000;

    /// @dev TSLA 350 call, weekly FRI_2026_09_18, at PPM.
    uint256 internal rentCall;
    /// @dev A writer whose ledger holds exactly what a test gives it.
    address internal thin = makeAddr("thin");

    function setUp() public override {
        super.setUp();
        V2Types.MarketConfig memory cfg = _market();
        cfg.mintFeePpm = PPM;
        vm.prank(admin);
        _reconfigure(ch, address(tsla), cfg);
        rentCall = ch.createSeries(address(tsla), false, RENT_STRIKE, FRI_2026_09_18);

        _fund(thin, ACTOR_USDG, ACTOR_SHARES, ACTOR_SHARES);
        vm.startPrank(thin);
        usdg.approve(address(book), type(uint256).max);
        usdg.approve(address(ch), type(uint256).max);
        tsla.approve(address(ch), type(uint256).max);
        ch.setApprovalForAll(address(book), true);
        ch.setOperator(address(book), true);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                             THE BUDGET
    //////////////////////////////////////////////////////////////*/

    /// @notice A maker holding exactly `units x collateralPerUnit` is skipped; one base unit of rent headroom fills it.
    function test_askWrite_exactCollateralIsSkipped_collateralPlusRentFills() public {
        uint64 units = 100;
        uint256 collateral = uint256(units) * V2Constants.UNIT;
        uint256 fee = ch.mintFee(rentCall, units);
        assertGt(fee, 0, "the rate charges");

        _depositExactly(thin, address(tsla), collateral);
        uint256 ask = _place(thin, rentCall, WRITE, P2_50, units);
        (uint64 quoted,,,) = book.quoteTake(_buy(rentCall, _ids(ask), units, alice));
        assertEq(quoted, 0, "the quote already knows it cannot mint");
        (uint64 filled,,) = _take(alice, _buy(rentCall, _ids(ask), units, alice));
        assertEq(filled, 0, "collateral alone is not enough any more");
        assertEq(ch.balanceOf(alice, rentCall), 0, "nothing was delivered");
        assertFalse(_order(ask).cancelled, "and the order is untouched, not cancelled");

        _depositExactly(thin, address(tsla), collateral + fee);
        (quoted,,,) = book.quoteTake(_buy(rentCall, _ids(ask), units, alice));
        assertEq(quoted, units, "with rent headroom the quote fills");
        (filled,,) = _take(alice, _buy(rentCall, _ids(ask), units, alice));
        assertEq(filled, units, "and so does the take");
        assertEq(ch.free(thin, address(tsla)), 0, "collateral and rent both left the ledger");
        assertEq(ch.series(rentCall).mintFeesHeld, fee, "the series holds the rent the book budgeted");
    }

    /// @notice Two write-on-fill asks of one maker share ONE budget, rent included: the second is skipped when only
    ///         the first one's collateral plus rent is there.
    function test_askWrite_twoAsksOfOneMakerShareTheRentBudget() public {
        uint64 units = 100;
        uint256 collateral = uint256(units) * V2Constants.UNIT;
        uint256 fee = ch.mintFee(rentCall, units);

        // Enough for one fill and its rent, and one base unit short of two.
        _depositExactly(thin, address(tsla), 2 * collateral + 2 * fee - 1);
        uint256 a = _place(thin, rentCall, WRITE, P2_50, units);
        uint256 b = _place(thin, rentCall, WRITE, P2_50, units);
        (uint64 filled,,) = _take(alice, _buy(rentCall, _ids(a, b), 2 * units, alice));
        assertEq(filled, units, "one of the two fits, the other does not");

        // One more base unit and the second fits as well.
        _depositExactly(thin, address(tsla), collateral + fee);
        (filled,,) = _take(alice, _buy(rentCall, _ids(b), units, alice));
        assertEq(filled, units, "the second fills once the rent is covered");
        assertEq(ch.series(rentCall).mintFeesHeld, 2 * fee, "two mints, two rents");
    }

    /// @notice `writeToSell` budgets the TAKER's collateral plus rent, the same way.
    function test_writeToSell_budgetsTheTakersCollateralPlusRent() public {
        uint64 units = 100;
        uint256 collateral = uint256(units) * V2Constants.UNIT;
        uint256 fee = ch.mintFee(rentCall, units);
        uint256 bid = _place(alice, rentCall, BID, P2_00, units);

        _depositExactly(thin, address(tsla), collateral);
        (uint64 quoted,,,) = book.quoteTake(_sell(rentCall, _ids(bid), units, true, thin));
        assertEq(quoted, 0, "the taker cannot mint on collateral alone");
        (uint64 filled,,) = _take(thin, _sell(rentCall, _ids(bid), units, true, thin));
        assertEq(filled, 0, "and does not");

        _depositExactly(thin, address(tsla), collateral + fee);
        (filled,,) = _take(thin, _sell(rentCall, _ids(bid), units, true, thin));
        assertEq(filled, units, "with the rent it sells");
        assertEq(ch.free(thin, address(tsla)), 0, "both were taken");
        assertEq(ch.series(rentCall).mintFeesHeld, fee);
    }

    /// @notice The budget is per-unit exact: it fills the largest size the ledger can pay rent on, and no more.
    function testFuzz_askWrite_fillsExactlyWhatCollateralPlusRentAllows(uint64 units, uint96 extra) public {
        units = uint64(bound(units, 1, 500));
        uint256 collateral = uint256(units) * V2Constants.UNIT;
        uint256 fee = ch.mintFee(rentCall, units);
        // Between one base unit short of the rent and one base unit over it.
        uint256 deposit = collateral + bound(extra, 0, fee == 0 ? 1 : fee + 1);

        _depositExactly(thin, address(tsla), deposit);
        uint256 ask = _place(thin, rentCall, WRITE, P2_50, units);
        (uint64 filled,,) = _take(alice, _buy(rentCall, _ids(ask), units, alice));
        if (deposit >= collateral + fee) {
            assertEq(filled, units, "the whole ask fills once collateral and rent are covered");
            assertEq(ch.free(thin, address(tsla)), deposit - collateral - fee, "exactly both were taken");
        } else {
            assertEq(filled, 0, "a short budget skips the order whole, never part of it");
            assertEq(ch.free(thin, address(tsla)), deposit, "and nothing moved");
        }
    }

    /// @notice {quoteTake} and {take} agree on units, premium and taker fee once rent is in the budget.
    function test_quoteTake_matchesTakeWithRentInTheBudget() public {
        uint64 units = 250;
        uint256 collateral = uint256(units) * V2Constants.UNIT;
        // Two makers, one with rent headroom and one without, so the quote has to skip the right one.
        _depositExactly(thin, address(tsla), collateral + ch.mintFee(rentCall, units));
        uint256 good = _place(thin, rentCall, WRITE, P2_00, units);
        uint256 bad = _place(stranger, rentCall, WRITE, P2_00, units);

        V2Types.TakeParams memory p = _buy(rentCall, _ids(bad, good), 2 * units, alice);
        (uint64 qUnits, uint256 qPremium, uint256 qFee,) = book.quoteTake(p);
        (uint64 tUnits, uint256 tPremium, uint256 tFee) = _take(alice, p);
        assertEq(tUnits, qUnits, "units");
        assertEq(tPremium, qPremium, "premium");
        assertEq(tFee, qFee, "taker fee");
        assertEq(tUnits, units, "only the maker that can pay the rent filled");
    }

    /*//////////////////////////////////////////////////////////////
                       THE PREMIUM FEE IS SEPARATE
    //////////////////////////////////////////////////////////////*/

    /// @notice At the launch fee set (`premiumFeeBps` 0) a primary fill charges no seller fee, and `primary` is still
    ///         true: nothing about what the book calls a primary fill moved in v7, only what it costs.
    function test_premiumFeeZero_sellerFeeIsZeroAndPrimaryIsUnchanged() public {
        V2Types.FeeParams memory f = _defaultFees();
        f.premiumFeeBps = 0;
        vm.prank(admin);
        book.setFeeParams(f);
        vm.warp(block.timestamp + V2Constants.FEE_CHANGE_DELAY);
        assertEq(book.feeParams().premiumFeeBps, 0, "the launch premium fee");

        uint64 units = 100;
        _depositExactly(thin, address(tsla), uint256(units) * V2Constants.UNIT + ch.mintFee(rentCall, units));
        uint256 ask = _place(thin, rentCall, WRITE, P2_50, units);
        vm.recordLogs();
        _take(alice, _buy(rentCall, _ids(ask), units, alice));
        Filled memory filled = _decodeFilled(_filledLogs(vm.getRecordedLogs())[0]);
        assertEq(filled.sellerFee, 0, "no premium fee at launch");
        assertTrue(filled.primary, "it is still a primary fill");
        assertEq(filled.premium, _premium(P2_50, units), "and the premium is untouched");
    }

    /// @notice Conservation with rent: every base unit the writer's ledger loses is collateral plus the rent the
    ///         series now holds, and the USDG legs of the fill are what they always were.
    function test_conservation_ledgerLossIsCollateralPlusHeldRent() public {
        uint64 units = 300;
        uint256 collateral = uint256(units) * V2Constants.UNIT;
        uint256 fee = ch.mintFee(rentCall, units);
        _depositExactly(thin, address(tsla), collateral + fee + 12);

        uint256 heldBefore = ch.series(rentCall).mintFeesHeld;
        uint256 ask = _place(thin, rentCall, WRITE, P2_50, units);
        (, uint256 premium, uint256 takerFee) = _take(alice, _buy(rentCall, _ids(ask), units, alice));

        assertEq(ch.free(thin, address(tsla)), 12, "the ledger lost collateral + rent, and nothing else");
        assertEq(ch.locked(rentCall), collateral, "only the collateral is locked");
        assertEq(ch.series(rentCall).mintFeesHeld - heldBefore, fee, "the rent is held by the series");
        assertEq(premium, _premium(P2_50, units), "premium unchanged by v7");
        assertEq(takerFee, _takerFee(premium), "taker fee unchanged by v7");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Tops `who`'s ledger balance of `asset` up to exactly `amount`, withdrawing first when it is already above.
    function _depositExactly(address who, address asset, uint256 amount) internal {
        uint256 have = ch.free(who, asset);
        vm.startPrank(who);
        if (have > amount) ch.withdraw(asset, have - amount, who);
        else if (have < amount) ch.deposit(asset, amount - have, who);
        vm.stopPrank();
        assertEq(ch.free(who, asset), amount, "ledger set to exactly the amount under test");
    }
}
