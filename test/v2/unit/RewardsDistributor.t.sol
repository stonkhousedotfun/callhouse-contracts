// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {BaseV2Test} from "../BaseV2.t.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {IRewardsDistributor} from "../../../src/v2/interfaces/IRewardsDistributor.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {RewardsDistributor} from "../../../src/v2/mm/RewardsDistributor.sol";

/// @notice RewardsDistributor (C2-11) against the OpenZeppelin StandardMerkleTree vector X2-03 published
///         (callhouse v2 01cd882, indexer/src/v2/fixtures/maker-epoch-2958.oz.json, copied byte for byte to
///         test/v2/fixtures/), plus double claims, wrong proofs, epoch roll, bitmap words and the total ceiling.
/// @dev Trees for the other epochs are built here with the §1.9 leaf and OZ's sorted-pair hash, the same two
///      primitives the contract uses, so they test the claim logic; the fixture tests the format itself.
contract RewardsDistributorTest is BaseV2Test {
    string internal constant VECTOR = "test/v2/fixtures/maker-epoch-2958.oz.json";

    RewardsDistributor internal dist;
    address internal stranger = makeAddr("stranger");

    struct Entry {
        uint256 index;
        address account;
        uint256 amount;
        bytes32[] proof;
    }

    struct Vector {
        uint256 epoch;
        bytes32 root;
        uint256 total;
        Entry[] entries;
        Entry tampered;
        bool tamperedVerifies;
    }

    function _deployCore() internal override {
        dist = _newDistributor(IERC20(address(usdg)), treasury, admin);
        usdg.mint(address(dist), 10_000_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                                FIXTURE
    //////////////////////////////////////////////////////////////*/

    function _entry(string memory json, string memory key) internal pure returns (Entry memory e) {
        e.index = vm.parseJsonUint(json, string.concat(key, ".index"));
        e.account = vm.parseJsonAddress(json, string.concat(key, ".account"));
        e.amount = vm.parseUint(vm.parseJsonString(json, string.concat(key, ".amount")));
        e.proof = vm.parseJsonBytes32Array(json, string.concat(key, ".proof"));
    }

    function _vector() internal view returns (Vector memory v) {
        string memory json = vm.readFile(VECTOR);
        v.epoch = vm.parseJsonUint(json, ".epoch");
        v.root = vm.parseJsonBytes32(json, ".root");
        v.total = vm.parseUint(vm.parseJsonString(json, ".total"));
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".entries[", vm.toString(n), "]"))) {
            ++n;
        }
        v.entries = new Entry[](n);
        for (uint256 i; i < n; ++i) {
            v.entries[i] = _entry(json, string.concat(".entries[", vm.toString(i), "]"));
        }
        v.tampered = _entry(json, ".tampered");
        v.tamperedVerifies = vm.parseJsonBool(json, ".tampered.verifies");
    }

    function _setVectorRoot(Vector memory v) internal {
        vm.prank(admin);
        dist.setRoot(v.epoch, v.root, v.total);
    }

    /// @dev The 02-interfaces §1.9 leaf, written out independently of the contract.
    function _leaf(uint256 epoch, uint256 index, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(epoch, index, account, amount))));
    }

    /*//////////////////////////////////////////////////////////////
                           THE X2-03 VECTOR
    //////////////////////////////////////////////////////////////*/

    function test_vector_isWhatThePlanPublished() public view {
        Vector memory v = _vector();
        assertEq(v.epoch, 2958, "epoch");
        assertEq(v.root, 0xbaf77ffed3c63b4f37de4ac3510116b613e912df932c670f6ddba5bc78da6cb8, "root");
        assertEq(v.total, 1_750_001, "total");
        assertEq(v.entries.length, 4, "four proofs");
        uint256 sum;
        for (uint256 i; i < v.entries.length; ++i) {
            assertEq(v.entries[i].index, i, "index = position in the values");
            sum += v.entries[i].amount;
        }
        assertEq(sum, v.total, "total = sum of amounts");
        assertFalse(v.tamperedVerifies, "the fixture says the tampered entry does not verify");
    }

    /// @dev The format check itself: each published leaf, hashed per §1.9, walks its proof to the published root with OZ
    ///      MerkleProof, and the contract's leaf() is the same hash.
    function test_vector_everyLeafProvesToTheRootWithTheSection19Formula() public view {
        Vector memory v = _vector();
        for (uint256 i; i < v.entries.length; ++i) {
            Entry memory e = v.entries[i];
            bytes32 leaf = _leaf(v.epoch, e.index, e.account, e.amount);
            assertEq(dist.leaf(v.epoch, e.index, e.account, e.amount), leaf, "contract leaf == section 1.9 leaf");
            assertEq(MerkleProof.processProof(e.proof, leaf), v.root, string.concat("entry ", vm.toString(i)));
        }
        Entry memory t = v.tampered;
        assertTrue(
            MerkleProof.processProof(t.proof, _leaf(v.epoch, t.index, t.account, t.amount)) != v.root,
            "tampered leaf does not prove"
        );
    }

    function test_vector_setRootAndClaimEveryEntry() public {
        Vector memory v = _vector();
        vm.expectEmit(address(dist));
        emit IRewardsDistributor.RootSet(v.epoch, v.root, v.total);
        _setVectorRoot(v);
        assertEq(dist.root(v.epoch), v.root);
        assertEq(dist.totalOf(v.epoch), v.total);

        uint256 distBefore = usdg.balanceOf(address(dist));
        for (uint256 i; i < v.entries.length; ++i) {
            Entry memory e = v.entries[i];
            assertFalse(dist.isClaimed(v.epoch, e.index), "unclaimed");
            vm.expectEmit(address(dist));
            emit IRewardsDistributor.Claimed(v.epoch, e.index, e.account, e.amount);
            vm.prank(keeper); // anyone may push; the account is paid
            dist.claim(v.epoch, e.index, e.account, e.amount, e.proof);
            assertEq(usdg.balanceOf(e.account), e.amount, "paid to the account");
            assertTrue(dist.isClaimed(v.epoch, e.index), "claimed");
        }
        assertEq(usdg.balanceOf(keeper), 0, "the caller gets nothing");
        assertEq(distBefore - usdg.balanceOf(address(dist)), v.total, "paid exactly the total");
        assertEq(dist.claimedAmount(v.epoch), v.total);
        assertEq(dist.claimedWord(v.epoch, 0), 0xf, "bits 0-3 of word 0");
    }

    function test_vector_tamperedEntryRejected() public {
        Vector memory v = _vector();
        _setVectorRoot(v);
        Entry memory t = v.tampered;
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        dist.claim(v.epoch, t.index, t.account, t.amount, t.proof);
        assertFalse(dist.isClaimed(v.epoch, t.index), "nothing marked");

        Entry memory e = v.entries[0];
        dist.claim(v.epoch, e.index, e.account, e.amount, e.proof);
        assertEq(usdg.balanceOf(e.account), 700_000, "the genuine entry still claims");
    }

    function test_vector_doubleClaimReverts() public {
        Vector memory v = _vector();
        _setVectorRoot(v);
        Entry memory e = v.entries[2];
        dist.claim(v.epoch, e.index, e.account, e.amount, e.proof);
        vm.expectRevert(V2Errors.AlreadyFinal.selector);
        dist.claim(v.epoch, e.index, e.account, e.amount, e.proof);
        vm.prank(e.account);
        vm.expectRevert(V2Errors.AlreadyFinal.selector);
        dist.claim(v.epoch, e.index, e.account, e.amount, e.proof);
        assertEq(usdg.balanceOf(e.account), e.amount, "paid once");
    }

    function test_vector_wrongProofIndexAccountOrEpochReverts() public {
        Vector memory v = _vector();
        _setVectorRoot(v);
        Entry memory e0 = v.entries[0];
        Entry memory e1 = v.entries[1];

        vm.expectRevert(V2Errors.NotAuthorized.selector);
        dist.claim(v.epoch, e0.index, e0.account, e0.amount, e1.proof); // another entry's proof
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        dist.claim(v.epoch, e1.index, e0.account, e0.amount, e0.proof); // wrong index
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        dist.claim(v.epoch, e0.index, e1.account, e0.amount, e0.proof); // entry 0's reward to entry 1's account
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        dist.claim(v.epoch, e0.index, e0.account, e0.amount, new bytes32[](0)); // no proof
        vm.expectRevert(V2Errors.NoSource.selector);
        dist.claim(v.epoch + 1, e0.index, e0.account, e0.amount, e0.proof); // epoch without a root
    }

    /*//////////////////////////////////////////////////////////////
                                 ROOTS
    //////////////////////////////////////////////////////////////*/

    function test_setRoot_oncePerEpochTreasuryAdminOnlyNonZero() public {
        Vector memory v = _vector();
        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        dist.setRoot(v.epoch, v.root, v.total);

        vm.prank(admin);
        vm.expectRevert(V2Errors.NoSource.selector);
        dist.setRoot(v.epoch, bytes32(0), v.total);

        _setVectorRoot(v);
        vm.prank(admin);
        vm.expectRevert(V2Errors.AlreadyFinal.selector);
        dist.setRoot(v.epoch, keccak256("another root"), 1);
        assertEq(dist.root(v.epoch), v.root, "the first root stands");
        assertEq(dist.root(v.epoch + 1), bytes32(0), "no root elsewhere");
    }

    function test_claimBeforeRootReverts() public {
        Vector memory v = _vector();
        Entry memory e = v.entries[0];
        vm.expectRevert(V2Errors.NoSource.selector);
        dist.claim(v.epoch, e.index, e.account, e.amount, e.proof);
    }

    /*//////////////////////////////////////////////////////////////
                    EPOCH ROLL, BITMAP WORDS, CEILING
    //////////////////////////////////////////////////////////////*/

    /// @dev Root of a two-leaf tree and the proof of each leaf.
    function _pair(bytes32 a, bytes32 b)
        internal
        pure
        returns (bytes32 root, bytes32[] memory proofA, bytes32[] memory proofB)
    {
        root = Hashes.commutativeKeccak256(a, b);
        proofA = new bytes32[](1);
        proofA[0] = b;
        proofB = new bytes32[](1);
        proofB[0] = a;
    }

    function test_epochRoll_bitmapsAndRootsAreIndependent() public {
        Vector memory v = _vector();
        _setVectorRoot(v);
        Entry memory e = v.entries[0];
        dist.claim(v.epoch, e.index, e.account, e.amount, e.proof);

        uint256 next = v.epoch + 1;
        (bytes32 root, bytes32[] memory proof0, bytes32[] memory proof1) =
            _pair(_leaf(next, 0, e.account, 5e6), _leaf(next, 1, carol, 7e6));
        vm.prank(admin);
        dist.setRoot(next, root, 12e6);

        assertFalse(dist.isClaimed(next, 0), "index 0 of the next epoch is fresh");
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        dist.claim(next, e.index, e.account, e.amount, e.proof); // last week's proof does not work this week
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        dist.claim(v.epoch, 1, carol, 7e6, proof1); // nor this week's proof last week

        dist.claim(next, 0, e.account, 5e6, proof0);
        dist.claim(next, 1, carol, 7e6, proof1);
        assertEq(usdg.balanceOf(e.account), 700_000 + 5e6, "both weeks paid");
        assertEq(usdg.balanceOf(carol) - ACTOR_USDG, 7e6);
        assertFalse(dist.isClaimed(v.epoch, 1), "last week's other entries untouched");
        assertEq(dist.claimedAmount(next), 12e6);
    }

    function test_bitmapWordBoundary() public {
        uint256 epoch = 3_000;
        (bytes32 root, bytes32[] memory proof255, bytes32[] memory proof256) =
            _pair(_leaf(epoch, 255, alice, 1e6), _leaf(epoch, 256, bob, 2e6));
        vm.prank(admin);
        dist.setRoot(epoch, root, 3e6);

        dist.claim(epoch, 255, alice, 1e6, proof255);
        assertEq(dist.claimedWord(epoch, 0), 1 << 255, "last bit of word 0");
        assertEq(dist.claimedWord(epoch, 1), 0);
        assertFalse(dist.isClaimed(epoch, 256));

        dist.claim(epoch, 256, bob, 2e6, proof256);
        assertEq(dist.claimedWord(epoch, 1), 1, "first bit of word 1");
        assertTrue(dist.isClaimed(epoch, 256));
    }

    function test_claimsNeverExceedTheEpochTotal() public {
        uint256 epoch = 3_001;
        (bytes32 root, bytes32[] memory proofA, bytes32[] memory proofB) =
            _pair(_leaf(epoch, 0, alice, 6e6), _leaf(epoch, 1, bob, 5e6));
        vm.prank(admin);
        dist.setRoot(epoch, root, 10e6); // the tree promises 11, the posted total is 10

        dist.claim(epoch, 0, alice, 6e6, proofA);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        dist.claim(epoch, 1, bob, 5e6, proofB);
        assertFalse(dist.isClaimed(epoch, 1));
    }

    function test_zeroAmountEntryIsMarkedWithoutTransfer() public {
        uint256 epoch = 3_002;
        usdg.freeze(carol); // a zero-value transfer to a frozen address would revert on the live token
        (bytes32 root, bytes32[] memory proofA,) = _pair(_leaf(epoch, 0, carol, 0), _leaf(epoch, 1, bob, 1));
        vm.prank(admin);
        dist.setRoot(epoch, root, 1);
        dist.claim(epoch, 0, carol, 0, proofA);
        assertTrue(dist.isClaimed(epoch, 0));
    }

    function testFuzz_bitmapIsolation(uint256 index, uint256 other, address account, uint256 amount) public {
        vm.assume(index != other);
        vm.assume(account != address(0) && account != address(dist));
        amount = bound(amount, 1, 1_000_000e6);
        uint256 epoch = 2_958;
        (bytes32 root, bytes32[] memory proof,) = _pair(_leaf(epoch, index, account, amount), keccak256("sibling"));
        vm.prank(admin);
        dist.setRoot(epoch, root, amount);
        dist.claim(epoch, index, account, amount, proof);
        assertTrue(dist.isClaimed(epoch, index));
        assertFalse(dist.isClaimed(epoch, other), "no other index is marked");
    }

    /*//////////////////////////////////////////////////////////////
                         FUNDING AND FAILURES
    //////////////////////////////////////////////////////////////*/

    function test_frozenAccountCanClaimLater() public {
        Vector memory v = _vector();
        _setVectorRoot(v);
        Entry memory e = v.entries[1];
        usdg.freeze(e.account);
        vm.expectRevert(MockERC20.AddressFrozen.selector);
        dist.claim(v.epoch, e.index, e.account, e.amount, e.proof);
        assertFalse(dist.isClaimed(v.epoch, e.index), "reverted whole");
        usdg.unfreeze(e.account);
        dist.claim(v.epoch, e.index, e.account, e.amount, e.proof);
        assertEq(usdg.balanceOf(e.account), e.amount);
    }

    function test_unfundedClaimRevertsAndStaysClaimable() public {
        Vector memory v = _vector();
        _setVectorRoot(v);
        uint256 balance = usdg.balanceOf(address(dist));
        vm.prank(admin);
        dist.defund(balance);
        Entry memory e = v.entries[0];
        vm.expectRevert();
        dist.claim(v.epoch, e.index, e.account, e.amount, e.proof);
        assertFalse(dist.isClaimed(v.epoch, e.index));
    }

    function test_fundAndDefund() public {
        vm.startPrank(alice);
        usdg.approve(address(dist), 100e6);
        vm.expectEmit(address(dist));
        emit RewardsDistributor.Funded(alice, 100e6);
        assertEq(dist.fund(100e6), 100e6);
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        dist.defund(1);

        vm.expectEmit(address(dist));
        emit RewardsDistributor.Defunded(treasury, 50e6);
        vm.prank(admin);
        dist.defund(50e6);
        assertEq(usdg.balanceOf(treasury), 50e6);
        assertEq(dist.authority(), address(manager), "the AccessManager is the authority");
    }

    /// @dev INTERFACE_VERSION 8: rewards leave only to {treasury}. The v7 form with a free recipient is deleted, so
    ///      nothing answers that selector, and the pointer moves only under TREASURY_ADMIN.
    function test_defund_paysTheTreasuryAndNowhereElse() public {
        address next = makeAddr("nextTreasury");
        (bool ok,) = address(dist).call(abi.encodeWithSignature("defund(address,uint256)", stranger, uint256(1)));
        assertFalse(ok, "defund(address,uint256) is deleted in v8");

        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        dist.setTreasury(stranger);

        vm.prank(admin);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        dist.setTreasury(address(0));

        vm.expectEmit(address(dist));
        emit IRewardsDistributor.TreasurySet(next);
        vm.prank(admin);
        dist.setTreasury(next);

        vm.prank(admin);
        dist.defund(25e6);
        assertEq(usdg.balanceOf(next), 25e6, "the exit followed the pointer");
        assertEq(usdg.balanceOf(stranger), 0, "and nothing reached anyone else");
    }

    function test_constructor_rejectsBadArgs() public {
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        new RewardsDistributor(IERC20(address(0xdead)), address(manager), treasury);
        // A code-less authority would make every restricted call revert with no way back.
        vm.expectRevert(V2Errors.NoSource.selector);
        new RewardsDistributor(IERC20(address(usdg)), address(0), treasury);
        vm.expectRevert(V2Errors.NoSource.selector);
        new RewardsDistributor(IERC20(address(usdg)), makeAddr("eoaAuthority"), treasury);
        // Rewards must always have somewhere to go back to.
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        new RewardsDistributor(IERC20(address(usdg)), address(manager), address(0));
    }
}
