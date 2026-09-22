// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {V2Ids} from "../../../src/v2/interfaces/V2Ids.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../../src/mocks/MockStockToken.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";
import {MakerVault} from "../../../src/v2/mm/MakerVault.sol";
import {RewardsDistributor} from "../../../src/v2/mm/RewardsDistributor.sol";

/// @notice Drives every way protocol-owned money can leave a v8 `MakerVault` and `RewardsDistributor`, for
///         {TreasuryExitInvariantTest}: the TREASURY_ADMIN lane withdrawing USDG, Stock Tokens and option positions
///         and defunding rewards, callers who hold no role at all trying the same, the treasury pointer moving, and
///         anyone funding either contract.
/// @dev WHAT IS BEING PROVED, and why it needs a campaign rather than a unit test. In INTERFACE_VERSION 7 each exit
///      took a free `to` argument, so "the money went to the treasury" was a property of the CALL, and a single
///      compromised admin call broke it. v8 deleted those arguments: `withdraw`, `withdrawPosition` and `defund`
///      read {MakerVault.treasury} / {RewardsDistributor.treasury}, which only TREASURY_ADMIN can move. The claim is
///      therefore about the CONTRACT over any sequence of calls, which is what a stateful campaign checks and a
///      fixed unit case cannot: whatever order the exits, the failed attempts and the pointer moves come in, every
///      base unit that left landed, in full, on the address the pointer named at that moment.
///
///      NOTHING TRADES HERE, on purpose. The campaign never quotes, fills or settles, so every actor's balance can
///      only FALL (by funding) unless an exit paid it. That is what lets
///      `invariant_noNonTreasuryAddressEverGained` be an equality-strength check rather than a guess about which of
///      a trader's receipts were legitimate. The outflow cap, which is about quoting, is covered by
///      {MakerVaultOutflowHandler} instead.
///
///      MEASURED, NOT ASSUMED. Each exit reads the CURRENT `treasury()` before the call and that address's balance
///      before and after, and counts a {misroutedExits} when the delta is not exactly the amount that left. So a
///      future edit that paid `msg.sender`, split the payment, or sent it to a stale pointer would be caught by the
///      delta, not by re-reading the same storage slot the contract used.
///
///      THE HANDLER NEVER REVERTS: every argument is bounded into range and every protocol refusal is swallowed, so
///      a revert reaching the fuzzer under `fail-on-revert = true` is a bug in this file.
contract TreasuryExitHandler is Test {
    /*//////////////////////////////////////////////////////////////
                                 WIRING
    //////////////////////////////////////////////////////////////*/

    MakerVault internal immutable vault;
    RewardsDistributor internal immutable rewards;
    Clearinghouse internal immutable ch;
    MockERC20 internal immutable usdg;
    MockStockToken internal immutable stock;
    AccessManager internal immutable manager;

    /// @dev The TREASURY_ADMIN holder, and three callers who hold nothing on either target.
    address internal immutable treasuryAdmin;
    address[3] internal outsiders;

    /// @notice The addresses the treasury pointer is ever allowed to be: the only addresses an exit may pay.
    address[3] public treasuries;

    /// @dev The long id the vault holds a position of.
    uint256 internal immutable longId;

    /*//////////////////////////////////////////////////////////////
                                GHOSTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Base units that left through a successful exit, by asset.
    uint256 public usdgExited;
    uint256 public stockExited;
    uint256 public unitsExited;

    /// @notice A successful exit whose recipient balance did not rise by exactly the amount that left. Must stay 0.
    uint256 public misroutedExits;
    /// @notice An exit that succeeded for a caller with no TREASURY_ADMIN. Must stay 0.
    uint256 public unauthorizedExitsSucceeded;
    /// @notice A treasury pointer moved by a caller with no TREASURY_ADMIN. Must stay 0.
    uint256 public unauthorizedTreasuryChanges;

    /// @notice Non-vacuity counters: {TreasuryExitInvariantTest.test_handlerExercisesEveryExit} asserts each moves.
    uint256 public usdgWithdrawals;
    uint256 public stockWithdrawals;
    uint256 public positionWithdrawals;
    uint256 public defunds;
    uint256 public deposits;
    uint256 public fundings;
    uint256 public treasuryMoves;
    uint256 public refusedAttempts;

    constructor(
        MakerVault vault_,
        RewardsDistributor rewards_,
        Clearinghouse ch_,
        AccessManager manager_,
        MockERC20 usdg_,
        MockStockToken stock_,
        address treasuryAdmin_,
        address[3] memory outsiders_,
        address[3] memory treasuries_,
        uint256 longId_
    ) {
        vault = vault_;
        rewards = rewards_;
        ch = ch_;
        manager = manager_;
        usdg = usdg_;
        stock = stock_;
        treasuryAdmin = treasuryAdmin_;
        outsiders = outsiders_;
        treasuries = treasuries_;
        longId = longId_;
    }

    /*//////////////////////////////////////////////////////////////
                          THE TREASURY LANE
    //////////////////////////////////////////////////////////////*/

    /// @notice TREASURY_ADMIN takes USDG out of the vault.
    function withdrawUsdg(uint256 amount) external {
        uint256 have = usdg.balanceOf(address(vault));
        if (have == 0) return;
        amount = bound(amount, 1, have);
        address to = vault.treasury();
        uint256 before = usdg.balanceOf(to);
        vm.prank(treasuryAdmin);
        try vault.withdraw(address(usdg), amount) {
            usdgExited += amount;
            ++usdgWithdrawals;
            _checkLanded(usdg.balanceOf(to) - before, amount);
        } catch {}
    }

    /// @notice TREASURY_ADMIN takes a Stock Token out of the vault. Same exit, a different asset: the recipient is
    ///         not a per-asset setting, so this must land on the same pointer.
    function withdrawStock(uint256 amount) external {
        uint256 have = stock.balanceOf(address(vault));
        if (have == 0) return;
        amount = bound(amount, 1, have);
        address to = vault.treasury();
        uint256 before = stock.balanceOf(to);
        vm.prank(treasuryAdmin);
        try vault.withdraw(address(stock), amount) {
            stockExited += amount;
            ++stockWithdrawals;
            _checkLanded(stock.balanceOf(to) - before, amount);
        } catch {}
    }

    /// @notice TREASURY_ADMIN unwinds an option position by hand. ERC-1155, so it is a different transfer path from
    ///         the ERC-20 exits and needs its own leg.
    function withdrawPosition(uint256 units, bool shortSide) external {
        uint256 tokenId = shortSide ? V2Ids.shortIdOf(longId) : longId;
        uint256 have = ch.balanceOf(address(vault), tokenId);
        if (have == 0) return;
        units = bound(units, 1, have);
        address to = vault.treasury();
        uint256 before = ch.balanceOf(to, tokenId);
        vm.prank(treasuryAdmin);
        try vault.withdrawPosition(tokenId, units) {
            unitsExited += units;
            ++positionWithdrawals;
            _checkLanded(ch.balanceOf(to, tokenId) - before, units);
        } catch {}
    }

    /// @notice TREASURY_ADMIN reclaims unclaimed maker rewards.
    function defund(uint256 amount) external {
        uint256 have = usdg.balanceOf(address(rewards));
        if (have == 0) return;
        amount = bound(amount, 1, have);
        address to = rewards.treasury();
        uint256 before = usdg.balanceOf(to);
        vm.prank(treasuryAdmin);
        try rewards.defund(amount) {
            usdgExited += amount;
            ++defunds;
            _checkLanded(usdg.balanceOf(to) - before, amount);
        } catch {}
    }

    /// @notice TREASURY_ADMIN moves the pointer, on one target or the other. The set it may move it to is the set
    ///         the invariants allow an exit to pay, so a later exit is checked against the NEW pointer.
    function moveTheTreasury(uint8 who, bool vaultSide) external {
        address next = treasuries[who % treasuries.length];
        vm.prank(treasuryAdmin);
        if (vaultSide) {
            try vault.setTreasury(next) {
                ++treasuryMoves;
            } catch {}
        } else {
            try rewards.setTreasury(next) {
                ++treasuryMoves;
            } catch {}
        }
    }

    /*//////////////////////////////////////////////////////////////
                      CALLERS WITH NO TREASURY ROLE
    //////////////////////////////////////////////////////////////*/

    /// @notice A caller with no TREASURY_ADMIN tries every exit. Each one must be refused; a success is counted and
    ///         fails {TreasuryExitInvariantTest.invariant_onlyTheTreasuryLaneCanExit}.
    /// @dev `who` includes the QUOTER key, which is the interesting one: it can move the vault's money around the
    ///      book all day and still must not be able to take any of it out.
    function outsiderTriesToExit(uint8 who, uint8 which, uint256 amount) external {
        address caller = outsiders[who % outsiders.length];
        (bool hasTreasuryRole,) = manager.hasRole(V8Roles.TREASURY_ADMIN, caller);
        if (hasTreasuryRole) return;
        amount = bound(amount, 1, 1e18);
        bool ok;
        if (which % 4 == 0) {
            vm.prank(caller);
            try vault.withdraw(address(usdg), amount) {
                ok = true;
            } catch {}
        } else if (which % 4 == 1) {
            vm.prank(caller);
            try vault.withdraw(address(stock), amount) {
                ok = true;
            } catch {}
        } else if (which % 4 == 2) {
            vm.prank(caller);
            try vault.withdrawPosition(longId, amount) {
                ok = true;
            } catch {}
        } else {
            vm.prank(caller);
            try rewards.defund(amount) {
                ok = true;
            } catch {}
        }
        if (ok) ++unauthorizedExitsSucceeded;
        else ++refusedAttempts;
    }

    /// @notice A caller with no TREASURY_ADMIN tries to point the exit at itself. The whole design rests on this
    ///         being impossible: a movable pointer with no gate is a free `to` argument with extra steps.
    function outsiderTriesToMoveTheTreasury(uint8 who, bool vaultSide) external {
        address caller = outsiders[who % outsiders.length];
        (bool hasTreasuryRole,) = manager.hasRole(V8Roles.TREASURY_ADMIN, caller);
        if (hasTreasuryRole) return;
        address wasVault = vault.treasury();
        address wasRewards = rewards.treasury();
        vm.prank(caller);
        if (vaultSide) {
            try vault.setTreasury(caller) {} catch {}
        } else {
            try rewards.setTreasury(caller) {} catch {}
        }
        if (vault.treasury() != wasVault || rewards.treasury() != wasRewards) ++unauthorizedTreasuryChanges;
        else ++refusedAttempts;
    }

    /*//////////////////////////////////////////////////////////////
                       FUNDING (PERMISSIONLESS)
    //////////////////////////////////////////////////////////////*/

    /// @notice Anyone funds the vault. INTERFACE_VERSION 8 made {MakerVault.deposit} permissionless, so this is a
    ///         role-free caller putting money IN while the same caller cannot get any out.
    function anyoneDeposits(uint8 who, bool usdgSide, uint256 amount) external {
        address caller = outsiders[who % outsiders.length];
        address asset = usdgSide ? address(usdg) : address(stock);
        amount = bound(amount, 1e6, 10_000e6);
        if (usdgSide) usdg.mint(caller, amount);
        else stock.mint(caller, amount);
        vm.startPrank(caller);
        IERC20(asset).approve(address(vault), amount);
        try vault.deposit(asset, amount) {
            ++deposits;
        } catch {}
        vm.stopPrank();
    }

    /// @notice Anyone funds the reward balance; it can only ever pay claims or go back to the treasury.
    function anyoneFundsRewards(uint8 who, uint256 amount) external {
        address caller = outsiders[who % outsiders.length];
        amount = bound(amount, 1e6, 10_000e6);
        usdg.mint(caller, amount);
        vm.startPrank(caller);
        usdg.approve(address(rewards), amount);
        try rewards.fund(amount) {
            ++fundings;
        } catch {}
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _checkLanded(uint256 delta, uint256 amount) private {
        if (delta != amount) ++misroutedExits;
    }
}
