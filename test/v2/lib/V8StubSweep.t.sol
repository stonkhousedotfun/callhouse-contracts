// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/// @notice C8-09b v8-stub sweep. Does NOT demand that no `v8-stub` marker remains: C8-13's OrderBook
///         pre-fund labels are downstream of C8-09, so "empty" is unsatisfiable. It fails when a marker
///         is present in a file owned by a C8-09 dependency (T-151 / C8-03), and it fails when the tree
///         stops matching the table below.
/// @dev     T-500 REBUILT THIS FILE. The previous version asserted nothing about the repository: every
///          argument was a string literal the test itself passed in, its `hits` parameter was declared
///          `uint256 /* hits */` and discarded, and it never opened a file, so it passed unconditionally
///          and could not detect a new marker, a removed one, or a changed count.
///
///          Its stated reason for not reading the tree -- that `fs_permissions` does not allow reading
///          `src/` -- WAS NOT TRUE. `foundry.toml` grants `{ access = "read", path = "./src" }` (added by
///          T-186 for CoreNatSpecLanes.t.sol), so the sources have been readable from tests since then.
///          This version reads them.
///
///          T-505 CLOSED THE GAP T-500 LEFT. `script/v2/RegisterMarkets.s.sol` was excluded because
///          `fs_permissions` did not reach it; foundry.toml now grants that ONE FILE by name, so it is back in
///          the table below and the UNREADABLE exclusion constant is gone with it. The grant is deliberately the single file
///          rather than `./script` or `./script/v2`: a grant wider than the need is a permission nobody
///          remembers giving, and keeping the rest of `./script` unreadable is what lets
///          {test_anUngrantedPathRevertsRatherThanCountingZero} prove this file's fail-closed arm against a
///          path `fs_permissions` genuinely refuses.
///
///          THE MAINTENANCE COST, carried forward from T-500 and restated because it is the thing most likely
///          to undo this file: a legitimate marker change now makes {test_tableStillMatchesTheTree} RED, and
///          someone must update the table and say why in the commit. That is the point of it. If a future lane
///          clears that red by deleting the test or loosening a count instead, the repo is back where it
///          started with extra steps and a green suite that proves nothing.
///
///          `ffi = false`, so the scan is `vm.readFile` plus a byte search in Solidity, not a shell grep.
contract V8StubSweepTest is Test {
    /// @dev The marker this sweep counts.
    string internal constant MARKER = "v8-stub";

    /// @dev A real, committed source that `fs_permissions` does NOT grant -- `./script` is not granted, only
    ///      `./script/v2/RegisterMarkets.s.sol` and `./script/v2/roles.v8.json` by name. It is read by
    ///      {test_anUngrantedPathRevertsRatherThanCountingZero} to prove the fail-closed arm on a genuinely
    ///      refused path rather than a contrived one. If a future grant widens to `./script`, that test goes
    ///      GREEN-BUT-MEANINGLESS -- it asserts a revert that would no longer happen, so it fails loudly
    ///      instead, and whoever widens the grant must pick a different ungranted path here.
    string internal constant UNGRANTED_PROBE = "script/v2/DeployV8.s.sol";

    /// @notice Every marker-bearing file, its owning task, and the count READ FROM THE TREE when this
    ///         table was last updated. A mismatch is a failure in either direction: a new marker, a
    ///         removed one, or a changed count all mean the table no longer describes the repository.
    /// @dev    Counts re-derived at contracts 6c2ec45a337787b15fc925cd2c9f0cda58c4b023. Note that
    ///         `src/v2/OrderBook.sol` carried 2 in the old table and carries 0 here: the markers went and
    ///         nothing noticed, because the old table's count was never compared to anything. That drift
    ///         is the clearest argument for this rebuild.
    function _table() internal pure returns (string[] memory paths, string[] memory owners, uint256[] memory expected) {
        paths = new string[](6);
        owners = new string[](6);
        expected = new uint256[](6);

        paths[0] = "src/v2/OrderBook.sol";
        owners[0] = "C8-13";
        expected[0] = 0;

        paths[1] = "src/v2/interfaces/V2Constants.sol";
        owners[1] = "C8-01..C8-05";
        expected[1] = 1;

        paths[2] = "src/v2/mocks/MockClearinghouse.sol";
        owners[2] = "C8-02";
        expected[2] = 5;

        paths[3] = "src/v2/mm/MakerVault.sol";
        owners[3] = "C8-05";
        expected[3] = 0;

        paths[4] = "src/v2/mm/RewardsDistributor.sol";
        owners[4] = "C8-05";
        expected[4] = 0;

        // Back in the table at T-505, once foundry.toml granted this one file by name.
        paths[5] = "script/v2/RegisterMarkets.s.sol";
        owners[5] = "C8-10";
        expected[5] = 0;
    }

    /// @notice A marker in a file owned by a C8-09 dependency is a failure. This is the invariant the file
    ///         has always claimed to enforce; it is now derived from the file's contents rather than from
    ///         the owner string beside it.
    function test_noV8StubRemainsInAC809DependencyFile() public view {
        (string[] memory paths, string[] memory owners,) = _table();
        for (uint256 i = 0; i < paths.length; i++) {
            uint256 hits = _countMarkers(paths[i]);
            if (hits != 0 && _ownerIsC809Dependency(owners[i])) {
                revert(
                    string.concat(
                        "v8-stub owned by a C8-09 dependency still present: ",
                        paths[i],
                        " ",
                        owners[i],
                        " hits=",
                        vm.toString(hits)
                    )
                );
            }
        }
    }

    /// @notice The table must keep describing the tree. Reads every listed file and compares the real count
    ///         against the recorded one, so a marker added to or removed from ANY listed file fails here --
    ///         including in a file whose owner is not a C8-09 dependency, which the old file could never do.
    function test_tableStillMatchesTheTree() public view {
        (string[] memory paths,, uint256[] memory expected) = _table();
        for (uint256 i = 0; i < paths.length; i++) {
            uint256 hits = _countMarkers(paths[i]);
            assertEq(
                hits,
                expected[i],
                string.concat(
                    "v8-stub count changed for ",
                    paths[i],
                    ": table says ",
                    vm.toString(expected[i]),
                    ", tree has ",
                    vm.toString(hits),
                    " -- update this table and say why in the commit"
                )
            );
        }
    }

    /// @notice The sweep must be looking at files that exist. A path typo, or a source that moved, would
    ///         otherwise read as a clean zero forever.
    function test_everyListedPathExists() public view {
        (string[] memory paths,,) = _table();
        for (uint256 i = 0; i < paths.length; i++) {
            assertTrue(vm.exists(paths[i]), string.concat("listed path does not exist: ", paths[i]));
        }
    }

    /// @notice POSITIVE CONTROL for the counter itself. A counter that always returned zero would make every
    ///         assertion above pass, which is the exact failure this file is being rebuilt out of.
    function test_counterCanCount() public pure {
        assertEq(_count("", MARKER), 0, "empty haystack");
        assertEq(_count("nothing here", MARKER), 0, "no marker");
        assertEq(_count("v8-stub", MARKER), 1, "one marker, whole string");
        assertEq(_count("a v8-stub b", MARKER), 1, "one marker, embedded");
        assertEq(_count("v8-stubv8-stub", MARKER), 2, "two adjacent");
        assertEq(_count("x v8-stub y v8-stub z v8-stub", MARKER), 3, "three separated");
        assertEq(_count("v8-stu", MARKER), 0, "prefix is not a match");
    }

    /// @notice THE FAIL-CLOSED ARM, which T-500 left unproven and this row exists to prove. An unreadable
    ///         source must REVERT, not be counted as zero markers -- a path nobody can read is not a path with
    ///         nothing in it. {UNGRANTED_PROBE} is a real committed file that `fs_permissions` refuses.
    /// @dev    The positive control is the half that makes this load-bearing: the same external entry point,
    ///         called on a GRANTED file, must return a real count. Without it a wrapper that reverted on
    ///         everything would satisfy the revert case and prove nothing.
    function test_anUngrantedPathRevertsRatherThanCountingZero() public {
        // NOTE: this test cannot call vm.exists on the probe -- vm.exists needs read permission too, so it
        // reverts on exactly the paths this test is about. That the probe is a real committed file is
        // established OUTSIDE the test (`git ls-files script/v2/DeployV8.s.sol`) and asserted below by the
        // REASON the read fails: "not allowed to be accessed" is a permission refusal, which a path that did
        // not exist would not produce.
        try this.countMarkersExternal(UNGRANTED_PROBE) returns (uint256 n) {
            revert(
                string.concat(
                    "FAIL-CLOSED ARM BROKEN: reading the ungranted path ",
                    UNGRANTED_PROBE,
                    " returned ",
                    vm.toString(n),
                    " instead of reverting. Either fs_permissions now grants it -- in which case pick another "
                    "ungranted path for UNGRANTED_PROBE -- or _countMarkers is swallowing the error."
                )
            );
        } catch (bytes memory err) {
            // A bare `catch` would accept ANY revert, including a typo in the probe path, and would be the
            // same class of defect this file was rebuilt out of. Assert on the REASON.
            assertGt(
                _count(string(err), "not allowed to be accessed"),
                0,
                string.concat("reverted for the WRONG reason, so this proves nothing: ", string(err))
            );
        }

        // POSITIVE CONTROL: the granted file reads and counts through the very same entry point.
        assertEq(this.countMarkersExternal("script/v2/RegisterMarkets.s.sol"), 0, "granted file must be readable");
    }

    /// @dev External so the test can `try`/`catch` it; `_countMarkers` is internal and its revert cannot be
    ///      caught across an internal call.
    function countMarkersExternal(string calldata path) external view returns (uint256) {
        return _countMarkers(path);
    }

    /// @dev Reads the file and counts {MARKER}. Reverts if the file cannot be read, which is the right
    ///      behaviour: an unreadable source must not count as a clean zero. Proven by
    ///      {test_anUngrantedPathRevertsRatherThanCountingZero}. NEVER wrap this in a try/catch that returns
    ///      zero -- that converts the fail-closed arm into a silent pass and is worse than the exclusion it
    ///      would replace.
    function _countMarkers(string memory path) internal view returns (uint256) {
        return _count(vm.readFile(path), MARKER);
    }

    /// @dev Occurrences of `needle` in `haystack`, counting overlaps as distinct starts.
    function _count(string memory haystack, string memory needle) internal pure returns (uint256 n) {
        bytes memory h = bytes(haystack);
        bytes memory nd = bytes(needle);
        if (nd.length == 0 || h.length < nd.length) return 0;
        for (uint256 i = 0; i + nd.length <= h.length; i++) {
            bool same = true;
            for (uint256 j = 0; j < nd.length; j++) {
                if (h[i + j] != nd[j]) {
                    same = false;
                    break;
                }
            }
            if (same) n++;
        }
    }

    function _ownerIsC809Dependency(string memory owner) internal pure returns (bool) {
        bytes32 h = keccak256(bytes(owner));
        return h == keccak256("C8-03") || h == keccak256("T-151") || h == keccak256("T-151-C8-03-REBASE2");
    }
}
