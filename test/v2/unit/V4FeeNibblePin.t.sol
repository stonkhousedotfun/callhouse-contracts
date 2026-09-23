// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V4BuybackExecutorFixture} from "./V4BuybackExecutorBase.t.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V4BuybackExecutor} from "../../../src/v2/periphery/V4BuybackExecutor.sol";
import {V4ProtocolFeeMirror} from "../lib/V4ProtocolFeeMirror.sol";

/// @notice Pins WHICH HALF of v4's packed `protocolFee` each of our decode sites reads.
///
/// @dev WHAT THIS PINS, AND WHAT IT DOES NOT. `getSlot0`'s `protocolFee` packs two 12-bit pip values. Three sites in
///      `src/` assert that the LOW twelve bits charge `zeroForOne` swaps: the interface doc at
///      `BuybackDeps.sol:45`, the executor's decode at `V4BuybackExecutor.sol:570` (`protocolFee & 0xFFF`), and the
///      router's cached route fee at `PayoutRouter.sol:224` (`zeroForOne ? & 0xFFF : >> 12`). This suite makes each
///      of those readable directions FAIL LOUDLY if anyone flips a mask.
///
///      IT NOW PINS AGAINST THE DEPENDENCY, NOT ONLY AGAINST ITSELF (T-250). The paragraph that used to sit here
///      said our convention could not be checked against v4-core because it is not a submodule. That was true of
///      this REPOSITORY and false of this MACHINE: v4-core is checked out at
///      `a local Uniswap v4-core checkout`, and its two accessors are now mirrored into
///      `test/v2/lib/V4ProtocolFeeMirror.sol` with their upstream file and line numbers recorded. The tests at the
///      bottom of this file assert our decode sites against THAT mirror, so "every site is wrong in the same
///      direction" is now a failing test rather than a frozen error.
///
///      WHAT IS STILL NOT PROVEN. The mirror is a copy, so it can go stale: if v4-core changes these accessors,
///      this suite pins the old convention until someone re-mirrors from the path named in
///      `V4ProtocolFeeMirror`'s NatSpec. And nothing here reads a live pool whose protocol fee is non-zero AND
///      asymmetric -- the pinned pool's real value is 0, which is symmetric, as `test_aSymmetricFeeCannotDistinguish
///      TheDirections` records.
///
///      WHY THE EXISTING CHECKS COULD NOT DO THIS, which is the whole reason the row exists. Each of them is
///      structurally unable to see the subject:
///        - `V4BuybackExecutorBase.t.sol:148` computes its expected figure with `protocolFee & 0xFFF`, THE SAME
///          EXPRESSION as the code under test. Flip both and it still passes.
///        - `MockV4StateView` is "a lens, not a source" by its own NatSpec, and `MockV4PoolManager:149` CHARGES with
///          `zeroForOne ? (protocolFee & 0xFFF) : (protocolFee >> 12)` -- the same convention the guard declares, so
///          declared and charged agree however the nibbles are read.
///        - `V4BuybackExecutorFork.t.sol:169` asserts `protocolFeeRaw == 0` on the real pinned pool. Zero is
///          SYMMETRIC: `(0 & 0xFFF) == (0 >> 12)`, so the only check touching a real v4 deployment reads the one
///          value that cannot distinguish the two directions.
///
///      THE VALUES ARE ASYMMETRIC ON PURPOSE. Every assertion below would hold under a flipped mask if the two
///      nibbles carried the same number, which is exactly how this went unnoticed.
contract V4FeeNibblePinTest is V4BuybackExecutorFixture {
    /// @dev Distinct, and distinct AFTER the pips->bps rounding the executor applies (`(pips + 99) / 100`):
    ///      111 pips is 2 bps, 222 pips is 3 bps. Values that collapsed to the same bps would prove nothing.
    uint24 internal constant ZERO_FOR_ONE_PIPS = 111;
    uint24 internal constant ONE_FOR_ZERO_PIPS = 222;
    uint16 internal constant ZERO_FOR_ONE_BPS = 2;
    uint16 internal constant ONE_FOR_ZERO_BPS = 3;

    /// @dev `V4BuybackExecutor.sol:149`. Mirrored, not typed from memory.
    uint24 internal constant MAX_PROTOCOL_FEE_PIPS = 1000;

    function _packed(uint24 zeroForOne, uint24 oneForZero) internal pure returns (uint24) {
        return zeroForOne | (oneForZero << 12);
    }

    /// @dev THE PIN. The executor trades `zeroForOne` only, so it must read the LOW nibble. With 111 low and 222
    ///      high, a flipped mask reports 3 bps where this requires 2.
    function test_executorReadsTheLowNibbleForZeroForOne() public {
        manager.setPool(key, uint160(1 << 96), 0, _packed(ZERO_FOR_ONE_PIPS, ONE_FOR_ZERO_PIPS), 0);

        (,, uint16 v4Protocol,,,) = exec.feeBps();

        assertEq(v4Protocol, ZERO_FOR_ONE_BPS, "executor must charge the zeroForOne nibble (low 12 bits)");
        assertTrue(v4Protocol != ONE_FOR_ZERO_BPS, "executor read the oneForZero nibble: the mask is inverted");
    }

    /// @dev The same fact proved through BEHAVIOUR rather than a reported number, because a reported number can be
    ///      right for the wrong reason. `V4BuybackExecutor.sol:571` refuses a protocol fee above
    ///      MAX_PROTOCOL_FEE_PIPS. Put the over-ceiling value in the LOW nibble and the call must revert.
    function test_ceilingSeesTheLowNibble() public {
        manager.setPool(key, uint160(1 << 96), 0, _packed(MAX_PROTOCOL_FEE_PIPS + 1, 0), 0);

        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        exec.feeBps();
    }

    /// @dev And the other direction, which is the half that makes the pair load-bearing: the SAME over-ceiling value
    ///      in the HIGH nibble must be ignored, because it charges the direction this executor never trades. A test
    ///      that only asserted the revert above would pass with the mask flipped AND with the ceiling widened.
    function test_ceilingIgnoresTheHighNibble() public {
        manager.setPool(key, uint160(1 << 96), 0, _packed(0, MAX_PROTOCOL_FEE_PIPS + 1), 0);

        (,, uint16 v4Protocol,,,) = exec.feeBps();

        assertEq(v4Protocol, 0, "an over-ceiling oneForZero fee must not be charged to a zeroForOne swap");
    }

    /// @dev The degenerate case that hides the defect in production, asserted so it is on the record rather than
    ///      discovered again. This is what the fork suite reads, and it is why the fork suite cannot pin anything.
    function test_aSymmetricFeeCannotDistinguishTheDirections() public {
        manager.setPool(key, uint160(1 << 96), 0, _packed(500, 500), 0);
        (,, uint16 symmetric,,,) = exec.feeBps();

        manager.setPool(key, uint160(1 << 96), 0, 0, 0);
        (,, uint16 zero,,,) = exec.feeBps();

        assertEq(symmetric, 5, "500 pips is 5 bps whichever nibble is read");
        assertEq(zero, 0, "the pinned pool's real value, 0, is identical under either mask");
    }

    /*//////////////////////////////////////////////////////////////
        T-250: THE SAME FACTS, ANCHORED TO v4-core INSTEAD OF TO US
    //////////////////////////////////////////////////////////////*/

    /// @dev THE PIN THIS FILE PREVIOUSLY COULD NOT MAKE. Every assertion above compares our decode against a
    ///      constant this file declares. These compare it against `V4ProtocolFeeMirror`, which is a line-for-line
    ///      copy of v4-core's `ProtocolFeeLibrary`. If our mask and the dependency's ever disagree, this fails where
    ///      the others would all still pass together.
    function test_ourZeroForOneNibbleMatchesV4Core() public pure {
        uint24 packed = ZERO_FOR_ONE_PIPS | (ONE_FOR_ZERO_PIPS << 12);

        // Our convention, written the way `PayoutRouter.sol:224` and `V4BuybackExecutor.sol:570` write it.
        uint256 ours = packed & 0xFFF;
        // v4-core's, mirrored.
        uint16 theirs = V4ProtocolFeeMirror.getZeroForOneFee(packed);

        assertEq(ours, uint256(theirs), "our zeroForOne mask disagrees with v4-core ProtocolFeeLibrary");
        assertEq(uint256(theirs), uint256(ZERO_FOR_ONE_PIPS), "the mirror did not return the low nibble");
    }

    /// @dev The other direction, for the same reason the ceiling pair above is a pair: one of these passing while
    ///      the other fails is what an inverted mask looks like.
    function test_ourOneForZeroNibbleMatchesV4Core() public pure {
        uint24 packed = ZERO_FOR_ONE_PIPS | (ONE_FOR_ZERO_PIPS << 12);

        uint256 ours = packed >> 12;
        uint16 theirs = V4ProtocolFeeMirror.getOneForZeroFee(packed);

        assertEq(ours, uint256(theirs), "our oneForZero mask disagrees with v4-core ProtocolFeeLibrary");
        assertEq(uint256(theirs), uint256(ONE_FOR_ZERO_PIPS), "the mirror did not return the high nibble");
    }

    /// @dev The ceiling constant the executor compares against is v4-core's, not ours to choose.
    ///      `V4BuybackExecutor.sol:149` carries 1000; so does `ProtocolFeeLibrary.sol:8`.
    function test_ourProtocolFeeCeilingMatchesV4Core() public pure {
        assertEq(
            uint256(MAX_PROTOCOL_FEE_PIPS),
            uint256(V4ProtocolFeeMirror.MAX_PROTOCOL_FEE),
            "our MAX_PROTOCOL_FEE_PIPS disagrees with v4-core MAX_PROTOCOL_FEE"
        );
    }

    /// @dev The mirror must be able to FAIL. An accessor pair that returned the same value for both directions
    ///      would satisfy every assertion above without proving anything, so assert they differ on an asymmetric
    ///      input -- the positive control for this file's new half.
    function test_theMirrorDistinguishesTheTwoDirections() public pure {
        uint24 packed = ZERO_FOR_ONE_PIPS | (ONE_FOR_ZERO_PIPS << 12);

        assertTrue(
            V4ProtocolFeeMirror.getZeroForOneFee(packed) != V4ProtocolFeeMirror.getOneForZeroFee(packed),
            "the mirror cannot tell the nibbles apart: it proves nothing"
        );
    }

    /*//////////////////////////////////////////////////////////////
       T-CV-FLYWHEEL / SEC-47: THE TOTAL MIXES DENOMINATIONS, PINNED
    //////////////////////////////////////////////////////////////*/

    /// @dev WHY THESE TWO LIVE IN THE NIBBLE-PIN FILE. `T-SEC-P4-BUYBACK-AND-SPLITTER` documented SEC-47 in
    ///      `_totalBps`'s NatSpec and recorded, as its own P3, that the claim had NO TEST: the executor's suites were
    ///      outside that row's fence. They are outside this row's fence too -- `V4BuybackExecutor.t.sol` and
    ///      `V4BuybackExecutorFees.t.sol` are not in T-CV-FLYWHEEL's `scope_paths`, and this file and the fixture it
    ///      extends are. So the pin goes where the fence allows rather than where the name would suggest. Both tests
    ///      are about the executor's DECLARED fee arithmetic, which is what the rest of this file pins.

    /// @dev SEC-47, HALF ONE: the reported total is the PLAIN SUM of five terms that are not in one denomination.
    ///      `v3`, `v4Lp` and `v4Protocol` come out of what goes IN; `hook` and `creatorTax` come out of what comes
    ///      OUT. `_totalBps` adds them anyway. That is deliberate and documented; what was missing is anything that
    ///      FAILS if the shape changes. The five terms are set to distinct values so a total that dropped or
    ///      double-counted one of them cannot still match by arithmetic accident.
    function test_feeBpsTotalIsThePlainSumOfItsFiveTerms() public {
        // 300 pips -> 3 bps protocol, 4_500 pips -> 45 bps LP, and the launch record's 60 / 70 bps output cuts.
        manager.setPool(key, uint160(1 << 96), 0, _packed(300, 0), 4_500);
        _setLaunch(60, 70);

        (uint16 v3, uint16 v4Lp, uint16 v4Protocol, uint16 hookFee, uint16 creatorTax, uint256 total) = exec.feeBps();

        assertEq(v3, 1, "the fixture's v3 tier is 100 pips, which is 1 bp");
        assertEq(v4Lp, 45, "4_500 pips is 45 bps");
        assertEq(v4Protocol, 3, "300 pips in the zeroForOne nibble is 3 bps");
        assertEq(hookFee, 60, "the hook's declared fee");
        assertEq(creatorTax, 70, "the creator tax");
        assertEq(
            total,
            uint256(v3) + v4Lp + v4Protocol + hookFee + creatorTax,
            "feeBps().total must be the plain sum of its five terms"
        );
        assertEq(total, 179, "1 + 45 + 3 + 60 + 70");
    }

    /// @dev SEC-47, HALF TWO, AND THE ONE WORTH HAVING: the additive total can refuse a route whose REAL drag is
    ///      under the cap. Charges applied in sequence drag `a + b - ab`, strictly less than `a + b` for fees in
    ///      (0,1), so the sum always over-states and the cap errs toward REFUSAL -- never toward allowing a route a
    ///      denomination-exact total would have refused. `T-SEC-P4` reasoned that out and wrote it into the NatSpec;
    ///      nothing executed it. Here the input side is 125 bps (1 v3 + 124 LP) and the output side 126 bps, so the
    ///      declared sum is 251 against a 250 cap and `buy` refuses, while the true sequential drag is 249.425 bps.
    ///      If anyone ever "corrects" `_totalBps` to the compounded form, this test goes red and the decision becomes
    ///      explicit instead of silent.
    function test_theAdditiveTotalRefusesARouteWhoseSequentialDragIsUnderTheCap() public {
        uint256 inputSideBps = 125; // 1 bp v3 + 124 bps LP
        uint256 outputSideBps = 126; // the hook's cut, under MAX_HOOK_FEE_BPS
        manager.setPool(key, uint160(1 << 96), 0, 0, 12_400);
        _setLaunch(uint16(outputSideBps), 0);

        (,,,,, uint256 total) = exec.feeBps();
        assertEq(total, inputSideBps + outputSideBps, "the declared total is the additive one");
        assertGt(total, FEE_CAP_BPS, "the additive total is above the cap, which is what makes the refusal happen");

        // The same route's real drag, at 1e4 scale so the sub-bp term survives: (a + b - ab) vs the cap.
        uint256 sequentialScaled = (inputSideBps + outputSideBps) * 10_000 - inputSideBps * outputSideBps;
        assertLt(
            sequentialScaled,
            uint256(FEE_CAP_BPS) * 10_000,
            "the sequentially-applied drag is BELOW the cap: this route is refused by the denomination mix alone"
        );

        vm.expectRevert(
            abi.encodeWithSelector(V4BuybackExecutor.FeeCapExceeded.selector, inputSideBps + outputSideBps, FEE_CAP_BPS)
        );
        _buy(USDG_IN, 1, 0);
    }

    /// @dev T-CV-FLYWHEEL, AND THE GAP A PROVE-BY-BREAKING ROUND FOUND IN MY OWN WORK. This row re-anchored
    ///      `V4BuybackExecutorFixture._expected` to `V4ProtocolFeeMirror` so the fixture's expectation stops being
    ///      the same expression as the code under test (T-185 finding 1). Flipping the executor's mask to `>> 12`
    ///      then showed the anchor is NOT SUFFICIENT on its own: `V4BuybackExecutor.t.sol` stayed 34/34 green,
    ///      because every test in it runs at `protocolFee == 0`, and zero is symmetric. An expectation that is
    ///      anchored to the right source still proves nothing if no test ever gives it an asymmetric input.
    ///
    ///      So this runs a REAL buy at an asymmetric protocol fee and reconciles the tokens the splitter received
    ///      against `_expected`. The value charged comes from `MockV4PoolManager` (:149), which decodes the nibbles
    ///      itself; the expectation now comes from the mirror. Flip the MOCK's convention and this goes red, which
    ///      is the one direction the pin file's other tests -- they read `feeBps()`, a declared view -- cannot see.
    function test_aRealBuyAtAnAsymmetricProtocolFeeReconcilesAgainstTheMirror() public {
        // 300 pips in the zeroForOne nibble (charged, 3 bps), 900 in the oneForZero nibble (not charged, 9 bps).
        // Distinct after the pips->bps rounding, and distinct in the token amount they would produce.
        manager.setPool(key, uint160(1 << 96), 0, _packed(300, 900), 0);

        (,,, uint256 wantTokenOut) = _expected(USDG_IN);
        (, uint256 gotTokenOut) = _buy(USDG_IN, 1, 0);

        assertEq(gotTokenOut, wantTokenOut, "the buy did not pay what the mirror-anchored expectation says");
        assertGt(gotTokenOut, 0, "the route filled, so the reconciliation is over a real amount");
    }

    /// @dev The positive control for the pair above, because a cap test that only ever sees a refusal cannot tell a
    ///      working guard from a broken venue: one bp lower on the output side and the SAME route goes through.
    function test_theSameRouteOneBpUnderTheCapIsAllowed() public {
        manager.setPool(key, uint160(1 << 96), 0, 0, 12_400);
        _setLaunch(125, 0);

        (,,,,, uint256 total) = exec.feeBps();
        assertEq(total, FEE_CAP_BPS, "exactly at the cap, which the guard allows");

        (, uint256 tokenOut) = _buy(USDG_IN, 1, 0);
        assertGt(tokenOut, 0, "the route fills when the additive total is not above the cap");
    }
}
