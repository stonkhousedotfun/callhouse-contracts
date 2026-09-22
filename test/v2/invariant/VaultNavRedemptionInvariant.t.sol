// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {EarnVaultTestBase} from "../unit/EarnVault.t.sol";
import {HouseVaultTestBase} from "../unit/HouseVaultBase.t.sol";
import {EarnNavHandler} from "./EarnNavHandler.sol";
import {HouseNavHandler} from "./HouseNavHandler.sol";
import {Mock4626Vault} from "../../../src/v2/mocks/Mock4626Vault.sol";
import {StockVenueAdapter} from "../../../src/v2/periphery/earn/adapters/StockVenueAdapter.sol";
import {V2Ids} from "../../../src/v2/interfaces/V2Ids.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";

/// @notice THE PRE-T-241 ADAPTER, restored exactly, for the prove-by-breaking case.
/// @dev The three overrides below are the code that shipped before `9dcc9db3`, copied from
///      `git show 9dcc9db3^:src/v2/periphery/earn/adapters/StockVenueAdapter.sol:41-62` rather than
///      re-reasoned. `enabled` gated MEASUREMENT as well as the deposit, so one `setEnabled(false)` on a
///      funded adapter removed the venue balance from {EarnVault.totalAssets}.
///
///      THIS EXISTS ONLY TO BE FAILED AGAINST. It is a test contract; nothing in `src/` inherits it.
contract PreT241StockVenueAdapter is StockVenueAdapter {
    constructor(address authority_, address asset_, address venue_, address vault_)
        StockVenueAdapter(authority_, asset_, venue_, vault_)
    {}

    function withdrawable() public view override returns (uint256) {
        if (!enabled) return 0;
        return super.withdrawable();
    }

    function totalAssets() public view override returns (uint256) {
        if (!enabled) return 0;
        return super.totalAssets();
    }

    function _withdrawFromVenue(uint256 assets, address to) internal override returns (uint256) {
        if (!enabled) return 0;
        return super._withdrawFromVenue(assets, to);
    }
}

