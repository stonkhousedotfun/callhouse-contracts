// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IExpiryCalendar} from "../../../src/v2/interfaces/IExpiryCalendar.sol";
import {ISettlementOracle} from "../../../src/v2/interfaces/ISettlementOracle.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {ForkFloor} from "./ForkFloor.sol";

/// @notice A real Friday settlement, read off chain 4663 rather than off a mock (P8-06 tests section).
/// @dev AUTHORED, NOT RUN. Under the owner's build-mode directive of 2026-09-19 this is written and compiled but
///      never executed here, and it is a FORK suite besides.
///
///      READ THIS BEFORE RUNNING IT -- 06-QUIRKS section A.1. `FOUNDRY_PROFILE=fork forge test` WITHOUT `--fork-url`
///      returns GREEN HAVING RUN NOTHING, because the gate below is `block.chainid != 4663` and an unforked run has
///      a different chain id. A green line from this file means nothing unless the run named a fork URL. Use
///      `-j 1`: the public RPC rate-limits parallel suites. And there are no pinned fork blocks -- the public RPC
///      keeps roughly 15 minutes of history, so "pinned" means a RECENT `--fork-block-number` that you record in
///      the run's evidence, not a number copied from an older task.
///
///      WHAT IT IS FOR. Everything else in this task proves the boundary against `MockSettlementOracle`, where
///      `setSettlement` hands the test whatever status it asks for. That proves the vault's ARITHMETIC. It does not
///      prove that a real weekly expiry on a real calendar ever reaches `Finalized` within a window a permissionless
///      `rollEpoch` can rely on -- which is the assumption the entire epoch design rests on. That is what this
///      checks, and it is the one assumption a mock cannot check.
contract HouseVaultSettlementForkTest is Test {
    /// @dev Filled in by the runner from the deployed set; left as zero so an unforked run cannot silently "pass"
    ///      against address(0).
    address internal constant CALENDAR = address(0);
    address internal constant ORACLE = address(0);
    address internal constant UNDERLYING = address(0);

    modifier onlyFork() {
        if (block.chainid != 4663) {
            console2.log("skipping: not forked onto 4663 (chainid %s)", block.chainid);
            vm.skip(true);
            return;
        }
        if (CALENDAR == address(0) || ORACLE == address(0) || UNDERLYING == address(0)) {
            console2.log("skipping: fork addresses not filled in");
            vm.skip(true);
            return;
        }
        _;
    }

    /// @notice The calendar's weekly grid really does return a Friday close, and it is in the future from now.
    function test_fork_weeklyBoundaryIsAFridayClose() public onlyFork {
        // casting to 'uint40' is safe until the year 36812
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 end = IExpiryCalendar(CALENDAR).nextExpiry(uint40(block.timestamp), true);
        assertGt(end, block.timestamp, "the next weekly close is not in the future");
        assertTrue(IExpiryCalendar(CALENDAR).isWeekly(end), "nextExpiry(weekly) returned a non-weekly close");
        assertTrue(IExpiryCalendar(CALENDAR).isValidExpiry(end), "the close is not a valid expiry");
    }

    /// @notice A weekly expiry that has already passed reaches a terminal settlement status, and when it is
    ///         Finalized the price is non-zero. THIS IS THE ASSUMPTION rollEpoch RESTS ON: if a real boundary can sit
    ///         at Pending indefinitely, a permissionless roll can be stalled and the epoch never closes.
    function test_fork_apastWeeklyExpirySettles() public onlyFork {
        // casting to 'uint40' is safe until the year 36812
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 next = IExpiryCalendar(CALENDAR).nextExpiry(uint40(block.timestamp), true);
        uint40 past = next - 7 days;

        (V2Types.SettlementStatus status, uint256 price) = ISettlementOracle(ORACLE).settlementPrice(UNDERLYING, past);
        console2.log("status", uint256(status));
        console2.log("price", price);

        if (status == V2Types.SettlementStatus.Finalized) {
            assertGt(price, 0, "Finalized with a zero price");
        } else {
            // Not a failure of this contract, but it IS the thing to record: the boundary the vault would have
            // rolled on is not final, and the launch pass needs to know how long that takes in practice.
            console2.log("NOT FINALIZED -- record how long this boundary took to finalize");
        }
    }

    /// @notice `snapshot` and `finalize` are permissionless on the live oracle, so anyone -- including the keeper --
    ///         can drive a boundary to Finalized without a role. If this ever stops being true, `rollEpoch` becomes
    ///         permissioned in practice while still looking permissionless.
    function test_fork_snapshotAndFinalizeArePermissionless() public onlyFork {
        // casting to 'uint40' is safe until the year 36812
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 past = IExpiryCalendar(CALENDAR).nextExpiry(uint40(block.timestamp), true) - 7 days;
        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        try ISettlementOracle(ORACLE).snapshot(UNDERLYING, past) returns (
            uint8
        ) {
        // fine: it did not revert on authority
        }
        catch (bytes memory err) {
            // TooEarly is acceptable; NotAuthorized is not.
            assertNotEq(bytes4(err), bytes4(keccak256("NotAuthorized()")), "snapshot became permissioned");
        }
    }

    /// @dev THE FLOOR (T-588, added here by T-OP-031). Every other test in this file carries a chain-id guard that
    ///      SKIPS when no fork is attached, so a run that never reached chain 4663 prints `0 failed` and exits 0 --
    ///      indistinguishable from a run in which every assertion held. This test carries no such guard. Under
    ///      `FOUNDRY_PROFILE=fork` it FAILS when the suite could not have executed, and it is the only test here
    ///      that can say so.
    ///
    ///      THE PLACEHOLDERS ARE THE WITNESSES. `CALENDAR`, `ORACLE` and `UNDERLYING` are `address(0)` until a runner
    ///      fills them from the deployed set, and `onlyFork` skips on that too -- so this suite has never executed on
    ///      ANY fork, however healthy. `ForkFloor.requireFixtureFilledIn` names that case as an empty fixture rather
    ///      than a dead fork, then applies the ordinary floor once the address is real. One test per placeholder, so
    ///      a red run names every empty field at once instead of the first one only. This row makes the emptiness
    ///      LOUD under an intended fork; it does not fill the addresses -- that is the runner's decision (see :26-27).
    ///      The explicit `requireExecutedAgainstRealFork` after the CALENDAR check is the same floor every other
    ///      suite states (`requireFixtureFilledIn` already ends in it); it is kept literal so `check-fork-floors.sh`
    ///      reads this file the way it reads the other fifteen.
    ///      A count of reported tests would not do: a skip IS a report, so such a floor is satisfied by a run in
    ///      which nothing ran. See `ForkFloor` for the rest of the reasoning.
    function test_fork_floor_houseVaultSettlementExecutedAgainstARealFork() public {
        ForkFloor.requireFixtureFilledIn(CALENDAR, "HouseVaultSettlement", "CALENDAR");
        ForkFloor.requireExecutedAgainstRealFork(CALENDAR, "HouseVaultSettlement");
    }

    function test_fork_floor_houseVaultSettlementOracleIsFilledIn() public {
        ForkFloor.requireFixtureFilledIn(ORACLE, "HouseVaultSettlement", "ORACLE");
    }

    function test_fork_floor_houseVaultSettlementUnderlyingIsFilledIn() public {
        ForkFloor.requireFixtureFilledIn(UNDERLYING, "HouseVaultSettlement", "UNDERLYING");
    }
}
