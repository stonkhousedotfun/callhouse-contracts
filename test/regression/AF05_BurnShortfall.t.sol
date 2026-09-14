// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseTest} from "../Base.t.sol";
import {Vault} from "../../src/Vault.sol";

/// @title AF-05 regression: an `adminBurn` shortfall closes deposits and is shared pro rata by the reserve
/// @notice Ported from the audit PoC `PoC_adminburn_shortfall_hidden_by_saturating_nav.t.sol`
///         (AUDIT-FINDINGS F-05, Low). FIXED FORM (stage C-04, decisions D6 and D8): `totalAssets =
///         max(balance + locked - reserved, 0)`, one `_depositRefused()` predicate closes deposits
///         (`DepositsClosed`, `maxDeposit == 0`) whenever `balanceOf(vault) < reservedAssets`, and every
///         uncollected reserved claimant takes the same `balance / reservedAssets` fraction of what is
///         booked to them. A depositor who arrives after the burn loses nothing to it.
///
///         FOLLOW-UP (the share-price floor). A burn that takes the whole book leaves shares outstanding over
///         a NAV of zero with the reserve gate satisfied, and the vault used to sell that book to the next
///         depositor at one wei a share; two such deposits put the supply near 1e58 and `shares x
///         accUsdgPerShare` past uint256 in the queue's maths. The same predicate now also refuses deposits
///         while `totalSupply() > totalAssets() x MAX_SHARES_PER_ASSET` (1e6), and the queue and index maths
///         no longer need `shares x index` to fit in 256 bits. The three `test_deadBook_*` /
///         `test_queueMaths_*` cases below are that regression.
/// @dev The live Stock Token's `adminBurn(from, amount)` is a BARE `_burn` (ADMIN_BURNER_ROLE, one EOA)
///      with no pause and no blocklist modifier; {MockStockToken.adminBurn} mirrors it.
contract AF05_BurnShortfall is BaseTest {
    using stdStorage for StdStorage;

    address internal dave = makeAddr("dave");

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        vault.setDepositCap(1_000e18);

        _fund(alice, 20e18, 0);
        _fund(bob, 20e18, 0);
        _fund(carol, 20e18, 0);
        _fund(dave, 100e18, 0);
    }

    function _queue(address who, uint256 shares) internal {
        vm.prank(who);
        vault.queueRedeem(shares);
    }

    function _complete(address who) internal returns (uint256 assets) {
        vm.prank(who);
        (assets,) = vault.completeRedeem(who);
    }

    function _assertDepositsClosed(address who, string memory why) internal {
        assertEq(vault.maxDeposit(who), 0, string.concat(why, ": maxDeposit must quote zero"));
        assertEq(vault.maxMint(who), 0, string.concat(why, ": maxMint must quote zero"));
        vm.startPrank(who);
        nvda.approve(address(vault), 1e18);
        vm.expectRevert(Vault.DepositsClosed.selector);
        vault.deposit(1e18, who);
        vm.expectRevert(Vault.DepositsClosed.selector);
        vault.mint(1e18, who);
        vm.stopPrank();
    }

    /// Idle: a burn below `reservedAssets` closes deposits, the two reserved claimants share the balance
    /// pro rata, and the depositor who arrives afterwards gets exactly what he put in back.
    function test_idle_adminBurnShortfallIsSharedByTheReserveAndClosesDeposits() public {
        _deposit(alice, 50e18);
        _deposit(bob, 50e18);
        _deposit(carol, 50e18);

        _queue(alice, 50e18);
        vault.settleQueue();
        _queue(bob, 25e18);
        vault.settleQueue();

        assertEq(vault.reservedAssets(), 75e18, "reserved");
        assertEq(nvda.balanceOf(address(vault)), 150e18, "balance");
        assertEq(vault.totalSupply(), 75e18, "supply: bob 25 + carol 50");

        // Issuer seizure of 100 NVDA from the vault.
        nvda.adminBurn(address(vault), 100e18);
        assertEq(nvda.balanceOf(address(vault)), 50e18);
        assertLt(nvda.balanceOf(address(vault)), vault.reservedAssets(), "balance < reserved: the reserve is unbacked");

        // FIXED: NAV is honestly zero (50 + 0 - 75 < 0) and deposits are shut, not quoted at the cap.
        assertEq(vault.totalAssets(), 0, "NAV reads zero");
        _assertDepositsClosed(dave, "unbacked reserve");
        assertTrue(vault.canRedeemInstantly(), "the instant path is open, but a share is worth nothing");
        vm.prank(carol);
        vm.expectRevert(Vault.ZeroAssets.selector);
        vault.redeem(50e18, carol, carol);

        // Both reserved claimants take the same 50/75 fraction, whichever order they collect in.
        (uint256 aliceDue,) = vault.previewCompleteRedeem(alice);
        (uint256 bobDue,) = vault.previewCompleteRedeem(bob);
        uint256 balance = nvda.balanceOf(address(vault)); // 50e18 over a 75e18 reserve
        assertEq(aliceDue, (50e18 * balance) / 75e18, "alice quoted two thirds");
        assertEq(bobDue, (25e18 * balance) / 75e18, "bob quoted two thirds");

        vm.expectEmit(true, false, false, true, address(vault));
        emit Vault.ReserveHaircut(alice, 50e18, aliceDue);
        assertEq(_complete(alice), aliceDue, "alice paid the quoted haircut");
        // The fraction survives alice's collection (16.67e18 of the 25e18 booked); the last claimant
        // takes exactly what is left, so floor rounding never strands a base unit in the reserve.
        (uint256 bobDueAfter,) = vault.previewCompleteRedeem(bob);
        assertApproxEqAbs(bobDueAfter, bobDue, 1, "bob's fraction is unchanged by alice collecting first");
        assertEq(bobDueAfter, 50e18 - aliceDue, "bob, last, is quoted exactly what is left");
        assertEq(_complete(bob), bobDueAfter, "bob paid the quote");
        assertEq(vault.reservedAssets(), 0, "reserve fully collected");
        assertEq(nvda.balanceOf(address(vault)), 0, "the whole balance went to the reserve, no dust");

        // The reserve is collected, but the book is DEAD: bob's 25e18 and carol's 50e18 shares are outstanding
        // over a NAV of zero, so the share-price floor keeps deposits shut (reason 6 of `_depositRefused`,
        // AF-05 follow-up). Before the floor the vault reopened here and sold dave 100e18 x 75e18 shares for
        // his 100 NVDA.
        assertEq(vault.totalSupply(), 75e18, "bob 25 + carol 50 outstanding");
        assertEq(vault.convertToAssets(vault.balanceOf(carol)), 0, "carol's shares are worth zero");
        _assertDepositsClosed(dave, "dead book: shares outstanding over a zero NAV");

        // The book is alive again the moment it is worth a millionth of a base unit a share: with 75e18
        // shares outstanding, 7.5e13 base units of NVDA. One less and it is still dead.
        nvda.mint(address(vault), 7.5e13 - 1);
        _assertDepositsClosed(dave, "one base unit below the floor");
        nvda.mint(address(vault), 1);
        assertEq(vault.maxDeposit(dave), 1_000e18 - 7.5e13, "at the floor deposits reopen, cap less NAV");
        uint256 daveShares = _deposit(dave, 100e18);

        // dave exits instantly and has lost nothing to a burn that happened before he arrived.
        vm.prank(dave);
        uint256 daveOut = vault.redeem(daveShares, dave, dave);
        assertApproxEqAbs(daveOut, 100e18, 2, "dave recovers his full deposit");
    }

    /// Listed: NAV counts the locked collateral and subtracts the whole reserve, deposits shut while the
    /// balance is below the reserve, and a claimant who collects during the shortfall takes the haircut.
    function test_listed_shortfallIsHonestlyPricedAndClosesDeposits() public {
        _deposit(alice, 50e18);
        _deposit(bob, 50e18);

        _queue(alice, 50e18);
        vault.settleQueue();
        assertEq(vault.reservedAssets(), 50e18);

        _openAndSell(47);
        assertEq(vault.lockedAssets(), 47e18);
        assertEq(nvda.balanceOf(address(vault)), 53e18);

        nvda.adminBurn(address(vault), 20e18); // balance 33 < reserved 50
        // FIXED: NAV reads the true 30 (33 + 47 - 50), not 47.
        assertEq(vault.totalAssets(), 33e18 + 47e18 - 50e18, "NAV reads the true 30e18");
        _assertDepositsClosed(dave, "Listed with an unbacked reserve");

        // alice collects during the shortfall: 50 booked, 33/50 of it paid. The reserve is a claim on
        // the idle balance, so the burn lands on it first; bob's shares keep the 47e18 locked.
        (uint256 aliceDue,) = vault.previewCompleteRedeem(alice);
        assertEq(aliceDue, 33e18, "haircut quoted");
        assertEq(_complete(alice), 33e18, "haircut paid");
        assertEq(vault.reservedAssets(), 0);
        assertEq(nvda.balanceOf(address(vault)), 0);

        // Deposits reopen on the honest book: 47e18 locked, nothing idle, nothing reserved.
        assertEq(vault.totalAssets(), 47e18, "NAV is the locked collateral");
        assertGt(vault.maxDeposit(dave), 0, "deposits reopen");
        uint256 daveShares = _deposit(dave, 47e18);

        // Run the cycle to expiry OTM and close.
        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();
        _rollClose();

        // dave gets back what he put in; the burn was borne before he arrived.
        vm.prank(dave);
        uint256 daveOut = vault.redeem(daveShares, dave, dave);
        assertApproxEqAbs(daveOut, 47e18, 2, "dave's 47 is still worth 47");
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(bob)), 47e18, 2, "bob keeps the locked 47");
    }

    /// Listed, nobody collects: the returning collateral refills the balance above the reserve, deposits
    /// reopen without anyone being haircut, and the reserved claimant is then paid in full. The loss
    /// stays with the live shares, whose NAV read it honestly the whole time.
    function test_listed_returningCollateralRefillsTheReserveAndReopensDeposits() public {
        _deposit(alice, 50e18);
        _deposit(bob, 50e18);
        _queue(alice, 50e18);
        vault.settleQueue();
        _openAndSell(47);

        nvda.adminBurn(address(vault), 20e18); // balance 33 < reserved 50
        _assertDepositsClosed(dave, "before the collateral returns");
        assertEq(vault.totalAssets(), 30e18, "true NAV during the shortfall");

        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();
        _rollClose();

        // 47e18 came back: balance 80 >= reserved 50. No haircut, deposits open, NAV unchanged at 30.
        assertEq(nvda.balanceOf(address(vault)), 80e18);
        assertEq(vault.totalAssets(), 30e18, "NAV did not move on the close");
        assertGt(vault.maxDeposit(dave), 0, "deposits reopen once the reserve is backed again");
        (uint256 aliceDue,) = vault.previewCompleteRedeem(alice);
        assertEq(aliceDue, 50e18, "alice quoted in full");
        assertEq(_complete(alice), 50e18, "alice paid in full");
        assertEq(vault.convertToAssets(vault.balanceOf(bob)), 30e18, "bob's 50 shares are worth the true 30");

        // A depositor now buys in at the honest price and loses nothing.
        uint256 daveShares = _deposit(dave, 30e18);
        vm.prank(dave);
        assertApproxEqAbs(vault.redeem(daveShares, dave, dave), 30e18, 2, "dave gets his 30 back");
    }

    /// The haircut is order-independent: three reserved claimants collecting in either order all take
    /// the same fraction, and the reserve drains to exactly the balance.
    function testFuzz_haircutFractionIsTheSameForEveryClaimant(uint256 burnSeed, bool bobFirst) public {
        _deposit(alice, 50e18);
        _deposit(bob, 50e18);
        _deposit(carol, 50e18);
        _queue(alice, 50e18);
        _queue(bob, 30e18);
        _queue(carol, 10e18);
        vault.settleQueue();
        assertEq(vault.reservedAssets(), 90e18);

        uint256 burn = bound(burnSeed, 60e18 + 1, 150e18); // leaves the balance below the 90e18 reserve
        nvda.adminBurn(address(vault), burn);
        uint256 bal = 150e18 - burn;
        assertLt(bal, 90e18);
        assertEq(vault.maxDeposit(dave), 0, "deposits shut");

        (uint256 aliceDue,) = vault.previewCompleteRedeem(alice);
        (uint256 bobDue,) = vault.previewCompleteRedeem(bob);
        (uint256 carolDue,) = vault.previewCompleteRedeem(carol);
        assertEq(aliceDue, (50e18 * bal) / 90e18);
        assertEq(bobDue, (30e18 * bal) / 90e18);
        assertEq(carolDue, (10e18 * bal) / 90e18);

        // Each payout is quoted the instant before it is made (that is exact) and compared with the
        // quote taken before anyone collected: the fraction moves by at most one base unit of floor
        // rounding per earlier collection, whichever order people arrive in.
        if (bobFirst) {
            assertEq(_complete(bob), bobDue, "bob first");
            assertApproxEqAbs(_complete(carol), carolDue, 1, "carol second");
            assertApproxEqAbs(_complete(alice), aliceDue, 2, "alice last");
        } else {
            assertEq(_complete(alice), aliceDue, "alice first");
            assertApproxEqAbs(_complete(bob), bobDue, 1, "bob second");
            assertApproxEqAbs(_complete(carol), carolDue, 2, "carol last");
        }
        assertEq(vault.reservedAssets(), 0, "reserve drained");
        // The last claimant's booked amount IS the remaining reserve, so the haircut pays exactly the
        // remaining balance: no base unit is stranded.
        assertEq(nvda.balanceOf(address(vault)), 0, "the reserve drained to exactly the balance");
        // bob's 20e18 and carol's 40e18 are still outstanding over a NAV of zero: a dead book, and the
        // share-price floor sells no new shares on it (AF-05 follow-up).
        assertEq(vault.totalSupply(), 60e18, "shares outstanding");
        assertEq(vault.maxDeposit(dave), 0, "a dead book sells no new shares");
    }

    /*//////////////////////////////////////////////////////////////
                AF-05 FOLLOW-UP: THE SHARE-PRICE FLOOR
    //////////////////////////////////////////////////////////////*/

    /// A burn that takes the whole idle balance leaves a DEAD BOOK: shares outstanding over a NAV of zero,
    /// with `reservedAssets == 0` so the F-05 reserve gate is satisfied. Before the floor a deposit into it
    /// minted `assets x (supply + 1)` shares at one wei each, and two of those put the supply near 1e58,
    /// past what `shares x accUsdgPerShare` (1e27-scaled) can hold in the queue's per-entry maths. Now
    /// `maxDeposit`/`maxMint` quote 0 and `deposit`/`mint` revert `DepositsClosed`, with the boundary at
    /// exactly `totalSupply() == totalAssets() x MAX_SHARES_PER_ASSET` (1e6 shares per base unit).
    function test_deadBook_sharePriceFloorClosesDepositsAtExactlyOneMillionSharesPerBaseUnit() public {
        _deposit(alice, 50e18);
        _deposit(bob, 50e18);
        assertEq(vault.totalSupply(), 100e18);

        nvda.adminBurn(address(vault), 100e18);
        assertEq(vault.totalAssets(), 0, "NAV zero");
        assertEq(vault.totalSupply(), 100e18, "shares outstanding");
        assertEq(vault.reservedAssets(), 0, "nothing reserved: the F-05 reserve gate is not what closes this");
        assertTrue(vault.canRedeemInstantly(), "the instant path is open, and a share is worth nothing");
        _assertDepositsClosed(dave, "dead book");

        // The quote still prices at the collapsed ratio; it is the gate, not the price, that refuses.
        assertEq(vault.previewDeposit(1), 100e18 + 1, "one wei would buy more than the whole supply again");

        // 100e18 shares need 1e14 base units of NAV. One short, still dead; at it, open.
        nvda.mint(address(vault), 1e14 - 1);
        assertEq(vault.totalSupply(), vault.totalAssets() * 1e6 + 1e6, "one base unit below the floor");
        _assertDepositsClosed(dave, "below the floor");
        nvda.mint(address(vault), 1);
        assertEq(vault.totalSupply(), vault.totalAssets() * 1e6, "exactly at the floor");
        assertEq(vault.maxDeposit(dave), 1_000e18 - 1e14, "at the floor: open, cap less NAV");
        uint256 shares = _deposit(dave, 1e18);
        uint256 floorRatioShares = (uint256(1e18) * (100e18 + 1)) / (1e14 + 1);
        assertEq(shares, floorRatioShares, "priced at the floor ratio");
        assertGt(vault.maxDeposit(dave), 0, "a deposit at the floor raises the price and stays open");
    }

    /// A dead book is wound down through the queue, not re-inflated: an account in escrow when the issuer
    /// strikes still settles and completes (zero NVDA, its USDG), an account that queues afterwards moves
    /// numbers only, and the book is reborn at par once its last share is gone.
    function test_deadBook_queueStillSettlesAndCompletesAndTheBookIsRebornOnceEmpty() public {
        _deposit(alice, 50e18);
        _deposit(bob, 50e18);
        _fullCycleOtm(10, _okUnitPrice()); // 19 USDG of premium, 18.05 net, indexed at the close
        assertEq(vault.claimableUsdg(bob), 9_025_000, "bob's half of the week");

        _queue(bob, 50e18); // bob is in escrow when the issuer strikes
        nvda.adminBurn(address(vault), 100e18);
        assertEq(vault.totalAssets(), 0, "NAV zero");
        _assertDepositsClosed(dave, "dead book with a live queue");

        // 1 USDG arriving now is indexed by settleQueue's checkpoint (0.95 net over 100e18 shares); the
        // escrow's half belongs to bob's entry, alice's half to her claimable balance.
        usdg.mint(address(vault), 1_000_000);
        vault.settleQueue();
        (uint256 sharesR, uint256 assetsR, uint256 usdgR) = vault.epochs(1);
        assertEq(sharesR, 50e18, "bob's entry");
        assertEq(assetsR, 0, "the asset leg of a dead book is nothing");
        assertEq(usdgR, 475_000, "the escrow's half of the 0.95 net");

        // alice can still queue (numbers only), and bob still completes: zero NVDA and his 0.475 USDG.
        _queue(alice, 50e18);
        (uint256 bobDueAssets, uint256 bobDueUsdg) = vault.previewCompleteRedeem(bob);
        assertEq(bobDueAssets, 0, "no NVDA to pay");
        assertEq(bobDueUsdg, 475_000, "his USDG");
        vm.prank(bob);
        (uint256 paidAssets, uint256 paidUsdg) = vault.completeRedeem(bob);
        assertEq(paidAssets, 0, "no NVDA paid");
        assertEq(paidUsdg, 475_000, "USDG paid");
        vm.prank(bob);
        assertEq(vault.claimUsdg(), 9_025_000, "the week's premium settled at queue time is still his");

        // Still dead, still shut: alice's escrow is the whole supply.
        assertEq(vault.totalSupply(), 50e18, "alice's shares, in escrow");
        _assertDepositsClosed(dave, "still dead");
        vault.settleQueue();
        vm.prank(alice);
        (paidAssets, paidUsdg) = vault.completeRedeem(alice);
        assertEq(paidAssets, 0, "nothing to pay alice in NVDA");
        assertEq(paidUsdg, 0, "nothing indexed while only alice was in escrow");

        // No share outstanding: the floor no longer holds (nothing is sold below nothing) and the book is
        // reborn at par for whoever comes next.
        assertEq(vault.totalSupply(), 0, "empty book");
        assertEq(vault.maxDeposit(dave), 1_000e18, "deposits reopen on the empty book");
        assertEq(_deposit(dave, 100e18), 100e18, "dave is priced at par");
    }

    /// The arithmetic half of the follow-up. The queue's per-entry maths used to form `shares x accUsdgPerShare`
    /// in 256 bits (the reward debt at `queueRedeem`, `shares x epochIndex - debt` at settlement), and so did
    /// `Distributor._pending` inside every transfer, mint and burn. The share-price floor keeps a real vault far
    /// from the bound, so the index is PLANTED here at 2^250: with 50e18 shares the old products are ~9e94 and
    /// every one of those calls reverted on overflow for the account. Now each entry is paid exactly its own
    /// index growth to the base unit, the planted part cancelling out of `shares x epochIndex - debt`.
    function test_queueMaths_doNotNeedShareTimesIndexToFit256Bits() public {
        _deposit(alice, 50e18);
        _deposit(bob, 50e18);
        uint256 planted = 1 << 250;
        stdstore.target(address(vault)).sig("accUsdgPerShare()").checked_write(planted);
        assertEq(vault.accUsdgPerShare(), planted, "index planted");
        // `bal x delta` is 50e18 x 2^250 ~ 9e94 and used to revert here; the 512-bit floor is ~9e67.
        assertEq(vault.claimableUsdg(alice), Math.mulDiv(50e18, planted, 1e27), "pending is the 512-bit floor");

        // alice queues at the planted index: her debt is 50e18 x 2^250, kept as quotient and remainder.
        _queue(alice, 50e18);
        assertEq(vault.balanceOf(address(vault)), 50e18, "escrowed");

        // Tranche 1 is indexed while only alice is in escrow: 1 USDG donated, checkpointed by carol's deposit.
        usdg.mint(address(vault), 1_000_000);
        _deposit(carol, 10e18);
        uint256 idx1 = vault.accUsdgPerShare();
        assertGt(idx1, planted, "tranche 1 indexed");
        // bob queues after it, so tranche 1 is alice's alone; tranche 2 lands while both sit in escrow.
        _queue(bob, 50e18);
        usdg.mint(address(vault), 2_000_000);
        vault.settleQueue(); // checkpoints tranche 2, then closes the epoch
        uint256 idxE = vault.accUsdgPerShare();
        (uint256 sharesR,, uint256 pot) = vault.epochs(1);
        assertEq(sharesR, 100e18, "both entries");
        assertGt(pot, 0, "the escrow earned both tranches");

        // alice, not last: exactly floor(50e18 x (idxE - planted) / 1e27), capped at the pot.
        uint256 aliceOwn = Math.mulDiv(50e18, idxE - planted, 1e27);
        (, uint256 aliceQuoted) = vault.previewCompleteRedeem(alice);
        assertEq(aliceQuoted, aliceOwn < pot ? aliceOwn : pot, "alice is quoted her own index growth");
        vm.prank(alice);
        (, uint256 aliceGot) = vault.completeRedeem(alice);
        assertEq(aliceGot, aliceQuoted, "and paid it");

        // bob, last: the rest of the pot, which is his own growth within the escrow's floor rounding.
        uint256 bobOwn = Math.mulDiv(50e18, idxE - idx1, 1e27);
        vm.prank(bob);
        (, uint256 bobGot) = vault.completeRedeem(bob);
        assertEq(bobGot, pot - aliceGot, "the last claimant takes the remainder");
        assertApproxEqAbs(bobGot, bobOwn, 3, "which is his own growth within rounding");
        assertEq(vault.usdgReservedForQueue(), 0, "nothing stranded");
    }
}