/// @notice Stateful invariant over the property NO EXISTING CAMPAIGN ASSERTS: a share redemption pays its
///         holder their pro-rata slice of the vault's ECONOMIC NAV, and pays it in both directions.
/// @dev WHY THIS ROW EXISTS. {V2Invariant} preserves the Clearinghouse identity exactly, and both SEC-02 and
///      SEC-19 preserved it too -- so an adapter flag that erased a funded venue from NAV, and a short the
///      vault never counted, were both invisible to every campaign on the board. HouseVault and EarnVault had
///      no campaign at all.
///
///      TWO-SIDED, AND THAT IS THE LOAD-BEARING WORD. The imported criterion asked for an upper bound, which
///      the pre-T-241 bug would have PASSED: a disabled adapter understated NAV, so the redeemer was
///      UNDERPAID, and underpayment never violates a ceiling. Both handlers therefore track a worst underpay
///      and a worst overpay, and both are asserted.
///
///      THE TOLERANCES, and why they are not zero. Share maths floor-divides, so an invariant that demanded
///      exactness would go red on arithmetic rather than on a defect -- and the third person to trip it would
///      disable it. Each tolerance is counted from the number of floor divisions between the pool and the
///      payment, and no wider:
///        - {EARN_TOLERANCE} = 2 base units. `owed = mulDiv(shares, totalAssets(), supply)` floors once
///          (`EarnVault.sol:316`) and {EarnNavHandler.economicNav} floors once more computing the expectation.
///        - {HOUSE_BATCH_TOLERANCE} = 8 base units. `rollEpoch` floors the USDG leg and the Stock leg
///          separately (`HouseVault.sol:520-540`), the handler converts the Stock leg to USDG at the boundary
///          price with one more floor, and the two conversion ORDERS differ by less than one base unit for any
///          price this campaign bounds (<= 1,000e6 USDG per 1e18 Stock). Three floors plus that difference is
///          under 4; 8 is one doubling of headroom so ordinary dust never reds.
///        - {HOUSE_CLAIM_TOLERANCE} = 4 base units: two floors in `claim` (`HouseVault.sol:436-437`) plus the
///          handler's conversion floor.
///      A defect large enough to matter is orders of magnitude outside these -- the pre-T-241 break below is
///      measured at 40% of the payment.
///
///      CONFIG mirrors {TreasuryExitInvariantTest}: the handlers bound every argument and swallow every
///      protocol refusal, so a revert reaching the fuzzer is a handler bug.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract VaultNavRedemptionInvariantTest is HouseVaultTestBase, EarnVaultTestBase {
    EarnNavHandler internal earnHandler;
    HouseNavHandler internal houseHandler;

    /// @dev A settlement price for the deterministic leg test below. Any value inside {HouseNavHandler}'s own
    ///      bound works; this one is the fixture's NVDA spot rounded to a whole dollar.
    uint256 internal constant BOUNDARY_PRICE = 230e6;

    uint256 internal constant EARN_TOLERANCE = 2;
    uint256 internal constant HOUSE_BATCH_TOLERANCE = 8;
    uint256 internal constant HOUSE_CLAIM_TOLERANCE = 4;

    /// @dev Both fixtures extend {MakerTestBase}, so this linearizes to one world with a HouseVault and an
    ///      EarnVault on the same Clearinghouse, book and oracle -- which is what the row asks for ("a campaign
    ///      covers HouseVault and EarnVault") and is cheaper than two campaigns that cannot interact.
    ///
    ///      NAMED BASE, NOT `super`. Both fixtures' `setUp` bodies start with `super.setUp()`, and in this
    ///      contract's linearization {EarnVaultTestBase}'s `super` IS {HouseVaultTestBase} -- so a bare
    ///      `super.setUp()` here would run the Maker world, then the House deploy, then the Earn deploy, and an
    ///      extra `_deployHouse()` after it would silently build a SECOND House vault that nothing targets.
    ///      Calling the House fixture's `setUp` (which chains to {MakerTestBase}) and then {_deployEarn}
    ///      directly says which world is being built, in what order, without depending on declaration order.
    function setUp() public override(HouseVaultTestBase, EarnVaultTestBase) {
        HouseVaultTestBase.setUp();
        _deployEarn();

        _setAdapter();

        earnHandler = new EarnNavHandler(earn, ch, IERC20(address(usdg)), venue, address(venue), quoter, [alice, bob]);
        earnHandler.trackSeries(callId);
        earnHandler.trackSeries(putId);
        // T-OP-036: the trader who fills the vault's own AskWrite, so the campaign can reach `isShort() == true`
        // through the vault's write path. `carol` is the taker the unit fixture uses (`EarnVault.t.sol:471`).
        earnHandler.setCounterparty(carol);
        vm.label(address(earnHandler), "EarnNavHandler");

        houseHandler = new HouseNavHandler(house, ch, oracle, splitterAddr, [depositorA, depositorB]);
        houseHandler.setQuoter(quoter);
        houseHandler.trackSeries(callId);
        houseHandler.trackSeries(putId);
        // T-OP-036: the maker on the other side of the vault's takes. `mm` is the writer the unit fixture uses
        // (`HouseVaultEpoch.t.sol:1142`); it is NOT a protocol account (`HouseVaultBase.t.sol:93-96`), so the
        // vault's self-deal refusal does not fire on it.
        houseHandler.setCounterparty(mm);
        vm.label(address(houseHandler), "HouseNavHandler");

        // A POOL TO REDEEM OUT OF. An invariant over redemptions whose vault is never funded asserts nothing:
        // every leg would return early and the campaign would be green because it did nothing. Seeded here so
        // the fuzzer starts from a state where all of it is reachable.
        _deposit(alice, DEP);
        _deposit(bob, DEP);
        _sweep(DEP / 2);

        targetContract(address(earnHandler));
        targetContract(address(houseHandler));

        // FIXTURE-ONLY SETTERS ARE NOT LEGS. `targetContract` exposes every external function, so without this the
        // fuzzer could call `setCounterparty(random)` / `setQuoter(random)` and starve the T-OP-036 legs (every
        // pranked place/take from an un-onboarded address is refused and swallowed), or push junk ids through
        // `trackSeries`. Neither reds the campaign; both quietly shrink what it reaches, which is the defect class
        // this row is about. `setQuoter` was exposed this way before this row and is fenced here for the same reason.
        bytes4[] memory earnSetters = new bytes4[](2);
        earnSetters[0] = EarnNavHandler.trackSeries.selector;
        earnSetters[1] = EarnNavHandler.setCounterparty.selector;
        excludeSelector(FuzzSelector({addr: address(earnHandler), selectors: earnSetters}));
        bytes4[] memory houseSetters = new bytes4[](3);
        houseSetters[0] = HouseNavHandler.trackSeries.selector;
        houseSetters[1] = HouseNavHandler.setQuoter.selector;
        houseSetters[2] = HouseNavHandler.setCounterparty.selector;
        excludeSelector(FuzzSelector({addr: address(houseHandler), selectors: houseSetters}));
    }

    /*//////////////////////////////////////////////////////////////
                                  EARN
    //////////////////////////////////////////////////////////////*/

    /// @notice A redeemer is paid their pro-rata slice of economic NAV -- not less, and not more.
    function invariant_earnRedemptionsPayProRataOfEconomicNav() public view {
        assertLe(earnHandler.worstUnderpay(), EARN_TOLERANCE, "a redeemer was paid less than their slice of NAV");
        assertLe(earnHandler.worstOverpay(), EARN_TOLERANCE, "a redeemer was paid more, diluting whoever stayed");
    }

    /// @notice The vault never prices while it is short something.
    /// @dev THE UNCOUNTED-SHORT HALF. While a series is written the collateral is locked and the pool's value
    ///      is not measurable, which is why T-184 queues instead of pricing. The counter is fed from a DIRECT
    ///      ledger read, so a short {EarnVault.hasOpenShort} cannot see still trips it.
    function invariant_earnNeverPricesWhileShort() public view {
        assertEq(earnHandler.pricedWhileShort(), 0, "the vault priced a deposit or a redemption while short");
    }

    /*//////////////////////////////////////////////////////////////
                                  HOUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Each boundary reserves the leavers their pro-rata slice of the post-fee pool, both directions.
    function invariant_houseBoundaryPricesWithdrawalsProRata() public view {
        assertLe(houseHandler.worstBatchUnderpay(), HOUSE_BATCH_TOLERANCE, "a withdrawal batch was underpaid");
        assertLe(houseHandler.worstBatchOverpay(), HOUSE_BATCH_TOLERANCE, "a withdrawal batch was overpaid");
    }

    /// @notice Each claimant receives their slice of the batch their request belonged to.
    function invariant_houseClaimsPaySliceOfTheirBatch() public view {
        assertLe(houseHandler.worstClaimUnderpay(), HOUSE_CLAIM_TOLERANCE, "a claimant was paid less than their slice");
        assertLe(houseHandler.worstClaimOverpay(), HOUSE_CLAIM_TOLERANCE, "a claimant was paid more than their slice");
    }

    /// @notice No boundary ever priced a vault that still held an option.
    /// @dev "Still held" is read AFTER the boundary: the boundary's own F10 step redeems settled balances before it
    ///      prices, which is the designed path and not a violation. See {HouseNavHandler.boundariesPricedWhileNotFlat}.
    function invariant_houseNeverPricesWhileHoldingAnOption() public view {
        assertEq(houseHandler.boundariesPricedWhileNotFlat(), 0, "a boundary valued a vault holding options");
    }

    /*//////////////////////////////////////////////////////////////
                             CAMPAIGN REACHED IT
    //////////////////////////////////////////////////////////////*/

    /// @notice The handlers' legs really reach the vaults and really move the counters the invariants read.
    /// @dev WITHOUT THIS THE SUITE IS A FALSE GREEN. Every invariant above is a `<=` or an `== 0` against a
    ///      counter that starts at zero, so handlers whose legs all returned early would pass while doing
    ///      nothing at all.
    ///
    ///      WHY IT IS A UNIT TEST AND NOT PART OF THE CAMPAIGN, stated because I tried both and both failed:
    ///        - as an `invariant_`, Foundry evaluates it ONCE BEFORE the first call sequence, so it fails at
    ///          `runs: 0, calls: 0` with "failed to set up invariant testing environment", always;
    ///        - as an `afterInvariant`, it runs after EVERY sequence, including the one-call sequence the
    ///          shrinker produces, and a one-call sequence legitimately redeems nothing.
    ///      Handler counters also reset between runs, so "did the campaign as a whole redeem anything" is not
    ///      a question the campaign can ask itself. It is asked here instead, deterministically, by driving
    ///      one full cycle through each handler and checking the counters moved.
    function test_theHandlerLegsReachBothVaultsAndMoveTheirCounters() public {
        earnHandler.deposit(0, 1_000e6);
        earnHandler.redeem(0, 5_000);
        assertGt(
            earnHandler.paidRedemptions() + earnHandler.queuedRedemptions(),
            0,
            "the Earn redeem leg never reached the vault"
        );

        // The House vault pays across a boundary, so the whole cycle is needed: queue, roll, claim the shares,
        // queue an exit, roll again, claim the payment.
        houseHandler.requestDeposit(0, true, DEP_USDG);
        houseHandler.rollEpoch(BOUNDARY_PRICE);
        houseHandler.claim(0);
        assertGt(house.balanceOf(depositorA), 0, "the deposit leg minted nothing");

        houseHandler.requestWithdraw(0, 10_000);
        houseHandler.rollEpoch(BOUNDARY_PRICE);
        houseHandler.claim(0);
        assertGt(houseHandler.boundariesPriced(), 0, "no House boundary ran");
        assertGt(houseHandler.claimsPaid(), 0, "no House claim paid");
    }

    /// @notice T-OP-036. The two "never prices while ..." invariants have a REACHABLE state to be false in, and the
    ///         guarded pricing paths were EVALUATED in that state.
    /// @dev THE DEFECT THIS FLOOR EXISTS FOR. {invariant_earnNeverPricesWhileShort} and
    ///      {invariant_houseNeverPricesWhileHoldingAnOption} each assert a counter is zero, and each counter is
    ///      gated on a state -- `isShort()`, `holdsAnOption()` -- that no leg of either handler could reach. Both
    ///      were green for the same reason a test with no assertion is green. This test drives the new legs and
    ///      asserts, SEPARATELY, that each state was observed true and that a pricing event was tried while it was
    ///      true. Reaching the state alone (forbidden fix (d)) proves the state, not the invariant's reach: a short
    ///      nobody deposits or redeems against was never priced against either.
    ///      ORDER MATTERS, and it is the fixture's timeline: the tracked series expire on the Friday the House
    ///      vault's SECOND epoch ends, so the House legs run first (inside epoch 2), then the Earn write, then the
    ///      Earn close -- which warps to expiry -- and finally the House boundary that must redeem the settled long.
    ///      The two invariants themselves are UNCHANGED; they are read here as the control that nothing priced
    ///      while short or non-flat during the sequence.
    function test_handlerLegsReachTheShortAndTheHeldOptionAndEvaluateThePricingPathsInThem() public {
        // ---- House, epoch 1 -> 2: a boundary rolls and the series enter the epoch ----------------------------
        houseHandler.requestDeposit(0, true, DEP_USDG);
        houseHandler.rollEpoch(BOUNDARY_PRICE);
        houseHandler.claim(0);
        assertGt(house.balanceOf(depositorA), 0, "precondition: the House vault has a shareholder and a pool");
        assertFalse(houseHandler.holdsAnOption(), "precondition: flat before the leg runs");

        // ---- House holds a long, sells it back, holds one again ------------------------------------------------
        houseHandler.takeALong(0, 10);
        assertEq(houseHandler.longsTaken(), 1, "the take leg did not put a long in the vault");
        assertTrue(houseHandler.holdsAnOption(), "holdsAnOption() must be TRUE after the vault's own take");

        houseHandler.sellTheLong(0, 10);
        assertEq(houseHandler.longsSold(), 1, "the resale leg did not take the long back out");
        assertFalse(houseHandler.holdsAnOption(), "flat again after the resale");

        houseHandler.takeALong(0, 10);
        assertEq(houseHandler.longsTaken(), 2);
        assertTrue(houseHandler.holdsAnOption());

        // A pricing event EVALUATED while holding: claim, then the boundary itself.
        uint256 houseEvalBefore = houseHandler.evaluatedWhileHolding();
        houseHandler.claim(0);
        assertEq(houseHandler.evaluatedWhileHolding(), houseEvalBefore + 1, "claim was not evaluated while holding");

        // ---- Earn goes short through its own AskWrite, and the guarded paths run while it is short --------------
        assertFalse(earnHandler.isShort(), "precondition: the Earn vault is flat");
        earnHandler.writeAnAsk(1, 100); // index 1 = putId, so the Earn short and the House long are different series
        assertEq(earnHandler.shortsWritten(), 1, "the write leg did not leave the vault short");
        assertTrue(earnHandler.isShort(), "isShort() must be TRUE after the vault's own write filled");
        assertTrue(earn.hasOpenShort(), "and the vault itself recorded it (the T-257 hook)");

        uint256 earnEvalBefore = earnHandler.evaluatedWhileShort();
        earnHandler.deposit(0, 1_000e6);
        earnHandler.redeem(1, 2_500);
        earnHandler.processQueue(4);
        assertEq(earnHandler.evaluatedWhileShort(), earnEvalBefore + 3, "three pricing paths evaluated while short");
        assertGt(earnHandler.shortObservations(), 0, "the short state was observed by a leg");
        // THE CONTROL: the unchanged invariant. The vault queued rather than priced, so nothing tripped.
        assertEq(earnHandler.pricedWhileShort(), 0, "the vault priced while short: the invariant's own subject");
        assertGt(earnHandler.queuedDeposits() + earnHandler.queuedRedemptions(), 0, "a short vault queues");

        // ---- The House boundary at expiry is EVALUATED while holding, and refused -----------------------------
        uint256 boundariesBefore = houseHandler.boundariesPriced();
        houseEvalBefore = houseHandler.evaluatedWhileHolding();
        houseHandler.rollEpoch(BOUNDARY_PRICE); // warps to the series' expiry; the vault still holds the long
        assertEq(
            houseHandler.evaluatedWhileHolding(), houseEvalBefore + 1, "the boundary was not evaluated while holding"
        );
        assertEq(houseHandler.boundariesPriced(), boundariesBefore, "an unsettled held long must refuse the boundary");
        assertEq(houseHandler.boundariesPricedWhileNotFlat(), 0, "the invariant's own subject stayed at zero");
        assertGt(houseHandler.optionObservations(), 0);

        // ---- Both vaults go flat the production way: settle, redeem -------------------------------------------
        houseHandler.settleTracked(0, BOUNDARY_PRICE);
        assertEq(houseHandler.seriesSettled(), 1, "the settle leg did not settle the held series");

        earnHandler.settleAndRedeemShort(1, BOUNDARY_PRICE);
        assertEq(earnHandler.shortsClosed(), 1, "the close leg did not redeem the vault's short");
        assertFalse(earnHandler.isShort(), "the Earn vault is flat again");

        // THE F10 PATH, AND THE REASON THE COUNTER IS A POST-READ. The vault enters this boundary holding a
        // SETTLED long; `_redeemSettled` redeems it at its real worth, `_requireFlat` passes, the boundary prices.
        // A pre-read of `holdsAnOption()` called exactly this a violation the first time it was ever reached.
        houseHandler.rollEpoch(BOUNDARY_PRICE);
        assertEq(houseHandler.boundariesPriced(), boundariesBefore + 1, "the boundary did not roll once settled");
        assertFalse(houseHandler.holdsAnOption(), "the House vault is flat again");
        assertEq(houseHandler.boundariesPricedWhileNotFlat(), 0, "and no boundary left an option behind");
    }
}

