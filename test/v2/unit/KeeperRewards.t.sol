// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {KeeperRewards} from "../../../src/v2/KeeperRewards.sol";
import {IKeeperRewards} from "../../../src/v2/interfaces/IKeeperRewards.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";

/// @notice A USDG stand-in that misbehaves on demand, for the failure paths MockERC20 cannot produce: a transfer that
///         returns false or a dirty bool, no return data at all, a balance read that reverts or returns nothing, and a
///         fee on transferFrom (to prove {fund} measures the delta).
/// @dev Private to this suite (C2-01 owns the shared v2 token mocks).
contract QuirkyUSDG is ERC20 {
    enum Mode {
        Normal,
        RevertTransfer,
        ReturnFalse,
        NoReturnData,
        DirtyTrue,
        RevertBalanceOf,
        EmptyBalanceOf,
        FeeOnTransferFrom
    }

    Mode public mode;

    constructor() ERC20("Quirky USDG", "qUSDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (mode == Mode.RevertTransfer) revert("QuirkyUSDG: blocked");
        if (mode == Mode.ReturnFalse) return false;
        bool ok = super.transfer(to, value);
        if (mode == Mode.NoReturnData) {
            assembly {
                return(0, 0)
            }
        }
        if (mode == Mode.DirtyTrue) {
            // Moves the tokens, then answers 2: not a valid ABI bool.
            assembly {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return ok;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (mode != Mode.FeeOnTransferFrom) return super.transferFrom(from, to, value);
        // 1 % is burned in flight, so the recipient receives 99 % of `value`.
        uint256 fee = value / 100;
        _spendAllowance(from, msg.sender, value);
        _burn(from, fee);
        _transfer(from, to, value - fee);
        return true;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (mode == Mode.RevertBalanceOf) revert("QuirkyUSDG: no balance");
        if (mode == Mode.EmptyBalanceOf) {
            assembly {
                return(0, 0)
            }
        }
        return super.balanceOf(account);
    }
}

/// @notice `src/v2/KeeperRewards.sol` (task C2-07, architecture §3.7, ADR-06): registered callers only, bounties under
///         MAX_BOUNTY, payment = min(bounty, cap remaining, balance), never a revert for a failing budget or token, the
///         6 h-epoch rolling cap across its boundaries, admin-only setters, fund/defund accounting, and a fuzzed
///         sequence proving total paid <= funded and <= dailyCap over every 24 h interval.
/// @dev Self-contained setup (C2-08 consolidates the v2 bases later). USDG is MockERC20 at 6 dp, whose pause and freeze
///      reproduce the live token's reverting transfers; QuirkyUSDG covers the rest. Time is carried in local variables
///      and set with vm.warp, never read back from block.timestamp inside a test, because via_ir may fold repeated
///      block.timestamp reads in one function.
contract KeeperRewardsTest is Test {
    uint256 internal constant USDG = 1e6;
    uint256 internal constant EPOCH = 6 hours;
    uint256 internal constant T0 = 1_789_000_000;

    bytes32 internal constant SNAPSHOT = V2Constants.ACTION_SNAPSHOT;
    bytes32 internal constant FINALIZE = V2Constants.ACTION_FINALIZE;
    bytes32 internal constant SETTLE = V2Constants.ACTION_SETTLE;
    bytes32 internal constant REDEEM = V2Constants.ACTION_REDEEM;
    bytes32 internal constant ROLL = V2Constants.ACTION_ROLL;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    /// @dev Stands in for a registered protocol contract (SettlementOracle, Clearinghouse, AutoRoller).
    address internal oracle = makeAddr("oracle");
    address internal clearinghouse = makeAddr("clearinghouse");

    MockERC20 internal usdg;
    KeeperRewards internal rewards;

    event Rewarded(address indexed keeper, bytes32 indexed action, uint256 amount);
    event BountySet(bytes32 indexed action, uint256 amount);
    event CallerSet(address indexed caller, bool registered);
    event DailyCapSet(uint256 amount);
    event Funded(address indexed from, uint256 amount);
    event Defunded(address indexed to, uint256 amount);

    function setUp() public {
        vm.warp(T0);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        rewards = new KeeperRewards(IERC20(address(usdg)), admin);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Registers `oracle`, sets `bounty` for SETTLE and the cap, and funds `budget` from the treasury.
    function _configure(KeeperRewards r, uint256 bounty, uint256 cap, uint256 budget) internal {
        vm.startPrank(admin);
        r.setCaller(oracle, true);
        r.setBounty(SETTLE, bounty);
        r.setDailyCap(cap);
        vm.stopPrank();
        _fund(r, budget);
    }

    function _fund(KeeperRewards r, uint256 amount) internal returns (uint256 received) {
        MockERC20(address(r.usdg())).mint(treasury, amount);
        vm.startPrank(treasury);
        r.usdg().approve(address(r), amount);
        received = r.fund(amount);
        vm.stopPrank();
    }

    function _reward(bytes32 action) internal returns (uint256) {
        vm.prank(oracle);
        return rewards.reward(keeper, action);
    }

    function _epochStart(uint256 t) internal pure returns (uint256) {
        return t - (t % EPOCH);
    }

    /// @dev Number of Rewarded logs among the recorded ones.
    function _rewardedLogs() internal view returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == Rewarded.selector) ++n;
        }
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_state() public view {
        assertEq(address(rewards.usdg()), address(usdg), "usdg");
        assertTrue(rewards.hasRole(V2Constants.DEFAULT_ADMIN_ROLE, admin), "admin role");
        assertEq(rewards.dailyCap(), 0, "cap starts at 0: pays nothing until configured");
        assertEq(rewards.spentToday(), 0, "nothing spent");
        assertEq(rewards.bounty(SETTLE), 0, "no bounties");
        assertFalse(rewards.isCaller(oracle), "no callers");
    }

    function test_constructor_rejectsCodelessUsdg() public {
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        new KeeperRewards(IERC20(address(0)), admin);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        new KeeperRewards(IERC20(makeAddr("eoa")), admin);
    }

    function test_constructor_rejectsZeroAdmin() public {
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        new KeeperRewards(IERC20(address(usdg)), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN SETTERS
    //////////////////////////////////////////////////////////////*/

    function test_admin_settersEmitAndStore() public {
        vm.startPrank(admin);
        vm.expectEmit(address(rewards));
        emit CallerSet(oracle, true);
        rewards.setCaller(oracle, true);
        assertTrue(rewards.isCaller(oracle), "registered");

        vm.expectEmit(address(rewards));
        emit BountySet(SETTLE, 50_000);
        rewards.setBounty(SETTLE, 50_000);
        assertEq(rewards.bounty(SETTLE), 50_000, "bounty");

        vm.expectEmit(address(rewards));
        emit DailyCapSet(20 * USDG);
        rewards.setDailyCap(20 * USDG);
        assertEq(rewards.dailyCap(), 20 * USDG, "cap");

        vm.expectEmit(address(rewards));
        emit CallerSet(oracle, false);
        rewards.setCaller(oracle, false);
        assertFalse(rewards.isCaller(oracle), "unregistered");
        vm.stopPrank();
    }

    function test_admin_onlyAdmin() public {
        _fund(rewards, 5 * USDG);
        address[3] memory strangers = [alice, keeper, oracle];
        vm.prank(admin);
        rewards.setCaller(oracle, true);

        for (uint256 i; i < strangers.length; ++i) {
            vm.startPrank(strangers[i]);
            vm.expectRevert(V2Errors.NotAuthorized.selector);
            rewards.setCaller(strangers[i], true);
            vm.expectRevert(V2Errors.NotAuthorized.selector);
            rewards.setBounty(SETTLE, 1);
            vm.expectRevert(V2Errors.NotAuthorized.selector);
            rewards.setDailyCap(1);
            vm.expectRevert(V2Errors.NotAuthorized.selector);
            rewards.defund(strangers[i], 1);
            vm.stopPrank();
        }
        assertEq(usdg.balanceOf(address(rewards)), 5 * USDG, "nothing moved");
        assertFalse(rewards.isCaller(alice), "not registered");
    }

    function test_admin_adminRoleTransfers() public {
        address newAdmin = makeAddr("newAdmin");
        vm.startPrank(admin);
        rewards.grantRole(V2Constants.DEFAULT_ADMIN_ROLE, newAdmin);
        rewards.renounceRole(V2Constants.DEFAULT_ADMIN_ROLE, admin);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        rewards.setDailyCap(1);
        vm.stopPrank();

        vm.prank(newAdmin);
        rewards.setDailyCap(1);
        assertEq(rewards.dailyCap(), 1, "new admin sets the cap");
    }

    function test_setBounty_ceiling() public {
        vm.startPrank(admin);
        rewards.setBounty(SETTLE, V2Constants.MAX_BOUNTY);
        assertEq(rewards.bounty(SETTLE), 1_000_000, "exactly MAX_BOUNTY (1 USDG) is allowed");
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        rewards.setBounty(SETTLE, V2Constants.MAX_BOUNTY + 1);
        rewards.setBounty(SETTLE, 0);
        assertEq(rewards.bounty(SETTLE), 0, "0 disables");
        vm.stopPrank();
    }

    function testFuzz_setBounty_ceiling(bytes32 action, uint256 amount) public {
        vm.prank(admin);
        if (amount > V2Constants.MAX_BOUNTY) {
            vm.expectRevert(V2Errors.CeilingExceeded.selector);
            rewards.setBounty(action, amount);
            assertEq(rewards.bounty(action), 0, "unchanged");
        } else {
            rewards.setBounty(action, amount);
            assertEq(rewards.bounty(action), amount, "stored");
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 CALLERS
    //////////////////////////////////////////////////////////////*/

    function test_reward_unregisteredCallerReverts() public {
        _configure(rewards, 50_000, 10 * USDG, 10 * USDG);

        // The keeper cannot pay itself, nor can the admin or an unregistered protocol contract.
        address[3] memory strangers = [keeper, admin, clearinghouse];
        for (uint256 i; i < strangers.length; ++i) {
            vm.prank(strangers[i]);
            vm.expectRevert(V2Errors.NotAuthorized.selector);
            rewards.reward(keeper, SETTLE);
        }
        assertEq(usdg.balanceOf(keeper), 0, "nothing paid");
        assertEq(rewards.spentToday(), 0, "nothing counted");
    }

    function test_reward_unregisteringStopsPayments() public {
        _configure(rewards, 50_000, 10 * USDG, 10 * USDG);
        assertEq(_reward(SETTLE), 50_000, "paid while registered");

        vm.prank(admin);
        rewards.setCaller(oracle, false);
        vm.prank(oracle);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        rewards.reward(keeper, SETTLE);
    }

    function test_reward_severalCallersShareOneBudgetAndCap() public {
        _configure(rewards, 400_000, USDG, 10 * USDG);
        vm.prank(admin);
        rewards.setCaller(clearinghouse, true);

        assertEq(_reward(SETTLE), 400_000, "oracle's call");
        vm.prank(clearinghouse);
        assertEq(rewards.reward(alice, SETTLE), 400_000, "clearinghouse's call");
        vm.prank(clearinghouse);
        assertEq(rewards.reward(alice, SETTLE), 200_000, "the cap is shared");
        assertEq(rewards.spentToday(), USDG, "cap reached");
    }

    /*//////////////////////////////////////////////////////////////
                                 PAYMENT
    //////////////////////////////////////////////////////////////*/

    function test_reward_paysBountyAndEmits() public {
        _configure(rewards, 50_000, 10 * USDG, 10 * USDG);

        vm.expectEmit(address(rewards));
        emit Rewarded(keeper, SETTLE, 50_000);
        assertEq(_reward(SETTLE), 50_000, "paid the bounty");

        assertEq(usdg.balanceOf(keeper), 50_000, "keeper received it");
        assertEq(usdg.balanceOf(address(rewards)), 10 * USDG - 50_000, "budget debited");
        assertEq(rewards.spentToday(), 50_000, "counted against the cap");
    }

    function test_reward_perActionTable() public {
        _configure(rewards, 0, 100 * USDG, 100 * USDG);
        bytes32[5] memory actions = [SNAPSHOT, FINALIZE, SETTLE, REDEEM, ROLL];
        uint256[5] memory amounts = [uint256(30_000), 40_000, 50_000, 20_000, V2Constants.MAX_BOUNTY];
        vm.startPrank(admin);
        for (uint256 i; i < 5; ++i) {
            rewards.setBounty(actions[i], amounts[i]);
        }
        vm.stopPrank();

        uint256 total;
        for (uint256 i; i < 5; ++i) {
            assertEq(_reward(actions[i]), amounts[i], "each action pays its own bounty");
            total += amounts[i];
        }
        assertEq(usdg.balanceOf(keeper), total, "sum");
        assertEq(rewards.spentToday(), total, "counted");
    }

    function test_reward_unsetBountyPaysNothing() public {
        _configure(rewards, 50_000, 10 * USDG, 10 * USDG);
        vm.recordLogs();
        assertEq(_reward(keccak256("NOT_AN_ACTION")), 0, "unknown action");
        assertEq(_reward(ROLL), 0, "known action without a bounty");
        assertEq(_rewardedLogs(), 0, "no Rewarded event");
        assertEq(rewards.spentToday(), 0, "nothing counted");
    }

    function test_reward_emptyBudgetPaysNothing() public {
        _configure(rewards, 50_000, 10 * USDG, 0);
        vm.recordLogs();
        assertEq(_reward(SETTLE), 0, "empty budget: 0, no revert");
        assertEq(_rewardedLogs(), 0, "no Rewarded event");
        assertEq(rewards.spentToday(), 0, "nothing counted");

        _fund(rewards, 50_000);
        assertEq(_reward(SETTLE), 50_000, "pays once funded");
    }

    function test_reward_partialBudget() public {
        _configure(rewards, 50_000, 10 * USDG, 70_000);
        assertEq(_reward(SETTLE), 50_000, "full bounty");

        vm.expectEmit(address(rewards));
        emit Rewarded(keeper, SETTLE, 20_000);
        assertEq(_reward(SETTLE), 20_000, "what is left");

        vm.recordLogs();
        assertEq(_reward(SETTLE), 0, "then nothing");
        assertEq(_rewardedLogs(), 0, "no Rewarded event");
        assertEq(usdg.balanceOf(address(rewards)), 0, "drained exactly");
        assertEq(usdg.balanceOf(keeper), 70_000, "keeper got the whole budget");
        assertEq(rewards.spentToday(), 70_000, "counted what was paid, not the bounties asked");
    }

    function test_reward_budgetIsTheBalance() public {
        _configure(rewards, 50_000, 10 * USDG, 0);
        // USDG sent straight to the contract (not through fund) pays bounties too.
        usdg.mint(address(rewards), 30_000);
        assertEq(_reward(SETTLE), 30_000, "direct transfer funds bounties");
    }

    /*//////////////////////////////////////////////////////////////
                                DAILY CAP
    //////////////////////////////////////////////////////////////*/

    function test_cap_zeroPaysNothing() public {
        _configure(rewards, 50_000, 0, 10 * USDG);
        vm.recordLogs();
        assertEq(_reward(SETTLE), 0, "cap 0");
        assertEq(_rewardedLogs(), 0, "no Rewarded event");
        assertEq(usdg.balanceOf(address(rewards)), 10 * USDG, "untouched");
    }

    function test_cap_clampsLastPaymentThenStops() public {
        _configure(rewards, 400_000, USDG, 10 * USDG);
        assertEq(_reward(SETTLE), 400_000, "1");
        assertEq(_reward(SETTLE), 400_000, "2");
        assertEq(_reward(SETTLE), 200_000, "3: clamped to the cap remaining");
        assertEq(_reward(SETTLE), 0, "4: cap reached, no revert");
        assertEq(rewards.spentToday(), USDG, "spent == cap");
        assertEq(usdg.balanceOf(keeper), USDG, "paid == cap");
    }

    function test_cap_loweredBelowSpentThenRaised() public {
        _configure(rewards, 400_000, 2 * USDG, 10 * USDG);
        _reward(SETTLE);
        _reward(SETTLE);

        vm.prank(admin);
        rewards.setDailyCap(500_000);
        assertEq(rewards.spentToday(), 800_000, "spend stays counted");
        assertEq(_reward(SETTLE), 0, "cap below spent: nothing");

        vm.prank(admin);
        rewards.setDailyCap(USDG);
        assertEq(_reward(SETTLE), 200_000, "raised: pays up to the new cap");
    }

    /// @dev A payment in the last second of an epoch stops counting exactly 24 h + 1 s later; one at an epoch's first
    ///      second counts for the full 30 h. Either way the cap holds across the boundary.
    function test_cap_acrossWindowBoundary() public {
        _configure(rewards, V2Constants.MAX_BOUNTY, 3 * USDG, 100 * USDG);

        // Last second of an epoch.
        uint256 t = _epochStart(T0) + EPOCH - 1;
        vm.warp(t);
        for (uint256 i; i < 3; ++i) {
            assertEq(_reward(SETTLE), USDG, "fill the cap");
        }
        assertEq(_reward(SETTLE), 0, "cap reached");

        // Next epoch, one second later: still inside the same 24 h.
        vm.warp(t + 1);
        assertEq(rewards.spentToday(), 3 * USDG, "a new epoch is not a new day");
        assertEq(_reward(SETTLE), 0, "still capped after the epoch boundary");

        // Exactly 24 h after the payments: [t, t + 24 h] must still respect the cap.
        vm.warp(t + 24 hours);
        assertEq(rewards.spentToday(), 3 * USDG, "counted at t + 24 h");
        assertEq(_reward(SETTLE), 0, "capped at t + 24 h");

        // One second later the payments' epoch rolls out.
        vm.warp(t + 24 hours + 1);
        assertEq(rewards.spentToday(), 0, "released at t + 24 h + 1 s");
        assertEq(_reward(SETTLE), USDG, "pays again");

        // First second of an epoch: counts for 30 h.
        uint256 u = _epochStart(t + 24 hours + 1) + 5 * EPOCH;
        vm.warp(u);
        assertEq(_reward(SETTLE), USDG, "first-second payment 1");
        assertEq(_reward(SETTLE), USDG, "first-second payment 2");
        assertEq(rewards.spentToday(), 2 * USDG, "the older payment has rolled out by now");

        vm.warp(u + 30 hours - 1);
        assertEq(rewards.spentToday(), 2 * USDG, "still counted at u + 30 h - 1 s");
        assertEq(_reward(SETTLE), USDG, "only the cap remaining is paid");
        assertEq(_reward(SETTLE), 0, "capped");

        vm.warp(u + 30 hours);
        assertEq(rewards.spentToday(), USDG, "u's payments released at u + 30 h");
    }

    function test_cap_epochsReleaseOneAtATime() public {
        _configure(rewards, V2Constants.MAX_BOUNTY, 10 * USDG, 100 * USDG);
        uint256 e = _epochStart(T0) + EPOCH; // start of the next epoch

        vm.warp(e);
        _reward(SETTLE);
        _reward(SETTLE); // 2 in epoch E
        vm.warp(e + 2 * EPOCH + 7);
        _reward(SETTLE); // 1 in epoch E+2
        vm.warp(e + 4 * EPOCH + 100);
        _reward(SETTLE);
        _reward(SETTLE);
        _reward(SETTLE); // 3 in epoch E+4

        (uint256 start, uint256[5] memory spent) = rewards.spendByEpoch();
        assertEq(start, e + 4 * EPOCH, "current epoch start");
        assertEq(spent[0], 3 * USDG, "E+4");
        assertEq(spent[1], 0, "E+3");
        assertEq(spent[2], USDG, "E+2");
        assertEq(spent[3], 0, "E+1");
        assertEq(spent[4], 2 * USDG, "E");
        assertEq(rewards.spentToday(), 6 * USDG, "sum");

        vm.warp(e + 5 * EPOCH);
        assertEq(rewards.spentToday(), 4 * USDG, "E released");
        vm.warp(e + 7 * EPOCH);
        assertEq(rewards.spentToday(), 3 * USDG, "E+2 released");
        vm.warp(e + 9 * EPOCH - 1);
        assertEq(rewards.spentToday(), 3 * USDG, "E+4 still counted");
        vm.warp(e + 9 * EPOCH);
        assertEq(rewards.spentToday(), 0, "all released");
        (, spent) = rewards.spendByEpoch();
        for (uint256 i; i < 5; ++i) {
            assertEq(spent[i], 0, "empty buckets");
        }

        // A long idle gap clears everything and the window starts clean.
        vm.warp(e + 400 days);
        assertEq(_reward(SETTLE), USDG, "pays after a long gap");
        assertEq(rewards.spentToday(), USDG, "one payment counted");
    }

    /*//////////////////////////////////////////////////////////////
                              FAILING USDG
    //////////////////////////////////////////////////////////////*/

    function test_usdg_pausedTokenPaysNothingAndLeavesNoTrace() public {
        _configure(rewards, 50_000, 10 * USDG, 10 * USDG);
        _reward(SETTLE);
        (, uint256[5] memory before) = rewards.spendByEpoch();

        usdg.pause(); // transfer reverts ContractPaused, like the live token
        vm.recordLogs();
        assertEq(_reward(SETTLE), 0, "reverting transfer: 0, no revert");
        assertEq(_rewardedLogs(), 0, "no Rewarded event");
        (, uint256[5] memory afterFail) = rewards.spendByEpoch();
        assertEq(keccak256(abi.encode(afterFail)), keccak256(abi.encode(before)), "spend window restored");
        assertEq(usdg.balanceOf(address(rewards)), 10 * USDG - 50_000, "budget untouched");

        usdg.unpause();
        assertEq(_reward(SETTLE), 50_000, "pays once the token works again");
    }

    function test_usdg_frozenKeeperPaysNothing() public {
        _configure(rewards, 50_000, 10 * USDG, 10 * USDG);
        usdg.freeze(keeper);
        assertEq(_reward(SETTLE), 0, "frozen recipient: 0");
        assertEq(rewards.spentToday(), 0, "nothing counted");

        vm.prank(oracle);
        assertEq(rewards.reward(alice, SETTLE), 50_000, "another keeper is still paid");
    }

    function test_usdg_revertingTransfer() public {
        (KeeperRewards r, QuirkyUSDG q) = _quirky(QuirkyUSDG.Mode.RevertTransfer);
        vm.prank(oracle);
        assertEq(r.reward(keeper, SETTLE), 0, "reverting transfer: 0");
        assertEq(r.spentToday(), 0, "nothing counted");
        assertEq(q.balanceOf(address(r)), 10 * USDG, "budget untouched");
    }

    function test_usdg_falseReturningTransfer() public {
        (KeeperRewards r, QuirkyUSDG q) = _quirky(QuirkyUSDG.Mode.ReturnFalse);
        vm.recordLogs();
        vm.prank(oracle);
        assertEq(r.reward(keeper, SETTLE), 0, "false-returning transfer: 0");
        assertEq(_rewardedLogs(), 0, "no Rewarded event");
        assertEq(r.spentToday(), 0, "nothing counted");
        assertEq(q.balanceOf(address(r)), 10 * USDG, "budget untouched");
    }

    function test_usdg_noReturnDataCountsAsSuccess() public {
        (KeeperRewards r, QuirkyUSDG q) = _quirky(QuirkyUSDG.Mode.NoReturnData);
        vm.prank(oracle);
        assertEq(r.reward(keeper, SETTLE), 50_000, "empty return data: paid");
        assertEq(q.balanceOf(keeper), 50_000, "moved");
        assertEq(r.spentToday(), 50_000, "counted");
    }

    /// @dev `abi.decode(ret, (bool))` would revert on the value 2; the contract compares the word with 1 instead.
    function test_usdg_dirtyBoolDoesNotRevert() public {
        (KeeperRewards r,) = _quirky(QuirkyUSDG.Mode.DirtyTrue);
        vm.prank(oracle);
        assertEq(r.reward(keeper, SETTLE), 0, "non-canonical bool is a failure, not a revert");
        assertEq(r.spentToday(), 0, "nothing counted");
    }

    function test_usdg_failingBalanceReadPaysNothing() public {
        (KeeperRewards r, QuirkyUSDG q) = _quirky(QuirkyUSDG.Mode.RevertBalanceOf);
        vm.prank(oracle);
        assertEq(r.reward(keeper, SETTLE), 0, "reverting balanceOf: 0");

        q.setMode(QuirkyUSDG.Mode.EmptyBalanceOf);
        vm.prank(oracle);
        assertEq(r.reward(keeper, SETTLE), 0, "empty balanceOf return: 0");
        assertEq(r.spentToday(), 0, "nothing counted");
    }

    /// @dev A caller that does NOT wrap {reward} in try/catch still completes its lifecycle call when the token fails:
    ///      the reward returns 0 instead of reverting. (The real callers wrap it anyway.)
    function test_usdg_callerIsNeverBlocked() public {
        _configure(rewards, 50_000, 10 * USDG, 10 * USDG);
        LifecycleCaller lc = new LifecycleCaller(rewards);
        vm.prank(admin);
        rewards.setCaller(address(lc), true);

        usdg.pause();
        vm.prank(keeper);
        assertEq(lc.advance(SETTLE), 0, "lifecycle call completes, reward 0");
        assertEq(lc.advances(), 1, "state advanced");

        usdg.unpause();
        vm.prank(keeper);
        assertEq(lc.advance(SETTLE), 50_000, "rewarded");
        assertEq(usdg.balanceOf(keeper), 50_000, "keeper paid");
    }

    /// @dev A KeeperRewards over QuirkyUSDG in `mode`, oracle registered, SETTLE = 0.05 USDG, cap 10 USDG, 10 USDG
    ///      funded (minted directly: the budget is the balance).
    function _quirky(QuirkyUSDG.Mode mode) internal returns (KeeperRewards r, QuirkyUSDG q) {
        q = new QuirkyUSDG();
        r = new KeeperRewards(IERC20(address(q)), admin);
        vm.startPrank(admin);
        r.setCaller(oracle, true);
        r.setBounty(SETTLE, 50_000);
        r.setDailyCap(10 * USDG);
        vm.stopPrank();
        q.mint(address(r), 10 * USDG);
        q.setMode(mode);
    }

    /*//////////////////////////////////////////////////////////////
                              FUND / DEFUND
    //////////////////////////////////////////////////////////////*/

    function test_fund_anyoneFundsAndEmits() public {
        usdg.mint(alice, 7 * USDG);
        vm.startPrank(alice);
        usdg.approve(address(rewards), 7 * USDG);
        vm.expectEmit(address(rewards));
        emit Funded(alice, 7 * USDG);
        assertEq(rewards.fund(7 * USDG), 7 * USDG, "received");
        vm.stopPrank();
        assertEq(usdg.balanceOf(address(rewards)), 7 * USDG, "held");
        assertEq(usdg.balanceOf(alice), 0, "pulled");
    }

    function test_fund_withoutApprovalReverts() public {
        usdg.mint(alice, USDG);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, rewards, 0, USDG));
        rewards.fund(USDG);
    }

    function test_fund_measuresDelta() public {
        QuirkyUSDG q = new QuirkyUSDG();
        KeeperRewards r = new KeeperRewards(IERC20(address(q)), admin);
        q.mint(treasury, 10 * USDG);
        q.setMode(QuirkyUSDG.Mode.FeeOnTransferFrom);

        vm.startPrank(treasury);
        q.approve(address(r), 10 * USDG);
        vm.expectEmit(address(r));
        emit Funded(treasury, 9_900_000);
        assertEq(r.fund(10 * USDG), 9_900_000, "reports what arrived, not what was asked");
        vm.stopPrank();
        assertEq(q.balanceOf(address(r)), 9_900_000, "held");
    }

    function test_defund_accounting() public {
        _configure(rewards, 400_000, 10 * USDG, 5 * USDG);
        _reward(SETTLE);

        vm.expectEmit(address(rewards));
        emit Defunded(treasury, 3 * USDG);
        vm.prank(admin);
        rewards.defund(treasury, 3 * USDG);

        assertEq(usdg.balanceOf(treasury), 3 * USDG, "treasury received");
        assertEq(usdg.balanceOf(address(rewards)), 5 * USDG - 400_000 - 3 * USDG, "funded - paid - defunded");
        assertEq(rewards.spentToday(), 400_000, "defunding does not touch the spend window");

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, rewards, 1_600_000, 2 * USDG)
        );
        rewards.defund(treasury, 2 * USDG); // 1.6 USDG left

        vm.prank(admin);
        rewards.defund(alice, 1_600_000);
        assertEq(usdg.balanceOf(address(rewards)), 0, "emptied");
        assertEq(_reward(SETTLE), 0, "nothing left to pay");
    }

    /*//////////////////////////////////////////////////////////////
                                   FUZZ
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant STEPS = 48;

    /// @dev A seed-driven sequence of fund, defund, warp, bounty changes and rewards against a reference model. After
    ///      every step: the payment equals min(bounty, cap - model spend, balance); balance == funded - defunded - paid
    ///      (so paid never exceeds funded); spentToday equals the model (payments in the current epoch and the four
    ///      before it) and never exceeds the cap. At the end: every 24 h interval starting at a payment paid <= cap.
    function testFuzz_neverPaysMoreThanFundedOrCap(uint256 seed, uint256 capSeed) public {
        uint256 cap = bound(capSeed, 0, 4 * USDG);
        bytes32[5] memory actions = [SNAPSHOT, FINALIZE, SETTLE, REDEEM, ROLL];
        vm.startPrank(admin);
        rewards.setCaller(oracle, true);
        rewards.setDailyCap(cap);
        for (uint256 a; a < 5; ++a) {
            rewards.setBounty(
                actions[a], uint256(keccak256(abi.encode(seed, "bounty", a))) % (V2Constants.MAX_BOUNTY + 1)
            );
        }
        vm.stopPrank();

        uint256 now_ = T0;
        uint256 funded = _fund(rewards, uint256(keccak256(abi.encode(seed, "fund"))) % (5 * USDG));
        uint256 defunded;
        uint256 paid;
        uint256[STEPS] memory payTs;
        uint256[STEPS] memory payAmt;
        uint256 n;

        for (uint256 i; i < STEPS; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = r % 10;
            r >>= 8;
            if (op == 0) {
                funded += _fund(rewards, r % (3 * USDG));
            } else if (op == 1) {
                uint256 bal = usdg.balanceOf(address(rewards));
                uint256 amount = r % (bal + 1);
                vm.prank(admin);
                rewards.defund(treasury, amount);
                defunded += amount;
            } else if (op <= 3) {
                now_ += r % 12 hours;
                vm.warp(now_);
            } else if (op == 4) {
                vm.prank(admin);
                rewards.setBounty(actions[r % 5], (r >> 8) % (V2Constants.MAX_BOUNTY + 1));
            } else {
                bytes32 action = actions[r % 5];
                uint256 spentModel = _modelSpent(payTs, payAmt, n, now_);
                uint256 expected = rewards.bounty(action);
                expected = _min(expected, cap > spentModel ? cap - spentModel : 0);
                expected = _min(expected, usdg.balanceOf(address(rewards)));

                vm.prank(oracle);
                uint256 p = rewards.reward(keeper, action);
                assertEq(p, expected, "pays min(bounty, cap remaining, balance)");
                if (p > 0) {
                    payTs[n] = now_;
                    payAmt[n] = p;
                    ++n;
                    paid += p;
                }
            }

            assertLe(paid + defunded, funded, "never pays out more than was funded");
            assertEq(usdg.balanceOf(address(rewards)), funded - defunded - paid, "balance accounting");
            assertEq(usdg.balanceOf(keeper), paid, "keeper received every payment");
            uint256 spent = rewards.spentToday();
            assertEq(spent, _modelSpent(payTs, payAmt, n, now_), "spentToday matches the model");
            assertLe(spent, cap, "spentToday <= dailyCap");
        }

        for (uint256 j; j < n; ++j) {
            uint256 inInterval;
            for (uint256 k; k < n; ++k) {
                if (payTs[k] >= payTs[j] && payTs[k] <= payTs[j] + 24 hours) inInterval += payAmt[k];
            }
            assertLe(inInterval, cap, "any 24 h interval pays <= dailyCap");
        }
    }

    /// @dev Reference model of the window: payments whose 6 h epoch is the current one or one of the four before it.
    function _modelSpent(uint256[STEPS] memory ts, uint256[STEPS] memory amt, uint256 n, uint256 now_)
        internal
        pure
        returns (uint256 total)
    {
        uint256 current = now_ / EPOCH;
        for (uint256 k; k < n; ++k) {
            if (ts[k] / EPOCH + 4 >= current) total += amt[k];
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

/// @notice A minimal protocol contract: advances its state, then asks for a bounty WITHOUT try/catch, so any revert in
///         {KeeperRewards.reward} would undo the advance.
contract LifecycleCaller {
    IKeeperRewards internal immutable rewards;
    uint256 public advances;

    constructor(IKeeperRewards rewards_) {
        rewards = rewards_;
    }

    function advance(bytes32 action) external returns (uint256 paid) {
        ++advances;
        paid = rewards.reward(msg.sender, action);
    }
}
