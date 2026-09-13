// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {Vault} from "../../src/Vault.sol";
import {Policy} from "../../src/Policy.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {OrderComponents} from "../../src/interfaces/ISeaport.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice The phase machine and every gate on `rollOpen` / `lockBook` / `rollClose`.
/// @dev Tasks T-04 (phase transitions + wrong-phase reverts), F-02 (rollOpen writes exact
///      contracts, claim NFT in vault), F-10 (wrong optionId reverts), F-13 (guardian
///      rollClose after expiry + 1h with the keeper dead).
///
///      The band arithmetic these tests lean on, stated once:
///        spot 220.000000, launch policy 300..1200 bps OTM
///        => strike window [226_600_000, 246_400_000]
///        => rung 0 (226.00) is BELOW, rung 4 (246.00) is ABOVE, rung 1 (231.00) is the pick.
contract VaultRollTest is BaseTest {
    /// @dev Somebody with no role at all. Used for the permissionless paths and, in
    ///      {test_rollClose_anyoneAfterGracePeriod}, to stand in for "the keeper is dead".
    address internal passerby = makeAddr("passerby");

    uint256 internal constant BAND_LO = 226_600_000; // 220.00 * 1.03
    uint256 internal constant BAND_HI = 246_400_000; // 220.00 * 1.12

    /// @dev Mirrors {Vault.RollOpen} so the emission can be pinned field by field. An
    ///      off-chain monitor sees nothing else, so a silently wrong argument here is a
    ///      silently wrong dashboard.
    event RollOpen(uint32 indexed cycleNumber, uint256 indexed optionId, uint112 contractsCount, uint256 strikeUsdg);

    /// @dev MockFeed stamps `updatedAt` on every `setAnswer`. Any test that warps more than
    ///      MAX_PRICE_AGE forward and then wants to write must re-stamp it, otherwise the
    ///      staleness gate fires instead of the gate under test.
    function _refreshFeed() internal {
        feed.setAnswer(SPOT_FEED);
    }

    /*//////////////////////////////////////////////////////////////
                      ROLLOPEN: THE HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev F-02. The whole point of a write: n contracts minted to the vault, one claim NFT
    ///      held by the vault (Valorem's `redeem` reverts for anyone who is not the claim
    ///      owner, so if the NFT ever landed elsewhere the collateral would be unrecoverable),
    ///      and exactly n lots of collateral moved into the clearinghouse.
    function test_rollOpen_writesExactContractsAndHoldsTheClaim() public {
        _deposit(alice, 20e18);

        uint256 optionId = optionIds[RUNG_PICK];

        vm.expectEmit(true, true, true, true, address(vault));
        emit RollOpen(1, optionId, 10, 231_000_000);
        vm.prank(keeper);
        vault.rollOpen(optionId, 10);

        assertEq(clear.balanceOf(address(vault), optionId), 10, "10 option tokens minted to the vault");

        uint256 key = vault.claimKey();
        assertTrue(key != 0, "a claim key was recorded");
        assertTrue(key != optionId, "the claim NFT is a different id from the option type");
        assertEq(clear.balanceOf(address(vault), key), 1, "the vault owns the claim NFT");

        assertEq(vault.optionId(), optionId, "optionId recorded");
        assertEq(vault.contractsWritten(), 10, "contractsWritten");
        assertEq(vault.contractsSold(), 0, "nothing sold yet");
        assertEq(vault.lockedAssets(), 10 * LOT, "10 lots locked behind the claim");

        // Collateral moved, it did not evaporate.
        assertEq(nvda.balanceOf(address(vault)), 10e18, "10 NVDA left idle");
        assertEq(nvda.balanceOf(address(clear)), 10e18, "10 NVDA sit in the clearinghouse");
        assertEq(vault.idleAssets(), 10e18, "idle is what is left over");

        assertEq(_phase(), 1, "Idle -> Listed");
    }

    /// @dev The cycle snapshot is taken at `rollOpen` and held locally, because the registry
    ///      rolls forward to the next cycle while this one is still settling.
    function test_rollOpen_snapshotsTheCycle() public {
        _deposit(alice, 20e18);
        _rollOpen(5);

        assertEq(vault.cycleNumber(), 1, "registry cycle 1");
        assertEq(vault.cycleExerciseTs(), exerciseTs, "exercise timestamp snapshotted");
        assertEq(vault.cycleExpiryTs(), expiryTs, "expiry timestamp snapshotted");
        assertEq(vault.cycleStrikeUsdg(), 231_000_000, "the 231.00 rung");
    }

    /// @dev The listing budget is three signed orders per cycle. Asserting it is zero on a
    ///      virgin vault proves nothing — it starts at zero. Spend it first, then roll into a
    ///      new cycle: if `rollOpen` failed to reset it, week two would open with a spent
    ///      budget and the keeper could never list at all.
    function test_rollOpen_resetsTheSpentListingBudget() public {
        _deposit(alice, 20e18);
        uint256 id = _rollOpen(5);

        // Only one order may be live at a time, so cancel between approvals.
        OrderComponents memory c1 = _approveListing(id, 5, _okUnitPrice());
        vm.prank(keeper);
        vault.cancelListing(c1);
        OrderComponents memory c2 = _approveListing(id, 5, _okUnitPrice() + 1);
        vm.prank(keeper);
        vault.cancelListing(c2);
        _approveListing(id, 5, _okUnitPrice() + 2);
        assertEq(vault.listingsThisCycle(), 3, "budget fully spent this cycle");

        _warpToExpiry();
        _rollClose();

        exerciseTs = uint40(block.timestamp + 6 days);
        expiryTs = uint40(block.timestamp + 7 days);
        _installCycle();
        _refreshFeed();

        _rollOpen(5);
        assertEq(vault.listingsThisCycle(), 0, "a new cycle starts with a full budget");
    }

    /// @dev Writing moves collateral into Valorem; it must not move the share price by a wei.
    ///      If `totalAssets` dipped at `rollOpen`, every depositor would be diluted the moment
    ///      the keeper did its job.
    function test_rollOpen_doesNotChangeTotalAssets() public {
        _deposit(alice, 20e18);
        _deposit(bob, 10e18);

        uint256 assetsBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();
        uint256 priceBefore = vault.convertToAssets(1e18);

        _rollOpen(20);

        assertEq(vault.totalAssets(), assetsBefore, "collateral moved, not lost");
        assertEq(vault.totalAssets(), 30e18, "idle 10 + locked 20");
        assertEq(vault.totalSupply(), supplyBefore, "no shares minted or burned");
        assertEq(vault.convertToAssets(1e18), priceBefore, "share price unmoved");
    }

    /*//////////////////////////////////////////////////////////////
                       ROLLOPEN: ACCESS + PHASE
    //////////////////////////////////////////////////////////////*/

    function test_rollOpen_isKeeperOnly() public {
        _deposit(alice, 20e18);
        uint256 id = optionIds[RUNG_PICK];
        bytes32 keeperRole = vault.KEEPER_ROLE();

        address[3] memory outsiders = [alice, admin, guardian];
        for (uint256 i; i < outsiders.length; i++) {
            vm.prank(outsiders[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector, outsiders[i], keeperRole
                )
            );
            vault.rollOpen(id, 5);
        }

        // And the keeper can.
        vm.prank(keeper);
        vault.rollOpen(id, 5);
        assertEq(_phase(), 1);
    }

    function test_rollOpen_revertsWrongPhaseFromListed() public {
        _deposit(alice, 20e18);
        uint256 id = _rollOpen(5);
        assertEq(_phase(), 1);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Vault.WrongPhase.selector, Vault.Phase.Idle, Vault.Phase.Listed));
        vault.rollOpen(id, 5);
    }

    function test_rollOpen_revertsWrongPhaseFromExercisable() public {
        _deposit(alice, 20e18);
        uint256 id = _rollOpen(5);

        _warpToExercise();
        vault.lockBook();
        assertEq(_phase(), 2);

        // The phase check runs before the registry's write-deadline check, so this is
        // WrongPhase and not WritingNotOpen even though the deadline has also passed.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Vault.WrongPhase.selector, Vault.Phase.Idle, Vault.Phase.Exercisable));
        vault.rollOpen(id, 5);
    }

    /*//////////////////////////////////////////////////////////////
                            ROLLOPEN: HALT
    //////////////////////////////////////////////////////////////*/

    function test_rollOpen_revertsWhenWritesHalted() public {
        _deposit(alice, 20e18);
        uint256 id = optionIds[RUNG_PICK];

        vm.prank(guardian);
        vault.haltWrites();
        assertTrue(vault.writesHalted());

        vm.prank(keeper);
        vm.expectRevert(Vault.WritesAreHalted.selector);
        vault.rollOpen(id, 5);

        // The guardian can stop, only the admin can start again.
        vm.prank(admin);
        vault.unhaltWrites();

        vm.prank(keeper);
        vault.rollOpen(id, 5);
        assertEq(_phase(), 1, "writing resumes once the halt is lifted");
    }

    /// @dev A halt must never trap an open cycle. If it blocked `lockBook` or `rollClose` the
    ///      guardian could freeze depositors' collateral inside Valorem indefinitely, which is
    ///      precisely the outcome the halt exists to prevent.
    function test_halt_doesNotBlockLockBookOrRollClose() public {
        _deposit(alice, 20e18);
        _rollOpen(5);

        vm.prank(guardian);
        vault.haltWrites();

        _warpToExercise();
        vm.prank(passerby);
        vault.lockBook();
        assertEq(_phase(), 2, "lockBook still runs under a halt");

        _warpToExpiry();
        _rollClose();
        assertEq(_phase(), 0, "rollClose still runs under a halt");
        assertTrue(vault.writesHalted(), "and the halt is still in force");
        assertEq(nvda.balanceOf(address(vault)), 20e18, "collateral came home anyway");
    }

    /*//////////////////////////////////////////////////////////////
                        ROLLOPEN: OPTION IDENTITY
    //////////////////////////////////////////////////////////////*/

    /// @dev F-10. A keeper may only write a rung Overcall approved for the live cycle. An
    ///      arbitrary Valorem option type — even one with the right assets, lot size and
    ///      timings — has never been through Overcall's review and is refused.
    function test_rollOpen_revertsOptionNotApproved() public {
        _deposit(alice, 20e18);

        // Same assets and timings, a strike that is inside the band but was never registered.
        uint256 stray =
            clear.newOptionType(address(nvda), uint96(LOT), address(usdg), 233_000_000, exerciseTs, expiryTs);
        assertFalse(registry.isApproved(stray), "the registry has never heard of it");

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Vault.OptionNotApproved.selector, stray));
        vault.rollOpen(stray, 5);

        assertEq(_phase(), 0, "still Idle");
        assertEq(vault.claimKey(), 0, "nothing was written");
    }

    /*//////////////////////////////////////////////////////////////
                         ROLLOPEN: STRIKE BAND
    //////////////////////////////////////////////////////////////*/

    /// @dev The 226.00 rung is 2.73% OTM at a spot of 220, just under the 3% floor. Selling it
    ///      is selling too close to the money, which is the exact thing the floor exists for.
    function test_rollOpen_revertsStrikeBelowBand() public {
        _deposit(alice, 20e18);
        uint256 id = optionIds[RUNG_BELOW_BAND];

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Policy.StrikeBelowBand.selector, uint256(226_000_000), BAND_LO));
        vault.rollOpen(id, 5);
    }

    /// @dev The 246.00 rung is 11.82% OTM, which is inside 12%... but the ceiling is computed
    ///      off spot, giving 246.40, and 246.00 clears it. Guard the arithmetic, not the
    ///      intuition: assert the rung the fixture calls ABOVE really is refused.
    function test_rollOpen_revertsStrikeAboveBand() public {
        _deposit(alice, 20e18);
        uint256 id = optionIds[RUNG_ABOVE_BAND];

        // 246.00 <= 246.40, so with the launch band this rung is actually legal. Push spot
        // down a dollar and the ceiling moves to 245.28, which puts the rung out of reach.
        feed.setAnswer(219_00000000);
        uint256 hi = (219_000_000 * 11_200) / 10_000;

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Policy.StrikeAboveBand.selector, uint256(246_000_000), hi));
        vault.rollOpen(id, 5);
    }

    /// @dev Both band edges in one place, so the ladder's own claim is pinned by arithmetic
    ///      rather than by a comment. At a $220 spot the window is [226.60, 246.40]: the 226
    ///      rung is 60 cents short of the floor, and the 246 rung — which the fixture labels
    ///      RUNG_ABOVE_BAND — actually clears the ceiling by 40 cents and is LEGAL. Only a
    ///      lower spot pushes it out. Worth a test rather than a footnote: a keeper told
    ///      "246 is always rejected" would build the wrong runbook.
    function test_rollOpen_bandEdgesAtFixtureSpot() public {
        _deposit(alice, 25e18);
        assertEq(vault.spotUsdg(), SPOT_USDG);

        uint256 below = optionIds[RUNG_BELOW_BAND];
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Policy.StrikeBelowBand.selector, uint256(226_000_000), BAND_LO));
        vault.rollOpen(below, 5);

        assertTrue(231_000_000 >= BAND_LO && 231_000_000 <= BAND_HI, "231.00 sits inside [226.60, 246.40]");
        assertTrue(246_000_000 <= BAND_HI, "246.00 is inside the launch band at a 220 spot");

        // The top rung writes at this spot.
        uint256 top = optionIds[RUNG_ABOVE_BAND];
        vm.prank(keeper);
        vault.rollOpen(top, 5);
        assertEq(vault.cycleStrikeUsdg(), 246_000_000, "the 246.00 rung is writable at 220 spot");
    }

    /*//////////////////////////////////////////////////////////////
                          ROLLOPEN: POSITION SIZE
    //////////////////////////////////////////////////////////////*/

    /// @dev 25 NVDA idle at a 95% utilization cap allows 23 whole lots. Asking for 24 is 96%
    ///      of idle and must be refused: the slack is what lets a queued redeemer out.
    function test_rollOpen_revertsAboveUtilization() public {
        _deposit(alice, 25e18);
        uint256 id = optionIds[RUNG_PICK];
        assertEq(vault.idleAssets(), 25e18);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Policy.ContractsAboveUtilization.selector, uint256(24), uint256(23)));
        vault.rollOpen(id, 24);
    }

    /// @dev 20 NVDA idle, 95% cap, 19 lots is exactly the ceiling and must go through.
    function test_rollOpen_succeedsAtExactUtilizationCeiling() public {
        _deposit(alice, 20e18);
        uint256 id = optionIds[RUNG_PICK];

        vm.prank(keeper);
        vault.rollOpen(id, 19);

        assertEq(vault.contractsWritten(), 19, "95% of idle is writable");
        assertEq(vault.lockedAssets(), 19e18);
        assertEq(vault.idleAssets(), 1e18, "5% left behind");
        assertEq(vault.totalAssets(), 20e18, "still 20 NVDA of NAV");
    }

    /// @dev THE HAZARD: `idleAssets()` is the raw balance MINUS `reservedAssets`, and the
    ///      utilization gate reads `idleAssets()`. Assets already set aside for a settled
    ///      redeemer must not be writable, or the redeemer's NVDA would end up collateralising
    ///      somebody else's short and `completeRedeem` would revert for want of balance.
    ///
    ///      The arithmetic, by hand: alice and bob deposit 10e18 each (20e18 supply, 1:1), the
    ///      keeper writes 10 lots, alice queues her whole 10e18 of shares. At settlement the
    ///      supply is still 20e18 and the balance is back to 20e18, so
    ///        payoutAssets = idle(20e18) * queued(10e18) / supply(20e18) = 10e18
    ///      and 10e18 is reserved out of a 20e18 balance.
    function test_rollOpen_cannotWriteAgainstAssetsReservedForARedeemer() public {
        _deposit(alice, 10e18);
        _deposit(bob, 10e18);
        _rollOpen(10);

        // Alice commits her whole position to the next settlement.
        vm.prank(alice);
        vault.queueRedeem(10e18);

        _warpToExpiry();
        _rollClose();

        //   balance 20e18, supply 20e18, queued 10e18
        //   payoutAssets = idle(20e18) * q(10e18) / supply(20e18) = 10e18
        //   reservedAssets = 10e18  =>  idleAssets() = 20e18 - 10e18 = 10e18
        assertEq(nvda.balanceOf(address(vault)), 20e18, "all collateral is physically back");
        assertEq(vault.reservedAssets(), 10e18, "half of it is spoken for");
        assertEq(vault.idleAssets(), 10e18, "only the unreserved half is writable");
        assertEq(vault.totalAssets(), 10e18, "NAV is bob's half alone");

        exerciseTs = uint40(block.timestamp + 6 days);
        expiryTs = uint40(block.timestamp + 7 days);
        _installCycle();
        _refreshFeed();

        // 10e18 idle at 95% = 9.5 lots -> 9. Ten lots would be writable off the RAW balance
        // of 20e18 (19 lots), so this revert is the whole point of the test.
        // The counterfactual, asserted rather than asserted-in-a-comment: off the RAW balance
        // the gate would have allowed 19 lots, so 10 would have sailed through.
        assertEq((nvda.balanceOf(address(vault)) * 9_500) / 10_000 / LOT, 19, "raw balance would allow 19");

        uint256 id = optionIds[RUNG_PICK];
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Policy.ContractsAboveUtilization.selector, uint256(10), uint256(9)));
        vault.rollOpen(id, 10);

        vm.prank(keeper);
        vault.rollOpen(id, 9);
        assertEq(vault.lockedAssets(), 9e18);
        assertEq(nvda.balanceOf(address(vault)), 11e18, "20 - 9 written");
        assertEq(vault.idleAssets(), 1e18, "11 held, 10 reserved");

        // And the reservation is real money: alice is paid in full while the new short is open.
        vm.prank(alice);
        (uint256 assetsOut, uint256 usdgOut) = vault.completeRedeem(alice);
        assertEq(assetsOut, 10e18, "alice gets exactly what was reserved");
        assertEq(usdgOut, 0, "no premium was ever collected");
        assertEq(nvda.balanceOf(alice), 20e18 + 10e18, "her 20 kept back plus the 10 redeemed");
        assertEq(vault.reservedAssets(), 0);
        assertEq(vault.idleAssets(), 1e18, "the writable slack is untouched by the payout");
    }

    function test_rollOpen_revertsContractsZero() public {
        _deposit(alice, 20e18);
        uint256 id = optionIds[RUNG_PICK];

        vm.prank(keeper);
        vm.expectRevert(Policy.ContractsZero.selector);
        vault.rollOpen(id, 0);
    }

    /// @dev The utilization boundary is arithmetic, so fuzz it. Everything at or below
    ///      floor(idle * 9500 / 10000 / 1e18) writes; everything above is refused with the
    ///      same two numbers the policy computed.
    function testFuzz_rollOpen_utilizationBoundary(uint256 assets, uint16 n) public {
        assets = bound(assets, 1e18, 30e18);
        _deposit(alice, assets);

        uint256 maxByUtilization = (assets * 9_500) / 10_000 / LOT;
        // The absolute cap is 50 lots and 30 NVDA can never reach it, so utilization is the
        // only binding constraint here.
        assertLe(maxByUtilization, 50);

        uint112 want = uint112(bound(uint256(n), 0, maxByUtilization + 3));
        uint256 id = optionIds[RUNG_PICK];

        if (want == 0) {
            vm.prank(keeper);
            vm.expectRevert(Policy.ContractsZero.selector);
            vault.rollOpen(id, want);
            return;
        }

        if (want > maxByUtilization) {
            vm.prank(keeper);
            vm.expectRevert(
                abi.encodeWithSelector(Policy.ContractsAboveUtilization.selector, uint256(want), maxByUtilization)
            );
            vault.rollOpen(id, want);
            return;
        }

        vm.prank(keeper);
        vault.rollOpen(id, want);
        assertEq(vault.contractsWritten(), want);
        assertEq(vault.lockedAssets(), uint256(want) * LOT);
        assertEq(vault.totalAssets(), assets, "writing never moves NAV");
    }

    /*//////////////////////////////////////////////////////////////
                          ROLLOPEN: VALOREM FEE
    //////////////////////////////////////////////////////////////*/

    /// @dev Valorem's engine fee is 15 bps of NOTIONAL, which on a weekly OTM call eats most
    ///      of the premium. Turning it on must stop the keeper dead.
    function test_rollOpen_revertsValoremFeeNotAccepted() public {
        _deposit(alice, 20e18);
        uint256 id = optionIds[RUNG_PICK];

        clear.setFeesEnabled(true);
        assertFalse(vault.valoremFeeAccepted());

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Vault.ValoremFeeNotAccepted.selector, uint8(15)));
        vault.rollOpen(id, 5);

        // With the fee back off the same write goes through untouched.
        clear.setFeesEnabled(false);
        vm.prank(keeper);
        vault.rollOpen(id, 5);
        assertEq(vault.contractsWritten(), 5);
    }

    /// @dev The governance switch has to actually switch something. `acceptValoremFee(true)`
    ///      is spec'd (plan 4.11 #9) as the lever that lets the vault write while Valorem's
    ///      engine fee is on, and BOTH gates have to honour it: `Vault.rollOpen` checks the
    ///      flag and the acceptance, and `AdapterValorem._writeCalls` now takes `feeAccepted`
    ///      and only reverts when the fee is on AND governance has not accepted it.
    ///
    ///      REGRESSION GUARD. An earlier draft had the adapter re-check `clear.feesEnabled()`
    ///      unconditionally, so accepting the fee changed only WHICH error came back and the
    ///      switch was decorative. If that guard is ever restored, this test reverts with
    ///      `AdapterValorem.ValoremFeesEnabled` and fails here.
    function test_rollOpen_shouldWriteOnceGovernanceAcceptsTheValoremFee() public {
        _deposit(alice, 20e18);
        uint256 id = optionIds[RUNG_PICK];

        clear.setFeesEnabled(true);
        vm.prank(admin);
        vault.acceptValoremFee(true);
        assertTrue(vault.valoremFeeAccepted(), "governance has accepted the fee");

        vm.prank(keeper);
        vault.rollOpen(id, 5);

        assertEq(vault.contractsWritten(), 5, "governance accepted the fee, so the write lands");
        assertEq(_phase(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                             ROLLOPEN: ORACLE
    //////////////////////////////////////////////////////////////*/

    /// @dev A Stock Token that has paused its own oracle has no defensible spot, so there is
    ///      no defensible strike band either. Hold spot and write nothing.
    function test_rollOpen_revertsOraclePaused() public {
        _deposit(alice, 20e18);
        uint256 id = optionIds[RUNG_PICK];

        nvda.setOraclePaused(true);

        vm.prank(keeper);
        vm.expectRevert(Vault.OraclePaused.selector);
        vault.rollOpen(id, 5);

        nvda.setOraclePaused(false);
        vm.prank(keeper);
        vault.rollOpen(id, 5);
        assertEq(_phase(), 1, "writing resumes once the token's oracle is live");
    }

    function test_rollOpen_revertsStalePrice() public {
        _deposit(alice, 20e18);
        uint256 id = optionIds[RUNG_PICK];

        uint256 tooOld = block.timestamp - MAX_PRICE_AGE - 1;
        feed.setUpdatedAt(tooOld);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Vault.StalePrice.selector, tooOld, uint256(MAX_PRICE_AGE)));
        vault.rollOpen(id, 5);

        // The check is strictly greater-than, so a price exactly MAX_PRICE_AGE old still writes.
        feed.setUpdatedAt(block.timestamp - MAX_PRICE_AGE);
        vm.prank(keeper);
        vault.rollOpen(id, 5);
        assertEq(_phase(), 1);
    }

    /// @dev TECHSPEC calls an issuer freeze an existential risk. If Robinhood Assets halts
    ///      transfers mid-week the collateral leg of the write cannot settle, and the only
    ///      acceptable outcome is a hard revert that leaves the vault flat — never a claim key
    ///      recorded against collateral that never moved.
    function test_rollOpen_revertsWhenTheIssuerFreezesTheToken() public {
        _deposit(alice, 20e18);
        uint256 id = optionIds[RUNG_PICK];

        nvda.setFrozen(true);

        vm.prank(keeper);
        vm.expectRevert(MockStockToken.IssuerFreeze.selector);
        vault.rollOpen(id, 5);

        assertEq(_phase(), 0, "still Idle, no half-open cycle");
        assertEq(vault.claimKey(), 0, "no claim recorded");
        assertEq(vault.contractsWritten(), 0);
        assertEq(nvda.balanceOf(address(vault)), 20e18, "collateral never left");

        nvda.setFrozen(false);
        vm.prank(keeper);
        vault.rollOpen(id, 5);
        assertEq(_phase(), 1, "writing resumes when the freeze lifts");
    }

    /*//////////////////////////////////////////////////////////////
                         ROLLOPEN: WRITE DEADLINE
    //////////////////////////////////////////////////////////////*/

    /// @dev The registry's write deadline IS the exercise timestamp. A write landing after it
    ///      would create a short that buyers can exercise immediately.
    function test_rollOpen_revertsAtWriteDeadline() public {
        _deposit(alice, 20e18);
        uint256 id = optionIds[RUNG_PICK];

        _warpToExercise();
        assertFalse(registry.isWritingOpen());

        vm.prank(keeper);
        vm.expectRevert(Vault.WritingNotOpen.selector);
        vault.rollOpen(id, 5);
    }

    function test_rollOpen_allowedOneSecondBeforeTheDeadline() public {
        _deposit(alice, 20e18);
        uint256 id = optionIds[RUNG_PICK];

        vm.warp(uint256(exerciseTs) - 1);
        _refreshFeed(); // staleness is a separate gate; keep it out of the way
        assertTrue(registry.isWritingOpen());

        vm.prank(keeper);
        vault.rollOpen(id, 5);
        assertEq(_phase(), 1, "a write one second before book close is legal");
    }

    /*//////////////////////////////////////////////////////////////
                                LOCKBOOK
    //////////////////////////////////////////////////////////////*/

    function test_lockBook_revertsBeforeExerciseTs() public {
        _deposit(alice, 20e18);
        _rollOpen(5);

        vm.warp(uint256(exerciseTs) - 1);
        vm.prank(passerby);
        vm.expectRevert(abi.encodeWithSelector(Vault.NotYetExercisable.selector, exerciseTs));
        vault.lockBook();

        assertEq(_phase(), 1, "still Listed");
    }

    /// @dev Permissionless on purpose: it only ever moves Listed -> Exercisable after a
    ///      timestamp the registry already fixed, so there is nothing to gain by calling it
    ///      and a great deal to lose if nobody can.
    function test_lockBook_isPermissionlessAtExerciseTs() public {
        _deposit(alice, 20e18);
        _rollOpen(5);

        _warpToExercise();
        vm.prank(passerby);
        vault.lockBook();

        assertEq(_phase(), 2, "Listed -> Exercisable");
        assertEq(vault.contractsWritten(), 5, "the short is untouched");
        assertEq(vault.lockedAssets(), 5e18, "collateral still locked");
    }

    function test_lockBook_revertsWrongPhaseWhenIdleOrAlreadyLocked() public {
        // Idle: nothing to lock.
        _warpToExercise();
        vm.expectRevert(abi.encodeWithSelector(Vault.WrongPhase.selector, Vault.Phase.Listed, Vault.Phase.Idle));
        vault.lockBook();

        // And it is not idempotent: a second call from Exercisable is a wrong-phase revert.
        vm.warp(1_789_000_000);
        _deposit(alice, 20e18);
        _rollOpen(5);
        _warpToExercise();
        vault.lockBook();

        vm.expectRevert(abi.encodeWithSelector(Vault.WrongPhase.selector, Vault.Phase.Listed, Vault.Phase.Exercisable));
        vault.lockBook();
    }

    /*//////////////////////////////////////////////////////////////
                                ROLLCLOSE
    //////////////////////////////////////////////////////////////*/

    function test_rollClose_revertsBeforeExpiry() public {
        _deposit(alice, 20e18);
        _rollOpen(5);
        _warpToExercise();
        vault.lockBook();

        vm.warp(uint256(expiryTs) - 1);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Vault.NotYetExpired.selector, expiryTs));
        vault.rollClose();

        // The expiry check runs before the keeper/grace check, so a stranger sees the same
        // error rather than GuardianTooEarly.
        vm.prank(passerby);
        vm.expectRevert(abi.encodeWithSelector(Vault.NotYetExpired.selector, expiryTs));
        vault.rollClose();
    }

    function test_rollClose_keeperWorksExactlyAtExpiry() public {
        _deposit(alice, 20e18);
        _rollOpen(5);
        _warpToExercise();
        vault.lockBook();

        _warpToExpiry();
        assertEq(block.timestamp, expiryTs, "exactly at expiry, not a second later");

        vm.prank(keeper);
        vault.rollClose();

        assertEq(_phase(), 0, "Exercisable -> (Settling) -> Idle in one transaction");
        assertEq(nvda.balanceOf(address(vault)), 20e18);
    }

    /// @dev F-13, the "keeper is dead" path. Depositors must never need a hot key to be alive
    ///      to get their collateral out of Valorem. An hour of exclusivity for the keeper,
    ///      then the whole world can close the cycle.
    function test_rollClose_anyoneAfterGracePeriod() public {
        _deposit(alice, 20e18);
        _rollOpen(5);
        _warpToExercise();
        vault.lockBook();

        uint40 openAt = expiryTs + 1 hours;

        // At expiry, and right up to the last second of the grace hour, only the keeper.
        _warpToExpiry();
        vm.prank(passerby);
        vm.expectRevert(abi.encodeWithSelector(Vault.GuardianTooEarly.selector, openAt));
        vault.rollClose();

        vm.warp(uint256(openAt) - 1);
        vm.prank(passerby);
        vm.expectRevert(abi.encodeWithSelector(Vault.GuardianTooEarly.selector, openAt));
        vault.rollClose();

        // The error is called GuardianTooEarly, which invites the assumption that the guardian
        // is exempt. It is not: the gate is KEEPER_ROLE or the clock, nothing else.
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Vault.GuardianTooEarly.selector, openAt));
        vault.rollClose();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Vault.GuardianTooEarly.selector, openAt));
        vault.rollClose();

        // Exactly one hour after expiry the door opens, and it opens for anybody: not the
        // guardian, not the admin, a passer-by.
        vm.warp(openAt);
        vm.prank(passerby);
        vault.rollClose();

        assertEq(_phase(), 0, "a stranger closed the cycle");
        assertEq(vault.claimKey(), 0, "the claim was redeemed");
        assertEq(nvda.balanceOf(address(vault)), 20e18, "all collateral back, keeper never woke up");
    }

    /// @dev Nobody called `lockBook` all week. `rollClose` must still work straight out of
    ///      Listed, otherwise a forgotten permissionless call would strand the collateral.
    function test_rollClose_worksDirectlyFromListed() public {
        _deposit(alice, 20e18);
        _rollOpen(5);
        assertEq(_phase(), 1, "nobody ever locked the book");

        _warpToExpiry();
        _rollClose();

        assertEq(_phase(), 0);
        assertEq(vault.contractsWritten(), 0);
        assertEq(nvda.balanceOf(address(vault)), 20e18, "collateral back from Listed");
    }

    function test_rollClose_revertsWrongPhaseWhenIdle() public {
        _warpToExpiry();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Vault.WrongPhase.selector, Vault.Phase.Exercisable, Vault.Phase.Idle));
        vault.rollClose();
    }

    /*//////////////////////////////////////////////////////////////
                          FULL CYCLE + RESTART
    //////////////////////////////////////////////////////////////*/

    /// @dev A cycle that expires out of the money returns every wei of collateral. Exact
    ///      balances on all four sides, no tolerances.
    ///
    ///      THE MONEY, BY HAND. 10 contracts at a $2.00 unit price:
    ///        feePerContract = 2_000_000 * 500 / 10_000            = 100_000
    ///        consideration[1] (Overcall) = 100_000   * 10         =  1_000_000
    ///        consideration[0] (vault)    = 1_900_000 * 10         = 19_000_000
    ///        gross the buyer pays        = 2_000_000 * 10         = 20_000_000
    ///      At rollClose nothing is committed yet, so the harvest is the whole 19_000_000:
    ///        protocol fee = 19_000_000 * 1_000 / 10_000           =  1_900_000
    ///        net to depositors = 19_000_000 - 1_900_000           = 17_100_000
    ///      Alice is the only holder, so `claimableUsdg(alice)` is that whole net.
    ///      Sum check: 1_000_000 + 1_900_000 + 17_100_000 = 20_000_000, the buyer's outlay.
    function test_fullOtmCycleReturnsAllCollateral() public {
        _deposit(alice, 20e18);
        assertEq(nvda.balanceOf(alice), 10e18, "alice kept 10 of her 30");

        // Inlined rather than run through `_fullCycleOtm` so the fill is observed, not assumed:
        // a "full cycle" test that never checks the inventory actually moved proves nothing.
        uint256 optionId = _rollOpen(10);
        OrderComponents memory c = _approveListing(optionId, 10, _okUnitPrice());
        _fill(c, 10);

        assertEq(clear.balanceOf(buyer, optionId), 10, "the buyer really holds the calls");
        assertEq(clear.balanceOf(address(vault), optionId), 0, "the vault sold its whole inventory");
        assertEq(usdg.balanceOf(address(vault)), 19_000_000, "premium landed before any fee");
        assertEq(usdg.balanceOf(overcallFee), 1_000_000, "Overcall is paid in the same fill");

        _warpToExercise();
        vault.lockBook();
        // Nobody exercises: at expiry the 231.00 calls are worthless against a 220.00 spot.
        _warpToExpiry();
        _rollClose();

        // Asset side: everything came home, nothing is stuck in Valorem or with the buyer.
        assertEq(nvda.balanceOf(address(vault)), 20e18, "vault holds all 20 NVDA again");
        assertEq(nvda.balanceOf(address(clear)), 0, "clearinghouse is empty");
        assertEq(nvda.balanceOf(buyer), 0, "an OTM call assigns nothing");
        assertEq(vault.totalAssets(), 20e18);
        assertEq(vault.lockedAssets(), 0);
        assertEq(vault.idleAssets(), 20e18);

        // Cash side: Overcall's 5%, the protocol's 10% of the net, the rest to the depositor.
        assertEq(usdg.balanceOf(overcallFee), 1_000_000, "Overcall 5% of gross");
        assertEq(usdg.balanceOf(feeSafe), 1_900_000, "protocol 10% of the 19 harvested");
        assertEq(usdg.balanceOf(address(vault)), 17_100_000, "the rest waits to be claimed");
        assertEq(vault.claimableUsdg(alice), 17_100_000);
        assertEq(usdg.balanceOf(buyer), 5_000_000_000 - 20_000_000, "buyer paid gross once");

        // Conservation: every cent that left the buyer sits in exactly one of the three
        // pockets. Computed from live balances, not from the literals above.
        assertEq(
            usdg.balanceOf(overcallFee) + usdg.balanceOf(feeSafe) + usdg.balanceOf(address(vault)),
            5_000_000_000 - usdg.balanceOf(buyer),
            "no USDG created, none stranded"
        );
    }

    /// @dev After a close the vault is genuinely flat: every cycle field zeroed, instant
    ///      redemption available again, and a brand new cycle openable.
    function test_rollClose_zeroesCycleStateAndANewCycleCanOpen() public {
        _deposit(alice, 20e18);
        _rollOpen(5);
        _warpToExpiry();
        _rollClose();

        assertEq(_phase(), 0, "Idle");
        assertEq(vault.claimKey(), 0, "claimKey zeroed");
        assertEq(vault.optionId(), 0, "optionId zeroed");
        assertEq(vault.contractsWritten(), 0, "contractsWritten zeroed");
        assertEq(vault.contractsSold(), 0, "contractsSold zeroed");
        assertEq(vault.lockedAssets(), 0, "nothing locked");
        assertTrue(vault.canRedeemInstantly(), "flat again, so the queue is not the only path");
        assertEq(vault.previewRedeem(1e18), 1e18, "and the preview quotes a number you can get");

        // Next week: new timestamps, new option types, new registry cycle.
        exerciseTs = uint40(block.timestamp + 6 days);
        expiryTs = uint40(block.timestamp + 7 days);
        _installCycle();
        _refreshFeed();
        assertEq(registry.cycleNumber(), 2);

        uint256 newOptionId = _rollOpen(7);

        assertEq(_phase(), 1, "open again");
        assertEq(vault.cycleNumber(), 2, "the vault followed the registry forward");
        assertEq(vault.cycleExerciseTs(), exerciseTs);
        assertEq(vault.cycleExpiryTs(), expiryTs);
        assertEq(vault.contractsWritten(), 7);
        assertEq(clear.balanceOf(address(vault), newOptionId), 7);
        assertEq(vault.lockedAssets(), 7e18);
        assertEq(vault.totalAssets(), 20e18, "two cycles in, NAV is still 20 NVDA");
    }
}