/// @notice PROVE BY BREAKING. The two defects the row names, reintroduced, with the campaign's own measurement
///         run against them -- and then the fixed code run through the identical checks.
/// @dev These are unit tests and not campaign legs on purpose: a fuzzer finding the break is luck, whereas
///      constructing it and watching the checker go red is proof that the checker CAN go red. A guard whose
///      failure has never been observed is a guard nobody has tested.
///
///      BOTH CASES USE {EarnNavHandler}'s MEASUREMENT, not a bespoke assertion written for the occasion. If
///      the handler's {economicNav} or {isShort} were blind to the defect, these tests would pass and the
///      break would be invisible -- which is exactly the failure being guarded against.
contract EarnNavProveByBreakingTest is EarnVaultTestBase {
    EarnNavHandler internal handler;
    Mock4626Vault internal erc4626;

    uint256 internal constant SWEPT = 4_000e6;

    function setUp() public override {
        super.setUp();
        erc4626 = new Mock4626Vault(IERC20(address(usdg)));
    }

    /*//////////////////////////////////////////////////////////////
                    BREAK 1: THE PRE-T-241 ADAPTER GATE
    //////////////////////////////////////////////////////////////*/

    /// @notice With the pre-T-241 gates restored, a redemption after `setEnabled(false)` underpays, and the
    ///         campaign's two-sided check SEES it.
    function test_breaking_preT241AdapterGateUnderpaysTheRedeemer() public {
        PreT241StockVenueAdapter broken =
            new PreT241StockVenueAdapter(address(manager), address(usdg), address(erc4626), address(earn));
        uint256 underpay = _redeemThroughAdapter(address(broken), true);
        // PRINTED, not just asserted. The magnitude is the evidence that this is the defect and not rounding,
        // and a later reader should not have to re-run the test to learn what it was.
        emit log_named_uint("pre-T-241 shortfall, USDG base units", underpay);

        assertGt(underpay, 2, "the restored gate must make the redeemer measurably short");
        // SIZE IT, do not just assert a direction: the venue balance is what vanished from NAV, so the
        // shortfall is the redeemed fraction of it. A one-wei "failure" would be rounding, not this defect.
        assertGt(underpay, SWEPT / 4, "the shortfall is the venue's whole balance, pro rata, not dust");
    }

    /// @notice THE SAME CHECK, THE SAME SEQUENCE, THE FIXED ADAPTER: green.
    /// @dev The control. Without it, break 1 proves only that the checker can fail, not that it passes on
    ///      correct code -- and a checker that always fails is as useless as one that never does.
    function test_control_shippedAdapterPaysTheRedeemerInFull() public {
        StockVenueAdapter fixed_ =
            new StockVenueAdapter(address(manager), address(usdg), address(erc4626), address(earn));
        uint256 underpay = _redeemThroughAdapter(address(fixed_), true);
        emit log_named_uint("shipped-adapter shortfall, USDG base units", underpay);
        assertLe(underpay, 2, "the shipped adapter must keep the redeemer whole");
    }

    /// @dev Deposit, sweep into the venue, optionally disable the adapter, then redeem half THROUGH THE
    ///      CAMPAIGN'S OWN HANDLER, and return the shortfall the handler measured. The handler's `books` are
    ///      pointed at the ERC-4626 itself -- the only depositor into it is the adapter -- so the measurement
    ///      is exactly the campaign's, and exactly what the adapter's gate cannot reach.
    function _redeemThroughAdapter(address adapterAddr, bool disableAfterFunding) private returns (uint256) {
        vm.prank(admin);
        earn.setAdapter(adapterAddr);
        StockVenueAdapter(adapterAddr).setEnabled(true);

        _deposit(alice, DEP);
        _sweep(SWEPT);
        assertGt(StockVenueAdapter(adapterAddr).totalAssets(), 0, "precondition: the venue is funded");

        if (disableAfterFunding) StockVenueAdapter(adapterAddr).setEnabled(false);

        handler = new EarnNavHandler(earn, ch, IERC20(address(usdg)), venue, address(erc4626), quoter, [alice, bob]);
        handler.redeem(0, 5_000); // alice redeems half
        assertGt(handler.paidRedemptions(), 0, "precondition: the redemption paid rather than queueing");

        return handler.worstUnderpay();
    }

    /*//////////////////////////////////////////////////////////////
              REGRESSION: A SHORT DELIVERED IN A BATCH IS COUNTED
    //////////////////////////////////////////////////////////////*/

    /// @notice T-257 REGRESSION. A short delivered by ERC-1155 BATCH is recorded, so {EarnVault.hasOpenShort}
    ///         sees it and the T-184 boundary queues the redemption instead of pricing it.
    /// @dev THIS WAS claude-25's BREAK CASE 2, PROMOTED. Until T-257 `onERC1155Received` recorded a short and
    ///      `onERC1155BatchReceived` did not, so a batch delivery left the vault short with
    ///      `hasOpenShort() == false` and T-184's whole boundary -- deposit, redeem and processQueue all key off
    ///      that one function -- opened again. It did not revert; it priced and paid, and was wrong.
    ///      IT IS NOW THE STANDING ASSERTION rather than a demonstration of the bug: the expectations below are
    ///      inverted from that break case, and {test_regression_singleDeliveredShortIsCountedAndTheVaultQueues}
    ///      keeps the single-transfer path as its CONTROL. A case that exercised only the batch path could not
    ///      show the asymmetry, and the asymmetry was the bug.
    ///      THE FIRST ASSERTION IS LOAD-BEARING AND IS NOT THERE FOR TIDINESS. Making the hook REVERT on a short
    ///      id would also make `hasOpenShort()` stop lying -- by refusing a legitimate transfer. `balanceOf > 0`
    ///      is what distinguishes "the vault recorded the short" from "the vault refused the batch", so this test
    ///      fails under that wrong fix instead of passing under both.
    function test_regression_batchDeliveredShortIsCountedAndTheVaultQueues() public {
        handler = new EarnNavHandler(earn, ch, IERC20(address(usdg)), venue, address(venue), quoter, [alice, bob]);
        handler.trackSeries(callId);

        _deposit(alice, DEP);
        uint256 shortId = _writeShortTo(address(earn), true);

        assertGt(ch.balanceOf(address(earn), shortId), 0, "the batch must DELIVER, not be refused: the vault is short");
        assertTrue(earn.hasOpenShort(), "a batch-delivered short must be recorded");
        assertTrue(handler.isShort(), "the campaign reads the ledger and sees the same short");

        handler.redeem(0, 5_000); // alice redeems half

        emit log_named_uint("redemptions the vault paid while really short", handler.paidRedemptions());
        emit log_named_uint("times the campaign's guard tripped", handler.pricedWhileShort());
        assertEq(handler.paidRedemptions(), 0, "a short vault must queue, not pay");
        assertEq(handler.pricedWhileShort(), 0, "nothing priced, so the guard stays quiet");
    }

    /// @notice THE CONTROL: the same short delivered one-by-one behaves IDENTICALLY. Both paths record, both
    ///         queue. That the two now agree is the regression; before T-257 they did not.
    function test_regression_singleDeliveredShortIsCountedAndTheVaultQueues() public {
        handler = new EarnNavHandler(earn, ch, IERC20(address(usdg)), venue, address(venue), quoter, [alice, bob]);
        handler.trackSeries(callId);

        _deposit(alice, DEP);
        uint256 shortId = _writeShortTo(address(earn), false);

        assertGt(ch.balanceOf(address(earn), shortId), 0, "the vault is short");
        assertTrue(earn.hasOpenShort(), "a single delivery is recorded");

        handler.redeem(0, 5_000);

        assertEq(handler.paidRedemptions(), 0, "a short vault must queue, not pay");
        assertEq(handler.pricedWhileShort(), 0, "nothing priced, so the guard stays quiet");
    }

    /// @dev `mm` writes the NVDA call and `carol` buys it, which mints the short to `mm`; `mm` then hands the
    ///      short to `to` either as a BATCH (the unrecorded path) or singly (the recorded one).
    function _writeShortTo(address to, bool viaBatch) private returns (uint256 shortId) {
        uint256 orderId = _place(mm, callId, WRITE, P2_50, 5);
        _take(carol, _buy(callId, _ids(orderId), 5, P2_50, carol));
        shortId = V2Ids.shortIdOf(callId);
        uint256 amount = ch.balanceOf(mm, shortId);
        assertGt(amount, 0, "precondition: the write filled and minted a short");

        vm.startPrank(mm);
        if (viaBatch) {
            uint256[] memory ids = new uint256[](1);
            uint256[] memory values = new uint256[](1);
            ids[0] = shortId;
            values[0] = amount;
            ch.safeBatchTransferFrom(mm, to, ids, values, "");
        } else {
            ch.safeTransferFrom(mm, to, shortId, amount, "");
        }
        vm.stopPrank();
    }
}
