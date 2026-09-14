// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {Vault} from "../../src/Vault.sol";
import {Policy, PolicyParams} from "../../src/Policy.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {OrderComponents} from "../../src/interfaces/ISeaport.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Roles, the halt, the policy hard caps, and the two Stock Token hazards the vault
///         cannot control: the ERC-8056 display multiplier and an issuer freeze.
/// @dev Tasks T-03, T-06, F-08, F-09, F-12, F-14.
contract VaultAdminTest is BaseTest {
    address internal stranger = makeAddr("stranger");
    address internal newFeeSafe = makeAddr("newFeeSafe");

    /// @dev ERC-1155 receiver magic values, written out so a silent signature change is loud.
    bytes4 internal constant ERC1155_RECEIVED = 0xf23a6e61;
    bytes4 internal constant ERC1155_BATCH_RECEIVED = 0xbc197c81;
    bytes4 internal constant REJECT = 0x00000000;

    /*//////////////////////////////////////////////////////////////
                             LOCAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev The launch policy, mirrored from Policy.launchDefaults() so each bounds test can
    ///      start from something legal and break exactly one field.
    function _launchPolicy() internal pure returns (PolicyParams memory) {
        return PolicyParams({
            minOtmBps: 300,
            maxOtmBps: 1_200,
            minPremiumBps: 40,
            maxUtilizationBps: 9_500,
            protocolFeeBps: 500,
            maxContractsCap: 50
        });
    }

    function _unauthorized(address who, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, role);
    }

    /// @dev Roll the fixture forward to a fresh Overcall cycle starting from now.
    /// @dev The feed is re-published as part of the roll. A week has passed since the fixture
    ///      deployed it, and the vault's staleness gate (6 hours here) would refuse the write
    ///      against a frozen `updatedAt` — a real feed keeps ticking, so the mock has to too.
    function _nextCycle() internal {
        feed.setAnswer(SPOT_FEED);
        exerciseTs = uint40(block.timestamp + 6 days);
        expiryTs = uint40(block.timestamp + 7 days);
        _installCycle();
    }

    function _assertPolicyIs(PolicyParams memory want, string memory what) internal view {
        (uint16 minOtm, uint16 maxOtm, uint16 minPrem, uint16 util, uint16 fee, uint64 cap) = vault.policy();
        assertEq(minOtm, want.minOtmBps, what);
        assertEq(maxOtm, want.maxOtmBps, what);
        assertEq(minPrem, want.minPremiumBps, what);
        assertEq(util, want.maxUtilizationBps, what);
        assertEq(fee, want.protocolFeeBps, what);
        assertEq(cap, want.maxContractsCap, what);
    }

    /*//////////////////////////////////////////////////////////////
                              ROLE WIRING
    //////////////////////////////////////////////////////////////*/

    function test_roleWiring() public view {
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), "admin holds DEFAULT_ADMIN_ROLE");
        assertTrue(vault.hasRole(vault.KEEPER_ROLE(), keeper), "keeper holds KEEPER_ROLE");
        assertTrue(vault.hasRole(vault.GUARDIAN_ROLE(), guardian), "guardian holds GUARDIAN_ROLE");

        // The separation is the point: the admin Safe is not a hot key, and the hot key is not
        // governance. Neither inherits the other's powers.
        assertFalse(vault.hasRole(vault.KEEPER_ROLE(), admin), "admin is not the keeper");
        assertFalse(vault.hasRole(vault.GUARDIAN_ROLE(), admin), "admin does not hold GUARDIAN_ROLE");
        assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), keeper), "keeper is not an admin");
        assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), guardian), "guardian is not an admin");
        assertFalse(vault.hasRole(vault.KEEPER_ROLE(), guardian), "guardian cannot write");

        assertEq(vault.getRoleAdmin(vault.KEEPER_ROLE()), vault.DEFAULT_ADMIN_ROLE(), "admin governs KEEPER_ROLE");
        assertEq(vault.getRoleAdmin(vault.GUARDIAN_ROLE()), vault.DEFAULT_ADMIN_ROLE(), "admin governs GUARDIAN_ROLE");
    }

    /*//////////////////////////////////////////////////////////////
                        WRONG CALLER IS REJECTED
    //////////////////////////////////////////////////////////////*/

    function test_rollOpen_rejectsEveryoneButKeeper() public {
        _deposit(alice, 20e18);
        uint256 optionId = optionIds[RUNG_PICK];
        bytes32 keeperRole = vault.KEEPER_ROLE();

        vm.prank(stranger);
        vm.expectRevert(_unauthorized(stranger, keeperRole));
        vault.rollOpen(optionId, 5);

        vm.prank(guardian);
        vm.expectRevert(_unauthorized(guardian, keeperRole));
        vault.rollOpen(optionId, 5);

        // Governance holding the keeper key would defeat the split entirely.
        vm.prank(admin);
        vm.expectRevert(_unauthorized(admin, keeperRole));
        vault.rollOpen(optionId, 5);
    }

    function test_approveListing_rejectsEveryoneButKeeper() public {
        // Hoisted: _buildOrder reads the Seaport counter, and an external call inside the
        // expectRevert window would consume the arm.
        OrderComponents memory c = _buildOrder(optionIds[RUNG_PICK], 5, _okUnitPrice());
        bytes32 keeperRole = vault.KEEPER_ROLE();

        vm.prank(stranger);
        vm.expectRevert(_unauthorized(stranger, keeperRole));
        vault.approveListing(c);

        vm.prank(admin);
        vm.expectRevert(_unauthorized(admin, keeperRole));
        vault.approveListing(c);

        vm.prank(guardian);
        vm.expectRevert(_unauthorized(guardian, keeperRole));
        vault.approveListing(c);
    }

    function test_adminFunctions_rejectNonAdmin() public {
        PolicyParams memory p = _launchPolicy();
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();

        address[3] memory outsiders = [keeper, guardian, stranger];
        for (uint256 i; i < outsiders.length; i++) {
            address who = outsiders[i];

            vm.prank(who);
            vm.expectRevert(_unauthorized(who, adminRole));
            vault.setPolicy(p);

            vm.prank(who);
            vm.expectRevert(_unauthorized(who, adminRole));
            vault.setFeeRecipient(newFeeSafe);

            vm.prank(who);
            vm.expectRevert(_unauthorized(who, adminRole));
            vault.setDepositCap(1e18);

            vm.prank(who);
            vm.expectRevert(_unauthorized(who, adminRole));
            vault.acceptValoremFee(true);

            vm.prank(who);
            vm.expectRevert(_unauthorized(who, adminRole));
            vault.unhaltWrites();

            vm.prank(who);
            vm.expectRevert(_unauthorized(who, adminRole));
            vault.setMaxPriceAge(2 days);
        }

        // Nothing moved.
        _assertPolicyIs(_launchPolicy(), "policy untouched by rejected calls");
        assertEq(vault.feeRecipient(), feeSafe, "fee recipient untouched");
        assertEq(vault.depositCap(), DEPOSIT_CAP, "deposit cap untouched");
        assertFalse(vault.valoremFeeAccepted(), "valorem fee still unaccepted");
        assertEq(vault.maxPriceAge(), MAX_PRICE_AGE, "price age untouched");
    }

    /*//////////////////////////////////////////////////////////////
                                 HALT
    //////////////////////////////////////////////////////////////*/

    function test_haltWrites_guardianOrAdmin_notStranger() public {
        bytes32 guardianRole = vault.GUARDIAN_ROLE();

        vm.prank(stranger);
        vm.expectRevert(_unauthorized(stranger, guardianRole));
        vault.haltWrites();

        // The keeper is a hot key: it may write, it may not pull the brake.
        vm.prank(keeper);
        vm.expectRevert(_unauthorized(keeper, guardianRole));
        vault.haltWrites();

        assertFalse(vault.writesHalted(), "still live");

        vm.prank(guardian);
        vault.haltWrites();
        assertTrue(vault.writesHalted(), "guardian can halt");

        vm.prank(admin);
        vault.unhaltWrites();
        assertFalse(vault.writesHalted());

        vm.prank(admin);
        vault.haltWrites();
        assertTrue(vault.writesHalted(), "admin can halt too");
    }

    /// @dev The guardian is a one-way switch on purpose: a compromised guardian can cost the
    ///      vault a week of premium, never restart writing on its own authority.
    function test_unhaltWrites_isAdminOnly_guardianCannotRestart() public {
        _deposit(alice, 20e18);

        vm.prank(guardian);
        vault.haltWrites();

        uint256 optionId = optionIds[RUNG_PICK];
        vm.prank(keeper);
        vm.expectRevert(Vault.WritesAreHalted.selector);
        vault.rollOpen(optionId, 5);

        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(guardian);
        vm.expectRevert(_unauthorized(guardian, adminRole));
        vault.unhaltWrites();
        assertTrue(vault.writesHalted(), "guardian could not restart writing");

        vm.prank(admin);
        vault.unhaltWrites();
        assertFalse(vault.writesHalted());

        vm.prank(keeper);
        vault.rollOpen(optionId, 5);
        assertEq(_phase(), 1, "writing resumed after the admin lifted the halt");
    }

    /// @dev THE ONE THAT MATTERS. A halt is an emergency brake on new risk, not a freeze on
    ///      depositors' money. Every exit path has to keep working through a halted cycle,
    ///      including the parts that need the keeper to have already gone away.
    function test_halt_blocksWritesOnly_fullCycleStillSettles() public {
        _deposit(alice, 20e18);
        _deposit(bob, 10e18);

        uint256 optionId = _rollOpen(10);
        OrderComponents memory c = _approveListing(optionId, 10, _okUnitPrice());
        _fill(c, 6); // 6 of 10 contracts sell: vault takes 6 * $1.90 = 11.40 USDG
        assertEq(usdg.balanceOf(address(vault)), 11_400_000, "premium in");

        vm.prank(guardian);
        vault.haltWrites();

        // --- deposits keep working in Listed --------------------------------------------
        uint256 carolShares = _deposit(carol, 10e18);
        assertEq(carolShares, 10e18, "deposit still open while halted");

        // --- the redeem queue keeps working ---------------------------------------------
        vm.prank(alice);
        uint256 aliceEpoch = vault.queueRedeem(20e18);
        assertEq(aliceEpoch, 1, "queued into epoch 1");
        assertEq(vault.queuedShares(), 20e18);

        // --- cancelling a live listing keeps working ------------------------------------
        vm.prank(keeper);
        vault.cancelListing(c);
        assertEq(vault.listingHash(), bytes32(0), "listing killed under halt");

        // --- but re-listing does not: that is new risk ----------------------------------
        OrderComponents memory relist = _buildOrder(optionId, 4, _okUnitPrice());
        vm.prank(keeper);
        vm.expectRevert(Vault.WritesAreHalted.selector);
        vault.approveListing(relist);

        // --- the permissionless book close keeps working --------------------------------
        _warpToExercise();
        vm.prank(stranger);
        vault.lockBook();
        assertEq(_phase(), 2, "locked by a stranger, halted");

        // --- and so does settlement ------------------------------------------------------
        _warpToExpiry();
        _rollClose();
        assertEq(_phase(), 0, "back to Idle, still halted");
        assertTrue(vault.writesHalted(), "the halt survived the roll");

        // THE ARITHMETIC, CHECKABLE BY HAND AGAINST THE FIXTURE.
        //
        // The premium is indexed by the CHECKPOINT inside Carol's deposit, not by the close:
        // `deposit` folds the accrual into `accUsdgPerShare` before minting, so Carol's shares
        // start from the fixed index and earn nothing from a week they did not back.
        //
        //   gross premium       = $2.00 x 6 filled contracts             = 12_000_000
        //   Overcall's 5%       = floor(2_000_000 * 500 / 10_000) * 6    =    600_000
        //   into the vault      = 12_000_000 - 600_000                   = 11_400_000
        //   protocol fee 5%     = 11_400_000 * 500 / 10_000              =    570_000
        //     (all premium, no assignment; accrued into `pendingFeeUsdg` by the checkpoint,
        //      swept at rollClose)
        //   net to depositors   = 11_400_000 - 570_000                   = 10_830_000
        //   supply AT THE CHECKPOINT = alice 20e18 + bob 10e18           =       30e18
        //     (Carol's 10e18 is minted after the index moves; Alice has not queued yet)
        //   indexDelta          = 10_830_000 * 1e27 / 30e18              = 361e12, exact
        //   alice (20e18)       = 20e18 * 361e12 / 1e27                  =  7_220_000
        //   bob   (10e18)       = 10e18 * 361e12 / 1e27                  =  3_610_000
        //   carol (10e18, after)=                                        =          0
        //   and 7_220_000 + 3_610_000 = 10_830_000 exactly: no dust.
        //
        // Alice then queues her whole 20e18 into escrow ON the vault. `queueRedeem` settles her
        // first, so her 7_220_000 stays in HER accrued balance rather than riding the shares
        // into escrow; the epoch's USDG leg is therefore 0 here. The close itself harvests
        // nothing: balance 11_400_000 == owed 10_830_000 + pending fee 570_000, so gross is
        // 0 and `_harvest` only sweeps the fee.
        assertEq(usdg.balanceOf(feeSafe), 570_000, "protocol fee taken during a halt");
        assertEq(vault.pendingFeeUsdg(), 0, "and the accrued fee really left at the close");

        // --- claimUsdg -------------------------------------------------------------------
        assertEq(vault.claimableUsdg(bob), 3_610_000, "bob's share of the net premium");
        // Carol deposited AFTER the premium landed, so the checkpoint fixed the index before
        // her shares existed and she earns none of it. A halt changes nothing about that.
        assertEq(vault.claimableUsdg(carol), 0, "a late depositor does not share the week");
        vm.prank(bob);
        uint256 bobClaimed = vault.claimUsdg();
        assertEq(bobClaimed, 3_610_000);
        assertEq(usdg.balanceOf(bob), 3_610_000, "claim paid under halt");

        // --- completeRedeem --------------------------------------------------------------
        // Alice's 7_220_000 was settled to HER account by `queueRedeem` before the shares
        // moved into escrow, because Carol's deposit had already checkpointed the index. So
        // the epoch's USDG leg is empty and the premium is hers to claim directly — the money
        // is in the same place either way, and nothing was stranded on the burned shares.
        assertEq(vault.claimableUsdg(alice), 7_220_000, "her accrual followed her, not the escrow");
        vm.prank(alice);
        (uint256 aliceAssets, uint256 aliceUsdg) = vault.completeRedeem(alice);
        assertEq(aliceAssets, 20e18, "collateral out under halt");
        assertEq(aliceUsdg, 0, "nothing was left accruing on the escrowed shares to pay out");
        assertEq(nvda.balanceOf(alice), 30e18, "alice whole again");

        vm.prank(alice);
        assertEq(vault.claimUsdg(), 7_220_000, "and she can still collect it after redeeming");
        assertEq(usdg.balanceOf(alice), 7_220_000, "premium paid under halt");

        // Every base unit of the net premium reached a holder, and none of it is stuck.
        assertEq(usdg.balanceOf(alice) + usdg.balanceOf(bob) + usdg.balanceOf(carol), 10_830_000, "net premium");
        assertEq(usdg.balanceOf(address(vault)), 0, "the vault kept nothing back");

        // --- instant redeem and withdraw --------------------------------------------------
        assertTrue(vault.canRedeemInstantly(), "flat and Idle, halt or no halt");
        vm.prank(bob);
        uint256 bobAssets = vault.redeem(10e18, bob, bob);
        assertEq(bobAssets, 10e18, "instant redeem under halt");

        vm.prank(carol);
        uint256 carolBurned = vault.withdraw(10e18, carol, carol);
        assertEq(carolBurned, 10e18, "withdraw under halt");
        assertEq(nvda.balanceOf(carol), 30e18, "carol whole again");

        // --- the only thing still blocked is a new write ----------------------------------
        uint256 nextOption = optionIds[RUNG_PICK];
        vm.prank(keeper);
        vm.expectRevert(Vault.WritesAreHalted.selector);
        vault.rollOpen(nextOption, 1);

        assertEq(vault.totalSupply(), 0, "every depositor got out of a halted vault");
    }

    /*//////////////////////////////////////////////////////////////
                            POLICY HARD CAPS
    //////////////////////////////////////////////////////////////*/

    /// @dev These caps are the only thing between a careless or captured admin Safe and a
    ///      policy that sells at-the-money calls or takes a 100% fee. They live in bytecode
    ///      precisely so governance cannot move them.
    function test_setPolicy_enforcesEveryHardCap() public {
        PolicyParams memory p;

        p = _launchPolicy();
        p.minOtmBps = 99;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Policy.MinOtmBelowFloor.selector, uint16(99), uint16(100)));
        vault.setPolicy(p);

        // TECHSPEC 10's named threat: admin sets minOtmBps = 0 and writes ATM calls against
        // depositors' collateral.
        p = _launchPolicy();
        p.minOtmBps = 0;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Policy.MinOtmBelowFloor.selector, uint16(0), uint16(100)));
        vault.setPolicy(p);

        p = _launchPolicy();
        p.maxOtmBps = 2_501;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Policy.MaxOtmAboveCeiling.selector, uint16(2_501), uint16(2_500)));
        vault.setPolicy(p);

        // Both fields legal on their own, but the band is upside down: no strike could pass.
        p = _launchPolicy();
        p.minOtmBps = 1_500;
        p.maxOtmBps = 1_200;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Policy.OtmBandInverted.selector, uint16(1_500), uint16(1_200)));
        vault.setPolicy(p);

        p = _launchPolicy();
        p.minPremiumBps = 9;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Policy.MinPremiumBelowFloor.selector, uint16(9), uint16(10)));
        vault.setPolicy(p);

        p = _launchPolicy();
        p.maxUtilizationBps = 10_001;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Policy.UtilizationAboveCeiling.selector, uint16(10_001), uint16(10_000)));
        vault.setPolicy(p);

        p = _launchPolicy();
        p.protocolFeeBps = 2_001;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Policy.ProtocolFeeAboveCeiling.selector, uint16(2_001), uint16(2_000)));
        vault.setPolicy(p);

        p = _launchPolicy();
        p.maxContractsCap = 0;
        vm.prank(admin);
        vm.expectRevert(Policy.ContractsCapZero.selector);
        vault.setPolicy(p);

        _assertPolicyIs(_launchPolicy(), "no rejected update leaked through");
    }

    /// @dev Exactly at the caps is legal; the caps are inclusive bounds, not exclusive.
    function test_setPolicy_acceptsTheBoundariesThemselves() public {
        PolicyParams memory p = PolicyParams({
            minOtmBps: 100,
            maxOtmBps: 2_500,
            minPremiumBps: 10,
            maxUtilizationBps: 10_000,
            protocolFeeBps: 2_000,
            maxContractsCap: 1
        });
        vm.prank(admin);
        vault.setPolicy(p);
        _assertPolicyIs(p, "boundary policy accepted");
    }

    /// @dev A legal update has to actually bite. Tighten the floor from 3% to 6% and the 231
    ///      rung the keeper wrote a moment ago stops being writable.
    function test_setPolicy_tighterBandRejectsAPreviouslyFineRung() public {
        _deposit(alice, 20e18);

        uint256 pick = optionIds[RUNG_PICK]; // 231.00, inside the launch band at $220 spot
        uint256 mid = optionIds[RUNG_MID]; // 236.00

        // Baseline: under the launch policy this rung writes.
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        vault.rollOpen(pick, 5);
        assertEq(vault.cycleStrikeUsdg(), 231_000_000, "231 is writable under the launch band");
        vm.revertToState(snap);
        assertEq(_phase(), 0, "back to a clean Idle vault");

        PolicyParams memory p = _launchPolicy();
        p.minOtmBps = 600; // floor moves to 220.00 * 1.06 = 233.20
        vm.prank(admin);
        vault.setPolicy(p);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(Policy.StrikeBelowBand.selector, uint256(231_000_000), uint256(233_200_000))
        );
        vault.rollOpen(pick, 5);

        // And the next rung up, which clears the new floor, still writes.
        vm.prank(keeper);
        vault.rollOpen(mid, 5);
        assertEq(vault.cycleStrikeUsdg(), 236_000_000, "236 clears the tightened floor");
        assertEq(_phase(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                          PRICE AGE HARD BOUNDS
    //////////////////////////////////////////////////////////////*/

    /// @dev `maxPriceAge` is mutable, so it is the same shape of hazard as the policy caps: an
    ///      admin who sets it to a year has silently switched the staleness check off and can
    ///      write a whole cycle's strike band off a price from the last bull market. The bounds
    ///      are in bytecode for exactly that reason, and the ceiling is the one that matters.
    function test_setMaxPriceAge_isBoundedInBytecode() public {
        uint32 floorAge = 1 hours;
        uint32 ceilAge = 7 days;

        // 0 and 365 days are the two that matter: the first would refuse every write, the second
        // is the silent switch-off of the staleness check.
        uint32[4] memory illegal = [uint32(0), uint32(1 hours - 1), uint32(7 days + 1), uint32(365 days)];
        for (uint256 i; i < illegal.length; i++) {
            vm.prank(admin);
            vm.expectRevert(abi.encodeWithSelector(Vault.PriceAgeOutOfBounds.selector, illegal[i], floorAge, ceilAge));
            vault.setMaxPriceAge(illegal[i]);
        }

        assertEq(vault.maxPriceAge(), MAX_PRICE_AGE, "no rejected setting leaked through");

        // Both bounds are inclusive.
        vm.prank(admin);
        vault.setMaxPriceAge(floorAge);
        assertEq(vault.maxPriceAge(), floorAge, "the floor itself is legal");

        vm.prank(admin);
        vault.setMaxPriceAge(ceilAge);
        assertEq(vault.maxPriceAge(), ceilAge, "the ceiling itself is legal");
    }

    /// @dev And a legal change has to actually bite, in both directions. The deploy config ships
    ///      6 hours against a us_equities_24/5 feed that goes ~52h quiet over a weekend, so this
    ///      setter is going to be used in anger; it must really move the gate the keeper hits.
    function test_setMaxPriceAge_movesTheStalenessGate() public {
        _deposit(alice, 20e18);
        uint256 id = optionIds[RUNG_PICK];

        // A price published 8 hours ago: stale under the fixture's 6 hours.
        uint256 publishedAt = block.timestamp - 8 hours;
        feed.setUpdatedAt(publishedAt);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Vault.StalePrice.selector, publishedAt, uint256(MAX_PRICE_AGE)));
        vault.rollOpen(id, 5);

        // Widen the window to a weekend's worth and the very same price is now acceptable.
        vm.prank(admin);
        vault.setMaxPriceAge(3 days);
        vm.prank(keeper);
        vault.rollOpen(id, 5);
        assertEq(_phase(), 1, "the widened window let the identical write through");
        assertEq(vault.contractsWritten(), 5, "and it really wrote, it did not just change phase");
    }

    /*//////////////////////////////////////////////////////////////
                            FEE RECIPIENT
    //////////////////////////////////////////////////////////////*/

    function test_setFeeRecipient_rejectsZero() public {
        vm.prank(admin);
        vm.expectRevert(Vault.ZeroAddr.selector);
        vault.setFeeRecipient(address(0));
        assertEq(vault.feeRecipient(), feeSafe, "unchanged");
    }

    /// @dev Burning the fee to address(0) is not the hazard; silently continuing to pay a
    ///      rotated-out Safe is. Prove the change routes the NEXT harvest and nothing else.
    ///
    ///      THE ARITHMETIC, PER WEEK, CHECKABLE BY HAND AGAINST THE FIXTURE:
    ///        gross premium     = $2.00 x 10 contracts                = 20_000_000
    ///        Overcall's 5%     = floor(2_000_000 * 500 / 10_000) * 10 =  1_000_000  (per contract)
    ///        into the vault    = 20_000_000 - 1_000_000              = 19_000_000
    ///        protocol fee 5%   = 19_000_000 * 500 / 10_000           =    950_000  (premium only)
    ///        net to depositors = 19_000_000 - 950_000                = 18_050_000
    ///      Alice is the only holder, so she takes the whole net both weeks: 2 x 18_050_000
    ///      (18_050_000 * 1e27 / 20e18 = 902_500e9 indexes exactly, so no dust either week).
    function test_setFeeRecipient_routesTheNextFee() public {
        _deposit(alice, 20e18);

        _fullCycleOtm(10, _okUnitPrice());
        assertEq(usdg.balanceOf(feeSafe), 950_000, "5% of the 19 USDG of premium the vault harvested");
        assertEq(vault.claimableUsdg(alice), 18_050_000, "week 1 net to the only depositor");

        vm.prank(admin);
        vault.setFeeRecipient(newFeeSafe);
        assertEq(vault.feeRecipient(), newFeeSafe);

        _nextCycle();
        _fullCycleOtm(10, _okUnitPrice());

        assertEq(usdg.balanceOf(feeSafe), 950_000, "the old safe received nothing more");
        assertEq(usdg.balanceOf(newFeeSafe), 950_000, "the new safe took the second week");
        assertEq(usdg.balanceOf(overcallFee), 2_000_000, "Overcall took 5% both weeks regardless");

        // The rotation moved WHO is paid, never HOW MUCH. Depositors are untouched by it, and
        // the fee is not double-charged to cover the new Safe.
        assertEq(vault.claimableUsdg(alice), 36_100_000, "two identical weeks of net premium");
        vm.prank(alice);
        assertEq(vault.claimUsdg(), 36_100_000, "and it is all actually payable");
        assertEq(usdg.balanceOf(address(vault)), 0, "nothing stranded on the vault after two weeks");
        assertEq(vault.totalAssets(), 20e18, "and the rotation never touched the collateral");
    }

    /*//////////////////////////////////////////////////////////////
                           VALOREM ENGINE FEE
    //////////////////////////////////////////////////////////////*/

    /// @dev Valorem's 15 bps notional fee is a big slice of a weekly OTM premium, so the vault
    ///      refuses to write while it is switched on. Acceptance is governance's call, and it
    ///      has to be a real one: the switch must move the vault from "refuses" to "writes".
    ///
    ///      REGRESSION GUARD. The gate lives in `ValoremLib.write` (shared by `rollOpen` and
    ///      `writeMore`), which is handed `feeAccepted` and reverts only on
    ///      `feesEnabled() && !feeAccepted`. An earlier draft had the adapter revert on
    ///      `clear.feesEnabled()` alone, which made the acceptance decorative: it changed only
    ///      which error came back. Both halves of the switch are asserted below.
    function test_acceptValoremFee_gatesWritingWhileEngineFeesAreOn() public {
        _deposit(alice, 20e18);
        uint256 optionId = optionIds[RUNG_PICK];

        mockClear.setFeesEnabled(true);

        // Unaccepted: the vault-level gate refuses, and it names the fee it refused over.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Vault.ValoremFeeNotAccepted.selector, uint8(15)));
        vault.rollOpen(optionId, 5);

        vm.prank(admin);
        vault.acceptValoremFee(true);
        assertTrue(vault.valoremFeeAccepted(), "governance accepted the engine fee");

        // Accepted: the write goes through with the engine fee still switched on. Neither the
        // vault gate nor the adapter's own guard may fire once governance has said yes.
        vm.prank(keeper);
        vault.rollOpen(optionId, 5);
        assertEq(vault.contractsWritten(), 5, "the acceptance switch actually lets the write land");
        assertEq(_phase(), 1, "and the vault moved to Listed");

        // Turn the engine fee back off and the next cycle writes with acceptance irrelevant.
        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();
        _rollClose();
        _nextCycle();
        mockClear.setFeesEnabled(false);
        vm.prank(admin);
        vault.acceptValoremFee(false);
        vm.prank(keeper);
        vault.rollOpen(optionIds[RUNG_PICK], 5);
        assertEq(_phase(), 1, "writes fine once Valorem's fee is off");
    }

    /// @dev The other direction: revoking acceptance re-arms the gate.
    function test_acceptValoremFee_revocationBlocksWritingAgain() public {
        _deposit(alice, 20e18);
        uint256 optionId = optionIds[RUNG_PICK];

        vm.prank(admin);
        vault.acceptValoremFee(true);
        vm.prank(admin);
        vault.acceptValoremFee(false);
        assertFalse(vault.valoremFeeAccepted());

        mockClear.setFeeBps(20);
        mockClear.setFeesEnabled(true);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Vault.ValoremFeeNotAccepted.selector, uint8(20)));
        vault.rollOpen(optionId, 5);
    }

    /*//////////////////////////////////////////////////////////////
                          UI MULTIPLIER SAFETY
    //////////////////////////////////////////////////////////////*/

    /// @dev ERC-8056's `uiMultiplier()` is how a Stock Token expresses a split or a dividend
    ///      WITHOUT touching balances. If any share maths ever read it, a 2:1 split would
    ///      double or halve everyone's redemption overnight. It must be display-only.
    function test_uiMultiplier_neverMovesShareMathsMidCycle() public {
        _deposit(alice, 20e18);
        _deposit(bob, 5e18);

        _fullCycleOtm(10, _okUnitPrice()); // give the Distributor a real balance to quote

        // Open a second cycle and fill it, so the change lands with collateral locked, USDG
        // claimable, and the vault mid-flight.
        _nextCycle();
        uint256 optionId = _rollOpen(10);
        OrderComponents memory c = _approveListing(optionId, 10, _okUnitPrice());
        _fill(c, 10);
        assertEq(_phase(), 1, "mid-cycle");

        uint256 sharesFor1 = vault.convertToShares(1e18);
        uint256 assetsFor1 = vault.convertToAssets(1e18);
        uint256 assetsFor7 = vault.convertToAssets(7e18);
        uint256 total = vault.totalAssets();
        uint256 locked = vault.lockedAssets();
        uint256 idle = vault.idleAssets();
        uint256 aliceUsdg = vault.claimableUsdg(alice);
        uint256 bobUsdg = vault.claimableUsdg(bob);
        uint256 previewFor3 = vault.previewDeposit(3e18);
        assertGt(aliceUsdg, 0, "there is USDG on the books to misprice");
        assertEq(vault.uiMultiplier(), 1e18, "starts at 1.0");

        // A 2:1 split, expressed the ERC-8056 way.
        nvda.setUiMultiplier(2e18);
        assertEq(vault.uiMultiplier(), 2e18, "the vault reports the token's new multiplier");
        assertEq(vault.convertToShares(1e18), sharesFor1, "convertToShares unmoved");
        assertEq(vault.convertToAssets(1e18), assetsFor1, "convertToAssets unmoved");
        assertEq(vault.convertToAssets(7e18), assetsFor7, "convertToAssets unmoved at size");
        assertEq(vault.totalAssets(), total, "totalAssets unmoved");
        assertEq(vault.lockedAssets(), locked, "lockedAssets unmoved");
        assertEq(vault.idleAssets(), idle, "idleAssets unmoved");
        assertEq(vault.claimableUsdg(alice), aliceUsdg, "claimableUsdg unmoved");
        assertEq(vault.claimableUsdg(bob), bobUsdg, "claimableUsdg unmoved");
        assertEq(vault.previewDeposit(3e18), previewFor3, "previewDeposit unmoved");

        // And a reverse split, which is the direction that would steal from depositors.
        nvda.setUiMultiplier(5e17);
        assertEq(vault.uiMultiplier(), 5e17, "multiplier down");
        assertEq(vault.convertToShares(1e18), sharesFor1, "convertToShares unmoved");
        assertEq(vault.convertToAssets(1e18), assetsFor1, "convertToAssets unmoved");
        assertEq(vault.totalAssets(), total, "totalAssets unmoved");
        assertEq(vault.claimableUsdg(alice), aliceUsdg, "claimableUsdg unmoved");
        assertEq(vault.previewDeposit(3e18), previewFor3, "previewDeposit unmoved");

        // The two degenerate values. A multiplier of 0 is what a naive `assets * m / 1e18`
        // would turn into a total wipeout, and uint256 max is what would overflow it. Both are
        // legal ERC-8056 values for a token to report, so both have to be inert here.
        nvda.setUiMultiplier(0);
        assertEq(vault.uiMultiplier(), 0, "a zero multiplier is reported, not swallowed");
        assertEq(vault.convertToAssets(1e18), assetsFor1, "convertToAssets survives m = 0");
        assertEq(vault.totalAssets(), total, "totalAssets survives m = 0");
        assertEq(vault.claimableUsdg(alice), aliceUsdg, "claimableUsdg survives m = 0");

        nvda.setUiMultiplier(type(uint256).max);
        assertEq(vault.uiMultiplier(), type(uint256).max, "max multiplier reported verbatim");
        assertEq(vault.convertToAssets(1e18), assetsFor1, "convertToAssets survives m = max");
        assertEq(vault.totalAssets(), total, "totalAssets survives m = max");
        assertEq(vault.claimableUsdg(alice), aliceUsdg, "claimableUsdg survives m = max");

        nvda.setUiMultiplier(5e17);

        // A real deposit taken while the multiplier is skewed mints exactly what it would
        // have minted at 1.0.
        uint256 carolShares = _deposit(carol, 3e18);
        assertEq(carolShares, previewFor3, "a deposit under a skewed multiplier mints the same");

        // Close the cycle out under the skewed multiplier and everyone still gets raw units.
        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();
        _rollClose();

        nvda.setUiMultiplier(1e18);
        vm.prank(carol);
        uint256 carolOut = vault.redeem(carolShares, carol, carol);
        assertEq(carolOut, 3e18, "3 tokens in, 3 tokens out, multiplier irrelevant");
    }

    /// @dev Unbounded on purpose. The two values a naive `x * uiMultiplier / 1e18` would blow up
    ///      on are exactly the ones a narrow bound excludes: 0 (every balance reads as nothing)
    ///      and type(uint256).max (every conversion overflows). If share maths ever touched the
    ///      multiplier, the full range is where it would show.
    function test_uiMultiplier_fuzzedValueNeverMovesShareMaths(uint256 m) public {
        // A vault with something to misprice: collateral locked in Valorem, an unsold short,
        // and real USDG already indexed to two different holders.
        _deposit(alice, 20e18);
        _deposit(bob, 5e18);
        _fullCycleOtm(10, _okUnitPrice());
        _nextCycle();
        uint256 optionId = _rollOpen(10);
        _fill(_approveListing(optionId, 10, _okUnitPrice()), 10);

        uint256 sharesFor1 = vault.convertToShares(1e18);
        uint256 assetsFor1 = vault.convertToAssets(1e18);
        uint256 total = vault.totalAssets();
        uint256 locked = vault.lockedAssets();
        uint256 previewFor3 = vault.previewDeposit(3e18);
        uint256 aliceUsdg = vault.claimableUsdg(alice);
        assertGt(locked, 0, "collateral really is locked");
        assertGt(aliceUsdg, 0, "there really is USDG to misprice");

        nvda.setUiMultiplier(m);

        assertEq(vault.uiMultiplier(), m, "reported verbatim");
        assertEq(vault.convertToShares(1e18), sharesFor1, "shares unmoved");
        assertEq(vault.convertToAssets(1e18), assetsFor1, "assets unmoved");
        assertEq(vault.totalAssets(), total, "NAV unmoved");
        assertEq(vault.lockedAssets(), locked, "locked collateral unmoved");
        assertEq(vault.previewDeposit(3e18), previewFor3, "previewDeposit unmoved");
        assertEq(vault.claimableUsdg(alice), aliceUsdg, "claimableUsdg unmoved");
    }

    /*//////////////////////////////////////////////////////////////
                             ISSUER FREEZE
    //////////////////////////////////////////////////////////////*/

    /// @dev Robinhood Assets (Jersey) Limited can freeze the Stock Token. THE VAULT CANNOT CODE
    ///      AROUND THIS: every asset-denominated path is a transfer of a token that now
    ///      reverts, so deposits and payouts fail and there is no clever alternative. What the
    ///      vault CAN promise is that the USDG side and the queue stay open, so premium already
    ///      earned is still claimable and depositors can get in line for the moment it lifts.
    function test_issuerFreeze_stopsAssetFlowsButNotUsdgOrTheQueue() public {
        _deposit(alice, 20e18);
        _deposit(bob, 10e18);
        _fullCycleOtm(10, _okUnitPrice());

        uint256 aliceUsdg = vault.claimableUsdg(alice);
        uint256 bobUsdg = vault.claimableUsdg(bob);
        // net 18_050_000 over 30e18 shares: indexDelta = floor(18_050_000 * 1e27 / 30e18)
        // = 601_666_666_666_666, which credits 18_049_999 and carries 1 base unit as dust.
        //   alice = floor(20e18 * 601_666_666_666_666 / 1e27) = 12_033_333
        //   bob   = floor(10e18 * 601_666_666_666_666 / 1e27) =  6_016_666
        assertEq(aliceUsdg, 12_033_333, "alice's two thirds of the 18.05 net, floored");
        assertEq(bobUsdg, 6_016_666, "bob's third, floored");

        nvda.pause();

        // --- deposits fail, loudly, with the issuer's own error --------------------------
        vm.prank(carol);
        nvda.approve(address(vault), 5e18); // approvals are not transfers; still fine
        vm.prank(carol);
        vm.expectRevert(MockStockToken.TokenPaused.selector);
        vault.deposit(5e18, carol);

        // --- asset payouts fail ----------------------------------------------------------
        assertTrue(vault.canRedeemInstantly(), "the vault believes it is flat and Idle");
        vm.prank(alice);
        vm.expectRevert(MockStockToken.TokenPaused.selector);
        vault.redeem(1e18, alice, alice);

        vm.prank(bob);
        vm.expectRevert(MockStockToken.TokenPaused.selector);
        vault.withdraw(1e18, bob, bob);

        // --- USDG is a different token and keeps moving ----------------------------------
        vm.prank(alice);
        uint256 claimed = vault.claimUsdg();
        assertEq(claimed, aliceUsdg, "premium still claimable through a freeze");
        assertEq(usdg.balanceOf(alice), aliceUsdg);

        // --- and the queue still takes commitments ---------------------------------------
        // queueRedeem only moves vault shares, so it is unaffected; the failure surfaces later
        // at the payout, which is the honest place for it.
        vm.prank(bob);
        vault.queueRedeem(10e18);
        assertEq(vault.queuedSharesOf(bob), 10e18, "queued while frozen");
        assertEq(vault.balanceOf(address(vault)), 10e18, "shares escrowed on the vault");

        // --- share maths are untouched by the freeze -------------------------------------
        assertEq(vault.totalAssets(), 30e18, "NAV still reads the frozen balance");

        // --- unfreeze and everything recovers, same numbers ------------------------------
        nvda.unpause();

        uint256 carolShares = _deposit(carol, 5e18);
        assertEq(carolShares, 5e18, "deposits work again");

        vm.prank(alice);
        uint256 out = vault.redeem(1e18, alice, alice);
        assertEq(out, 1e18, "redemption works again");
        assertEq(nvda.balanceOf(alice), 10e18 + 1e18, "alice has her 10 left over plus the 1");

        assertEq(vault.claimableUsdg(bob), bobUsdg, "bob's premium survived the freeze");
        vm.prank(bob);
        assertEq(vault.claimUsdg(), bobUsdg, "and is still claimable");
    }

    /*//////////////////////////////////////////////////////////////
                          INTERFACES AND HOOKS
    //////////////////////////////////////////////////////////////*/

    function test_supportsInterface() public view {
        assertTrue(vault.supportsInterface(0x4e2312e0), "ERC1155Receiver");
        assertTrue(vault.supportsInterface(0x1626ba7e), "EIP-1271");
        assertTrue(vault.supportsInterface(type(IAccessControl).interfaceId), "IAccessControl");
        assertTrue(vault.supportsInterface(0x01ffc9a7), "ERC-165 itself");

        assertFalse(vault.supportsInterface(0xffffffff), "the ERC-165 invalid id");
        assertFalse(vault.supportsInterface(0x36372b07), "ERC-20 is not advertised");
    }

    /// @dev Valorem pushes the option tokens and the claim NFT straight to the writer, so the
    ///      hooks must accept from the clearinghouse. Accepting from anyone would turn the
    ///      vault into a dumping ground for unrelated ERC-1155s.
    function test_erc1155Hooks_acceptOnlyFromTheClearinghouse() public {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = optionIds[RUNG_PICK];
        amounts[0] = 1;

        vm.prank(address(clear));
        assertEq(vault.onERC1155Received(keeper, address(0), ids[0], 1, ""), ERC1155_RECEIVED, "accepts the engine");

        vm.prank(address(clear));
        assertEq(
            vault.onERC1155BatchReceived(keeper, address(0), ids, amounts, ""),
            ERC1155_BATCH_RECEIVED,
            "accepts a batch from the engine"
        );

        // `address(nvda)` is in here on purpose: the underlying is the one address a lazy
        // "is this one of our contracts?" check would wave through.
        address[4] memory impostors = [stranger, keeper, address(seaport), address(nvda)];
        for (uint256 i; i < impostors.length; i++) {
            vm.prank(impostors[i]);
            assertEq(vault.onERC1155Received(impostors[i], impostors[i], 1, 1, ""), REJECT, "rejects a stranger");

            vm.prank(impostors[i]);
            assertEq(
                vault.onERC1155BatchReceived(impostors[i], impostors[i], ids, amounts, ""),
                REJECT,
                "rejects a stranger's batch"
            );
        }
    }
}
