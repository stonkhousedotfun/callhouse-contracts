// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {Vault} from "../../src/Vault.sol";
import {Distributor} from "../../src/Distributor.sol";
import {OrderComponents} from "../../src/interfaces/ISeaport.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @notice T-01 / F-01 — deposits, minting, the deposit cap, and instant redemption.
/// @dev The share price here moves for exactly one reason: the asset balance moved. USDG never
///      enters `totalAssets`, so every number below is pure Stock Token arithmetic. Where a
///      "price move" is needed the test donates the asset straight to the vault, which is the
///      honest shape of the move (an assignment or a transfer in) without dragging a whole
///      cycle into a deposit test.
contract VaultDepositTest is BaseTest {
    /*//////////////////////////////////////////////////////////////
                            LOCAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Mint exactly `shares` as `who`, approving only what the preview says it costs.
    ///      Approving the exact amount is the point: if `mint` ever pulled more than it
    ///      quoted, the approval would fail and the test would catch it.
    function _mintShares(address who, uint256 shares) internal returns (uint256 assets) {
        uint256 cost = vault.previewMint(shares);
        vm.startPrank(who);
        nvda.approve(address(vault), cost);
        assets = vault.mint(shares, who);
        vm.stopPrank();
    }

    /// @dev Move the share price by putting assets in the vault that nobody minted against.
    function _donate(uint256 amount) internal {
        nvda.mint(address(vault), amount);
    }

    /// @dev Take an open cycle all the way back to Idle: lock the book at the exercise
    ///      timestamp, warp to expiry, close.
    function _closeCycle() internal {
        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();
        _rollClose();
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT AND PRICING
    //////////////////////////////////////////////////////////////*/

    function test_firstDepositIsOneToOne() public {
        assertEq(vault.previewDeposit(10e18), 10e18, "preview is 1:1 on an empty vault");

        vm.startPrank(alice);
        nvda.approve(address(vault), 10e18);
        vm.expectEmit(true, true, false, true, address(vault));
        emit Vault.Deposit(alice, alice, 10e18, 10e18);
        uint256 shares = vault.deposit(10e18, alice);
        vm.stopPrank();

        assertEq(shares, 10e18, "first deposit mints 1 share per token");
        assertEq(vault.balanceOf(alice), 10e18, "shares credited");
        assertEq(vault.totalSupply(), 10e18, "supply");
        assertEq(vault.totalAssets(), 10e18, "assets");
        assertEq(nvda.balanceOf(alice), 20e18, "assets left the depositor");
        assertEq(nvda.balanceOf(address(vault)), 10e18, "assets landed in the vault");
    }

    /// @dev The second depositor must buy in at the CURRENT price, not the launch price.
    ///      Vault holds 20 NVDA against 10 shares, so 10 NVDA buys 5 shares, not 10.
    ///
    ///      HAND-CHECKED ARITHMETIC (check this against the fixture, do not trust the number):
    ///        state before Bob:  totalAssets = 20e18, totalSupply = 10e18
    ///        previewDeposit(a) = a * (supply + 1) / (assets + 1), floored
    ///                          = 10e18 * (10e18 + 1) / (20e18 + 1)
    ///        numerator   = 1e38 + 1e19
    ///        5e18 * (20e18 + 1) = 1e38 + 5e18, and the leftover 5e18 < 20e18 + 1
    ///        so the quotient floors to exactly 5e18. No off-by-one hides here.
    function test_secondDepositorPaysTheMovedPrice() public {
        _deposit(alice, 10e18);
        _donate(10e18); // share price doubles: 20 assets behind 10 shares

        assertEq(vault.totalAssets(), 20e18, "price moved");
        assertEq(vault.convertToAssets(1e18), 1999999999999999999, "~2 assets per share");

        uint256 bobShares = _deposit(bob, 10e18);
        assertEq(bobShares, 5e18, "10 assets at 2 assets/share is 5 shares");

        // Alice's stake is untouched by Bob arriving, and Bob can take back what he put in
        // (less the one wei the virtual-share offset always rounds against him).
        assertEq(vault.convertToAssets(bobShares), 10e18 - 1, "Bob's claim is his deposit");
        assertEq(vault.convertToAssets(10e18), 20e18 - 1, "Alice still owns the doubled stake");
        assertEq(vault.totalAssets(), 30e18, "assets");
        assertEq(vault.totalSupply(), 15e18, "supply");
    }

    /// @dev `mint` must round the COST up. Rounding down would let a minter buy a share for
    ///      one wei less than it is worth, over and over, and the leak lands on the holders
    ///      who stayed. One wei of donated dust is enough to make the direction visible.
    function test_mintRoundsTheCostUpAgainstTheDepositor() public {
        _deposit(alice, 10e18);
        _donate(1); // price is now 1e18 + epsilon per share

        uint256 floorValue = vault.convertToAssets(1e18);
        uint256 cost = vault.previewMint(1e18);
        assertEq(floorValue, 1e18, "floor value of one share");
        assertEq(cost, 1e18 + 1, "mint cost is rounded UP, one wei above the floor value");

        uint256 before = nvda.balanceOf(bob);
        uint256 paid = _mintShares(bob, 1e18);

        assertEq(paid, cost, "mint charged exactly what it previewed");
        assertEq(before - nvda.balanceOf(bob), cost, "and pulled exactly that much");
        assertEq(vault.balanceOf(bob), 1e18, "minter got exactly the shares asked for");
    }

    function test_depositCreditsTheReceiverNotTheSender() public {
        vm.startPrank(alice);
        nvda.approve(address(vault), 10e18);
        uint256 shares = vault.deposit(10e18, carol);
        vm.stopPrank();

        assertEq(shares, 10e18, "returned shares");
        assertEq(vault.balanceOf(carol), 10e18, "receiver holds the shares");
        assertEq(vault.balanceOf(alice), 0, "payer holds none");
        assertEq(nvda.balanceOf(alice), 20e18, "payer paid");
        assertEq(nvda.balanceOf(carol), 30e18, "receiver paid nothing");
    }

    function test_mintCreditsTheReceiverNotTheSender() public {
        uint256 cost = vault.previewMint(4e18);
        vm.startPrank(alice);
        nvda.approve(address(vault), cost);
        uint256 assets = vault.mint(4e18, carol);
        vm.stopPrank();

        assertEq(assets, 4e18, "1:1 on an empty vault");
        assertEq(vault.balanceOf(carol), 4e18, "receiver holds the shares");
        assertEq(vault.balanceOf(alice), 0, "payer holds none");
        assertEq(nvda.balanceOf(alice), 26e18, "payer paid");
    }

    /*//////////////////////////////////////////////////////////////
                                PHASES
    //////////////////////////////////////////////////////////////*/

    /// @dev New money in Listed must sit in idle, NOT be bolted onto the open short. A late
    ///      depositor who could be assigned against a call written before they arrived would
    ///      be paying for someone else's week.
    function test_depositAndMintWorkWhileListed() public {
        _deposit(alice, 20e18);
        _rollOpen(10);

        assertEq(_phase(), 1, "Listed");
        assertEq(vault.contractsWritten(), 10, "10 contracts written");
        assertEq(vault.lockedAssets(), 10e18, "10 NVDA behind the claim");
        assertEq(vault.idleAssets(), 10e18, "10 NVDA idle");
        assertEq(vault.totalAssets(), 20e18, "writing did not move the share price");

        uint256 bobShares = _deposit(bob, 10e18);
        assertEq(bobShares, 10e18, "still 1:1, the short is not marked to market");
        assertEq(vault.contractsWritten(), 10, "deposit did not enlarge the short");
        assertEq(vault.lockedAssets(), 10e18, "collateral behind the claim is unchanged");
        assertEq(vault.idleAssets(), 20e18, "new money is idle");

        uint256 paid = _mintShares(carol, 5e18);
        assertEq(paid, 5e18, "mint is 1:1 too");
        assertEq(vault.contractsWritten(), 10, "mint did not enlarge the short either");
        assertEq(vault.idleAssets(), 25e18, "minted assets are idle");
        assertEq(vault.totalAssets(), 35e18, "idle 25 + locked 10");
        assertEq(vault.totalSupply(), 35e18, "supply");
        assertEq(_phase(), 1, "still Listed");
    }

    function test_depositRevertsInExercisable() public {
        _deposit(alice, 20e18);
        _rollOpen(10);
        _warpToExercise();
        vault.lockBook();
        assertEq(_phase(), 2, "Exercisable");

        vm.startPrank(bob);
        nvda.approve(address(vault), 5e18);
        vm.expectRevert(Vault.DepositsClosed.selector);
        vault.deposit(5e18, bob);
        vm.stopPrank();
    }

    function test_mintRevertsInExercisable() public {
        _deposit(alice, 20e18);
        _rollOpen(10);
        _warpToExercise();
        vault.lockBook();

        vm.startPrank(bob);
        nvda.approve(address(vault), 5e18);
        vm.expectRevert(Vault.DepositsClosed.selector);
        vault.mint(5e18, bob);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              DEPOSIT CAP
    //////////////////////////////////////////////////////////////*/

    function test_maxDepositShrinksToZeroAtTheCap() public {
        assertEq(vault.maxDeposit(alice), DEPOSIT_CAP, "empty vault offers the whole cap");

        _deposit(alice, 30e18);
        assertEq(vault.maxDeposit(alice), 20e18, "cap less what is held");

        _deposit(bob, 20e18);
        assertEq(vault.maxDeposit(carol), 0, "full");
        assertEq(nvda.balanceOf(address(vault)), DEPOSIT_CAP, "held exactly the cap");

        // One wei over is over.
        vm.startPrank(carol);
        nvda.approve(address(vault), 1);
        vm.expectRevert(abi.encodeWithSelector(Vault.DepositCapExceeded.selector, DEPOSIT_CAP + 1, DEPOSIT_CAP));
        vault.deposit(1, carol);
        vm.stopPrank();
    }

    function test_mintRespectsTheDepositCap() public {
        _deposit(alice, 30e18);
        _deposit(bob, 20e18);

        // previewMint(1) costs 1 asset at this price; hoisted out of expectRevert's way.
        uint256 cost = vault.previewMint(1);
        assertEq(cost, 1, "one wei of shares costs one wei of assets here");

        vm.startPrank(carol);
        nvda.approve(address(vault), cost);
        vm.expectRevert(abi.encodeWithSelector(Vault.DepositCapExceeded.selector, DEPOSIT_CAP + 1, DEPOSIT_CAP));
        vault.mint(1, carol);
        vm.stopPrank();
    }

    function test_adminCanReopenTheCap() public {
        _deposit(alice, 30e18);
        _deposit(bob, 20e18);
        assertEq(vault.maxDeposit(carol), 0, "full");

        vm.prank(admin);
        vault.setDepositCap(60e18);
        assertEq(vault.maxDeposit(carol), 10e18, "cap re-opened by 10");

        uint256 shares = _deposit(carol, 10e18);
        assertEq(shares, 10e18, "still 1:1");
        assertEq(vault.maxDeposit(carol), 0, "and full again");
        assertEq(vault.totalAssets(), 60e18, "assets");
    }

    /// @dev A direct transfer in counts against the cap, because the cap is measured on the
    ///      balance and not on deposits. Worth pinning: it means anyone can shrink the room
    ///      left under the cap for the price of the tokens they give away.
    function test_donationCountsAgainstTheCap() public {
        _donate(1e18);
        assertEq(vault.maxDeposit(alice), 49e18, "donated asset eats cap room");

        // The quote is not the claim: prove the boundary actually bites. 49e18 fits exactly,
        // and the very next wei is refused with the cap arithmetic spelled out in the error.
        _deposit(alice, 30e18);
        _deposit(bob, 19e18);
        assertEq(nvda.balanceOf(address(vault)), DEPOSIT_CAP, "donation + deposits == the cap");
        assertEq(vault.maxDeposit(carol), 0, "no room left");

        vm.startPrank(carol);
        nvda.approve(address(vault), 1);
        vm.expectRevert(abi.encodeWithSelector(Vault.DepositCapExceeded.selector, DEPOSIT_CAP + 1, DEPOSIT_CAP));
        vault.deposit(1, carol);
        vm.stopPrank();
    }

    /// @dev Lowering the cap under what is already held does not claw anything back; it just
    ///      shuts the door. Worth pinning because an admin reaching for `setDepositCap` in an
    ///      incident must know it is not a withdrawal tool.
    function test_loweringTheCapBelowHoldingsBlocksDepositsButKeepsTheMoney() public {
        _deposit(alice, 30e18);

        vm.prank(admin);
        vault.setDepositCap(10e18);

        assertEq(vault.maxDeposit(bob), 0, "no room under the lowered cap");
        assertEq(vault.totalAssets(), 30e18, "already-deposited assets are untouched");
        assertEq(vault.balanceOf(alice), 30e18, "and so are the shares");

        vm.startPrank(bob);
        nvda.approve(address(vault), 1e18);
        vm.expectRevert(abi.encodeWithSelector(Vault.DepositCapExceeded.selector, 31e18, 10e18));
        vault.deposit(1e18, bob);
        vm.stopPrank();

        // Alice can still leave: the cap gates the way in, never the way out.
        vm.prank(alice);
        assertEq(vault.redeem(30e18, alice, alice), 30e18, "exit is unaffected by the cap");
    }

    /// @dev The write path enforces the cap on NAV, so writing collateral into Valorem cannot
    ///      re-open it. REGRESSION GUARD for a real defect: the cap used to be measured on
    ///      `asset.balanceOf(vault)`, and collateral written into Valorem has left that
    ///      balance. The moment the vault went Listed the cap re-opened by however much was
    ///      written, and total exposure could be driven far above `depositCap` with no admin
    ///      action at all. `maxDeposit`, `deposit` and `mint` all read `totalAssets()` now,
    ///      which counts locked collateral.
    ///
    ///      The sibling test below pins the same property at the view; this one proves the
    ///      quote is not just honest but actually enforced on the way in.
    function test_capStaysShutWhileCollateralIsLockedInValorem() public {
        _deposit(alice, 30e18);
        _deposit(bob, 20e18);
        assertEq(vault.maxDeposit(carol), 0, "full while flat");

        _rollOpen(47); // 95% utilization of 50 idle
        assertEq(vault.lockedAssets(), 47e18, "collateral left the vault balance");
        assertEq(nvda.balanceOf(address(vault)), 3e18, "and the raw balance really did drop");
        assertEq(vault.totalAssets(), DEPOSIT_CAP, "but NAV is unchanged: 3e18 idle + 47e18 locked");
        assertEq(vault.maxDeposit(carol), 0, "so the cap did NOT re-open by what was written");
        assertEq(vault.maxMint(carol), 0, "and maxMint mirrors it");

        // The quote is not the claim: prove the write path refuses too, with the cap
        // arithmetic spelled out against NAV rather than against the drained balance.
        vm.startPrank(carol);
        nvda.approve(address(vault), 30e18);
        vm.expectRevert(abi.encodeWithSelector(Vault.DepositCapExceeded.selector, 80e18, DEPOSIT_CAP));
        vault.deposit(30e18, carol);
        vm.stopPrank();

        assertEq(vault.totalAssets(), DEPOSIT_CAP, "exposure never exceeded the cap");
    }

    /// @dev `maxDeposit` must never quote room the caller cannot take. REGRESSION GUARD: it
    ///      used to ignore the phase entirely and advertise headroom in Exercisable, where
    ///      `deposit` always reverts `WrongPhase`. That is the same dishonesty as
    ///      `previewRedeem` quoting an instant redemption while the queue is the only path.
    ///      It now returns 0 outside Idle and Listed, and `maxMint` mirrors it.
    function test_maxDepositRespectsThePhaseGate() public {
        _deposit(alice, 20e18);
        _rollOpen(10);

        // Listed is a phase where `deposit` works, so the quote must be live and exact:
        // 20e18 of NAV against a 50e18 cap leaves 30e18, whether or not it is locked.
        assertEq(_phase(), 1, "Listed");
        assertEq(vault.maxDeposit(bob), 30e18, "real room in a phase that accepts deposits");

        _warpToExercise();
        vault.lockBook();

        assertEq(_phase(), 2, "Exercisable");
        assertEq(vault.maxDeposit(bob), 0, "no quote in a phase the caller cannot deposit in");
        assertEq(vault.maxMint(bob), 0, "and none from maxMint either");

        vm.startPrank(bob);
        nvda.approve(address(vault), 1e18);
        vm.expectRevert(Vault.DepositsClosed.selector);
        vault.deposit(1e18, bob);
        vm.stopPrank();

        // Settling is unreachable from outside, but Idle after the close must quote again.
        _warpToExpiry();
        _rollClose();
        assertEq(_phase(), 0, "Idle");
        assertEq(vault.maxDeposit(bob), 30e18, "the quote comes back with the phase");
    }

    /*//////////////////////////////////////////////////////////////
                             ZERO AMOUNTS
    //////////////////////////////////////////////////////////////*/

    function test_zeroDepositReverts() public {
        vm.prank(alice);
        vm.expectRevert(Vault.ZeroAssets.selector);
        vault.deposit(0, alice);
    }

    function test_zeroMintReverts() public {
        vm.prank(alice);
        vm.expectRevert(Vault.ZeroShares.selector);
        vault.mint(0, alice);
    }

    function test_zeroRedeemReverts() public {
        _deposit(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(Vault.ZeroShares.selector);
        vault.redeem(0, alice, alice);
    }

    function test_zeroWithdrawReverts() public {
        _deposit(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(Vault.ZeroAssets.selector);
        vault.withdraw(0, alice, alice);
    }

    /*//////////////////////////////////////////////////////////////
                         INSTANT REDEMPTION
    //////////////////////////////////////////////////////////////*/

    function test_instantRedeemWhileFlat() public {
        _deposit(alice, 10e18);
        assertTrue(vault.canRedeemInstantly(), "flat");
        assertEq(vault.previewRedeem(4e18), 4e18, "preview");

        vm.prank(alice);
        uint256 assets = vault.redeem(4e18, alice, alice);

        assertEq(assets, 4e18, "paid what it previewed");
        assertEq(vault.balanceOf(alice), 6e18, "shares burned");
        assertEq(vault.totalSupply(), 6e18, "supply burned too");
        assertEq(nvda.balanceOf(alice), 24e18, "assets returned");
        assertEq(vault.totalAssets(), 6e18, "vault shrank by the same");
    }

    /// @dev `withdraw` is the exact-assets side, so the SHARE count is what rounds, and it
    ///      must round up. At 2 assets/share, 5 assets costs 2.5 shares plus one wei.
    ///
    ///      HAND-CHECKED ARITHMETIC:
    ///        state: totalAssets = 20e18, totalSupply = 10e18
    ///        previewWithdraw(a) = a * (supply + 1) / (assets + 1), rounded UP
    ///                           = 5e18 * (10e18 + 1) / (20e18 + 1)
    ///        numerator = 5e36 + 5e18
    ///        2.5e18 * (20e18 + 1) = 5e36 + 2.5e18, leaving a remainder of 2.5e18
    ///        remainder is non-zero, so Ceil bumps the quotient: 2.5e18 + 1.
    ///        That single wei is the whole point - it is charged to the exiting holder,
    ///        never to the ones who stay.
    function test_instantWithdrawBurnsSharesRoundedUp() public {
        _deposit(alice, 10e18);
        _donate(10e18);

        uint256 expectedShares = 2_500_000_000_000_000_001;
        assertEq(vault.previewWithdraw(5e18), expectedShares, "preview rounds the share cost up");

        vm.prank(alice);
        uint256 shares = vault.withdraw(5e18, alice, alice);

        assertEq(shares, expectedShares, "burned what it previewed");
        assertEq(nvda.balanceOf(alice), 25e18, "got exactly the assets asked for");
        assertEq(vault.balanceOf(alice), 10e18 - expectedShares, "shares burned");
    }

    function test_redeemToAnotherReceiver() public {
        _deposit(alice, 10e18);

        vm.prank(alice);
        uint256 assets = vault.redeem(10e18, bob, alice);

        assertEq(assets, 10e18, "assets");
        assertEq(nvda.balanceOf(bob), 40e18, "receiver got the assets");
        assertEq(nvda.balanceOf(alice), 20e18, "owner did not");
        assertEq(vault.balanceOf(alice), 0, "owner's shares burned");
    }

    /*//////////////////////////////////////////////////////////////
                       INSTANT PATH CLOSED WHEN SHORT
    //////////////////////////////////////////////////////////////*/

    function test_redeemRevertsUseQueueOnceACallIsOpen() public {
        _deposit(alice, 20e18);
        _rollOpen(10);

        assertFalse(vault.canRedeemInstantly(), "a call is open");

        vm.prank(alice);
        vm.expectRevert(Vault.UseQueue.selector);
        vault.redeem(1e18, alice, alice);
    }

    function test_withdrawRevertsUseQueueOnceACallIsOpen() public {
        _deposit(alice, 20e18);
        _rollOpen(10);

        vm.prank(alice);
        vm.expectRevert(Vault.UseQueue.selector);
        vault.withdraw(1e18, alice, alice);
    }

    /// @dev The vault holds 10 idle NVDA here, so a redemption of 1 could physically be paid.
    ///      It is still refused: the queue is the only fair path while anyone is short, because
    ///      paying an early exit out of idle would hand the assignment risk to whoever stayed.
    function test_useQueueEvenWhenIdleCouldCoverIt() public {
        _deposit(alice, 20e18);
        _rollOpen(10);
        assertEq(vault.idleAssets(), 10e18, "idle could cover a small exit");

        vm.prank(alice);
        vm.expectRevert(Vault.UseQueue.selector);
        vault.redeem(1e18, alice, alice);
    }

    /// @dev TECHSPEC 4.3: a preview must never quote a number the caller cannot get right now.
    ///      `convertTo*` still tells the truth about value; only the previews go quiet.
    function test_previewsReturnZeroWhileACallIsOpen() public {
        _deposit(alice, 20e18);
        assertEq(vault.previewRedeem(10e18), 10e18, "flat: the real figure");
        assertEq(vault.previewWithdraw(10e18), 10e18, "flat: the real figure");

        _rollOpen(10);

        assertEq(vault.previewRedeem(10e18), 0, "open: quotes nothing");
        assertEq(vault.previewWithdraw(10e18), 0, "open: quotes nothing");
        assertEq(vault.convertToAssets(10e18), 10e18, "value itself is unchanged");
        assertEq(vault.convertToShares(10e18), 10e18, "value itself is unchanged");

        // Still zero in Exercisable, and back to the truth once the cycle closes flat.
        _warpToExercise();
        vault.lockBook();
        assertEq(vault.previewRedeem(10e18), 0, "Exercisable: quotes nothing");

        _warpToExpiry();
        _rollClose();
        assertEq(_phase(), 0, "Idle again");
        assertEq(vault.previewRedeem(10e18), 10e18, "flat again: the real figure");
        assertEq(vault.previewWithdraw(10e18), 10e18, "flat again: the real figure");
    }

    /*//////////////////////////////////////////////////////////////
                              ALLOWANCE
    //////////////////////////////////////////////////////////////*/

    function test_redeemOnBehalfSpendsAllowance() public {
        _deposit(alice, 10e18);

        vm.prank(alice);
        vault.approve(bob, 4e18);

        vm.prank(bob);
        uint256 assets = vault.redeem(4e18, bob, alice);

        assertEq(assets, 4e18, "assets");
        assertEq(vault.allowance(alice, bob), 0, "allowance consumed");
        assertEq(vault.balanceOf(alice), 6e18, "owner's shares burned");
        assertEq(nvda.balanceOf(bob), 34e18, "spender received the assets");
    }

    function test_redeemOnBehalfRevertsWithoutAllowance() public {
        _deposit(alice, 10e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 4e18));
        vault.redeem(4e18, bob, alice);
    }

    function test_redeemOnBehalfRevertsWhenAllowanceIsShort() public {
        _deposit(alice, 10e18);

        vm.prank(alice);
        vault.approve(bob, 3e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 3e18, 4e18));
        vault.redeem(4e18, bob, alice);
    }

    function test_withdrawOnBehalfSpendsAllowance() public {
        _deposit(alice, 10e18);

        vm.prank(alice);
        vault.approve(bob, 4e18);

        vm.prank(bob);
        uint256 shares = vault.withdraw(4e18, bob, alice);

        assertEq(shares, 4e18, "shares burned at 1:1");
        assertEq(vault.allowance(alice, bob), 0, "allowance consumed");
        assertEq(nvda.balanceOf(bob), 34e18, "spender received the assets");
    }

    function test_withdrawOnBehalfRevertsWithoutAllowance() public {
        _deposit(alice, 10e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 4e18));
        vault.withdraw(4e18, bob, alice);
    }

    /*//////////////////////////////////////////////////////////////
                           SHARE TRANSFERS
    //////////////////////////////////////////////////////////////*/

    function test_shareTransferMovesTheClaimOnTheUnderlying() public {
        _deposit(alice, 10e18);

        vm.prank(alice);
        vault.transfer(bob, 4e18);

        assertEq(vault.balanceOf(alice), 6e18, "sender's stake shrank");
        assertEq(vault.balanceOf(bob), 4e18, "receiver's stake grew");
        assertEq(vault.previewRedeem(4e18), 4e18, "and it is worth 4 assets");

        vm.prank(bob);
        uint256 assets = vault.redeem(4e18, bob, bob);
        assertEq(assets, 4e18, "the new holder redeems it");
        assertEq(nvda.balanceOf(bob), 34e18, "assets landed with the new holder");

        vm.prank(alice);
        uint256 aliceAssets = vault.redeem(6e18, alice, alice);
        assertEq(aliceAssets, 6e18, "and the old holder gets only what is left");
        assertEq(vault.totalSupply(), 0, "vault emptied");
    }

    /*//////////////////////////////////////////////////////////////
                       FIRST-DEPOSITOR INFLATION
    //////////////////////////////////////////////////////////////*/

    /// @dev The classic grief: donate assets into an empty vault so the first real depositor's
    ///      share count rounds toward nothing. The +1 virtual share/asset offset bounds it —
    ///      the depositor still gets non-zero shares, and what they lose is capped by what the
    ///      griefer threw away. It is NOT a total loss and it is NOT free for the attacker.
    function test_inflationGriefIsBoundedByTheDonation() public {
        _donate(1e18); // the griefer burns 1 NVDA to set this up

        uint256 shares = _deposit(alice, 10e18);
        assertGt(shares, 0, "first depositor is not minted zero shares");
        assertEq(shares, 9, "the offset floors the count, it does not zero it");

        vm.prank(alice);
        uint256 back = vault.redeem(shares, alice, alice);

        assertEq(back, 9.9e18, "redeems the donated pot too, less the rounding");
        assertGe(back, 10e18 - 1e18, "loss is capped by what the griefer donated");
        assertLe(10e18 - back, 1e18, "and it is nowhere near a total loss");
        assertEq(nvda.balanceOf(alice), 29.9e18, "alice is down 0.1, the griefer is down 1.0");

        // Where the missing 0.1 went: it is stranded in a vault with no shares left against
        // it, alongside the griefer's own 1.0. Nobody captured it, which is why the grief is
        // not profitable - the attacker cannot get it back either.
        assertEq(vault.totalSupply(), 0, "no shares remain");
        assertEq(nvda.balanceOf(address(vault)), 1.1e18, "the griefer's outlay plus Alice's dust is stranded");
    }

    /// @dev And when the donation is big enough that the share count WOULD round to zero, the
    ///      deposit reverts instead of silently taking the money for nothing.
    function test_depositRevertsRatherThanMintZeroShares() public {
        _donate(30e18);

        vm.startPrank(alice);
        nvda.approve(address(vault), 10e18);
        vm.expectRevert(Vault.ZeroShares.selector);
        vault.deposit(10e18, alice);
        vm.stopPrank();

        assertEq(nvda.balanceOf(alice), 30e18, "no assets were taken");
        assertEq(vault.totalSupply(), 0, "no shares were minted");
    }

    /*//////////////////////////////////////////////////////////////
                  LISTED-PHASE DEPOSIT: THE PREMIUM SEAT
    //////////////////////////////////////////////////////////////*/

    /// @dev A depositor whose money never backed the short earns none of the premium that
    ///      short was paid for.
    ///
    ///      REGRESSION GUARD for a real dilution defect. `deposit` is open in Listed, and a
    ///      premium lands the moment a buyer fills — days before `rollClose` runs the harvest.
    ///      An earlier draft indexed that money only at the close, across `totalSupply()` as it
    ///      stood at THAT instant, so anyone could deposit after the fill and take a cut of a
    ///      week they had not carried. `deposit` and `mint` now call `_checkpointHarvest()`
    ///      BEFORE minting: the accrual is folded into `accUsdgPerShare` first, and the new
    ///      shares start from the fixed index.
    ///
    ///      HAND-CHECKED ARITHMETIC (verify against the fixture, do not trust the number):
    ///        buyer pays 10 contracts x $2.00           = 20_000_000 USDG gross
    ///        Overcall's 5%, floored per contract       =  1_000_000 to overcallFee
    ///        vault receives                            = 19_000_000
    ///        protocol fee, 5% of the premium           =    950_000, held in pendingFeeUsdg
    ///          (a checkpoint passes feeFree 0; strike proceeds cannot be here yet)
    ///        net pushed into the index                 = 18_050_000
    ///        supply AT THE CHECKPOINT = alice alone    =       20e18
    ///        indexDelta = 18_050_000 * 1e27 / 20e18    = 902_500_000_000_000, exact
    ///        alice      = 20e18 * indexDelta / 1e27    = 18_050_000   (all of it)
    ///        bob        = snapshot taken AT that index =          0
    ///      At the close the vault holds 19_000_000 against owed 18_050_000 + pending fee
    ///      950_000, so `_harvest` finds gross 0 and only sweeps the fee to feeSafe.
    ///      Alice wrote the call and carried the whole week, and she keeps every cent her risk
    ///      earned. Bob arrived after the hand was decided and leaves with his principal, and
    ///      nothing else.
    function test_lateDepositorInListedDoesNotEarnTheWeeksPremium() public {
        _deposit(alice, 20e18);

        uint256 optionId = _rollOpen(10);
        OrderComponents memory c = _approveListing(optionId, 10, _okUnitPrice());
        _fill(c, 10);

        assertEq(usdg.balanceOf(address(vault)), 19_000_000, "premium already in the vault");
        assertEq(_phase(), 1, "still Listed, so deposits are open");
        assertEq(vault.claimableUsdg(alice), 0, "nothing indexed until something checkpoints");

        // Bob arrives with the week's outcome already known and nothing at stake. His own
        // deposit runs the checkpoint that locks him out of it.
        uint256 bobShares = _deposit(bob, 20e18);
        assertEq(bobShares, 20e18, "bought in at an unmoved price: USDG is not in the share price");
        assertEq(vault.lockedAssets(), 10e18, "his money is NOT behind the short");
        assertEq(vault.idleAssets(), 30e18, "it is idle, carrying no risk");

        // The index moved before his shares existed, so the split is already settled here,
        // days before the close.
        assertEq(vault.claimableUsdg(alice), 18_050_000, "the writer's week, indexed at the checkpoint");
        assertEq(vault.claimableUsdg(bob), 0, "and the latecomer starts from that index");
        assertEq(vault.pendingFeeUsdg(), 950_000, "the fee accrued rather than leaving inside a deposit");

        _closeCycle();

        assertEq(vault.claimableUsdg(bob), 0, "no pay for a risk never taken");
        assertEq(vault.claimableUsdg(alice), 18_050_000, "the harvest is the writer's, whole");
        assertEq(usdg.balanceOf(feeSafe), 950_000, "and the fee was swept once, at the close");
        assertEq(vault.pendingFeeUsdg(), 0, "with nothing left pending");
        assertEq(vault.usdgDust(), 0, "18.05 over 20e18 shares indexes exactly");

        // He gets his principal back and not a cent more.
        vm.prank(bob);
        assertEq(vault.redeem(bobShares, bob, bob), 20e18, "principal returned whole");
        assertEq(nvda.balanceOf(bob), 30e18, "bob is square on the asset");
        assertEq(usdg.balanceOf(bob), 0, "and square on USDG: no free ride");

        vm.prank(bob);
        vm.expectRevert(Distributor.NothingToClaim.selector);
        vault.claimUsdg();
    }

    /// @dev The same property at the view: a full vault stays full while it is short, because
    ///      `maxDeposit` measures the cap on `totalAssets()` and collateral locked in Valorem
    ///      is still the vault's responsibility. REGRESSION GUARD for a cap that used to
    ///      re-open by exactly what the keeper wrote; the enforcement half is
    ///      `test_capStaysShutWhileCollateralIsLockedInValorem`.
    function test_capCountsCollateralWrittenIntoValorem() public {
        _deposit(alice, 30e18);
        _deposit(bob, 20e18);
        _rollOpen(47);

        assertEq(vault.maxDeposit(carol), 0, "a full vault stays full while short");
    }

    /*//////////////////////////////////////////////////////////////
                     REMAINING SURFACE ON THE BRIEF
    //////////////////////////////////////////////////////////////*/

    /// @dev `mint` shares the Deposit event with `deposit`, and the event must carry the assets
    ///      actually pulled, not the shares. An indexer reading the wrong field would report a
    ///      vault that grew by 4 tokens when it grew by 8.
    function test_mintEmitsDepositWithTheAssetsActuallyPaid() public {
        _deposit(alice, 10e18);
        _donate(10e18); // 2 assets per share

        // HAND-CHECKED ARITHMETIC: totalAssets = 20e18, totalSupply = 10e18.
        //   floor value of 4e18 shares = 4e18 * (20e18 + 1) / (10e18 + 1), floored:
        //     (8e18 - 1) * (1e19 + 1) = 8e37 - 2e18 - 1, remainder 6e18 + 1, which is
        //     below the divisor 1e19 + 1, so the floor is 8e18 - 1.
        //   previewMint rounds that UP, so the cost is 8e18 - one wei more than the shares
        //   are worth, charged to the minter and not to the holders who stayed.
        uint256 cost = vault.previewMint(4e18);
        assertEq(vault.convertToAssets(4e18), 8e18 - 1, "floor value of the shares");
        assertEq(cost, 8e18, "mint cost is that, rounded up");

        vm.startPrank(bob);
        nvda.approve(address(vault), cost);
        vm.expectEmit(true, true, false, true, address(vault));
        emit Vault.Deposit(bob, bob, cost, 4e18);
        vault.mint(4e18, bob);
        vm.stopPrank();
    }

    function test_withdrawToAnotherReceiver() public {
        _deposit(alice, 10e18);

        vm.prank(alice);
        uint256 shares = vault.withdraw(4e18, carol, alice);

        assertEq(shares, 4e18, "shares burned from the owner");
        assertEq(nvda.balanceOf(carol), 34e18, "receiver got the assets");
        assertEq(nvda.balanceOf(alice), 20e18, "owner got none of them");
        assertEq(vault.balanceOf(alice), 6e18, "owner paid out of her own shares");
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev The one property that must never break: a deposit followed immediately by a
    ///      redeem cannot be a profit. If it could, the round trip would be a free pump on
    ///      every other holder's share price. The vault is seeded off 1:1 first so the
    ///      rounding actually has somewhere to go.
    function testFuzz_depositThenRedeemNeverReturnsMoreThanWentIn(uint256 amount) public {
        _deposit(alice, 7e18);
        _donate(3e18); // price is now 10/7 assets per share

        amount = bound(amount, 1e6, 30e18);

        uint256 shares = _deposit(bob, amount);
        vm.prank(bob);
        uint256 out = vault.redeem(shares, bob, bob);

        assertLe(out, amount, "a round trip must never pay out more than it took in");
        // ...and it must not silently eat a real amount either: the only loss allowed is the
        // sub-share rounding, which at this price is under two wei of asset per leg.
        assertLe(amount - out, 3, "round-trip loss is rounding dust only");
    }

    /// @dev Same property on the mint/withdraw pair, which round the other way.
    ///      This asserts on an EXECUTED redeem, not on `previewRedeem`: a preview that lied
    ///      would sail through a preview-only check, and the preview is exactly the thing a
    ///      rounding bug would get wrong.
    function testFuzz_mintThenRedeemNeverReturnsMoreThanWentIn(uint256 shares) public {
        _deposit(alice, 7e18);
        _donate(3e18);

        shares = bound(shares, 1e6, 20e18);

        uint256 paid = _mintShares(bob, shares);
        uint256 quoted = vault.previewRedeem(shares);

        vm.prank(bob);
        uint256 out = vault.redeem(shares, bob, bob);

        assertEq(out, quoted, "the preview must match what the redeem actually pays");
        assertLe(out, paid, "minting then redeeming the same shares is never a profit");
        assertLe(paid - out, 2, "and the only loss allowed is sub-wei rounding on each leg");
    }

    /// @dev The exact-assets side, executed rather than previewed. Two properties at once:
    ///      `withdraw` hands over the exact assets asked for (checked on the token balance,
    ///      not on the function's own return value, so a short payment cannot hide behind its
    ///      own report), and the share cost it charges never exceeds what the caller owns.
    ///
    ///      The target is `convertToAssets(shares)`, NOT the original deposit. Asking for the
    ///      deposit back exactly is unaffordable by design: deposit floors the shares and
    ///      withdraw ceils them, so the round trip is short by one share. That is the vault
    ///      rounding in the pool's favour on both legs, and it is correct.
    function testFuzz_withdrawPaysExactlyTheAssetsAsked(uint256 amount) public {
        _deposit(alice, 7e18);
        _donate(3e18);

        amount = bound(amount, 1e6, 20e18);

        uint256 shares = _deposit(bob, amount);
        vm.assume(shares != 0);

        uint256 target = vault.convertToAssets(shares);
        vm.assume(target != 0);

        uint256 before = nvda.balanceOf(bob);
        uint256 quoted = vault.previewWithdraw(target);
        vm.prank(bob);
        uint256 burned = vault.withdraw(target, bob, bob);

        assertEq(nvda.balanceOf(bob) - before, target, "withdraw pays the exact assets asked");
        assertEq(burned, quoted, "and burns exactly the shares it previewed");
        assertLe(burned, shares, "never charges more shares than the caller owns");
        assertLe(target, amount, "the round trip is never a profit");
        assertLe(amount - target, 2, "and loses only rounding dust");
    }

    /// @dev Deposit pricing must be monotone in the deposit: more assets in can never buy
    ///      fewer shares, at any size.
    function testFuzz_previewDepositIsMonotone(uint256 a, uint256 b) public {
        _deposit(alice, 7e18);
        _donate(3e18);

        a = bound(a, 1, 20e18);
        b = bound(b, a, 40e18);

        assertLe(vault.previewDeposit(a), vault.previewDeposit(b), "more assets, never fewer shares");

        // Monotonicity is worth nothing if the preview is not the price actually charged.
        uint256 quoted = vault.previewDeposit(a);
        vm.assume(quoted != 0);
        assertEq(_deposit(bob, a), quoted, "previewDeposit is the price deposit actually charges");
    }
}
