// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ClearinghouseTestBase} from "./ClearinghouseBase.t.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {IFundingSource} from "../../../src/v2/interfaces/IFundingSource.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {MockFundingSource} from "../../../src/v2/mocks/MockFundingSource.sol";

/// @notice The just-in-time funding double, tested alone — no OrderBook. C8-13B argues the pre-fund stage against
///         these behaviours, so they are pinned here first.
/// @dev EVERY DELIVERY ASSERTION IS A `free` DELTA, never a return value. {IFundingSource} states twice
///      (src/v2/interfaces/IFundingSource.sol:15-21, :39-43) that the book measures the source's Clearinghouse
///      `free` delta and never the call's answer, so a self-test that trusted the return would be proving
///      something the book will never read. The Garbage mode exists precisely to make a return-trusting caller
///      wrong, and it would pass a return-based test.
contract MockFundingSourceTest is ClearinghouseTestBase {
    MockFundingSource internal src;

    /// @dev A caller of {IFundingSource.fund} capped exactly as the book caps it, so the modes are judged under
    ///      the real budget rather than under Foundry's whole-test gas.
    function _fund(address asset, uint256 amount) private returns (bool ok) {
        bytes memory data = abi.encodeCall(IFundingSource.fund, (asset, amount));
        // V2Constants.FUNDING_GAS = 400_000 (src/v2/interfaces/V2Constants.sol:121).
        (ok,) = address(src).call{gas: V2Constants.FUNDING_GAS}(data);
    }

    /// @dev {IFundingSource.fundable} read exactly as the book reads it: a gas-capped staticcall that copies ONE
    ///      word and treats anything shorter as a failure. Mirrors OrderBook._rebateBps (src/v2/OrderBook.sol:1050-1063)
    ///      rather than restating the rule. V2Constants.FUNDABLE_READ_GAS = 50_000 (V2Constants.sol:124).
    function _fundable(address asset) private view returns (bool ok, uint256 value) {
        address target = address(src);
        bytes memory data = abi.encodeCall(IFundingSource.fundable, (asset));
        uint256 cap = V2Constants.FUNDABLE_READ_GAS;
        assembly ("memory-safe") {
            ok := staticcall(cap, target, add(data, 0x20), mload(data), 0x00, 0x20)
            ok := and(ok, iszero(lt(returndatasize(), 0x20)))
            value := mload(0x00)
        }
    }

    function setUp() public override {
        super.setUp();
        src = new MockFundingSource(IClearinghouse(address(ch)));
        src.approveClearinghouse(address(usdg));
        src.approveClearinghouse(address(nvda));
        usdg.mint(address(src), 1_000_000e6);
        nvda.mint(address(src), 1_000e18);
        vm.label(address(src), "MockFundingSource");
    }

    /*//////////////////////////////////////////////////////////////
                              DELIVERY
    //////////////////////////////////////////////////////////////*/

    function test_honest_deliversTheWholeAmountIntoItsOwnLedger() public {
        uint256 before = ch.free(address(src), address(usdg));
        assertTrue(_fund(address(usdg), 10_000e6), "honest fund succeeds");
        assertEq(ch.free(address(src), address(usdg)) - before, 10_000e6, "delta is the whole amount");
        // Its OWN account, never the book's, the taker's or a third party's (IFundingSource.sol:27-29).
        assertEq(ch.free(address(this), address(usdg)), 0, "nothing landed on the caller");
    }

    function test_partial_deliversStrictlyLessAndTheDeltaSaysSo() public {
        src.setMode(MockFundingSource.Mode.Partial);
        src.setDeliverBps(2_500);
        uint256 before = ch.free(address(src), address(usdg));
        assertTrue(_fund(address(usdg), 10_000e6), "a partial delivery is not a failure");
        uint256 delivered = ch.free(address(src), address(usdg)) - before;
        assertEq(delivered, 2_500e6, "25 % of the ask");
        assertLt(delivered, 10_000e6, "strictly less than asked: the case the feature must survive");
    }

    function test_over_deliversStrictlyMoreAndDoesNotRevert() public {
        src.setMode(MockFundingSource.Mode.Over);
        uint256 before = ch.free(address(src), address(nvda));
        assertTrue(_fund(address(nvda), 5e18), "over-delivery is not a failure");
        uint256 delivered = ch.free(address(src), address(nvda)) - before;
        assertGt(delivered, 5e18, "strictly more than asked");
        assertEq(delivered, 10e18, "twice the ask, since the source holds it");
    }

    /// @notice F-CT3-01 (ops/audit/CT3-ORACLE-MOCKS-LEGACY.md:37-77). Every other mode here either deposits >= 0
    ///         or reverts, so the shared double could not express the ONE input {OrderBook._preFund} saturates
    ///         for: a `fund` that returns normally having LOWERED its own `free`. Drain is that input.
    /// @dev The delta is asserted as a DROP, not with the `- before` subtraction every other test here uses --
    ///      that subtraction is exactly what underflows, and writing it that way would make this test panic
    ///      rather than measure. That is the same arithmetic the book must not do, one layer down.
    function test_drain_returnsNormallyHavingLoweredItsOwnFree() public {
        src.setMode(MockFundingSource.Mode.Drain);
        vm.prank(address(src));
        ch.deposit(address(usdg), 5_000e6, address(src));
        uint256 before = ch.free(address(src), address(usdg));
        uint256 walletBefore = usdg.balanceOf(address(src));
        assertEq(before, 5_000e6, "precondition: the source has free collateral to give back");
        src.setDrainAmount(5_000e6);

        assertTrue(_fund(address(usdg), 10_000e6), "a net withdrawal is NOT a revert -- that is the whole point");

        uint256 after_ = ch.free(address(src), address(usdg));
        assertLt(after_, before, "free did not fall, so this mode cannot produce the input it exists for");
        assertEq(after_, 0, "the whole parked balance came back out");
        assertEq(usdg.balanceOf(address(src)) - walletBefore, 5_000e6, "the tokens landed on the source itself");
    }

    /// @dev THE CONTROL. A mode that drained whatever it was asked would make the test above pass for the wrong
    ///      reason. With `drainAmount` left at its default 0 the same call moves nothing, so what the test above
    ///      measures is the drain and not merely "Drain deposits nothing".
    function test_drain_withNothingToDrainMovesNothing() public {
        src.setMode(MockFundingSource.Mode.Drain);
        vm.prank(address(src));
        ch.deposit(address(usdg), 5_000e6, address(src));
        uint256 before = ch.free(address(src), address(usdg));

        assertTrue(_fund(address(usdg), 10_000e6), "still not a revert");
        assertEq(ch.free(address(src), address(usdg)), before, "nothing was drained and nothing was deposited");
    }

    function test_revert_leavesTheDeltaAtZeroAndIsCatchable() public {
        src.setMode(MockFundingSource.Mode.Revert);
        uint256 before = ch.free(address(src), address(usdg));
        assertFalse(_fund(address(usdg), 10_000e6), "the outer call catches it");
        assertEq(ch.free(address(src), address(usdg)) - before, 0, "nothing delivered");
    }

    function test_gasDrain_leavesTheDeltaAtZeroUnderTheFundingCap() public {
        src.setMode(MockFundingSource.Mode.GasDrain);
        uint256 before = ch.free(address(src), address(usdg));
        // Burns through V2Constants.FUNDING_GAS (400_000, V2Constants.sol:121) and delivers nothing.
        assertFalse(_fund(address(usdg), 10_000e6), "out of gas inside the cap, caught by the caller");
        assertEq(ch.free(address(src), address(usdg)) - before, 0, "nothing delivered");
    }

    function test_garbage_returnsDataAndDeliversNothing() public {
        src.setMode(MockFundingSource.Mode.Garbage);
        uint256 before = ch.free(address(src), address(usdg));
        // The call "succeeds" and even returns a word. A caller that believed the return instead of the delta
        // would credit a delivery that never happened — which is the whole reason the book measures the delta.
        assertTrue(_fund(address(usdg), 10_000e6), "garbage does not revert");
        assertEq(ch.free(address(src), address(usdg)) - before, 0, "nothing delivered, whatever it returned");
    }

    /*//////////////////////////////////////////////////////////////
                              FUNDABLE
    //////////////////////////////////////////////////////////////*/

    function test_fundable_reportsWhatItWasSet() public {
        src.setFundable(42_000e6);
        (bool ok, uint256 value) = _fundable(address(usdg));
        assertTrue(ok, "an honest read succeeds");
        assertEq(value, 42_000e6);
    }

    function test_fundable_garbageReturnsFewerThan32Bytes() public {
        src.setFundable(42_000e6);
        src.setMode(MockFundingSource.Mode.Garbage);
        (bool ok,) = _fundable(address(usdg));
        // 16 bytes back: the book's read requires a full word, so short data is a failure and counts as 0
        // (IFundingSource.sol:32-34), NOT as the value that happens to be sitting in scratch memory.
        assertFalse(ok, "short return data is not a reading");
    }

    function test_fundable_revertAndGasDrainBothReadAsAFailure() public {
        src.setFundable(42_000e6);

        src.setMode(MockFundingSource.Mode.Revert);
        (bool revertOk,) = _fundable(address(usdg));
        assertFalse(revertOk, "a revert is not a reading");

        src.setMode(MockFundingSource.Mode.GasDrain);
        (bool drainOk,) = _fundable(address(usdg));
        assertFalse(drainOk, "out of the 50,000 gas cap is not a reading");
    }

    function test_fundable_isNotViewSoTheReenterProbeCanAttemptAWrite() public {
        // The declaration itself is the deliverable: a `view` double could not ATTEMPT the write the Reenter
        // probe exists to have refused (MockFeeDiscount.sol:12-16 makes the same argument). Reading it through
        // a staticcall is what turns the attempt into an EVM-level failure.
        src.setMode(MockFundingSource.Mode.Reenter);
        src.setBook(address(this));
        src.setReenterCalldata(abi.encodeCall(this.reenterTarget, ()));
        src.setFundable(7);

        // THE ATTEMPT IS ASSERTED, NOT ASSUMED. `reentered == 0` alone is also exactly what a double that never
        // fired the probe leaves behind, so without this the test is green for forbidden fix (d). The call into
        // reenterTarget is counted even though the static flag halts it there.
        vm.expectCall(address(this), abi.encodeCall(this.reenterTarget, ()), 1);
        // Read under the book's real FUNDABLE_READ_GAS cap (see _fundable). Until T-454 an uncapped probe let the
        // refused frame burn 63/64 of that cap and this read ran OUT OF GAS, so the assertion below failed on gas
        // and said nothing about reentrancy. MockFundingSource.REENTER_ANSWER_RESERVE is the fix.
        (bool ok, uint256 value) = _fundable(address(usdg));
        assertTrue(ok, "the double still answers after the refused attempt");
        assertEq(value, 7);
        // Refused, not merely skipped: the same calldata outside a static context DOES land -- see
        // test_reenter_firesAtTheBookAndStillDeliversHonestly, which asserts `reentered == 1`.
        assertEq(reentered, 0, "the write inside the staticcall did not land");
    }

    /*//////////////////////////////////////////////////////////////
                               REENTER
    //////////////////////////////////////////////////////////////*/

    uint256 public reentered;

    function reenterTarget() external {
        reentered += 1;
    }

    function test_reenter_firesAtTheBookAndStillDeliversHonestly() public {
        src.setMode(MockFundingSource.Mode.Reenter);
        src.setBook(address(this));
        src.setReenterCalldata(abi.encodeCall(this.reenterTarget, ()));

        uint256 before = ch.free(address(src), address(usdg));
        assertTrue(_fund(address(usdg), 1_000e6), "the funding still succeeds");
        assertEq(ch.free(address(src), address(usdg)) - before, 1_000e6, "Reenter delivers like Honest");
        // Outside a staticcall the attempt lands, which is what makes it a real probe: against the book it is
        // the book's own reentrancy guard, held for the whole take, that must refuse it.
        assertEq(reentered, 1, "the attempt was made");
    }

    /// @dev T-470. The explicit target defaults to the book, and keeps following it when {setBook} comes later, so
    ///      every Reenter test written before the target existed still aims where it did.
    function test_reenterTarget_defaultsToTheBookAndFollowsALaterSetBook() public {
        assertEq(src.reenterTarget(), address(0), "no book yet, no target");
        src.setBook(address(this));
        assertEq(src.reenterTarget(), address(this), "the book is the default target");
        src.setBook(address(0xB00C));
        assertEq(src.reenterTarget(), address(0xB00C), "a later setBook moves the default with it");
        src.setReenterTarget(address(this));
        assertEq(src.reenterTarget(), address(this), "an explicit target wins over the book");
        src.setReenterTarget(address(0));
        assertEq(src.reenterTarget(), address(0xB00C), "zero restores the book");
    }

    /// @dev T-470. Aimed away from the book, the probe fires at the named target and never at the book: the book here
    ///      is an address with no code, so a call to it would also "succeed" and prove nothing -- the count on the
    ///      named target is what is asserted.
    function test_reenter_firesAtAnExplicitTargetNotTheBook() public {
        src.setMode(MockFundingSource.Mode.Reenter);
        src.setBook(address(0xB00C));
        src.setReenterTarget(address(this));
        src.setReenterCalldata(abi.encodeCall(this.reenterTarget, ()));

        vm.expectCall(address(this), abi.encodeCall(this.reenterTarget, ()), 1);
        vm.expectCall(address(0xB00C), abi.encodeCall(this.reenterTarget, ()), 0);
        uint256 before = ch.free(address(src), address(usdg));
        assertTrue(_fund(address(usdg), 1_000e6), "the funding still succeeds");
        assertEq(ch.free(address(src), address(usdg)) - before, 1_000e6, "Reenter delivers like Honest");
        assertEq(reentered, 1, "the attempt landed on the explicit target");
    }

    /*//////////////////////////////////////////////////////////////
                          SHAPE AND CONSTANTS
    //////////////////////////////////////////////////////////////*/

    function test_defaults_areHonestAndFullDelivery() public view {
        MockFundingSource fresh = src;
        assertEq(uint256(fresh.mode()), uint256(MockFundingSource.Mode.Honest), "Honest is enum value 0");
        assertEq(fresh.deliverBps(), 10_000, "a fresh double delivers all of it");
        assertEq(address(fresh.ch()), address(ch));
    }

    function test_setOperator_forwardsSoTheBookCanMintForThisMaker() public {
        assertFalse(ch.isOperator(address(src), address(this)), "not an operator yet");
        src.setOperator(address(this), true);
        assertTrue(ch.isOperator(address(src), address(this)), "the book can now mint for this maker");
    }

    /// @dev The three pins C8-13B sizes the stage against. Read from V2Constants, never retyped
    ///      (src/v2/interfaces/V2Constants.sol:121, :124, :127).
    function test_constantsAreReadFromV2Constants() public pure {
        assertEq(V2Constants.FUNDING_GAS, 400_000, "V2Constants.sol:121");
        assertEq(V2Constants.FUNDABLE_READ_GAS, 50_000, "V2Constants.sol:124");
        assertEq(V2Constants.MAX_FUNDED_MAKERS_PER_TAKE, 4, "V2Constants.sol:127");
    }
}
