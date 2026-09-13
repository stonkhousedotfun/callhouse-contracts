// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {Policy, PolicyParams} from "../../src/Policy.sol";
import {MockClear} from "../../src/mocks/MockClear.sol";
import {OrderComponents} from "../../src/interfaces/ISeaport.sol";

/// @notice Exercise, assignment and every in-the-money settlement path (tasks F-05, F-06).
/// @dev The whole point of this file is that assignment is NORMAL, not exceptional. Valorem
///      assigns by bucket, so a vault that wrote N contracts can come back with anywhere from
///      0 to N assigned, and every number in that range has to settle to the cent. The strike
///      is fixed at 231.00 USDG (RUNG_PICK) and one lot is 1e18, so "x assigned" always means
///      "x * 1e18 NVDA out, x * 231_000_000 USDG in".
///
///      THE FIXTURE ARITHMETIC, ONCE, SO EVERY NUMBER BELOW CAN BE CHECKED BY HAND
///        unit price                 $2.00        = 2_000_000 USDG base units
///        Overcall fee per contract  5% of 2.00   =   100_000   (floored PER CONTRACT)
///        vault premium per contract 2.00 - 0.10  = 1_900_000
///        strike per contract        $231.00      = 231_000_000
///        protocol fee               500 bps of the PREMIUM only (Policy.launchDefaults);
///                                   strike proceeds are credited to holders fee-free
///      So a 10-contract week that fully fills pays the vault 19_000_000 of premium (fee
///      950_000) and Overcall 1_000_000, and every assigned contract adds 231_000_000 on top,
///      none of which is fee'd.
contract VaultAssignmentTest is BaseTest {
    /// @dev Re-declared so {vm.expectEmit} has a shape to match. Must stay byte-identical to
    ///      the declaration in {Vault}.
    event RollClose(
        uint32 indexed cycleNumber, uint256 assetsReturned, uint256 usdgFromAssignment, uint256 contractsAssignedCount
    );
    event Harvest(uint32 indexed cycleNumber, uint256 grossUsdg, uint256 feeUsdg, uint256 netUsdg);

    uint256 internal constant STRIKE = 231_000_000; // RUNG_PICK, USDG 6dp per contract

    /// @dev $2.00 x 10 contracts, split per contract: 5% to Overcall, 95% to the vault.
    uint256 internal constant PREMIUM_TO_VAULT_10 = 19_000_000;
    uint256 internal constant PREMIUM_TO_OVERCALL_10 = 1_000_000;

    /// @dev Harvest of a fully filled, fully assigned 10-contract week.
    ///        gross = 10 * 231_000_000 + 19_000_000 = 2_329_000_000
    ///        fee   = 19_000_000 * 500 / 10000      =       950_000   (premium only)
    ///        net   = gross - fee                   = 2_328_050_000
    uint256 internal constant FULL_ASSIGN_GROSS = 2_329_000_000;
    uint256 internal constant FULL_ASSIGN_FEE = 950_000;
    uint256 internal constant FULL_ASSIGN_NET = 2_328_050_000;

    /// @dev The fee on a fully filled 10-contract week, assigned or not: 5% of 19_000_000.
    uint256 internal constant PREMIUM_FEE_10 = 950_000;

    /*//////////////////////////////////////////////////////////////
                          FULL ASSIGNMENT
    //////////////////////////////////////////////////////////////*/

    /// @dev Write 10, sell 10, every one of them exercised. The vault hands over the entire
    ///      10e18 of collateral and is paid 10 x strike in USDG. This is the worst case for
    ///      NAV and the one the share price has to report honestly.
    ///
    ///      ARITHMETIC, BY HAND:
    ///        deposit                20e18 NVDA
    ///        written                10 contracts x 1e18 lot   -> 10e18 into Valorem, 10e18 idle
    ///        exercised              10 -> 0e18 comes back from the claim
    ///        vault NVDA at the end  10e18 idle + 0 returned    = 10e18
    ///        USDG in                10 x 231_000_000 strike    = 2_310_000_000
    ///                             +      19_000_000 premium    = 2_329_000_000 gross
    ///        protocol fee           19_000_000 premium * 5%    =       950_000
    ///        to depositors          2_329_000_000 - fee        = 2_328_050_000
    function test_fullAssignment_allTenExercised() public {
        _deposit(alice, 20e18);
        assertEq(vault.totalAssets(), 20e18, "start flat at 20 NVDA");

        uint256 oid = _rollOpen(10);
        assertEq(vault.lockedAssets(), 10e18, "10e18 went into Valorem as collateral");
        assertEq(vault.idleAssets(), 10e18, "the other 10e18 stayed idle");

        OrderComponents memory c = _approveListing(oid, 10, _okUnitPrice());
        _fill(c, 10);

        _warpToExercise();
        vault.lockBook();
        _exercise(oid, 10);

        // Valorem reports the scalar as amountExercised * 1e18; the adapter divides it back.
        assertEq(vault.contractsAssigned(), 10, "all ten assigned");
        assertEq(vault.lockedAssets(), 0, "nothing left behind the claim");
        assertEq(vault.claimedExerciseProceeds(), 10 * STRIKE, "ten strikes sitting in the claim");

        // NAV responds to assignment IMMEDIATELY, before settlement, because lockedAssets()
        // reads Valorem's live position rather than the written size.
        assertEq(vault.totalAssets(), 10e18, "NAV already reflects assignment before settlement");

        _warpToExpiry();
        _rollClose();

        // Settlement is NAV-neutral in asset terms: the collateral was already written off
        // when it was assigned, so redeeming the claim must not move totalAssets again.
        assertEq(vault.totalAssets(), 10e18, "rollClose did not move NAV a second time");

        // The collateral is gone and the strike proceeds arrived.
        assertEq(nvda.balanceOf(address(vault)), 10e18, "10e18 NVDA given up");
        assertEq(nvda.balanceOf(buyer), 10e18, "buyer took delivery");

        assertEq(10 * STRIKE + PREMIUM_TO_VAULT_10, FULL_ASSIGN_GROSS, "strike proceeds plus premium");
        assertEq(FULL_ASSIGN_FEE + FULL_ASSIGN_NET, FULL_ASSIGN_GROSS, "the split accounts for every cent");
        assertEq(usdg.balanceOf(feeSafe), FULL_ASSIGN_FEE, "protocol fee is 5% of the premium, nothing on the strikes");
        assertEq(usdg.balanceOf(address(vault)), FULL_ASSIGN_NET, "the rest is held for depositors");
        assertEq(vault.claimableUsdg(alice), FULL_ASSIGN_NET, "and all of it is alice's");
        assertEq(vault.usdgDust(), 0, "2_328_050_000 over 20e18 shares indexes exactly");
        assertEq(usdg.balanceOf(overcallFee), PREMIUM_TO_OVERCALL_10, "Overcall's 5% of the premium only");

        // The buyer paid strike + premium and nothing else.
        assertEq(
            usdg.balanceOf(buyer),
            5_000_000_000 - (10 * STRIKE + PREMIUM_TO_VAULT_10 + PREMIUM_TO_OVERCALL_10),
            "buyer paid exactly 10 strikes plus the full 20.00 premium"
        );

        assertEq(vault.contractsWritten(), 0, "the cycle's position is cleared");
        assertEq(vault.claimKey(), 0, "the claim was redeemed");
        assertEq(_phase(), 0, "back to Idle");
        assertTrue(vault.canRedeemInstantly(), "flat again, so no queue");
    }

    /// @dev REGRESSION GUARD. The fee is charged on the PREMIUM only. On an assigned week most of
    ///      the USDG that arrives is the strike price of the depositors' own called-away stock:
    ///      principal changing form, not yield. An earlier draft fee'd the whole inflow, so this
    ///      exact week paid 232_900_000, of which 231_000_000 was 10% of returned principal and
    ///      more than twelve times the entire premium. Now the assigned week pays exactly what
    ///      the identical unassigned week pays (test_zeroAssignment_despiteFullFill).
    function test_protocolFeeIsChargedOnPremiumOnlyNeverOnStrikeProceeds() public {
        _deposit(alice, 20e18);
        uint256 oid = _rollOpen(10);
        OrderComponents memory c = _approveListing(oid, 10, _okUnitPrice());
        _fill(c, 10);
        _warpToExercise();
        vault.lockBook();
        _exercise(oid, 10);
        _warpToExpiry();

        // The terminal Harvest still reports the whole inflow as gross; only the fee changed.
        vm.expectEmit(true, false, false, true, address(vault));
        emit Harvest(1, FULL_ASSIGN_GROSS, PREMIUM_FEE_10, FULL_ASSIGN_GROSS - PREMIUM_FEE_10);
        _rollClose();

        assertEq(usdg.balanceOf(feeSafe), (PREMIUM_TO_VAULT_10 * 500) / 10_000, "5% of the premium");
        assertEq(usdg.balanceOf(feeSafe), PREMIUM_FEE_10, "the same fee as the unassigned week");
        assertLt(usdg.balanceOf(feeSafe), PREMIUM_TO_VAULT_10, "a cut of the yield, never more than it");
        assertEq(
            vault.claimableUsdg(alice),
            10 * STRIKE + PREMIUM_TO_VAULT_10 - PREMIUM_FEE_10,
            "every strike dollar reaches holders"
        );
    }

    /// @dev The admin's whole fee lever, pulled all the way, still cannot reach principal. A
    ///      compromised Safe can raise `protocolFeeBps` to the compiled-in 2_000 ceiling; on an
    ///      assigned week that used to mean 20% of the strike proceeds. Now it is 20% of premium.
    function test_maxFeeCeilingOnAnAssignedWeekTakesOnlyPremium() public {
        PolicyParams memory p = Policy.launchDefaults();
        p.protocolFeeBps = 2_000;
        vm.prank(admin);
        vault.setPolicy(p);

        _deposit(alice, 20e18);
        uint256 oid = _rollOpen(10);
        OrderComponents memory c = _approveListing(oid, 10, _okUnitPrice());
        _fill(c, 10);
        _warpToExercise();
        vault.lockBook();
        _exercise(oid, 10);
        _warpToExpiry();
        _rollClose();

        assertEq(usdg.balanceOf(feeSafe), 3_800_000, "20% of 19_000_000 premium, nothing of 2_310_000_000 strikes");
        assertEq(vault.claimableUsdg(alice), 10 * STRIKE + PREMIUM_TO_VAULT_10 - 3_800_000, "strikes intact");
    }

    /// @dev A premium checkpointed by a mid-week deposit is fee'd once, at the checkpoint, and
    ///      the close then sees only strike proceeds: fee 0 at the close, and the week's total
    ///      fee is still exactly 5% of premium.
    function test_checkpointedPremiumThenAssignment_feeIsStillPremiumOnly() public {
        _deposit(alice, 20e18);
        uint256 oid = _rollOpen(10);
        OrderComponents memory c = _approveListing(oid, 10, _okUnitPrice());
        _fill(c, 10);
        _deposit(bob, 10e18); // checkpoints the 19_000_000 premium
        assertEq(vault.pendingFeeUsdg(), PREMIUM_FEE_10, "fee accrued at the checkpoint");

        _warpToExercise();
        vault.lockBook();
        _exercise(oid, 10);
        _warpToExpiry();

        vm.expectEmit(true, false, false, true, address(vault));
        emit Harvest(1, 10 * STRIKE, 0, 10 * STRIKE);
        _rollClose();

        assertEq(usdg.balanceOf(feeSafe), PREMIUM_FEE_10, "one fee for the week, on premium only");
    }

    /*//////////////////////////////////////////////////////////////
                        PARTIAL ASSIGNMENT
    //////////////////////////////////////////////////////////////*/

    /// @dev Four of ten exercised. Six lots of collateral come home, four strikes' worth of
    ///      USDG comes in, and `contractsAssigned()` must read 4 and not 4e18.
    ///
    ///      ARITHMETIC, BY HAND:
    ///        vault NVDA at the end  10e18 never written out + 6e18 returned = 16e18
    ///        USDG in                4 x 231_000_000 + 19_000_000 = 943_000_000 gross
    ///        protocol fee           19_000_000 premium * 5%      =     950_000
    ///        to depositors                                       = 942_050_000
    function test_partialAssignment_fourOfTen() public {
        _deposit(alice, 20e18);

        uint256 oid = _rollOpen(10);
        OrderComponents memory c = _approveListing(oid, 10, _okUnitPrice());
        _fill(c, 10);

        _warpToExercise();
        vault.lockBook();
        _exercise(oid, 4);

        // The scalar trap: Valorem stores 4e18, the vault must report 4.
        assertEq(vault.contractsAssigned(), 4, "contractsAssigned is a raw count, not a 1e18 scalar");
        assertEq(vault.lockedAssets(), 6e18, "six lots still behind the claim");
        assertEq(vault.claimedExerciseProceeds(), 4 * STRIKE, "four strikes sitting in the claim");
        assertEq(vault.totalAssets(), 16e18, "NAV already down four lots, before settlement");

        _warpToExpiry();
        _rollClose();

        assertEq(nvda.balanceOf(address(vault)), 16e18, "10e18 never written out + 6e18 returned");
        assertEq(vault.totalAssets(), 16e18, "NAV down by exactly the four assigned lots");
        assertEq(nvda.balanceOf(buyer), 4e18, "buyer took delivery of four");
        assertEq(nvda.balanceOf(address(clear)), 0, "the clearinghouse kept nothing back");

        assertEq(4 * STRIKE + PREMIUM_TO_VAULT_10, 943_000_000, "four strikes plus premium");
        assertEq(usdg.balanceOf(feeSafe), PREMIUM_FEE_10, "5% of premium, none on the four strikes");
        assertEq(usdg.balanceOf(address(vault)), 942_050_000, "the rest held for depositors");
        assertEq(vault.claimableUsdg(alice), 942_050_000, "and all of it is claimable");
    }

    /// @dev Valorem assigns incrementally against the same claim, so a week can be assigned in
    ///      several bites rather than one. The adapter reads the claim live, so the count and
    ///      the locked collateral have to track every bite, not just the first.
    function test_assignmentAccumulatesAcrossSeveralExercises() public {
        _deposit(alice, 20e18);

        uint256 oid = _rollOpen(10);
        OrderComponents memory c = _approveListing(oid, 10, _okUnitPrice());
        _fill(c, 10);

        _warpToExercise();
        vault.lockBook();

        _exercise(oid, 3);
        assertEq(vault.contractsAssigned(), 3, "after the first bite");
        assertEq(vault.lockedAssets(), 7e18, "seven lots still collateralised");

        vm.warp(block.timestamp + 1 hours);
        _exercise(oid, 2);
        assertEq(vault.contractsAssigned(), 5, "the second bite accumulates on the same claim");
        assertEq(vault.lockedAssets(), 5e18, "five lots left");

        vm.warp(block.timestamp + 1 hours);
        _exercise(oid, 1);
        assertEq(vault.contractsAssigned(), 6, "six of ten assigned in three bites");
        assertEq(vault.lockedAssets(), 4e18, "four lots left");
        assertEq(vault.claimedExerciseProceeds(), 6 * STRIKE, "proceeds accumulate too");

        _warpToExpiry();
        _rollClose();

        // 10e18 idle + 4e18 returned; 6 x 231.00 strike + 19.00 premium = 1_405_000_000 gross.
        assertEq(nvda.balanceOf(address(vault)), 14e18, "collateral back is (10 - 6) lots");
        assertEq(usdg.balanceOf(feeSafe) + usdg.balanceOf(address(vault)), 6 * STRIKE + PREMIUM_TO_VAULT_10, "gross");
        assertEq(usdg.balanceOf(feeSafe), PREMIUM_FEE_10, "5% of the 19.00 premium only");
        assertEq(vault.claimableUsdg(alice), 1_404_050_000, "1,405.00 less the 0.95 fee");
    }

    /*//////////////////////////////////////////////////////////////
                          ZERO ASSIGNMENT
    //////////////////////////////////////////////////////////////*/

    /// @dev A full fill is not an assignment. The buyer can simply sit on the options and let
    ///      them expire, in which case every lot of collateral comes back AND the premium is
    ///      still earned. This is the week the product is designed around.
    function test_zeroAssignment_despiteFullFill() public {
        _deposit(alice, 20e18);

        uint256 oid = _rollOpen(10);
        OrderComponents memory c = _approveListing(oid, 10, _okUnitPrice());
        _fill(c, 10);

        _warpToExercise();
        vault.lockBook();
        // The buyer holds all ten and never exercises.
        assertEq(clear.balanceOf(buyer, oid), 10, "buyer holds the inventory");
        assertEq(vault.contractsAssigned(), 0, "nothing assigned");
        assertEq(vault.lockedAssets(), 10e18, "all ten lots still collateralised");

        _warpToExpiry();
        _rollClose();

        assertEq(nvda.balanceOf(address(vault)), 20e18, "every lot of collateral returned");
        assertEq(vault.totalAssets(), 20e18, "NAV unchanged");
        assertEq(nvda.balanceOf(buyer), 0, "buyer took no delivery");
        assertEq(vault.convertToAssets(1e18), 1e18, "share price untouched by a clean week");

        // Premium still earned, minus the 5% protocol fee on it. Compare
        // test_protocolFeeIsChargedOnPremiumOnlyNeverOnStrikeProceeds: identical fee.
        assertEq(usdg.balanceOf(feeSafe), PREMIUM_FEE_10, "5% of 19 USDG");
        assertEq(vault.claimableUsdg(alice), 18_050_000, "95% of 19 USDG");
    }

    /*//////////////////////////////////////////////////////////////
                     UNDERWEIGHT AFTER ASSIGNMENT
    //////////////////////////////////////////////////////////////*/

    /// @dev v1 DOES NOT REBUY. After assignment the vault is short the stock it sold and holds
    ///      USDG instead, and that USDG goes out to depositors as a claim rather than being
    ///      swapped back into NVDA. The consequences, asserted below, are deliberate:
    ///        1. NAV per share falls, permanently, by the assigned collateral.
    ///        2. The vault's NVDA balance does not recover on its own.
    ///        3. Next week's write is sized against the SMALLER book.
    ///      A v2 that wanted to stay delta-one would have to buy the stock back here. It does
    ///      not, and a depositor reading `totalAssets()` sees that immediately.
    function test_afterAssignment_vaultIsUnderweightAndDoesNotRebuy() public {
        _deposit(alice, 20e18);

        uint256 pricePerShareBefore = vault.convertToAssets(1e18);
        assertEq(pricePerShareBefore, 1e18, "1 share = 1 NVDA at the start");

        uint256 oid = _rollOpen(10);
        OrderComponents memory c = _approveListing(oid, 10, _okUnitPrice());
        _fill(c, 10);
        _warpToExercise();
        vault.lockBook();
        _exercise(oid, 10);
        _warpToExpiry();
        _rollClose();

        // 1. NAV in NVDA terms is halved and the share price says so.
        //    20e18 deposited, 10e18 called away, 20e18 shares outstanding -> 0.5 NVDA/share.
        assertEq(vault.totalAssets(), 10e18, "half the book was called away");
        assertLt(vault.convertToAssets(1e18), pricePerShareBefore, "share price fell");
        assertEq(vault.convertToAssets(1e18), 0.5e18, "1 share = 0.5 NVDA");

        // 2. The strike USDG sits as a claim. Not one wei of it became NVDA.
        assertEq(nvda.balanceOf(address(vault)), 10e18, "vault bought nothing back");
        assertEq(vault.claimableUsdg(alice), FULL_ASSIGN_NET, "proceeds are a USDG claim");
        vm.prank(alice);
        vault.claimUsdg();
        assertEq(usdg.balanceOf(alice), FULL_ASSIGN_NET, "and they leave the vault as USDG");
        assertEq(nvda.balanceOf(address(vault)), 10e18, "still underweight after the claim");
        assertEq(vault.totalAssets(), 10e18, "claiming USDG does not touch NAV: USDG is not in it");

        // 3. Next week is written against 10e18, not 20e18. 95% utilisation of 10 lots is 9.
        exerciseTs = uint40(block.timestamp + 6 days);
        expiryTs = uint40(block.timestamp + 7 days);
        _installCycle();
        feed.setAnswer(SPOT_FEED); // refresh staleness after the warp

        // Hoist the id: reading it is an external call and would disarm the expectRevert.
        uint256 nextOid = optionIds[RUNG_PICK];
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Policy.ContractsAboveUtilization.selector, uint256(10), uint256(9)));
        vault.rollOpen(nextOid, 10);

        vm.prank(keeper);
        vault.rollOpen(nextOid, 9);
        assertEq(vault.contractsWritten(), 9, "the smaller book is all there is to write against");
    }

    /// @dev The loss has to be realisable, not just displayed. A depositor who exits after an
    ///      assigned week takes stock at the lower price, and new money entering afterwards
    ///      buys at that same lower price rather than being handed a share of the loss (or a
    ///      free ride on the survivors).
    ///
    ///      ARITHMETIC, BY HAND (the vault's 1-wei virtual share makes these off-by-one):
    ///        after the assigned week: totalAssets 10e18, supply 20e18
    ///        bob deposits 10e18 -> shares = 10e18 * (20e18 + 1) / (10e18 + 1)
    ///                                     = 19_999_999_999_999_999_999   (floor, favours the vault)
    ///        alice redeems 20e18 -> assets = 20e18 * (20e18 + 1) / (39_999_999_999_999_999_999 + 1)
    ///                                      = 10e18 exactly
    ///        bob then redeems all -> 10e18 exactly, i.e. the stock he put in
    function test_newMoneyAfterAnAssignedWeekBuysAtTheLowerSharePrice() public {
        _deposit(alice, 20e18);
        uint256 oid = _rollOpen(10);
        OrderComponents memory c = _approveListing(oid, 10, _okUnitPrice());
        _fill(c, 10);
        _warpToExercise();
        vault.lockBook();
        _exercise(oid, 10);
        _warpToExpiry();
        _rollClose();

        assertEq(vault.totalAssets(), 10e18, "half the book gone");
        assertEq(vault.totalSupply(), 20e18, "shares unchanged");

        uint256 bobShares = _deposit(bob, 10e18);
        assertEq(bobShares, 19_999_999_999_999_999_999, "bob paid 0.5 NVDA per share, less one wei of rounding");
        assertEq(vault.totalAssets(), 20e18, "his stock is really in the vault");

        // Alice realises the loss in stock: 20 NVDA in, 10 NVDA out, plus her USDG claim.
        vm.prank(alice);
        uint256 aliceOut = vault.redeem(20e18, alice, alice);
        assertEq(aliceOut, 10e18, "alice exits at 0.5 NVDA per share, exactly");
        assertEq(nvda.balanceOf(alice), 10e18 + 10e18, "10e18 she never deposited + 10e18 returned");

        // And bob is not left holding alice's loss: he takes back what he put in.
        vm.prank(bob);
        uint256 bobOut = vault.redeem(bobShares, bob, bob);
        assertEq(bobOut, 10e18, "bob gets his 10e18 back, to the wei");
        assertEq(vault.totalAssets(), 0, "the vault is empty and nothing was stranded");
    }

    /// @dev A depositor who arrives during Listed is NOT added to the open short - the write
    ///      size is fixed at rollOpen - but he is still a pro-rata owner of the pool when that
    ///      short is assigned. The two legs of the USDG take are split differently, and that
    ///      is the point of this test: the PREMIUM was earned before he arrived and is fixed
    ///      into the index by the checkpoint inside his own deposit, while the ASSIGNMENT
    ///      proceeds arrive at the close and are shared by everyone holding shares then.
    ///
    ///      ARITHMETIC, BY HAND:
    ///        alice 20e18 -> 20e18 shares; write 10 (10e18 locked, 10e18 idle)
    ///        fill 10 at $2.00 -> vault takes 19_000_000 premium
    ///        bob's deposit CHECKPOINTS first, over supply 20e18:
    ///          fee 5% = 950_000 (pending), net 18_050_000
    ///          indexDelta = 18_050_000 * 1e27 / 20e18 = 902_500e9, exact
    ///          alice += 20e18 * 902_500e9 / 1e27 = 18_050_000; bob starts from that index
    ///        bob then deposits 10e18 -> 10e18 * (20e18+1)/(20e18+1) = 10e18 shares
    ///        all ten assigned -> 10 * 231_000_000 = 2_310_000_000 strike proceeds at the close
    ///        close harvests over supply 30e18, and all of it is strike proceeds:
    ///          fee 0 (strike proceeds are fee-free), net 2_310_000_000
    ///          indexDelta = 2_310_000_000 * 1e27 / 30e18 = 77_000e12, exact
    ///          bob   = 10e18 * 77_000e12 / 1e27 =   770_000_000
    ///          alice = 18_050_000 + 20e18 * 77_000e12 / 1e27 = 1_558_050_000
    ///        1_558_050_000 + 770_000_000 = 2_328_050_000 = FULL_ASSIGN_NET, to the unit.
    ///        vault NVDA 20e18, supply 30e18
    ///        bob's stake = 10e18 * (20e18 + 1) / (30e18 + 1) = 6_666_666_666_666_666_666
    function test_lateDepositorDuringListed_isNotWrittenAgainstButSharesTheAssignment() public {
        _deposit(alice, 20e18);

        uint256 oid = _rollOpen(10);
        OrderComponents memory c = _approveListing(oid, 10, _okUnitPrice());
        _fill(c, 10);

        uint256 bobShares = _deposit(bob, 10e18);
        assertEq(bobShares, 10e18, "bob bought in at par: NAV per share is still 1.0");

        // The short did not grow to cover bob's money.
        assertEq(vault.contractsWritten(), 10, "write size is fixed at rollOpen");
        assertEq(vault.lockedAssets(), 10e18, "bob's stock was never posted as collateral");
        assertEq(vault.idleAssets(), 20e18, "it sits idle instead");

        _warpToExercise();
        vault.lockBook();
        _exercise(oid, 10);
        _warpToExpiry();
        _rollClose();

        assertEq(nvda.balanceOf(address(vault)), 20e18, "10e18 alice idle + 10e18 bob idle");
        assertEq(vault.totalSupply(), 30e18, "three ten-lot stakes");

        // Bob shares the ASSIGNMENT pro-rata even though his collateral was not written: the
        // book he owns a third of is the one the assignment shrank.
        assertEq(vault.convertToAssets(bobShares), 6_666_666_666_666_666_666, "bob owns 1/3 of the smaller book");
        assertEq(vault.claimableUsdg(bob), 770_000_000, "a third of the 2_310_000_000 strike proceeds");

        // He shares none of the PREMIUM, which was earned and indexed before his shares
        // existed. Alice keeps all 18_050_000 of it on top of her two thirds of the proceeds.
        assertEq(vault.claimableUsdg(alice), 1_558_050_000, "two thirds of the proceeds plus the whole premium");
        assertEq(vault.claimableUsdg(alice) - 2 * 770_000_000, 18_050_000, "and that surplus is exactly the premium");

        assertEq(
            vault.claimableUsdg(alice) + vault.claimableUsdg(bob),
            FULL_ASSIGN_NET,
            "together they hold every cent of the week's net take"
        );
        assertEq(vault.usdgDust(), 0, "both distributions index exactly, no dust");
    }

    /*//////////////////////////////////////////////////////////////
                  A QUEUED REDEEMER THROUGH ASSIGNMENT
    //////////////////////////////////////////////////////////////*/

    /// @dev Someone who queues during a week that ends up fully assigned cannot be paid purely
    ///      in stock: the stock was called away. They get their pro-rata slice of what is left
    ///      PLUS the USDG their escrowed shares accrued while they waited. Both halves matter;
    ///      dropping the USDG half would hand the queued depositor's premium to the holders
    ///      who stayed.
    ///
    ///      ARITHMETIC, BY HAND:
    ///        supply at settlement   30e18, of which 10e18 is escrowed
    ///        idle NVDA at settlement 20e18 (the claim returned nothing)
    ///        epoch assets           20e18 * 10e18 / 30e18 = 6_666_666_666_666_666_666
    ///        index                  floor(2_328_050_000 * 1e27 / 30e18) = 77_601_666_666_666_666
    ///        epoch USDG             floor(10e18 * index / 1e27)          =         776_016_666
    ///        (three ten-lot stakes floor to 2_328_049_998; the 2 base units ride as dust)
    function test_queuedRedeemerThroughAnAssignedWeek_getsNvdaAndUsdg() public {
        _deposit(alice, 20e18);
        _deposit(bob, 10e18);

        uint256 oid = _rollOpen(10);
        OrderComponents memory c = _approveListing(oid, 10, _okUnitPrice());
        _fill(c, 10);

        // Queue half of alice's position while the call is still live.
        vm.prank(alice);
        vault.queueRedeem(10e18);
        assertEq(vault.queuedShares(), 10e18, "escrowed on the vault");
        assertEq(vault.balanceOf(address(vault)), 10e18, "shares really moved into escrow");
        assertEq(vault.balanceOf(alice), 10e18, "and left her balance");

        _warpToExercise();
        vault.lockBook();
        _exercise(oid, 10); // fully assigned week
        _warpToExpiry();
        _rollClose();

        assertEq(vault.claimableUsdg(alice), 776_016_666, "alice's remaining 10e18 shares");
        assertEq(vault.claimableUsdg(bob), 776_016_666, "bob's 10e18 shares");

        // The escrow's third was taken out of the index and reserved for the epoch instead.
        assertEq(vault.usdgReservedForQueue(), 776_016_666, "escrow accrual is reserved, not left behind");
        assertEq(vault.totalSupply(), 20e18, "escrowed shares burned at settlement");

        uint256 expectedAssets = 6_666_666_666_666_666_666;
        assertEq(vault.reservedAssets(), expectedAssets, "assets carved out of NAV");
        // Reserved assets are excluded from NAV, so the survivors' share price is unaffected
        // by the pending payout sitting in the vault's balance.
        assertEq(nvda.balanceOf(address(vault)), 20e18, "the stock has not moved yet");
        assertEq(vault.totalAssets(), 20e18 - expectedAssets, "but NAV already excludes it");

        (uint256 previewAssets, uint256 previewUsdg) = vault.previewCompleteRedeem(alice);
        assertEq(previewAssets, expectedAssets, "preview matches");
        assertEq(previewUsdg, 776_016_666, "preview matches");

        uint256 nvdaBefore = nvda.balanceOf(alice);
        vm.prank(alice);
        (uint256 gotAssets, uint256 gotUsdg) = vault.completeRedeem(alice);

        assertEq(gotAssets, expectedAssets, "a MIX: the NVDA half");
        assertEq(gotUsdg, 776_016_666, "a MIX: the USDG half");
        assertGt(gotAssets, 0, "not paid purely in USDG");
        assertGt(gotUsdg, 0, "not paid purely in NVDA");
        assertEq(nvda.balanceOf(alice) - nvdaBefore, expectedAssets, "NVDA actually delivered");
        assertEq(usdg.balanceOf(alice), 776_016_666, "USDG actually delivered");

        // The last (here only) claimant of an epoch drains it exactly.
        assertEq(vault.reservedAssets(), 0, "no assets stranded");
        assertEq(vault.usdgReservedForQueue(), 0, "no USDG stranded");
    }

    /// @dev ZERO DUST, WITH DELIBERATELY AWKWARD NUMBERS. Two people queue amounts that do not
    ///      divide the epoch cleanly, so the proportional drawdown floors for the first
    ///      claimant and the LAST claimant has to absorb the remainder. If the last claimant
    ///      were paid by the same formula instead of taking what is left, one wei of NVDA and
    ///      one base unit of USDG would be stranded in the vault every single epoch, forever.
    ///
    ///      ARITHMETIC, BY HAND:
    ///        k = 1_111_111_112_111_111_111 (chosen so BOTH legs leave a unit of remainder)
    ///        alice queues 7_777_777_784_777_777_777 = 7k
    ///        bob   queues 3_333_333_336_333_333_333 = 3k
    ///        queued total 11_111_111_121_111_111_110 -> the split is exactly 7/10 and 3/10
    ///        epoch assets 20e18 * Q / 30e18            = 7_407_407_414_074_074_073
    ///          alice 7/10 -> floor(...* 7 / 10)        = 5_185_185_189_851_851_851
    ///          bob        -> takes the remainder       = 2_222_222_224_222_222_222
    ///          (bob's own floor would be              2_222_222_224_222_222_221, so 1 wei
    ///           would strand if the last claimant were not given the balance)
    ///        index        floor(2_328_050_000 * 1e27 / 30e18) = 77_601_666_666_666_666
    ///        epoch USDG   floor(Q * index / 1e27)      =         862_240_741
    ///          USDG is paid per entry by index growth, not pro rata (both queued at index 0):
    ///          alice      -> floor(7k * index / 1e27)  =         603_568_519
    ///          bob, last  -> takes the remainder       =         258_672_222  (= his own floor)
    ///          The NVDA leg is still pro rata and still shows the one-wei strand the last-claimant
    ///          rule prevents; on the USDG leg the per-entry floors already sum to the pot here.
    function test_twoQueuedRedeemersThroughAnAssignedWeek_leaveZeroDust() public {
        _deposit(alice, 20e18);
        _deposit(bob, 10e18);

        uint256 oid = _rollOpen(10);
        OrderComponents memory c = _approveListing(oid, 10, _okUnitPrice());
        _fill(c, 10);

        uint256 aliceQ = 7_777_777_784_777_777_777;
        uint256 bobQ = 3_333_333_336_333_333_333;
        vm.prank(alice);
        vault.queueRedeem(aliceQ);
        vm.prank(bob);
        vault.queueRedeem(bobQ);
        assertEq(vault.queuedShares(), aliceQ + bobQ, "both in the same epoch");

        _warpToExercise();
        vault.lockBook();
        _exercise(oid, 10);
        _warpToExpiry();
        _rollClose();

        uint256 epochAssets = 7_407_407_414_074_074_073;
        uint256 epochUsdg = 862_240_741;
        assertEq(vault.reservedAssets(), epochAssets, "epoch assets, floored");
        assertEq(vault.usdgReservedForQueue(), epochUsdg, "epoch USDG, floored");
        (uint256 sharesRem, uint256 assetsRem, uint256 usdgRem) = vault.epochs(1);
        assertEq(sharesRem, aliceQ + bobQ, "epoch 1 holds both stakes");
        assertEq(assetsRem, epochAssets, "and the assets");
        assertEq(usdgRem, epochUsdg, "and the USDG");

        // First claimant: strict floor of the proportional share of NVDA, and exactly the index
        // growth its own shares earned in escrow for USDG.
        vm.prank(alice);
        (uint256 aliceAssets, uint256 aliceUsdg) = vault.completeRedeem(alice);
        assertEq(aliceAssets, 5_185_185_189_851_851_851, "floor(epochAssets * 7/10)");
        assertEq(aliceUsdg, 603_568_519, "floor(aliceQ * index / 1e27): what her shares earned");

        // Last claimant: takes exactly what remains of both legs. On NVDA that is one wei more than
        // his proportional floor — the dust that never strands. On USDG it equals his own index
        // growth, because the per-entry floors already sum to the pot.
        uint256 bobAssetsFloor = (epochAssets * bobQ) / (aliceQ + bobQ);
        uint256 bobUsdgFloor = (epochUsdg * bobQ) / (aliceQ + bobQ);
        vm.prank(bob);
        (uint256 bobAssets, uint256 bobUsdg) = vault.completeRedeem(bob);
        assertEq(bobAssets, 2_222_222_224_222_222_222, "the balance, not the floor");
        assertEq(bobUsdg, 258_672_222, "the balance of the epoch");
        assertEq(bobAssets - bobAssetsFloor, 1, "exactly one wei of NVDA would otherwise strand");
        assertEq(bobUsdg, (bobQ * vault.accUsdgPerShare()) / 1e27, "bob's remainder equals his own index growth");
        assertLe(bobUsdgFloor, bobUsdg, "and is never less than the old pro-rata floor");

        // Conservation: the epoch is drained to nothing.
        assertEq(aliceAssets + bobAssets, epochAssets, "assets conserved exactly");
        assertEq(aliceUsdg + bobUsdg, epochUsdg, "USDG conserved exactly");
        assertEq(vault.reservedAssets(), 0, "no assets stranded");
        assertEq(vault.usdgReservedForQueue(), 0, "no USDG stranded");
        (, uint256 assetsLeft, uint256 usdgLeft) = vault.epochs(1);
        assertEq(assetsLeft, 0, "epoch emptied");
        assertEq(usdgLeft, 0, "epoch emptied");
    }

    /*//////////////////////////////////////////////////////////////
                      EXERCISING OUTSIDE THE WINDOW
    //////////////////////////////////////////////////////////////*/

    /// @dev The exercise window is the clearinghouse's rule, not the vault's. A buyer who owns
    ///      the option outright still cannot take delivery before the book closes, which is
    ///      what lets the vault keep writing and listing right up to `exerciseTs`; and once
    ///      expiry passes the option is worthless, which is what lets `rollClose` pull the
    ///      whole remaining collateral back without racing anyone.
    function test_exerciseOutsideTheWindow_revertsInTheClearinghouse() public {
        _deposit(alice, 20e18);
        uint256 oid = _rollOpen(10);
        OrderComponents memory c = _approveListing(oid, 10, _okUnitPrice());
        _fill(c, 10);

        assertEq(clear.balanceOf(buyer, oid), 10, "buyer genuinely owns them");

        vm.startPrank(buyer);
        usdg.approve(address(clear), type(uint256).max);
        vm.expectRevert(MockClear.TooEarlyToExercise.selector);
        clear.exercise(oid, 10);
        vm.stopPrank();

        // Still refused one second before the window opens.
        vm.warp(uint256(exerciseTs) - 1);
        vm.prank(buyer);
        vm.expectRevert(MockClear.TooEarlyToExercise.selector);
        clear.exercise(oid, 10);
        assertEq(vault.contractsAssigned(), 0, "nothing slipped through");

        // Accepted on the tick.
        _warpToExercise();
        _exercise(oid, 4);
        assertEq(vault.contractsAssigned(), 4, "the window opened exactly at exerciseTs");

        // And shut again at expiry, with six contracts still live in the buyer's hands.
        assertEq(clear.balanceOf(buyer, oid), 6, "six unexercised options remain");
        _warpToExpiry();
        vm.prank(buyer);
        vm.expectRevert(MockClear.Expired.selector);
        clear.exercise(oid, 6);
        assertEq(vault.contractsAssigned(), 4, "the late exercise changed nothing");

        // rollClose then pulls back the collateral for all six.
        _rollClose();
        assertEq(nvda.balanceOf(address(vault)), 16e18, "10e18 idle + 6e18 the buyer could not take");
    }

    /*//////////////////////////////////////////////////////////////
             RECON R4: DO LEFTOVERS BLOCK THE CLAIM?
    //////////////////////////////////////////////////////////////*/

    /// @dev R4 asked whether option ERC-1155 still sitting in the vault at expiry blocks the
    ///      claim redemption. ANSWER: NO. The claim NFT and the option tokens are independent;
    ///      redeeming the claim returns the collateral for everything that was not exercised,
    ///      whether the matching option token was sold, held, or burned. If this were false an
    ///      unsold week would permanently strand collateral, which is the single worst failure
    ///      this vault could have.
    function test_unsoldInventoryDoesNotBlockTheClaim() public {
        _deposit(alice, 20e18);

        uint256 oid = _rollOpen(10);
        OrderComponents memory c = _approveListing(oid, 10, _okUnitPrice());
        _fill(c, 6); // only six of the ten sold

        assertEq(clear.balanceOf(address(vault), oid), 4, "four unsold options left in the vault");
        assertEq(clear.balanceOf(buyer, oid), 6, "six with the buyer");

        _warpToExercise();
        vault.lockBook();
        // The six that sold are never exercised either.
        _warpToExpiry();
        _rollClose();

        // The claim redeemed despite the leftovers, and ALL ten lots came home.
        assertEq(nvda.balanceOf(address(vault)), 20e18, "all 10e18 of collateral returned");
        assertEq(vault.totalAssets(), 20e18, "NAV whole");
        assertEq(vault.claimKey(), 0, "the claim was redeemed, not skipped");
        assertEq(clear.balanceOf(address(vault), oid), 4, "the worthless leftovers are simply still there");
        assertEq(nvda.balanceOf(address(clear)), 0, "the clearinghouse is holding nothing of ours");

        // Premium from the partial fill: 19.00 x 6/10 = 11.40 USDG gross to the vault.
        assertEq(usdg.balanceOf(feeSafe), 570_000, "5% of 11.40");
        assertEq(vault.claimableUsdg(alice), 10_830_000, "95% of 11.40");

        // And the vault is flat, so redemption is instant again. Leftovers block nothing.
        assertTrue(vault.canRedeemInstantly(), "leftover inventory does not pin the vault");
        vm.prank(alice);
        vault.redeem(20e18, alice, alice);
        assertEq(nvda.balanceOf(alice), 30e18, "depositor made whole in stock");
    }

    /*//////////////////////////////////////////////////////////////
              PARTIAL FILL *AND* PARTIAL ASSIGNMENT
    //////////////////////////////////////////////////////////////*/

    /// @dev The realistic week: not everything sells, and not everything that sells is
    ///      exercised. Write 10, sell 6, three of the six exercised.
    ///
    ///      ARITHMETIC, BY HAND:
    ///        premium in   19_000_000 * 6/10 = 11_400_000 to the vault
    ///                      1_000_000 * 6/10 =    600_000 to Overcall
    ///        NVDA         20e18 - 10e18 written = 10e18 idle; claim returns (10-3) = 7e18
    ///                     -> 17e18, buyer holds 3e18
    ///        USDG gross   11_400_000 + 3 * 231_000_000 = 704_400_000
    ///        fee 5% of the 11_400_000 premium only      =     570_000
    ///        to depositors                              = 703_830_000
    function test_partialFillAndPartialAssignment() public {
        _deposit(alice, 20e18);

        uint256 oid = _rollOpen(10);
        OrderComponents memory c = _approveListing(oid, 10, _okUnitPrice());
        _fill(c, 6);

        // Premium is pro-rata on a PARTIAL_OPEN order: 19.00 x 6/10 and 1.00 x 6/10.
        assertEq(usdg.balanceOf(address(vault)), 11_400_000, "vault's 95% of six contracts");
        assertEq(usdg.balanceOf(overcallFee), 600_000, "Overcall's 5% of six contracts");

        _warpToExercise();
        vault.lockBook();
        _exercise(oid, 3);

        assertEq(vault.contractsAssigned(), 3, "three of the six sold were exercised");
        assertEq(vault.lockedAssets(), 7e18, "seven lots still collateralised");

        _warpToExpiry();
        _rollClose();

        // NVDA: 10e18 never written out, 7e18 returned from the claim, 3e18 delivered.
        assertEq(nvda.balanceOf(address(vault)), 17e18, "exact NVDA the vault ends with");
        assertEq(vault.totalAssets(), 17e18, "NAV down by exactly three lots");
        assertEq(nvda.balanceOf(buyer), 3e18, "three lots delivered");

        assertEq(11_400_000 + 3 * STRIKE, 704_400_000, "premium plus three strikes");
        assertEq(usdg.balanceOf(feeSafe), 570_000, "5% of premium, none on the three strikes");
        assertEq(usdg.balanceOf(address(vault)), 703_830_000, "exact USDG the vault ends with");
        assertEq(vault.claimableUsdg(alice), 703_830_000, "all of it claimable, to the cent");
        assertEq(vault.usdgDust(), 0, "703.83 over 20e18 shares indexes exactly");
    }

    /*//////////////////////////////////////////////////////////////
                              FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev For every (written, filled, exercised) triple the settlement identity must hold
    ///      exactly: collateral back is (n - x) lots, and USDG from assignment is x * strike.
    ///      `filled` is deliberately allowed to be less than `written` and `exercised` less
    ///      than `filled`, because that is the shape of a real week. The bounds reach the
    ///      corners: n = 1 and n = 28 (the utilisation cap on 30e18) are both generated, as
    ///      are f = 0 (nothing sold) and x = f (everything sold is exercised).
    function testFuzz_collateralAndStrikeAreExact(uint8 nRaw, uint8 fRaw, uint8 xRaw) public {
        // 30e18 deposited at 95% utilisation caps the write at 28 lots.
        uint112 n = uint112(bound(uint256(nRaw), 1, 28));
        uint112 f = uint112(bound(uint256(fRaw), 0, n));
        uint112 x = uint112(bound(uint256(xRaw), 0, f));

        _fund(buyer, 0, 20_000_000_000); // enough USDG to exercise 28 lots at $231
        _deposit(alice, 30e18);

        uint256 oid = _rollOpen(n);
        OrderComponents memory c = _approveListing(oid, n, _okUnitPrice());
        if (f != 0) _fill(c, f);

        (uint256 toVaultFull, uint256 toOvercallFull,) = _splitPremium(_okUnitPrice(), n);
        uint256 premiumToVault = (toVaultFull * f) / n;
        assertEq(usdg.balanceOf(address(vault)), premiumToVault, "premium in before settlement");
        assertEq(usdg.balanceOf(overcallFee), (toOvercallFull * f) / n, "Overcall's cut is pro-rata too");

        _warpToExercise();
        vault.lockBook();
        if (x != 0) _exercise(oid, x);

        assertEq(vault.contractsAssigned(), x, "assigned count is a raw count");
        assertEq(vault.lockedAssets(), (uint256(n) - x) * 1e18, "locked collateral tracks assignment live");
        assertEq(vault.claimedExerciseProceeds(), uint256(x) * STRIKE, "strike proceeds accrue in the claim");

        uint256 nvdaBefore = nvda.balanceOf(address(vault));
        _warpToExpiry();
        _rollClose();

        // Collateral returned by the claim.
        assertEq(nvda.balanceOf(address(vault)) - nvdaBefore, (uint256(n) - x) * 1e18, "collateral returned");
        assertEq(nvda.balanceOf(address(vault)), 30e18 - uint256(x) * 1e18, "book is short exactly the assigned lots");
        assertEq(vault.totalAssets(), 30e18 - uint256(x) * 1e18, "and NAV says so");
        assertEq(nvda.balanceOf(buyer), uint256(x) * 1e18, "buyer took delivery of exactly x lots");
        assertEq(nvda.balanceOf(address(clear)), 0, "the clearinghouse kept nothing back");

        // Everything harvested is either in the vault for depositors or in the fee safe, so
        // their sum is the gross take. The fee is 5% of the premium alone, floored, whatever
        // was assigned.
        uint256 gross = premiumToVault + uint256(x) * STRIKE;
        uint256 fee = (premiumToVault * 500) / 10_000;
        assertEq(usdg.balanceOf(address(vault)) + usdg.balanceOf(feeSafe), gross, "gross take");
        assertEq(usdg.balanceOf(feeSafe), fee, "protocol fee floors at 5% of premium, none on strikes");
        assertEq(usdg.balanceOf(address(vault)), gross - fee, "the remainder is depositors'");

        assertEq(vault.contractsWritten(), 0, "position cleared");
        assertEq(_phase(), 0, "back to Idle");
    }

    /*//////////////////////////////////////////////////////////////
                      THE PUBLIC CYCLE TAPE
    //////////////////////////////////////////////////////////////*/

    /// @dev The `RollClose` event's fourth parameter is named `contractsAssignedCount` and it
    ///      has to be the real one: an indexer or an ops dashboard has nothing else to read,
    ///      and the claim is gone by the time the transaction ends. On this week it must be 10
    ///      — `assetsReturned == 0` and `usdgFromAssignment == 2_310_000_000` in the same event
    ///      prove all ten were assigned.
    ///
    ///      REGRESSION GUARD. The parameter used to be a hardcoded `0`, so every assigned week
    ///      looked unassigned. The fix reads `contractsAssigned()` BEFORE `_redeemClaim(...)`
    ///      runs, because `_redeemClaim` zeroes `claimKey` and the view returns 0 from then on;
    ///      reading it after would silently reintroduce the same zero.
    function test_rollClose_emitsTheRealAssignedCount() public {
        _deposit(alice, 20e18);

        uint256 oid = _rollOpen(10);
        OrderComponents memory c = _approveListing(oid, 10, _okUnitPrice());
        _fill(c, 10);
        _warpToExercise();
        vault.lockBook();
        _exercise(oid, 10);

        assertEq(vault.contractsAssigned(), 10, "ten really were assigned");

        _warpToExpiry();
        vm.expectEmit(true, false, false, true, address(vault));
        emit RollClose(1, 0, 10 * STRIKE, 10);
        _rollClose();

        // And the view it was read from is zeroed by the redemption, which is exactly why the
        // read has to happen first.
        assertEq(vault.contractsAssigned(), 0, "the claim is gone once it has been redeemed");
    }

    /// @dev The vault is a passive Seaport offerer: a fill moves the option ERC-1155 out
    ///      without calling back, so anything the vault counted in storage would drift the
    ///      moment a buyer filled. `contractsRemaining()` and `contractsSold()` are therefore
    ///      VIEWS over `clear.balanceOf(address(this), optionId)` — the one number that cannot
    ///      be wrong.
    ///
    ///      REGRESSION GUARD. `contractsSold` used to be a storage variable, set to 0 on the
    ///      write and never touched again, so `contractsRemaining()` reported the full written
    ///      size while the real inventory was lower. Settlement never read either one, so this
    ///      was a reporting defect rather than a loss of funds — but `approveListing` sizes the
    ///      next listing from the ERC-1155 balance precisely because the getter could not be
    ///      trusted, and an ops dashboard had no way to tell a sold-out week from an unsold one.
    function test_contractsRemaining_tracksTheVaultsRealInventory() public {
        _deposit(alice, 20e18);
        uint256 oid = _rollOpen(10);
        OrderComponents memory c = _approveListing(oid, 10, _okUnitPrice());

        assertEq(vault.contractsRemaining(), 10, "nothing sold yet: the whole write is still here");
        assertEq(vault.contractsSold(), 0, "and nothing has left");

        _fill(c, 6);

        assertEq(clear.balanceOf(address(vault), oid), 4, "the vault really only holds four");
        assertEq(vault.contractsSold(), 6, "six left the vault on the fill");
        assertEq(vault.contractsRemaining(), clear.balanceOf(address(vault), oid), "and four are left");
        assertEq(vault.contractsWritten(), 10, "the write size itself is unchanged by a fill");
        assertEq(vault.contractsSold() + vault.contractsRemaining(), 10, "sold plus held is what was written");
    }
}
