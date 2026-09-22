// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {V8AccessTest} from "../lib/V8Access.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {RewardsDistributor} from "../../../src/v2/mm/RewardsDistributor.sol";
import {VerifyLenderRewards} from "../../../script/v2/VerifyLenderRewards.s.sol";

/// @dev A contract with code and no behaviour, standing in for a Safe. The point is only that `code.length != 0`:
///      the checks under test distinguish a CONTRACT holder from a plain key, not one contract from another.
contract SafeStub {}

/// @notice P8-05: the LENDER `RewardsDistributor` -- the second instance, paying the 18-decimal $STONKHOUSE token
///         instead of 6-decimal USDG -- against `test/v2/fixtures/lender-epoch-2960.oz.json`, plus the
///         fail-closed checks in `script/v2/VerifyLenderRewards.s.sol` shown going red and green.
/// @dev WHY 18 DECIMALS NEEDS ITS OWN SUITE. Every existing rewards test is 6-decimal USDG, where a whole epoch
///      fits in a uint64. One hundred 18-dp tokens is 1e20, which does not: anything that narrowed an amount to
///      uint64 somewhere would pass the entire maker suite and silently truncate here. Two of the vector's five
///      amounts are above `type(uint64).max` for exactly that reason.
///
///      THE VECTOR IS THE PINNED ARTIFACT. `script/v2/EmitLenderEpoch.s.sol` produced it, and that generator is
///      itself validated against `maker-epoch-2958.oz.json`, a vector the real OpenZeppelin merkle-tree library
///      produced. P8-05-EPOCH's off-chain generator and P8-05-CLAIM's browser proof check must reproduce this
///      file's root byte for byte, so this suite re-derives it rather than trusting it: every leaf is rebuilt with
///      the §1.9 formula from `src/v2/mm/RewardsDistributor.sol:201` and walked to the published root.
contract LenderRewardsTest is V8AccessTest {
    string internal constant VECTOR = "test/v2/fixtures/lender-epoch-2960.oz.json";

    /// @dev The manifest key the lender instance's three TREASURY_ADMIN rows live under.
    string internal constant TARGET = "RewardsDistributorLender";

    /// @dev `keccak256("Transfer(address,address,uint256)")`, to prove a zero-amount claim moves no tokens.
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    MockERC20 internal stonk;
    RewardsDistributor internal lender;
    VerifyLenderRewards internal verifier;

    /// @dev Holds TREASURY_ADMIN at delay 0 so the mechanics tests can `vm.prank` it straight through.
    address internal opsSafe;
    /// @dev Holds TREASURY_ADMIN at the MANIFEST delay, which is what {VerifyLenderRewards} requires of the
    ///      holder it is given. The two are separate addresses because a member's execution delay cannot be
    ///      changed back and forth mid-test without AccessManager's setback rules getting in the way.
    address internal manifestSafe;
    address internal treasurySafe;
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

    function setUp() public {
        stonk = new MockERC20("Stonkhouse", "STONKHOUSE", 18);
        treasurySafe = address(new SafeStub());
        opsSafe = address(new SafeStub());
        manifestSafe = address(new SafeStub());

        _deployManager();
        lender = new RewardsDistributor(IERC20(address(stonk)), address(manager), treasurySafe);
        _map(address(lender), TARGET);
        _grant(V8Roles.TREASURY_ADMIN, opsSafe, 0);
        _grant(V8Roles.TREASURY_ADMIN, manifestSafe, V8Roles.TREASURY_ADMIN_DELAY);

        verifier = new VerifyLenderRewards();
        vm.label(address(lender), "LenderRewardsDistributor");
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

    /// @dev The 02-interfaces §1.9 leaf, written out here independently of the contract so the two can disagree.
    ///      Mirrors `src/v2/mm/RewardsDistributor.sol:201`.
    function _leaf(uint256 epoch, uint256 index, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(epoch, index, account, amount))));
    }

    function _postVector(Vector memory v) internal {
        stonk.mint(address(lender), v.total);
        vm.prank(opsSafe);
        lender.setRoot(v.epoch, v.root, v.total);
    }

    /*//////////////////////////////////////////////////////////////
                            THE PINNED VECTOR
    //////////////////////////////////////////////////////////////*/

    function test_vector_isWhatTheGeneratorPublished() public view {
        Vector memory v = _vector();
        assertEq(v.epoch, 2960, "epoch");
        assertTrue(v.root != bytes32(0), "a root was published");
        assertEq(v.entries.length, 5, "five entries");

        uint256 sum;
        uint256 aboveUint64;
        uint256 zeros;
        for (uint256 i; i < v.entries.length; ++i) {
            assertEq(v.entries[i].index, i, "index = position in the published values");
            sum += v.entries[i].amount;
            if (v.entries[i].amount > type(uint64).max) ++aboveUint64;
            if (v.entries[i].amount == 0) ++zeros;
        }
        assertEq(sum, v.total, "total = the exact sum of the amounts");
        assertGe(aboveUint64, 1, "at least one amount is above type(uint64).max");
        assertEq(zeros, 1, "exactly one zero-amount entry");
        assertFalse(v.tamperedVerifies, "the fixture says the tampered entry does not verify");
    }

    /// @dev The format check: every published leaf, hashed per §1.9, walks its published proof to the published
    ///      root with OZ `MerkleProof`, and the contract's own `leaf()` is the same hash. This is what the other
    ///      two P8-05 tasks have to reproduce.
    function test_vector_everyLeafProvesToTheRootWithTheSection19Formula() public view {
        Vector memory v = _vector();
        for (uint256 i; i < v.entries.length; ++i) {
            Entry memory e = v.entries[i];
            bytes32 leaf = _leaf(v.epoch, e.index, e.account, e.amount);
            assertEq(lender.leaf(v.epoch, e.index, e.account, e.amount), leaf, "contract leaf == section 1.9 leaf");
            assertEq(MerkleProof.processProof(e.proof, leaf), v.root, string.concat("entry ", vm.toString(i)));
        }
        Entry memory t = v.tampered;
        assertTrue(
            MerkleProof.processProof(t.proof, _leaf(v.epoch, t.index, t.account, t.amount)) != v.root,
            "the tampered leaf does not prove"
        );
    }

    /*//////////////////////////////////////////////////////////////
                         18-DECIMAL ARITHMETIC
    //////////////////////////////////////////////////////////////*/

    function test_everyEntryClaimsItsExact18DecimalAmount() public {
        Vector memory v = _vector();
        _postVector(v);

        for (uint256 i; i < v.entries.length; ++i) {
            Entry memory e = v.entries[i];
            lender.claim(v.epoch, e.index, e.account, e.amount, e.proof);
            assertEq(stonk.balanceOf(e.account), e.amount, "the account was paid its exact amount");
            assertTrue(lender.isClaimed(v.epoch, e.index), "the entry is marked claimed");
        }
        assertEq(stonk.balanceOf(address(lender)), 0, "the epoch paid out exactly its total");
        assertEq(lender.claimedAmount(v.epoch), v.total, "claimedAmount reached the total and no further");
    }

    /// @dev 100 whole 18-dp tokens is 1e20. Anything that narrowed an amount to uint64 anywhere would pass the
    ///      entire 6-decimal maker suite and truncate this to 1e20 mod 2^64.
    function test_anAmountAboveUint64Max_isPaidInFull() public {
        Vector memory v = _vector();
        _postVector(v);

        bool sawBig;
        for (uint256 i; i < v.entries.length; ++i) {
            Entry memory e = v.entries[i];
            if (e.amount <= type(uint64).max) continue;
            sawBig = true;
            lender.claim(v.epoch, e.index, e.account, e.amount, e.proof);
            assertEq(stonk.balanceOf(e.account), e.amount, "an amount above 2^64-1 is paid whole, not truncated");
            assertGt(e.amount, uint256(type(uint64).max), "the entry really is above the uint64 ceiling");
        }
        assertTrue(sawBig, "the vector contains an amount above type(uint64).max");
    }

    /// @dev `RewardsDistributor.sol:137` transfers only when the amount is non-zero. The bit is still written, so
    ///      the entry can never be claimed twice, and no ERC-20 `Transfer` is emitted at all.
    function test_aZeroAmountEntry_isMarkedClaimedWithNoTransfer() public {
        Vector memory v = _vector();
        _postVector(v);

        uint256 idx = type(uint256).max;
        for (uint256 i; i < v.entries.length; ++i) {
            if (v.entries[i].amount == 0) idx = i;
        }
        assertTrue(idx != type(uint256).max, "the vector has a zero-amount entry");
        Entry memory e = v.entries[idx];

        uint256 before = stonk.balanceOf(address(lender));
        vm.recordLogs();
        lender.claim(v.epoch, e.index, e.account, e.amount, e.proof);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 transfers;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(stonk) && logs[i].topics.length != 0 && logs[i].topics[0] == TRANSFER_TOPIC)
            {
                ++transfers;
            }
        }
        assertEq(transfers, 0, "a zero-amount claim emits no ERC-20 Transfer");
        assertTrue(lender.isClaimed(v.epoch, e.index), "the entry is marked claimed anyway");
        assertEq(stonk.balanceOf(address(lender)), before, "the reward balance did not move");

        vm.expectRevert(V2Errors.AlreadyFinal.selector);
        lender.claim(v.epoch, e.index, e.account, e.amount, e.proof);
    }

    function test_theSameEntryCannotBeClaimedTwice() public {
        Vector memory v = _vector();
        _postVector(v);
        Entry memory e = v.entries[0];
        lender.claim(v.epoch, e.index, e.account, e.amount, e.proof);
        vm.expectRevert(V2Errors.AlreadyFinal.selector);
        lender.claim(v.epoch, e.index, e.account, e.amount, e.proof);
    }

    function test_theTamperedEntryIsRefused() public {
        Vector memory v = _vector();
        _postVector(v);
        Entry memory t = v.tampered;
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        lender.claim(v.epoch, t.index, t.account, t.amount, t.proof);
    }

    /*//////////////////////////////////////////////////////////////
                              THE CEILING
    //////////////////////////////////////////////////////////////*/

    /// @dev A MALFORMED tree whose amounts add up to more than the posted total cannot spend another epoch's
    ///      rewards: `RewardsDistributor.sol:132` stops it. Built here with the same two primitives the contract
    ///      uses, because the point is a tree the generator would never produce.
    function test_ceilingExceeded_whenTheTreeSumsAboveTheTotal() public {
        uint256 epoch = 3000;
        address a = makeAddr("lenderA");
        address b = makeAddr("lenderB");
        uint256 amountA = 400e18;
        uint256 amountB = 300e18;

        bytes32 leafA = _leaf(epoch, 0, a, amountA);
        bytes32 leafB = _leaf(epoch, 1, b, amountB);
        bytes32 root = Hashes.commutativeKeccak256(leafA, leafB);

        // The posted total is one base unit short of what the tree would pay.
        uint256 posted = amountA + amountB - 1;
        stonk.mint(address(lender), amountA + amountB);
        vm.prank(opsSafe);
        lender.setRoot(epoch, root, posted);

        bytes32[] memory proofA = new bytes32[](1);
        proofA[0] = leafB;
        bytes32[] memory proofB = new bytes32[](1);
        proofB[0] = leafA;

        lender.claim(epoch, 0, a, amountA, proofA);
        assertEq(stonk.balanceOf(a), amountA, "the first claim is inside the ceiling and pays");

        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        lender.claim(epoch, 1, b, amountB, proofB);
        assertFalse(lender.isClaimed(epoch, 1), "the refused entry stays unclaimed");
        assertEq(stonk.balanceOf(b), 0, "and unpaid");
    }

    /*//////////////////////////////////////////////////////////////
               VerifyLenderRewards: RED, THEN GREEN
    //////////////////////////////////////////////////////////////*/

    /// @dev An epoch with no root, which is what the verifier requires of the epoch about to be posted.
    function _verifyInputs(address instance, address holder)
        internal
        view
        returns (VerifyLenderRewards.Inputs memory in_)
    {
        in_.lender = instance;
        in_.token = IERC20(address(RewardsDistributor(instance).usdg()));
        in_.manager = address(manager);
        in_.treasury = treasurySafe;
        in_.epoch = 2961;
        in_.adminSafe = holder;
        in_.keys = new address[](1);
        in_.keys[0] = stranger;
    }

    function test_verify_isGreenOnAHealthyLenderInstance() public {
        (uint256 passed, uint256 failed) = verifier.check(_verifyInputs(address(lender), manifestSafe));
        assertEq(failed, 0, "a correctly wired lender instance fails nothing");
        assertGt(passed, 0, "and it actually checked something");
    }

    /// @dev PROVE IT BY BREAKING IT (1 of 2): the decimals check. The instance is wired identically -- same
    ///      manager, same mapping, same treasury, same holder -- and the ONLY difference is a 6-decimal reward
    ///      token, the mistake that would pay a millionth of every lender reward without reverting anywhere.
    function test_verify_goesRedWhenTheRewardTokenIsNot18Decimals() public {
        MockERC20 sixDp = new MockERC20("Stonkhouse", "STONKHOUSE", 6);
        RewardsDistributor wrong = new RewardsDistributor(IERC20(address(sixDp)), address(manager), treasurySafe);
        _map(address(wrong), TARGET);

        (uint256 passed, uint256 failed) = verifier.check(_verifyInputs(address(wrong), manifestSafe));
        assertEq(failed, 1, "exactly one check fails, and it is the decimals one");
        assertGt(passed, 0, "everything else still passes, so the failure is isolated");
    }

    /// @dev PROVE IT BY BREAKING IT (2 of 2): the no-plain-key check. Same instance, same wiring; the only
    ///      difference is that TREASURY_ADMIN is held by an EOA rather than by a Safe. An EOA on a 24 h lane is a
    ///      single key that can drain the reward balance to the treasury on its own schedule.
    function test_verify_goesRedWhenAPlainKeyHoldsTreasuryAdmin() public {
        address eoa = makeAddr("aPlainKeyWithTreasuryAdmin");
        assertEq(eoa.code.length, 0, "the stand-in really is a plain key");
        _grant(V8Roles.TREASURY_ADMIN, eoa, V8Roles.TREASURY_ADMIN_DELAY);

        (uint256 passed, uint256 failed) = verifier.check(_verifyInputs(address(lender), eoa));
        assertEq(failed, 1, "exactly one check fails, and it is the contract-holder one");
        assertGt(passed, 0, "everything else still passes, so the failure is isolated");
    }

    /// @dev And the epoch guard: a root can never be replaced (`RewardsDistributor.sol:96`), so verifying against
    ///      an epoch that already has one must fail rather than wave the operator through.
    function test_verify_goesRedWhenTheEpochAlreadyHasARoot() public {
        Vector memory v = _vector();
        _postVector(v);

        VerifyLenderRewards.Inputs memory in_ = _verifyInputs(address(lender), manifestSafe);
        in_.epoch = v.epoch;
        (, uint256 failed) = verifier.check(in_);
        assertEq(failed, 1, "exactly one check fails, and it is the empty-epoch one");
    }
}
