// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {HouseVaultTestBase} from "./HouseVaultBase.t.sol";
import {HouseVault} from "../../../src/v2/periphery/house/HouseVault.sol";
import {MockSettlementOracle} from "../../../src/v2/mocks/MockSettlementOracle.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice The quoting guard rails: self-dealing, the MakerVault equivalence, and the seller-fee gross-up
///         (P8-06 criteria 7, 8, 9).
/// @dev AUTHORED, NOT RUN under the owner's build-mode directive; they compile. Only the pinned-artifact suite and
///      `forge build --sizes` were executed.
contract HouseVaultGuardsTest is HouseVaultTestBase {
    /// @dev In the money at the fixture's spot of 220 USDG, unlike `CALL_STRIKE` (230) and `PUT_STRIKE` (210).
    uint128 internal constant ITM_CALL_STRIKE = 200_000_000;
    /// @dev A boundary price inside the fixture's band; the same value `HouseVaultEpoch.t.sol:33` uses.
    uint256 internal constant BOUNDARY_PRICE = 220_000_000;

    /*//////////////////////////////////////////////////////////////
                    CRITERION 7 -- NO SELF-DEALING
    //////////////////////////////////////////////////////////////*/

    /// @dev Checked ON CHAIN before the book is called: the named makers are read with `getOrders` and the take is
    ///      refused if any of them is a protocol account or this vault.
    ///
    ///      THIS TEST NEVER ONCE REACHED THE REFUSAL IT NAMES. Until this row it used `callId`, whose expiry is
    ///      FRI_2026_09_18 -- BEYOND the boundary {HouseVault} takes from the calendar at construction. So
    ///      `_seriesInEpoch` at HouseVault.sol:734 reverted `BadExpiry` one line before `_requireNoSelfDeal` at
    ///      :736, and the suite reported `Error != expected error: BadExpiry() != NotAuthorized()` at every base
    ///      anyone has measured. The assertion whose entire job is to prove the vault refuses a protocol-account
    ///      maker had never executed that refusal.
    ///
    ///      WHY THAT WAS WORSE THAN A MISSING TEST, and the reason this row exists rather than a ledger line: it
    ///      failed its own `expectRevert` for the WRONG ERROR. The day anyone fixed the fixture's expiry for an
    ///      unrelated reason, it would have gone GREEN without a single person confirming the refusal fires.
    ///
    ///      THE SERIES IS THE FIX, NOT THE CONTRACT. The contract was behaving correctly at every point; the test
    ///      simply never got to it. {_inEpochCallId} builds a series that expires ON the boundary, which is what
    ///      the epoch guard requires, and {test_take_reachesTheSelfDealCheckAtAll} is the control that says so
    ///      independently of the refusal under test.
    function test_take_refusesAProtocolAccountMaker() public {
        uint256 longId = _inEpochCallId();
        vm.prank(admin);
        house.setProtocolAccount(mm, true);
        uint256 askId = _place(mm, longId, WRITE, P3_00, 10);

        V2Types.TakeParams memory p = _buyParamsFor(longId, askId);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        house.take(p);
    }

    /// @dev THE CONTROL FOR THE TEST ABOVE, and it is the whole point of this row. A refusal test proves nothing
    ///      unless something independent shows the call REACHES the refusal. Same series, same shape, maker NOT a
    ///      protocol account: this call must not die on `BadExpiry`. It still reverts -- the vault holds no USDG in
    ///      this fixture, which is {T-HV-SUITE-16-FAILURES} and not this row -- and the assertion is about WHICH
    ///      revert, exactly as the sibling controls in this file are.
    ///
    ///      WITHOUT THIS, "fix the expiry until the test goes green" is indistinguishable from "fix the expiry and
    ///      accidentally stop reaching the guard a different way".
    function test_take_reachesTheSelfDealCheckAtAll() public {
        uint256 longId = _inEpochCallId();
        assertFalse(house.protocolAccount(mm), "control precondition: mm is an ordinary maker");
        uint256 askId = _place(mm, longId, WRITE, P3_00, 10);
        V2Types.TakeParams memory p = _buyParamsFor(longId, askId);

        vm.prank(quoter);
        (bool ok, bytes memory ret) = address(house).call(abi.encodeCall(HouseVault.take, (p)));

        assertFalse(ok, "the fixture funds no USDG, so this must still revert");
        // T-586 / F-CT5B-02. WITHOUT THIS LINE THE TWO ASSERTIONS BELOW ARE VACUOUS. Both are of the form
        // `assertFalse(ret.length >= 4 && bytes4(ret) == ...)`, and `ret.length >= 4` short-circuits the `&&`,
        // so a revert carrying NO returndata -- out of gas, a bare `revert()`, a failed `require` with no
        // string -- satisfies BOTH and this control reports the self-deal check reachable having shown
        // nothing at all. The control for a control has to be that there IS something to inspect.
        assertTrue(ret.length >= 4, "the revert carried no selector, so neither assertion below can see anything");
        assertFalse(
            ret.length >= 4 && bytes4(ret) == V2Errors.BadExpiry.selector,
            "the epoch guard still refuses this series, so the self-deal check is STILL unreachable"
        );
        assertFalse(
            ret.length >= 4 && bytes4(ret) == V2Errors.NotAuthorized.selector,
            "an ordinary maker was refused as a protocol account"
        );
    }

    /// @dev The vault must not take its own resting order either.
    function test_take_refusesItsOwnOrderAsMaker() public {
        _seedVaultWallet(10_000e6);
        // CREATED BEFORE THE PRANK, DELIBERATELY. `_inEpochCallId` calls `house.epochEnd()` and `ch.createSeries`,
        // so leaving it under the prank lets it eat the prank and `place` arrives from the TEST CONTRACT.
        uint256 longId = _inEpochCallId();
        vm.prank(quoter);
        house.depositToClearinghouse(address(usdg), 5_000e6);
        vm.prank(quoter);
        uint256 own = house.place(longId, BID, P2_00, 10, 0);

        V2Types.TakeParams memory p = _buyParamsFor(longId, own);
        p.buying = false;
        vm.prank(quoter);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        house.take(p);
    }

    function test_take_allowsAnOrdinaryMaker() public {
        uint256 longId = _inEpochCallId();
        uint256 askId = _place(mm, longId, WRITE, P3_00, 10);
        assertFalse(house.protocolAccount(mm), "fixture precondition");
        V2Types.TakeParams memory p = _buyParamsFor(longId, askId);
        _seedVaultWallet(10_000e6);
        vm.prank(quoter);
        house.depositToClearinghouse(address(usdg), 5_000e6);
        vm.prank(quoter);
        house.take(p);
    }

    /// @dev Stated in the contract NatSpec and restated here so nobody mistakes the scope: a PROTOCOL ACCOUNT CAN
    ///      STILL HIT THE VAULT'S RESTING ORDER, because the book never calls back into the maker on a fill. No
    ///      contract-level check can see that. Refusing it is the bot's job (K8-05) plus indexing.
    function test_restingOrderSelfDealIsNotCoveredOnChain() public {
        vm.prank(admin);
        house.setProtocolAccount(mm, true);
        _seedVaultWallet(10_000e6);
        // Created before the prank, same reason as {test_take_refusesItsOwnOrderAsMaker}.
        uint256 longId = _inEpochCallId();
        vm.prank(quoter);
        house.depositToClearinghouse(address(usdg), 5_000e6);
        vm.prank(quoter);
        uint256 bidId = house.place(longId, BID, P2_00, 10, 0);

        // mm -- a protocol account -- sells INTO the vault's bid. The vault is the maker and is never consulted.
        V2Types.TakeParams memory p;
        p.longId = callId;
        p.buying = false;
        p.orderIds = _ids(bidId);
        p.units = 10;
        p.limitPrice = P2_00;
        p.writeToSell = true;
        p.recipient = mm;
        p.deadline = NO_DEADLINE;
        p.maxTotalFee = type(uint128).max;
        _take(mm, p); // succeeds -- documented, not a defect of this contract
    }

    /// @notice T-283/F-CT2-03 (ops/audit/CT2-PERIPHERY.md). THIS PINS A KNOWN HOLE, IT DOES NOT CLOSE IT. The ask
    ///         floor is `max(0, intrinsic - spot x askToleranceBps/BPS) x BPS/(BPS - sellerFeeBps)`, and `intrinsic`
    ///         is ZERO for every out-of-the-money series. So the floor is zero on exactly the series a covered-call
    ///         vault exists to write, and {_checkPrice} then accepts ANY non-zero tick price there -- including one
    ///         tick, against depositor collateral. The EarnVault NatSpec describes this guard as closing the
    ///         "one wei AskWrite" hole; on an OTM series it does not bind at all.
    /// @dev    NOT FIXED HERE, DELIBERATELY -- this is a scope boundary, not an omission. `_askFloor` is
    ///         BYTE-IDENTICAL in HouseVault.sol, src/v2/mm/MakerVault.sol and src/v2/periphery/earn/EarnVault.sol,
    ///         and {test_askFloorAndBidCapAgreeWithMakerVaultExactly} below pins House and Maker to agree EXACTLY on
    ///         calls and puts, for minting and resale fills. The other two contracts are outside T-283's
    ///         `scope_paths`, so giving OTM series a real floor here alone would silently diverge three mirrored
    ///         contracts AND require weakening the one test that keeps them in step. It needs a single row scoped to
    ///         all three, and a design ruling first: a real OTM floor needs a premium model or a tuned non-zero
    ///         tolerance, which the EarnVault NatSpec already lists as a follow-up nobody owns.
    ///         What this test buys is an EXAMINED zero instead of an assumed one. The day someone gives OTM series a
    ///         floor, this goes red and they have to change it on purpose rather than discovering it later.
    function test_askFloorIsZeroOnAnOutOfTheMoneySeries_soAOneTickWriteIsAccepted() public {
        uint256 otm = _inEpochCallId();
        assertEq(house.askFloorOf(otm, true), 0, "KNOWN HOLE: no floor at all on an out-of-the-money series");

        // ...and the book really does take the smallest price the tick grid allows.
        _seedVaultWallet(10_000e6);
        nvda.mint(address(house), DEP_STOCK); // collateral to write a call against
        vm.prank(quoter);
        house.depositToClearinghouse(address(nvda), DEP_STOCK);
        vm.prank(quoter);
        uint256 orderId = house.place(otm, WRITE, uint128(V2Constants.PRICE_TICK), 1, 0);
        assertGt(orderId, 0, "a one-tick AskWrite rests: the guard the NatSpec advertises does not bind here");
    }

    /*//////////////////////////////////////////////////////////////
          CRITERION 8 -- EQUIVALENCE WITH THE v8 MakerVault
    //////////////////////////////////////////////////////////////*/

    /// @dev The two vaults are constructed with IDENTICAL {Limits} on identical state, so every price guard must
    ///      agree EXACTLY. A paraphrase of MakerVault's helpers -- which is what this had to be, since every one of
    ///      them is `private` and cannot be inherited -- is only safe if it is checked against the original.
    function test_askFloorAndBidCapAgreeWithMakerVaultExactly() public view {
        assertEq(house.askFloorOf(callId, true), vault.askFloorOf(callId, true), "call, minting fill");
        assertEq(house.askFloorOf(callId, false), vault.askFloorOf(callId, false), "call, resale fill");
        assertEq(house.bidCap(callId), vault.bidCap(callId), "call, bid cap");

        assertEq(house.askFloorOf(putId, true), vault.askFloorOf(putId, true), "put, minting fill");
        assertEq(house.askFloorOf(putId, false), vault.askFloorOf(putId, false), "put, resale fill");
        assertEq(house.bidCap(putId), vault.bidCap(putId), "put, bid cap");
    }

    /// @dev And they must keep agreeing as spot moves, including through the in-the-money / out-of-the-money edge
    ///      where `intrinsic` turns on and the tolerance clamps `base` to zero.
    function test_askFloorAgreesAcrossSpot() public {
        uint256[6] memory spots =
            [uint256(180_000_000), 210_000_000, 229_000_000, 230_000_000, 231_000_000, 400_000_000];
        for (uint256 i; i < spots.length; ++i) {
            _setSpot(address(nvda), spots[i]);
            assertEq(house.askFloorOf(callId, true), vault.askFloorOf(callId, true), "call floor diverged");
            assertEq(house.askFloorOf(putId, true), vault.askFloorOf(putId, true), "put floor diverged");
            assertEq(house.bidCap(callId), vault.bidCap(callId), "bid cap diverged");
        }
    }

    /// @dev The outflow bucket refills linearly over OUTFLOW_WINDOW and NO CALLER IS EXEMPT -- `msg.sender` is not
    ///      consulted by `_bookOutflow` at all, so the bound is a property of the contract. Both vaults expose the
    ///      same view and must report the same refill on the same elapsed time.
    function test_outflowBucketRefillsOverTheWindowForEveryCaller() public {
        (uint256 usedHouse, uint256 availHouse) = house.outflow();
        (uint256 usedMaker, uint256 availMaker) = vault.outflow();
        assertEq(usedHouse, usedMaker, "used diverged at rest");
        assertEq(availHouse, availMaker, "available diverged at rest");
        assertEq(availHouse, MAX_DAILY_OUTFLOW, "a fresh bucket is the full cap");

        vm.warp(block.timestamp + OUTFLOW_WINDOW / 2);
        (, uint256 availHalf) = house.outflow();
        assertEq(availHalf, MAX_DAILY_OUTFLOW, "an unused bucket cannot exceed the cap");
    }

    /// @dev Every limit still binds: the per-series unit ceiling refuses growth past it.
    function test_maxSeriesUnitsStillBinds() public {
        _seedVaultWallet(400_000e6);
        // `callId` outlives the epoch, so `place` refuses BadExpiry before the ceiling is ever consulted -- the
        // same defect {_inEpochCallId} was written for and the same one line 24 records against this file.
        uint256 longId = _inEpochCallId();
        vm.prank(quoter);
        house.depositToClearinghouse(address(usdg), 200_000e6);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        house.place(longId, BID, P2_00, uint64(MAX_SERIES_UNITS) + 1, 0);
    }

    /// @dev And the live-order ceiling, which bounds the gas of every exposure measurement.
    function test_maxLiveOrdersPerSeriesStillBinds() public {
        _seedVaultWallet(400_000e6);
        uint256 longId = _inEpochCallId();
        vm.prank(quoter);
        house.depositToClearinghouse(address(usdg), 200_000e6);
        for (uint256 i; i < house.MAX_LIVE_ORDERS_PER_SERIES(); ++i) {
            vm.prank(quoter);
            house.place(longId, BID, P2_00, 1, 0);
        }
        vm.prank(quoter);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        house.place(longId, BID, P2_00, 1, 0);
    }

    /*//////////////////////////////////////////////////////////////
        CRITERION 9 -- THE ASK FLOOR IS GROSSED UP BY THE BOOK'S FEE
    //////////////////////////////////////////////////////////////*/

    /// @dev MIRROR, DO NOT RE-REASON. The expected value is recomputed here from the SAME inputs the contract reads --
    ///      `orderBook.feeParams()` and `V2Constants.BPS` -- never from a hard-coded 500. If the book's fee moves,
    ///      both sides move together and this test still holds; a literal would silently stop testing anything.
    function test_askFloorIsGrossedUpByTheSellerFeeReadFromTheBook() public view {
        V2Types.FeeParams memory f = book.feeParams();
        V2Types.Series memory s = ch.series(callId);
        (uint256 spot,) = oracle.spot(address(nvda));

        uint256 intrinsic = spot > s.strike ? spot - s.strike : 0;
        uint256 tolerance = spot * ASK_TOLERANCE_BPS / V2Constants.BPS;
        uint256 base = intrinsic > tolerance ? intrinsic - tolerance : 0;

        uint256 expectedPrimary =
            base == 0 ? 0 : Math.ceilDiv(base * V2Constants.BPS, V2Constants.BPS - f.premiumFeeBps);
        uint256 expectedResale = base == 0 ? 0 : Math.ceilDiv(base * V2Constants.BPS, V2Constants.BPS - f.resaleFeeBps);

        assertEq(house.askFloorOf(callId, true), expectedPrimary, "minting fill uses premiumFeeBps");
        assertEq(house.askFloorOf(callId, false), expectedResale, "resale fill uses resaleFeeBps");
    }

    /// @dev The rate is READ, not copied: raising the book's premium fee must raise the floor on the next read with
    ///      no redeploy and no setter on the vault.
    function test_askFloorFollowsAFeeChangeInTheBook() public {
        uint256 longId = _inEpochItmCallId();
        uint256 before = house.askFloorOf(longId, true);
        assertGt(before, 0, "fixture precondition: the floor must be non-zero before a fee change can raise it");
        V2Types.FeeParams memory f = book.feeParams();
        f.premiumFeeBps = f.premiumFeeBps * 2;
        vm.prank(admin);
        book.setFeeParams(f);

        // THE FEE IS SCHEDULED, NOT APPLIED, AND THAT IS WHAT THIS TEST GOT WRONG. `OrderBook.setFeeParams`
        // (`OrderBook.sol:592-602`) stores the new params as `_pendingFees` with `effectiveAt = now +
        // V2Constants.FEE_CHANGE_DELAY` -- 48 h, new in INTERFACE_VERSION 8. Before that instant `feeParams()`
        // still resolves to the OLD fee, so the floor was right to be unchanged: 18736843 is exactly
        // ceilDiv(17_800_000 x BPS, BPS - 500). The test was written against v7, where the write took effect on
        // the spot. Reading the floor immediately measured the delay, not the vault.
        assertEq(house.askFloorOf(longId, true), before, "the fee must NOT move the floor before it is effective");
        vm.warp(block.timestamp + V2Constants.FEE_CHANGE_DELAY);
        assertGt(house.askFloorOf(longId, true), before, "the floor did not follow the fee once it was effective");
    }

    /// @dev A selling quote below the floor is refused BadPrice, which is what the gross-up exists to enforce: at the
    ///      bare intrinsic the vault would keep only (BPS - sellerFeeBps)/BPS of it and hand the rest to the buyer.
    function test_placingAnAskBelowTheFloorIsRefused() public {
        // The floor is read off an IN-EPOCH series. On `callId` it was zero -- the series outlives the epoch --
        // and `vm.assume(0 > PRICE_TICK)` fails the test outright in a NON-FUZZ body, which is what FOUNDRY::ASSUME
        // was. An assume is a precondition here, not a fuzz filter, so it is now an assertion: if the floor is ever
        // zero again this says so instead of skipping.
        uint256 longId = _inEpochItmCallId();
        uint256 floor = house.askFloorOf(longId, true);
        assertGt(floor, V2Constants.PRICE_TICK, "fixture precondition: the floor must exceed one tick");
        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadPrice.selector);
        house.place(longId, WRITE, uint128(floor - V2Constants.PRICE_TICK), 1, 0);
    }

    /*//////////////////////////////////////////////////////////////
                         THE EPOCH CONFINEMENT
    //////////////////////////////////////////////////////////////*/

    /// @dev Quoting is confined to the epoch: a series that outlives {epochEnd} is refused BadExpiry, because the
    ///      boundary has to find the vault flat and cannot if a position can outlive it.
    function test_quotingRefusesASeriesBeyondTheEpoch() public {
        uint40 end = house.epochEnd();
        V2Types.Series memory s = ch.series(callId);

        // THE PRECONDITION WAS WRITTEN BACKWARDS. This test needs a series that OUTLIVES the epoch -- that is the
        // whole point of it -- and it asserted `s.expiry <= end`, which is the opposite. `callId` expires
        // FRI_2026_09_18, past the boundary `epochEnd` took from the calendar at construction, so the condition was
        // false and `vm.assume` failed the test outright: in a NON-FUZZ body an assume is a precondition, not a
        // filter, and FOUNDRY::ASSUME is a failure rather than a skip. So it never once reached the refusal it names.
        assertGt(s.expiry, end, "fixture precondition: the series must outlive the epoch");

        // The warp is kept because `place` also reads the mint cutoff, but it does NOT do what the old comment
        // claimed: `epochEnd` is STORED state (`HouseVault.sol:201`, written at construction and at each roll), so
        // moving `block.timestamp` cannot move the boundary. The series outlives the epoch on its own.
        vm.warp(uint256(s.expiry) - 8 days);
        assertLt(house.epochEnd(), s.expiry, "fixture precondition: the series outlives the epoch");
        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadExpiry.selector);
        house.place(callId, BID, P2_00, 1, 0);
    }

    /*//////////////////////////////////////////////////////////////
       CRITERION 7b -- THE SET IS NOT EMPTY, AND EMPTY FAILS CLOSED
    //////////////////////////////////////////////////////////////*/

    /// @notice The gap this section exists for: `protocolAccount` was EMPTY at launch and nothing filled it, so
    ///         {HouseVault._requireNoSelfDeal} passed every take by having no subject to refuse. The constructor now
    ///         seeds the one address it can derive, and {HouseVault.take} refuses to run until CONFIG_ADMIN has
    ///         named the rest.
    /// @dev READ THE SHAPE OF THESE TESTS. The protected fact is "the set was configured by a human who knew what
    ///      the protocol addresses are". So they break THAT -- by building a vault nobody ever configured -- rather
    ///      than breaking the checker. A test that asserted `_requireNoSelfDeal` reverts for a maker it had just
    ///      added itself is exactly the shape that let the original defect ship: it can only ever pass.
    function test_constructor_seedsTheSplitterAsAProtocolAccount() public view {
        assertTrue(house.protocolAccount(splitterAddr), "splitter must be a protocol account from birth");
    }

    /// @dev Seeding is NOT arming. The splitter is derivable; the MakerVault, the EarnVault, the Hedger and the
    ///      protocol Safes are not, and a vault cannot tell a deliberate empty set from a forgotten one.
    function test_constructor_doesNotArmTheVault() public {
        HouseVault fresh = _newUnarmedHouse();
        assertTrue(fresh.protocolAccount(splitterAddr), "splitter seeded");
        assertFalse(fresh.protocolAccountsConfirmed(), "a fresh vault must NOT be armed");
    }

    /// @notice THE RED HALF. A vault whose protocol-account set was never configured cannot take at all.
    /// @dev This is the state every House vault was in at launch before this row. `recipient` is deliberately
    ///      `address(0)`, an INVALID recipient, which is what makes the pair below load-bearing: the only thing
    ///      that changes between this test and the next is whether CONFIG_ADMIN has spoken.
    function test_take_refusesWhileTheProtocolAccountSetWasNeverConfigured() public {
        HouseVault fresh = _newUnarmedHouse();
        V2Types.TakeParams memory p = _buyParams(_place(mm, callId, WRITE, P3_00, 10));
        p.recipient = address(0);

        vm.prank(quoter);
        vm.expectRevert(V2Errors.NoSource.selector);
        fresh.take(p);
    }

    /// @notice THE GREEN HALF. Same vault, same call, same invalid recipient -- one `setProtocolAccount` apart.
    /// @dev It now fails `NotAuthorized` on the recipient check that sits immediately AFTER the confirmation gate,
    ///      which proves the take got past the gate rather than proving the take succeeded. Asserting a successful
    ///      fill here would have needed funding and would have made the pair depend on something other than the
    ///      guard under test.
    function test_take_passesTheConfirmationGateOnceArmed() public {
        HouseVault fresh = _newUnarmedHouse();
        vm.prank(admin);
        fresh.setProtocolAccount(address(vault), true);
        assertTrue(fresh.protocolAccountsConfirmed(), "one blocking call arms it");

        V2Types.TakeParams memory p = _buyParams(_place(mm, callId, WRITE, P3_00, 10));
        p.recipient = address(0);

        vm.prank(quoter);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        fresh.take(p);
    }

    /// @dev Arming requires naming an account to BLOCK. `setProtocolAccount(x, false)` says nothing about whether
    ///      the operator ever considered the set, and a vault armed by it would be armed with an empty set -- the
    ///      exact state the gate exists to refuse.
    function test_unblockingAnAccountDoesNotArmTheVault() public {
        HouseVault fresh = _newUnarmedHouse();
        vm.prank(admin);
        fresh.setProtocolAccount(mm, false);
        assertFalse(fresh.protocolAccountsConfirmed(), "an unblock must not arm the vault");

        V2Types.TakeParams memory p = _buyParams(_place(mm, callId, WRITE, P3_00, 10));
        p.recipient = address(0);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.NoSource.selector);
        fresh.take(p);
    }

    /// @dev Clearing the set afterwards does NOT re-close the gate, on purpose. That is a deliberate act by
    ///      CONFIG_ADMIN on a live vault, not the never-configured state, and disarming mid-epoch would strand
    ///      open positions the vault still has to trade out of.
    function test_clearingTheSetDoesNotDisarmALiveVault() public {
        assertTrue(house.protocolAccountsConfirmed(), "fixture precondition: armed");
        vm.prank(admin);
        house.setProtocolAccount(address(vault), false);
        assertFalse(house.protocolAccount(address(vault)), "cleared");
        assertTrue(house.protocolAccountsConfirmed(), "still armed");
    }

    /// @dev THE FAIL-CLOSED STATE MUST NOT TRAP MONEY. An unarmed vault cannot quote, but every depositor path
    ///      stays open -- the same property the GUARDIAN brake is written around.
    function test_anUnarmedVaultStillAcceptsDeposits() public {
        HouseVault fresh = _newUnarmedHouse();
        vm.startPrank(depositorA);
        usdg.approve(address(fresh), type(uint256).max);
        fresh.requestDeposit(address(usdg), DEP_USDG);
        vm.stopPrank();

        assertFalse(fresh.protocolAccountsConfirmed(), "still unarmed");
        assertEq(fresh.pendingDepositUsdg(), DEP_USDG, "deposit queued on an unarmed vault");
    }

    /// @dev The arming is observable off chain, and happens exactly once. Counted from the logs rather than with
    ///      `expectEmit` so that the SECOND half -- "and not again" -- is asserted by the same mechanism as the
    ///      first, instead of by an absence nothing measures.
    /// @dev F7. The zero address can never be a maker, so blocking it blocks nothing -- and since `blocked == true`
    ///      is what ARMS {take}, accepting it would arm the self-deal check on a set that proves nothing was ever
    ///      considered. That is the "a check satisfied because it had nothing to check" state the arming flag
    ///      exists to refuse, reached by the CONFIG_ADMIN key in one typo.
    function test_setProtocolAccount_refusesTheZeroAddress() public {
        HouseVault fresh = _newUnarmedHouse();
        // `admin` is the CONFIG_ADMIN holder in this fixture, as every other setProtocolAccount case here uses.
        vm.prank(admin);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        fresh.setProtocolAccount(address(0), true);
        assertFalse(fresh.protocolAccountsConfirmed(), "a refused call still armed the vault");
    }

    function test_setProtocolAccount_announcesTheArmingExactlyOnce() public {
        HouseVault fresh = _newUnarmedHouse();

        vm.recordLogs();
        vm.prank(admin);
        fresh.setProtocolAccount(address(vault), true);
        assertEq(_countArmingLogs(vm.getRecordedLogs(), address(fresh)), 1, "the arming call announces once");

        // A second blocking call is an ordinary configuration change and must not re-announce.
        vm.recordLogs();
        vm.prank(admin);
        fresh.setProtocolAccount(splitterAddr, true);
        assertEq(_countArmingLogs(vm.getRecordedLogs(), address(fresh)), 0, "a later call must not re-announce");
    }

    /*//////////////////////////////////////////////////////////////
              CRITERION 10 -- THE BID CAP IS ACTUALLY ENFORCED
    //////////////////////////////////////////////////////////////*/

    /// @dev THE ENFORCEMENT, NOT THE VIEW, AND THE DIFFERENCE IS THE WHOLE ROW. Before this pair the only
    ///      bid-cap coverage in this file was `assertEq(house.bidCap(x), vault.bidCap(x))` at :180, :184 and
    ///      :196 -- three assertions comparing HouseVault's VIEW ({HouseVault.bidCap}, HouseVault.sol:996-998)
    ///      against MakerVault's. The guard that refuses an over-cap bid is a DIFFERENT code path, the
    ///      `if (price > spot * _limits.maxBidBpsOfSpot / V2Constants.BPS) revert` inside {HouseVault._checkPrice}
    ///      at HouseVault.sol:1119. MEASURED, NOT ASSUMED: deleting that `revert` left all 24 tests in this file
    ///      green. A view that agrees with another view says nothing about whether either is enforced.
    /// @dev THE CAP IS DERIVED FROM THE CONSTANTS, NOT READ BACK OUT OF `bidCap()`. Taking the price under test
    ///      from the view would make this pair FOLLOW the view if the two paths ever drift -- which is the exact
    ///      failure it exists to catch, and the reason comparing the views cannot substitute for it. NVDA_SPOT is
    ///      220e6 and MAX_BID_BPS is 1_000, so the cap is 22e6, and it is tick-aligned: an off-grid price would be
    ///      refused by the book rather than by the guard, which would prove nothing about this bound.
    /// @dev IN-EPOCH SERIES AND A FUNDED WALLET, both load-bearing, both learned from defects in this codebase.
    ///      `callId` outlives the epoch, so `place` reverts BadExpiry at HouseVault.sol:806 before `_checkPrice`
    ///      is reached at :808 -- the same defect line 24 of this file records against its own self-dealing test.
    ///      And the accept leg escrows premium through the book, so an unfunded vault would fail it for
    ///      collateral rather than for price: that is exactly how EarnVault's accept case passed for its whole
    ///      life without ever testing its bound, which is what T-493 fixed.
    function test_bidCapRefusesOneTickAboveAndAcceptsTheCapItself() public {
        _seedVaultWallet(400_000e6);
        uint256 longId = _inEpochCallId();
        vm.prank(quoter);
        house.depositToClearinghouse(address(usdg), 200_000e6);

        uint256 cap = NVDA_SPOT * MAX_BID_BPS / V2Constants.BPS;
        assertEq(cap % V2Constants.PRICE_TICK, 0, "the cap must be tick-aligned or the book, not the guard, refuses");

        // ONE TICK ABOVE THE CAP IS REFUSED, and specifically as BadPrice. Naming the error is what keeps this
        // leg honest: if the series or the epoch fixture ever regresses, this fails as BadExpiry rather than
        // passing on an unrelated revert.
        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadPrice.selector);
        house.place(longId, BID, uint128(cap + V2Constants.PRICE_TICK), 1, 0);

        // THE CAP ITSELF IS ACCEPTED, AS A BARE CALL. Deliberately not a try/catch: an accept side wrapped in
        // try/catch passes on any revert at all, which is the defect T-493 was opened to fix in EarnVault. A
        // bare call fails this test outright if `place` reverts for any reason, and that is what makes the pair
        // pin the cap from both sides instead of merely reacting to it.
        vm.prank(quoter);
        uint256 orderId = house.place(longId, BID, uint128(cap), 1, 0);
        assertGt(orderId, 0, "the cap was accepted but nothing rests: place returned order id 0");
    }

    /// @dev SUSPICION 3 OF T-506, CLOSED. {HouseVault._checkPrice} has THREE call sites, not one:
    ///      HouseVault.sol:808 in `place`, :834 in `replace` and :894 in `take`. T-506 shipped exactly one
    ///      enforcement test, {test_bidCapRefusesOneTickAboveAndAcceptsTheCapItself}, and it reaches :808 only.
    ///      That catches a deletion of the SHARED guard body -- which is what its AC4 measured -- but it would
    ///      NOT catch a replace-specific or take-specific bypass that routed around `_checkPrice` altogether.
    ///      Its own entry names that gap and names these two tests as the fix, in the {MakerVaultGuards} shape
    ///      (MakerVaultGuards.t.sol:205-221), which HouseVault had no equivalent of.
    /// @dev THE CAP IS DERIVED, NOT READ BACK from `bidCap()`, for the same reason the T-506 pair derives it:
    ///      taking the price under test out of the view makes the test follow the view if the two paths drift,
    ///      which is the exact failure it exists to catch. NVDA_SPOT 220e6 x MAX_BID_BPS 1000 / BPS = 22e6.
    function test_bidCap_replaceFollowsSpot() public {
        _seedVaultWallet(400_000e6);
        uint256 longId = _inEpochCallId();
        vm.prank(quoter);
        house.depositToClearinghouse(address(usdg), 200_000e6);

        uint256 cap = NVDA_SPOT * MAX_BID_BPS / V2Constants.BPS;
        vm.prank(quoter);
        uint256 id = house.place(longId, BID, uint128(cap - V2Constants.PRICE_TICK), 1, 0);

        // THE REPLACE PATH'S OWN _checkPrice, HouseVault.sol:834. One tick above the cap is refused there.
        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadPrice.selector);
        house.replace(id, uint128(cap + V2Constants.PRICE_TICK), 1);

        // AND THE BOUND FOLLOWS SPOT rather than being a stored number: double the spot and the SAME price that
        // was just refused is now legal. A cap frozen at construction would fail this leg.
        _setSpot(address(nvda), NVDA_SPOT * 2);
        vm.prank(quoter);
        uint256 newId = house.replace(id, uint128(cap + V2Constants.PRICE_TICK), 1);
        assertGt(newId, 0, "the raised cap was accepted but nothing rests: replace returned order id 0");
    }

    /// @dev The buying-take leg of the same bound, through {HouseVault.take}'s own `_checkPrice` at
    ///      HouseVault.sol:894 -- the third call site, and the one a take-specific bypass would route around.
    ///      `mm` is asserted NOT a protocol account first, because `_requireNoSelfDeal` runs at :895, one line
    ///      AFTER the price check: if that precondition ever regresses this test would fail as NotAuthorized and
    ///      the cap would go untested while the suite was red for an unrelated-looking reason.
    function test_bidCap_buyingTakeLimit() public {
        _seedVaultWallet(400_000e6);
        uint256 longId = _inEpochCallId();
        uint256 askId = _place(mm, longId, WRITE, P3_00, 10);
        assertFalse(house.protocolAccount(mm), "fixture precondition: mm must not be a protocol account");
        vm.prank(quoter);
        house.depositToClearinghouse(address(usdg), 200_000e6);

        uint256 cap = NVDA_SPOT * MAX_BID_BPS / V2Constants.BPS;
        V2Types.TakeParams memory p = _buyParamsFor(longId, askId);

        p.limitPrice = uint128(cap + V2Constants.PRICE_TICK);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadPrice.selector);
        house.take(p);

        // THE CAP ITSELF FILLS, as a bare call. Not a try/catch: an accept leg wrapped in try/catch passes on
        // any revert at all, which is the defect T-493 was opened to fix in EarnVault.
        p.limitPrice = uint128(cap);
        vm.prank(quoter);
        (uint64 filled,,) = house.take(p);
        assertEq(filled, 10, "the take at the cap must fill against the resting ask at P3_00");
    }

    /*//////////////////////////////////////////////////////////////
        T-OP-047 -- THE CANCEL WINDOW IS THE REQUEST WINDOW (F-4)
    //////////////////////////////////////////////////////////////*/

    /// @dev The settlement price used by the boundary in these tests. Same value HouseVaultEpoch.t.sol uses.
    uint256 internal constant CANCEL_BOUNDARY_PRICE = 220_000_000;

    /// @dev THE DEFECT, and the fixture that reaches it. `requestDeposit` refuses at `epochEnd` (HouseVault.sol:368)
    ///      so nobody can join a finished batch at a known rate, but `epochId` only advances inside `rollEpoch`, so
    ///      the interval `[epochEnd, rollEpoch)` exists and the Finalized price is readable inside it. Before this
    ///      row `cancelDepositRequest` checked only `r.epochId != epochId` and paid out in that interval; the test
    ///      pins that it now refuses with the SAME error the way in uses, at `epochEnd` exactly and after it.
    ///
    ///      PROVE BY BREAKING (authored, not executed): delete the `PastCutoff` line in `cancelDepositRequest` and
    ///      this test goes red at `expectRevert` -- the cancel succeeds, the depositor is refunded, and
    ///      `pendingDepositUsdg` drops to 0 while the boundary's price is already public.
    function test_cancelDepositRequest_refusedAtOrAfterEpochEnd_beforeRoll() public {
        uint40 end = house.epochEnd();
        assertLt(block.timestamp, end, "fixture precondition: the request is made before the cutoff");
        _requestDeposit(depositorA, DEP_USDG, 0);
        assertEq(house.pendingDepositUsdg(), DEP_USDG, "the request is queued");

        // The interval the defect lives in: the boundary price is final and public, and nobody has rolled.
        uint64 idBefore = house.epochId();
        _finalizeBoundary(CANCEL_BOUNDARY_PRICE);
        (V2Types.SettlementStatus status, uint256 price) = oracle.settlementPrice(address(nvda), end);
        assertEq(uint8(status), uint8(V2Types.SettlementStatus.Finalized), "boundary price is not final");
        assertEq(price, CANCEL_BOUNDARY_PRICE, "boundary price is not known");
        assertEq(house.epochId(), idBefore, "fixture precondition: rollEpoch has not run, the request is still current");
        assertEq(block.timestamp, end, "at the cutoff exactly");

        // AT epochEnd: refused by the same name requestDeposit uses.
        uint256 walletBefore = usdg.balanceOf(depositorA);
        vm.prank(depositorA);
        vm.expectRevert(V2Errors.PastCutoff.selector);
        house.cancelDepositRequest(depositorA);

        // AFTER epochEnd, still before the roll: refused the same way.
        vm.warp(uint256(end) + 1 hours);
        assertEq(house.epochId(), idBefore, "still not rolled");
        vm.prank(depositorA);
        vm.expectRevert(V2Errors.PastCutoff.selector);
        house.cancelDepositRequest(depositorA);

        assertEq(house.pendingDepositUsdg(), DEP_USDG, "the request stayed committed to its batch");
        assertEq(usdg.balanceOf(depositorA), walletBefore, "nothing was refunded");

        // And the batch then prices it: the roll admits the request and the depositor holds shares, not USDG.
        house.rollEpoch();
        assertEq(house.pendingDepositUsdg(), 0, "the boundary consumed the queued deposit");
        vm.prank(depositorA);
        house.claim();
        assertGt(house.balanceOf(depositorA), 0, "the committed request was priced into shares");
        assertEq(usdg.balanceOf(depositorA), walletBefore, "the USDG stayed in the vault");
    }

    /// @dev CONTROL for the happy path: before the cutoff the cancel pays exactly as before this row.
    function test_cancelDepositRequest_beforeCutoffStillPays() public {
        uint40 end = house.epochEnd();
        uint256 walletBefore = usdg.balanceOf(depositorA);
        _requestDeposit(depositorA, DEP_USDG, 0);
        assertEq(usdg.balanceOf(depositorA), walletBefore - DEP_USDG, "the deposit was pulled");

        vm.warp(uint256(end) - 1);
        assertLt(block.timestamp, end, "one second before the cutoff");
        vm.prank(depositorA);
        vm.expectEmit(true, false, false, true, address(house));
        emit HouseVault.DepositRequestCancelled(depositorA, DEP_USDG, 0);
        house.cancelDepositRequest(depositorA);

        assertEq(house.pendingDepositUsdg(), 0, "the reservation was released");
        assertEq(usdg.balanceOf(depositorA), walletBefore, "the deposit came back in full");
        (uint64 epochOf, uint128 usdgLeft, uint128 stockLeft) = house.depositRequestOf(depositorA);
        assertEq(uint256(usdgLeft) + stockLeft, 0, "the request is gone");
        epochOf; // the epoch id of a deleted request is not part of the contract
    }

    /// @dev After the roll the request belongs to a CLOSED epoch: the pre-existing `TooEarly` refusal still fires
    ///      first, so the new cutoff changed nothing about a stale request, and the depositor claims shares.
    function test_cancelDepositRequest_afterRoll_priorEpochStillRefusedTooEarly() public {
        _requestDeposit(depositorA, DEP_USDG, 0);
        _finalizeBoundary(CANCEL_BOUNDARY_PRICE);
        house.rollEpoch();
        uint40 newEnd = house.epochEnd();
        assertLt(block.timestamp, newEnd, "the new epoch is running, so the cutoff is not what refuses here");

        vm.prank(depositorA);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.TooEarly.selector, newEnd));
        house.cancelDepositRequest(depositorA);

        vm.prank(depositorA);
        house.claim();
        assertGt(house.balanceOf(depositorA), 0, "the prior-epoch request was priced into shares");
    }

    /// @dev CONTROL: the withdraw-side cancel is UNCHANGED by this row. `cancelWithdrawRequest` has the same shape
    ///      (`r.epochId != epochId` only) but no price enters it: withdrawals are paid in kind pro rata at the
    ///      boundary (HouseVault.sol rollEpoch, the `usdgPool`/`stockPool` split), so a late cancel moves no value
    ///      between depositors. It must still succeed at and after `epochEnd` while the roll has not run.
    function test_cancelWithdrawRequest_unchangedAtOrAfterEpochEnd() public {
        // Acquire shares: deposit, roll, claim.
        _requestDeposit(depositorA, DEP_USDG, 0);
        _finalizeBoundary(CANCEL_BOUNDARY_PRICE);
        house.rollEpoch();
        vm.prank(depositorA);
        house.claim();
        uint256 shares = house.balanceOf(depositorA);
        assertGt(shares, 0, "fixture precondition: the depositor holds shares");

        // Escrow them for the next boundary, then stand in [epochEnd, rollEpoch) of THAT epoch.
        vm.prank(depositorA);
        house.requestWithdraw(shares);
        assertEq(house.pendingWithdrawShares(), shares, "the withdrawal is escrowed");
        uint40 end = house.epochEnd();
        uint64 idBefore = house.epochId();
        _finalizeBoundary(CANCEL_BOUNDARY_PRICE);
        assertEq(house.epochId(), idBefore, "not rolled");
        assertGe(block.timestamp, end, "at or after the cutoff");

        vm.prank(depositorA);
        house.cancelWithdrawRequest();
        assertEq(house.pendingWithdrawShares(), 0, "the withdraw-side cancel still pays after the cutoff");
        assertEq(house.balanceOf(depositorA), shares, "the shares came back");
    }

    /*//////////////////////////////////////////////////////////////
       T-OP-048 -- A RESERVE THE BOUNDARY LEFT IN THE LEDGER (F-5)
    //////////////////////////////////////////////////////////////*/

    /// @dev THE STATE F-5 DESCRIBES, REACHED. The withdrawal batch is measured over wallet PLUS `clearinghouse.free`
    ///      (rollEpoch's `stockPool`), so when the quoter has already posted the vault's Stock into the ledger the
    ///      boundary can set `owedStock` ABOVE the wallet, with the difference sitting in `free`. The F3 clamp on
    ///      {depositToClearinghouse} cannot see that: it only stops NEW deposits of reserved wallet balance, and this
    ///      balance was unreserved when it was deposited and became reserved in place. The next epoch's AskWrite
    ///      fill then locks the ledger balance through `Clearinghouse.mint`, which debits `free` with no notion of
    ///      reserves, and the withdrawer's {claim} finds `wallet + free < owed`.
    ///
    ///      THE WRITE LOCKS EVERYTHING THE LEDGER WILL COLLATERALISE, sized from `free` at the time rather than a
    ///      constant, so the test means the same thing on both sides of the fix: before it, the ledger held A's
    ///      reserve and the write locked it; after it, the ledger holds only B's unreserved Stock, the write locks
    ///      that, and A's reserve is in the wallet where a write cannot reach it.
    ///
    ///      THE ASSERTION IS THE INVARIANT, NOT THE FAILURE: the withdrawer is paid. At the base this row attached
    ///      to (82ac4c9b) this test is RED -- `claim` reverts `InsufficientCollateral` -- which is what establishes
    ///      that the state is reachable rather than only readable. With {_restoreReserve} at the boundary it is green.
    function test_claim_paysAWithdrawalReserveTheBoundaryLeftInTheLedger_afterAWriteLocksIt() public {
        // Epoch 0: A and B deposit Stock, the boundary prices them, both hold shares.
        _requestDeposit(depositorA, DEP_USDG, DEP_STOCK);
        _requestDeposit(depositorB, 0, DEP_STOCK);
        _finalizeBoundary(CANCEL_BOUNDARY_PRICE);
        house.rollEpoch();
        vm.prank(depositorA);
        house.claim();
        vm.prank(depositorB);
        house.claim();
        uint256 sharesA = house.balanceOf(depositorA);
        assertGt(sharesA, 0, "fixture precondition: A holds shares");

        // The quoter posts the whole Stock wallet as write collateral. Legal: nothing is reserved yet.
        uint256 stockWallet = nvda.balanceOf(address(house));
        assertEq(stockWallet, 2 * DEP_STOCK, "fixture precondition: both deposits are in the wallet");
        vm.prank(quoter);
        house.depositToClearinghouse(address(nvda), stockWallet);
        assertEq(nvda.balanceOf(address(house)), 0, "the wallet is empty");
        assertEq(ch.free(address(house), address(nvda)), 2 * DEP_STOCK, "the Stock is in the ledger");

        // Epoch 1: A escrows every share; the boundary measures the pool over wallet + ledger.
        vm.prank(depositorA);
        house.requestWithdraw(sharesA);
        _finalizeBoundary(CANCEL_BOUNDARY_PRICE);
        house.rollEpoch();

        uint256 owed = house.owedStock();
        assertGt(owed, 0, "the boundary reserved Stock for A");
        uint256 freeAfterRoll = ch.free(address(house), address(nvda));
        assertGe(nvda.balanceOf(address(house)) + freeAfterRoll, owed, "fixture precondition: the reserve is covered");

        // Epoch 2: the quoter writes a call that expires on this boundary for as many units as the ledger will
        // collateralise (95 %, leaving room for the mint rent), and a taker fills it.
        uint256 longId = _inEpochCallId();
        uint64 units = uint64(freeAfterRoll * 95 / 100 / ch.collateralPerUnit(longId));
        assertGt(units, 0, "fixture precondition: the ledger collateralises at least one unit");
        assertLe(units, MAX_SERIES_UNITS, "fixture precondition: inside the series cap");
        uint256 floor_ = house.askFloorOf(longId, true);
        uint128 ask = uint128(
            floor_ > P3_00
                ? (floor_ + V2Constants.PRICE_TICK - 1) / V2Constants.PRICE_TICK * V2Constants.PRICE_TICK
                : P3_00
        );
        vm.prank(quoter);
        uint256 askId = house.place(longId, WRITE, ask, units, 0);
        V2Types.TakeParams memory p = _buyParamsFor(longId, askId);
        p.units = units;
        p.limitPrice = ask;
        p.recipient = mm;
        assertEq(_take(mm, p), units, "mm did not take the vault's ask");
        assertLt(ch.free(address(house), address(nvda)), freeAfterRoll / 10, "the fill locked the ledger Stock");

        // THE INVARIANT (SEC-15 / F3 as HouseVault.sol states it above depositToClearinghouse): a priced withdrawal
        // is somebody else's money and claim always pays it, open short or not.
        uint256 aBefore = nvda.balanceOf(depositorA);
        vm.prank(depositorA);
        house.claim();
        assertEq(nvda.balanceOf(depositorA) - aBefore, owed, "A was paid the whole Stock reserve");
        assertEq(house.owedStock(), 0, "the reserve is retired");
    }

    /// @dev CONTROL for the fix: the pull-back moves ONLY the reserve. Two depositors, one leaves; after the boundary
    ///      the wallet holds exactly the reserve, the rest of the ledger balance is still the quoter's to write
    ///      against, an AskWrite fills as before, and the leaver is paid while the short is open.
    function test_rollEpoch_pullsBackExactlyTheLedgerHeldReserve_andAnUnreservedWriteStillFills() public {
        _requestDeposit(depositorA, DEP_USDG, DEP_STOCK);
        _requestDeposit(depositorB, DEP_USDG, DEP_STOCK);
        _finalizeBoundary(CANCEL_BOUNDARY_PRICE);
        house.rollEpoch();
        vm.prank(depositorA);
        house.claim();
        vm.prank(depositorB);
        house.claim();
        uint256 sharesA = house.balanceOf(depositorA);

        // Read the wallet BEFORE the prank: a call inside the argument list would consume it (T-586's trap).
        uint256 stockWallet = nvda.balanceOf(address(house));
        vm.prank(quoter);
        house.depositToClearinghouse(address(nvda), stockWallet);
        uint256 ledgerBefore = ch.free(address(house), address(nvda));
        assertEq(ledgerBefore, 2 * DEP_STOCK, "both deposits are in the ledger");

        vm.prank(depositorA);
        house.requestWithdraw(sharesA);
        _finalizeBoundary(CANCEL_BOUNDARY_PRICE);
        house.rollEpoch();

        uint256 owed = house.owedStock();
        assertGt(owed, 0, "A's reserve exists");
        assertEq(nvda.balanceOf(address(house)), owed, "the wallet holds exactly the reserve, nothing more");
        assertEq(ch.free(address(house), address(nvda)), ledgerBefore - owed, "the ledger gave up exactly the reserve");

        // The quoter still writes against what is left in the ledger.
        uint256 longId = _inEpochCallId();
        uint256 floor_ = house.askFloorOf(longId, true);
        uint128 ask = uint128(
            floor_ > P3_00
                ? (floor_ + V2Constants.PRICE_TICK - 1) / V2Constants.PRICE_TICK * V2Constants.PRICE_TICK
                : P3_00
        );
        vm.prank(quoter);
        uint256 askId = house.place(longId, WRITE, ask, 10, 0);
        V2Types.TakeParams memory p = _buyParamsFor(longId, askId);
        p.units = 10;
        p.limitPrice = ask;
        p.recipient = mm;
        assertEq(_take(mm, p), 10, "an unreserved write still fills");

        uint256 aBefore = nvda.balanceOf(depositorA);
        vm.prank(depositorA);
        house.claim();
        assertEq(nvda.balanceOf(depositorA) - aBefore, owed, "A is paid from the wallet while the short is open");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev `ProtocolAccountsConfirmed()` emitted by `emitter`. The topic is spelled out rather than taken from
    ///      the type, so the assertion still reads the real signature if the event is ever renamed.
    function _countArmingLogs(Vm.Log[] memory logs, address emitter) private pure returns (uint256 n) {
        bytes32 topic = keccak256("ProtocolAccountsConfirmed()");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics.length != 0 && logs[i].topics[0] == topic) ++n;
        }
    }

    /// @dev A call series that expires ON {HouseVault.epochEnd}, so `_seriesInEpoch` lets the take through.
    ///      `callId` cannot be used: its expiry is FRI_2026_09_18, which is past the boundary the vault took from
    ///      the calendar at construction -- which is exactly the state
    ///      {test_quotingRefusesASeriesBeyondTheEpoch} exists to refuse. T-586: that sentence used to say the
    ///      other test's `vm.assume` "fails for that reason", and it pointed at a mechanism that is gone -- the
    ///      assume was replaced by an `assertGt` precondition, because in a NON-FUZZ body FOUNDRY::ASSUME is a
    ///      failure rather than a filter and the test never reached the refusal it names. No `vm.assume` call
    ///      remains in this file; the three occurrences of the word are all prose describing that history. The boundary is itself a calendar expiry (`nextExpiry(..., true)`), so it is a legal
    ///      `createSeries` argument; the assertion below is here so that if it ever stops being one, this file
    ///      says so rather than the take failing for a reason nobody reads.
    function _inEpochCallId() internal returns (uint256 longId) {
        uint40 end = house.epochEnd();
        longId = ch.createSeries(address(nvda), false, CALL_STRIKE, end);
        V2Types.Series memory s = ch.series(longId);
        assertLe(s.expiry, house.epochEnd(), "the series must expire inside the epoch or take never reaches the guard");
    }

    /// @dev An IN-EPOCH call that is also IN THE MONEY, for the two tests that read {HouseVault.askFloorOf} and
    ///      need it to be non-zero. `_inEpochCallId` is not enough: it uses `CALL_STRIKE` (230 USDG) against a spot
    ///      of 220 (`BaseV2.NVDA_FEED_ANSWER`), so the call is OUT OF THE MONEY, `_askFloor`'s `intrinsic` is zero,
    ///      and the floor is CORRECTLY zero -- `HouseVault.sol:948-959` returns 0 whenever intrinsic <= tolerance.
    ///      The fixture's put is no better: `PUT_STRIKE` is 210, also out of the money at 220.
    ///
    ///      SO THOSE TWO TESTS COULD NEVER HAVE PASSED AGAINST THE SHARED SERIES, and the zero they measured was
    ///      the contract being right rather than the vault being broken. 200 USDG leaves intrinsic 20 against a
    ///      tolerance of 1% of spot (2.2), which clears `base != 0` with room to spare.
    function _inEpochItmCallId() internal returns (uint256 longId) {
        uint40 end = house.epochEnd();
        longId = ch.createSeries(address(nvda), false, ITM_CALL_STRIKE, end);
        assertLe(ch.series(longId).expiry, end, "the series must expire inside the epoch");
        assertGt(house.askFloorOf(longId, true), 0, "an in-the-money call must have a non-zero floor");
    }

    /// @dev {_buyParams} for a series other than `callId`. Same shape; the longId is the only difference.
    function _buyParamsFor(uint256 longId, uint256 orderId) internal view returns (V2Types.TakeParams memory p) {
        p = _buyParams(orderId);
        p.longId = longId;
    }

    function _buyParams(uint256 orderId) internal view returns (V2Types.TakeParams memory p) {
        p.longId = callId;
        p.buying = true;
        p.orderIds = _ids(orderId);
        p.units = 10;
        p.limitPrice = P3_00;
        p.recipient = address(house);
        p.deadline = NO_DEADLINE;
        p.maxTotalFee = type(uint128).max;
    }

    /*//////////////////////////////////////////////////////////////
            T-OP-058 -- THE BOUNDARY ORACLE CAN MOVE (BUG-02 F6)
    //////////////////////////////////////////////////////////////*/

    /// @dev `HouseVaultBase._wireHouseByHand` now maps `setOracle(address)` to CONFIG_ADMIN itself (T-OP-064,
    ///      the T-OP-058 follow-up), so this is a second, idempotent application of the same manifest mapping
    ///      (`roles.v8.json` `.targets.HouseVault["setOracle(address)"] = CONFIG_ADMIN`). It stays so that the
    ///      setOracle tests below do not depend on the fixture's hand list being complete: if that list ever drops
    ///      the selector again, these tests still measure CONFIG_ADMIN and not ADMIN-by-default (06-QUIRKS §A.8).
    ///      UNPRANKED for the reason `_wireHouseByHand` documents: the test contract is this manager's admin.
    function _mapSetOracleFromManifest() private {
        bytes4[] memory c = new bytes4[](1);
        c[0] = HouseVault.setOracle.selector;
        manager.setTargetFunctionRole(address(house), c, V8Roles.CONFIG_ADMIN);
    }

    /// @dev A second, distinct oracle that conforms: the same mock the fixture uses, freshly deployed and empty.
    function _freshOracle() private returns (MockSettlementOracle fresh) {
        fresh = new MockSettlementOracle();
        vm.label(address(fresh), "MockSettlementOracle#2");
    }

    function test_setOracle_refusesEveryoneButConfigAdmin() public {
        _mapSetOracleFromManifest();
        MockSettlementOracle fresh = _freshOracle();
        // QUOTER holds the whole quoting surface and is exactly who must NOT be able to move the price source.
        vm.prank(quoter);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        house.setOracle(address(fresh));
        vm.prank(guardian);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        house.setOracle(address(fresh));
        vm.prank(depositorA);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        house.setOracle(address(fresh));
        // THE CONTROL: the CONFIG_ADMIN holder gets through the same gate.
        vm.prank(admin);
        house.setOracle(address(fresh));
        assertEq(address(house.oracle()), address(fresh), "CONFIG_ADMIN moved the oracle");
    }

    function test_setOracle_refusesTheZeroAddress() public {
        _mapSetOracleFromManifest();
        vm.prank(admin);
        vm.expectRevert(V2Errors.NoSource.selector);
        house.setOracle(address(0));
    }

    function test_setOracle_refusesACodelessAddress() public {
        _mapSetOracleFromManifest();
        address eoa = makeAddr("not-a-contract");
        assertEq(eoa.code.length, 0, "precondition: no code");
        vm.prank(admin);
        vm.expectRevert(V2Errors.NoSource.selector);
        house.setOracle(eoa);
    }

    /// @dev A contract that is not an oracle: the USDG token has code and no `SETTLEMENT_WINDOW()`, so the probe's
    ///      staticcall reverts and the setter refuses -- the same fail-closed probe `Clearinghouse.setMarketOracle`
    ///      applies (`Clearinghouse.sol:370-377`).
    function test_setOracle_refusesAContractThatIsNotAnOracle() public {
        _mapSetOracleFromManifest();
        assertGt(address(usdg).code.length, 0, "precondition: a real contract");
        vm.prank(admin);
        vm.expectRevert(V2Errors.NoSource.selector);
        house.setOracle(address(usdg));
    }

    /// @dev `block.timestamp >= epochEnd` is a PENDING boundary: {rollEpoch} is callable and will read the oracle.
    ///      A switch here would let one epoch be pinned on one oracle and priced on another. Refused by name,
    ///      and the control shows the identical call succeeds one boundary later, inside the next epoch.
    function test_setOracle_refusesWhileABoundaryIsPending() public {
        _mapSetOracleFromManifest();
        MockSettlementOracle fresh = _freshOracle();
        _finalizeBoundary(BOUNDARY_PRICE); // warps to epochEnd
        assertGe(block.timestamp, house.epochEnd(), "precondition: the boundary is due");

        vm.prank(admin);
        vm.expectRevert(V2Errors.NotSettled.selector);
        house.setOracle(address(fresh));

        // THE CONTROL. Roll the boundary; the vault is inside the next epoch and the same call is accepted.
        house.rollEpoch();
        assertLt(block.timestamp, house.epochEnd(), "precondition: inside the new epoch");
        vm.prank(admin);
        house.setOracle(address(fresh));
        assertEq(address(house.oracle()), address(fresh));
    }

    function test_setOracle_emitsPreviousAndNext() public {
        _mapSetOracleFromManifest();
        MockSettlementOracle fresh = _freshOracle();
        vm.expectEmit(true, true, false, true, address(house));
        emit HouseVault.OracleSet(address(oracle), address(fresh));
        vm.prank(admin);
        house.setOracle(address(fresh));
    }

    /// @dev THE POINT OF THE ROW. After the switch the NEXT boundary prices off the NEW oracle: both oracles carry a
    ///      Finalized price for `epochEnd`, deliberately DIFFERENT, and the boundary's emitted price is the new
    ///      one's. Finalizing both is what makes the assertion load-bearing -- with only the new oracle finalized
    ///      the roll would prove "it read something that was final", not "it read the new one".
    function test_setOracle_theNextBoundaryPricesOffTheNewOracle() public {
        _mapSetOracleFromManifest();
        MockSettlementOracle fresh = _freshOracle();
        uint256 OLD_PRICE = 111_000_000;
        uint256 NEW_PRICE = 333_000_000;

        _requestDeposit(depositorA, DEP_USDG, 0);
        vm.prank(admin);
        house.setOracle(address(fresh));

        uint40 end = house.epochEnd();
        oracle.setSettlement(address(nvda), end, V2Types.SettlementStatus.Finalized, OLD_PRICE);
        fresh.setSettlement(address(nvda), end, V2Types.SettlementStatus.Finalized, NEW_PRICE);
        vm.warp(end);

        vm.recordLogs();
        house.rollEpoch();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("EpochRolled(uint64,uint40,uint256,uint256,uint256,uint256,uint256,uint256)");
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(house) || logs[i].topics[0] != topic) continue;
            (uint256 price,,,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
            assertEq(price, NEW_PRICE, "the boundary priced off the OLD oracle");
            assertTrue(price != OLD_PRICE, "the two prices must differ for this to prove anything");
            ++seen;
        }
        assertEq(seen, 1, "exactly one EpochRolled");
    }

    /// @dev The other half of the same proof: if the OLD oracle is the only one finalized, the boundary is now
    ///      REFUSED -- the vault really did stop reading it. Without this a `setOracle` that wrote the new address
    ///      and kept reading the old one would pass the test above only by the accident of both being finalized.
    function test_setOracle_theOldOracleNoLongerSatisfiesTheBoundary() public {
        _mapSetOracleFromManifest();
        MockSettlementOracle fresh = _freshOracle();
        _requestDeposit(depositorA, DEP_USDG, 0);
        vm.prank(admin);
        house.setOracle(address(fresh));

        uint40 end = house.epochEnd();
        oracle.setSettlement(address(nvda), end, V2Types.SettlementStatus.Finalized, BOUNDARY_PRICE);
        // `fresh` says nothing about `end`.
        vm.warp(end);
        vm.expectRevert(V2Errors.NotSettled.selector);
        house.rollEpoch();
    }

    /*//////////////////////////////////////////////////////////////
       T-OP-064 -- sync IS EPOCH-GATED; close IS THE ESCAPE HATCH AND NEVER TRACKS
    //////////////////////////////////////////////////////////////*/

    /// @dev A series that outlives {epochEnd} can reach this vault only by transfer: {place}/{replace}/{take} refuse
    ///      it BadExpiry, and the receipt hooks accept any Clearinghouse token from anyone. `mm` writes `units`
    ///      against its own ledger collateral and sends the long leg (and, on request, the short leg) here.
    ///      The operator grant is FIXTURE AUTHORIZATION, not part of the scenario: `Clearinghouse.mint` needs both an
    ///      allowlisted minter and the writer's consent, and this test contract is the minter.
    function _transferInALateSeries(uint64 units, bool bothLegs) internal returns (uint256 lateId) {
        uint40 end = house.epochEnd();
        uint40 later = calendar.nextExpiry(end + 1, true);
        assertGt(later, end, "fixture precondition: the series must outlive the epoch");
        lateId = ch.createSeries(address(nvda), false, CALL_STRIKE, later);
        vm.prank(mm);
        ch.setOperator(address(this), true);
        ch.mint(lateId, units, mm, mm);
        vm.prank(mm);
        ch.safeTransferFrom(mm, address(house), lateId, units, "");
        if (bothLegs) {
            // Computed BEFORE the prank: `shortIdOf` is a call, and a prank spends itself on the next one.
            uint256 shortId = ch.shortIdOf(lateId);
            vm.prank(mm);
            ch.safeTransferFrom(mm, address(house), shortId, units, "");
        }
        assertEq(house.trackedSeries().length, 0, "a bare transfer must not track anything by itself");
    }

    /// @notice SEC-14 residual, closed. A QUOTER {sync} on a transferred-in series expiring after {epochEnd} used to
    ///         put it into {_tracked}, after which {_requireFlat} held the boundary until THAT series settled. Now
    ///         {sync} refuses it by name, exactly as {place} does, so nothing an outsider sends can reach the boundary
    ///         through the QUOTER key.
    /// @dev    PROVE BY BREAKING: delete `_seriesInEpoch(longIds[i]);` from {HouseVault.sync} and this goes red twice
    ///         -- first at the `expectRevert` (the sync succeeds and tracks), then `rollEpoch` reverts NotSettled
    ///         because {_requireFlat} now waits on the donated series.
    function test_syncRefusesASeriesBeyondTheEpoch_soTheBoundaryRolls() public {
        uint256 lateId = _transferInALateSeries(1, false);

        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadExpiry.selector);
        house.sync(_ids(lateId));
        assertEq(house.trackedSeries().length, 0, "refused, so nothing was tracked");

        // An in-epoch sync is unchanged, and a batch is all-or-nothing: one out-of-epoch id refuses the whole call.
        uint256 inId = _inEpochCallId();
        vm.prank(quoter);
        house.sync(_ids(inId));
        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadExpiry.selector);
        house.sync(_ids(inId, lateId));
        assertEq(house.trackedSeries().length, 0, "nothing is held in either series, so nothing is tracked");

        // THE BOUNDARY ROLLS. The donated long is still here and still unexpired; it is simply not the vault's
        // problem, because it was never tracked.
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        assertEq(ch.balanceOf(address(house), lateId), 1, "the donated unit is still held, untracked");
    }

    /// @notice SEC-14 runbook step 5, kept working on purpose: if the vault holds BOTH legs of an out-of-epoch pair,
    ///         QUOTER {close} releases the collateral to the vault's ledger early. {close} is therefore NOT
    ///         epoch-gated -- but it must never TRACK such a series, or the escape hatch would itself hold the boundary.
    /// @dev    The partial close is the assertion that matters: after closing 1 of 2, a pair is still held, and an
    ///         unconditional `_refresh` would track it (the old code). PROVE BY BREAKING: make {HouseVault.close} call
    ///         `_refresh(longId)` unconditionally and "closed, not tracked" goes red on the partial close, then
    ///         `rollEpoch` reverts NotSettled.
    function test_closeReleasesAnOutOfEpochPair_andNeverTracksIt() public {
        uint256 lateId = _transferInALateSeries(2, true);
        uint256 shortId = ch.shortIdOf(lateId);
        uint256 freeBefore = ch.free(address(house), address(nvda));

        vm.prank(quoter);
        house.close(lateId, 1);
        assertEq(ch.balanceOf(address(house), lateId), 1, "one long remains");
        assertEq(ch.balanceOf(address(house), shortId), 1, "one short remains");
        assertGt(ch.free(address(house), address(nvda)), freeBefore, "the closed unit's collateral reached the vault's ledger");
        assertEq(house.trackedSeries().length, 0, "closed, not tracked");

        // The remaining pair does not hold the boundary either: it was never tracked, so {_requireFlat} never sees it.
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();

        // And the rest of the pair can still be released after the roll: close is the door out in every epoch.
        vm.prank(quoter);
        house.close(lateId, 1);
        assertEq(ch.balanceOf(address(house), lateId), 0, "the pair is fully closed");
        assertEq(ch.balanceOf(address(house), shortId), 0, "and the shorts with it");
        assertEq(house.trackedSeries().length, 0, "still nothing tracked");
    }

    /*//////////////////////////////////////////////////////////////
       T-OP-073 -- THE BOOK-OWED SLICE OF THE WITHDRAWAL POOL, AND WHETHER claim CAN REACH IT
    //////////////////////////////////////////////////////////////*/

    /// @dev The T-OP-048 residual, reach-first. The boundary measures the withdrawal pool over wallet + ledger +
    ///      `orderBook.owed(vault)` (HouseVault.sol:597-598) and reserves `owedUsdg` from it, but {_restoreReserve}
    ///      brings home only the LEDGER slice; the BOOK slice was reachable only through the QUOTER's {claimOwed}.
    ///      With the whole pool reserved for one withdrawer and the book holding part of it, {claim} paid from
    ///      wallet + free came up short by exactly the book-owed amount and failed closed in {_payReserved}.
    ///
    ///      THE FIXTURE, step by step, because every step is a precondition the assertion depends on:
    ///        1. one depositor funds the vault and takes every share after the first boundary;
    ///        2. the vault rests a Bid on an in-epoch series -- its escrow leaves the wallet for the book;
    ///        3. the depositor asks for ALL its shares back, so the next boundary reserves the ENTIRE pool;
    ///        4. at the boundary the series settles and the expired Bid is pruned with the refund transfer to the
    ///           vault made to fail (`vm.mockCallRevert` on `usdg.transfer(house, *)` only), so the refund is
    ///           recorded in `orderBook.owed` instead -- the exact shape {_nav}'s NatSpec describes at :731-733;
    ///        5. the ledger holds nothing, so {_restoreReserve} has nothing to pull.
    ///      After the roll, `owedUsdg` counts the book slice and the wallet does not hold it.
    function _reserveBackedByBookOwedUsdg() internal returns (uint256 reserved, uint256 bookOwed) {
        // 1. Shares.
        _requestDeposit(depositorA, DEP_USDG, 0);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        vm.prank(depositorA);
        house.claim();
        uint256 shares = house.balanceOf(depositorA);
        assertGt(shares, 0, "fixture: the depositor holds shares");

        // 2. A Bid whose escrow leaves the wallet. The series expires at the boundary, so the bid dies with it.
        uint256 inId = _inEpochCallId();
        vm.prank(quoter);
        house.place(inId, BID, P2_00, 10, 0);
        uint256[] memory ids = house.orderIdsOf(inId);
        assertEq(ids.length, 1, "fixture: exactly one resting bid");

        // 3. Everything out.
        vm.prank(depositorA);
        house.requestWithdraw(shares);

        // 4. Boundary: settle, then prune with the refund transfer failing, so the book OWES the vault the escrow.
        _finalizeBoundary(BOUNDARY_PRICE);
        vm.prank(keeper);
        assertTrue(ch.settle(inId), "fixture: the series did not settle");
        vm.mockCallRevert(address(usdg), abi.encodeWithSelector(IERC20.transfer.selector, address(house)), "");
        assertEq(book.prune(ids), 1, "fixture: prune did not cancel the expired bid");
        vm.clearMockedCalls();
        bookOwed = book.owed(address(house));
        assertGt(bookOwed, 0, "fixture: the refund was not recorded as owed");

        // 5. Nothing in the ledger to cover it.
        assertEq(ch.free(address(house), address(usdg)), 0, "fixture: the ledger must hold nothing");

        house.rollEpoch();
        reserved = house.owedUsdg();
        assertGt(reserved, 0, "fixture: nothing was reserved for the withdrawer");
    }

    /// @notice REACH TEST for the T-OP-048 residual. Scratch verdict at 1147989e, before the fix: RED --
    ///         `InsufficientCollateral(wallet + free, owed)` from {_payReserved}, the wallet short of the reserve by
    ///         exactly the book-owed refund. After the fix the boundary pulls the book slice home before measuring,
    ///         and the same claim pays in full.
    /// @dev    PROVE BY BREAKING: delete the `orderBook.claimOwed()` pull from {rollEpoch} and this reds at `claim`
    ///         with InsufficientCollateral, as it did before the fix.
    function test_claim_isPaidWhenTheReserveWasBackedByUsdgTheBookOwed() public {
        (uint256 reserved, uint256 bookOwed) = _reserveBackedByBookOwedUsdg();

        // THE FIX, observable: the book no longer owes the vault anything once the boundary has rolled, and the
        // wallet holds the whole reserve.
        assertEq(book.owed(address(house)), 0, "the boundary did not pull the book-owed slice home");
        assertGe(usdg.balanceOf(address(house)), reserved, "the wallet does not cover the reserve");
        assertGe(reserved, bookOwed, "the reserve is smaller than the slice that was in the book");

        uint256 before = usdg.balanceOf(depositorA);
        vm.prank(depositorA);
        house.claim();
        assertEq(usdg.balanceOf(depositorA) - before, reserved, "the withdrawer was not paid the whole reserve");
        assertEq(house.owedUsdg(), 0, "the reserve was not released");
    }

    /// @notice THE PULL IS BEST-EFFORT, and this is the guard on that: a USDG that refuses to pay this vault is the
    ///         very reason an `owed` balance exists, so the boundary must roll THROUGH a failing pull, leaving the
    ///         slice in the book where NAV and the pool still count it. Restoring the QUOTER's {claimOwed} later is
    ///         the pre-existing path.
    /// @dev    PROVE BY BREAKING: replace `try orderBook.claimOwed() {} catch {}` in {rollEpoch} with a bare
    ///         `orderBook.claimOwed();` and this reds at `rollEpoch` -- the book's `safeTransfer` bubbles up and the
    ///         permissionless boundary is blocked by a token the vault does not control.
    function test_rollEpoch_stillRollsWhenTheBookCannotPayTheVault() public {
        // Same fixture up to the boundary, but the refund transfer keeps failing THROUGH the roll.
        _requestDeposit(depositorA, DEP_USDG, 0);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        vm.prank(depositorA);
        house.claim();
        uint256 inId = _inEpochCallId();
        vm.prank(quoter);
        house.place(inId, BID, P2_00, 10, 0);
        uint256[] memory ids = house.orderIdsOf(inId);
        _finalizeBoundary(BOUNDARY_PRICE);
        vm.prank(keeper);
        assertTrue(ch.settle(inId), "fixture: the series did not settle");
        vm.mockCallRevert(address(usdg), abi.encodeWithSelector(IERC20.transfer.selector, address(house)), "");
        assertEq(book.prune(ids), 1, "fixture: prune did not cancel the expired bid");
        uint256 bookOwed = book.owed(address(house));
        assertGt(bookOwed, 0, "fixture: the refund was not recorded as owed");

        // The mock is still live: the pull inside rollEpoch fails, and the boundary must not care.
        uint64 idBefore = house.epochId();
        vm.prank(stranger);
        house.rollEpoch();
        vm.clearMockedCalls();
        assertEq(house.epochId(), idBefore + 1, "a failing pull blocked the permissionless boundary");
        assertEq(book.owed(address(house)), bookOwed, "the slice must stay in the book when the pull fails");
    }

    /// @notice CONTROL: a boundary with nothing owed by the book is unchanged -- the pull is a no-op on the book
    ///         side (`OrderBook.claimOwed` returns early on zero) and the withdrawer is paid exactly as before.
    function test_rollEpoch_withNothingOwedByTheBook_isUnchanged() public {
        _requestDeposit(depositorA, DEP_USDG, 0);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        vm.prank(depositorA);
        house.claim();
        uint256 shares = house.balanceOf(depositorA);
        vm.prank(depositorA);
        house.requestWithdraw(shares);
        assertEq(book.owed(address(house)), 0, "control precondition: the book owes nothing");

        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        uint256 reserved = house.owedUsdg();
        assertGt(reserved, 0, "control: nothing reserved");
        uint256 before = usdg.balanceOf(depositorA);
        vm.prank(depositorA);
        house.claim();
        assertEq(usdg.balanceOf(depositorA) - before, reserved, "control: the withdrawer was not paid the reserve");
    }

    /*//////////////////////////////////////////////////////////////
       T-OP-127 -- THE BATCH IS PRICED FROM THE POOL AFTER _redeemSettled
    //////////////////////////////////////////////////////////////*/

    /// @dev THE POOL COMPOSITION, pinned from primitives (T-OP-127). {HouseVault.rollEpoch} redeems every settled
    ///      tracked position (`_redeemSettled`) and pulls the book-owed slice home (T-OP-073) BEFORE it prices the
    ///      withdrawal batch, so a leaver's pro-rata share includes what a settled option just paid the vault. The
    ///      invariant campaign's model (`HouseNavHandler.poolValue`) read the pool BEFORE the call and valued no
    ///      option, so a boundary that redeemed an in-the-money call read as "a withdrawal batch was overpaid" by
    ///      exactly the leavers' share of the payout (T-OP-097's red, traced in the T-OP-127 ledger entry). This
    ///      test is the contract-side half of that verdict: the batch equals the mirror ONLY when the mirror counts
    ///      the settled payout, and the payout is what {Clearinghouse._redeem} multiplies -- `units x
    ///      longPayoutPerUnit` -- not a number asked of `house.nav()`.
    function test_rollEpoch_pricesTheBatchFromThePoolAfterRedeemingASettledLong() public {
        // 1. Shares, then a whole-supply exit queued so the batch is the entire pool.
        _requestDeposit(depositorA, DEP_USDG, 0);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        vm.prank(depositorA);
        house.claim();
        uint256 shares = house.balanceOf(depositorA);
        assertGt(shares, 0, "fixture: the depositor holds shares");

        // 2. The vault BUYS an in-the-money, in-epoch call from an ordinary writer (the T-OP-036 leg shape).
        uint256 longId = _inEpochItmCallId();
        uint256 askId = _place(mm, longId, WRITE, P3_00, 10);
        vm.prank(quoter);
        house.take(_buyParamsFor(longId, askId));
        uint256 units = ch.balanceOf(address(house), longId);
        assertEq(units, 10, "fixture: the vault holds the long it bought");

        vm.prank(depositorA);
        house.requestWithdraw(shares);

        // 3. Expiry: the series settles in the money (spot 220 against strike 200) and is NOT redeemed yet.
        _finalizeBoundary(BOUNDARY_PRICE);
        vm.prank(keeper);
        assertTrue(ch.settle(longId), "fixture: the series did not settle");
        V2Types.Series memory s = ch.series(longId);
        assertTrue(s.settled && !s.isPut, "fixture: a settled call");
        assertGt(s.longPayoutPerUnit, 0, "fixture: the call finished in the money");
        assertEq(nvda.balanceOf(address(house)), 0, "fixture: nothing has been redeemed into the wallet yet");

        // THE MIRROR, from primitives, read before the boundary: what the wallet holds plus what the settled long
        // will pay when the boundary redeems it (`Clearinghouse._redeem`: owed = amount * longPayoutPerUnit, in
        // Stock for a call), then the batch as the pro-rata slice of each leg.
        uint256 payoutStock = units * s.longPayoutPerUnit;
        uint256 usdgPool = usdg.balanceOf(address(house)) + ch.free(address(house), address(usdg))
            + book.owed(address(house)) - house.pendingDepositUsdg() - house.owedUsdg();
        uint256 stockPool = nvda.balanceOf(address(house)) + ch.free(address(house), address(nvda)) + payoutStock;
        uint256 supply = house.totalSupply();
        uint256 wShares = house.pendingWithdrawShares();
        assertEq(wShares, shares, "fixture: the whole holding is queued");
        uint256 expectStock = Math.mulDiv(stockPool, wShares, supply);
        uint256 expectUsdg = Math.mulDiv(usdgPool, wShares, supply);
        assertGt(expectStock, 0, "the batch must carry a Stock leg, or the payout was not in the pool");

        house.rollEpoch();

        // The contract's number equals the mirror that counts the payout -- and the payout landed in the wallet.
        assertEq(nvda.balanceOf(address(house)), payoutStock, "the boundary redeemed the settled long into the wallet");
        assertEq(ch.balanceOf(address(house), longId), 0, "the long was burned by the redeem");
        assertEq(house.owedStock(), expectStock, "the Stock leg of the batch is not the pro-rata share of the redeemed payout");
        assertEq(house.owedUsdg(), expectUsdg, "the USDG leg of the batch moved");
        // And the wallet-only mirror is short by exactly the leavers' share of the payout: the shape T-OP-097 read
        // as an overpayment. Stated as a number so the class of the T-OP-097 red is pinned, not just its absence.
        assertEq(house.owedStock() - Math.mulDiv(stockPool - payoutStock, wShares, supply), Math.mulDiv(payoutStock, wShares, supply), "the wallet-only model is short by the payout share");

        // The leaver collects both legs.
        uint256 stockBefore = nvda.balanceOf(depositorA);
        vm.prank(depositorA);
        house.claim();
        assertEq(nvda.balanceOf(depositorA) - stockBefore, expectStock, "the claimant did not receive the Stock leg");
        assertEq(house.owedStock(), 0, "the Stock reserve was not retired");
    }
}
