// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {OrderComponents} from "../../src/interfaces/ISeaport.sol";

/// @notice REGRESSION (2026-09-13 finding): every queue entry is paid the USDG its OWN escrowed
///         shares earned, never a pro-rata slice of a pot other entries earned.
/// @dev THE BUG. Queued shares sit together in escrow at the vault, and `_settleQueue` takes the
///      escrow's whole accrual as one pot. The pot was split pro rata by shares at settlement, but it
///      is earned tranche by tranche on whatever the escrow held when each tranche was indexed. A
///      deposit or mint that indexed premium between two queue entries in the same epoch therefore
///      moved value from the earlier queuer to the later one: in the claim's sequence alice's epoch
///      USDG was 1_504_166 instead of 4_512_500, and a newcomer who deposited 30e18 (her own deposit
///      being the checkpoint) and queued it took 6_768_750 of alice's 9_025_000 while earning nothing.
///      A checkpoint at the start of `queueRedeem` would not have fixed it: a second fill indexed by a
///      later deposit, after one entry and before the next, reproduces it with nothing unindexed at
///      either queue call.
///      THE FIX. A reward debt per account (`shares * accUsdgPerShare` at escrow time) and the index
///      at each epoch's settlement; an entry is paid `floor((shares * epochIndex - debt) / 1e27)`,
///      capped at what the epoch holds, and the last claimant takes the remainder.
contract VaultQueueFairnessTest is BaseTest {
    function _closeCycle() internal {
        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();
        _rollClose();
    }

    function _queue(address who, uint256 shares) internal {
        vm.prank(who);
        vault.queueRedeem(shares);
    }

    function _epochUsdg(address who) internal view returns (uint256 usdgOut) {
        (, usdgOut) = vault.previewCompleteRedeem(who);
    }

    function _unindexed() internal view returns (uint256) {
        return usdg.balanceOf(address(vault)) - vault.usdgAccounted();
    }

    /// The claim's sequence. $19.00 reaches the vault, fee 950_000, net 18_050_000, indexed at carol's
    /// deposit over 20e18 supply while the escrow held only alice's 5e18: index 902_500e9, so alice's
    /// escrowed 5e18 earned 4_512_500 and bob's 10e18, not yet escrowed, earned 9_025_000 in his own
    /// balance. Nothing is indexed after bob queues.
    function test_earlierQueuerKeepsTheTrancheOnlyHerSharesEarned() public {
        _deposit(alice, 10e18);
        _deposit(bob, 10e18);
        uint256 id = _rollOpen(10);
        OrderComponents memory c = _approveListing(id, 10, _okUnitPrice());
        _fill(c, 10);
        _queue(alice, 5e18);
        _deposit(carol, 10e18);
        _queue(bob, 10e18);
        _closeCycle();

        assertEq(_epochUsdg(alice), 4_512_500, "alice's escrowed shares earned the whole checkpoint tranche");
        assertEq(_epochUsdg(bob), 0, "bob's shares were not in escrow when it was indexed");
        assertEq(vault.claimableUsdg(bob), 9_025_000, "bob keeps what his shares earned before he queued");
        assertEq(vault.claimableUsdg(alice), 4_512_500, "alice keeps her unqueued half's share");

        vm.prank(bob);
        (, uint256 bOut) = vault.completeRedeem(bob);
        vm.prank(alice);
        (, uint256 aOut) = vault.completeRedeem(alice);
        assertEq(bOut, 0, "bob collects nothing from the escrow pot");
        assertEq(aOut, 4_512_500, "alice, last, collects the whole pot");
        assertEq(vault.usdgReservedForQueue(), 0, "no USDG stranded");
        assertEq(
            aOut + bOut + vault.claimableUsdg(alice) + vault.claimableUsdg(bob), 18_050_000, "every unit accounted"
        );
    }

    /// The deliberate variant: carol has earned nothing, deposits 30e18 after the fill (her deposit is
    /// the checkpoint) and queues it all. She gets her principal back and no premium.
    function test_depositThenQueueTakesNoneOfAnEarlierQueuersPremium() public {
        _deposit(alice, 10e18);
        _deposit(bob, 10e18);
        uint256 id = _rollOpen(10);
        OrderComponents memory c = _approveListing(id, 10, _okUnitPrice());
        _fill(c, 10);
        _queue(alice, 10e18);

        uint256 carolShares = _deposit(carol, 30e18);
        assertEq(vault.claimableUsdg(carol), 0, "carol earned nothing");
        _queue(carol, carolShares);
        _closeCycle();

        (uint256 cAssets, uint256 cUsdg) = vault.previewCompleteRedeem(carol);
        (, uint256 aUsdg) = vault.previewCompleteRedeem(alice);
        assertEq(cAssets, 30e18, "carol gets her principal back");
        assertEq(cUsdg, 0, "and none of alice's premium");
        assertEq(aUsdg, 9_025_000, "alice keeps all of what her 10e18 earned: half of 18_050_000");
    }

    /// Two partial fills, each indexed by a deposit, nothing unindexed at either queue call. Tranche 2
    /// (9_500_000 in, fee 475_000, net 9_025_000) is indexed over 21e18 while the escrow holds alice's
    /// 5e18 only: alice earns floor(5e18 * floor(9_025_000e27 / 21e18) / 1e27) = 2_148_809; bob, who
    /// queued after it, earns none of it in escrow.
    function test_trancheIndexedBetweenEntriesStaysWithTheEntryItAccruedTo() public {
        _deposit(alice, 10e18);
        _deposit(bob, 10e18);
        uint256 id = _rollOpen(10);
        OrderComponents memory c = _approveListing(id, 10, _okUnitPrice());
        _fill(c, 5);
        _deposit(carol, 1e18);

        assertEq(_unindexed(), 0, "nothing unindexed at alice's queue");
        _queue(alice, 5e18);

        _fill(c, 5);
        _deposit(carol, 1e18);

        assertEq(_unindexed(), 0, "nothing unindexed at bob's queue");
        _queue(bob, 10e18);
        _closeCycle();

        (,, uint256 pot) = vault.epochs(1);
        assertEq(pot, 2_148_809, "the escrow earned tranche 2 on alice's 5e18 only");
        assertEq(_epochUsdg(alice), 2_148_809, "alice gets all of it");
        assertEq(_epochUsdg(bob), 0, "bob gets none of it");
    }

    /// FUZZ. Three entries queued around two independently sized premium tranches, each indexed by a
    /// deposit at a fuzzed point. Every entry except the last claimant must receive exactly the floor
    /// of its own shares' index growth; the last takes the remainder, which may differ from its own
    /// floor only by the rounding of the others (bounded by the entry count); and the pot is paid out
    /// to the base unit.
    function testFuzz_eachEntryIsPaidItsOwnIndexGrowth(uint8 fill1Raw, uint8 orderSeed, uint64 aRaw, uint64 bRaw)
        public
    {
        uint112 fill1 = uint112(bound(uint256(fill1Raw), 1, 9));
        uint256 aQ = bound(uint256(aRaw), 1, 10e18);
        uint256 bQ = bound(uint256(bRaw), 1, 10e18);

        address checkpointer = makeAddr("checkpointer");
        _fund(checkpointer, 2e18, 0);
        _deposit(alice, 10e18);
        _deposit(bob, 10e18);
        _deposit(carol, 10e18);
        uint256 id = _rollOpen(20);
        OrderComponents memory c = _approveListing(id, 20, _okUnitPrice());

        uint256[3] memory debt;
        address[3] memory who = [alice, bob, carol];
        uint256[3] memory shares = [aQ, bQ, uint256(10e18)];

        // Entry 0 queues before any premium, entry 1 between the tranches, entry 2 after both, in an
        // order chosen by the seed.
        uint256 first = uint256(orderSeed) % 3;
        uint256 second = (first + 1 + (uint256(orderSeed) / 3) % 2) % 3;
        uint256 third = 3 - first - second;

        debt[first] = shares[first] * vault.accUsdgPerShare();
        _queue(who[first], shares[first]);

        _fill(c, fill1);
        _deposit(checkpointer, 1e18); // checkpoint tranche 1
        debt[second] = shares[second] * vault.accUsdgPerShare();
        _queue(who[second], shares[second]);

        _fill(c, 20 - fill1);
        _deposit(checkpointer, 1e18); // checkpoint tranche 2
        debt[third] = shares[third] * vault.accUsdgPerShare();
        _queue(who[third], shares[third]);

        _closeCycle();
        uint256 idx = vault.accUsdgPerShare();
        (,, uint256 pot) = vault.epochs(1);

        uint256 paid;
        for (uint256 i; i < 3; i++) {
            vm.prank(who[i]);
            (, uint256 got) = vault.completeRedeem(who[i]);
            uint256 own = (shares[i] * idx - debt[i]) / 1e27;
            if (i < 2) {
                assertEq(got, own < pot - paid ? own : pot - paid, "a non-last entry gets its own index growth");
            } else {
                assertApproxEqAbs(got, own, 3, "the last entry's remainder is its own growth within rounding");
            }
            paid += got;
        }
        assertEq(paid, pot, "the pot is paid out to the base unit");
        assertEq(vault.usdgReservedForQueue(), 0, "nothing stranded");
    }
}
