// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @notice Writes `test/v2/fixtures/lender-epoch-2960.oz.json`: the 18-decimal reference vector for the LENDER
///         `RewardsDistributor` instance (P8-05), in the same shape as `maker-epoch-2958.oz.json`. Read-only, no
///         RPC, no broadcast.
///
///           forge script script/v2/EmitLenderEpoch.s.sol
///
/// @dev WHY THIS FILE EXISTS AT ALL, and why it is Solidity. The lender vector is a PINNED ARTIFACT: P8-05-EPOCH's
///      off-chain generator and P8-05-CLAIM's browser-side proof check must both reproduce its root byte for byte,
///      so the root has to be exactly what OpenZeppelin's merkle-tree package would produce with
///      `StandardMerkleTree.of`. That package is not installed anywhere in this workspace and nothing here may
///      install one, so the tree is built from the two primitives the contract itself uses -- the §1.9
///      double-hashed leaf (`src/v2/mm/RewardsDistributor.sol:201`) and OpenZeppelin's sorted-pair node hash
///      (`Hashes.commutativeKeccak256`, what `MerkleProof` verifies with).
///
///      A REIMPLEMENTATION THAT IS NEVER TRUSTED ON ITS OWN WORD. {_control} rebuilds `maker-epoch-2958.oz.json`
///      -- a vector that WAS produced by the real OpenZeppelin library -- from that file's own published values, and
///      requires both the root AND every published proof to come back identical before this script is allowed to
///      emit anything. A builder that reproduces a real OZ vector is OZ-equivalent; without that control this file
///      would be publishing a guessed constant, which is the exact failure `F8-02`'s wrong selector pins were.
///
///      THE ALGORITHM, mirrored from `StandardMerkleTree.of(values, types)` with its DEFAULTS (the `source` line of
///      `maker-epoch-2958.oz.json` records `default sortLeaves`):
///        1. leaf[k]   = keccak256(bytes.concat(keccak256(abi.encode(epoch, index, account, amount))))
///        2. the leaves are SORTED ascending by hash (a 32-byte big-endian compare is a uint256 compare)
///        3. `tree` has `2n-1` nodes; sorted leaf `i` lands at `tree[2n-2-i]`, and every internal node is
///           `commutativeKeccak256(tree[2i+1], tree[2i+2])`, computed from the back
///        4. a proof walks `sibling(i) = i odd ? i+1 : i-1` up to the root
///      Nothing here is retyped from prose: the leaf formula mirrors `RewardsDistributor.sol:201`.
contract EmitLenderEpoch is Script {
    string internal constant OUT = "test/v2/fixtures/lender-epoch-2960.oz.json";

    /// @dev The known-good OpenZeppelin vector this script's tree builder is validated against.
    string internal constant CONTROL = "test/v2/fixtures/maker-epoch-2958.oz.json";

    /// @dev Weeks since Monday 1970-01-05 00:00 UTC, two epochs after the maker vector.
    uint256 internal constant EPOCH = 2960;

    struct Value {
        uint256 index;
        address account;
        uint256 amount;
    }

    /// @notice The epoch's values, in published order: `index` IS the position.
    /// @dev Chosen to exercise what 6-decimal USDG never did. Entry 0 and entry 1 are both above
    ///      `type(uint64).max` (18_446_744_073_709_551_615), which 100 and 2_500 whole 18-dp tokens are and no
    ///      realistic USDG reward ever was; entry 3 is a ZERO amount, which {RewardsDistributor.claim} marks
    ///      claimed without a transfer; entry 4 is a sub-token dust amount that is not a round number of wei, so a
    ///      generator that rounds to 6 dp or to whole tokens cannot reproduce it.
    function values() public pure returns (Value[] memory v) {
        v = new Value[](5);
        v[0] = Value(0, 0x1111111111111111111111111111111111111111, 100e18);
        v[1] = Value(1, 0x2222222222222222222222222222222222222222, 2500e18);
        v[2] = Value(2, 0x3333333333333333333333333333333333333333, 1e18);
        v[3] = Value(3, 0x4444444444444444444444444444444444444444, 0);
        v[4] = Value(4, 0x5555555555555555555555555555555555555555, 123_456_789_012_345_678);
    }

    /*//////////////////////////////////////////////////////////////
                          THE OZ TREE, REBUILT
    //////////////////////////////////////////////////////////////*/

    /// @notice The StandardMerkleTree leaf of one entry, mirroring `src/v2/mm/RewardsDistributor.sol:201`.
    function leafOf(uint256 epoch, uint256 index, address account, uint256 amount) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(epoch, index, account, amount))));
    }

    /// @notice Builds the tree over `leaves` in published order.
    /// @return tree The `2n-1` nodes, root at 0.
    /// @return treeIndexOf `treeIndexOf[k]` is where published entry `k` sits in `tree` after the leaf sort.
    function build(bytes32[] memory leaves) public pure returns (bytes32[] memory tree, uint256[] memory treeIndexOf) {
        uint256 n = leaves.length;
        require(n != 0, "empty tree");

        // Sorted copy, carrying each leaf's published position with it. Insertion sort: n is a handful of entries
        // and a stable, obviously-correct sort matters more here than its cost.
        bytes32[] memory sorted = new bytes32[](n);
        uint256[] memory origin = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            bytes32 h = leaves[i];
            uint256 k = i;
            while (k != 0 && uint256(sorted[k - 1]) > uint256(h)) {
                sorted[k] = sorted[k - 1];
                origin[k] = origin[k - 1];
                --k;
            }
            sorted[k] = h;
            origin[k] = i;
        }

        tree = new bytes32[](2 * n - 1);
        for (uint256 i; i < n; ++i) {
            tree[tree.length - 1 - i] = sorted[i];
        }
        // Internal nodes, from the deepest back to the root. `n - 1` of them, so the loop is skipped for n == 1.
        for (uint256 i = n - 1; i != 0;) {
            --i;
            tree[i] = Hashes.commutativeKeccak256(tree[2 * i + 1], tree[2 * i + 2]);
        }

        treeIndexOf = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            treeIndexOf[origin[i]] = tree.length - 1 - i;
        }
    }

    /// @notice The proof of the node at `treeIndex`: every sibling on the way up, deepest first.
    function proofOf(bytes32[] memory tree, uint256 treeIndex) public pure returns (bytes32[] memory proof) {
        uint256 depth;
        for (uint256 i = treeIndex; i != 0; i = (i - 1) / 2) {
            ++depth;
        }
        proof = new bytes32[](depth);
        uint256 k;
        for (uint256 i = treeIndex; i != 0; i = (i - 1) / 2) {
            proof[k++] = tree[i % 2 == 1 ? i + 1 : i - 1];
        }
    }

    /*//////////////////////////////////////////////////////////////
                              THE CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @dev Rebuilds `maker-epoch-2958.oz.json` from its own published values and requires the root AND every
    ///      published proof back, identical. The proofs matter as much as the root: a root can match while the
    ///      sibling ORDER is wrong, and it is the proofs the other two P8-05 tasks will actually carry.
    function _control() internal view {
        string memory json = vm.readFile(CONTROL);
        uint256 epoch = vm.parseJsonUint(json, ".epoch");
        bytes32 want = vm.parseJsonBytes32(json, ".root");

        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".entries[", vm.toString(n), "]"))) {
            ++n;
        }
        require(n != 0, "control vector has no entries");

        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            string memory k = string.concat(".entries[", vm.toString(i), "]");
            leaves[i] = leafOf(
                epoch,
                vm.parseJsonUint(json, string.concat(k, ".index")),
                vm.parseJsonAddress(json, string.concat(k, ".account")),
                vm.parseUint(vm.parseJsonString(json, string.concat(k, ".amount")))
            );
        }

        (bytes32[] memory tree, uint256[] memory treeIndexOf) = build(leaves);
        require(tree[0] == want, "control: rebuilt root != the published OpenZeppelin root");

        for (uint256 i; i < n; ++i) {
            bytes32[] memory got = proofOf(tree, treeIndexOf[i]);
            bytes32[] memory published =
                vm.parseJsonBytes32Array(json, string.concat(".entries[", vm.toString(i), "].proof"));
            require(got.length == published.length, "control: proof length differs");
            for (uint256 j; j < got.length; ++j) {
                require(got[j] == published[j], "control: proof element differs");
            }
        }
        console2.log("control ok: %s rebuilt from its own values, root and all proofs identical", CONTROL);
    }

    /*//////////////////////////////////////////////////////////////
                                 EMIT
    //////////////////////////////////////////////////////////////*/

    function run() public {
        _control();

        Value[] memory v = values();
        uint256 n = v.length;
        bytes32[] memory leaves = new bytes32[](n);
        uint256 total;
        for (uint256 i; i < n; ++i) {
            require(v[i].index == i, "index must be the published position");
            leaves[i] = leafOf(EPOCH, v[i].index, v[i].account, v[i].amount);
            total += v[i].amount;
        }

        (bytes32[] memory tree, uint256[] memory treeIndexOf) = build(leaves);
        bytes32 root = tree[0];

        string[] memory rows = new string[](n);
        for (uint256 i; i < n; ++i) {
            bytes32[] memory proof = proofOf(tree, treeIndexOf[i]);
            // Self-check before the value is written: the emitted proof must verify against the emitted root with
            // the same OZ verifier the contract calls.
            require(MerkleProof.processProof(proof, leaves[i]) == root, "emitted proof does not prove its leaf");

            string memory key = string.concat("entry", vm.toString(i));
            vm.serializeUint(key, "index", v[i].index);
            vm.serializeAddress(key, "account", v[i].account);
            vm.serializeString(key, "amount", vm.toString(v[i].amount));
            rows[i] = vm.serializeBytes32(key, "proof", proof);
        }

        // The tampered entry: entry 0's account and proof with one more base unit of reward. It must NOT verify,
        // which is the property a consumer's proof check is actually being asked to have.
        {
            bytes32[] memory proof0 = proofOf(tree, treeIndexOf[0]);
            uint256 tamperedAmount = v[0].amount + 1;
            require(
                MerkleProof.processProof(proof0, leafOf(EPOCH, v[0].index, v[0].account, tamperedAmount)) != root,
                "the tampered entry must not prove"
            );
            vm.serializeUint("tampered", "index", v[0].index);
            vm.serializeAddress("tampered", "account", v[0].account);
            vm.serializeString("tampered", "amount", vm.toString(tamperedAmount));
            vm.serializeBytes32("tampered", "proof", proof0);
            vm.serializeBool("tampered", "verifies", false);
        }

        string[] memory types_ = new string[](4);
        types_[0] = "uint256";
        types_[1] = "uint256";
        types_[2] = "address";
        types_[3] = "uint256";

        vm.serializeString(
            "root",
            "source",
            string.concat(
                "@openzeppelin/merkle-tree StandardMerkleTree.of, default sortLeaves -- rebuilt by ",
                "callhouse-contracts script/v2/EmitLenderEpoch.s.sol and validated against ",
                CONTROL
            )
        );
        vm.serializeString("root", "generatedBy", "callhouse-contracts script/v2/EmitLenderEpoch.s.sol");
        vm.serializeString("root", "decimals", "18");
        vm.serializeString("root", "types", types_);
        vm.serializeUint("root", "epoch", EPOCH);
        vm.serializeBytes32("root", "root", root);
        vm.serializeString("root", "total", vm.toString(total));
        vm.serializeString("root", "entries", rows);
        string memory json = vm.serializeString("root", "tampered", vm.serializeBool("tampered", "verifies", false));
        vm.writeJson(json, OUT);
        // writeJson ends the file at the closing brace; a committed text file ends with a newline.
        vm.writeLine(OUT, "");

        console2.log("wrote %s entries to %s", n, OUT);
        console2.log("epoch %s root:", EPOCH);
        console2.logBytes32(root);
        console2.log("total (18 dp base units): %s", vm.toString(total));
    }
}
