// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {ForkFloor} from "./ForkFloor.sol";

/// @notice Authored under build mode, NOT RUN as a shipping gate.
/// @dev `FOUNDRY_PROFILE=fork forge test` without `--fork-url` is green having run nothing (06-QUIRKS.md §A.1).
contract HedgerForkTest is Test {
    address internal constant MORPHO = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;

    modifier onlyFork() {
        if (block.chainid != 4663) {
            console2.log("skipping: not forked onto 4663 (chainid %s)", block.chainid);
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        if (block.chainid != 4663) return;
    }

    function test_fork_morphoHasCodeOn4663() public onlyFork {
        assertGt(MORPHO.code.length, 0, "4663 Morpho 0x9D53..1010");
    }

    /// @dev THE FLOOR (T-588, added here by T-OP-031). Every other test in this file carries a chain-id guard that
    ///      SKIPS when no fork is attached, so a run that never reached chain 4663 prints `0 failed` and exits 0 --
    ///      indistinguishable from a run in which every assertion held. This test carries no such guard. Under
    ///      `FOUNDRY_PROFILE=fork` it FAILS when the suite could not have executed, and it is the only test here
    ///      that can say so.
    ///
    ///      Its witness is `MORPHO`, the one address this suite's only test reads.
    ///      A count of reported tests would not do: a skip IS a report, so such a floor is satisfied by a run in
    ///      which nothing ran. See `ForkFloor` for the rest of the reasoning.
    function test_fork_floor_hedgerForkExecutedAgainstARealFork() public {
        ForkFloor.requireExecutedAgainstRealFork(MORPHO, "HedgerFork");
    }
}
