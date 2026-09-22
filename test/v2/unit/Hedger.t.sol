// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {V8AccessTest} from "../lib/V8Access.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";
import {Hedger} from "../../../src/v2/periphery/Hedger.sol";
import {StockLoanAdapter} from "../../../src/v2/periphery/lending/StockLoanAdapter.sol";
import {IHedger} from "../../../src/v2/interfaces/IHedger.sol";
import {IPayoutAdapter} from "../../../src/v2/interfaces/IPayoutAdapter.sol";
import {MarketParams} from "../../../src/v2/periphery/lending/MorphoDeps.sol";
import {IV4PoolManager, V4PoolKey, V4SwapParams} from "../../../src/v2/periphery/BuybackDeps.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {MockMorphoBlue, MockMorphoOracle} from "../../../src/v2/mocks/MockMorphoBlue.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";

contract MockSpot {
    bool public ok = true;
    uint256 public price = 100e6;
    uint256 public updatedAt;

    function set(bool ok_, uint256 price_, uint256 updatedAt_) external {
        ok = ok_;
        price = price_;
        updatedAt = updatedAt_;
    }

    function trySpot(address) external view returns (bool, uint256, uint256) {
        return (ok, price, updatedAt);
    }
}

contract MockPayout is IPayoutAdapter {
    MockERC20 public immutable dollar;

    constructor(MockERC20 dollar_) {
        dollar = dollar_;
    }

    function swapToUsdg(address asset, uint256 amountIn, uint256 minOut, address to) external returns (uint256 out) {
        IERC20(asset).transferFrom(msg.sender, address(this), amountIn);
        out = amountIn * 100e6 / 1e18;
        require(out >= minOut, "min");
        dollar.mint(to, out);
    }

    function routeFeeBps(address) external pure returns (uint16) {
        return 0;
    }
}

/// @notice The v4 lock and one exact-input USDG -> asset fill at a fixed price.
/// @dev F-CT2B-02 (ops/audit/CT2B-HEDGER.md). Until this row `swap` was declared `(bytes, bytes, bytes)`, which is
///      a DIFFERENT SELECTOR from the real `IV4PoolManager.swap(V4PoolKey, V4SwapParams, bytes)`, so
///      {V4Buy._onUnlock} died on dispatch with no returndata and NO TEST IN THIS FILE HAD EVER EXECUTED THE
///      UNWIND MONEY PATH. The signature here is mirrored from `src/v2/periphery/BuybackDeps.sol:36-38` and the
///      delta packing from `src/v2/periphery/v4/V4Types.sol:70-84`; neither is re-derived.
///
///      FILLING IS OPT-IN, and the default is off on purpose. A mock that always filled would silently change what
///      every pre-existing test in this file means: they assert that an unwind "still reverts" past a guard. With
///      `fill` false `swap` returns a zero delta, which {V4Buy._onUnlock} refuses at `V4Buy.sol:107` -- so those
///      calls still revert, on a guard now rather than on a missing selector.
contract MockV4Pm {
    MockERC20 public immutable dollar;
    MockERC20 public immutable stock;
    /// @dev USDG (6 dp) per 1e18 of stock -- the convention {MockSpot} and {MockPayout} already use.
    uint256 public price = 100e6;
    bool public fill;

    constructor(MockERC20 dollar_, MockERC20 stock_) {
        dollar = dollar_;
        stock = stock_;
    }

    function setFill(bool on) external {
        fill = on;
    }

    function setPrice(uint256 price_) external {
        price = price_;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return Hedger(msg.sender).unlockCallback(data);
    }

    /// @dev Exact input only: `amountSpecified` is negative and is the USDG sold. The return is v4-core's packed
    ///      `BalanceDelta` -- amount0 in the upper 128 bits, amount1 in the lower, each signed from the CALLER's
    ///      point of view, so the sold currency is negative and the bought one positive.
    function swap(V4PoolKey memory key, V4SwapParams memory params, bytes calldata) external view returns (int256) {
        if (!fill) return 0;
        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 out = amountIn * 1e18 / price;
        bool usdgIsZero = key.currency0 == address(dollar);
        int128 amt0 = usdgIsZero ? -int128(int256(amountIn)) : int128(int256(out));
        int128 amt1 = usdgIsZero ? int128(int256(out)) : -int128(int256(amountIn));
        return (int256(amt0) << 128) | int256(uint256(uint128(amt1)));
    }

    function sync(address) external {}

    function settle() external payable returns (uint256) {
        return 0;
    }

    /// @dev Pays the bought currency out of the mock's OWN balance, so the recipient delta {V4Buy._buyExactInput}
    ///      measures at `V4Buy.sol:76` is a real token movement and not an accounting fiction.
    function take(address currency, address to, uint256 amount) external {
        MockERC20(currency).transfer(to, amount);
    }
}

/// @notice A trading-week authority whose answer the test controls.
/// @dev Only {isRegularSession} matters to {Hedger}; the rest of {IExpiryCalendar} is present so the probe in
///      {Hedger.setCalendar} has a real surface to find, and absent behaviour is never exercised.
contract MockCalendar {
    bool public open = true;

    function setOpen(bool on) external {
        open = on;
    }

    function isRegularSession(uint40) external view returns (bool) {
        return open;
    }

    function isValidExpiry(uint40) external pure returns (bool) {
        return true;
    }

    function isWeekly(uint40) external pure returns (bool) {
        return true;
    }

    function nextExpiry(uint40 afterTs, bool) external pure returns (uint40) {
        return afterTs;
    }

    function newYorkOffset(uint40) external pure returns (int32) {
        return -18000;
    }
}

/// @notice A code-bearing interest-rate model placeholder.
/// @dev SEC-32 makes `setMarket` refuse a code-less `irm`, and the fixture previously passed `address(1)`. A real
///      Morpho market's IRM is always a contract, so this makes the fixture MORE faithful rather than working
///      around the new check -- which is the distinction worth keeping: the check found a fixture that could not
///      have existed on chain.
contract StubIrm {
    uint256 public rate;
}

/// @notice Code with no calendar surface, for the setter's probe.
contract NotACalendar {
    uint256 public unrelated = 1;
}

