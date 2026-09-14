// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RealClearBase} from "../helpers/RealClearBase.sol";
import {MockClear} from "../../src/mocks/MockClear.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {IValoremClear} from "../../src/interfaces/IValoremClear.sol";

/// @title MockClear differential test against the real Valorem Clear bytecode (6436c82)
/// @notice Runs three fixed multi-writer scenarios on {MockClear} and on the real clearinghouse with the
///         SAME tokens (so the option id, and with it the settlement seed, is identical), and requires
///         every observable number to match: `claim()` amounts, `position()` amounts and the redeem
///         payouts of every writer.
/// @dev WHY THIS EXISTS. The F-01 audit finding lives entirely in Valorem's bucket engine, and every
///      unit and invariant suite runs against the mock. A mock that mis-models assignment would let a
///      write-on-fill or capped-inventory design pass its own tests while the real engine assigned
///      differently. The scenarios pin the three things that matter:
///        1. ONE BUCKET, PRO RATA BY WRITTEN. Every pre-exercise write shares bucket 0 and assignment
///           is split by amount written, whoever sold (the unsteered F-01 numbers: 20 of 220 written,
///           205 exercised -> 18.636 assigned).
///        2. WRITE AFTER AN EXERCISE OPENS A NEW BUCKET, and a top-up of an existing claim lands in the
///           bucket that is current at the time, giving the claim a second index.
///        3. THE DRAW IS `seed % n` WITH SWAP-AND-POP: an exercise that fully consumes the drawn bucket
///           pops it and continues into the bucket that took its slot.
///      The mock-only invariant "long supply == unexercised collateral" is asserted after every step.
contract MockClearDiffTest is Test, RealClearBase {
    MockStockToken internal nvda;
    MockERC20 internal usdg;
    MockClear internal mock;
    IValoremClear internal real;

    address internal writerA = makeAddr("writerA");
    address internal writerB = makeAddr("writerB");
    address internal writerC = makeAddr("writerC");
    address internal exerciser = makeAddr("exerciser");

    uint96 internal constant LOT = 1e18;
    uint96 internal constant STRIKE = 231_000_000;
    uint40 internal exerciseTs;
    uint40 internal expiryTs;

    /// @dev Observations: the whole (writer, claim) matrix flattened in a fixed order.
    struct Obs {
        uint256 amountWritten;
        uint256 amountExercised;
        uint256 posUnderlying;
        uint256 posExercise;
        uint256 redeemedNvda;
        uint256 redeemedUsdg;
    }

    function setUp() public {
        vm.warp(1_789_000_000);
        nvda = new MockStockToken("NVDA Stock Token", "NVDAx");
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        mock = new MockClear();
        real = _deployRealClear();

        exerciseTs = uint40(block.timestamp + 6 days);
        expiryTs = uint40(block.timestamp + 7 days);

        address[4] memory actors = [writerA, writerB, writerC, exerciser];
        for (uint256 i; i < 4; i++) {
            nvda.mint(actors[i], 1_000e18);
            usdg.mint(actors[i], 1_000_000_000_000);
            vm.startPrank(actors[i]);
            nvda.approve(address(mock), type(uint256).max);
            nvda.approve(address(real), type(uint256).max);
            usdg.approve(address(mock), type(uint256).max);
            usdg.approve(address(real), type(uint256).max);
            vm.stopPrank();
        }
    }

    /*//////////////////////////////////////////////////////////////
                              THE THREE RUNS
    //////////////////////////////////////////////////////////////*/

    /// Scenario 1: the vault-shaped writer V writes 20 and sells 5, Mallory writes 200 into the same
    /// bucket, the buyer exercises 5 and Mallory 200. V is assigned 205 x 20 / 220 = 18.636.
    function test_diff_singleBucketProRataByWritten() public {
        uint256 snap = vm.snapshotState();
        Obs[] memory m = _scenario1(IValoremClear(address(mock)), true);
        vm.revertToState(snap);
        Obs[] memory r = _scenario1(real, false);
        _assertSame(m, r);

        // The audit's F-01 numbers, on the real bytecode: V wrote 20, exercised 18.636...
        assertEq(r[0].amountWritten, 20e18);
        assertEq(r[0].amountExercised, 18_636_363_636_363_636_363, "V assigned 205 x 20 / 220");
        // position(V) before expiry: 15 x 20 / 220 NVDA left, 205 x 20 / 220 x 231 USDG owed.
        assertEq(r[0].posUnderlying, 1_363_636_363_636_363_636, "V's unassigned collateral");
        assertEq(r[0].posExercise, 4_305_000_000, "V's strike proceeds");
        assertEq(r[0].redeemedNvda, 1_363_636_363_636_363_636);
        assertEq(r[0].redeemedUsdg, 4_305_000_000);
    }

    /// Scenario 2: after a first exercise, a fresh write opens bucket 1 and a top-up of A's claim lands
    /// there too, so A's claim spans two buckets with different exercise ratios.
    function test_diff_writeAfterExerciseOpensANewBucket() public {
        uint256 snap = vm.snapshotState();
        Obs[] memory m = _scenario2(IValoremClear(address(mock)), true);
        vm.revertToState(snap);
        Obs[] memory r = _scenario2(real, false);
        _assertSame(m, r);
    }

    /// Scenario 3: three buckets, then an exercise sized to consume the DRAWN bucket exactly plus one,
    /// which forces the swap-and-pop and a continuation into the bucket that took its slot.
    function test_diff_steeredDrawWithSwapAndPop() public {
        uint256 snap = vm.snapshotState();
        // The mock run computes the steering amount from its bucket views; the real run replays the
        // same amount (the real engine exposes no bucket view, and the draw is a pure function of the
        // same public inputs). Matching claims then prove the real engine consumed the same bucket.
        (Obs[] memory m, uint112 steer) = _scenario3(IValoremClear(address(mock)), true, 0);
        vm.revertToState(snap);
        (Obs[] memory r,) = _scenario3(real, false, steer);
        _assertSame(m, r);
        assertGt(steer, 1, "the steered exercise emptied a whole bucket and spilled over");
    }

    /*//////////////////////////////////////////////////////////////
                               SCENARIOS
    //////////////////////////////////////////////////////////////*/

    function _scenario1(IValoremClear c, bool isMock) internal returns (Obs[] memory obs) {
        uint256 id = c.newOptionType(address(nvda), LOT, address(usdg), STRIKE, exerciseTs, expiryTs);

        uint256 claimV = _write(c, writerA, id, 20);
        _transfer(c, writerA, exerciser, id, 5); // "sold" 5
        uint256 claimM = _write(c, writerB, id, 200);
        _checkSupply(c, id, isMock);

        vm.warp(exerciseTs);
        _exercise(c, exerciser, id, 5);
        _exercise(c, writerB, id, 200);
        _checkSupply(c, id, isMock);

        obs = new Obs[](2);
        obs[0] = _observe(c, claimV);
        obs[1] = _observe(c, claimM);

        vm.warp(expiryTs);
        (obs[0].redeemedNvda, obs[0].redeemedUsdg) = _redeem(c, writerA, claimV);
        (obs[1].redeemedNvda, obs[1].redeemedUsdg) = _redeem(c, writerB, claimM);
    }

    function _scenario2(IValoremClear c, bool isMock) internal returns (Obs[] memory obs) {
        uint256 id = c.newOptionType(address(nvda), LOT, address(usdg), STRIKE, exerciseTs, expiryTs);

        uint256 claimA = _write(c, writerA, id, 10);
        _transfer(c, writerA, exerciser, id, 6);

        vm.warp(exerciseTs);
        _exercise(c, exerciser, id, 3); // bucket 0: 10 written, 3 exercised
        _checkSupply(c, id, isMock);

        uint256 claimB = _write(c, writerB, id, 10); // opens bucket 1
        uint256 topped = _write(c, writerA, claimA, 5); // A's top-up lands in bucket 1 as a 2nd index
        assertEq(topped, claimA, "top-up returns the same claim id");
        if (isMock) {
            assertEq(mock.bucketCount(id), 2, "a write after an exercise opened bucket 1");
            (uint112 w1, uint112 e1) = mock.bucket(id, 1);
            assertEq(w1, 15, "bucket 1 holds B's 10 and A's 5");
            assertEq(e1, 0);
        }
        _checkSupply(c, id, isMock);

        _exercise(c, exerciser, id, 3); // drawn by seed % 2
        _checkSupply(c, id, isMock);

        obs = new Obs[](2);
        obs[0] = _observe(c, claimA);
        obs[1] = _observe(c, claimB);

        vm.warp(expiryTs);
        (obs[0].redeemedNvda, obs[0].redeemedUsdg) = _redeem(c, writerA, claimA);
        (obs[1].redeemedNvda, obs[1].redeemedUsdg) = _redeem(c, writerB, claimB);
    }

    function _scenario3(IValoremClear c, bool isMock, uint112 steerAmount)
        internal
        returns (Obs[] memory obs, uint112 steerUsed)
    {
        uint256 id = c.newOptionType(address(nvda), LOT, address(usdg), STRIKE, exerciseTs, expiryTs);

        // Bucket 0: the exerciser writes 30 and A writes 10. Every writer hands its longs to the
        // exerciser, so the exerciser can always consume a whole bucket.
        uint256 claimX = _write(c, exerciser, id, 30);
        uint256 claimA = _write(c, writerA, id, 10);
        _transfer(c, writerA, exerciser, id, 10);

        vm.warp(exerciseTs);
        _exercise(c, exerciser, id, 2); // bucket 0 exercised: later writes open new buckets

        uint256 claimB = _write(c, writerB, id, 4); // bucket 1
        _transfer(c, writerB, exerciser, id, 4);
        _exercise(c, exerciser, id, 1); // drawn by seed % 2 -> bucket 0 or bucket 1

        uint256 claimC = _write(c, writerC, id, 3); // bucket 2 if bucket 1 was hit, else joins bucket 1
        _transfer(c, writerC, exerciser, id, 3);
        _checkSupply(c, id, isMock);

        // Steer: compute the draw from PUBLIC state and size the exercise to exactly empty the drawn
        // bucket plus one, which forces the swap-and-pop and a continuation into the next slot.
        uint160 seed = c.option(id).settlementSeed;
        assertEq(seed, uint160(id >> 96), "settlementSeed is the option key");
        if (isMock) {
            uint96[] memory idx = mock.unexercisedBucketIndices(id);
            assertGe(idx.length, 2, "at least two buckets hold collateral");
            uint96 target = idx[seed % idx.length];
            (uint112 tw, uint112 te) = mock.bucket(id, target);
            steerUsed = tw - te + 1;
            _exercise(c, exerciser, id, steerUsed);
            (, uint112 teAfter) = mock.bucket(id, target);
            assertEq(teAfter, tw, "the drawn bucket was fully assigned");
            assertEq(mock.unexercisedBucketIndices(id).length, idx.length - 1, "and popped from the list");
        } else {
            steerUsed = steerAmount;
            _exercise(c, exerciser, id, steerUsed);
        }
        _checkSupply(c, id, isMock);

        obs = new Obs[](4);
        obs[0] = _observe(c, claimX);
        obs[1] = _observe(c, claimA);
        obs[2] = _observe(c, claimB);
        obs[3] = _observe(c, claimC);

        vm.warp(expiryTs);
        (obs[0].redeemedNvda, obs[0].redeemedUsdg) = _redeem(c, exerciser, claimX);
        (obs[1].redeemedNvda, obs[1].redeemedUsdg) = _redeem(c, writerA, claimA);
        (obs[2].redeemedNvda, obs[2].redeemedUsdg) = _redeem(c, writerB, claimB);
        (obs[3].redeemedNvda, obs[3].redeemedUsdg) = _redeem(c, writerC, claimC);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _write(IValoremClear c, address who, uint256 tokenId, uint112 n) internal returns (uint256 claimId) {
        vm.prank(who);
        claimId = c.write(tokenId, n);
    }

    function _transfer(IValoremClear c, address from, address to, uint256 id, uint256 n) internal {
        vm.prank(from);
        c.safeTransferFrom(from, to, id, n, "");
    }

    function _exercise(IValoremClear c, address who, uint256 id, uint112 n) internal {
        vm.prank(who);
        c.exercise(id, n);
    }

    function _redeem(IValoremClear c, address who, uint256 claimId) internal returns (uint256 dNvda, uint256 dUsdg) {
        uint256 n0 = nvda.balanceOf(who);
        uint256 u0 = usdg.balanceOf(who);
        vm.prank(who);
        c.redeem(claimId);
        dNvda = nvda.balanceOf(who) - n0;
        dUsdg = usdg.balanceOf(who) - u0;
        // After redeem the claim is gone on both implementations.
        assertEq(uint8(c.tokenType(claimId)), uint8(IValoremClear.TokenType.None), "redeemed claim is None");
        vm.expectRevert(abi.encodeWithSelector(IValoremClear.TokenNotFound.selector, claimId));
        c.claim(claimId);
    }

    function _observe(IValoremClear c, uint256 claimId) internal view returns (Obs memory o) {
        IValoremClear.Claim memory cl = c.claim(claimId);
        IValoremClear.Position memory p = c.position(claimId);
        o.amountWritten = cl.amountWritten;
        o.amountExercised = cl.amountExercised;
        o.posUnderlying = uint256(p.underlyingAmount);
        o.posExercise = uint256(p.exerciseAmount);
    }

    /// @dev Mock-only invariant: outstanding option tokens equal unassigned contracts across buckets.
    function _checkSupply(IValoremClear c, uint256 id, bool isMock) internal view {
        if (!isMock) return;
        MockClear m = MockClear(address(c));
        assertEq(m.optionSupply(id), m.unexercisedContracts(id), "long supply == unexercised collateral");
    }

    function _assertSame(Obs[] memory m, Obs[] memory r) internal pure {
        assertEq(m.length, r.length);
        for (uint256 i; i < m.length; i++) {
            assertEq(m[i].amountWritten, r[i].amountWritten, "claim.amountWritten");
            assertEq(m[i].amountExercised, r[i].amountExercised, "claim.amountExercised");
            assertEq(m[i].posUnderlying, r[i].posUnderlying, "position.underlyingAmount");
            assertEq(m[i].posExercise, r[i].posExercise, "position.exerciseAmount");
            assertEq(m[i].redeemedNvda, r[i].redeemedNvda, "redeem NVDA");
            assertEq(m[i].redeemedUsdg, r[i].redeemedUsdg, "redeem USDG");
        }
    }
}
