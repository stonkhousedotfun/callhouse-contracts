// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PinnedRuntimesBase} from "./PinnedRuntimesBase.t.sol";
import {VerifyV8} from "../../../script/v2/VerifyV8.s.sol";
import {V2DeployBase} from "../../../script/v2/lib/V2DeployBase.sol";

/// @notice C3-101, offline: the pinned runtimes of the live set are self-consistent and reproduce the chain's code hash
///         exactly, and VerifyV8 compares a live address with its pinned artifact -- only that address, under that
///         registry name, on chain 4663 -- masking the immutable slots and nothing else. The fork suite
///         (test/v2/fork/PinnedRuntimesFork.t.sol) runs the same comparison against the chain itself.
contract VerifyV8PinnedTest is PinnedRuntimesBase {
    VerifyV8 internal verify;
    string internal m;

    function setUp() public {
        verify = new VerifyV8();
        m = _manifest();
    }

    /// The manifest pins exactly the 13 of the set, for chain 4663, from one full commit SHA built with the settings
    /// this repository compiles with (foundry.toml: solc 0.8.28, via-IR, 200 runs, cancun, no metadata hash).
    function test_manifest_pinsTheSetFromOneCommit() public view {
        assertEq(verify.PINNED_MANIFEST(), MANIFEST, "VerifyV8 reads this manifest");
        assertEq(vm.parseJsonUint(m, ".chainId"), 4663, "chain 4663");
        string memory rev = vm.parseJsonString(m, ".source.rev");
        assertEq(bytes(rev).length, 40, "a full commit SHA");
        assertEq(vm.parseJsonKeys(m, ".contracts").length, 13, "13 contracts, no more");
        assertEq(vm.parseJsonString(m, ".source.compiler.solc"), "0.8.28+commit.7893614a", "solc");
        assertTrue(vm.parseJsonBool(m, ".source.compiler.viaIR"), "via-IR");
        assertTrue(vm.parseJsonBool(m, ".source.compiler.optimizer"), "optimizer");
        assertEq(vm.parseJsonUint(m, ".source.compiler.optimizerRuns"), 200, "200 runs");
        assertEq(vm.parseJsonString(m, ".source.compiler.evmVersion"), "cancun", "cancun");
        assertEq(vm.parseJsonString(m, ".source.compiler.bytecodeHash"), "none", "no metadata hash in the CBOR tail");

        string[13] memory names = _names();
        for (uint256 i; i < names.length; ++i) {
            string memory e = _entry(names[i]);
            string memory art = vm.readFile(_pinnedPath(m, names[i]));
            assertEq(vm.parseJsonString(art, ".sourceRev"), rev, "every pinned file is from the manifest's commit");
            assertEq(
                vm.parseJsonString(art, ".contractName"),
                vm.parseJsonString(m, string.concat(e, ".contract")),
                "the file is the contract the manifest names"
            );
            assertTrue(vm.parseJsonBool(m, string.concat(e, ".match")), "proven against the chain when pinned");
            assertEq(
                keccak256(_artifactRuntime(m, names[i])),
                vm.parseJsonBytes32(m, string.concat(e, ".runtimeArtifactKeccak")),
                "the pinned runtime is the one the manifest hashed"
            );
            assertTrue(
                vm.parseJsonBool(m, string.concat(e, ".deploy.creationInputIsArtifactPlusArgs")),
                "the deploy transaction created it from this commit's creation bytecode"
            );
        }
    }

    /// Offline proof: pinned artifact + the recorded immutable words == the runtime whose keccak the chain reported as
    /// the account's code hash, and the recorded words sit exactly on the artifact's immutable references.
    function test_manifest_artifactPlusRecordedWordsIsTheChainCodeHash() public view {
        string[13] memory names = _names();
        for (uint256 i; i < names.length; ++i) {
            string memory e = _entry(names[i]);
            bytes memory live = _liveRuntime(m, names[i]);
            assertEq(live.length, vm.parseJsonUint(m, string.concat(e, ".codeSize")), "code size");
            assertEq(keccak256(live), vm.parseJsonBytes32(m, string.concat(e, ".codeHash")), names[i]);

            // the words cover the artifact's immutable references one to one
            string memory art = vm.readFile(_pinnedPath(m, names[i]));
            string[] memory ids; // forge writes no `immutableReferences` for a contract without immutables
            if (vm.keyExistsJson(art, ".deployedBytecode.immutableReferences")) {
                ids = vm.parseJsonKeys(art, ".deployedBytecode.immutableReferences");
            }
            uint256 refs;
            uint256 masked;
            for (uint256 k; k < ids.length; ++k) {
                Ref[] memory r = abi.decode(
                    vm.parseJson(art, string.concat(".deployedBytecode.immutableReferences.", ids[k])), (Ref[])
                );
                refs += r.length;
                for (uint256 j; j < r.length; ++j) {
                    masked += r[j].length;
                }
            }
            assertEq(_words(m, names[i]).length, refs, "one recorded word per immutable reference");
            assertEq(masked, vm.parseJsonUint(m, string.concat(e, ".maskedBytes")), "masked bytes");
        }
    }

    /// A pin applies to the recorded address under its registry name on chain 4663, and to nothing else.
    function test_pinnedArtifact_onlyThatNameAddressAndChain() public {
        address ch = _pinnedAddress(m, "clearinghouse");
        (bool pinned,,) = verify.pinnedArtifact("clearinghouse", ch);
        assertFalse(pinned, "not on another chain (31337): a test or local set is compared with out/");

        vm.chainId(4663);
        string memory path;
        string memory rev;
        (pinned, path, rev) = verify.pinnedArtifact("clearinghouse", ch);
        assertTrue(pinned, "the recorded address under its name on 4663");
        assertEq(path, "script/artifacts/v2-4663/Clearinghouse.json", "its pinned artifact");
        assertEq(rev, vm.parseJsonString(m, ".source.rev"), "the deployed commit");

        (pinned,,) = verify.pinnedArtifact("clearinghouse", makeAddr("freshClearinghouse"));
        assertFalse(pinned, "a fresh deploy (a rehearsal's new set) is compared with out/");
        (pinned,,) = verify.pinnedArtifact("orderBook", ch);
        assertFalse(pinned, "the Clearinghouse's address under another name is not pinned");
        (pinned,,) = verify.pinnedArtifact("feeSplitter", ch);
        assertFalse(pinned, "a name the manifest does not list");
    }

    /// The comparison masks the immutable slots and nothing else: another word in a slot still matches (its value is
    /// VerifyV8's `immutables` group, through the getters), one flipped byte anywhere else or one more byte does not.
    function test_runtimeMatches_masksImmutableSlotsOnly() public {
        vm.chainId(4663);
        address ch = _pinnedAddress(m, "clearinghouse");
        string memory path = _pinnedPath(m, "clearinghouse");
        bytes memory live = _liveRuntime(m, "clearinghouse");
        vm.etch(ch, live);
        assertTrue(verify.runtimeMatches(ch, path), "the live runtime");

        Word[] memory w = _words(m, "clearinghouse");
        assertGt(w.length, 0, "the Clearinghouse has immutables (USDG)");
        bytes memory other = bytes.concat(live);
        bytes32 word = keccak256("another USDG");
        uint256 start = w[0].start;
        assembly ("memory-safe") {
            mstore(add(add(other, 32), start), word)
        }
        vm.etch(ch, other);
        assertTrue(verify.runtimeMatches(ch, path), "another word in an immutable slot: masked");

        bytes memory flipped = bytes.concat(live);
        flipped[flipped.length - 2] = flipped[flipped.length - 2] ^ 0x01; // the CBOR tail, never executed
        vm.etch(ch, flipped);
        assertFalse(verify.runtimeMatches(ch, path), "one flipped byte outside the slots");

        vm.etch(ch, bytes.concat(live, hex"00"));
        assertFalse(verify.runtimeMatches(ch, path), "one byte more");
    }

    /// VerifyV8's bytecode group on the live runtimes at the pinned addresses: 13 ok; one tampered byte, one FAIL.
    function test_checkBytecode_pinnedSet() public {
        vm.chainId(4663);
        string[13] memory names = _names();
        for (uint256 i; i < names.length; ++i) {
            vm.etch(_pinnedAddress(m, names[i]), _liveRuntime(m, names[i]));
        }
        V2DeployBase.Contracts memory c = _pinnedSet(m);
        (uint256 passed, uint256 failed) = verify.checkBytecode(c);
        // INTERFACE_VERSION 8: `_set` is 16 and this manifest pins the THIRTEEN contracts that are live on 4663
        // today. The three v8 additions -- accessManager, flywheel.feeSplitter, flywheel.buybackExecutor -- have no
        // live v7 address, so they are absent from the pinned set and VerifyV8 says so instead of passing them.
        // That is the right answer for a v7 run-off set and it flips to 16/0 once the v8 set is deployed and pinned;
        // asserting 13/0 here would have required VerifyV8 to skip an address it cannot find, which is exactly the
        // silent-skip this suite exists to prevent.
        assertEq(passed, 13, "the 13 live v7 runtimes match");
        assertEq(failed, 3, "the 3 v8-only contracts are not in the v7 pinned set");

        bytes memory code = c.clearinghouse.code;
        code[0] = code[0] ^ 0x01;
        vm.etch(c.clearinghouse, code);
        (passed, failed) = verify.checkBytecode(c);
        assertEq(passed, 12, "the other 12");
        assertEq(failed, 4, "the clearinghouse runtime, plus the same 3 absentees");
    }
}