contract HedgerTest is V8AccessTest {
    address internal admin = makeAddr("admin");
    address internal quoter = makeAddr("quoter");
    /// @dev The Hedger's immutable single exit (F-CP-10): `withdraw` and `withdrawCollateral` pay here, nowhere else.
    address internal treasury = makeAddr("treasury");
    MockERC20 internal usdg;
    MockERC20 internal nvda;
    MockMorphoBlue internal morpho;
    MockMorphoOracle internal mOracle;
    MockSpot internal spot;
    MockPayout internal payout;
    MockV4Pm internal v4;
    Hedger internal hedger;

    uint256 internal constant BORROW = 1e18;
    uint256 internal constant COLL = 200e6;

    function setUp() public {
        vm.warp(30 days);
        _deployManager();
        usdg = new MockERC20("USDG", "USDG", 6);
        nvda = new MockERC20("NVDA", "NVDA", 18);
        morpho = new MockMorphoBlue();
        mOracle = new MockMorphoOracle();
        spot = new MockSpot();
        spot.set(true, 100e6, block.timestamp);
        payout = new MockPayout(usdg);
        v4 = new MockV4Pm(usdg, nvda);
        // T-265: the calendar is a constructor argument, so it is built BEFORE the Hedger rather than wired after.
        // The "unwired Hedger" state the old fixture worked around no longer exists -- the constructor refuses a
        // zero, codeless or non-answering calendar, so there is no window in which one can be built without one.
        // The unpranked `setCalendar` call that used to sit here is gone with the setter: it was a restricted
        // selector that `script/v2/roles.v8.json` never listed, so it fell to ADMIN (here, the test contract).
        // Removing the function removed that unmapped selector; see the WIRE-09 / BUG-05 F-05-02 finding.
        calendar = new MockCalendar();
        hedger = new Hedger(
            address(manager),
            address(usdg),
            address(v4),
            address(spot),
            address(payout),
            address(morpho),
            treasury,
            address(calendar)
        );
        irm = new StubIrm();
        _wire(address(hedger), "Hedger", admin, 0);
        _grant(V8Roles.TREASURY_ADMIN, admin, 0);
        _grant(V8Roles.CONFIG_ADMIN, admin, 0);
        _grant(V8Roles.GUARDIAN, admin, 0);
        _grant(V8Roles.QUOTER, quoter, 0);

        MarketParams memory m = MarketParams({
            loanToken: address(nvda),
            collateralToken: address(usdg),
            oracle: address(mOracle),
            irm: address(irm),
            lltv: 0.86e18
        });
        morpho.setMarket(m);
        nvda.mint(address(morpho), 1_000e18);
        vm.prank(admin);
        hedger.setStockLoanMarket(m);
        vm.prank(admin);
        hedger.setLimits(
            IHedger.Limits({
                maxBorrowPerAsset: 10e18,
                maxUsdgCollateral: 10_000e6,
                healthFactorFloorBps: 0,
                slippageBps: 500,
                maxDailyNotional: 10_000e6
            })
        );
        usdg.mint(admin, 1_000_000e6);
        vm.startPrank(admin);
        usdg.approve(address(hedger), type(uint256).max);
        hedger.fund(500_000e6);
        vm.stopPrank();
    }

    MockCalendar internal calendar;
    StubIrm internal irm;

    function _arm() internal {
        vm.prank(admin);
        hedger.setEnabled(address(nvda), true);
    }

    function test_hedgeRevertsWhileDisabled() public {
        vm.prank(quoter);
        vm.expectRevert(IHedger.Disabled.selector);
        hedger.hedge(address(nvda), BORROW, COLL, 90e6);
    }

    function test_eoaCannotEnable() public {
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        hedger.setEnabled(address(nvda), true);
    }

    /// @dev T-CV-HEDGER-AND-LEND: THIS TEST IS NAMED FOR THE WEEKEND BRAKE AND PROVES THE STALENESS BRAKE.
    ///      Its spot is `block.timestamp - 2 hours`, so `Hedger._requireFresh` refuses first and the calendar is
    ///      never consulted -- traced at -vvvv, `MockSpot::trySpot` then straight to `[Revert] WeekendBrake()`,
    ///      with no `isRegularSession` call in the trace. Both guards answer the same error one line apart
    ///      (`_requireFresh` then `_requireOpenSession` in {Hedger.hedge}), which is what makes the shadowing
    ///      invisible to `vm.expectRevert`.
    ///      NOT A COVERAGE GAP: {test_hedge_refusedOutsideTheRegularSessionEvenWithAFreshOracle} holds the spot
    ///      current and is where the session guard is actually proven. Left named as it is rather than renamed,
    ///      because the name is the only wrong thing here -- but do not cite THIS test as evidence that the
    ///      weekend brake works.
    function test_weekendBrakeWhileEnabled() public {
        _arm();
        spot.set(true, 100e6, block.timestamp - 2 hours);
        vm.prank(quoter);
        vm.expectRevert(IHedger.WeekendBrake.selector);
        hedger.hedge(address(nvda), BORROW, COLL, 90e6);
    }

    /// T-265, and this REPLACES `test_hedge_unwiredCalendarIsDistinguishableFromAClosedSession`.
    /// @dev THE STATE THAT TEST DISTINGUISHED NO LONGER EXISTS. It asserted that an UNWIRED calendar
    ///      ({V2Errors.NoSource}) and a CLOSED session ({IHedger.WeekendBrake}) fail differently, which mattered
    ///      while the pointer was settable and a Hedger could exist before anyone wired it. The pointer is now an
    ///      immutable the constructor refuses to leave empty, so "unwired" is unconstructible and a test for it
    ///      would be asserting against an unreachable state -- green forever, proving nothing.
    ///
    ///      WHAT REPLACES IT IS THE SAME PROTECTION, MOVED: the refusal is asserted where it now happens, at
    ///      construction. Deleting the constructor's probe makes THIS test fail, which is what the old test did
    ///      for the old design.
    function test_constructor_refusesACalendarItCannotUse() public {
        // ZERO: no code, so the code.length test catches it.
        vm.expectRevert(V2Errors.NoSource.selector);
        new Hedger(
            address(manager),
            address(usdg),
            address(v4),
            address(spot),
            address(payout),
            address(morpho),
            treasury,
            address(0)
        );

        // HAS CODE BUT IS NOT A CALENDAR: this is the case `code.length` alone would pass, which is why the
        // constructor probes `isRegularSession` the way Clearinghouse._requireSettlementOracle does (SEC-07).
        address notACalendar = address(new NotACalendar());
        assertGt(notACalendar.code.length, 0, "precondition: it has code, so a code.length check would pass it");
        vm.expectRevert(V2Errors.NoSource.selector);
        new Hedger(
            address(manager),
            address(usdg),
            address(v4),
            address(spot),
            address(payout),
            address(morpho),
            treasury,
            notACalendar
        );

        // CONTROL: a real calendar is accepted, so the probe is not simply refusing everything.
        MockCalendar good = new MockCalendar();
        Hedger fresh = new Hedger(
            address(manager),
            address(usdg),
            address(v4),
            address(spot),
            address(payout),
            address(morpho),
            treasury,
            address(good)
        );
        assertEq(address(fresh.calendar()), address(good), "the real calendar was accepted and pinned");
    }

    /// T-265: a closed session still refuses a new short, and still says WeekendBrake rather than NoSource.
    /// @dev The other half of what the deleted pair asserted. The two errors were the point of that test; one of
    ///      the two states is now unconstructible, so what survives is that the REACHABLE one keeps its own name.
    function test_hedge_closedSessionRevertsWeekendBrakeNotNoSource() public {
        MockCalendar closed = new MockCalendar();
        Hedger fresh = new Hedger(
            address(manager),
            address(usdg),
            address(v4),
            address(spot),
            address(payout),
            address(morpho),
            treasury,
            address(closed)
        );
        _wire(address(fresh), "Hedger", admin, 0);
        vm.prank(admin);
        fresh.setEnabled(address(nvda), true);
        closed.setOpen(false);

        vm.prank(quoter);
        vm.expectRevert(IHedger.WeekendBrake.selector);
        fresh.hedge(address(nvda), BORROW, COLL, 90e6);
    }

    /// T-265. `test_hedge_refusedUntilTheCalendarIsWired` was DELETED, not ported, and this comment is its record.
    /// @dev Its precondition was `assertEq(address(fresh.calendar()), address(0))`. That is now unreachable: the
    ///      constructor refuses a zero calendar, so no Hedger can exist with one and the assertion could only ever
    ///      be written against a contract that cannot be built. A test whose precondition is unconstructible is the
    ///      false-green shape this codebase keeps finding -- it would sit green and protect nothing. The guarantee
    ///      it stood for is asserted at its new home in {test_constructor_refusesACalendarItCannotUse}.

    /// D29: a fresh oracle is not enough -- the session must be open.
    /// @dev THE CASE `_requireFresh` COULD NOT SEE. The spot here is CURRENT, so the staleness brake passes; what
    ///      refuses is the calendar. Before D29 this hedge succeeded at 15:59 on a Friday.
    function test_hedge_refusedOutsideTheRegularSessionEvenWithAFreshOracle() public {
        _arm();
        spot.set(true, 100e6, block.timestamp);
        calendar.setOpen(false);

        vm.prank(quoter);
        vm.expectRevert(IHedger.WeekendBrake.selector);
        hedger.hedge(address(nvda), BORROW, COLL, 90e6);
    }

    /// THE EXIT IS NEVER GATED. A brake must not trap inventory (the rule is stated on {HouseVault.cancel}).
    /// @dev This is the control that matters most: a calendar rule that also blocked the exit would leave a
    ///      position stuck over a weekend, which is precisely when someone needs out.
    function test_closedSessionDoesNotBlockRepayOrUnwind() public {
        calendar.setOpen(false);

        // `repay` and `unwind` refuse for their OWN reasons (zero units, nothing borrowed) and never for
        // WeekendBrake -- that is the assertion. A session gate on the exit would surface here as WeekendBrake.
        vm.expectRevert(V2Errors.BadUnits.selector);
        hedger.repay(address(nvda), 0);

        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadUnits.selector);
        hedger.unwind(address(nvda), 0, 0, 3000, 60);
    }

    /// T-265. `test_setCalendar_refusesSomethingThatIsNotACalendar` was DELETED with the setter it tested.
    /// @dev Its three cases -- codeless, has-code-but-not-a-calendar, and a real calendar as the control -- were
    ///      not dropped: they moved verbatim in substance to {test_constructor_refusesACalendarItCannotUse}, which
    ///      asserts them where the refusal now happens. Recorded here so a reader looking for the probe's coverage
    ///      finds it rather than concluding it was lost.

    // SEC-33 HAS NO BEHAVIOURAL TEST IN THIS SUBMISSION AND THAT IS A STATED GAP, NOT AN OVERSIGHT.
    // I wrote one (fill the bucket, raise the cap, assert the next hedge is still refused) and could not get it
    // to isolate the bucket: `hedge` charges `maxBorrowPerAsset` and `maxUsdgCollateral` BEFORE
    // `_chargeNotional`, and both trip with the SAME `LimitExceeded` error, so a passing test would not have
    // proved which limit refused the call. A test that cannot tell which guard fired is the false-green shape
    // this board keeps finding, and shipping one would have been worse than shipping none.
    // WHAT IT NEEDS: either a bucket accessor to assert against directly, or limits set so that borrow and
    // collateral headroom are provably not the binding constraint at the moment of the second hedge. Both are
    // more than this row should carry. Recorded in the ledger as the launch-phase action.

    /// SEC-32: a market pointer that is merely non-zero is refused; it must bear code.
    function test_setMarket_refusesACodelessOracleOrIrm() public {
        MarketParams memory bad = MarketParams({
            loanToken: address(nvda),
            collateralToken: address(usdg),
            oracle: address(mOracle),
            irm: address(1),
            lltv: 0.86e18
        });
        vm.prank(admin);
        vm.expectRevert(V2Errors.NoSource.selector);
        hedger.setStockLoanMarket(bad);

        bad.irm = address(irm);
        bad.oracle = address(2);
        vm.prank(admin);
        vm.expectRevert(V2Errors.NoSource.selector);
        hedger.setStockLoanMarket(bad);

        // CONTROL: the fixture's own market, both pointers code-bearing, is still accepted.
        bad.oracle = address(mOracle);
        vm.prank(admin);
        hedger.setStockLoanMarket(bad);
    }

    function test_unwindAndRepayWhileDisabled() public {
        vm.expectRevert(V2Errors.BadUnits.selector);
        hedger.repay(address(nvda), 0);
    }

    function test_repayZeroReverts() public {
        vm.expectRevert(V2Errors.BadUnits.selector);
        hedger.repay(address(nvda), 0);
    }

    function test_maxBorrowTripsWhileEnabled() public {
        _arm();
        vm.prank(admin);
        hedger.setLimits(
            IHedger.Limits({
                maxBorrowPerAsset: uint128(BORROW - 1),
                maxUsdgCollateral: 10_000e6,
                healthFactorFloorBps: 1,
                slippageBps: 500,
                maxDailyNotional: 10_000e6
            })
        );
        vm.prank(quoter);
        vm.expectRevert(IHedger.LimitExceeded.selector);
        hedger.hedge(address(nvda), BORROW, COLL, 90e6);
    }

    function test_maxCollateralTripsWhileEnabled() public {
        _arm();
        vm.prank(admin);
        hedger.setLimits(
            IHedger.Limits({
                maxBorrowPerAsset: 10e18,
                maxUsdgCollateral: uint128(COLL - 1),
                healthFactorFloorBps: 1,
                slippageBps: 500,
                maxDailyNotional: 10_000e6
            })
        );
        vm.prank(quoter);
        vm.expectRevert(IHedger.LimitExceeded.selector);
        hedger.hedge(address(nvda), BORROW, COLL, 90e6);
    }

    function test_healthFactorFloorTripsWhileEnabled() public {
        _arm();
        mOracle.setPrice(1);
        vm.prank(admin);
        hedger.setLimits(
            IHedger.Limits({
                maxBorrowPerAsset: 10e18,
                maxUsdgCollateral: 10_000e6,
                healthFactorFloorBps: uint16(V2Constants.BPS),
                slippageBps: 500,
                maxDailyNotional: 10_000e6
            })
        );
        vm.prank(quoter);
        vm.expectRevert(IHedger.LimitExceeded.selector);
        hedger.hedge(address(nvda), BORROW, COLL, 95e6);
    }

    function test_slippageTripsWhileEnabled() public {
        _arm();
        vm.prank(quoter);
        vm.expectRevert(IHedger.Slippage.selector);
        hedger.hedge(address(nvda), BORROW, COLL, 1);
    }

    /// @dev T-512. THE TWO PATHS USED TO DISAGREE ABOUT A ZERO SPOT, and this pair is what pins that they no longer do.
    ///      `hedge` builds its slippage floor from the oracle spot (`expected` and `floor` in {Hedger.hedge}): at
    ///      px == 0 the floor is 0 and `minUsdgOut < 0` is unsatisfiable, so the slippage check runs and CANNOT
    ///      FAIL. `unwind` reads the same spot and refuses it outright (`if (px == 0) revert BadPrice()`, right after
    ///      its own `trySpot` in {Hedger.unwind}).
    ///      NOT REACHABLE THROUGH THE DEPLOYED ORACLE: {SettlementOracle._spot} answers SPOT_NO_SOURCE for a zero
    ///      price, and {SettlementOracle.trySpot} answers ok only for SPOT_OK. It is reachable through a double -
    ///      MockSpot below returns whatever `set` was given, as does MockSettlementOracle - which is exactly the
    ///      exposure worth pinning: a mock laxer than the contract it stands in for.
    ///      GREEN SINCE T-590 (a820a42b), which put the same `px == 0` refusal in {Hedger.hedge} BEFORE the floor is
    ///      computed. This test was written red as the proof that fix should carry; it is now what keeps the fix.
    ///      Do not delete that line from `hedge` as dead code on the grounds that the canonical oracle never returns
    ///      ok-with-zero: that unreachability is enforced by a different contract, not by anything in Hedger.
    ///      (Citations are by symbol, not line: the line numbers this note used to carry drifted when T-590 landed.)
    function test_T512_hedgeMustRefuseAZeroSpotTheWayUnwindDoes() public {
        _arm();
        spot.set(true, 0, block.timestamp); // ok and fresh, so {Hedger._requireFresh} passes: it never reads the price
        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadPrice.selector);
        hedger.hedge(address(nvda), BORROW, COLL, 1); // an unbounded minUsdgOut, which a zero floor admits
    }

    /// @dev T-512, the other half of the pair and the control that proves the disagreement is real rather than a
    ///      misreading of the fixture: the SAME zero spot, through `unwind`, is refused, and always has been.
    ///      If it ever goes red, the refusal has been dropped from `unwind` and the two paths disagree again - restore
    ///      it there rather than removing its twin from {Hedger.hedge} to make them match.
    function test_T512_unwindAlreadyRefusesTheSameZeroSpot() public {
        _arm();
        spot.set(true, 0, block.timestamp);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadPrice.selector);
        hedger.unwind(address(nvda), 100e6, 0, 3000, 60);
    }

    /// @dev SEC-33, THE BEHAVIOURAL TEST THAT ENTRY SHIPPED WITHOUT, written by T-CV-MAKERVAULT at the launch pass.
    ///      WHY IT WAS WITHDRAWN THEN AND CAN BE WRITTEN NOW. The T-SEC-P4-HEDGER-AND-LENDING ledger entry records
    ///      that its author wrote this test and pulled it: `hedge` charges `maxBorrowPerAsset` and
    ///      `maxUsdgCollateral` BEFORE `_chargeNotional`, and all three refuse with the same
    ///      {IHedger.LimitExceeded}, so a green test could not say WHICH guard fired. The entry named the two ways
    ///      out -- a bucket accessor, or limits proving the other two cannot bind. The accessor exists:
    ///      {Hedger.notional} returns the bucket itself, so this asserts on the bucket rather than on a revert and
    ///      the ambiguity does not arise.
    ///
    ///      THE PROPERTY. `setLimits` settles the bucket at the OLD cap before storing the new one ({Hedger.setLimits}
    ///      reads `_limits.maxDailyNotional` into `_refilled` and restamps `_notionalAt` BEFORE `_limits = next`
    ///      overwrites it). Without that pair, `_refilled` would price ALREADY-ELAPSED time at the NEW cap, so
    ///      raising `maxDailyNotional` would refill the bucket retroactively and CONFIG_ADMIN could clear its own
    ///      daily rate limit by raising the cap and lowering it again. A rate limit its own key can clear is not one.
    ///
    ///      THE NUMBERS ARE CHOSEN SO THE TWO BEHAVIOURS CANNOT AGREE. One hedge fills the bucket exactly
    ///      (`maxDailyNotional == COLL`, charge `COLL`). A quarter window later the cap is raised 8x. Settled at the
    ///      OLD cap the refill is `COLL * WINDOW/4`, leaving three quarters -- 150e6. Priced at the NEW cap it would
    ///      be `8 * COLL * WINDOW/4`, which exceeds the whole bucket, leaving 0. 150e6 and 0 are not a boundary
    ///      quibble; they are the whole limit and none of it.
    function test_SEC33_raisingTheCapDoesNotRefillAlreadyElapsedTimeAtTheNewRate() public {
        _arm();
        // EVERY OTHER LIMIT IS MADE UNABLE TO BIND, which is the whole reason this test can exist. The borrow and
        // collateral ceilings are set far above one hedge, and the health-factor floor is ZERO because
        // {MockMorphoOracle} prices this position at `healthFactorBps() == 0`: with a floor of 1 the call dies at
        // the `healthFactorFloorBps` check in {Hedger.hedge} with {IHedger.LimitExceeded} -- the SAME error the
        // notional bucket raises a few lines earlier. That is exactly the ambiguity the T-SEC-P4 entry withdrew
        // its own test over, and it is not hypothetical: it is what the first run of this test did.
        vm.prank(admin);
        hedger.setLimits(
            IHedger.Limits({
                maxBorrowPerAsset: 10e18,
                maxUsdgCollateral: 10_000e6,
                healthFactorFloorBps: 0,
                slippageBps: 500,
                maxDailyNotional: uint128(COLL)
            })
        );
        vm.prank(quoter);
        hedger.hedge(address(nvda), BORROW, COLL, 95e6);
        (uint256 usedAfterHedge,) = hedger.notional();
        assertEq(usedAfterHedge, COLL, "the hedge should fill the bucket exactly, or the rest of this proves nothing");

        uint256 quarter = hedger.OUTFLOW_WINDOW() / 4;
        vm.warp(block.timestamp + quarter);
        vm.prank(admin);
        hedger.setLimits(
            IHedger.Limits({
                maxBorrowPerAsset: 10e18,
                maxUsdgCollateral: 10_000e6,
                healthFactorFloorBps: 0,
                slippageBps: 500,
                maxDailyNotional: uint128(COLL * 8)
            })
        );

        (uint256 usedAfterRaise,) = hedger.notional();
        assertEq(
            usedAfterRaise,
            COLL * 3 / 4,
            "raising the cap re-priced already-elapsed time at the new rate: the bucket refilled retroactively"
        );
        // Stated separately because it is the half that matters: a zero here is the rate limit cleared outright,
        // and an exact-value assertion that happened to be satisfied by zero would read as a pass.
        assertGt(usedAfterRaise, 0, "the daily rate limit was cleared by a cap raise, which is the SEC-33 defect");
    }

    function test_dailyNotionalTripsWhileEnabled() public {
        _arm();
        vm.prank(admin);
        hedger.setLimits(
            IHedger.Limits({
                maxBorrowPerAsset: 10e18,
                maxUsdgCollateral: 10_000e6,
                healthFactorFloorBps: 1,
                slippageBps: 500,
                maxDailyNotional: uint128(COLL - 1)
            })
        );
        vm.prank(quoter);
        vm.expectRevert(IHedger.LimitExceeded.selector);
        hedger.hedge(address(nvda), BORROW, COLL, 90e6);
    }

    function test_borrowRevertLeavesNothing() public {
        MockERC20 other = new MockERC20("X", "X", 18);
        vm.prank(admin);
        hedger.setEnabled(address(other), true);
        MarketParams memory m = MarketParams({
            loanToken: address(other),
            collateralToken: address(usdg),
            oracle: address(mOracle),
            irm: address(irm),
            lltv: 0.86e18
        });
        vm.prank(admin);
        hedger.setStockLoanMarket(m);
        uint256 u0 = usdg.balanceOf(address(hedger));
        uint256 a0 = other.balanceOf(address(hedger));
        vm.prank(quoter);
        vm.expectRevert();
        hedger.hedge(address(other), BORROW, COLL, 95e6);
        assertEq(usdg.balanceOf(address(hedger)), u0, "PayoutRouter.sol:145");
        assertEq(other.balanceOf(address(hedger)), a0);
    }

    function test_hedgeHappyPathWhileEnabled() public {
        _arm();
        vm.prank(quoter);
        hedger.hedge(address(nvda), BORROW, COLL, 95e6);
        assertGt(hedger.loan().borrowed(address(nvda)), 0);
    }

    /// @dev Kept as it was: it never asserted anything about {unwind}, so T-OP-067 did not have to rewrite it.
    ///      The three-function rule under pause is {test_pause_freezesUnwindAndHedgeButNeverRepay} below.
    function test_pauseBlocksHedgeNotRepay() public {
        _arm();
        vm.prank(admin);
        hedger.pause(true);
        vm.prank(quoter);
        vm.expectRevert(IHedger.Paused.selector);
        hedger.hedge(address(nvda), BORROW, COLL, 95e6);
        vm.expectRevert(V2Errors.BadUnits.selector);
        hedger.repay(address(nvda), 0);
    }

    /*//////////////////////////////////////////////////////////////
        T-OP-067 -- PAUSE FREEZES EVERYTHING THAT SPENDS, AND NOTHING ELSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Owner ruling 2026-09-22 item 13: pause freezes everything. Under pause, with a real debt open and
    ///         the v4 fill armed so the exit COULD complete, {unwind} refuses {Paused}, {hedge} refuses {Paused},
    ///         and {repay} closes the debt with Stock Token from outside. Then the pause is lifted and the same
    ///         unwind runs to a closed debt, so the refusal above was the pause and not a broken exit.
    /// @dev THE OLD RULE, for the record: `paused` was "NEW shorts only" and {unwind} ignored it, so a paused
    ///      Hedger still let the QUOTER key spend USDG through the exit (T-553 ep3 suspicion 1). {repay} stays
    ///      open on purpose -- it spends nothing of the vault's and is the "a brake must never trap inventory"
    ///      escape hatch -- and this test PROVES it by executing one, not by asserting a zero-amount refusal.
    ///      RED before T-OP-067: the first `expectRevert(Paused)` on {unwind} sees the exit go through.
    function test_pause_freezesUnwindAndHedgeButNeverRepay() public {
        _openDebt();
        _armTheV4Fill();
        uint256 owed = hedger.loan().borrowed(address(nvda));
        uint256 usdgIn = 100e6;
        uint256 floor = _floorFor(usdgIn);
        uint256 hedgerUsdgBefore = usdg.balanceOf(address(hedger));

        vm.prank(admin);
        hedger.pause(true);

        vm.prank(quoter);
        vm.expectRevert(IHedger.Paused.selector);
        hedger.unwind(address(nvda), usdgIn, floor, 3000, 60);
        assertEq(usdg.balanceOf(address(hedger)), hedgerUsdgBefore, "a paused unwind moved USDG");
        assertEq(hedger.loan().borrowed(address(nvda)), owed, "a paused unwind touched the debt");

        vm.prank(quoter);
        vm.expectRevert(IHedger.Paused.selector);
        hedger.hedge(address(nvda), BORROW, COLL, 95e6);

        // The escape hatch, executed: half the debt repaid from outside while paused.
        uint256 half = owed / 2;
        nvda.mint(address(this), half);
        nvda.approve(address(hedger), half);
        hedger.repay(address(nvda), half);
        assertEq(hedger.loan().borrowed(address(nvda)), owed - half, "repay must work under pause");

        // Lifted: the same exit closes what is left, so the refusal above was the pause and nothing else.
        vm.prank(admin);
        hedger.pause(false);
        uint256 restIn = 50e6;
        uint256 restFloor = _floorFor(restIn);
        vm.expectEmit(address(hedger));
        emit IHedger.Unwound(address(nvda), restIn, owed - half);
        vm.prank(quoter);
        hedger.unwind(address(nvda), restIn, restFloor, 3000, 60);
        assertEq(hedger.loan().borrowed(address(nvda)), 0, "the exit did not close the debt once unpaused");
    }

    /// @dev The pause is checked FIRST in {unwind}, before the input guards, so a paused Hedger answers {Paused}
    ///      to every unwind and not only to well-formed ones -- a zero `usdgIn` under pause is {Paused}, not
    ///      {BadUnits}. Pins the order so a later reshuffle cannot make the freeze visible only past the guards.
    function test_pause_isTheFirstRefusalUnwindGives() public {
        vm.prank(admin);
        hedger.pause(true);
        vm.prank(quoter);
        vm.expectRevert(IHedger.Paused.selector);
        hedger.unwind(address(nvda), 0, 0, 3000, 60);
    }

    /// @notice T-OP-033. `enabled` is PER ASSET: with nvda the only enabled asset, hedge on another asset is
    ///         refused `Disabled()` and, in the SAME state, hedge on nvda goes all the way through.
    /// @dev THE HOLE THIS CLOSES (T-553 ep3, P2). Every earlier test either enabled nothing
    ///      ({test_hedgeRevertsWhileDisabled}) or enabled and hedged the SAME asset ({_arm} then nvda;
    ///      {test_borrowRevertLeavesNothing} enables `other` and hedges `other`), so a refactor that collapsed
    ///      `mapping(address => bool) enabled` to one `bool` would have left the whole suite green. This test
    ///      is the pin: under that collapse `_arm` sets the bool, `other` sails past the guard and reverts
    ///      LATER with `UnknownMarket(other)` instead of `Disabled()`, and the first expectRevert goes red.
    ///      The second half is what makes it a per-asset assertion rather than a re-run of the disabled test:
    ///      nvda SUCCEEDS here (the fixture is fully wired for it, exactly as in
    ///      {test_hedgeHappyPathWhileEnabled}), so the refusal above cannot be a global "everything is off".
    function test_enabledIsPerAsset_otherRefusedWhileNvdaHedges() public {
        _arm();
        MockERC20 other = new MockERC20("X", "X", 18);
        assertTrue(hedger.enabled(address(nvda)), "nvda is the one enabled asset");
        assertFalse(hedger.enabled(address(other)), "other was never enabled");

        vm.prank(quoter);
        vm.expectRevert(IHedger.Disabled.selector);
        hedger.hedge(address(other), BORROW, COLL, 95e6);

        vm.prank(quoter);
        hedger.hedge(address(nvda), BORROW, COLL, 95e6);
        assertGt(hedger.loan().borrowed(address(nvda)), 0, "nvda got past the guard and borrowed");
    }

    /// @notice T-OP-033, the disable direction. `setEnabled(nvda, false)` refuses nvda and does not touch an asset
    ///         enabled afterwards: that one gets PAST the `enabled` guard and fails later, by name.
    /// @dev `other` has no stock-loan market, so once past `Disabled()` it runs through freshness (MockSpot
    ///      answers for any asset), the open session, the limits and the slippage floor, and is refused at
    ///      {StockLoanAdapter.postCollateral} with `UnknownMarket(other)` -- a named error from a later line,
    ///      which is the proof that the `enabled` read was per asset. Under the single-bool collapse the
    ///      second `setEnabled` turns everything back on and the nvda call below does not revert at all.
    function test_enabledIsPerAsset_disablingNvdaLeavesALaterEnabledAssetAlone() public {
        _arm();
        vm.prank(admin);
        hedger.setEnabled(address(nvda), false);
        MockERC20 other = new MockERC20("X", "X", 18);
        vm.prank(admin);
        hedger.setEnabled(address(other), true);
        assertFalse(hedger.enabled(address(nvda)), "nvda is off again");
        assertTrue(hedger.enabled(address(other)), "other is on");

        vm.prank(quoter);
        vm.expectRevert(IHedger.Disabled.selector);
        hedger.hedge(address(nvda), BORROW, COLL, 95e6);

        vm.prank(quoter);
        vm.expectRevert(abi.encodeWithSelector(StockLoanAdapter.UnknownMarket.selector, address(other)));
        hedger.hedge(address(other), BORROW, COLL, 95e6);
    }

    /*//////////////////////////////////////////////////////////////
       F-CP-02 / F-CP-10 -- THE COLLATERAL EXIT AND THE SINGLE EXIT
    //////////////////////////////////////////////////////////////*/

    /// @dev F-CP-10. The recipient is NOT a parameter. Before this, `withdraw(uint256,address)` let any holder of a
    ///      delay-0 TREASURY_ADMIN hot key send the vault's USDG anywhere. Same shape as F-CP-01 on
    ///      Erc4626VenueAdapter, where a caller-supplied recipient on a money path WAS the vulnerability.
    function test_withdraw_paysOnlyTheImmutableTreasury() public {
        usdg.mint(address(hedger), 500e6);
        uint256 before = usdg.balanceOf(treasury);

        vm.prank(admin);
        hedger.withdraw(100e6);

        assertEq(usdg.balanceOf(treasury) - before, 100e6, "the exit did not land on the treasury");
        assertEq(hedger.treasury(), treasury, "the treasury is not the immutable one");
    }

    /// @dev F-CP-02. Without {withdrawCollateral} every USDG posted by {hedge} is locked forever: the adapter's own
    ///      withdrawCollateral is `onlyOwner` and the Hedger is its IMMUTABLE owner, so no other address can ever
    ///      call it and no role, delay or upgrade recovers the funds. This asserts the exit exists, that it moves
    ///      real collateral, and that it lands on the treasury rather than a caller-chosen address.
    ///      T-OP-069: THIS SCENARIO IS MOCK-SHAPED. It withdraws ALL the collateral while the debt is still open,
    ///      which the real Morpho Blue refuses (`"insufficient collateral"`); it passes only because the double's
    ///      LLTV check is off by default. Kept as the exit's existence proof; the honest ordering -- repay first,
    ///      then withdraw -- is {test_morpho_withdrawCollateralUnderADebtIsRefusedAndSucceedsOnceRepaid}.
    function test_withdrawCollateral_returnsLockedCollateralToTheTreasury() public {
        // Same happy path as test_hedgeHappyPathWhileEnabled, so the collateral posted here is real.
        _arm();
        vm.prank(quoter);
        hedger.hedge(address(nvda), BORROW, COLL, 95e6);

        uint256 posted = hedger.loan().collateral(address(nvda));
        assertGt(posted, 0, "no collateral was posted, so this proves nothing");
        uint256 before = usdg.balanceOf(treasury);

        vm.prank(admin);
        hedger.withdrawCollateral(address(nvda), posted);

        assertEq(usdg.balanceOf(treasury) - before, posted, "collateral did not reach the treasury");
        assertEq(hedger.loan().collateral(address(nvda)), 0, "collateral is still locked in the market");
    }

    /*//////////////////////////////////////////////////////////////
       F-CP-08 -- THE BORROW CEILING READ A DEBT THAT HAD STOPPED MOVING
    //////////////////////////////////////////////////////////////*/

    /// @dev F-CP-08, and this is the line it actually bit rather than the one the review named. Morpho only updates
    ///      `totalBorrowAssets` when something touches the market, so between touches every reader sees a debt that
    ///      is stale and therefore UNDERSTATED. `hedge` gates the new borrow on `loan.borrowed(asset) +
    ///      borrowAssets > maxBorrowPerAsset`, and that read runs FIRST, before anything has touched the market --
    ///      so the ceiling was too generous by exactly the unaccrued interest. It fails OPEN.
    ///
    ///      (The health-factor check further down was never the vulnerable read: `morpho.borrow` accrues on the way
    ///      through, so by the time it runs the totals have already moved. Worth saying, because the ledger entry
    ///      this task inherited frames F-CP-08 as a health-floor bug and a reader would otherwise look in the wrong
    ///      place.)
    ///
    ///      THE NUMBERS ARE CHOSEN TO STRADDLE THE CEILING, which is what makes this a test rather than a
    ///      demonstration: 1e18 already borrowed, 0.0864e18 of interest accrued over a day, a 2e18 ceiling and a
    ///      second borrow of 1e18. On the STALE debt that is 1e18 + 1e18 = 2e18, which is not above the ceiling and
    ///      would be allowed. On the ACCRUED debt it is 2.0864e18, which is. Delete the `loan.accrue(asset)` call
    ///      in `hedge` and this test stops reverting.
    function test_hedgeBorrowCeilingAccruesTheDebtFirst() public {
        _arm();
        vm.prank(quoter);
        hedger.hedge(address(nvda), BORROW, COLL, 95e6);

        // 1e12 per second for a day on 1e18 of debt: 1e18 * 1e12 * 86400 / 1e18 = 0.0864e18.
        morpho.setBorrowRatePerSecond(1e12);
        vm.warp(block.timestamp + 1 days);
        spot.set(true, 100e6, block.timestamp); // the warp made the oracle stale; `hedge` requires it fresh

        assertEq(
            hedger.loan().borrowed(address(nvda)),
            BORROW,
            "the STORED debt has not moved -- that understatement is the finding"
        );

        vm.prank(admin);
        hedger.setLimits(
            IHedger.Limits({
                maxBorrowPerAsset: 2e18,
                maxUsdgCollateral: 10_000e6,
                healthFactorFloorBps: 0,
                slippageBps: 500,
                maxDailyNotional: 10_000e6
            })
        );

        // The contract refuses on a debt LARGER than the one the view above just reported, which is only possible
        // because it accrued before it read.
        vm.prank(quoter);
        vm.expectRevert(IHedger.LimitExceeded.selector);
        hedger.hedge(address(nvda), BORROW, COLL, 95e6);
    }

    /// @dev The other half: with no interest outstanding the accrual changes nothing, so the fix cannot be passing
    ///      the test above by simply refusing every second hedge.
    function test_hedgeStillAllowedWhenNoInterestHasAccrued() public {
        _arm();
        vm.prank(quoter);
        hedger.hedge(address(nvda), BORROW, COLL, 95e6);

        vm.prank(admin);
        hedger.setLimits(
            IHedger.Limits({
                maxBorrowPerAsset: 2e18,
                maxUsdgCollateral: 10_000e6,
                healthFactorFloorBps: 0,
                slippageBps: 500,
                maxDailyNotional: 10_000e6
            })
        );

        vm.prank(quoter);
        hedger.hedge(address(nvda), BORROW, COLL, 95e6);
        assertEq(hedger.loan().borrowed(address(nvda)), 2 * BORROW, "both borrows stand");
    }

    /*//////////////////////////////////////////////////////////////
       F-CP-05 -- THE UNWIND FLOOR, WHICH FUNDS THE SWAP FROM OUR OWN BALANCE
    //////////////////////////////////////////////////////////////*/

    /// @dev The floor {unwind} applies, recomputed here from {hedge}'s OWN formula rather than from `unwind`'s.
    ///      {hedge} computes `expectedUsdg = assets * px / 1e18`. Inverting THAT, not re-deriving a second rule,
    ///      gives `expectedAsset = usdgIn * 1e18 / px`. Every assertion below is pinned to this function, so if the
    ///      contract ever uses a different scale the boundary tests stop straddling the revert and fail.
    function _expectedAssetOut(uint256 usdgIn) internal view returns (uint256) {
        (, uint256 px,) = spot.trySpot(address(nvda));
        return usdgIn * 1e18 / px;
    }

    /// @dev THE INVERSION IS EXACT, AND THIS IS THE ASSERTION THAT SAYS SO. claude-9 flagged in the T-173 ledger
    ///      that `unwind`'s floor inverts `hedge`'s formula and that the inversion had never been executed: if `px`
    ///      were not USDG-per-1e18-asset in the units assumed, the floor would be wrong by a scale factor and would
    ///      either block every unwind or permit a bad one. It round-trips: selling {BORROW} assets through `hedge`
    ///      expects exactly the USDG that, fed back through `unwind`, expects {BORROW} assets again. A scale error
    ///      in either direction breaks this equality, which is why it is asserted rather than reasoned about.
    function test_unwindFloorIsTheExactInverseOfTheHedgeFormula() public view {
        (, uint256 px,) = spot.trySpot(address(nvda));
        uint256 hedgeExpectsUsdg = BORROW * px / 1e18;
        assertEq(hedgeExpectsUsdg, 100e6, "the fixture's hedge leg is not the 100 USDG this test is written around");
        assertEq(
            _expectedAssetOut(hedgeExpectsUsdg), BORROW, "unwind's expected output is not hedge's input back again"
        );
    }

    /// @dev F-CP-05, THE HALF THAT MATTERS. {V4Buy._buyExactInput} now spends THIS CONTRACT'S USDG rather than
    ///      pulling it from `msg.sender`, so a caller-chosen route and a caller-chosen `minAssetOut` stopped risking
    ///      the role key's own money and started risking the vault's. One basis point below the floor must be
    ///      refused, by {IHedger.Slippage} specifically and not by some later accident of the mock.
    function test_unwindRefusesAMinAssetOutBelowTheOracleFloor() public {
        _arm();
        uint256 usdgIn = 100e6;
        uint256 floor = _expectedAssetOut(usdgIn) * (V2Constants.BPS - 500) / V2Constants.BPS;

        vm.prank(quoter);
        vm.expectRevert(IHedger.Slippage.selector);
        hedger.unwind(address(nvda), usdgIn, floor - 1, 3000, 60);
    }

    /// @dev THE POSITIVE CONTROL FOR THE TEST ABOVE, and the reason that one is load-bearing: a floor that rejected
    ///      EVERY value would make the test above pass for the wrong reason and look identical to a correct one.
    ///      At exactly the floor the guard must let the call THROUGH.
    ///
    ///      IT STILL REVERTS, and the assertion is about WHICH revert. {MockV4Pm} is left UNARMED here (`fill`
    ///      false), so its zero delta is refused at `V4Buy.sol:107` and the call dies below this guard -- which is
    ///      why this asserts on the absence of {IHedger.Slippage} rather than naming a downstream error. Before
    ///      F-CT2B-02 the mock's `swap` did not even carry v4's real signature, so the call died on dispatch with
    ///      `unrecognized function selector 0xf3cd914c` and no returndata; the assertion shape survives both.
    ///
    ///      NO LONGER TRUE, AND KEPT HERE SO THE CHANGE IS VISIBLE: this file used to have no executable unwind
    ///      happy path at all. It has one now -- test_unwind_roundTripThroughTheV4Lock -- which arms the mock.
    function test_unwindAtExactlyTheFloorPassesTheSlippageGuard() public {
        _arm();
        uint256 usdgIn = 100e6;
        uint256 floor = _expectedAssetOut(usdgIn) * (V2Constants.BPS - 500) / V2Constants.BPS;

        vm.prank(quoter);
        (bool ok, bytes memory ret) =
            address(hedger).call(abi.encodeCall(IHedger.unwind, (address(nvda), usdgIn, floor, 3000, 60)));

        assertFalse(ok, "the v4 mock is unarmed here, so this call must still revert");
        assertTrue(
            ret.length < 4 || bytes4(ret) != IHedger.Slippage.selector,
            "the slippage floor rejected a minAssetOut that was AT the floor"
        );
    }

    /// @dev T-OP-066 REVERSED THE DECISION THIS TEST USED TO PIN. It read: "the floor needs a usable spot, so
    ///      {unwind} now calls `_requireFresh` and a weekend or stale oracle BLOCKS UNWINDING" -- and that was
    ///      SEC-21c: the Chainlink feed is 24/5, so every weekend exit was refused on raw age while the Morpho
    ///      liquidation of the same position waited for nobody. The floor needs an ACCURATE spot, not a YOUNG
    ///      one, and since T-OP-061 `trySpot`'s `ok` says exactly that (thirty minutes, or corroborated by the
    ///      live pool). So an old print the oracle still stands behind lets the exit through to its next guard.
    ///      With `minAssetOut` 0 that guard is the slippage floor, and the assertion is that THAT is what
    ///      refuses -- not WeekendBrake. {test_unwind_completesOnAWeekendWhenThePoolCorroboratesTheOldPrint}
    ///      is the end-to-end half.
    function test_unwind_isNotBlockedByAnOldSpotTheOracleStandsBehind() public {
        _arm();
        spot.set(true, 100e6, block.timestamp - 2 hours);

        vm.prank(quoter);
        vm.expectRevert(IHedger.Slippage.selector);
        hedger.unwind(address(nvda), 100e6, 0, 3000, 60);
    }

    /*//////////////////////////////////////////////////////////////
          T-OP-066 / SEC-21c -- THE WEEKEND: EXITS NEED ACCURACY, NOT YOUTH
    //////////////////////////////////////////////////////////////*/

    /// @dev A weekend, modelled the way the real oracle presents one after T-OP-061: the last Chainlink print is
    ///      40 hours old (Friday close, read on Sunday), the calendar says the session is closed, and the
    ///      oracle's `trySpot` is OK because the market's live pool corroborates that print within the band.
    ///      {MockSpot} returns the oracle's VERDICT; the band arithmetic that produces it is the oracle's and is
    ///      pinned in `SettlementOracle.t.sol` (T-OP-061), not re-derived here.
    function _weekendWithTheOracleStandingBehindThePrint() internal {
        spot.set(true, 100e6, block.timestamp - 40 hours);
        calendar.setOpen(false);
    }

    /// @notice (i) The owner's question, answered by execution: on a weekend, with the pool agreeing, the exit
    ///         runs all the way through the v4 lock to a closed debt, and a NEW short is still refused.
    /// @dev Mirrors {test_unwind_roundTripThroughTheV4Lock} exactly, with the weekend laid over it after the debt
    ///      is opened. The `Unwound` event is the proof the path completed; the debt reading 0 is the proof it
    ///      did what it said. RED before T-OP-066: `WeekendBrake` at `_requireFresh`, no event, debt untouched.
    function test_unwind_completesOnAWeekendWhenThePoolCorroboratesTheOldPrint() public {
        _openDebt();
        _armTheV4Fill();
        _weekendWithTheOracleStandingBehindThePrint();

        // The brake on NEW risk holds: the print is older than `freshnessSeconds`, so opening is refused.
        vm.prank(quoter);
        vm.expectRevert(IHedger.WeekendBrake.selector);
        hedger.hedge(address(nvda), BORROW, COLL, 95e6);

        uint256 usdgIn = 100e6;
        uint256 floor = _floorFor(usdgIn);
        vm.expectEmit(address(hedger));
        emit IHedger.Unwound(address(nvda), usdgIn, BORROW);
        vm.prank(quoter);
        hedger.unwind(address(nvda), usdgIn, floor, 3000, 60);
        assertEq(hedger.loan().borrowed(address(nvda)), 0, "the weekend exit did not close the debt");
    }

    /// @notice (ii) The pool DISAGREES with the old print by more than the band, so the oracle no longer stands
    ///         behind it: the exit is refused, and it says so with the oracle's own error, not the brake's.
    /// @dev `trySpot` returns `(false, 0, 0)` from the real oracle in this state; the mock is set the same way so
    ///      the `StaleSpot(updatedAt)` argument is what a decoder would really see. Asserted by selector through
    ///      the raw call so the test can ALSO assert what it is not: not WeekendBrake, which is the new short's
    ///      refusal and must stay distinguishable from an exit's.
    function test_unwind_refusesByNameWhenThePoolDoesNotCorroborateTheOldPrint() public {
        _openDebt();
        _armTheV4Fill();
        spot.set(false, 0, 0);
        calendar.setOpen(false);

        (bool ok, bytes memory ret) = _tryUnwind(100e6, 0);
        assertFalse(ok, "an exit with no spot the oracle stands behind must not proceed");
        assertTrue(_revertIs(ret, V2Errors.StaleSpot.selector), "the exit's refusal must name the dead spot");
        assertFalse(_revertIs(ret, IHedger.WeekendBrake.selector), "and must not be mistaken for the brake");
        assertEq(hedger.loan().borrowed(address(nvda)), BORROW, "nothing moved");

        // The same verdict carrying a price and a timestamp -- the shape a source that "answers but does not
        // vouch" would produce -- is refused identically: `ok` is the rule, not the presence of a number. This is
        // the probe that catches an {unwind} that skipped the `ok` check and went to the floor on the number.
        spot.set(false, 100e6, block.timestamp - 40 hours);
        (ok, ret) = _tryUnwind(100e6, _floorFor(100e6));
        assertFalse(ok, "a spot the oracle does not vouch for must not price an exit, whatever number rides with it");
        assertTrue(_revertIs(ret, V2Errors.StaleSpot.selector), "refused by name, with the timestamp it returned");

        // And a NEW short in the same state is still the brake's refusal, so the two stay distinguishable.
        vm.prank(quoter);
        vm.expectRevert(IHedger.WeekendBrake.selector);
        hedger.hedge(address(nvda), BORROW, COLL, 95e6);
    }

    /// @dev THE SPLIT ITSELF, pinned from the setter's side: {freshnessSeconds} bounds {hedge} and nothing else.
    ///      At one second, a spot two minutes old refuses a new short and lets the exit through to its slippage
    ///      floor. A future change that re-routed {unwind} through `_requireFresh` reds here, on the exit half.
    function test_freshnessSeconds_boundsOnlyTheNewShort() public {
        _arm();
        vm.prank(admin);
        hedger.setFreshnessSeconds(1);
        spot.set(true, 100e6, block.timestamp - 2 minutes);

        vm.prank(quoter);
        vm.expectRevert(IHedger.WeekendBrake.selector);
        hedger.hedge(address(nvda), BORROW, COLL, 95e6);

        vm.prank(quoter);
        vm.expectRevert(IHedger.Slippage.selector);
        hedger.unwind(address(nvda), 100e6, 0, 3000, 60);
    }

    /*//////////////////////////////////////////////////////////////
       SEC-04 -- THE FOUR GUARDS unwind NEVER HAD
    //////////////////////////////////////////////////////////////*/

    /// @dev Opens a real short so the debt reads non-zero. {hedge} is the only path that creates one, and its
    ///      happy path is executable here because {MockPayout} fills; {MockV4Pm} is left unarmed by this helper,
    ///      which is why the unwind assertions below all stop at a guard rather than at a completed swap. The one
    ///      test that wants a completed swap arms it explicitly.
    function _openDebt() internal {
        _arm();
        vm.prank(quoter);
        hedger.hedge(address(nvda), BORROW, COLL, 95e6);
        assertGt(hedger.loan().borrowed(address(nvda)), 0, "fixture precondition: there must be a debt");
    }

    /// @dev The ceiling {unwind} now applies to `usdgIn`, recomputed here from the DEBT and the oracle rather than
    ///      copied from the contract: the debt's value at the worst price the contract will accept.
    function _maxUsdgIn() internal view returns (uint256) {
        (, uint256 px,) = spot.trySpot(address(nvda));
        uint256 owed = hedger.loan().borrowed(address(nvda));
        return (owed * px / 1e18) * V2Constants.BPS / (V2Constants.BPS - 500);
    }

    function _floorFor(uint256 usdgIn) internal view returns (uint256) {
        return _expectedAssetOut(usdgIn) * (V2Constants.BPS - 500) / V2Constants.BPS;
    }

    /// @dev Calls `unwind` and returns the raw revert data, so an assertion can say WHICH refusal happened without
    ///      needing the call to succeed. {MockV4Pm} is unarmed for these, so nothing below the guards is reached
    ///      and each assertion is about the guard it names rather than about the fill.
    function _tryUnwind(uint256 usdgIn, uint256 minAssetOut) internal returns (bool ok, bytes memory ret) {
        vm.prank(quoter);
        (ok, ret) = address(hedger).call(abi.encodeCall(IHedger.unwind, (address(nvda), usdgIn, minAssetOut, 3000, 60)));
    }

    function _revertIs(bytes memory ret, bytes4 sel) internal pure returns (bool) {
        return ret.length >= 4 && bytes4(ret) == sel;
    }

    /// @notice SEC-04 (1). `IHedger.NothingBorrowed` was declared and fired by NOTHING -- a guard designed and
    ///         dropped. Unwinding against no debt bought stock and called repay with nothing owed.
    function test_unwind_revertsNothingBorrowedWhenTheAdapterOwesNothing() public {
        _arm();
        assertEq(hedger.loan().borrowed(address(nvda)), 0, "precondition: no debt");
        // EVERY VALUE IS COMPUTED BEFORE THE CHEATCODES. `_floorFor` makes external calls, and an argument is
        // evaluated AFTER `vm.expectRevert` has armed -- so inlining it arms the expectation against `trySpot`,
        // which does not revert, and the test fails with "next call did not revert as expected" while the
        // contract is behaving correctly. Cost the first run of this file five failures.
        uint256 floor = _floorFor(100e6);

        vm.prank(quoter);
        vm.expectRevert(IHedger.NothingBorrowed.selector);
        hedger.unwind(address(nvda), 100e6, floor, 3000, 60);
    }

    /// @dev THE POSITIVE CONTROL for the test above, and the reason it is load-bearing. A guard that refused every
    ///      unwind would make that test pass identically. With a debt open, the SAME call must get past the debt
    ///      check -- it still reverts, because the v4 mock is unarmed here, and the assertion is about WHICH revert.
    function test_unwind_isPastTheDebtGuardOnceThereIsDebt() public {
        _openDebt();
        (bool ok, bytes memory ret) = _tryUnwind(100e6, _floorFor(100e6));
        assertFalse(ok, "the v4 mock is unarmed here, so this must still revert");
        assertFalse(_revertIs(ret, IHedger.NothingBorrowed.selector), "the debt guard fired although a debt exists");
    }

    /// @notice SEC-04 (2). `usdgIn` was unbounded, so a delay-0 QUOTER key could convert the whole USDG balance
    ///         into stock in one call. One wei above the debt's worst-price value is refused.
    function test_unwind_refusesMoreUsdgThanTheDebtCanPossiblyNeed() public {
        _openDebt();
        uint256 over = _maxUsdgIn() + 1;
        uint256 floor = _floorFor(over);

        vm.prank(quoter);
        vm.expectRevert(IHedger.LimitExceeded.selector);
        hedger.unwind(address(nvda), over, floor, 3000, 60);
    }

    /// @dev THE BOUNDARY CONTROL. A ceiling that rejected everything would pass the test above for the wrong
    ///      reason. AT the ceiling the call must get through the bound -- the gross-up exists precisely so a final
    ///      repayment at the worst acceptable price is still fundable.
    function test_unwind_allowsExactlyTheGrossedUpDebtValue() public {
        _openDebt();
        uint256 atCeiling = _maxUsdgIn();
        (bool ok, bytes memory ret) = _tryUnwind(atCeiling, _floorFor(atCeiling));
        assertFalse(ok, "the v4 mock is unarmed here, so this must still revert");
        assertFalse(_revertIs(ret, IHedger.LimitExceeded.selector), "the ceiling rejected a usdgIn that was AT it");
    }

    /// @notice SEC-04 (3). The daily notional bucket metered {hedge} and not {unwind}, so the rate limit could be
    ///         walked around by doing the volume through the unwind side.
    function test_unwind_chargesTheSameDailyNotionalBucketAsHedge() public {
        _openDebt();
        vm.prank(admin);
        hedger.setLimits(
            IHedger.Limits({
                maxBorrowPerAsset: 10e18,
                maxUsdgCollateral: 10_000e6,
                healthFactorFloorBps: 0,
                slippageBps: 500,
                maxDailyNotional: 1
            })
        );

        uint256 floor = _floorFor(100e6);

        vm.prank(quoter);
        vm.expectRevert(IHedger.LimitExceeded.selector);
        hedger.unwind(address(nvda), 100e6, floor, 3000, 60);
    }

    /// @dev THE CONTROL FOR THE BUCKET, and it is not the same assertion as the ceiling control above: this one
    ///      shows the SAME call passes when the bucket is wide, so the refusal above came from the bucket and not
    ///      from the `usdgIn` ceiling, which also raises LimitExceeded.
    function test_unwind_passesWhenTheNotionalBucketIsWide() public {
        _openDebt();
        (bool ok, bytes memory ret) = _tryUnwind(100e6, _floorFor(100e6));
        assertFalse(ok, "the v4 mock is unarmed here, so this must still revert");
        assertFalse(_revertIs(ret, IHedger.LimitExceeded.selector), "a wide bucket still refused the same call");
    }

    /// @notice SEC-04 (4), THE MECHANISM, proven on the path that CAN execute it. {StockLoanAdapter.repay} forwards
    ///         its amount to Morpho, which subtracts it from the position -- so repaying more than is owed reverts.
    ///         Before this row {unwind} passed the whole swap output straight through, so the final partial
    ///         repayment of a position could not be made. {unwind} now caps the repay at the outstanding debt.
    /// @dev THIS IS NOT A PROOF OF THE CAP ITSELF and must not be read as one. The cap sits BELOW the swap, and
    ///      this test never reaches it. What this proves is that the underflow the cap exists to avoid is real on
    ///      this fixture. The arithmetic is {MockMorphoBlue}'s, not Morpho's. The cap IS now reached by
    ///      test_unwind_roundTripThroughTheV4Lock, which repays a `got` larger than the debt.
    function test_repay_revertsWhenGivenMoreThanIsOwed() public {
        _openDebt();
        uint256 owed = hedger.loan().borrowed(address(nvda));
        nvda.mint(address(this), owed * 2);
        nvda.approve(address(hedger), type(uint256).max);

        vm.expectRevert();
        hedger.repay(address(nvda), owed + 1);

        // And the same call AT the debt succeeds, so the revert above is about the excess and not about the path.
        hedger.repay(address(nvda), owed);
        assertEq(hedger.loan().borrowed(address(nvda)), 0, "the debt did not close");
    }

    /*//////////////////////////////////////////////////////////////
          F-CT2B-02 -- THE MONEY PATH, EXECUTED END TO END
    //////////////////////////////////////////////////////////////*/

    /// @dev Arms {MockV4Pm} to fill at the fixture's spot and gives it the stock it will have to hand over. The
    ///      mock pays `take` out of its own balance, so without this the swap cannot settle.
    function _armTheV4Fill() internal {
        v4.setFill(true);
        nvda.mint(address(v4), 100e18);
    }

    /// @notice T-551. THE DRIFT GUARD, and the reason it is a separate test rather than a comment.
    /// @dev THE SUSPICION THIS ROW WAS MINED FROM is already closed: it said `MockV4Pm.swap` did not carry v4's
    ///      real signature, so `_buyExactInput` died inside the mock at `unrecognized function selector
    ///      0xf3cd914c` and nothing below the slippage guard was ever executed. F-CT2B-02 fixed that and
    ///      {test_unwind_roundTripThroughTheV4Lock} below now runs the path end to end.
    ///
    ///      WHAT WAS STILL MISSING IS A RED THAT NAMES THE CAUSE. Restoring the old `(bytes,bytes,bytes)`
    ///      signature was measured on this row: the round-trip test DOES go red, but it reports
    ///      `log != expected log` -- the `vm.expectEmit` failing, because no `Unwound` event is reached. The real
    ///      cause, `unrecognized function selector 0xf3cd914c`, appears only at `-vvvv`. A future reader seeing
    ///      that message would look at the event, not at the mock's ABI.
    ///
    ///      THIS COMPARES THE TWO SELECTORS DIRECTLY, so the drift is named at the top line. It is mirrored from
    ///      the interface rather than re-derived: {IV4PoolManager.swap} in `src/v2/periphery/BuybackDeps.sol` is
    ///      the thing {V4Buy._onUnlock} actually dispatches to.
    function test_T551_theMockSwapSelectorMatchesTheRealV4Interface() public pure {
        assertEq(
            MockV4Pm.swap.selector,
            IV4PoolManager.swap.selector,
            "MockV4Pm.swap has drifted from IV4PoolManager.swap: the unwind money path dispatches to nothing and every assertion below the slippage guard is vacuous"
        );
    }

    /// @notice F-CT2B-02 (ops/audit/CT2B-HEDGER.md). NOTHING IN THIS REPOSITORY HAD EVER EXECUTED THIS MONEY PATH,
    ///         in any environment: the unit mock's `swap` carried a different selector from v4's, the fork suite
    ///         has never run, and the devnet deploys no Hedger. This is the first test that runs `hedge` and then
    ///         `unwind` all the way through the v4 lock -- swap, sync, settle, take -- to a closed debt.
    /// @dev THE NUMBERS ARE THE FIXTURE'S, NOT COPIED FROM THE CONTRACT: at a 100 USDG spot, hedging 1e18 NVDA
    ///      sells for 100e6 USDG, so unwinding with the same 100e6 buys exactly 1e18 NVDA back and closes the debt
    ///      to the wei. That is also what test_unwindFloorInvertsTheHedgeFormula asserts about the arithmetic; this
    ///      one asserts it about the tokens.
    function test_unwind_roundTripThroughTheV4Lock() public {
        _openDebt();
        _armTheV4Fill();
        uint256 owed = hedger.loan().borrowed(address(nvda));
        assertEq(owed, BORROW, "fixture precondition: the hedge leg owes exactly what it borrowed");

        uint256 usdgIn = 100e6;
        uint256 hedgerUsdgBefore = usdg.balanceOf(address(hedger));
        uint256 poolUsdgBefore = usdg.balanceOf(address(v4));
        // EVERY VALUE BEFORE THE CHEATCODES, per the note on
        // test_unwind_revertsNothingBorrowedWhenTheAdapterOwesNothing: `_floorFor` makes an external call, and an
        // argument is evaluated AFTER `vm.prank` has armed -- so inlining it spends the prank on {MockSpot} and
        // the unwind runs as the test contract, which reverts NotAuthorized. Cost this test its first run.
        uint256 floor = _floorFor(usdgIn);

        vm.expectEmit(address(hedger));
        emit IHedger.Unwound(address(nvda), usdgIn, BORROW);
        vm.prank(quoter);
        hedger.unwind(address(nvda), usdgIn, floor, 3000, 60);

        assertEq(hedger.loan().borrowed(address(nvda)), 0, "the debt did not close through the executed path");
        assertEq(usdg.balanceOf(address(hedger)) + usdgIn, hedgerUsdgBefore, "the Hedger paid other than usdgIn");
        assertEq(usdg.balanceOf(address(v4)) - poolUsdgBefore, usdgIn, "the pool was not settled the USDG it sold");
        assertEq(nvda.balanceOf(address(hedger)), 0, "the bought stock did not all go to the debt");
    }

    /// @dev THE CONTROL, and it is the whole reason the test above means anything: the SAME call with the mock
    ///      unarmed reverts, because a zero delta is refused at `V4Buy.sol:107`. So the round trip above passes
    ///      because the swap filled, not because the guards above it were removed. This is also the second of the
    ///      two layers F-CT2B-02 names -- repairing the selector alone would still have left the path unexecutable.
    function test_unwind_zeroDeltaFromThePoolIsRefused() public {
        _openDebt();
        uint256 usdgIn = 100e6;
        uint256 floor = _floorFor(usdgIn);

        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadUnits.selector);
        hedger.unwind(address(nvda), usdgIn, floor, 3000, 60);
    }

    /// @notice SEC-04, the compounding half. `setFreshnessSeconds` wrote straight to storage with no bound, so a
    ///         delay-0 key could make {_requireFresh} pass on any spot however old -- turning both oracle floors
    ///         into floors against a stale number.
    function test_setFreshnessSeconds_refusesAboveTheCompiledCeiling() public {
        uint256 ceil_ = hedger.FRESHNESS_CEIL();

        vm.prank(admin);
        vm.expectRevert(IHedger.CeilingExceeded.selector);
        hedger.setFreshnessSeconds(ceil_ + 1);
    }

    /// @dev The control: AT the ceiling it is accepted and actually stored, so the guard bounds rather than blocks.
    function test_setFreshnessSeconds_acceptsTheCeilingItself() public {
        uint256 ceil_ = hedger.FRESHNESS_CEIL();

        vm.prank(admin);
        hedger.setFreshnessSeconds(ceil_);
        assertEq(hedger.freshnessSeconds(), ceil_, "the ceiling value was not stored");
    }

    /// @dev Both new money paths are role-gated, not merely recipient-pinned.
    function test_bothExitsRefuseAStranger() public {
        usdg.mint(address(hedger), 500e6);
        vm.expectRevert();
        vm.prank(quoter);
        hedger.withdraw(1e6);

        vm.expectRevert();
        vm.prank(quoter);
        hedger.withdrawCollateral(address(nvda), 1e6);
    }
    /*//////////////////////////////////////////////////////////////
        T-OP-069 -- THE HEDGER UNDER A MORPHO REFUSAL (T-OP-049 item 2)
    //////////////////////////////////////////////////////////////*/

    /// @dev THE FIXTURE'S ORACLE PRICE IS UNREALISTIC AND THAT IS WHY THE MOCK NEVER REFUSED ANYTHING WITHOUT
    ///      ANYONE NOTICING. {MockMorphoOracle} defaults to 1e36, "1:1" in RAW units: 200e6 base units of USDG are
    ///      then worth 200e6 wei of NVDA, so the fixture's own happy path (borrow 1e18 against 200 USDG) is
    ///      UNHEALTHY by Morpho's rule by a factor of ~6e9, and `healthFactorFloorBps: 0` on the Hedger side lets
    ///      it through. A real price: the oracle answers loan-token units per collateral unit, 1e36-scaled; at
    ///      100 USDG per NVDA one base unit of USDG (1e-6) is 1e-8 NVDA = 1e10 wei, so the price is 1e10 x 1e36 =
    ///      1e46. At that price 200 USDG backs 2e18 NVDA before LLTV and 1.72e18 after 86 %, so the fixture's
    ///      1e18 borrow is healthy and the refusal below is the LLTV and nothing else.
    uint256 internal constant REAL_MORPHO_PRICE = 1e46;

    function _fixtureMarket() internal view returns (MarketParams memory) {
        return hedger.loan().market(address(nvda));
    }

    /// @dev Turns the double's LLTV rule on for the fixture market at a realistic price, and proves the fixture's
    ///      own happy path still clears it -- the control that makes every refusal below the LLTV's and not the
    ///      fixture's numbers.
    function _armWithRealLltv() internal {
        _arm();
        mOracle.setPrice(REAL_MORPHO_PRICE);
        morpho.setEnforceLltv(_fixtureMarket(), true);
    }

    /// @dev Every balance a refused hedge could strand or move, before and after, with the bucket.
    struct HedgeState {
        uint256 hedgerUsdg;
        uint256 hedgerNvda;
        uint256 collateral;
        uint256 borrowed;
        uint256 notionalUsed;
    }

    function _hedgeState() internal view returns (HedgeState memory h) {
        h.hedgerUsdg = usdg.balanceOf(address(hedger));
        h.hedgerNvda = nvda.balanceOf(address(hedger));
        h.collateral = hedger.loan().collateral(address(nvda));
        h.borrowed = hedger.loan().borrowed(address(nvda));
        (h.notionalUsed,) = hedger.notional();
    }

    function _assertNothingStranded(HedgeState memory before, string memory why) internal view {
        HedgeState memory after_ = _hedgeState();
        assertEq(after_.hedgerUsdg, before.hedgerUsdg, string.concat(why, ": USDG left the Hedger"));
        assertEq(after_.hedgerNvda, before.hedgerNvda, string.concat(why, ": stock arrived at the Hedger"));
        assertEq(after_.collateral, before.collateral, string.concat(why, ": collateral stranded in the market"));
        assertEq(after_.borrowed, before.borrowed, string.concat(why, ": a short was recorded"));
        assertEq(after_.notionalUsed, before.notionalUsed, string.concat(why, ": the notional bucket was charged"));
    }

    /// @notice CONTROL: with the LLTV rule ON at a real price the fixture's hedge still succeeds, so the refusals
    ///         below are the rule's and not an artefact of switching it on.
    function test_morpho_theFixtureHedgeIsHealthyUnderARealLltvCheck() public {
        _armWithRealLltv();
        vm.prank(quoter);
        hedger.hedge(address(nvda), BORROW, COLL, 95e6);
        assertEq(hedger.loan().borrowed(address(nvda)), BORROW, "the healthy hedge went through");
        // The adapter's own reading agrees with Morpho's rule: 200 USDG x 1e10 / 1e18-debt = 2.0x = 20_000 bps.
        assertEq(hedger.loan().healthFactorBps(address(nvda)), 20_000, "adapter and double disagree on health");
    }

    /// @notice Morpho refuses the borrow at the LLTV: nothing is stranded, no short is recorded, the bucket is
    ///         not charged, and the error is Morpho's own string. 1.8e18 against 200 USDG is over the 1.72e18 the
    ///         86 % LLTV allows and under the Hedger's own 10e18 `maxBorrowPerAsset`, so only Morpho can refuse it.
    /// @dev `postCollateral` runs BEFORE `borrow` inside {Hedger.hedge}, so the USDG is in the market when Morpho
    ///      refuses -- and the refusal reverts the whole call, which is the only reason it is not stranded. That
    ///      is the property under test: the Hedger does not catch the venue's refusal and carry on with the
    ///      collateral posted. RED ON THE OLD DOUBLE: the borrow succeeds and the first `expectRevert` fails.
    function test_morpho_hedgeRefusedAtTheLltvStrandsNothing() public {
        _armWithRealLltv();
        uint256 tooMuch = 1.8e18;
        HedgeState memory before = _hedgeState();
        // Read BEFORE the prank: `morpho.INSUFFICIENT_COLLATERAL()` is an external call, and an argument evaluated
        // after `vm.prank` is the call the prank binds to (the trap this suite documents on the round-trip test).
        bytes memory refusal = bytes(morpho.INSUFFICIENT_COLLATERAL());

        // 1.8e18 at 100 USDG is 180 USDG expected; 175 clears the 5 % floor so the Hedger's own guards stay quiet.
        vm.prank(quoter);
        vm.expectRevert(refusal);
        hedger.hedge(address(nvda), tooMuch, COLL, 175e6);

        _assertNothingStranded(before, "LLTV refusal");
    }

    /// @notice Morpho refuses the borrow for liquidity: the market has less to lend than the ask. Same three
    ///         assertions, Morpho's other string. The liquidity cap is set BELOW the fixture's borrow and the
    ///         position would be healthy, so only the liquidity rule can refuse it.
    function test_morpho_hedgeRefusedForLiquidityStrandsNothing() public {
        _armWithRealLltv();
        morpho.setLiquidity(_fixtureMarket(), uint128(BORROW / 2), true);
        HedgeState memory before = _hedgeState();
        bytes memory refusal = bytes(morpho.INSUFFICIENT_LIQUIDITY()); // before the prank, see above

        vm.prank(quoter);
        vm.expectRevert(refusal);
        hedger.hedge(address(nvda), BORROW, COLL, 95e6);

        _assertNothingStranded(before, "liquidity refusal");

        // And with the cap AT the borrow the same call clears, so the refusal above was the cap's.
        morpho.setLiquidity(_fixtureMarket(), uint128(BORROW), true);
        vm.prank(quoter);
        hedger.hedge(address(nvda), BORROW, COLL, 95e6);
        assertEq(hedger.loan().borrowed(address(nvda)), BORROW, "the funded borrow went through");
    }

    /// @notice THE THIRD SCENARIO THE ROW NAMED DOES NOT EXIST IN MORPHO BLUE, and this test says what does. A
    ///         `repay` is never refused for LLTV or liquidity -- it only makes the position healthier -- and the
    ///         one way it reverts, repaying MORE than is owed, is fenced off by {Hedger.unwind}'s SEC-04 (4) cap
    ///         (`pay = got > owed ? owed : got`), so the exit's repay leg cannot reach a Morpho refusal at all.
    ///         With BOTH rules on, a full round trip through the v4 lock still closes the debt and leaves the
    ///         position consistent; the over-repay shape is {test_repay_revertsWhenGivenMoreThanIsOwed}.
    function test_morpho_unwindRepayLegIsNeverRefusedWithBothRulesOn() public {
        _armWithRealLltv();
        morpho.setLiquidity(_fixtureMarket(), uint128(BORROW), true);
        vm.prank(quoter);
        hedger.hedge(address(nvda), BORROW, COLL, 95e6);
        _armTheV4Fill();

        uint256 usdgIn = 100e6;
        uint256 floor = _floorFor(usdgIn);
        vm.expectEmit(address(hedger));
        emit IHedger.Unwound(address(nvda), usdgIn, BORROW);
        vm.prank(quoter);
        hedger.unwind(address(nvda), usdgIn, floor, 3000, 60);

        assertEq(hedger.loan().borrowed(address(nvda)), 0, "the debt did not close under the refusal model");
        assertEq(hedger.loan().collateral(address(nvda)), COLL, "the collateral is still posted, untouched by the exit");
        assertEq(nvda.balanceOf(address(hedger)), 0, "bought stock did not all go to the debt");
    }

    /// @notice The exit the fixture's F-CP-02 test takes -- withdraw ALL collateral with the debt open -- is what
    ///         the real Morpho refuses, and the Hedger forwards the refusal unchanged (its NatSpec says the venue
    ///         enforces the health floor; here the venue finally does). Once the debt is repaid the same withdrawal
    ///         reaches the treasury.
    function test_morpho_withdrawCollateralUnderADebtIsRefusedAndSucceedsOnceRepaid() public {
        _armWithRealLltv();
        vm.prank(quoter);
        hedger.hedge(address(nvda), BORROW, COLL, 95e6);
        uint256 posted = hedger.loan().collateral(address(nvda));
        uint256 treasuryBefore = usdg.balanceOf(treasury);
        bytes memory refusal = bytes(morpho.INSUFFICIENT_COLLATERAL()); // before the prank, see above

        vm.prank(admin);
        vm.expectRevert(refusal);
        hedger.withdrawCollateral(address(nvda), posted);
        assertEq(hedger.loan().collateral(address(nvda)), posted, "a refused withdrawal moved collateral");
        assertEq(usdg.balanceOf(treasury), treasuryBefore, "a refused withdrawal paid the treasury");

        uint256 owed = hedger.loan().borrowed(address(nvda));
        nvda.mint(address(this), owed);
        nvda.approve(address(hedger), owed);
        hedger.repay(address(nvda), owed);

        vm.prank(admin);
        hedger.withdrawCollateral(address(nvda), posted);
        assertEq(usdg.balanceOf(treasury) - treasuryBefore, posted, "collateral did not reach the treasury once flat");
    }

}
