// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {Vault} from "../../src/Vault.sol";
import {Distributor} from "../../src/Distributor.sol";
import {OrderComponents} from "../../src/interfaces/ISeaport.sol";

/// @notice USDG accrual and claiming: the half of the product that actually pays people.
/// @dev The property under test throughout is the one the whole design rests on — premium is
///      a separate USDG claim, never a bump in the share price. Every number here is asserted
///      exactly; a "roughly right" premium split is a wrong premium split.
///
///      Reference numbers, used over and over below. Ten contracts at $2.00:
///        gross           20.000000 USDG   (buyer pays)
///        Overcall 5%      1.000000 USDG   (consideration[1], rounded PER CONTRACT)
///        to the vault    19.000000 USDG   (consideration[0])
///        protocol 5%      0.950000 USDG   (of the premium harvested, i.e. of the 19)
///        to holders      18.050000 USDG
///
///      Every week in this file is out of the money, so the harvest is all premium and the
///      whole 19.000000 is fee-bearing. (Strike proceeds on an assigned week are fee-free;
///      that path is covered in VaultAssignment.t.sol.)
///
///      18.050000 does NOT divide by three. On the 20e18 / 10e18 split used below the index
///      floors to 601_666_666_666_666, alice gets 12.033333, bob 6.016666, and one base unit
///      is carried as `usdgDust` into the next distribution.
contract VaultDistributorTest is BaseTest {
    /// @dev Mirrors Distributor.ACC_PRECISION, which is internal.
    uint256 internal constant ACC_PRECISION = 1e27;

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Roll the fixture on to a fresh weekly cycle. The registry's writing window closes
    ///      at the exercise timestamp, so a second cycle needs new option types and new
    ///      timings or `rollOpen` reverts with WritingNotOpen.
    function _newWeek() internal {
        exerciseTs = uint40(block.timestamp + 6 days);
        expiryTs = uint40(block.timestamp + 7 days);
        _installCycle();
        // A week has passed, so the fixture's feed is now older than MAX_PRICE_AGE. A live
        // keeper would be looking at a fresh round; without this every second roll reverts
        // with StalePrice for reasons that have nothing to do with the accrual under test.
        feed.setUpdatedAt(block.timestamp);
    }

    /// @dev Everything the vault's USDG balance is spoken for: every holder's claim, the
    ///      escrow's claim on behalf of queued redeemers, and what is already fenced off for
    ///      settled epochs.
    function _owedUsdg() internal view returns (uint256) {
        return vault.claimableUsdg(alice) + vault.claimableUsdg(bob) + vault.claimableUsdg(carol)
            + vault.claimableUsdg(buyer) + vault.claimableUsdg(address(vault)) + vault.usdgReservedForQueue();
    }

    /// @dev The solvency invariant. If this ever fails somebody's claim is unpayable.
    function _assertUsdgInvariant(string memory tag) internal view {
        assertGe(usdg.balanceOf(address(vault)), _owedUsdg(), tag);
    }

    /*//////////////////////////////////////////////////////////////
                          PRO-RATA DISTRIBUTION
    //////////////////////////////////////////////////////////////*/

    /// @dev Two holders with different stakes, one filled week, exact split - including the
    ///      one base unit the reference week cannot split three ways.
    ///
    ///      The arithmetic, by hand:
    ///        net 18_050_000 over a 30e18 supply: 18_050_000 * 1e27 / 30e18 = 601_666_666_666_666.67,
    ///          floored to 601_666_666_666_666.
    ///        credited = 601_666_666_666_666 * 30e18 / 1e27 = 18_049_999.99998, floored to 18_049_999,
    ///          so usdgDust = 1.
    ///        alice 20e18 -> 12_033_333 (12_033_333.33 floored), bob 10e18 -> 6_016_666 (6_016_666.67
    ///          floored); 12_033_333 + 6_016_666 == 18_049_999, exactly what was credited.
    function test_filledWeekSplitsProRata() public {
        _deposit(alice, 20e18);
        _deposit(bob, 10e18);

        assertEq(vault.accUsdgPerShare(), 0, "index starts flat");
        assertEq(vault.totalUsdgDistributed(), 0, "nothing distributed yet");

        uint256 gross = _fullCycleOtm(10, _okUnitPrice());
        assertEq(gross, 20_000_000, "$2.00 x 10 contracts");

        // 18.050000 USDG over 30 shares, 1e27-scaled, floored.
        assertEq(vault.accUsdgPerShare(), 601_666_666_666_666, "index credited");
        assertEq(vault.totalUsdgDistributed(), 18_049_999, "net of the 5% protocol fee, floored to the index");
        assertEq(vault.usdgDust(), 1, "18.05 USDG does not divide by three: one base unit carried");
        assertEq(vault.totalUsdgDistributed() + vault.usdgDust(), 18_050_000, "the whole net is credited or carried");

        assertEq(vault.claimableUsdg(alice), 12_033_333, "alice holds two thirds");
        assertEq(vault.claimableUsdg(bob), 6_016_666, "bob holds one third");
        assertEq(
            vault.claimableUsdg(alice) + vault.claimableUsdg(bob),
            vault.totalUsdgDistributed(),
            "the two claims are exactly what was credited"
        );

        _assertUsdgInvariant("after a filled week");
    }

    /*//////////////////////////////////////////////////////////////
                                 CLAIM
    //////////////////////////////////////////////////////////////*/

    function test_claimUsdgPaysAndZeroes() public {
        _deposit(alice, 20e18);
        _fullCycleOtm(10, _okUnitPrice());

        uint256 owed = vault.claimableUsdg(alice);
        // 18.050000 over 20e18 shares indexes exactly (902_500_000_000_000), so no dust.
        assertEq(owed, 18_050_000, "sole holder takes the whole net");

        vm.prank(alice);
        uint256 paid = vault.claimUsdg();

        assertEq(paid, owed, "claim returns what it paid");
        assertEq(usdg.balanceOf(alice), owed, "USDG reached alice");
        assertEq(vault.claimableUsdg(alice), 0, "claim zeroed");
        assertEq(vault.totalUsdgClaimed(), owed, "lifetime claimed");
        assertEq(vault.usdgOwed(), 0, "vault owes nothing more");
        assertEq(usdg.balanceOf(address(vault)), 0, "the vault kept nothing back");
    }

    /// @dev Claiming twice must revert rather than quietly pay zero: a silent no-op would let
    ///      a UI show a successful claim that moved no money.
    function test_secondClaimReverts() public {
        _deposit(alice, 20e18);
        _fullCycleOtm(10, _okUnitPrice());

        vm.prank(alice);
        vault.claimUsdg();

        vm.expectRevert(Distributor.NothingToClaim.selector);
        vm.prank(alice);
        vault.claimUsdg();
    }

    function test_claimWithNothingAccruedReverts() public {
        _deposit(alice, 20e18);

        vm.expectRevert(Distributor.NothingToClaim.selector);
        vm.prank(alice);
        vault.claimUsdg();
    }

    function test_claimUsdgToSendsToThirdParty() public {
        _deposit(alice, 20e18);
        _fullCycleOtm(10, _okUnitPrice());

        vm.prank(alice);
        uint256 paid = vault.claimUsdgTo(carol);

        assertEq(paid, 18_050_000, "amount");
        assertEq(usdg.balanceOf(carol), 18_050_000, "carol received it");
        assertEq(usdg.balanceOf(alice), 0, "alice was only the owner, not the recipient");
        assertEq(vault.claimableUsdg(alice), 0, "alice's claim is spent");
        assertEq(vault.claimableUsdg(carol), 0, "carol holds no shares, so accrues nothing");
    }

    function test_claimUsdgToZeroAddressReverts() public {
        _deposit(alice, 20e18);
        _fullCycleOtm(10, _okUnitPrice());

        vm.expectRevert(Distributor.ZeroAddress.selector);
        vm.prank(alice);
        vault.claimUsdgTo(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                    USDG IS NOT PART OF THE SHARE PRICE
    //////////////////////////////////////////////////////////////*/

    /// @dev THE honesty property. TECHSPEC 4.2 forbids marking the short to market, and
    ///      folding premium into `totalAssets` would be the same dishonesty wearing a
    ///      different coat: the share price would jump the instant a premium landed, and a
    ///      depositor who arrived a block later would buy that jump at par. So: a harvest
    ///      must move `claimableUsdg` and nothing else.
    function test_harvestDoesNotMoveTheSharePrice() public {
        _deposit(alice, 20e18);
        _deposit(bob, 10e18);

        uint256 assetsBefore = vault.totalAssets();
        uint256 perShareBefore = vault.convertToAssets(1e18);
        uint256 sharesPerAssetBefore = vault.convertToShares(1e18);
        uint256 supplyBefore = vault.totalSupply();

        _fullCycleOtm(10, _okUnitPrice());

        assertGt(usdg.balanceOf(address(vault)), 0, "the vault really is holding USDG now");
        // Two thirds of 18.050000, floored: 12.033333.
        assertEq(vault.claimableUsdg(alice), 12_033_333, "premium landed as a claim");

        assertEq(vault.totalAssets(), assetsBefore, "totalAssets ignores USDG");
        assertEq(vault.convertToAssets(1e18), perShareBefore, "share price unchanged by the harvest");
        assertEq(vault.convertToShares(1e18), sharesPerAssetBefore, "and unchanged in the other direction");
        assertEq(vault.totalSupply(), supplyBefore, "no shares minted by the harvest");

        // Claiming must not move it either: the USDG was never in the price to begin with.
        vm.prank(alice);
        vault.claimUsdg();
        assertEq(vault.totalAssets(), assetsBefore, "totalAssets unchanged by a claim");
        assertEq(vault.convertToAssets(1e18), perShareBefore, "share price unchanged by a claim");
    }

    /*//////////////////////////////////////////////////////////////
                          SETTLE ON TRANSFER
    //////////////////////////////////////////////////////////////*/

    /// @dev Whoever held the shares when the premium landed keeps it. This is the hazard the
    ///      `_update` hook exists for: without settling both sides of a transfer, alice's
    ///      earned week would walk out of the door attached to the shares.
    function test_transferKeepsTheEarnedWeekWithTheSeller() public {
        _deposit(alice, 20e18);

        // Week one: alice is the only holder, so the whole net is hers.
        _fullCycleOtm(10, _okUnitPrice());
        assertEq(vault.claimableUsdg(alice), 18_050_000, "week one is alice's");
        assertEq(vault.claimableUsdg(bob), 0, "bob holds nothing yet");

        vm.prank(alice);
        vault.transfer(bob, 20e18);

        assertEq(vault.balanceOf(alice), 0, "alice sold out");
        assertEq(vault.balanceOf(bob), 20e18, "bob holds the shares");
        assertEq(vault.claimableUsdg(alice), 18_050_000, "alice keeps the week she sat through");
        assertEq(vault.claimableUsdg(bob), 0, "bob inherits shares, not accrued premium");

        // Week two: $3.00 x 10 => Overcall 0.150000 per contract, 28.500000 to the vault,
        // 1.425000 fee (5% of 28.5), 27.075000 net - which indexes exactly over 20e18 shares.
        _newWeek();
        _fullCycleOtm(10, 3_000_000);

        assertEq(vault.claimableUsdg(bob), 27_075_000, "bob earns the week he actually held");
        assertEq(vault.claimableUsdg(alice), 18_050_000, "alice earns nothing after selling");

        // Both can be paid in full, at the same time.
        vm.prank(alice);
        vault.claimUsdg();
        vm.prank(bob);
        vault.claimUsdg();
        assertEq(usdg.balanceOf(alice), 18_050_000, "alice paid");
        assertEq(usdg.balanceOf(bob), 27_075_000, "bob paid");
        assertEq(usdg.balanceOf(address(vault)), 0, "nothing stranded");
    }

    /// @dev A depositor who arrives after the money landed must not dilute the people who
    ///      were there for it.
    function test_lateDepositorEarnsNothingFromTheHarvestBeforeIt() public {
        _deposit(alice, 20e18);
        _fullCycleOtm(10, _okUnitPrice());
        assertEq(vault.claimableUsdg(alice), 18_050_000, "week one is alice's");

        _deposit(carol, 10e18);
        assertEq(vault.claimableUsdg(carol), 0, "carol bought in after the premium landed");
        assertEq(vault.claimableUsdg(alice), 18_050_000, "and took nothing from alice");

        // She does earn the next one, pro-rata on a 30e18 supply: 18.050000 floors to an index
        // delta of 601_666_666_666_666, so carol 10e18 -> 6.016666 and alice 20e18 -> 12.033333
        // (floored once over her combined delta: 30_083_333.33 -> 30_083_333).
        _newWeek();
        _fullCycleOtm(10, _okUnitPrice());
        assertEq(vault.claimableUsdg(carol), 6_016_666, "one third of week two");
        assertEq(vault.claimableUsdg(alice), 30_083_333, "week one plus two thirds of week two");
    }

    /*//////////////////////////////////////////////////////////////
                             PROTOCOL FEE
    //////////////////////////////////////////////////////////////*/

    /// @dev Fee is 5% of the premium the VAULT harvested, not of what the buyer paid: Overcall's
    ///      5% never touches the vault, so charging on it would be charging on money we never
    ///      had. This week is out of the money, so all 19.000000 harvested is premium.
    function test_protocolFeeIsExactlyFivePercentAndLandsAtFeeSafe() public {
        _deposit(alice, 20e18);

        uint256 optionId = _rollOpen(10);
        OrderComponents memory c = _approveListing(optionId, 10, _okUnitPrice());
        _fill(c, 10);

        (uint256 toVault, uint256 toOvercall, uint256 gross) = _splitPremium(_okUnitPrice(), 10);
        assertEq(gross, 20_000_000, "buyer paid");
        assertEq(toOvercall, 1_000_000, "Overcall's 5%");
        assertEq(usdg.balanceOf(overcallFee), toOvercall, "Overcall was paid in the same fill");
        assertEq(usdg.balanceOf(address(vault)), toVault, "the vault received 95% of gross");

        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();

        vm.expectEmit(true, false, false, true, address(vault));
        // 19_000_000 * 500 / 10_000 = 950_000 exactly; 19_000_000 - 950_000 = 18_050_000.
        emit Vault.Harvest(1, 19_000_000, 950_000, 18_050_000);
        vm.prank(keeper);
        vault.rollClose();

        assertEq(usdg.balanceOf(feeSafe), 950_000, "fee landed at the fee safe");
        assertEq(usdg.balanceOf(feeSafe) * 20, toVault, "exactly a twentieth of the harvest");
        assertEq(vault.totalUsdgDistributed(), 18_050_000, "the other nineteen twentieths went to holders");
    }

    /*//////////////////////////////////////////////////////////////
                           AN UNFILLED WEEK
    //////////////////////////////////////////////////////////////*/

    /// @dev "5% of premium harvested (filled weeks only)". A week nobody bought must cost the
    ///      depositors nothing at all — no fee, no index movement, and above all no revert:
    ///      a vault that cannot close a quiet week is a vault that cannot be unwound.
    function test_unfilledWeekIsFreeAndClosesCleanly() public {
        _deposit(alice, 20e18);
        _deposit(bob, 10e18);

        uint256 assetsBefore = vault.totalAssets();
        uint256 perShareBefore = vault.convertToAssets(1e18);

        uint256 optionId = _rollOpen(10);
        _approveListing(optionId, 10, _okUnitPrice());
        // Nobody fills.

        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();

        vm.expectEmit(true, false, false, true, address(vault));
        emit Vault.Harvest(1, 0, 0, 0);
        vm.prank(keeper);
        vault.rollClose();

        assertEq(_phase(), 0, "back to Idle");
        assertEq(usdg.balanceOf(feeSafe), 0, "an unfilled week is free");
        assertEq(usdg.balanceOf(address(vault)), 0, "no USDG anywhere");
        assertEq(vault.accUsdgPerShare(), 0, "index untouched");
        assertEq(vault.totalUsdgDistributed(), 0, "nothing distributed");
        assertEq(vault.usdgDust(), 0, "no dust invented");
        assertEq(vault.usdgUnallocated(), 0, "nothing left unallocated");
        assertEq(vault.claimableUsdg(alice), 0, "alice earned nothing");
        assertEq(vault.claimableUsdg(bob), 0, "bob earned nothing");

        // The collateral came back whole and the vault is usable again.
        assertEq(vault.totalAssets(), assetsBefore, "collateral returned");
        assertEq(vault.convertToAssets(1e18), perShareBefore, "share price flat");
        assertTrue(vault.canRedeemInstantly(), "flat again");
        assertEq(vault.contractsWritten(), 0, "position closed");

        vm.expectRevert(Distributor.NothingToClaim.selector);
        vm.prank(alice);
        vault.claimUsdg();

        // And the next week still works.
        _newWeek();
        _fullCycleOtm(10, _okUnitPrice());
        // Identical to a single filled week on this split (see test_filledWeekSplitsProRata).
        assertEq(vault.claimableUsdg(alice), 12_033_333, "the quiet week cost nobody anything");
    }

    /*//////////////////////////////////////////////////////////////
                        CONSECUTIVE FILLED WEEKS
    //////////////////////////////////////////////////////////////*/

    function test_twoFilledWeeksAccumulate() public {
        _deposit(alice, 20e18);

        _fullCycleOtm(10, _okUnitPrice());
        // 18_050_000 * 1e27 / 20e18 = 902_500_000_000_000, exactly.
        assertEq(vault.accUsdgPerShare(), 902_500_000_000_000, "week one index");
        assertEq(vault.claimableUsdg(alice), 18_050_000, "week one");

        // Week two: $3.00 x 5 => 14.250000 to the vault, 0.712500 fee, 13.537500 net.
        // 13_537_500 * 1e27 / 20e18 = 676_875_000_000_000; 902_500_000_000_000 + that =
        // 1_579_375_000_000_000. Fees: 950_000 + 712_500 = 1_662_500.
        _newWeek();
        _fullCycleOtm(5, 3_000_000);

        assertEq(vault.accUsdgPerShare(), 1_579_375_000_000_000, "index accumulated, not replaced");
        assertEq(vault.claimableUsdg(alice), 31_587_500, "both weeks");
        assertEq(vault.totalUsdgDistributed(), 31_587_500, "lifetime distributed");
        assertEq(usdg.balanceOf(feeSafe), 1_662_500, "both protocol fees");
        assertEq(vault.usdgDust(), 0, "no dust at these sizes");

        vm.prank(alice);
        assertEq(vault.claimUsdg(), 31_587_500, "one claim collects both weeks");
        assertEq(usdg.balanceOf(address(vault)), 0, "nothing stranded");
    }

    /*//////////////////////////////////////////////////////////////
                              DUST CARRY
    //////////////////////////////////////////////////////////////*/

    /// @dev With a very large share supply the index cannot represent a small premium: one
    ///      unit of `accUsdgPerShare` here is worth 10.000000 USDG in total, so a 4.512500
    ///      net harvest rounds to nothing. That remainder must be CARRIED, not dropped — dropped
    ///      dust is USDG that sits in the vault forever with no owner.
    ///
    ///      Week two is 49 contracts, not a round 50, on purpose. At 50 the week-two net
    ///      (90.250000) indexes to 9 units on its own, so the carried dust would ride along
    ///      without changing what alice is credited and "credited later" would go unproven.
    ///      At 49 the week-two net (88.445000) floors to 8 units on its own, and only the
    ///      carried 4.512500 lifts the pot over the ninth.
    function test_dustIsCarriedAndCreditedLater() public {
        vm.prank(admin);
        vault.setDepositCap(type(uint256).max);

        // 1e34 shares. accUsdgPerShare is 1e27-scaled, so one index unit == 1e7 USDG units.
        nvda.mint(alice, 1e34);
        uint256 shares = _deposit(alice, 1e34);
        assertEq(shares, 1e34, "first deposit is 1:1");

        // Week one: $1.00 x 5 => Overcall 0.050000 per contract, 4.750000 to the vault,
        // 0.237500 fee, 4.512500 net. 4_512_500 * 1e27 / 1e34 = 0.45 of a unit, floored to 0.
        _fullCycleOtm(5, 1_000_000);

        assertEq(vault.accUsdgPerShare(), 0, "too small to index at all");
        assertEq(vault.totalUsdgDistributed(), 0, "nothing could be credited");
        assertEq(vault.claimableUsdg(alice), 0, "so alice cannot claim it yet");
        assertEq(vault.usdgDust(), 4_512_500, "the whole net is carried as dust");
        assertEq(usdg.balanceOf(feeSafe), 237_500, "the fee was still taken on a real harvest");
        assertEq(usdg.balanceOf(address(vault)), 4_512_500, "the money is in the vault, just unindexed");

        // Week two: $2.00 x 49 => 93.100000 to the vault, 4.655000 fee, 88.445000 net.
        // On its own 88.445000 would index to 8 units (80.000000). The pot is 88.445000 + the
        // 4.512500 carried = 92.957500, which indexes to 9 units (90.000000) and carries
        // 2.957500 forward again.
        _newWeek();
        _fullCycleOtm(49, _okUnitPrice());

        assertEq(vault.accUsdgPerShare(), 9, "nine index units - week two alone floors to eight");
        assertEq(vault.totalUsdgDistributed(), 90_000_000, "credited");
        assertEq(vault.claimableUsdg(alice), 90_000_000, "including the unit only the carried week could buy");
        assertEq(vault.usdgDust(), 2_957_500, "the new remainder is carried in turn");
        assertEq(usdg.balanceOf(feeSafe), 237_500 + 4_655_000, "one fee per harvest, none on the carried dust");
        assertEq(
            vault.totalUsdgDistributed() + vault.usdgDust(),
            4_512_500 + 88_445_000,
            "every cent of both nets is either credited or carried - nothing is lost"
        );

        _assertUsdgInvariant("dust carry");

        vm.prank(alice);
        assertEq(vault.claimUsdg(), 90_000_000, "claimable pays out");
        assertEq(usdg.balanceOf(address(vault)), 2_957_500, "exactly the carried dust remains");
        assertEq(vault.usdgDust(), 2_957_500, "and it is still accounted for");
    }

    /*//////////////////////////////////////////////////////////////
                             UNALLOCATED
    //////////////////////////////////////////////////////////////*/

    /// @dev A harvest with no shares outstanding has nobody to credit. It must be parked in
    ///      `usdgUnallocated` and rolled into the next distribution, not burned into the
    ///      vault's balance where `_harvest` would re-harvest it and re-charge the fee.
    ///
    ///      The setup is a direct token donation: collateral with no shares against it. That
    ///      inflates the share price (10 shares for 20e18 of assets below), which is expected
    ///      and is not what this test is about.
    function test_unallocatedUsdgIsCarriedWhenSupplyIsZero() public {
        nvda.mint(address(vault), 2e18 - 1);
        assertEq(vault.totalSupply(), 0, "no shares exist");

        // One contract at $2.00 => 1.900000 to the vault, 0.095000 fee, 1.805000 net.
        _fullCycleOtm(1, _okUnitPrice());

        assertEq(vault.usdgUnallocated(), 1_805_000, "parked, with nobody to credit");
        assertEq(vault.accUsdgPerShare(), 0, "index cannot move with no supply");
        assertEq(vault.totalUsdgDistributed(), 0, "nothing distributed");
        assertEq(vault.usdgDust(), 0, "not dust - a different bucket");
        assertEq(usdg.balanceOf(feeSafe), 95_000, "the fee was taken");
        assertEq(usdg.balanceOf(address(vault)), 1_805_000, "held, not lost");

        uint256 shares = _deposit(alice, 20e18);
        assertEq(shares, 10, "donation inflated the price: 2e18 assets per share");
        assertEq(vault.claimableUsdg(alice), 0, "nothing credited to her on deposit");

        // Week two: $2.00 x 10 => 19.000000 to the vault, 0.950000 fee, 18.050000 net.
        // The orphaned 1.805000 rides along and is NOT charged a fee a second time: had it
        // been, the fee would be 5% of 20.805000 = 1.040250, not 0.950000.
        _newWeek();
        _fullCycleOtm(10, _okUnitPrice());

        assertEq(usdg.balanceOf(feeSafe), 95_000 + 950_000, "fee charged once per harvest only");
        assertEq(vault.usdgUnallocated(), 0, "the parked USDG was spent into the index");
        assertEq(vault.totalUsdgDistributed(), 19_855_000, "18.050000 + the carried 1.805000");
        assertEq(vault.claimableUsdg(alice), 19_855_000, "the first holder picks up the orphaned week");
        assertEq(vault.usdgDust(), 0, "10 shares divide it exactly");

        _assertUsdgInvariant("unallocated carry");

        vm.prank(alice);
        assertEq(vault.claimUsdg(), 19_855_000, "paid in full");
        assertEq(usdg.balanceOf(address(vault)), 0, "nothing lost along the way");
    }

    /*//////////////////////////////////////////////////////////////
                           THE USDG INVARIANT
    //////////////////////////////////////////////////////////////*/

    /// @dev usdg.balanceOf(vault) >= sum(claimable) + usdgReservedForQueue, held through a
    ///      sequence that mixes a mid-cycle queue with two filled weeks. The escrowed shares
    ///      keep earning to settlement and that accrual leaves with the redeemer, so the
    ///      obligation moves from `claimableUsdg` to `usdgReservedForQueue` without the total
    ///      ever exceeding what the vault holds.
    ///
    ///      The inequality is not slack for show. At the reference price the claims come out
    ///      ONE base unit below the balance, and the test pins that unit exactly.
    ///
    ///      The arithmetic, by hand:
    ///        week one: net 18_050_000 over 30e18 floors to an index delta d1 = 601_666_666_666_666,
    ///          credits 18_049_999 and carries 1 as dust. alice 12_033_333, bob 6_016_666.
    ///        bob queues 5e18 mid-cycle: his 6_016_666 is settled at d1.
    ///        week two: pot 18_050_000 + the carried 1 = 18_050_001, which DOES divide by three:
    ///          d2 = 601_666_700_000_000, credited 18_050_001, dust 0. 36_100_000 credited in all.
    ///        alice floors once over d1 + d2: 20e18 * 1_203_333_366_666_666 / 1e27 = 24_066_667.33
    ///          -> 24_066_667.
    ///        bob's unqueued half: 5e18 * d2 / 1e27 = 3_008_333.5 -> 3_008_333, so 9_024_999 in all.
    ///        the escrow's half: the same 3_008_333, reserved for bob.
    ///        24_066_667 + 9_024_999 + 3_008_333 = 36_099_999 against a 36_100_000 balance. Bob's
    ///        accrual floors three times and alice's once; the unit they lose between them was
    ///        indexed (usdgDust is 0) but no account can claim it. It stays in the vault, already
    ///        counted in `usdgAccounted`, so it is never re-harvested or charged a fee.
    function test_usdgInvariantHoldsThroughQueueAndClaims() public {
        _deposit(alice, 20e18);
        _deposit(bob, 10e18);

        _fullCycleOtm(10, _okUnitPrice());
        _assertUsdgInvariant("after week one");
        assertEq(vault.claimableUsdg(alice), 12_033_333, "week one, alice");
        assertEq(vault.claimableUsdg(bob), 6_016_666, "week one, bob");
        assertEq(vault.usdgDust(), 1, "week one, the unit the index cannot split three ways");

        // Week two, with bob committing HALF his position mid-cycle. Half rather than all on
        // purpose: it forces the week's accrual to split across two places at once - the shares
        // still in bob's own balance, and the shares sitting in escrow - and those two halves
        // then have to come back to him by two different routes, `claimUsdg` and
        // `completeRedeem`. Queueing everything would only exercise the escrow route.
        _newWeek();
        uint256 optionId = _rollOpen(10);
        OrderComponents memory c = _approveListing(optionId, 10, _okUnitPrice());
        _fill(c, 10);

        vm.prank(bob);
        vault.queueRedeem(5e18);
        assertEq(vault.balanceOf(address(vault)), 5e18, "shares escrowed on the vault");
        assertEq(vault.claimableUsdg(bob), 6_016_666, "queueing settled bob first, losing him nothing");
        _assertUsdgInvariant("bob queued mid-cycle");

        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();
        _rollClose();

        // Week two's 18.050001 pot was split across the full 30e18 supply, escrow included.
        assertEq(vault.usdgDust(), 0, "week two's pot divides by three and absorbs the carried unit");
        assertEq(vault.totalUsdgDistributed(), 36_100_000, "18_049_999 + 18_050_001");
        assertEq(vault.claimableUsdg(alice), 24_066_667, "alice: both weeks at two thirds");
        assertEq(vault.claimableUsdg(bob), 9_024_999, "bob: week one plus his unqueued half");
        assertEq(vault.usdgReservedForQueue(), 3_008_333, "the escrow's earnings follow the redeemer");
        assertEq(vault.claimableUsdg(address(vault)), 0, "escrow swept, not left to the stayers");
        assertEq(usdg.balanceOf(address(vault)), 36_100_000, "two weeks of net premium");
        assertEq(_owedUsdg(), 36_099_999, "all of it spoken for but the one unit of per-account floor");
        _assertUsdgInvariant("after settlement");

        vm.prank(bob);
        (uint256 assetsOut, uint256 usdgOut) = vault.completeRedeem(bob);
        assertEq(assetsOut, 5e18, "pro-rata collateral");
        assertEq(usdgOut, 3_008_333, "plus the escrow's week");
        assertEq(vault.usdgReservedForQueue(), 0, "reserve drawn down to zero");
        _assertUsdgInvariant("after completeRedeem");

        vm.prank(bob);
        vault.claimUsdg();
        vm.prank(alice);
        vault.claimUsdg();

        assertEq(usdg.balanceOf(bob), 9_024_999 + 3_008_333, "bob got his third of both weeks, less three floors");
        assertEq(usdg.balanceOf(alice), 24_066_667, "alice got her two thirds of both weeks, floored once");
        assertEq(usdg.balanceOf(address(vault)), 1, "only the one unit of per-account floor is left");
        assertEq(vault.usdgAccounted(), 1, "and it is attributed, so it can never be harvested twice");
        _assertUsdgInvariant("fully drained");
    }

    /*//////////////////////////////////////////////////////////////
                        TRANSFER MID-ACCRUAL
    //////////////////////////////////////////////////////////////*/

    /// @dev The harder half of settle-on-transfer, and a real economic edge nobody should
    ///      discover by losing money to it. The premium is in the vault's hands the instant
    ///      the order fills, but it is not credited to ANYBODY until `rollClose` moves the
    ///      index. So a holder who sells part-way through a cycle hands that whole week's
    ///      premium to the buyer even though the USDG was already sitting in the vault when
    ///      they sold, while keeping every previous week in full.
    ///
    ///      The arithmetic, by hand:
    ///        week one, 10 x $2.00: buyer pays 20.000000, Overcall takes 5% per contract
    ///          (0.100000 x 10 = 1.000000), the vault receives 19.000000, the protocol takes
    ///          5% of that premium (0.950000) and 18.050000 indexes over a 30e18 supply.
    ///          The index floors to 601_666_666_666_666, crediting 18.049999 and carrying one
    ///          base unit as dust. alice 20/30 -> 12.033333, bob 10/30 -> 6.016666.
    ///        week two is the same 18.050000 net plus the carried unit, a pot of 18.050001 that
    ///          divides by three exactly (index delta 601_666_700_000_000, no dust). alice moves
    ///          10e18 to bob AFTER the fill and BEFORE the close, and the transfer settles both
    ///          of them at the week-one index, so week two applies to the post-transfer
    ///          balances: alice 10/30 -> 6.016667, bob 20/30 -> 12.033334.
    ///        both therefore end on 18.050000 (12.033333 + 6.016667 and 6.016666 + 12.033334),
    ///        exactly half the 36.100000 distributed over the two weeks, despite never having
    ///        held equal stakes at the same time.
    function test_midCycleTransferHandsTheUnindexedWeekToTheBuyer() public {
        _deposit(alice, 20e18);
        _deposit(bob, 10e18);

        _fullCycleOtm(10, _okUnitPrice());
        assertEq(vault.claimableUsdg(alice), 12_033_333, "week one, two thirds");
        assertEq(vault.claimableUsdg(bob), 6_016_666, "week one, one third");
        assertEq(vault.usdgDust(), 1, "week one, the unit the index cannot split three ways");

        // Week two: open, list and FILL, but do not close. The premium is now physically in
        // the vault and still belongs to nobody.
        _newWeek();
        uint256 optionId = _rollOpen(10);
        OrderComponents memory c = _approveListing(optionId, 10, _okUnitPrice());
        _fill(c, 10);

        // Week one's whole net (18.049999 credited + 1 carried) plus week two's 19.000000.
        assertEq(usdg.balanceOf(address(vault)), 18_050_000 + 19_000_000, "week two's premium has landed");
        uint256 accBeforeTransfer = vault.accUsdgPerShare();

        vm.prank(alice);
        vault.transfer(bob, 10e18);

        // Nothing moved: the index has not advanced, so the settle on both sides of the
        // transfer credited zero to each.
        assertEq(vault.accUsdgPerShare(), accBeforeTransfer, "a transfer must never move the index");
        assertEq(vault.claimableUsdg(alice), 12_033_333, "alice keeps week one and not a unit more");
        assertEq(vault.claimableUsdg(bob), 6_016_666, "bob has not been credited week two either - yet");
        assertEq(vault.balanceOf(alice), 10e18, "alice halved her stake");
        assertEq(vault.balanceOf(bob), 20e18, "bob doubled his");

        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();
        _rollClose();

        assertEq(vault.totalUsdgDistributed(), 36_100_000, "two weeks of net premium indexed");
        assertEq(vault.usdgDust(), 0, "the carried unit was absorbed by week two's pot");
        assertEq(vault.claimableUsdg(alice), 18_050_000, "12.033333 earned, then only 6.016667 of week two");
        assertEq(vault.claimableUsdg(bob), 18_050_000, "6.016666 earned, then 12.033334 of the week he bought into");
        assertEq(
            vault.claimableUsdg(alice) + vault.claimableUsdg(bob),
            vault.totalUsdgDistributed(),
            "the two claims are the whole distributed total - nothing stranded by the transfer"
        );
        _assertUsdgInvariant("after a mid-cycle transfer");

        vm.prank(alice);
        assertEq(vault.claimUsdg(), 18_050_000, "alice paid in full");
        vm.prank(bob);
        assertEq(vault.claimUsdg(), 18_050_000, "bob paid in full");
        assertEq(usdg.balanceOf(address(vault)), 0, "and the vault is empty");
    }

    /*//////////////////////////////////////////////////////////////
                              PARTIAL FILL
    //////////////////////////////////////////////////////////////*/

    /// @dev F-03 at its awkward edge. The listing is PARTIAL_OPEN, so a buyer may take four of
    ///      ten contracts, and the vault must harvest exactly four contracts' worth and no
    ///      more. The unit price is chosen so nothing divides evenly, which pins the two
    ///      roundings that a "roughly right" implementation would get backwards.
    ///
    ///      The arithmetic, by hand, at $1.234567 per contract:
    ///        Overcall's 5% is floored PER CONTRACT: 1_234_567 * 500 / 10_000 = 61_728
    ///          (61_728.35 truncated), so the vault's share is 1_172_839 per contract.
    ///        Listing 10 puts 11_728_390 and 617_280 in the two consideration items; filling 4
    ///          pays 4/10 of each, which is 4_691_356 and 246_912 - both exactly four times
    ///          the per-contract figures, which is the whole point of flooring per contract
    ///          rather than on the total.
    ///        The protocol fee is 5% of the 4_691_356 of premium harvested, floored: 234_567
    ///          (234_567.8 truncated), leaving 4_456_789 for holders. 234_567 * 20 is
    ///          4_691_340, sixteen units short of the gross, and the 0.8 of a unit the floor
    ///          shaved off the fee goes to the holders, not the fee safe. Rounding must favour
    ///          the depositors.
    function test_partialFillHarvestsOnlyWhatWasSold() public {
        _deposit(alice, 20e18);
        uint256 assetsBefore = vault.totalAssets();

        uint256 unitPrice = 1_234_567;
        uint256 optionId = _rollOpen(10);
        OrderComponents memory c = _approveListing(optionId, 10, unitPrice);
        _fill(c, 4);

        assertEq(usdg.balanceOf(address(vault)), 4_691_356, "the vault was paid for four contracts only");
        assertEq(usdg.balanceOf(overcallFee), 246_912, "Overcall's 5% on four contracts, floored per contract");
        assertEq(usdg.balanceOf(address(vault)) + usdg.balanceOf(overcallFee), unitPrice * 4, "and that is the gross");

        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();

        vm.expectEmit(true, false, false, true, address(vault));
        emit Vault.Harvest(1, 4_691_356, 234_567, 4_456_789);
        vm.prank(keeper);
        vault.rollClose();

        assertEq(usdg.balanceOf(feeSafe), 234_567, "fee is 5% of the partial harvest, floored");
        assertLt(usdg.balanceOf(feeSafe) * 20, 4_691_356, "the flooring shortfall stays with the holders");
        assertEq(vault.totalUsdgDistributed(), 4_456_789, "and every remaining unit was indexed");
        assertEq(vault.claimableUsdg(alice), 4_456_789, "sole holder takes all of it");
        assertEq(vault.usdgDust(), 0, "20e18 shares divide it exactly");

        // The six unsold contracts were still collateralised; they expire worthless in the
        // vault and the collateral comes back whole.
        assertEq(vault.totalAssets(), assetsBefore, "all ten lots of collateral returned");
        assertEq(vault.contractsWritten(), 0, "position closed");
        _assertUsdgInvariant("after a partial fill");
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev For any share split and any harvest size, the sum of what holders can claim never
    ///      exceeds what was actually indexed, and never exceeds what the vault holds. The
    ///      per-account floor in `_pending` can only ever round DOWN, so the vault is always
    ///      solvent against the claims it has issued.
    function testFuzz_claimsNeverExceedWhatWasDistributed(
        uint256 aliceDeposit,
        uint256 bobDeposit,
        uint256 unitPrice,
        uint256 rawContracts
    ) public {
        // Two deposits that together stay under the 50e18 cap.
        aliceDeposit = bound(aliceDeposit, 1e18, 24e18);
        bobDeposit = bound(bobDeposit, 1e18, 24e18);

        uint256 aliceShares = _deposit(alice, aliceDeposit);
        uint256 bobShares = _deposit(bob, bobDeposit);

        // Whole lots, inside the 95% utilization bound and the 50-contract cap.
        uint256 maxContracts = ((aliceDeposit + bobDeposit) * 9_500) / 10_000 / 1e18;
        if (maxContracts > 50) maxContracts = 50;
        uint112 n = uint112(bound(rawContracts, 1, maxContracts));

        // $0.88 is the 0.40%-of-spot policy floor at a $220 spot; the ceiling keeps the fill
        // inside the buyer's 5,000 USDG.
        unitPrice = bound(unitPrice, 880_000, 5_000_000);

        // Out of the money, so everything the vault harvests is premium and all of it is
        // fee-bearing at 5%.
        (uint256 toVault,,) = _splitPremium(unitPrice, n);
        uint256 expectedFee = (toVault * 500) / 10_000;
        uint256 expectedNet = toVault - expectedFee;

        _fullCycleOtm(n, unitPrice);

        assertEq(usdg.balanceOf(feeSafe), expectedFee, "protocol fee is 5% of the premium harvested");
        assertEq(vault.totalUsdgDistributed() + vault.usdgDust(), expectedNet, "every unit is credited or carried");

        uint256 claimed = vault.claimableUsdg(alice) + vault.claimableUsdg(bob);
        assertLe(claimed, vault.totalUsdgDistributed(), "claims never exceed the indexed total");
        assertLe(claimed, usdg.balanceOf(address(vault)), "the vault can always pay every claim");

        uint256 acc = vault.accUsdgPerShare();
        assertEq(vault.claimableUsdg(alice), (aliceShares * acc) / ACC_PRECISION, "alice exact");
        assertEq(vault.claimableUsdg(bob), (bobShares * acc) / ACC_PRECISION, "bob exact");

        _assertUsdgInvariant("fuzzed cycle");
    }

    /// @dev Same property one level down, and driven through the REAL contract rather than a
    ///      reimplementation of its arithmetic: whatever the supply and the harvest, the index
    ///      can never credit more than the pot it was given, the shortfall is exactly
    ///      `usdgDust`, and the index and the credited total agree with each other.
    ///
    ///      The supply is deliberately pushed as far as 1e30 shares. `accUsdgPerShare` is
    ///      1e27-scaled, so at 1e30 shares ONE unit of the index is worth 1000 USDG base
    ///      units and a week's premium genuinely cannot be represented exactly. That is the
    ///      only regime in which `_distributeUsdg` produces dust at all, so bounding the fuzz
    ///      below it would make the interesting case ungenerable.
    function testFuzz_indexCreditsEverythingOrCarriesIt(uint256 depositAmount, uint256 unitPrice, uint256 rawContracts)
        public
    {
        vm.prank(admin);
        vault.setDepositCap(type(uint256).max);

        // Floor at 2e18 so at least one whole lot fits inside the 95% utilization bound.
        depositAmount = bound(depositAmount, 2e18, 1e30);
        nvda.mint(alice, depositAmount);
        uint256 supply = _deposit(alice, depositAmount);
        assertEq(supply, depositAmount, "first deposit into an empty vault is 1:1");

        // Whole lots, inside the 95% utilization bound and the 50-lot policy cap.
        uint256 maxContracts = (depositAmount * 9_500) / 10_000 / 1e18;
        if (maxContracts > 50) maxContracts = 50;
        uint112 n = uint112(bound(rawContracts, 1, maxContracts));
        // $0.88 is the 0.40%-of-spot policy floor at a $220 spot; the ceiling keeps the fill
        // inside the buyer's 5,000 USDG.
        unitPrice = bound(unitPrice, 880_000, 5_000_000);

        // Out of the money: the whole harvest is premium, so the pot is it less a 5% fee.
        (uint256 toVault,,) = _splitPremium(unitPrice, n);
        uint256 pot = toVault - (toVault * 500) / 10_000;

        _fullCycleOtm(n, unitPrice);

        uint256 credited = vault.totalUsdgDistributed();
        uint256 dust = vault.usdgDust();

        assertLe(credited, pot, "the index can never credit more than it was given");
        assertEq(credited + dust, pot, "credited plus dust is the whole pot");
        assertEq((vault.accUsdgPerShare() * supply) / ACC_PRECISION, credited, "the index and the credited total agree");
        assertEq(vault.claimableUsdg(alice), credited, "the sole holder can claim every credited unit");
        // At any realistic supply - anything below 1e27 shares - this bound is ONE USDG base
        // unit, which is why 1e27 rather than 1e18 was the right scaling choice.
        assertLe(dust, (supply + ACC_PRECISION - 1) / ACC_PRECISION, "dust is bounded by ceil(supply/1e27)");
        assertEq(usdg.balanceOf(address(vault)), credited + dust, "the only USDG that left the vault was the fee");

        _assertUsdgInvariant("fuzzed index arithmetic");
    }
}
