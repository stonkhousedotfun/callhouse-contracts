// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {Vault} from "../../src/Vault.sol";
import {Policy} from "../../src/Policy.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {OrderComponents} from "../../src/interfaces/ISeaport.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @notice The redeem queue: escrow, settlement, and collection.
/// @dev The queue is the ONLY exit while a call is open, so everything here is a
///      depositor-safety property rather than a nicety. Three rules drive the file:
///
///        1. Escrow is real. Queued shares leave the holder's balance and sit on the vault,
///           so nothing can move or sell them out from under the settlement they back.
///        2. Shares in escrow keep earning until settlement, and that accrual leaves WITH the
///           redeemer. It must never fall to the holders who stayed.
///        3. Settlement fixes an Epoch and claimants draw it down proportionally. The last
///           claimant takes whatever is left, which is what makes the division exact and
///           leaves zero dust stranded in the vault forever.
contract VaultQueueTest is BaseTest {
    /*//////////////////////////////////////////////////////////////
                         EVENTS (mirrors of Vault)
    //////////////////////////////////////////////////////////////*/

    event QueueRedeem(address indexed owner, uint256 shares, uint256 epochId);
    event QueueSettled(uint256 indexed epochId, uint256 shares, uint256 assets, uint256 usdgOut);
    event CompleteRedeem(
        address indexed owner, address indexed receiver, uint256 shares, uint256 assets, uint256 usdgOut
    );
    event QueueEntrySettled(
        address indexed owner, uint256 indexed epochId, uint256 shares, uint256 assets, uint256 usdgOut
    );

    /*//////////////////////////////////////////////////////////////
                            AWKWARD NUMBERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Chosen so nothing divides evenly: 7 + 1 + 3.3333 = 11.3333 queued out of a 33.0
    ///      supply, settled against a 28.0 asset pot and $1,179.70 of gross USDG ($1,178.465
    ///      net: the 5% fee touches only the $24.70 premium, never the $1,155 of strikes).
    uint256 internal constant Q_ALICE = 7e18;
    uint256 internal constant Q_BOB = 1e18;
    uint256 internal constant Q_CAROL = 3_333_300_000_000_000_000; // 3.3333

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Close the current cycle out of the money: lock the book, expire, settle.
    function _closeCycle() internal {
        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();
        _rollClose();
    }

    /// @dev Close the current cycle with `assignN` contracts exercised against it, so the
    ///      vault comes back holding less of the asset and some USDG from the strike.
    function _closeCycleAssigned(uint256 optionId_, uint112 assignN) internal {
        _warpToExercise();
        _exercise(optionId_, assignN);
        vault.lockBook();
        _warpToExpiry();
        _rollClose();
    }

    /// @dev Register a fresh cycle dated from now, and re-stamp the feed. The fixture's cycle
    ///      is one-shot: after a roll closes, its write deadline and its price are both stale.
    function _nextCycle() internal {
        exerciseTs = uint40(block.timestamp + 6 days);
        expiryTs = uint40(block.timestamp + 7 days);
        _installCycle();
        feed.setAnswer(SPOT_FEED);
    }

    /// @dev Open + list + fill in one go, leaving the vault in Listed with premium banked.
    function _openAndFill(uint112 n) internal returns (uint256 optionId_) {
        optionId_ = _rollOpen(n);
        OrderComponents memory c = _approveListing(optionId_, n, _okUnitPrice());
        _fill(c, n);
    }

    function _queue(address who, uint256 shares) internal returns (uint256 epoch) {
        vm.prank(who);
        epoch = vault.queueRedeem(shares);
    }

    function _complete(address who) internal returns (uint256 assets, uint256 usdgOut) {
        vm.prank(who);
        (assets, usdgOut) = vault.completeRedeem(who);
    }

    /*//////////////////////////////////////////////////////////////
                                ESCROW
    //////////////////////////////////////////////////////////////*/

    /// @dev The escrow IS the safety model: the shares leave the holder's balance and sit on
    ///      the vault, where nothing can reach them while the claim they back is open. Total
    ///      supply must not change — burning happens at settlement, not here — otherwise the
    ///      share price would jump for everyone the moment somebody joined the queue.
    function test_queueRedeemEscrowsSharesOnTheVault() public {
        _deposit(alice, 20e18);
        uint256 supplyBefore = vault.totalSupply();

        vm.expectEmit(true, false, false, true, address(vault));
        emit QueueRedeem(alice, 8e18, 1);
        uint256 epoch = _queue(alice, 8e18);

        assertEq(epoch, 1, "first settlement is epoch 1");
        assertEq(vault.balanceOf(alice), 12e18, "escrowed shares left the holder");
        assertEq(vault.balanceOf(address(vault)), 8e18, "and landed on the vault itself");
        assertEq(vault.totalSupply(), supplyBefore, "escrow is a transfer, not a burn");
        assertEq(vault.queuedSharesOf(alice), 8e18, "queuedSharesOf");
        assertEq(vault.queuedEpochOf(alice), 1, "queuedEpochOf");
        assertEq(vault.queuedShares(), 8e18, "global queue total");

        // Nothing is reserved until rollClose actually settles the epoch.
        assertEq(vault.reservedAssets(), 0, "no reservation before settlement");
        assertEq(vault.totalAssets(), 20e18, "NAV untouched by queueing");
        assertEq(vault.convertToAssets(1e18), 1e18, "and so is the share price");
    }

    /// @dev A holder must be able to commit their WHOLE position. Anything less and the queue
    ///      is not an exit, it is a haircut.
    function test_queueRedeemAcceptsTheEntireBalance() public {
        _deposit(alice, 10e18);

        _queue(alice, 10e18);

        assertEq(vault.balanceOf(alice), 0, "whole position escrowed");
        assertEq(vault.balanceOf(address(vault)), 10e18, "escrow holds all of it");
        assertEq(vault.queuedSharesOf(alice), 10e18, "slot holds all of it");
        assertEq(vault.totalSupply(), 10e18, "supply unchanged until settlement");
    }

    function test_queueRedeemRejectsZero() public {
        _deposit(alice, 5e18);
        vm.prank(alice);
        vm.expectRevert(Vault.ZeroShares.selector);
        vault.queueRedeem(0);
    }

    function test_queueRedeemRejectsMoreSharesThanOwned() public {
        _deposit(alice, 5e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Vault.InsufficientFreeShares.selector, 5e18, 5e18 + 1));
        vault.queueRedeem(5e18 + 1);
    }

    function test_queueRedeemTwiceInSameEpochAccumulates() public {
        _deposit(alice, 20e18);

        uint256 e1 = _queue(alice, 4e18);
        uint256 e2 = _queue(alice, 4e18);

        assertEq(e1, e2, "both land in the same open epoch");
        assertEq(vault.queuedSharesOf(alice), 8e18, "queued position accumulates");
        assertEq(vault.queuedShares(), 8e18, "global total accumulates");
        assertEq(vault.balanceOf(address(vault)), 8e18, "both tranches escrowed");
        assertEq(vault.balanceOf(alice), 12e18, "holder debited once per call");
    }

    /*//////////////////////////////////////////////////////////////
                           TRANSFER LOCK
    //////////////////////////////////////////////////////////////*/

    /// @dev The queued position must not be sellable out from under the settlement. Because
    ///      escrow is a real transfer, the guarantee is structural: the shares are simply not
    ///      in the holder's balance any more, so there is nothing to move.
    function test_escrowedSharesAreBeyondTheHoldersReach() public {
        _deposit(alice, 12e18);
        _queue(alice, 8e18);

        uint256 free = vault.balanceOf(alice);
        assertEq(free, 4e18, "only the un-queued remainder is still hers to move");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, free, free + 1));
        vault.transfer(bob, free + 1);

        // The free remainder still moves normally, and the queue slot is untouched by it.
        vm.prank(alice);
        assertTrue(vault.transfer(bob, free), "free remainder transfers");
        assertEq(vault.balanceOf(bob), 4e18, "bob received the free shares");
        assertEq(vault.queuedSharesOf(alice), 8e18, "queue slot survives the transfer");
        assertEq(vault.balanceOf(address(vault)), 8e18, "escrow survives the transfer");

        // And having given the remainder away she cannot queue what she no longer holds.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Vault.InsufficientFreeShares.selector, 0, 1));
        vault.queueRedeem(1);
    }

    /// @dev A settled-but-uncollected slot must not hold the holder's OTHER shares hostage.
    ///      Those shares are hers, the vault is flat, and the instant path has to stay open.
    function test_settledSlotDoesNotFreezeTheHoldersRemainingShares() public {
        _deposit(alice, 20e18);
        _queue(alice, 10e18);

        _rollOpen(10);
        _closeCycle();

        assertTrue(vault.canRedeemInstantly(), "vault is flat again");
        assertEq(vault.balanceOf(alice), 10e18, "she still holds 10e18 un-queued shares");
        assertEq(vault.queuedSharesOf(alice), 10e18, "settled slot not yet collected");

        vm.prank(alice);
        assertEq(vault.redeem(10e18, alice, alice), 10e18, "instant path still open to her");

        (uint256 assets,) = _complete(alice);
        assertEq(assets, 10e18, "and the queued half collects on top");
        assertEq(nvda.balanceOf(alice), 30e18, "every token back");
        assertEq(nvda.balanceOf(address(vault)), 0, "nothing stranded");
    }

    /*//////////////////////////////////////////////////////////////
                          COMPLETE: GUARD RAILS
    //////////////////////////////////////////////////////////////*/

    function test_completeRedeemRevertsBeforeTheEpochSettles() public {
        _deposit(alice, 20e18);
        _queue(alice, 5e18);
        _rollOpen(10);

        // Hoisted: reading epochId is an external call and would disarm expectRevert.
        uint256 current = vault.epochId();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Vault.EpochNotSettled.selector, current, current));
        vault.completeRedeem(alice);

        // Still not settled right up to the moment rollClose runs.
        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Vault.EpochNotSettled.selector, current, current));
        vault.completeRedeem(alice);

        _rollClose();
        (uint256 assets,) = _complete(alice);
        assertEq(assets, 5e18, "and opens the moment it does");
    }

    function test_completeRedeemRevertsWithNoPosition() public {
        _deposit(bob, 10e18);
        vm.prank(bob);
        vm.expectRevert(Vault.NothingQueued.selector);
        vault.completeRedeem(bob);

        // Still nothing to collect after someone else's epoch settles.
        _deposit(alice, 10e18);
        _queue(alice, 5e18);
        _rollOpen(10);
        _closeCycle();

        vm.prank(bob);
        vm.expectRevert(Vault.NothingQueued.selector);
        vault.completeRedeem(bob);
    }

    /// @dev Collecting twice must not drain a second slice of the epoch.
    function test_completeRedeemCannotBeClaimedTwice() public {
        _deposit(alice, 20e18);
        _queue(alice, 5e18);
        _rollOpen(10);
        _closeCycle();

        _complete(alice);
        vm.prank(alice);
        vm.expectRevert(Vault.NothingQueued.selector);
        vault.completeRedeem(alice);
    }

    /*//////////////////////////////////////////////////////////////
                        SETTLE + COLLECT, UNFILLED
    //////////////////////////////////////////////////////////////*/

    /// @dev A week nobody bought is still a week the queue must clear: full pro-rata assets
    ///      back, no USDG, and no protocol fee charged on a zero harvest.
    function test_queuedPositionSurvivesAnUnfilledWeek() public {
        _deposit(alice, 20e18);
        _queue(alice, 5e18);

        _rollOpen(10); // written, never listed, never filled

        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();
        vm.expectEmit(true, false, false, true, address(vault));
        emit QueueSettled(1, 5e18, 5e18, 0);
        _rollClose();

        assertEq(vault.epochId(), 2, "epoch rolled forward");
        (uint256 sharesR, uint256 assetsR, uint256 usdgR) = vault.epochs(1);
        assertEq(sharesR, 5e18, "epoch shares");
        assertEq(assetsR, 5e18, "a quarter of a 20e18 pot for a quarter of the supply");
        assertEq(usdgR, 0, "nothing was sold, so nothing accrued");
        assertEq(usdg.balanceOf(feeSafe), 0, "an unfilled week is free");

        (uint256 assets, uint256 usdgOut) = _complete(alice);
        assertEq(assets, 5e18, "full pro-rata assets");
        assertEq(usdgOut, 0, "no USDG on an unfilled week");
        assertEq(nvda.balanceOf(alice), 10e18 + 5e18, "10e18 never deposited + 5e18 redeemed");
        assertEq(vault.reservedAssets(), 0, "reservation released");
        assertEq(vault.queuedSharesOf(alice), 0, "slot cleared");
        assertEq(vault.queuedEpochOf(alice), 0, "epoch pointer cleared");
    }

    /*//////////////////////////////////////////////////////////////
                      WHO OWNS THE WEEK'S PREMIUM
    //////////////////////////////////////////////////////////////*/

    /// @dev THE reason escrow holds shares instead of burning them early. Alice queues half
    ///      her position during Listed and sits through the fill. Her escrowed half must earn
    ///      exactly the same USDG per share as the half she kept, and Bob — who stayed — must
    ///      earn exactly his own share and not one cent of hers.
    ///
    ///      20e18 supply, 10 contracts at $2.00: gross $20, Overcall 5% -> $19 to the vault,
    ///      protocol 5% of that premium -> $0.95, leaving $18.05 to spread over 20e18 shares.
    ///        indexDelta = 18_050_000 * 1e27 / 20e18 = 902_500_000_000_000, exact (no dust)
    ///        escrow 5e18 -> 4_512_500   Alice 5e18 -> 4_512_500   Bob 10e18 -> 9_025_000
    function test_queuedSharesEarnTheWeeksPremiumNotTheStayers() public {
        _deposit(alice, 10e18);
        _deposit(bob, 10e18);

        _openAndFill(10);
        assertEq(_phase(), 1, "Listed");

        _queue(alice, 5e18); // queueing during Listed is allowed

        _closeCycle();

        assertEq(usdg.balanceOf(overcallFee), 1_000_000, "Overcall's 5%");
        assertEq(usdg.balanceOf(feeSafe), 950_000, "protocol 5% of the $19 premium");

        (uint256 sharesR, uint256 assetsR, uint256 usdgR) = vault.epochs(1);
        assertEq(sharesR, 5e18, "epoch shares");
        assertEq(assetsR, 5e18, "expired OTM, so a quarter of the 20e18 pot");
        assertEq(usdgR, 4_512_500, "the escrow's own quarter of $18.05");

        assertEq(vault.claimableUsdg(bob), 9_025_000, "the stayer earns exactly his half, no windfall");
        assertEq(vault.claimableUsdg(alice), 4_512_500, "Alice's un-queued quarter");
        assertEq(vault.usdgReservedForQueue(), 4_512_500, "the escrow's accrual is ring-fenced");

        (uint256 pa, uint256 pu) = vault.previewCompleteRedeem(alice);
        assertEq(pa, 5e18, "preview assets");
        assertEq(pu, 4_512_500, "preview usdg");

        vm.expectEmit(true, true, false, true, address(vault));
        emit CompleteRedeem(alice, alice, 5e18, 5e18, 4_512_500);
        (uint256 assets, uint256 usdgOut) = _complete(alice);
        assertEq(assets, pa, "payout matches preview");
        assertEq(usdgOut, pu, "payout matches preview");

        vm.prank(alice);
        vault.claimUsdg();

        // Both halves earned the same rate, and the total matches Bob's for equal exposure.
        assertEq(usdg.balanceOf(alice), 9_025_000, "queued half + kept half == a full week's rate");
        assertEq(vault.claimableUsdg(bob), 9_025_000, "stayer's share is exactly his own");
        assertEq(vault.usdgReservedForQueue(), 0, "ring-fence released");
        assertEq(usdg.balanceOf(address(vault)), 9_025_000, "only Bob's claim is left behind");
    }

    /*//////////////////////////////////////////////////////////////
                     RESERVED ASSETS ARE OFF THE NAV
    //////////////////////////////////////////////////////////////*/

    /// @dev Between settlement and collection the vault physically holds the redeemer's
    ///      assets. If those counted toward `totalAssets` the share price would spike for
    ///      everyone else and then collapse when the redeemer finally showed up — a free
    ///      option on other people's collateral.
    function test_reservedAssetsAreExcludedFromNavUntilCollected() public {
        _deposit(alice, 10e18);
        _deposit(bob, 10e18);
        _queue(alice, 5e18);

        _rollOpen(10);
        _closeCycle();

        assertEq(nvda.balanceOf(address(vault)), 20e18, "assets are physically still here");
        assertEq(vault.reservedAssets(), 5e18, "but 5e18 of them is spoken for");
        assertEq(vault.totalSupply(), 15e18, "escrowed shares burned at settlement");
        assertEq(vault.totalAssets(), 15e18, "NAV excludes the reservation");
        assertEq(vault.idleAssets(), 15e18, "and so does writable idle");
        assertEq(vault.convertToAssets(1e18), 1e18, "share price is unmoved at exactly 1.0");

        // Collecting must not move the price either.
        _complete(alice);
        assertEq(vault.reservedAssets(), 0, "reservation released");
        assertEq(vault.totalAssets(), 15e18, "NAV unchanged by the collection");
        assertEq(vault.convertToAssets(1e18), 1e18, "share price still exactly 1.0");
    }

    /// @dev A settled-but-uncollected reservation is not the vault's asset to lend against,
    ///      so it must not be writable as collateral for the next cycle either.
    function test_reservedAssetsAreNotWritableCollateral() public {
        _deposit(alice, 10e18);
        _deposit(bob, 10e18);
        _queue(alice, 5e18);

        _rollOpen(10);
        _closeCycle();
        _nextCycle();

        // Idle is 15e18, so 95% utilisation allows 14 contracts — not the 19 the raw 20e18
        // balance would imply.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Policy.ContractsAboveUtilization.selector, uint256(15), uint256(14)));
        vault.rollOpen(optionIds[RUNG_PICK], 15);

        vm.prank(keeper);
        vault.rollOpen(optionIds[RUNG_PICK], 14);
        assertEq(vault.contractsWritten(), 14, "capped by idle net of the reservation");
    }

    /*//////////////////////////////////////////////////////////////
                         THE ZERO-DUST PROPERTY
    //////////////////////////////////////////////////////////////*/

    /// @dev THE core queue invariant. Three holders queue amounts that share no common factor
    ///      with each other or with the pot, and the pot itself is awkward: a 33e18 supply
    ///      writes 13 contracts, 5 of which are assigned, so 28e18 of asset and $1,179.70 of
    ///      USDG ($1,178.465 after the premium-only fee) come back to be split 11.3333e18 ways.
    ///
    ///      A naive "everyone gets floor(pot * mine / total)" split strands dust in the vault
    ///      forever, once per epoch, for the life of the product. This proves the draw-down
    ///      design instead: each claimant is paid out of what is LEFT, so the last one absorbs
    ///      the remainder and the epoch closes at exactly zero on all three ledgers.
    function test_zeroDust_threeAwkwardClaimantsLeaveNothingBehind() public {
        _deposit(alice, 20e18);
        _deposit(bob, 4e18);
        _deposit(carol, 9e18);
        assertEq(vault.totalSupply(), 33e18, "awkward supply");

        uint256 optionId_ = _openAndFill(13);

        _queue(alice, Q_ALICE);
        _queue(bob, Q_BOB);
        _queue(carol, Q_CAROL);
        uint256 q = Q_ALICE + Q_BOB + Q_CAROL;
        assertEq(vault.queuedShares(), q, "11.3333e18 queued");

        _closeCycleAssigned(optionId_, 5);

        (uint256 sharesR, uint256 assetsR, uint256 usdgR) = vault.epochs(1);
        assertEq(sharesR, q, "epoch holds every queued share");
        assertEq(vault.reservedAssets(), assetsR, "reservation matches the epoch");
        assertEq(vault.usdgReservedForQueue(), usdgR, "USDG ring-fence matches the epoch");
        assertGt(assetsR, 0, "there is an asset pot to split");
        assertGt(usdgR, 0, "and a USDG pot");

        // Prove the numbers really are indivisible: a flat floor split loses money on BOTH
        // legs. Without the draw-down design, this is the dust that would stay behind.
        uint256 naiveAssets = (assetsR * Q_ALICE) / q + (assetsR * Q_BOB) / q + (assetsR * Q_CAROL) / q;
        uint256 naiveUsdg = (usdgR * Q_ALICE) / q + (usdgR * Q_BOB) / q + (usdgR * Q_CAROL) / q;
        assertLt(naiveAssets, assetsR, "a flat floor split would strand asset dust");
        assertLt(naiveUsdg, usdgR, "a flat floor split would strand USDG dust");

        // Collect out of order; the LAST caller, whoever it is, absorbs the remainder.
        (uint256 bA, uint256 bU) = _complete(bob);
        (uint256 cA, uint256 cU) = _complete(carol);

        (, uint256 leftA, uint256 leftU) = vault.epochs(1);
        (uint256 aA, uint256 aU) = _complete(alice);
        assertEq(aA, leftA, "last claimant takes the whole asset remainder");
        assertEq(aU, leftU, "last claimant takes the whole USDG remainder");
        assertGt(aA, (assetsR * Q_ALICE) / q, "strictly more than her flat floor share");
        assertGt(aU, (usdgR * Q_ALICE) / q, "on the USDG leg too");

        // ZERO DUST.
        (uint256 s0, uint256 a0, uint256 u0) = vault.epochs(1);
        assertEq(s0, 0, "epoch sharesRemaining == 0");
        assertEq(a0, 0, "epoch assetsRemaining == 0");
        assertEq(u0, 0, "epoch usdgRemaining == 0");
        assertEq(vault.reservedAssets(), 0, "reservedAssets back to 0");
        assertEq(vault.usdgReservedForQueue(), 0, "usdgReservedForQueue back to 0");

        // And nothing was conjured: the payouts sum to exactly what was reserved.
        assertEq(bA + cA + aA, assetsR, "asset payouts sum to the reservation");
        assertEq(bU + cU + aU, usdgR, "USDG payouts sum to the reservation");
    }

    /// @dev The degenerate end of the same property: everybody leaves at once. Supply goes to
    ///      zero, NAV goes to zero, and the vault must still hand every token over and remain
    ///      usable for the next depositor rather than bricking on a 0/0.
    function test_zeroDust_everyShareQueuedDrainsTheVaultCompletely() public {
        _deposit(alice, 10e18);
        _deposit(bob, 10e18);

        _openAndFill(10);
        _queue(alice, 10e18);
        _queue(bob, 10e18);
        assertEq(vault.balanceOf(address(vault)), 20e18, "the entire supply is in escrow");

        _closeCycle();

        assertEq(vault.totalSupply(), 0, "every share burned at settlement");
        assertEq(vault.totalAssets(), 0, "NAV is zero: it all belongs to the epoch now");
        assertEq(vault.reservedAssets(), 20e18, "the whole pot is reserved");
        // $19.00 premium, 5% protocol fee $0.95, $18.05 net indexed over the 20e18 escrow.
        (,, uint256 usdgR) = vault.epochs(1);
        assertEq(usdgR, 18_050_000, "the whole net premium follows the queue out");
        assertEq(usdg.balanceOf(feeSafe), 950_000, "protocol fee still taken");

        (uint256 aA, uint256 aU) = _complete(alice);
        (uint256 bA, uint256 bU) = _complete(bob);
        assertEq(aA + bA, 20e18, "all collateral out");
        assertEq(aU + bU, 18_050_000, "all premium out");
        assertEq(nvda.balanceOf(address(vault)), 0, "no asset stranded");
        assertEq(usdg.balanceOf(address(vault)), 0, "no USDG stranded");

        // Not bricked: the next depositor starts from a clean 1:1.
        assertEq(_deposit(carol, 5e18), 5e18, "vault is reusable after a full exit");
    }

    /*//////////////////////////////////////////////////////////////
                      ASSIGNED WEEK: A MIXED PAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @dev When the call is assigned the collateral is gone and USDG came in at the strike.
    ///      The queue must pay what the vault actually has — fewer tokens plus cash — rather
    ///      than promising one asset unit per share and quietly going short.
    ///
    ///      20e18 supply, 10 written, 4 assigned at $231: 16e18 of asset survives, and $19 of
    ///      premium plus $924 of strike proceeds land. The 5% protocol fee is on the premium
    ///      only; the strike proceeds are principal and reach holders fee-free.
    ///        gross 943_000_000 | fee 19_000_000 * 5% = 950_000 | net 942_050_000
    ///        indexDelta = 942_050_000 * 1e27 / 20e18 = 47_102_500_000_000_000, exact
    ///        escrow 5e18 -> 235_512_500
    function test_assignedWeekPaysAMixOfAssetAndUsdg() public {
        _deposit(alice, 10e18);
        _deposit(bob, 10e18);

        uint256 optionId_ = _openAndFill(10);
        _queue(alice, 5e18);

        _closeCycleAssigned(optionId_, 4);

        assertEq(nvda.balanceOf(buyer), 4e18, "buyer took delivery of 4 lots");
        assertEq(nvda.balanceOf(address(vault)), 16e18, "vault is 4e18 lighter");
        assertEq(usdg.balanceOf(feeSafe), 950_000, "5% of $19 premium, nothing on the $924 strike");

        (, uint256 assetsR, uint256 usdgR) = vault.epochs(1);
        assertEq(assetsR, 4e18, "a quarter of the 16e18 that survived, not the 5e18 queued");
        assertEq(usdgR, 235_512_500, "a quarter of the $942.05 net");

        (uint256 assets, uint256 usdgOut) = _complete(alice);
        assertEq(assets, 4e18, "asset leg");
        assertEq(usdgOut, 235_512_500, "USDG leg");
        assertLt(assets, 5e18, "NOT a 1:1 token promise against the shares queued");

        // The stayer takes the identical haircut; assignment is not dumped on the queue.
        assertEq(vault.totalAssets(), 12e18, "16e18 less the 4e18 just collected");
        assertEq(vault.totalSupply(), 15e18, "5e18 burned at settlement");
        assertEq(vault.convertToAssets(10e18), 8e18, "Bob's half of the surviving 16e18");
    }

    /*//////////////////////////////////////////////////////////////
                         CROSS-EPOCH BEHAVIOUR
    //////////////////////////////////////////////////////////////*/

    /// @dev There is one queue slot per account, so a second `queueRedeem` in a later epoch has
    ///      to flush the settled one first. Without that, the earlier claim would be silently
    ///      overwritten and its assets orphaned in the epoch forever.
    ///
    ///      The flush PARKS the old position in `owedAssets` rather than paying it out. That is
    ///      deliberate: paying out means touching the Stock Token, and an issuer freeze would
    ///      then stop the holder from queueing at all. See
    ///      {test_issuerFreezeDoesNotBlockQueueingForAStaleSlotHolder}.
    function test_queueRedeemInALaterEpochParksTheSettledEntry() public {
        _deposit(alice, 20e18);
        _queue(alice, 5e18);

        _rollOpen(10);
        _closeCycle();
        assertEq(vault.epochId(), 2, "epoch 1 settled");
        assertEq(vault.reservedAssets(), 5e18, "epoch 1 still uncollected");

        uint256 nvdaBefore = nvda.balanceOf(alice);
        _nextCycle();

        // Alice never calls completeRedeem. Queueing again flushes the old slot into her owed
        // balance, moving no tokens.
        uint256 epoch = _queue(alice, 4e18);

        assertEq(epoch, 2, "the new position sits in the live epoch");
        assertEq(nvda.balanceOf(alice), nvdaBefore, "no tokens moved during the flush");
        assertEq(vault.owedAssets(alice), 5e18, "epoch 1 is parked, not orphaned");
        assertEq(vault.reservedAssets(), 5e18, "and stays reserved until she collects");

        (uint256 s1, uint256 a1,) = vault.epochs(1);
        assertEq(s1, 0, "epoch 1 drained");
        assertEq(a1, 0, "epoch 1 drained");
        assertEq(vault.queuedSharesOf(alice), 4e18, "slot now holds only the new position");
        assertEq(vault.queuedEpochOf(alice), 2, "pointer moved to epoch 2");
        assertEq(vault.queuedShares(), 4e18, "global total is the new position only");

        // Collecting the parked amount works immediately and leaves the new entry alone.
        vm.prank(alice);
        (uint256 got,) = vault.completeRedeem(alice);
        assertEq(got, 5e18, "collected the parked epoch");
        assertEq(nvda.balanceOf(alice), nvdaBefore + 5e18);
        assertEq(vault.reservedAssets(), 0, "epoch 1 fully released");
        assertEq(vault.queuedSharesOf(alice), 4e18, "the new queue entry survives");
    }

    /// @dev The auto-settle above must be visible off-chain: it moves real value out of an
    ///      epoch and into the owner's owed balances, and before the event existed an indexer
    ///      saw the epoch drain with no claim against it. 10 contracts filled at $2.00 gross
    ///      pays the vault 19_000_000; the 500 bps protocol fee on that premium (950_000) leaves
    ///      18_050_000 over 20 whole shares, and the escrow's quarter of the supply accrues
    ///      exactly 5e18 * (18_050_000 * 1e27 / 20e18) / 1e27 = 4_512_500.
    function test_queueEntrySettledIsEmittedWhenQueueingOverAStaleSlot() public {
        _deposit(alice, 20e18);
        _queue(alice, 5e18);

        _openAndFill(10);
        _closeCycle();
        _nextCycle();

        vm.expectEmit(true, true, true, true, address(vault));
        emit QueueEntrySettled(alice, 1, 5e18, 5e18, 4_512_500);
        _queue(alice, 4e18);

        assertEq(vault.owedAssets(alice), 5e18);
    }

    /// @dev The same event fires inside `completeRedeem`, immediately before `CompleteRedeem`
    ///      reports the payout, so a log reader can always tell which epoch a collection drew
    ///      down. Numbers are the unfilled-week case: the whole 5 queued shares, no USDG.
    function test_queueEntrySettledIsEmittedInsideCompleteRedeem() public {
        _deposit(alice, 20e18);
        _queue(alice, 5e18);

        _rollOpen(10);
        _closeCycle();

        vm.expectEmit(true, true, true, true, address(vault));
        emit QueueEntrySettled(alice, 1, 5e18, 5e18, 0);
        vm.expectEmit(true, true, true, true, address(vault));
        emit CompleteRedeem(alice, alice, 5e18, 5e18, 0);
        _complete(alice);
    }

    /// @dev REGRESSION. `queueRedeem` documents itself as never blocked: "If the issuer freezes
    ///      the Stock Token this still succeeds". An earlier draft made that false for anyone
    ///      carrying an uncollected epoch, because the implicit auto-complete moved the frozen
    ///      asset and took the whole call down with it. Settling a stale slot is now pure
    ///      bookkeeping, and only collecting touches tokens.
    function test_issuerFreezeDoesNotBlockQueueingForAStaleSlotHolder() public {
        _deposit(alice, 20e18);
        _deposit(bob, 20e18);
        _queue(alice, 5e18);

        _rollOpen(10);
        _closeCycle(); // epoch 1 settles; alice does not collect
        _nextCycle();

        (uint256 owedA,) = vault.previewCompleteRedeem(alice);
        assertGt(owedA, 0, "alice has an uncollected epoch");

        nvda.setFrozen(true);

        // A holder with no settled slot was never affected.
        _queue(bob, 5e18);
        assertEq(vault.queuedSharesOf(bob), 5e18, "a clean queue still works under a freeze");

        // And a holder carrying a stale slot can now queue too. The stale entry is moved into
        // her owed balance rather than paid out.
        vm.prank(alice);
        vault.queueRedeem(1e18);
        assertEq(vault.queuedSharesOf(alice), 1e18, "alice joined the new queue under a freeze");
        assertEq(vault.owedAssets(alice), owedA, "her settled epoch is parked, not lost");

        // Collecting is the one leg a freeze can stop, which is the honest failure: the tokens
        // genuinely cannot move. It costs her nothing else.
        vm.prank(alice);
        vm.expectRevert(MockStockToken.IssuerFreeze.selector);
        vault.completeRedeem(alice);

        // Once the issuer lifts the freeze she collects exactly what was parked.
        nvda.setFrozen(false);
        vm.prank(alice);
        (uint256 got,) = vault.completeRedeem(alice);
        assertEq(got, owedA, "collected in full after the freeze lifted");
        assertEq(vault.owedAssets(alice), 0);
    }

    /// @dev The deposit cap must be measured on NAV, not on the raw token balance. Assets that
    ///      settlement has already handed to the redeem queue are physically in the vault but
    ///      are owed out, not held from deposits. Counting them would let any redeemer who
    ///      simply never pressed "collect" cap the vault's growth indefinitely, for free.
    ///
    ///      This WAS a live defect: `maxDeposit`, `deposit` and `mint` all read
    ///      `asset.balanceOf(this)`. It is fixed in the current `src/Vault.sol`; this test is
    ///      what pins the fix so it cannot quietly regress.
    function test_uncollectedReservationDoesNotEatTheDepositCap() public {
        _deposit(alice, 30e18);
        _deposit(bob, 20e18); // 50e18 cap, now full
        assertEq(vault.maxDeposit(carol), 0, "full while every token backs a live share");

        _queue(alice, 30e18);
        _rollOpen(10);
        _closeCycle();

        assertEq(nvda.balanceOf(address(vault)), 50e18, "the asset is all still physically here");
        assertEq(vault.reservedAssets(), 30e18, "but Alice's exit is settled, just uncollected");
        assertEq(vault.totalAssets(), 20e18, "only Bob's 20e18 is really the vault's");
        assertEq(vault.maxDeposit(carol), 30e18, "so the cap has 30e18 of genuine headroom");

        assertEq(_deposit(carol, 10e18), 10e18, "and a deposit into it goes through at 1:1");
        assertEq(vault.maxDeposit(carol), 20e18, "headroom shrinks by exactly what was taken");

        // Collecting moves assets out of the building but never out of the NAV, so it must not
        // move the headroom either.
        (uint256 got,) = _complete(alice);
        assertEq(got, 30e18, "Alice's reservation was never diluted by the new money");
        assertEq(nvda.balanceOf(address(vault)), 30e18, "Bob's 20e18 plus Carol's 10e18");
        assertEq(vault.totalAssets(), 30e18, "NAV unchanged by the collection");
        assertEq(vault.maxDeposit(carol), 20e18, "and so is the headroom");
    }

    /// @dev A settlement with an empty queue must be a no-op: no epoch written, no id burned.
    ///      Burning the id would be invisible until somebody queued, and then their epoch
    ///      pointer would name a slot that settlement had already walked past.
    function test_settlementWithAnEmptyQueueIsANoOp() public {
        _deposit(alice, 20e18);
        _rollOpen(10);
        _closeCycle();

        assertEq(vault.epochId(), 1, "epoch id does not advance on an empty queue");
        (uint256 s, uint256 a, uint256 u) = vault.epochs(1);
        assertEq(s, 0, "no epoch shares recorded");
        assertEq(a, 0, "no epoch assets recorded");
        assertEq(u, 0, "no epoch USDG recorded");
        assertEq(vault.reservedAssets(), 0, "nothing reserved");
        assertEq(vault.usdgReservedForQueue(), 0, "nothing ring-fenced");

        // The id really was not consumed: the next real queue still settles INTO epoch 1.
        _nextCycle();
        assertEq(_queue(alice, 5e18), 1, "the untouched id is still the live one");
        _rollOpen(10);
        _closeCycle();

        (uint256 s2, uint256 a2, uint256 u2) = vault.epochs(1);
        assertEq(s2, 5e18, "epoch 1 finally carries the real queue");
        assertEq(a2, 5e18, "a quarter of the 20e18 pot for a quarter of the supply");
        assertEq(u2, 0, "still nothing sold");
        assertEq(vault.epochId(), 2, "and only now does the id advance");
    }

    /*//////////////////////////////////////////////////////////////
                            HALT SEMANTICS
    //////////////////////////////////////////////////////////////*/

    /// @dev A halt is a brake on writing, never a trapdoor on depositors. Queueing, settling
    ///      and collecting all have to keep working while `writesHalted` is true, or the
    ///      guardian key quietly becomes a freeze key.
    function test_queueAndCollectWorkWhileWritesAreHalted() public {
        _deposit(alice, 20e18);
        _rollOpen(10);

        vm.prank(guardian);
        vault.haltWrites();
        assertTrue(vault.writesHalted(), "halted");

        // Queue while halted, mid-cycle.
        _queue(alice, 5e18);
        assertEq(vault.queuedSharesOf(alice), 5e18, "halt does not block queueRedeem");

        // Settle while halted: lockBook and rollClose are both unaffected.
        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();
        _rollClose();
        assertEq(_phase(), 0, "halt does not block rollClose");

        // Collect while halted.
        (uint256 assets,) = _complete(alice);
        assertEq(assets, 5e18, "halt does not block completeRedeem");
        assertTrue(vault.writesHalted(), "and the halt is still on");

        // Only the write is blocked.
        _nextCycle();
        vm.prank(keeper);
        vm.expectRevert(Vault.WritesAreHalted.selector);
        vault.rollOpen(optionIds[RUNG_PICK], 5);
    }

    /*//////////////////////////////////////////////////////////////
                        PREVIEWS AND THE QUEUE GATE
    //////////////////////////////////////////////////////////////*/

    /// @dev A preview that quotes a number the caller cannot actually get is a lie the UI will
    ///      repeat. While a call is open the queue is the only exit, so both previews read 0.
    function test_previewsReadZeroWhileTheQueueIsTheOnlyExit() public {
        _deposit(alice, 20e18);
        assertEq(vault.previewRedeem(5e18), 5e18, "the instant path quotes honestly while flat");

        _rollOpen(10);
        assertFalse(vault.canRedeemInstantly(), "a call is open");
        assertEq(vault.previewRedeem(5e18), 0, "previewRedeem must not quote the queue");
        assertEq(vault.previewWithdraw(5e18), 0, "previewWithdraw must not quote the queue");

        vm.prank(alice);
        vm.expectRevert(Vault.UseQueue.selector);
        vault.redeem(5e18, alice, alice);

        vm.prank(alice);
        vm.expectRevert(Vault.UseQueue.selector);
        vault.withdraw(5e18, alice, alice);
    }

    /// @dev `previewCompleteRedeem` is the queue's own quote and must stay silent until the
    ///      epoch it points at has actually settled.
    function test_previewCompleteRedeemIsZeroUntilSettled() public {
        _deposit(alice, 20e18);

        (uint256 a0, uint256 u0) = vault.previewCompleteRedeem(alice);
        assertEq(a0 + u0, 0, "nothing queued, nothing quoted");

        _queue(alice, 5e18);
        (uint256 a1, uint256 u1) = vault.previewCompleteRedeem(alice);
        assertEq(a1 + u1, 0, "queued but unsettled quotes nothing");

        _openAndFill(10);
        _closeCycle();

        (uint256 a2, uint256 u2) = vault.previewCompleteRedeem(alice);
        (uint256 gotA, uint256 gotU) = _complete(alice);
        assertEq(gotA, a2, "quote matched the asset payout");
        assertEq(gotU, u2, "quote matched the USDG payout");
        assertGt(gotU, 0, "and there really was USDG to quote");
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev The solvency half of the zero-dust property, over random sizes: whatever the three
    ///      claimants collect, it can never exceed what settlement set aside for them, and it
    ///      must add up to exactly that. Over-payment here would come straight out of the
    ///      remaining holders' collateral; under-payment strands it forever.
    ///
    ///      THE BOUNDS EARN THEIR KEEP. An earlier version of this test wrote a single contract
    ///      and allowed a 1-wei queue. At a 50e18 supply one contract nets $1.805 of premium
    ///      after the 5% fee, so the escrow's accrual is
    ///      floor(1 * (1_805_000 * 1e27 / 50e18) / 1e27) == 0 and every
    ///      USDG assertion below held trivially at 0 == 0. The contract count now scales with
    ///      the pot and the queue floor is 1e15, and `assertGt(usdgR, 0)` keeps it that way.
    function testFuzz_collectionsNeverExceedWhatWasReserved(
        uint96 dA,
        uint96 dB,
        uint96 dC,
        uint96 fA,
        uint96 fB,
        uint96 fC
    ) public {
        uint256 depA = bound(dA, 2e18, 20e18);
        uint256 depB = bound(dB, 2e18, 20e18);
        uint256 depC = bound(dC, 2e18, 10e18); // 50e18 deposit cap in total

        _deposit(alice, depA);
        _deposit(bob, depB);
        _deposit(carol, depC);

        // ~90% utilisation, inside the 9,500 bps policy ceiling and the 50-contract cap.
        _openAndFill(uint112((depA + depB + depC) * 9 / 10 / 1e18));

        uint256 qA = bound(fA, 1e15, depA);
        uint256 qB = bound(fB, 1e15, depB);
        uint256 qC = bound(fC, 1e15, depC);
        _queue(alice, qA);
        _queue(bob, qB);
        _queue(carol, qC);

        _closeCycle();

        (uint256 sharesR, uint256 assetsR, uint256 usdgR) = vault.epochs(1);
        assertEq(sharesR, qA + qB + qC, "epoch holds every queued share");
        assertEq(vault.reservedAssets(), assetsR, "reservation matches the epoch");
        assertEq(vault.usdgReservedForQueue(), usdgR, "ring-fence matches the epoch");
        assertGt(assetsR, 0, "the asset leg is genuinely live");
        assertGt(usdgR, 0, "and so is the USDG leg -- not a trivial 0 == 0 below");

        (uint256 pA, uint256 pU) = vault.previewCompleteRedeem(alice);
        (uint256 aA, uint256 aU) = _complete(alice);
        assertEq(aA, pA, "the quote Alice was shown is the amount she got");
        assertEq(aU, pU, "on the USDG leg too");
        (uint256 bA, uint256 bU) = _complete(bob);
        (uint256 cA, uint256 cU) = _complete(carol);

        assertLe(aA + bA + cA, assetsR, "never pays out more asset than was reserved");
        assertLe(aU + bU + cU, usdgR, "never pays out more USDG than was reserved");
        assertEq(aA + bA + cA, assetsR, "and never strands any of it either");
        assertEq(aU + bU + cU, usdgR, "and never strands any of it either");

        (uint256 s0, uint256 a0, uint256 u0) = vault.epochs(1);
        assertEq(s0, 0, "epoch drained");
        assertEq(a0, 0, "epoch drained");
        assertEq(u0, 0, "epoch drained");
        assertEq(vault.reservedAssets(), 0, "reservedAssets back to 0");
        assertEq(vault.usdgReservedForQueue(), 0, "usdgReservedForQueue back to 0");

        // Solvency, exactly: with nothing reserved and nothing locked, every token the vault
        // holds now backs a live share. `assertGe` here would pass on a vault that had
        // quietly stranded collateral outside the NAV, so pin the equality.
        assertEq(nvda.balanceOf(address(vault)), vault.totalAssets(), "no asset outside the NAV");
        assertEq(vault.totalSupply(), (depA - qA) + (depB - qB) + (depC - qC), "only the stayers' shares survive");
        // The full USDG identity. `usdgOwed()` alone is off by the index dust, which is a real
        // carried-forward balance and not a leak, so state every bucket rather than loosening
        // this to an approximate compare.
        assertEq(
            usdg.balanceOf(address(vault)),
            vault.usdgOwed() + vault.usdgDust() + vault.usdgUnallocated() + vault.pendingFeeUsdg(),
            "every USDG the vault still holds is owed to a stayer, carried as dust, or an unpaid fee"
        );
    }

    /// @dev Settlement must never reserve more of the asset than the vault is actually
    ///      holding, whatever the queue-to-supply ratio, and it must never hand the queue a
    ///      better price per share than the stayers keep. `payoutAssets` floors, which rounds
    ///      in the stayers' favour; the opposite rounding would let a queuer skim a wei per
    ///      settlement out of everybody else's collateral, every week, forever.
    ///
    ///      The fairness check is stated as a cross-multiplication so it is exact:
    ///        reserved / queued  <=  NAV_after / supply_after
    ///      Bob is always present so `supply_after` can never be 0 and the comparison is never
    ///      vacuous, and the week is always filled so the USDG leg is always real.
    function testFuzz_settlementNeverReservesMoreThanTheVaultHolds(uint96 dep, uint96 frac) public {
        uint256 deposit_ = bound(dep, 4e18, 30e18);
        uint256 q = bound(frac, 1e15, deposit_);

        _deposit(alice, deposit_);
        _deposit(bob, 10e18); // a stayer, so the split is a real division and not 100%
        _queue(alice, q);

        _openAndFill(uint112((deposit_ + 10e18) * 9 / 10 / 1e18));
        _closeCycle();

        uint256 held = nvda.balanceOf(address(vault));
        (, uint256 assetsR, uint256 usdgR) = vault.epochs(1);
        assertLe(assetsR, held, "the reservation is covered by a real balance");
        assertEq(vault.reservedAssets(), assetsR, "reservation recorded exactly once");
        assertEq(vault.totalAssets() + assetsR, held, "NAV + reservation == holdings");
        assertGt(usdgR, 0, "the USDG leg is live");

        // Fairness, both directions bounded: the queue's price per share is never better than
        // the stayers', and the gap it gives up is under one whole share's worth of dust.
        uint256 supplyAfter = vault.totalSupply();
        uint256 navAfter = vault.totalAssets();
        assertEq(supplyAfter, deposit_ + 10e18 - q, "only the queued shares were burned");
        assertLe(assetsR * supplyAfter, navAfter * q, "the queue never out-prices the stayers");
        // ...and the stayers' windfall is exactly one flooring, never a systematic skim:
        //   NAV_after*q - reserved*supply_after  ==  idle*q - reserved*supply_before  <  supply_before
        assertLt(
            navAfter * q - assetsR * supplyAfter,
            deposit_ + 10e18,
            "the stayers' gain is bounded by a single floor, not a haircut"
        );

        (uint256 got, uint256 gotU) = _complete(alice);
        assertEq(got, assetsR, "the sole claimant takes the whole epoch");
        assertEq(gotU, usdgR, "on the USDG leg too");
        assertEq(vault.reservedAssets(), 0, "and leaves nothing reserved");
        assertEq(vault.usdgReservedForQueue(), 0, "ring-fence released");
    }

    /*//////////////////////////////////////////////////////////////
                       TWO EPOCHS ALIVE AT ONCE
    //////////////////////////////////////////////////////////////*/

    /// @dev The hardest case the queue has to get right, and the one the single-epoch tests
    ///      cannot see. A second settlement runs while an earlier epoch is still uncollected,
    ///      so its payout MUST be derived from `idleAssets()` — the balance net of the first
    ///      epoch's reservation — and not from the raw token balance. Getting it from the raw
    ///      balance over-reserves epoch 2 and spends Alice's already-settled money on Bob.
    ///
    ///      HAND ARITHMETIC — check this against the fixture, do not trust it.
    ///        cycle 1  supply 40e18, held 40e18, Alice queues 10e18, nothing sold
    ///                 epoch1 = (10e18 shares, 40e18 * 10/40 = 10e18 assets, 0 USDG)
    ///                 reservedAssets 10e18 | supply 30e18 | NAV 40 - 10 = 30e18 | price 1.0
    ///        cycle 2  Bob queues 10e18, 12 contracts fill at $2.00
    ///                 gross $24.00, Overcall 5% = $1.20, so $22.80 reaches the vault
    ///                 protocol 5% of the $22.80 premium = $1.14 to feeSafe, $21.66 to spread
    ///                 indexDelta = 21_660_000 * 1e27 / 30e18 = 722_000_000_000_000, exact
    ///                   escrow 10e18 -> 7_220_000   Alice 10e18 -> 7_220_000   Bob 10e18 -> 7_220_000
    ///                 idleAssets = 40e18 held - 10e18 reserved = 30e18   (NOT 40e18)
    ///                 epoch2 = (10e18, 30e18 * 10/30 = 10e18, 7_220_000)
    ///                 reservedAssets 20e18 | supply 20e18 | NAV 20e18 | price still 1.0
    ///        A raw-balance settlement would have set epoch2's asset leg to
    ///        40e18 * 10/30 = 13.33e18 and put `reservedAssets` at 23.33e18 against a 40e18
    ///        balance that only has 20e18 of genuinely free collateral behind it.
    ///
    ///      WHY 12 CONTRACTS, NOT 10. The closing USDG checks below are exact: the vault holds
    ///      precisely the stayers' claims, with no index dust. That needs the net to split into
    ///      whole thirds. At 10 contracts the net is 18_050_000, which does not: the index floors
    ///      to 601_666_666_666_666, each third accrues 6_016_666 and 1 unit is carried as
    ///      `usdgDust`. 12 contracts (well inside 95% of the 30e18 idle) nets 21_660_000, which
    ///      divides by 3 exactly, so the property is still stated with assertEq.
    function test_twoUncollectedEpochsReserveIndependently() public {
        _deposit(alice, 20e18);
        _deposit(bob, 20e18);

        // ---- cycle 1: Alice queues, the week goes unsold ----
        _queue(alice, 10e18);
        _rollOpen(10);
        _closeCycle();

        assertEq(vault.epochId(), 2, "epoch 1 settled");
        assertEq(vault.reservedAssets(), 10e18, "and is left uncollected on purpose");
        assertEq(vault.totalAssets(), 30e18, "NAV already excludes it");

        // ---- cycle 2: Bob queues, the week fills ----
        _nextCycle();
        _queue(bob, 10e18);
        _openAndFill(12);
        _closeCycle();

        assertEq(usdg.balanceOf(feeSafe), 1_140_000, "5% of the $22.80 premium that reached the vault");

        (uint256 s2, uint256 a2, uint256 u2) = vault.epochs(2);
        assertEq(s2, 10e18, "epoch 2 shares");
        assertEq(a2, 10e18, "priced off idleAssets 30e18, NOT the 40e18 raw balance");
        assertEq(u2, 7_220_000, "the escrow's third of the $21.66 net");

        assertEq(vault.reservedAssets(), 20e18, "both epochs reserved, side by side");
        assertEq(nvda.balanceOf(address(vault)), 40e18, "and both are physically covered");
        assertEq(vault.totalSupply(), 20e18, "two 10e18 burns");
        assertEq(vault.totalAssets(), 20e18, "NAV nets off both reservations");
        assertEq(vault.convertToAssets(1e18), 1e18, "the stayers' price never moved");

        // ---- both collect, in the wrong order, long after the fact ----
        (uint256 bA, uint256 bU) = _complete(bob);
        assertEq(bA, 10e18, "epoch 2 asset leg");
        assertEq(bU, 7_220_000, "epoch 2 USDG leg");

        (uint256 aA, uint256 aU) = _complete(alice);
        assertEq(aA, 10e18, "epoch 1 paid in full despite settling first and collecting last");
        assertEq(aU, 0, "epoch 1 sat through an unsold week, so it carries no USDG");

        assertEq(vault.reservedAssets(), 0, "both reservations released");
        assertEq(nvda.balanceOf(address(vault)), 20e18, "exactly the stayers' collateral left");
        assertEq(vault.totalAssets(), 20e18, "and all of it counts");
        (, uint256 left1,) = vault.epochs(1);
        (, uint256 left2,) = vault.epochs(2);
        assertEq(left1, 0, "epoch 1 drained to zero");
        assertEq(left2, 0, "epoch 2 drained to zero");

        // $21.66 distributed, $7.22 walked out with Bob's queue, $14.44 owed to the stayers.
        assertEq(vault.claimableUsdg(alice), 7_220_000, "Alice's un-queued half earned its own");
        assertEq(vault.claimableUsdg(bob), 7_220_000, "so did Bob's");
        assertEq(usdg.balanceOf(address(vault)), 14_440_000, "and the vault holds exactly that");
        assertEq(vault.usdgOwed(), 14_440_000, "with nothing unaccounted for");
    }

    /*//////////////////////////////////////////////////////////////
                        THE QUEUE IS ALWAYS OPEN
    //////////////////////////////////////////////////////////////*/

    /// @dev The queue is the only exit while a call is open, so it must not have a phase gate
    ///      of its own. Exercisable is the dangerous one: the book is shut, the keeper has
    ///      nothing left to do, and a holder who cannot queue there is stranded for a week.
    function test_queueRedeemIsOpenInEveryPhase() public {
        _deposit(alice, 30e18);

        assertEq(_phase(), 0, "Idle");
        assertEq(_queue(alice, 1e18), 1, "queued from Idle");

        _rollOpen(10);
        assertEq(_phase(), 1, "Listed");
        assertEq(_queue(alice, 2e18), 1, "queued from Listed");

        _warpToExercise();
        vault.lockBook();
        assertEq(_phase(), 2, "Exercisable");
        assertEq(_queue(alice, 3e18), 1, "queued from Exercisable, after the book shut");

        assertEq(vault.queuedSharesOf(alice), 6e18, "all three tranches land in one epoch");
        assertEq(vault.balanceOf(alice), 24e18, "and all three left her balance");
        assertEq(vault.balanceOf(address(vault)), 6e18, "escrow holds the lot");

        _warpToExpiry();
        _rollClose();

        (uint256 assets,) = _complete(alice);
        assertEq(assets, 6e18, "6e18 of a 30e18 pot for 6e18 of a 30e18 supply");
    }

    /*//////////////////////////////////////////////////////////////
                     A FULL EXIT KEEPS OLD PREMIUM
    //////////////////////////////////////////////////////////////*/

    /// @dev A holder who leaves completely must keep the premium they already earned. The
    ///      accrual index is balance-weighted, so the instant the escrow transfer takes their
    ///      balance to zero there is nothing left to re-derive it from: it has to have been
    ///      settled into their claimable pot on the way out. Get this wrong and every full
    ///      exit silently donates its back-premium to whoever stayed.
    ///
    ///      HAND ARITHMETIC  cycle 1: 10 contracts at $2.00 -> $20.00 gross, $1.00 to Overcall,
    ///      $19.00 to the vault, $0.95 protocol fee (5% of that premium), $18.05 spread over a
    ///      20e18 supply = $0.9025 per 1e18 shares (indexDelta 902_500_000_000_000, exact).
    ///      Alice and Bob earn 9_025_000 each and neither claims.
    ///      Cycle 2 is unsold, so the escrow itself earns nothing and the epoch's USDG leg is 0
    ///      — which is precisely why Alice's 9_025_000 has to survive somewhere else.
    function test_aFullExitCarriesThePreviousWeeksUnclaimedPremium() public {
        _deposit(alice, 10e18);
        _deposit(bob, 10e18);

        _openAndFill(10);
        _closeCycle();

        assertEq(vault.claimableUsdg(alice), 9_025_000, "half of the $18.05 net");
        assertEq(vault.claimableUsdg(bob), 9_025_000, "the other half");

        // ---- Alice exits 100%, without ever claiming ----
        _nextCycle();
        _queue(alice, 10e18);
        assertEq(vault.balanceOf(alice), 0, "no share balance left to accrue against");
        assertEq(vault.claimableUsdg(alice), 9_025_000, "settled into her pot on the way into escrow");

        _rollOpen(5); // unsold week
        _closeCycle();

        (, uint256 assetsR, uint256 usdgR) = vault.epochs(1);
        assertEq(assetsR, 10e18, "her whole pro-rata share of the collateral");
        assertEq(usdgR, 0, "the escrow earned nothing in an unsold week");

        (uint256 assets, uint256 usdgOut) = _complete(alice);
        assertEq(assets, 10e18, "asset leg");
        assertEq(usdgOut, 0, "no USDG on the queue leg");
        assertEq(vault.totalSupply(), 10e18, "only Bob is left");

        // The old premium is still hers and still claimable with a zero share balance.
        assertEq(vault.claimableUsdg(alice), 9_025_000, "a full exit did not burn her back-premium");
        vm.prank(alice);
        assertEq(vault.claimUsdg(), 9_025_000, "and she can still draw it");
        assertEq(usdg.balanceOf(alice), 9_025_000, "paid in full");
        assertEq(nvda.balanceOf(alice), 30e18, "every NVDA token back as well");

        assertEq(vault.claimableUsdg(bob), 9_025_000, "the stayer got his own share and not one cent of hers");
        assertEq(usdg.balanceOf(address(vault)), 9_025_000, "exactly Bob's claim is left behind");
        assertEq(vault.usdgOwed(), 9_025_000, "and the ledger agrees with the balance");
    }

    /*//////////////////////////////////////////////////////////////
                      NEW MONEY PRICES OFF THE NAV
    //////////////////////////////////////////////////////////////*/

    /// @dev A settled-but-uncollected reservation is somebody else's money parked in the
    ///      vault's balance. If the mint priced against that raw balance instead of NAV, the
    ///      next depositor would be handed 9e18 * 9e18/30e18 = 2.7e18 shares for 9e18 of
    ///      asset — a 70% haircut paid straight to the incumbents — and Alice's reservation
    ///      would be diluted by money that arrived after her exit was already fixed.
    function test_depositAfterSettlementPricesOffNavNotTheRawBalance() public {
        _deposit(alice, 21e18);
        _deposit(bob, 9e18);

        _queue(alice, 21e18);
        _rollOpen(10);
        _closeCycle();

        assertEq(nvda.balanceOf(address(vault)), 30e18, "the asset is all still physically here");
        assertEq(vault.reservedAssets(), 21e18, "but 21e18 of it is Alice's already");
        assertEq(vault.totalAssets(), 9e18, "NAV is Bob's 9e18 and nothing more");
        assertEq(vault.totalSupply(), 9e18, "Bob's shares are the whole supply");

        assertEq(vault.previewDeposit(9e18), 9e18, "priced at NAV, so 1:1");
        uint256 minted = _deposit(carol, 9e18);
        assertEq(minted, 9e18, "and the mint matches the preview");
        assertEq(vault.totalAssets(), 18e18, "NAV is Bob + Carol, still net of the reservation");

        (uint256 got,) = _complete(alice);
        assertEq(got, 21e18, "Alice's reservation was never diluted by the new money");

        // Round trip: Carol takes exactly what she put in, so nothing leaked either way.
        vm.prank(carol);
        assertEq(vault.redeem(9e18, carol, carol), 9e18, "no value leaked on the way in");
        assertEq(vault.totalAssets(), 9e18, "Bob's 9e18, untouched by any of it");
        assertEq(vault.convertToAssets(9e18), 9e18, "and his price is still exactly 1.0");
    }

    /*//////////////////////////////////////////////////////////////
                          RECEIVER ROUTING
    //////////////////////////////////////////////////////////////*/

    /// @dev `completeRedeem` takes a receiver, and BOTH legs have to follow it. A payout that
    ///      honoured the receiver for the asset and quietly sent the USDG to the owner (or the
    ///      reverse) would clear the epoch and look correct on every aggregate assertion in
    ///      this file, so it is worth pinning the addresses directly.
    function test_completeRedeemPaysTheNominatedReceiver() public {
        _deposit(alice, 10e18);
        _deposit(bob, 10e18);

        _openAndFill(10);
        _queue(alice, 5e18);
        _closeCycle();

        uint256 aliceNvdaBefore = nvda.balanceOf(alice);
        uint256 aliceUsdgBefore = usdg.balanceOf(alice);
        uint256 carolNvdaBefore = nvda.balanceOf(carol);

        vm.prank(alice);
        (uint256 assets, uint256 usdgOut) = vault.completeRedeem(carol);

        // 20e18 supply, 10 contracts: $19.00 to the vault, $0.95 fee (5% of premium), $18.05
        // over 20e18. Alice's escrowed 5e18 is a quarter of that supply -> $4.5125.
        assertEq(assets, 5e18, "asset leg");
        assertEq(usdgOut, 4_512_500, "USDG leg");
        assertEq(nvda.balanceOf(carol), carolNvdaBefore + 5e18, "asset routed to the receiver");
        assertEq(usdg.balanceOf(carol), 4_512_500, "USDG routed to the same receiver");
        assertEq(nvda.balanceOf(alice), aliceNvdaBefore, "owner's asset balance untouched");
        assertEq(usdg.balanceOf(alice), aliceUsdgBefore, "owner's USDG balance untouched");

        // The slot belongs to the owner regardless of where the money went.
        assertEq(vault.queuedSharesOf(alice), 0, "owner's slot cleared");
        assertEq(vault.queuedSharesOf(carol), 0, "and the receiver never gained one");
        vm.prank(carol);
        vm.expectRevert(Vault.NothingQueued.selector);
        vault.completeRedeem(carol);
    }

    /*//////////////////////////////////////////////////////////////
                    THE FIXES THE BUGS ABOVE ARE WAITING ON
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
              A LATE DEPOSITOR CANNOT DILUTE THE QUEUE
    //////////////////////////////////////////////////////////////*/

    /// @dev `deposit` checkpoints the harvest before minting, which fixes the USDG index in
    ///      place so new shares start from it. The queue has to survive that seam: a premium
    ///      that landed on Monday belongs to the people who backed the call, including the
    ///      escrow, and a Friday depositor must not thin it out. The failure mode is quiet —
    ///      the epoch simply settles with less USDG in it and nobody can tell where it went.
    ///
    ///      HAND ARITHMETIC — supply is 20e18 when the order fills and when Carol's deposit
    ///      forces the checkpoint.
    ///        10 contracts at $2.00  -> $20.00 gross, Overcall 5% = $1.00, $19.00 to the vault
    ///        protocol 5% of the $19.00 premium = $0.95, leaving $18.05 to index over 20e18
    ///        indexDelta = 18_050_000 * 1e27 / 20e18 = 902_500_000_000_000, exact
    ///          Alice (5e18, kept)   -> 4_512_500
    ///          escrow (5e18)        -> 4_512_500   <- must survive Carol's arrival intact
    ///          Bob   (10e18)        -> 9_025_000
    ///          Carol (10e18, after) ->         0
    ///      The fee is taken once, at Carol's checkpoint, and swept at the close.
    ///      Carol then joins the ASSET pot, so settlement pays the escrow
    ///      30e18 * 5/30 = 5e18 — the same 1.0 per share everyone else holds.
    function test_aLateDepositorDoesNotDiluteAQueuedPositionsPremium() public {
        _deposit(alice, 10e18);
        _deposit(bob, 10e18);

        _openAndFill(10); // the premium is in the building, un-harvested
        _queue(alice, 5e18);

        // Carol arrives after the fill and before the close. Her deposit runs the checkpoint.
        assertEq(_deposit(carol, 10e18), 10e18, "priced at NAV: 10e18 idle + 10e18 locked");
        assertEq(vault.claimableUsdg(carol), 0, "she earns nothing from a week she did not back");

        _closeCycle();

        assertEq(usdg.balanceOf(feeSafe), 950_000, "5% of the $19.00 premium that reached the vault");
        assertEq(vault.pendingFeeUsdg(), 0, "and the accrued fee actually left at the close");

        (uint256 sharesR, uint256 assetsR, uint256 usdgR) = vault.epochs(1);
        assertEq(sharesR, 5e18, "epoch shares");
        assertEq(usdgR, 4_512_500, "the escrow's quarter of the $18.05, undiluted by Carol");
        assertEq(assetsR, 5e18, "and its sixth of the 30e18 asset pot Carol did join");

        assertEq(vault.claimableUsdg(alice), 4_512_500, "her kept half earned the same rate");
        assertEq(vault.claimableUsdg(bob), 9_025_000, "the stayer earned exactly his own");
        assertEq(vault.claimableUsdg(carol), 0, "and the latecomer still earns nothing");
        assertEq(
            vault.claimableUsdg(alice) + vault.claimableUsdg(bob) + usdgR,
            18_050_000,
            "every cent of the net premium is accounted for"
        );

        (uint256 assets, uint256 usdgOut) = _complete(alice);
        assertEq(assets, 5e18, "asset leg");
        assertEq(usdgOut, 4_512_500, "USDG leg");

        assertEq(vault.totalSupply(), 25e18, "5e18 burned at settlement");
        assertEq(vault.totalAssets(), 25e18, "and the asset pot follows it exactly");
        assertEq(vault.convertToAssets(1e18), 1e18, "so nobody's price moved at all");
    }

    /*//////////////////////////////////////////////////////////////
                 F1: SETTLING A QUEUE MADE WHILE FLAT
    //////////////////////////////////////////////////////////////*/

    /// @dev The PoC that used to trap alice. She queues while Idle, the guardian halts writes and
    ///      nobody lifts it: no `rollOpen`, so no `rollClose`, so no settlement, while bob (who
    ///      never queued) walks out instantly. A year later she was still stuck. Now anyone can
    ///      settle the flat queue, and she is paid what an instant redemption would have paid.
    function test_settleQueue_freesSharesQueuedWhileIdleUnderAHaltNobodyLifts() public {
        uint256 aliceStart = nvda.balanceOf(alice);
        uint256 bobStart = nvda.balanceOf(bob);
        _deposit(alice, 10e18);
        _deposit(bob, 10e18);
        _queue(alice, 10e18);
        vm.prank(guardian);
        vault.haltWrites();

        vm.prank(bob);
        vault.redeem(10e18, bob, bob);
        assertEq(nvda.balanceOf(bob), bobStart, "the holder who did not queue exits instantly");

        vm.warp(block.timestamp + 365 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Vault.EpochNotSettled.selector, 1, 1));
        vault.completeRedeem(alice);
        vm.expectRevert(abi.encodeWithSelector(Vault.WrongPhase.selector, Vault.Phase.Exercisable, Vault.Phase.Idle));
        vault.rollClose();

        // A stranger settles; the vault is still halted, and that does not matter.
        vm.prank(makeAddr("stranger"));
        vault.settleQueue();
        assertTrue(vault.writesHalted(), "still halted");
        assertEq(vault.epochId(), 2, "epoch 1 settled");

        (uint256 assets, uint256 usdgOut) = _complete(alice);
        assertEq(assets, 10e18, "alice gets her whole position back");
        assertEq(usdgOut, 0, "no USDG ever arrived");
        assertEq(nvda.balanceOf(alice), aliceStart, "measured as a balance delta, to the wei");
        assertEq(vault.totalSupply(), 0, "and the vault is empty");
    }

    /// @dev The second PoC: the sole holder with half a lot. Nothing can ever be written, so the
    ///      queue could never settle through a roll.
    function test_settleQueue_freesTheLastHolderBelowOneLot() public {
        uint256 start = nvda.balanceOf(carol);
        _deposit(carol, 0.5e18);
        _queue(carol, 0.5e18);

        uint256 id = optionIds[RUNG_PICK];
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Policy.ContractsAboveUtilization.selector, 1, 0));
        vault.rollOpen(id, 1);

        vault.settleQueue();
        (uint256 assets,) = _complete(carol);
        assertEq(assets, 0.5e18, "carol's half lot comes back");
        assertEq(nvda.balanceOf(carol), start, "to the wei");
    }

    /// @dev USDG that reaches the vault while it is flat (a late settlement from elsewhere, or a
    ///      donation) is folded into the index by the checkpoint before settlement, so the
    ///      escrow's share of it leaves with the queuer instead of staying behind.
    function test_settleQueue_paysTheEscrowsAccrualToTheQueuer() public {
        _deposit(alice, 10e18);
        _deposit(bob, 30e18);
        _queue(alice, 10e18);
        usdg.mint(address(vault), 4_000_000); // $4.00 fee-bearing inflow, $3.80 net of 5%

        vault.settleQueue();
        (uint256 assets, uint256 usdgOut) = _complete(alice);
        assertEq(assets, 10e18, "asset leg");
        assertEq(usdgOut, 950_000, "a quarter of the $3.80 net: the escrow held 10 of 40 shares");
        assertEq(vault.claimableUsdg(bob), 2_850_000, "and bob keeps exactly his three quarters");
    }

    /// @dev Settling a flat queue must pay what an instant redemption of the same shares pays at
    ///      the same moment, so nobody gains by queueing instead of redeeming or by forcing a
    ///      settlement on somebody else. Awkward numbers: an assigned week leaves 28 - 3 = 25
    ///      NVDA against a 28-share supply.
    function test_settleQueue_paysWhatAnInstantRedeemWouldHave() public {
        _deposit(alice, 7e18);
        _deposit(bob, 21e18);
        uint256 oid = _openAndFill(5);
        _closeCycleAssigned(oid, 3);
        _nextCycle();

        uint256 q = 3_333_333_333_333_333_333;
        uint256 instant = vault.previewRedeem(q);
        uint256 bobBefore = vault.convertToAssets(vault.balanceOf(bob));
        _queue(alice, q);
        vault.settleQueue();

        (uint256 assets,) = _complete(alice);
        assertEq(assets, instant, "the queue pays the instant price exactly, virtual share included");
        assertApproxEqAbs(
            vault.convertToAssets(vault.balanceOf(bob)), bobBefore, 1, "and moves no value onto or off the stayers"
        );
    }

    /// @dev Review round 2 PoC. `_settleQueue` used to pay `idle * q / supply` with no virtual
    ///      share, and `settleQueue` made that an atomic exit while flat (halted or not). bob seeds
    ///      3 wei into the empty vault and donates 20 NVDA; alice's 9.8 rounds down to ONE share;
    ///      bob queues and settles out. Unfixed he took 22.35 NVDA for 20 NVDA + 3 wei, a 2.35
    ///      profit carved out of alice. Now the queue prices exactly like instant redeem, so the
    ///      donation is a loss to him again (the grief stays bounded, as
    ///      `test_inflationGriefIsBoundedByTheDonation` expects) and alice's queue exit is her
    ///      instant exit.
    function test_settleQueue_doesNotMakeDonationInflationProfitable() public {
        vm.prank(guardian);
        vault.haltWrites();
        uint256 bobStart = nvda.balanceOf(bob);
        _deposit(bob, 3);
        vm.prank(bob);
        nvda.transfer(address(vault), 20e18);
        assertEq(_deposit(alice, 9.8e18), 1, "alice rounds down to one share");

        uint256 instant = vault.previewRedeem(3);
        _queue(bob, 3);
        vault.settleQueue();
        (uint256 got,) = _complete(bob);
        assertEq(got, instant, "the queue exit pays the instant price");
        assertEq(got, 17.88e18 + 2, "3 * (29.8e18 + 3 + 1) / (4 + 1)");
        assertLt(nvda.balanceOf(bob), bobStart, "the donation is a loss, not a profit");

        instant = vault.previewRedeem(1);
        _queue(alice, 1);
        vault.settleQueue();
        (got,) = _complete(alice);
        assertEq(got, instant, "and alice's queue exit is her instant exit");
    }

    function test_settleQueue_revertsOutsideIdleAndWhenNothingIsQueued() public {
        vm.expectRevert(Vault.NothingQueued.selector);
        vault.settleQueue();

        _deposit(alice, 10e18);
        _rollOpen(5);
        _queue(alice, 1e18);
        vm.expectRevert(abi.encodeWithSelector(Vault.WrongPhase.selector, Vault.Phase.Idle, Vault.Phase.Listed));
        vault.settleQueue();

        _warpToExercise();
        vault.lockBook();
        vm.expectRevert(abi.encodeWithSelector(Vault.WrongPhase.selector, Vault.Phase.Idle, Vault.Phase.Exercisable));
        vault.settleQueue();
    }

    /// @dev Pure bookkeeping, so an issuer freeze cannot stop it; only the payout waits.
    function test_settleQueue_worksUnderAnIssuerFreeze() public {
        _deposit(alice, 10e18);
        _queue(alice, 4e18);
        nvda.setFrozen(true);

        vault.settleQueue();
        vm.prank(alice);
        vm.expectRevert(MockStockToken.IssuerFreeze.selector);
        vault.completeRedeem(alice);

        nvda.setFrozen(false);
        (uint256 assets,) = _complete(alice);
        assertEq(assets, 4e18, "paid once the freeze lifts");
    }
}
