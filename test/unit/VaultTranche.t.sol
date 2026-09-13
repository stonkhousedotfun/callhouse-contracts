// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {Vault} from "../../src/Vault.sol";
import {Policy, PolicyParams} from "../../src/Policy.sol";
import {IValoremClear} from "../../src/interfaces/IValoremClear.sol";
import {IOvercallRegistry} from "../../src/interfaces/IOvercallRegistry.sol";
import {OrderComponents} from "../../src/interfaces/ISeaport.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Tranche writes: `writeMore` tops this cycle's Valorem claim up.
/// @dev WHY TRANCHES. Valorem assigns an exercise across every writer of an option id pro rata by
///      what each WROTE, not by what each sold. Unsold inventory is therefore pure assignment
///      exposure, and writing per listing bounds it by the live listing's unfilled part. The
///      tests below pin that a tranche lands in the SAME claim (so settlement is untouched), that
///      every gate a fresh write passes is re-run at today's state, and that size is measured on
///      the claim's total so tranches can never creep past the utilisation limit or the cap.
///
///      Band arithmetic, as in {VaultRollTest}: spot 220 => [226.60, 246.40]; the 231 rung is
///      written. A rally to $225 lifts the floor to 231.75, which puts 231 below the band.
contract VaultTrancheTest is BaseTest {
    event CallsWritten(uint256 indexed optionId, uint256 indexed claimKey, uint112 contractsCount, uint256 collateral);

    /// @dev Alice deposits 30, the keeper writes 5 of the 231 rung.
    function _open() internal returns (uint256 id) {
        _deposit(alice, 30e18);
        id = _rollOpen(5);
    }

    /// @dev `err` must be computed by the caller: see the README on `vm.expectRevert`.
    function _rejectWriteMore(uint112 n, bytes memory err) internal {
        vm.prank(keeper);
        vm.expectRevert(err);
        vault.writeMore(n);
    }

    /*//////////////////////////////////////////////////////////////
                              HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_writeMore_topsUpTheSameClaim() public {
        uint256 id = _open();
        uint256 key = vault.claimKey();

        vm.expectEmit(true, true, true, true, address(vault));
        emit CallsWritten(id, key, 4, 4e18);
        _writeMore(4);

        assertEq(vault.claimKey(), key, "one claim, topped up");
        assertEq(vault.optionId(), id, "same option");
        assertEq(vault.contractsWritten(), 9, "5 + 4");
        assertEq(clear.balanceOf(address(vault), id), 9, "nine option tokens held");
        assertEq(clear.balanceOf(address(vault), key), 1, "still exactly one claim NFT");
        assertEq(vault.lockedAssets(), 9e18, "collateral read from the claim aggregate");
        assertEq(vault.totalAssets(), 30e18, "writing moves collateral, it does not lose it");
        IValoremClear.Claim memory c = clear.claim(key);
        assertEq(c.amountWritten, 9e18, "Valorem reports the summed claim");
        assertEq(nvda.allowance(address(vault), address(clear)), 0, "no standing approval left behind");
    }

    /// @dev The keeper sells a tranche, writes the next, and relists at the same price: the relist
    ///      is free under the price-cut listing budget, and can offer the whole topped-up balance.
    function test_writeMore_topUpIsListableAndSells() public {
        uint256 id = _open();
        OrderComponents memory first = _approveListing(id, 5, _okUnitPrice());
        _fill(first, 5);

        _writeMore(5);
        vm.prank(keeper);
        vault.invalidateAllListings();
        OrderComponents memory second = _approveListing(id, 5, _okUnitPrice());
        _fill(second, 5);

        assertEq(vault.contractsSold(), 10, "both tranches sold");
        assertEq(vault.contractsRemaining(), 0, "no unsold exposure");
        assertEq(vault.listingsThisCycle(), 1, "a same-price relist spends no slot");
    }

    /// @dev A full week in tranches with a partial assignment and a queued redeemer, settled to the
    ///      base unit where the arithmetic is exact.
    ///        alice 20, bob 10; write 4, sell 4 @ $2.00 (vault leg 7_600_000)
    ///        write 6 more, sell 3 @ $2.00 (vault leg 5_700_000); premium 13_300_000
    ///        bob queues 5; 5 of 10 assigned -> 5 NVDA back, 5 * 231 = 1_155_000_000 USDG
    ///        fee 5% of premium only = 665_000; vault NVDA 25e18
    ///        epoch assets = 25e18 * 5e18 / 30e18 = 4_166_666_666_666_666_666
    function test_trancheCycle_partialAssignmentSettlesExactly() public {
        _deposit(alice, 20e18);
        _deposit(bob, 10e18);
        uint256 id = _rollOpen(4);
        _fill(_approveListing(id, 4, _okUnitPrice()), 4);

        _writeMore(6);
        vm.prank(keeper);
        vault.invalidateAllListings();
        _fill(_approveListing(id, 6, _okUnitPrice()), 3);
        vm.prank(bob);
        vault.queueRedeem(5e18);

        _warpToExercise();
        _exercise(id, 5);
        assertEq(vault.contractsAssigned(), 5, "half of the claim assigned, across both tranches");
        assertEq(vault.lockedAssets(), 5e18, "the claim aggregate follows the assignment");
        vault.lockBook();
        _warpToExpiry();
        _rollClose();

        assertEq(vault.contractsWritten(), 0, "flat again");
        assertEq(nvda.balanceOf(address(vault)), 25e18, "30 in, 5 assigned out");
        assertEq(nvda.balanceOf(buyer), 5e18, "the buyer holds exactly what was assigned");
        assertEq(usdg.balanceOf(feeSafe), 665_000, "fee on premium only");
        assertEq(usdg.balanceOf(address(vault)), 13_300_000 + 1_155_000_000 - 665_000, "every other cent stayed");

        uint256 epochAssets = 4_166_666_666_666_666_666;
        assertEq(vault.reservedAssets(), epochAssets, "bob's sixth of the book, set aside");
        assertEq(vault.totalAssets() + epochAssets, 25e18, "and nothing else moved");

        (uint256 assets, uint256 usdgOut) = _completeAs(bob);
        assertEq(assets, epochAssets, "bob's asset leg");
        uint256 net = 13_300_000 + 1_155_000_000 - 665_000;
        uint256 held = vault.claimableUsdg(alice) + vault.claimableUsdg(bob) + usdgOut;
        assertLe(held, net, "never more than the net take");
        assertApproxEqAbs(held, net, 3, "and all of it, less index rounding");
    }

    function _completeAs(address who) internal returns (uint256 assets, uint256 usdgOut) {
        vm.prank(who);
        (assets, usdgOut) = vault.completeRedeem(who);
    }

    /// @dev Sizing is on the TOTAL against idle + locked. With 10 NVDA the limit is 9 contracts in
    ///      all, however it is split; a later deposit raises it, and can be written against.
    function test_writeMore_sizesOnTheTotalAndCountsLateDeposits() public {
        _deposit(alice, 10e18);
        _rollOpen(5);
        _writeMore(4);
        _rejectWriteMore(1, abi.encodeWithSelector(Policy.ContractsAboveUtilization.selector, 10, 9));

        _deposit(bob, 10e18);
        _writeMore(10);
        assertEq(vault.contractsWritten(), 19, "95% of 20 NVDA, in three tranches");
        assertEq(vault.lockedAssets(), 19e18, "bob's stock is now collateral too");
    }

    /*//////////////////////////////////////////////////////////////
                             REVERT PATHS
    //////////////////////////////////////////////////////////////*/

    function test_writeMore_revertsOutsideListed() public {
        _deposit(alice, 30e18);
        _rejectWriteMore(1, abi.encodeWithSelector(Vault.WrongPhase.selector, Vault.Phase.Listed, Vault.Phase.Idle));

        _rollOpen(5);
        _warpToExercise();
        vault.lockBook();
        _rejectWriteMore(
            1, abi.encodeWithSelector(Vault.WrongPhase.selector, Vault.Phase.Listed, Vault.Phase.Exercisable)
        );
    }

    function test_writeMore_revertsForNonKeeperZeroAndHalt() public {
        _open();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, keccak256("KEEPER_ROLE")
            )
        );
        vault.writeMore(1);

        _rejectWriteMore(0, abi.encodeWithSelector(Policy.ContractsZero.selector));

        vm.prank(guardian);
        vault.haltWrites();
        _rejectWriteMore(1, abi.encodeWithSelector(Vault.WritesAreHalted.selector));
    }

    /// @dev No tranche once exercise can start. On the mock (and on Overcall) the write deadline IS
    ///      the exercise time, so the registry refuses first; with a registry that left writing
    ///      open, the vault's own check still holds the line.
    function test_writeMore_revertsOnceExerciseCanStart() public {
        _open();
        vm.warp(exerciseTs - 1);
        feed.setAnswer(SPOT_FEED);
        _writeMore(1);

        vm.warp(exerciseTs);
        feed.setAnswer(SPOT_FEED);
        _rejectWriteMore(1, abi.encodeWithSelector(Vault.WritingNotOpen.selector));

        vm.mockCall(
            address(registry), abi.encodeWithSelector(IOvercallRegistry.isWritingOpen.selector), abi.encode(true)
        );
        _rejectWriteMore(1, abi.encodeWithSelector(Vault.WriteWindowClosed.selector, exerciseTs));
    }

    /// @dev The registry rolling on ends the tranche window, even if it re-approves the same id.
    function test_writeMore_revertsWhenTheRegistryHasMovedOn() public {
        uint256 id = _open();
        registry.setCycleWithStrikes(optionIds, strikes, exerciseTs, expiryTs);
        _rejectWriteMore(1, abi.encodeWithSelector(Vault.OptionNotInCurrentCycle.selector, id, uint32(1), uint32(2)));

        registry.setCycleWithStrikes(new uint256[](0), new uint96[](0), exerciseTs, expiryTs);
        _rejectWriteMore(1, abi.encodeWithSelector(Vault.OptionNotApproved.selector, id));
    }

    function test_writeMore_honoursTheValoremFeeSwitch() public {
        _open();
        clear.setFeesEnabled(true);
        _rejectWriteMore(4, abi.encodeWithSelector(Vault.ValoremFeeNotAccepted.selector, uint8(15)));

        vm.prank(admin);
        vault.acceptValoremFee(true);
        uint256 before = nvda.balanceOf(address(vault));
        _writeMore(4);
        assertEq(before - nvda.balanceOf(address(vault)), 4e18 + 6e15, "collateral plus the 15 bps fee");
        assertEq(nvda.allowance(address(vault), address(clear)), 0, "approval scrubbed after the top-up");
    }

    function test_writeMore_revertsOnAPausedOrStaleOracle() public {
        _open();
        nvda.setOraclePaused(true);
        _rejectWriteMore(1, abi.encodeWithSelector(Vault.OraclePaused.selector));
        nvda.setOraclePaused(false);

        uint256 tooOld = block.timestamp - MAX_PRICE_AGE - 1;
        feed.setUpdatedAt(tooOld);
        _rejectWriteMore(1, abi.encodeWithSelector(Vault.StalePrice.selector, tooOld, uint256(MAX_PRICE_AGE)));
    }

    /// @dev A rally must not let the keeper write more of a rung that is now inside the band floor.
    function test_writeMore_reChecksTheStrikeBandAtLiveSpot() public {
        _open();
        feed.setAnswer(225_00000000);
        _rejectWriteMore(
            1, abi.encodeWithSelector(Policy.StrikeBelowBand.selector, uint256(231_000_000), uint256(231_750_000))
        );
    }

    function test_writeMore_revertsWhenTheTotalPassesTheCap() public {
        _open();
        PolicyParams memory p = Policy.launchDefaults();
        p.maxContractsCap = 8;
        vm.prank(admin);
        vault.setPolicy(p);
        _writeMore(3);
        _rejectWriteMore(1, abi.encodeWithSelector(Policy.ContractsAboveCap.selector, 9, 8));
    }
}
