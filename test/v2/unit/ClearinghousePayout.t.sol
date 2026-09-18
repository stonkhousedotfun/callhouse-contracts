// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ClearinghouseTestBase} from "./ClearinghouseBase.t.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {IPayoutAdapter} from "../../../src/v2/interfaces/IPayoutAdapter.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {MockPayoutAdapter} from "../../../src/v2/mocks/MockPayoutAdapter.sol";

/// @notice Holds a holder's own USDG and hands it back to the holder on anyone's call, as OrderBook.prune refunds an
///         expired bid's escrow to its maker and RewardsDistributor.claim pays an entry to its account.
contract HolderRefundEscrow {
    using SafeERC20 for IERC20;

    IERC20 internal immutable usdg;
    address internal immutable holder;

    constructor(IERC20 usdg_, address holder_) {
        usdg = usdg_;
        holder = holder_;
    }

    function refund() external {
        usdg.safeTransfer(holder, usdg.balanceOf(address(this)));
    }
}

/// @notice Clearinghouse USDG payout conversion (ADR-11): an ITM call long is sold through the PayoutAdapter and the
///         Clearinghouse itself checks the USDG that arrived. Success really pays USDG (the regression the plan calls
///         out: a guarded inner call would always revert and silently degrade to in kind), every adapter failure pays
///         in kind, a malicious adapter can take no more than the approved amount and cannot re-enter. The floor is
///         measured above the adapter's route fee (INTERFACE_VERSION 6), which is read with bounded trust.
/// @dev Fixture: NVDA call K = 240 settled at P = 250; bob holds 100 units. Owed 3.75e16 NVDA base units (0.0375
///      share) worth 9.375 USDG at P; with the 100 bps bound and the mock's default route fee of 0, minOut = 9_281_250.
///      The adapter quotes at 250.00 unless a test changes the rate.
contract ClearinghousePayoutTest is ClearinghouseTestBase {
    uint256 internal callId;
    uint256 internal otmId;
    uint256 internal dustId;

    uint256 internal constant P = 250e6;
    uint256 internal constant OWED = 3.75e16;
    uint256 internal constant VALUE = 9_375_000;
    uint256 internal constant MIN_OUT = 9_281_250;
    /// @dev The route fee of a 0.30 % pool, bps.
    uint256 internal constant FEE_30 = 30;
    /// @dev VALUE less 130 bps: the 100 bps bound above a 30 bps route fee.
    uint256 internal constant MIN_OUT_FEE_30 = 9_253_125;
    /// @dev A spot 5 % above P, what OWED is worth there, and that value less the 100 bps bound.
    uint256 internal constant SPOT_UP = 262_500_000;
    uint256 internal constant VALUE_AT_SPOT_UP = 9_843_750;
    uint256 internal constant MIN_OUT_AT_SPOT_UP = 9_745_312;

    function setUp() public override {
        super.setUp();
        callId = _call(K_240, FRI_2026_09_18);
        otmId = _call(260_000_000, FRI_2026_09_18);
        dustId = _call(K_240, FRI_2026_09_11);
        _write(alice, callId, 100, bob);
        _write(carol, callId, 50, carol); // other collateral the adapter must not be able to reach
        _write(alice, otmId, 10, bob);
        _write(alice, dustId, 1, bob);
        // One base unit above the strike: the long is owed 37_500_000 base units (3.75e-11 share), worth 0 USDG.
        _settle(dustId, 240_000_001);
        _settle(callId, P);
        vm.prank(keeper);
        ch.settle(otmId);
        adapter.setRate(P, 10_000);
    }

    /*//////////////////////////////////////////////////////////////
                                 SUCCESS
    //////////////////////////////////////////////////////////////*/

    /// @dev The regression test: USDG really arrives, from inside redeem's guard.
    function test_convert_success_paysUsdg() public {
        uint256 chNvda = nvda.balanceOf(address(ch));
        uint256 chUsdg = usdg.balanceOf(address(ch));
        vm.expectEmit(true, true, false, true, address(ch));
        emit IClearinghouse.Redeemed(callId, bob, bob, 100, address(usdg), VALUE, OWED, false);
        (uint256 paid, bool inUsdg) = _redeem(callId, bob);

        assertTrue(inUsdg, "converted");
        assertEq(paid, VALUE);
        assertEq(usdg.balanceOf(bob), ACTOR_USDG + VALUE, "holder received USDG");
        assertEq(nvda.balanceOf(bob), ACTOR_SHARES, "and no Stock Tokens");
        assertEq(nvda.balanceOf(address(adapter)), OWED, "adapter took exactly the payout");
        assertEq(chNvda - nvda.balanceOf(address(ch)), OWED);
        assertEq(nvda.allowance(address(ch), address(adapter)), 0, "approval zeroed");
        assertEq(adapter.calls(), 1);
        assertEq(adapter.lastAsset(), address(nvda));
        assertEq(adapter.lastAmountIn(), OWED);
        assertEq(adapter.lastMinOut(), MIN_OUT, "minOut = amount * P / 1e18 * (1e4 - slippage) / 1e4");
        assertEq(adapter.lastTo(), address(ch), "USDG comes to the Clearinghouse (sweep contracts-c30)");
        assertEq(usdg.balanceOf(address(ch)), chUsdg, "which sends all of it on to the holder");
        assertEq(ch.accruedFees(address(nvda)), 2.5e15, "fee still accrues in kind");
    }

    /// @dev Same through redeemBatch, where the conversion is a self-call two frames below the guard.
    function test_convert_success_insideBatch() public {
        address[] memory holders = new address[](1);
        holders[0] = bob;
        vm.prank(keeper);
        assertEq(ch.redeemBatch(callId, holders), 1);
        assertEq(usdg.balanceOf(bob), ACTOR_USDG + VALUE, "batch conversion pays USDG too");
        assertEq(adapter.calls(), 1);
    }

    function test_convert_success_toLedger() public {
        vm.prank(bob);
        ch.setPayoutToLedger(true);
        uint256 chUsdg = usdg.balanceOf(address(ch));
        vm.expectEmit(true, true, false, true, address(ch));
        emit IClearinghouse.Redeemed(callId, bob, address(ch), 100, address(usdg), VALUE, OWED, true);
        (uint256 paid, bool inUsdg) = _redeem(callId, bob);
        assertTrue(inUsdg);
        assertEq(paid, VALUE);
        assertEq(adapter.lastTo(), address(ch), "USDG comes to the Clearinghouse");
        assertEq(ch.free(bob, address(usdg)), VALUE, "and is credited as USDG");
        assertEq(usdg.balanceOf(address(ch)) - chUsdg, VALUE);
        assertEq(usdg.balanceOf(bob), ACTOR_USDG);
    }

    /// @dev A rate 50 bps under fair value is inside the 100 bps bound.
    function test_convert_withinSlippageAccepted() public {
        adapter.setRate(P, 9_950);
        (uint256 paid, bool inUsdg) = _redeem(callId, bob);
        assertTrue(inUsdg);
        assertEq(paid, 9_328_125);
        assertGe(paid, MIN_OUT);
    }

    /*//////////////////////////////////////////////////////////////
                           FAILURES -> IN KIND
    //////////////////////////////////////////////////////////////*/

    /// @dev An adapter that happily delivers a bad rate (no minOut check of its own): the Clearinghouse's check
    ///      rejects it and everything the adapter did is rolled back.
    function test_convert_belowMinOut_paysInKind() public {
        adapter.setRate(P, 9_899);
        assertLt(adapter.quote(OWED), MIN_OUT);
        uint256 adapterUsdg = usdg.balanceOf(address(adapter));
        _assertInKind();
        assertEq(usdg.balanceOf(address(adapter)), adapterUsdg, "the bad swap was undone");
        assertEq(adapter.calls(), 0, "including its bookkeeping");
    }

    function test_convert_adapterEnforcesMinOut_paysInKind() public {
        adapter.setRate(P, 5_000);
        adapter.setEnforceMinOut(true);
        _assertInKind();
    }

    function test_convert_adapterReverts_paysInKind() public {
        adapter.setMode(MockPayoutAdapter.Mode.Revert);
        _assertInKind();
    }

    function test_convert_adapterPullsWithoutPaying_paysInKind() public {
        adapter.setMode(MockPayoutAdapter.Mode.PullNoPay);
        _assertInKind();
    }

    function test_convert_adapterPullsPartially_paysInKind() public {
        adapter.setMode(MockPayoutAdapter.Mode.PullPartial);
        _assertInKind();
    }

    function test_convert_adapterOutOfUsdg_paysInKind() public {
        uint256 all = usdg.balanceOf(address(adapter));
        vm.prank(address(adapter));
        assertTrue(usdg.transfer(carol, all));
        _assertInKind();
    }

    /// @dev USDG frozen for the holder: the delivery of the swap's USDG reverts, and with it the swap; the Stock Token
    ///      payout goes through.
    function test_convert_holderFrozenForUsdg_paysInKind() public {
        usdg.freeze(bob);
        _assertInKind();
    }

    /// @dev An adapter address with no code: the try/catch-wrapped self-call reverts and the payout is in kind.
    function test_convert_codelessAdapter_paysInKind() public {
        vm.prank(admin);
        ch.setPayoutAdapter(makeAddr("eoa-adapter"), 100);
        (uint256 paid, bool inUsdg) = _redeem(callId, bob);
        assertFalse(inUsdg);
        assertEq(paid, OWED);
        assertEq(nvda.balanceOf(bob), ACTOR_SHARES + OWED);
    }

    /// @dev Conversion fails and the Stock Token also refuses the holder: credited in kind to the ledger.
    function test_convert_failsAndHolderBlocked_creditsLedger() public {
        adapter.setMode(MockPayoutAdapter.Mode.Revert);
        nvda.blockAccount(bob);
        vm.expectEmit(true, true, false, true, address(ch));
        emit IClearinghouse.Redeemed(callId, bob, address(ch), 100, address(nvda), OWED, OWED, true);
        (uint256 paid, bool inUsdg) = _redeem(callId, bob);
        assertFalse(inUsdg);
        assertEq(paid, OWED);
        assertEq(ch.free(bob, address(nvda)), OWED);
    }

    /*//////////////////////////////////////////////////////////////
                           MALICIOUS ADAPTER
    //////////////////////////////////////////////////////////////*/

    /// @dev The adapter tries to pull more than the payout before and after the swap: every extra pull fails, the
    ///      conversion itself succeeds, and the Clearinghouse loses exactly the payout. The adapter also reports a
    ///      30 bps route fee and pays the holder the least the Clearinghouse accepts: what it captures is exactly
    ///      maxPayoutSlippageBps + routeFee of the payout's value, and one bps more is refused (INTERFACE_VERSION 6).
    function test_convert_stealAttemptTakesNoMore() public {
        adapter.setMode(MockPayoutAdapter.Mode.StealExtra);
        adapter.setRouteFee(MockPayoutAdapter.FeeMode.Word, FEE_30);
        adapter.setRate(P, 10_000 - SLIPPAGE_BPS - FEE_30);
        uint256 snap = vm.snapshotState();
        adapter.setRate(P, 10_000 - SLIPPAGE_BPS - FEE_30 - 1);
        _assertInKind();
        vm.revertToState(snap);

        uint256 chNvda = nvda.balanceOf(address(ch));
        (uint256 paid, bool inUsdg) = _redeem(callId, bob);
        assertTrue(inUsdg);
        assertEq(paid, MIN_OUT_FEE_30, "paid the floor");
        assertEq(adapter.lastMinOut(), MIN_OUT_FEE_30);
        assertLe(VALUE - paid, VALUE * (SLIPPAGE_BPS + FEE_30) / V2Constants.BPS, "captured <= bound + route fee");
        assertEq(adapter.stealAttempts(), 3);
        assertFalse(adapter.stealSucceeded(), "no pull beyond the approval");
        assertEq(chNvda - nvda.balanceOf(address(ch)), OWED, "lost exactly the payout");
        assertEq(nvda.allowance(address(ch), address(adapter)), 0);

        // Everyone else is still whole.
        _redeem(_short(callId), alice);
        _redeem(_short(callId), carol);
        vm.prank(carol);
        ch.setPayoutInKind(true);
        _redeem(callId, carol);
        assertEq(ch.locked(callId), 0);
        assertEq(
            nvda.balanceOf(address(ch)),
            ch.accruedFees(address(nvda)) + ch.locked(otmId) + ch.locked(dustId),
            "fees and the other series fully backed"
        );
    }

    /// @dev From inside swapToUsdg the adapter calls back into the Clearinghouse. Guarded entry points revert on the
    ///      guard; the two self-call-only functions revert NotAuthorized. The conversion still completes.
    function test_convert_reentryFromAdapterBlocked() public {
        address[] memory holders = new address[](1);
        holders[0] = carol;
        bytes[6] memory attacks = [
            abi.encodeCall(ch.redeem, (callId, carol)),
            abi.encodeCall(ch.redeemBatch, (callId, holders)),
            abi.encodeCall(ch.withdraw, (address(nvda), 1, address(adapter))),
            abi.encodeCall(ch.sweepFees, (address(nvda))),
            abi.encodeCall(ch.convertPayout, (address(nvda), 1e18, 0, address(adapter))),
            abi.encodeCall(ch.batchRedeemOne, (callId, carol, address(adapter)))
        ];
        bytes4[6] memory expected = [
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
            V2Errors.NotAuthorized.selector,
            V2Errors.NotAuthorized.selector
        ];
        adapter.setMode(MockPayoutAdapter.Mode.Reenter);
        for (uint256 i; i < attacks.length; ++i) {
            uint256 snap = vm.snapshotState();
            adapter.setReenter(address(ch), attacks[i]);
            (, bool inUsdg) = _redeem(callId, bob);
            assertTrue(inUsdg, "conversion completed");
            assertFalse(adapter.reenterSucceeded(), "re-entry failed");
            assertEq(bytes4(adapter.reenterRevertData()), expected[i]);
            assertEq(ch.balanceOf(carol, callId), 50, "carol untouched");
            vm.revertToState(snap);
        }
    }

    /// @dev The adapter keeps the whole payout and pays nothing of its own: during the swap it has a third party push
    ///      the holder's own USDG to the holder (an expired bid pruned, a rewards claim; HolderRefundEscrow stands in
    ///      for both). Measured at the holder's wallet that rise passed for the conversion and the adapter kept the
    ///      Stock Tokens (sweep contracts-c30). The USDG is measured where nobody else can add to it, at the
    ///      Clearinghouse, so the payout falls back to in kind and the refund is undone with the swap.
    function test_convert_adapterPayingWithTheHoldersOwnUsdg_paysInKind() public {
        HolderRefundEscrow escrow = new HolderRefundEscrow(IERC20(address(usdg)), bob);
        vm.prank(bob);
        assertTrue(usdg.transfer(address(escrow), VALUE));
        adapter.setMode(MockPayoutAdapter.Mode.Reenter);
        adapter.setReenter(address(escrow), abi.encodeCall(HolderRefundEscrow.refund, ()));
        adapter.setRate(P, 0);

        _assertInKind();
        assertEq(usdg.balanceOf(address(escrow)), VALUE, "the refund was undone with the swap");
    }

    function test_selfCallsRejectOutsiders() public {
        vm.prank(bob);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        ch.convertPayout(address(nvda), 1e18, 0, bob);
        vm.prank(address(adapter));
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        ch.convertPayout(address(nvda), 1e18, 0, address(adapter));
        vm.prank(keeper);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        ch.batchRedeemOne(callId, bob, keeper);
    }

    /*//////////////////////////////////////////////////////////////
                  ROUTE FEE (INTERFACE_VERSION 6)
    //////////////////////////////////////////////////////////////*/

    /// @dev minOut = value * (BPS - (maxPayoutSlippageBps + routeFee)) / BPS, and the adapter is asked for the fee of
    ///      the payout's asset.
    function test_floor_addsRouteFee() public {
        adapter.setRouteFee(MockPayoutAdapter.FeeMode.Word, FEE_30);
        adapter.setRate(P, 9_880); // 120 bps short: outside the 100 bps bound, inside bound + fee
        vm.expectCall(address(adapter), abi.encodeCall(IPayoutAdapter.routeFeeBps, (address(nvda))), 1);
        (uint256 paid, bool inUsdg) = _redeem(callId, bob);
        assertTrue(inUsdg, "converted above the fee-aware floor");
        assertEq(paid, 9_262_500);
        assertEq(adapter.lastMinOut(), MIN_OUT_FEE_30, "minOut = value * (1e4 - 100 - 30) / 1e4");
        assertEq(MIN_OUT_FEE_30, VALUE * (10_000 - 130) / 10_000);
    }

    /// @dev The launch bound, 30 bps, over a 0.30 % pool's 30 bps fee: a conversion 55 bps short of value converts,
    ///      61 bps short pays in kind. Without the fee the 55 bps conversion would have paid in kind too.
    function test_floor_launchBoundAboveA30BpsRoute() public {
        vm.prank(admin);
        ch.setPayoutAdapter(address(adapter), 30);
        uint256 floor60 = VALUE * (10_000 - 60) / 10_000;
        assertEq(floor60, 9_318_750);

        uint256 snap = vm.snapshotState();
        adapter.setRate(P, 9_945); // 55 bps short
        assertEq(adapter.quote(OWED), 9_323_437);
        _assertInKind(); // route fee 0: the floor is value less 30 bps
        vm.revertToState(snap);

        adapter.setRouteFee(MockPayoutAdapter.FeeMode.Word, FEE_30);
        snap = vm.snapshotState();
        adapter.setRate(P, 9_945);
        (uint256 paid, bool inUsdg) = _redeem(callId, bob);
        assertTrue(inUsdg, "55 bps short converts above a 30 bps route");
        assertEq(paid, 9_323_437);
        assertEq(adapter.lastMinOut(), floor60);
        vm.revertToState(snap);

        adapter.setRate(P, 9_939); // 61 bps short
        assertLt(adapter.quote(OWED), floor60);
        _assertInKind();
    }

    /// @dev A route fee read that reverts, returns one byte or burns its gas counts as 0: the floor is the bound alone
    ///      (the tighter floor), so a 101 bps shortfall that a 30 bps route fee would allow pays in kind, and a
    ///      shortfall inside the bound still converts at minOut = value less the bound.
    function test_floor_badRouteFeeReadCountsAsZero() public {
        MockPayoutAdapter.FeeMode[3] memory modes =
            [MockPayoutAdapter.FeeMode.Revert, MockPayoutAdapter.FeeMode.Short, MockPayoutAdapter.FeeMode.BurnGas];
        for (uint256 i; i < modes.length; ++i) {
            uint256 snap = vm.snapshotState();
            adapter.setRouteFee(modes[i], FEE_30);
            adapter.setRate(P, 9_899);
            _assertInKind();
            vm.revertToState(snap);

            snap = vm.snapshotState();
            adapter.setRouteFee(modes[i], FEE_30);
            adapter.setRate(P, 9_900);
            (uint256 paid, bool inUsdg) = _redeem(callId, bob);
            assertTrue(inUsdg, "still converts inside the bound");
            assertEq(paid, MIN_OUT);
            assertEq(adapter.lastMinOut(), MIN_OUT, "route fee read as 0");
            vm.revertToState(snap);
        }
    }

    /// @dev The one-byte answer is really short (the mock is not accidentally ABI-encoding a word).
    function test_floor_shortAnswerIsOneByte() public {
        adapter.setRouteFee(MockPayoutAdapter.FeeMode.Short, FEE_30);
        (bool ok, bytes memory ret) =
            address(adapter).staticcall(abi.encodeCall(IPayoutAdapter.routeFeeBps, (address(nvda))));
        assertTrue(ok);
        assertEq(ret.length, 1);
    }

    /// @dev An adapter that burns gas in routeFeeBps costs the redemption at most the 30_000 gas the read is given.
    function test_floor_gasBurningRouteFeeCostsAtMostTheCap() public {
        vm.prank(admin);
        ch.setKeeperRewards(address(0));
        uint256 snap = vm.snapshotState();
        adapter.setRouteFee(MockPayoutAdapter.FeeMode.Word, FEE_30);
        vm.prank(keeper);
        uint256 honest = gasleft();
        ch.redeem(callId, bob);
        honest -= gasleft();
        vm.revertToState(snap);

        adapter.setRouteFee(MockPayoutAdapter.FeeMode.BurnGas, FEE_30);
        vm.prank(keeper);
        uint256 burning = gasleft();
        (, bool inUsdg) = ch.redeem(callId, bob);
        burning -= gasleft();
        console2.log("gas: redeem converted, honest routeFeeBps / gas-burning routeFeeBps", honest, burning);
        assertTrue(inUsdg, "the redemption still converts");
        assertGt(burning, honest);
        assertLe(burning - honest, 30_000, "the read costs at most its gas cap");
    }

    /// @dev An answer above MAX_ROUTE_FEE_BPS counts as 100: a lying adapter reporting 5000 bps (or a word that does
    ///      not fit uint16) moves the floor to value less 200 bps, not 5100.
    function test_floor_routeFeeClampedToMax() public {
        assertEq(V2Constants.MAX_ROUTE_FEE_BPS, 100);
        uint256 floor200 = VALUE * (10_000 - SLIPPAGE_BPS - V2Constants.MAX_ROUTE_FEE_BPS) / 10_000;
        assertEq(floor200, 9_187_500);
        uint256[2] memory words = [uint256(5000), type(uint256).max];
        for (uint256 i; i < words.length; ++i) {
            uint256 snap = vm.snapshotState();
            adapter.setRouteFee(MockPayoutAdapter.FeeMode.Word, words[i]);
            adapter.setRate(P, 9_799); // 201 bps short
            _assertInKind();
            vm.revertToState(snap);

            snap = vm.snapshotState();
            adapter.setRouteFee(MockPayoutAdapter.FeeMode.Word, words[i]);
            adapter.setRate(P, 9_800);
            (uint256 paid, bool inUsdg) = _redeem(callId, bob);
            assertTrue(inUsdg);
            assertEq(paid, floor200);
            assertEq(adapter.lastMinOut(), floor200, "fee clamped to MAX_ROUTE_FEE_BPS");
            vm.revertToState(snap);
        }
    }

    /// @dev bound + route fee is capped at MAX_PAYOUT_SLIPPAGE_CEIL_BPS: 250 + 100 -> 300.
    function test_floor_totalCappedAtCeiling() public {
        vm.prank(admin);
        ch.setPayoutAdapter(address(adapter), 250);
        adapter.setRouteFee(MockPayoutAdapter.FeeMode.Word, 100);
        uint256 floor300 = VALUE * (10_000 - V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS) / 10_000;
        assertEq(floor300, 9_093_750);

        uint256 snap = vm.snapshotState();
        adapter.setRate(P, 9_699); // 301 bps short
        _assertInKind();
        vm.revertToState(snap);

        adapter.setRate(P, 9_700);
        (uint256 paid, bool inUsdg) = _redeem(callId, bob);
        assertTrue(inUsdg);
        assertEq(paid, floor300);
        assertEq(adapter.lastMinOut(), floor300, "350 bps capped at 300");
    }

    /// @dev Holders who chose in kind, shorts and OTM longs never trigger the route fee read, so a gas-burning adapter
    ///      cannot touch them.
    function test_floor_notReadWithoutAConversion() public {
        adapter.setRouteFee(MockPayoutAdapter.FeeMode.BurnGas, FEE_30);
        vm.expectCall(address(adapter), abi.encodeCall(IPayoutAdapter.routeFeeBps, (address(nvda))), 0);
        vm.prank(bob);
        ch.setPayoutInKind(true);
        (uint256 paid, bool inUsdg) = _redeem(callId, bob);
        assertFalse(inUsdg);
        assertEq(paid, OWED);
        assertEq(nvda.balanceOf(bob), ACTOR_SHARES + OWED);
        _redeem(_short(callId), alice);
        _redeem(otmId, bob);
        assertEq(adapter.calls(), 0);
    }

    /// @dev For any bound, any route fee answer and any rate: the payout converts exactly when the adapter's output
    ///      meets value * (1e4 - min(bound + min(fee, 100), 300)) / 1e4, and what the adapter keeps is never more than
    ///      min(bound + MAX_ROUTE_FEE_BPS, MAX_PAYOUT_SLIPPAGE_CEIL_BPS) of the value (rounded up: the floor itself
    ///      rounds down, by less than one base unit).
    function testFuzz_floor_captureBounded(uint16 slippageBps, uint256 feeWord, uint256 rateBps) public {
        // casting to 'uint16' is safe because the value is bounded to [0, 300]
        // forge-lint: disable-next-line(unsafe-typecast)
        slippageBps = uint16(bound(slippageBps, 0, V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS));
        rateBps = bound(rateBps, 9_500, 10_000);
        vm.prank(admin);
        ch.setPayoutAdapter(address(adapter), slippageBps);
        adapter.setRouteFee(MockPayoutAdapter.FeeMode.Word, feeWord);
        adapter.setRate(P, rateBps);

        uint256 fee = feeWord > V2Constants.MAX_ROUTE_FEE_BPS ? V2Constants.MAX_ROUTE_FEE_BPS : feeWord;
        uint256 total = uint256(slippageBps) + fee;
        if (total > V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS) total = V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS;
        uint256 floor = VALUE * (10_000 - total) / 10_000;
        uint256 quoted = adapter.quote(OWED);

        (uint256 paid, bool inUsdg) = _redeem(callId, bob);
        assertEq(inUsdg, quoted >= floor, "converts iff the output meets the fee-aware floor");
        if (inUsdg) {
            assertEq(paid, quoted);
            assertEq(adapter.lastMinOut(), floor);
            uint256 worst = uint256(slippageBps) + V2Constants.MAX_ROUTE_FEE_BPS;
            if (worst > V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS) worst = V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS;
            assertLe(VALUE - paid, (VALUE * worst + 9_999) / 10_000, "captured <= min(bound + 100, 300) bps");
            assertLe(VALUE - paid, (VALUE * total + 9_999) / 10_000, "captured <= bound + clamped fee");
        } else {
            assertEq(paid, OWED);
            assertEq(nvda.balanceOf(bob), ACTOR_SHARES + OWED);
        }
    }

    /*//////////////////////////////////////////////////////////////
               FLOOR PRICE: THE CURRENT SPOT (sweep contracts-c01)
    //////////////////////////////////////////////////////////////*/

    /// @dev The sandwich: the market moved 5 % above the settlement price after the window, and a third party pushes
    ///      the pool back down to P inside its redeeming transaction. A floor valued at P alone accepts that fill and
    ///      the caller keeps the move; valued at the fresh spot it misses the floor and pays in kind. At a fill near
    ///      the spot the payout still converts, with minOut = value at the spot less the bound.
    function test_floorPrice_freshSpotAboveSettlement_valuesThePayoutAtSpot() public {
        oracle.setSpot(address(nvda), true, SPOT_UP, block.timestamp);
        adapter.setRate(P, 10_000); // the pool pushed back to the settlement price
        uint256 snap = vm.snapshotState();
        _assertInKind();
        vm.revertToState(snap);

        adapter.setRate(SPOT_UP, 9_950); // an honest fill 50 bps under the spot
        (uint256 paid, bool inUsdg) = _redeem(callId, bob);
        assertTrue(inUsdg, "converts near the spot");
        assertEq(adapter.lastMinOut(), MIN_OUT_AT_SPOT_UP, "minOut = value at the spot less the bound");
        assertEq(paid, VALUE_AT_SPOT_UP * 9_950 / 10_000);
        assertEq(MIN_OUT_AT_SPOT_UP, VALUE_AT_SPOT_UP * 9_900 / 10_000);
    }

    /// @dev A fresh spot below the settlement price leaves the floor at P: the holder is never promised less.
    function test_floorPrice_freshSpotBelowSettlement_keepsTheSettlementPrice() public {
        oracle.setSpot(address(nvda), true, 230_000_000, block.timestamp);
        adapter.setRate(P, 9_900);
        (uint256 paid, bool inUsdg) = _redeem(callId, bob);
        assertTrue(inUsdg);
        assertEq(paid, MIN_OUT);
        assertEq(adapter.lastMinOut(), MIN_OUT);
    }

    /// @dev INTERFACE_VERSION 7 (owner sign-off c01): freshness is whatever the oracle itself accepts, the market's
    ///      spotMaxAge (25 h at launch), with no extra bound in the Clearinghouse. An ok spot sets the floor however
    ///      old the observation is; only a not-ok or zero answer is ignored.
    function test_floorPrice_okSpotSetsTheFloorAtAnyAge() public {
        uint256[3] memory ages = [uint256(1 hours), 25 hours, 4 days];
        for (uint256 i; i < ages.length; ++i) {
            uint256 snap = vm.snapshotState();
            oracle.setSpot(address(nvda), true, SPOT_UP, block.timestamp - ages[i]);
            adapter.setRate(P, 10_000);
            _assertInKind();
            vm.revertToState(snap);
        }

        oracle.setSpot(address(nvda), true, 0, block.timestamp);
        (uint256 paid, bool inUsdg) = _redeem(callId, bob);
        assertTrue(inUsdg, "a zero spot is ignored, so the floor is P");
        assertEq(paid, VALUE);
        assertEq(adapter.lastMinOut(), MIN_OUT);
    }

    /// @notice The floor's freshness bound IS the market's registry `spotMaxAge`, and nothing tighter.
    /// @dev Owner sign-off c01 (DECISIONS-2026-09-17 §7): the Clearinghouse used to insist on a spot under an hour
    ///      old on top of whatever the oracle accepted, which the real feed cadence (ops-c13) would rarely satisfy, so
    ///      automated redemptions paid in kind. v7 takes the oracle's own answer: a reading inside the market's
    ///      spotMaxAge -- 90,000 s, 25 h, at launch -- is ok and sets the floor; one past it is not ok and is ignored,
    ///      and the floor falls back to the settlement price. The staleness error a 25 h reading admits is bounded by
    ///      the feed's own 0.5 % deviation threshold, and the floor is never below the settlement price either way.
    ///      This suite's oracle is the mock, so `ok` is set here to stand for the decision the real SettlementOracle
    ///      makes from `spotMaxAge`; {SettlementOracleTest} is where that decision itself is pinned.
    function test_floorPrice_freshnessIsTheMarketsSpotMaxAgeAndNothingTighter() public {
        uint256 launchSpotMaxAge = 90_000;
        assertGt(launchSpotMaxAge, 1 hours, "the launch bound is far looser than the hour v6 applied");

        // Inside spotMaxAge the oracle answers ok, so the floor is max(P, spot) however old the print is.
        uint256 snap = vm.snapshotState();
        oracle.setSpot(address(nvda), true, SPOT_UP, block.timestamp - launchSpotMaxAge);
        adapter.setRate(P, 10_000);
        _assertInKind();
        vm.revertToState(snap);

        // One second past it the oracle answers not ok, and the floor is the settlement price alone.
        oracle.setSpot(address(nvda), false, SPOT_UP, block.timestamp - launchSpotMaxAge - 1);
        (uint256 paid, bool inUsdg) = _redeem(callId, bob);
        assertTrue(inUsdg, "a not-ok spot leaves the floor at P, and the payout still converts inside the grace");
        assertEq(paid, VALUE);
        assertEq(adapter.lastMinOut(), MIN_OUT, "the floor is P, not the stale spot");
    }

    /// @dev Without an ok spot (not ok, zero, a reverting oracle), a third party converts on P alone only
    ///      within 30 minutes of expiry. Later, its redemption pays in kind, directly and inside a batch, while the
    ///      holder itself or its operator still converts on P, and a fresh spot restores the conversion for anyone.
    function test_floorPrice_noFreshSpot_lateThirdPartyPaysInKind() public {
        uint40 expiry = FRI_2026_09_18;
        for (uint256 mode; mode < 3; ++mode) {
            uint256 snap = vm.snapshotState();
            if (mode == 0) oracle.setSpot(address(nvda), false, 0, 0);
            if (mode == 1) oracle.setSpot(address(nvda), true, 0, block.timestamp);
            if (mode == 2) oracle.setTrySpotReverts(true);

            uint256 inner = vm.snapshotState();
            vm.warp(expiry + 30 minutes);
            (, bool inUsdg) = _redeem(callId, bob);
            assertTrue(inUsdg, "a third party converts on P inside the grace");
            assertEq(adapter.lastMinOut(), MIN_OUT);
            vm.revertToState(inner);

            vm.warp(expiry + 30 minutes + 1);
            inner = vm.snapshotState();
            _assertInKind();
            vm.revertToState(inner);

            inner = vm.snapshotState();
            address[] memory holders = new address[](1);
            holders[0] = bob;
            vm.prank(keeper);
            assertEq(ch.redeemBatch(callId, holders), 1);
            assertEq(nvda.balanceOf(bob), ACTOR_SHARES + OWED, "in kind inside a batch too");
            assertEq(adapter.calls(), 0);
            vm.revertToState(inner);

            inner = vm.snapshotState();
            vm.prank(bob);
            (, inUsdg) = ch.redeem(callId, bob);
            assertTrue(inUsdg, "the holder converts on P");
            assertEq(adapter.lastMinOut(), MIN_OUT);
            vm.revertToState(inner);

            inner = vm.snapshotState();
            vm.prank(bob);
            ch.setOperator(keeper, true);
            (, inUsdg) = _redeem(callId, bob);
            assertTrue(inUsdg, "the holder's operator converts on P");
            vm.revertToState(inner);

            if (mode != 2) {
                oracle.setSpot(address(nvda), true, 230_000_000, block.timestamp);
                (, inUsdg) = _redeem(callId, bob);
                assertTrue(inUsdg, "a fresh spot lets anyone convert");
                assertEq(adapter.lastMinOut(), MIN_OUT);
            }
            vm.revertToState(snap);
        }
    }

    /// @dev Redemption needs only the stored settlement: an oracle that burns every unit of gas it is given costs a
    ///      converted redemption at most the 150_000 gas the spot read is capped at, and counts as no spot.
    function test_floorPrice_gasBurningOracleCostsAtMostTheCap() public {
        vm.prank(admin);
        ch.setKeeperRewards(address(0));
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        uint256 honest = gasleft();
        ch.redeem(callId, bob);
        honest -= gasleft();
        vm.revertToState(snap);

        vm.etch(address(oracle), hex"5b5f56"); // JUMPDEST PUSH0 JUMP: loops until out of gas
        vm.prank(keeper);
        uint256 burning = gasleft();
        (, bool inUsdg) = ch.redeem(callId, bob);
        burning -= gasleft();
        console2.log("gas: redeem converted, honest oracle / gas-burning oracle", honest, burning);
        assertTrue(inUsdg, "converts on P inside the grace");
        assertEq(adapter.lastMinOut(), MIN_OUT);
        assertLe(burning - honest, 150_000, "the read costs at most its gas cap");
    }

    /// @dev For any spot, age and fill: the payout converts exactly when the fill meets the bound below the value at
    ///      the higher of P and the spot. The age never changes the answer (INTERFACE_VERSION 7): the oracle decides
    ///      what counts as ok, and this mock reports ok for every age it is given.
    function testFuzz_floorPrice_convertsIffTheFillMeetsTheHigherPrice(uint256 spot, uint256 age, uint256 rateBps)
        public
    {
        spot = bound(spot, 1, 1_000e6);
        age = bound(age, 0, 4 days);
        rateBps = bound(rateBps, 9_000, 12_000);
        oracle.setSpot(address(nvda), true, spot, block.timestamp - age);
        adapter.setRate(P, rateBps);

        uint256 price = spot > P ? spot : P;
        uint256 floor = OWED * price / 1e18 * (10_000 - SLIPPAGE_BPS) / 10_000;
        uint256 quoted = adapter.quote(OWED);
        (uint256 paid, bool inUsdg) = _redeem(callId, bob);
        assertEq(inUsdg, quoted >= floor, "converts iff the fill meets the floor at the higher price");
        if (inUsdg) {
            assertEq(paid, quoted);
            assertEq(adapter.lastMinOut(), floor);
        } else {
            assertEq(nvda.balanceOf(bob), ACTOR_SHARES + OWED);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          PATHS THAT NEVER CONVERT
    //////////////////////////////////////////////////////////////*/

    function test_noConversion_inKindPreference() public {
        vm.prank(bob);
        ch.setPayoutInKind(true);
        (uint256 paid, bool inUsdg) = _redeem(callId, bob);
        assertFalse(inUsdg);
        assertEq(paid, OWED);
        assertEq(adapter.calls(), 0);
    }

    function test_noConversion_noAdapter() public {
        vm.prank(admin);
        ch.setPayoutAdapter(address(0), 0);
        (, bool inUsdg) = _redeem(callId, bob);
        assertFalse(inUsdg);
        assertEq(nvda.balanceOf(bob), ACTOR_SHARES + OWED);
    }

    function test_noConversion_shortsAndOtm() public {
        _redeem(_short(callId), alice);
        assertEq(adapter.calls(), 0, "a call short is paid in kind");
        (uint256 paid, bool inUsdg) = _redeem(otmId, bob);
        assertEq(paid, 0);
        assertFalse(inUsdg);
        assertEq(adapter.calls(), 0, "an OTM long has nothing to convert");
    }

    /// @dev A payout so small that minOut rounds to 0 is never sent to the adapter (a zero minOut accepts anything).
    function test_noConversion_dustPayout() public {
        assertEq(ch.series(dustId).longPayoutPerUnit, 37_500_000);
        (uint256 paid, bool inUsdg) = _redeem(dustId, bob);
        assertFalse(inUsdg);
        assertEq(paid, 37_500_000);
        assertEq(adapter.calls(), 0);
    }

    function test_gas_redeemWithConversion() public {
        vm.prank(admin);
        ch.setKeeperRewards(address(0));
        vm.prank(keeper);
        uint256 g = gasleft();
        ch.redeem(callId, bob);
        g -= gasleft();
        console2.log("gas: redeem call long converted to USDG (mock adapter), no bounty", g);
        assertEq(usdg.balanceOf(bob), ACTOR_USDG + VALUE);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _assertInKind() internal {
        uint256 bobUsdg = usdg.balanceOf(bob);
        vm.recordLogs();
        (uint256 paid, bool inUsdg) = _redeem(callId, bob);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertFalse(inUsdg, "fell back to in kind");
        assertEq(paid, OWED);
        assertEq(nvda.balanceOf(bob), ACTOR_SHARES + OWED, "Stock Tokens delivered");
        assertEq(usdg.balanceOf(bob), bobUsdg, "no USDG");
        assertEq(nvda.balanceOf(address(adapter)), 0, "adapter kept nothing");
        assertEq(nvda.allowance(address(ch), address(adapter)), 0, "no approval left");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(ch) && logs[i].topics[0] == IClearinghouse.Redeemed.selector) {
                (address to,, address asset, uint256 amount, uint256 inKind, bool toLedger) =
                    abi.decode(logs[i].data, (address, uint64, address, uint256, uint256, bool));
                assertEq(to, bob);
                assertEq(asset, address(nvda));
                assertEq(amount, OWED);
                assertEq(inKind, OWED);
                assertFalse(toLedger);
                found = true;
            }
        }
        assertTrue(found, "Redeemed logged");
    }
}
