// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

/// @notice The floor every fork suite asserts: that its bodies actually EXECUTED against a real fork, rather than
///         that its tests were reported.
///
/// @dev THE DEFECT THIS EXISTS FOR. Every fork suite in this repository guards its tests with a chain-id check and
///      `vm.skip(true)`. That is correct behaviour on its own -- a suite that cannot reach the chain should not
///      pretend to check it -- but it means a run in which NOTHING executed prints `0 failed` and exits 0. A green
///      fork run and a fork that never connected are the same observation from outside. Until the owner's standing
///      network grant that was a known and harmless hole, because nobody ran these suites; from the moment lanes
///      started running them against live 4663, a green run began to be read as evidence.
///
///      WHY A COUNT OF REPORTED TESTS IS THE WRONG FIX, and is forbidden by this row's contract. A SKIP IS A REPORT.
///      A floor of the form "at least N tests reported" is satisfied by a run in which every one of those N tests
///      skipped, which reproduces the exact defect inside the guard written to catch it. The floor below is not a
///      count of anything: it is an assertion, in a test that does NOT carry the suite's skip guard, that the
///      preconditions under which bodies can execute are actually present.
///
///      WHAT IT CHECKS, and why it is two things rather than one. `block.chainid` says a fork is attached and which
///      chain it is. `witness.code.length` says that fork actually SERVES STATE for an address this suite's own
///      tests depend on -- an RPC that answers `eth_chainId` and nothing else, or one whose state at the requested
///      block has been pruned, passes the first check and fails the second. The pruned case is not hypothetical:
///      `FlywheelRouteFork`'s recorded block 67,296,505 still serves its HEADER while `eth_call` at that block
///      returns `-32000 historical state is not available`.
///
///      WHEN IT IS ALLOWED TO SKIP, which is the one judgement in this file. A plain `forge test` runs these files
///      too -- `[profile.default]` has no `match_path` -- and it is not asking for a fork, so a floor that failed
///      there would turn every ordinary test run red. The floor therefore fires only when a fork was INTENDED:
///      `FOUNDRY_PROFILE=fork`, which is exactly how `.github/workflows/ci.yml:54` and every runbook invokes these
///      suites, or the explicit `FORK_FLOOR_STRICT=true` opt-in. Intent is read from the environment and never
///      inferred from the chain id, because the chain id is the thing under test.
library ForkFloor {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Robinhood Chain. Mirrored from the suites' own guards, not re-reasoned.
    uint256 internal constant FORK_CHAIN_ID = 4663;

    /// @dev True when the caller asked for a fork run. `FOUNDRY_PROFILE=fork` is the documented invocation;
    ///      `FORK_FLOOR_STRICT=true` exists so a runner that selects these paths some other way can still demand
    ///      the floor.
    function forkIntended() internal view returns (bool) {
        if (VM.envOr("FORK_FLOOR_STRICT", false)) return true;
        return keccak256(bytes(VM.envOr("FOUNDRY_PROFILE", string("")))) == keccak256(bytes("fork"));
    }

    /// @notice Fail unless this suite is running against a fork that serves state for `witness`.
    /// @param witness An address THIS suite's tests read. It must be one whose absence makes the suite meaningless,
    ///        so that a fork serving an empty or wrong state cannot satisfy the floor.
    /// @param suite The suite's name, so a red run names which floor fired without the reader opening the file.
    function requireExecutedAgainstRealFork(address witness, string memory suite) internal {
        if (block.chainid != FORK_CHAIN_ID) {
            if (!forkIntended()) {
                // No fork was asked for: the suite's own guards will skip its tests, and so does this one.
                VM.skip(true);
                return;
            }
            revert(
                string.concat(
                    "FORK FLOOR: ",
                    suite,
                    " was run under the fork profile but is not on chain 4663, so every test in it skipped and the",
                    " run proved nothing. This failure is the floor, not the suite."
                )
            );
        }
        if (witness.code.length == 0) {
            revert(
                string.concat(
                    "FORK FLOOR: ",
                    suite,
                    " is on chain 4663 but its witness address has no code, so the fork is not serving the state",
                    " this suite reads -- a pruned block or the wrong endpoint. This failure is the floor."
                )
            );
        }
    }

    /// @notice The floor for a suite whose fork addresses are UNFILLED placeholders.
    /// @dev `HouseVaultSettlement` pins `CALENDAR`, `ORACLE` and `UNDERLYING` as `address(0)` with the comment
    ///      "filled in by the runner from the deployed set", and skips when they are zero. That is a second,
    ///      DIFFERENT defect from the one this library exists for: the suite cannot execute on ANY fork, however
    ///      healthy, so it has never checked the assumption its own NatSpec says a mock cannot check. It gets its own
    ///      message so a red run does not read as "the fork is down" when the fork is fine and the fixture is empty.
    function requireFixtureFilledIn(address witness, string memory suite, string memory field) internal {
        if (witness == address(0)) {
            if (!forkIntended()) {
                VM.skip(true);
                return;
            }
            revert(
                string.concat(
                    "FORK FLOOR: ",
                    suite,
                    " cannot execute on any fork because its `",
                    field,
                    "` is still the address(0) placeholder, so every test in it has always skipped. This is not the",
                    " fork being unavailable -- fill the address from the deployed set, or delete the suite."
                )
            );
        }
        requireExecutedAgainstRealFork(witness, suite);
    }
}
