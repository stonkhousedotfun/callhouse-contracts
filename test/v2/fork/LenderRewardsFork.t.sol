// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";
import {V8AccessTest} from "../lib/V8Access.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {RewardsDistributor} from "../../../src/v2/mm/RewardsDistributor.sol";

import {ForkFloor} from "./ForkFloor.sol";

/// @dev Multicall3's batch entry point, the one the web claim path will use to push many claims in one
///      transaction. Only the two structs and the one function this suite needs.
interface IMulticall3 {
    struct Call3 {
        address target;
        bool allowFailure;
        bytes callData;
    }

    struct Result {
        bool success;
        bytes returnData;
    }

    function aggregate3(Call3[] calldata calls) external payable returns (Result[] memory);
}

/// @dev A contract with code and no behaviour, standing in for the Treasury Safe.
contract TreasuryStub {}

/// @notice P8-05 on a fork of chain 4663, against the REAL $STONKHOUSE token: exact delivery on `fund` and on
///         `claim`, twenty-five claims through Multicall3 in one transaction, and the one behaviour that a unit
///         test with a mock could lie about -- a claim that cannot be paid must revert WHOLE and leave the entry
///         claimable.
/// @dev Run with:
///        FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC --match-path "test/v2/fork/LenderRewardsFork.t.sol" -vv
///      Without a fork (chain id != 4663) every test logs and returns, the pattern
///      `test/v2/fork/DataStreamsFork.t.sol` uses.
///
///      THE DISTRIBUTOR IS FRESH, THE TOKEN IS REAL. The lender instance and its `AccessManager` are deployed by
///      this suite so it owns TREASURY_ADMIN and can post a root without the live Safe; what comes off the chain
///      is the TOKEN, which is the part a mock cannot stand in for. A real ERC-20 may take a fee on transfer,
///      round, revert on a zero-value move or freeze an account -- `fund` measures the balance DELTA
///      (`src/v2/mm/RewardsDistributor.sol:149-151`) precisely because the amount asked for and the amount that
///      arrives are not the same number in general.
///
///      THE TOKEN ADDRESS IS RE-DERIVED, NEVER TRUSTED. `v8-plan/impact/IMPACT-contracts.md` records
///      `0xc2525b7c68b6d66dE5AABFEDC7B13314F389D5C4`; that is the DEFAULT this suite starts from and it then calls
///      `decimals()` and `symbol()` on it and REFUSES to run against anything that is not an 18-decimal
///      STONKHOUSE. A wrong address that happens to hold a 6-decimal token would otherwise produce a green fork
///      run proving nothing.
///
///      WHY THE DEFUND CASE IS THE LOAD-BEARING ONE. `claim` writes the claimed bit and the paid amount BEFORE it
///      transfers (`RewardsDistributor.sol:135-137`). Nothing "unsets" the bit on a failed transfer -- the WHOLE
///      call reverting is what preserves it. So the assertion that matters is not that the claim failed; it is
///      that `isClaimed` is still false afterwards and the same proof pays once the balance is back. A posted and
///      unclaimed amount is a permanent liability: a defund does not expire it, and this suite proves that rather
///      than assuming it.
contract LenderRewardsForkTest is V8AccessTest {
    /// @dev The default, from `v8-plan/impact/IMPACT-contracts.md:469`. Checked, not trusted; override with
    ///      `V2_STONKHOUSE_TOKEN`.
    address internal constant STONKHOUSE_DEFAULT = 0xc2525b7c68b6d66dE5AABFEDC7B13314F389D5C4;

    /// @dev The canonical deterministic Multicall3 deployment. Override with `V2_MULTICALL3`.
    address internal constant MULTICALL3_DEFAULT = 0xcA11bde05977b3631167028862bE2a173976CA11;

    uint256 internal constant EPOCH = 2960;
    uint256 internal constant BATCH = 25;

    IERC20 internal stonk;
    RewardsDistributor internal lender;
    address internal treasury;
    address internal funder = makeAddr("funder");

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

        address token = vm.envOr("V2_STONKHOUSE_TOKEN", STONKHOUSE_DEFAULT);
        require(token.code.length != 0, "V2_STONKHOUSE_TOKEN has no code on this fork");
        uint8 d = IERC20Metadata(token).decimals();
        require(d == 18, "the token on this fork is not 18 decimals: the default address is a default, not a fact");
        require(
            keccak256(bytes(IERC20Metadata(token).symbol())) == keccak256("STONKHOUSE"),
            "the token on this fork is not STONKHOUSE"
        );
        stonk = IERC20(token);

        treasury = address(new TreasuryStub());
        _deployManager();
        lender = new RewardsDistributor(stonk, address(manager), treasury);
        _map(address(lender), "RewardsDistributorLender");
        _grant(V8Roles.TREASURY_ADMIN, address(this), 0);
        vm.label(address(lender), "LenderRewardsDistributor");
        vm.label(token, "STONKHOUSE");
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Gives `to` `amount` of the real token, from a real holder when the environment names one and by
    ///      writing the balance slot when it does not. Which path ran is LOGGED: an impersonated holder proves
    ///      the token lets that balance move, a written slot does not.
    function _obtain(address to, uint256 amount) internal {
        address holder = vm.envOr("V2_STONKHOUSE_HOLDER", address(0));
        if (holder != address(0) && stonk.balanceOf(holder) >= amount) {
            console2.log("funding from the impersonated holder %s", holder);
            vm.prank(holder);
            stonk.transfer(to, amount);
            return;
        }
        console2.log("no V2_STONKHOUSE_HOLDER with enough balance: writing the balance slot instead");
        deal(address(stonk), to, amount);
    }

    /// @dev The §1.9 leaf, mirroring `src/v2/mm/RewardsDistributor.sol:201`.
    function _leaf(uint256 epoch, uint256 index, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(epoch, index, account, amount))));
    }

    /// @dev A balanced tree over `n` power-of-two leaves, built with the same sorted-pair hash OZ `MerkleProof`
    ///      verifies with. Returns the root and, for each leaf, its proof.
    function _tree(bytes32[] memory leaves) internal pure returns (bytes32 root, bytes32[][] memory proofs) {
        uint256 n = leaves.length;
        require(n != 0 && (n & (n - 1)) == 0, "this helper builds power-of-two trees only");

        uint256 depth;
        for (uint256 w = n; w > 1; w >>= 1) {
            ++depth;
        }
        proofs = new bytes32[][](n);
        for (uint256 i; i < n; ++i) {
            proofs[i] = new bytes32[](depth);
        }

        bytes32[] memory level = leaves;
        for (uint256 d; d < depth; ++d) {
            uint256 half = level.length / 2;
            bytes32[] memory next = new bytes32[](half);
            for (uint256 i; i < half; ++i) {
                next[i] = Hashes.commutativeKeccak256(level[2 * i], level[2 * i + 1]);
            }
            // Every original leaf under node `i` at this depth takes the sibling of `i` as its next proof element.
            uint256 span = n / level.length;
            for (uint256 i; i < level.length; ++i) {
                bytes32 sibling = level[i ^ 1];
                for (uint256 k; k < span; ++k) {
                    proofs[i * span + k][d] = sibling;
                }
            }
            level = next;
        }
        root = level[0];
    }

    /*//////////////////////////////////////////////////////////////
                           EXACT DELIVERY
    //////////////////////////////////////////////////////////////*/

    function test_fork_fundReportsWhatActuallyArrived() public onlyFork {
        uint256 amount = 1_000e18;
        _obtain(funder, amount);

        uint256 beforeLender = stonk.balanceOf(address(lender));
        uint256 beforeFunder = stonk.balanceOf(funder);

        vm.startPrank(funder);
        stonk.approve(address(lender), amount);
        uint256 received = lender.fund(amount);
        vm.stopPrank();

        uint256 delta = stonk.balanceOf(address(lender)) - beforeLender;
        assertEq(received, delta, "fund() returns the measured balance delta, not the amount asked for");
        assertEq(beforeFunder - stonk.balanceOf(funder), amount, "the funder paid exactly what it asked to pay");
        // On a token with no transfer fee these are the same number; the assertion above is what holds either way.
        assertEq(received, amount, "this token takes no fee on transfer");
    }

    function test_fork_claimPaysTheExactAmountAndRecordsGas() public onlyFork {
        (bytes32 root, bytes32[][] memory proofs, address[] memory accounts, uint256[] memory amounts, uint256 total) =
            _epochOf(4);

        _fundAndPost(root, total);

        for (uint256 i; i < accounts.length; ++i) {
            uint256 before = stonk.balanceOf(accounts[i]);
            uint256 gasBefore = gasleft();
            lender.claim(EPOCH, i, accounts[i], amounts[i], proofs[i]);
            console2.log("claim %s gas: %s", i, gasBefore - gasleft());
            assertEq(stonk.balanceOf(accounts[i]) - before, amounts[i], "the account was paid its exact amount");
        }
    }

    /*//////////////////////////////////////////////////////////////
                        TWENTY-FIVE IN ONE BATCH
    //////////////////////////////////////////////////////////////*/

    /// @dev 25 claims in ONE transaction through Multicall3, which is how the web will push a whole epoch. The
    ///      tree is 32 leaves (the helper builds power-of-two trees); the last seven are simply not claimed here.
    function test_fork_twentyFiveClaimsInOneMulticall3Batch() public onlyFork {
        address multicall = vm.envOr("V2_MULTICALL3", MULTICALL3_DEFAULT);
        require(multicall.code.length != 0, "Multicall3 has no code on this fork: set V2_MULTICALL3");

        (bytes32 root, bytes32[][] memory proofs, address[] memory accounts, uint256[] memory amounts, uint256 total) =
            _epochOf(32);
        _fundAndPost(root, total);

        IMulticall3.Call3[] memory calls = new IMulticall3.Call3[](BATCH);
        for (uint256 i; i < BATCH; ++i) {
            calls[i] = IMulticall3.Call3({
                target: address(lender),
                allowFailure: false,
                callData: abi.encodeCall(RewardsDistributor.claim, (EPOCH, i, accounts[i], amounts[i], proofs[i]))
            });
        }

        uint256 gasBefore = gasleft();
        IMulticall3.Result[] memory results = IMulticall3(multicall).aggregate3(calls);
        uint256 used = gasBefore - gasleft();
        console2.log("25 claims in one aggregate3: %s gas total, %s per claim", used, used / BATCH);

        for (uint256 i; i < BATCH; ++i) {
            assertTrue(results[i].success, "every claim in the batch succeeded");
            assertEq(stonk.balanceOf(accounts[i]), amounts[i], "each account was paid its exact amount");
            assertTrue(lender.isClaimed(EPOCH, i), "each entry is marked claimed");
        }
        assertFalse(lender.isClaimed(EPOCH, BATCH), "the entries outside the batch are untouched");
    }

    /*//////////////////////////////////////////////////////////////
              DEFUND DOES NOT EXPIRE A POSTED CLAIM
    //////////////////////////////////////////////////////////////*/

    function test_fork_claimAfterDefundRevertsWholeAndTheEntryStaysClaimable() public onlyFork {
        (bytes32 root, bytes32[][] memory proofs, address[] memory accounts, uint256[] memory amounts, uint256 total) =
            _epochOf(4);
        _fundAndPost(root, total);

        // TREASURY_ADMIN takes the whole reward balance back to the treasury. Every posted-but-unclaimed amount is
        // still owed; nothing here expires it.
        uint256 balance = stonk.balanceOf(address(lender));
        lender.defund(balance);
        assertEq(stonk.balanceOf(address(lender)), 0, "the reward balance is gone");
        assertEq(stonk.balanceOf(treasury), balance, "and it went to the treasury, the only place it can go");

        // The claim is valid and unpayable. The whole call must revert: the claimed bit was written before the
        // transfer, so a partial success would burn the entry.
        vm.expectRevert();
        lender.claim(EPOCH, 0, accounts[0], amounts[0], proofs[0]);

        assertFalse(lender.isClaimed(EPOCH, 0), "the entry is STILL unclaimed after the failed claim");
        assertEq(lender.claimedAmount(EPOCH), 0, "and nothing was recorded as paid");
        assertEq(stonk.balanceOf(accounts[0]), 0, "and the account received nothing");

        // A later refill pays the same proof, unchanged. No new root, no re-publication.
        _obtain(funder, total);
        vm.startPrank(funder);
        stonk.approve(address(lender), total);
        lender.fund(total);
        vm.stopPrank();

        lender.claim(EPOCH, 0, accounts[0], amounts[0], proofs[0]);
        assertEq(stonk.balanceOf(accounts[0]), amounts[0], "the same proof pays in full once the balance is back");
        assertTrue(lender.isClaimed(EPOCH, 0), "and only now is the entry claimed");
    }

    /*//////////////////////////////////////////////////////////////
                             EPOCH SETUP
    //////////////////////////////////////////////////////////////*/

    /// @dev `n` entries whose amounts are all above `type(uint64).max`, which is what an 18-decimal reward of any
    ///      realistic size is.
    function _epochOf(uint256 n)
        internal
        returns (
            bytes32 root,
            bytes32[][] memory proofs,
            address[] memory accounts,
            uint256[] memory amounts,
            uint256 total
        )
    {
        accounts = new address[](n);
        amounts = new uint256[](n);
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            accounts[i] = makeAddr(string.concat("lender", vm.toString(i)));
            amounts[i] = 100e18 + i * 1e18;
            require(amounts[i] > type(uint64).max, "an 18-decimal reward is above the uint64 ceiling");
            total += amounts[i];
            leaves[i] = _leaf(EPOCH, i, accounts[i], amounts[i]);
        }
        (root, proofs) = _tree(leaves);
    }

    function _fundAndPost(bytes32 root, uint256 total) internal {
        _obtain(funder, total);
        vm.startPrank(funder);
        stonk.approve(address(lender), total);
        lender.fund(total);
        vm.stopPrank();
        lender.setRoot(EPOCH, root, total);
        assertEq(lender.root(EPOCH), root, "the root is posted");
    }

    /// @dev THE FLOOR (T-588). Every other test in this file carries a chain-id guard that SKIPS when no fork is
    ///      attached, so a run that never reached chain 4663 prints `0 failed` and exits 0 -- indistinguishable from
    ///      a run in which every invariant held. This test carries no such guard. Under `FOUNDRY_PROFILE=fork` it
    ///      FAILS when the suite could not have executed, and it is the only test here that can say so.
    ///
    ///      Its witness is `STONKHOUSE_DEFAULT`, an address this suite's own tests read.
    ///      A count of reported tests would not do: a skip IS a report, so such a floor is satisfied by a run in
    ///      which nothing ran. See `ForkFloor` for the rest of the reasoning.
    function test_fork_floor_lenderRewardsForkExecutedAgainstARealFork() public {
        ForkFloor.requireExecutedAgainstRealFork(STONKHOUSE_DEFAULT, "LenderRewardsFork");
    }
}
