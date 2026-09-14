// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {Vault} from "../../src/Vault.sol";
import {Policy} from "../../src/Policy.sol";
import {ValoremLib} from "../../src/lib/ValoremLib.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {OrderComponents} from "../../src/interfaces/ISeaport.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice The phase machine and every gate on `rollOpen` / `lockBook` / `rollClose`.
/// @dev `rollOpen(optionId)` ARMS a cycle and writes nothing (decision D1). There is no registry
///      (decision D16): the keeper names a Valorem option id, and the arm gate ({ValoremLib.open})
///      reads the tuple back from the clearinghouse and refuses anything the vault would not
///      underwrite. Most of this file is that refusal matrix; the rest is the phase transitions,
///      including a `rollClose` on a week where nothing sold and so nothing was ever written.
///
///      The band arithmetic these tests lean on, stated once:
///        spot 220.000000, launch policy 300..1200 bps OTM
///        => strike window [226_600_000, 246_400_000]
///        => rung 0 (226.00) is BELOW, rung 4 (246.00) is inside by 40 cents, rung 1 (231.00) is the pick.
contract VaultRollTest is BaseTest {
    /// @dev Somebody with no role at all. Used for the permissionless paths and, in
    ///      {test_rollClose_anyoneAfterGracePeriod}, to stand in for "the keeper is dead".
    address internal passerby = makeAddr("passerby");

    uint256 internal constant BAND_LO = 226_600_000; // 220.00 * 1.03
    uint256 internal constant BAND_HI = 246_400_000; // 220.00 * 1.12

    /// @dev Mirrors {Vault.RollOpen} so the emission can be pinned field by field.
    event RollOpen(uint32 indexed cycleNumber, uint256 indexed optionId, uint112 contractsCount, uint256 strikeUsdg);

    /// @dev MockFeed stamps `updatedAt` on every `setAnswer`. Any test that warps more than
    ///      MAX_PRICE_AGE forward and then wants to arm must re-stamp it, otherwise the
    ///      staleness gate fires instead of the gate under test.
    function _refreshFeed() internal {
        feed.setAnswer(SPOT_FEED);
    }

    /// @dev Arm `id` as the keeper and require exactly `err`. `err` is computed by the caller so no
    ///      external call sits between the cheatcode and the call it arms.
    function _armRejects(uint256 id, bytes memory err) internal {
        vm.prank(keeper);
        vm.expectRevert(err);
        vault.rollOpen(id);
        assertEq(_phase(), 0, "still Idle");
        assertEq(vault.optionId(), 0, "nothing armed");
    }

    /// @dev A one-off option type with our tuple and the given window and strike.
    function _type(uint96 strike, uint40 exTs, uint40 expTs) internal returns (uint256) {
        return clear.newOptionType(address(nvda), uint96(LOT), address(usdg), strike, exTs, expTs);
    }

    /*//////////////////////////////////////////////////////////////
                      ROLLOPEN: THE HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev ARMING WRITES NOTHING. No option token, no claim, no collateral moved: the vault is
    ///      Listed with an empty position, and every write will come from a fill.
    function test_rollOpen_armsTheTypeAndWritesNothing() public {
        _deposit(alice, 20e18);
        uint256 optionId = optionIds[RUNG_PICK];

        vm.expectEmit(true, true, true, true, address(vault));
        emit RollOpen(1, optionId, 0, 231_000_000);
        vm.prank(keeper);
        vault.rollOpen(optionId);

        assertEq(_phase(), 1, "Idle -> Listed");
        assertEq(vault.optionId(), optionId, "optionId recorded");
        assertEq(vault.contractsWritten(), 0, "nothing written");
        assertEq(vault.claimKey(), 0, "no claim yet");
        assertEq(vault.lockedAssets(), 0, "nothing locked");
        assertEq(clear.balanceOf(address(vault), optionId), 0, "no option tokens minted");
        assertEq(nvda.balanceOf(address(vault)), 20e18, "collateral never moved");
        assertEq(nvda.balanceOf(address(clear)), 0, "the clearinghouse holds nothing of ours");
        assertEq(vault.idleAssets(), 20e18);
        assertEq(vault.totalAssets(), 20e18);
    }

    /// @dev The cycle snapshot is taken at `rollOpen` from the clearinghouse's immutable tuple, and
    ///      the cycle number is the vault's own counter.
    function test_rollOpen_snapshotsTheCycleAndNumbersIt() public {
        _deposit(alice, 20e18);
        _rollOpen();

        assertEq(vault.cycleNumber(), 1, "the vault's first cycle");
        assertEq(vault.cycleExerciseTs(), exerciseTs, "exercise timestamp snapshotted");
        assertEq(vault.cycleExpiryTs(), expiryTs, "expiry timestamp snapshotted");
        assertEq(vault.cycleStrikeUsdg(), 231_000_000, "the 231.00 rung");
    }

    /// @dev The listing budget is three authorised orders per cycle. Spend it, roll into a new
    ///      cycle: if `rollOpen` failed to reset it, week two would open with a spent budget.
    function test_rollOpen_resetsTheSpentListingBudget() public {
        _deposit(alice, 20e18);
        uint256 id = _rollOpen();

        OrderComponents memory c1 = _approveListing(id, 5, _okUnitPrice() + 2);
        vm.prank(keeper);
        vault.cancelListing(c1);
        OrderComponents memory c2 = _approveListing(id, 5, _okUnitPrice() + 1);
        vm.prank(keeper);
        vault.cancelListing(c2);
        _approveListing(id, 5, _okUnitPrice());
        assertEq(vault.listingsThisCycle(), 3, "budget fully spent this cycle");

        _warpToExpiry();
        _rollClose();
        _nextWeek();

        _rollOpen();
        assertEq(vault.listingsThisCycle(), 0, "a new cycle starts with a full budget");
        assertEq(vault.cycleNumber(), 2, "and the vault counted it");
    }

    /// @dev Arming never touches the share price, and neither does the fill that follows.
    function test_rollOpen_andTheFillDoNotChangeTotalAssets() public {
        _deposit(alice, 20e18);
        _deposit(bob, 10e18);

        uint256 assetsBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();
        uint256 priceBefore = vault.convertToAssets(1e18);

        _openAndSell(20);

        assertEq(vault.totalAssets(), assetsBefore, "collateral moved, not lost");
        assertEq(vault.totalAssets(), 30e18, "idle 10 + locked 20");
        assertEq(vault.lockedAssets(), 20e18);
        assertEq(vault.totalSupply(), supplyBefore, "no shares minted or burned");
        assertEq(vault.convertToAssets(1e18), priceBefore, "share price unmoved");
    }

    /// @dev Arming needs no idle collateral at all. Sizing happens at the fill, against the NAV of
    ///      that moment, so an empty vault can be armed and a later deposit can be written against.
    function test_rollOpen_worksWithNoDepositsYet() public {
        _rollOpen();
        assertEq(_phase(), 1, "armed with an empty book");
        _deposit(alice, 20e18);
        OrderComponents memory c = _approveListing(optionIds[RUNG_PICK], 5, _okUnitPrice());
        _fill(c, 5);
        assertEq(vault.contractsWritten(), 5, "the late deposit was written against");
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
            vault.rollOpen(id);
        }

        vm.prank(keeper);
        vault.rollOpen(id);
        assertEq(_phase(), 1);
    }

    function test_rollOpen_revertsWrongPhaseFromListed() public {
        _deposit(alice, 20e18);
        uint256 id = _rollOpen();
        assertEq(_phase(), 1);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Vault.WrongPhase.selector, Vault.Phase.Idle, Vault.Phase.Listed));
        vault.rollOpen(id);
    }

    function test_rollOpen_revertsWrongPhaseFromExercisable() public {
        _deposit(alice, 20e18);
        uint256 id = _rollOpen();

        _warpToExercise();
        vault.lockBook();
        assertEq(_phase(), 2);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Vault.WrongPhase.selector, Vault.Phase.Idle, Vault.Phase.Exercisable));
        vault.rollOpen(id);
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
        vault.rollOpen(id);

        // The guardian can stop, only the admin can start again.
        vm.prank(admin);
        vault.unhaltWrites();

        vm.prank(keeper);
        vault.rollOpen(id);
        assertEq(_phase(), 1, "arming resumes once the halt is lifted");
    }

    /// @dev A halt must never trap an open cycle. If it blocked `lockBook` or `rollClose` the
    ///      guardian could freeze depositors' collateral inside Valorem indefinitely.
    function test_halt_doesNotBlockLockBookOrRollClose() public {
        _deposit(alice, 20e18);
        _openAndSell(5);

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
                    ROLLOPEN: THE ARM GATE (D16)
    //////////////////////////////////////////////////////////////*/

    /// @dev A claim id is not an option type. `option()` ignores the claim key, so a claim id would
    ///      pass every tuple check and then the first fill's `write` would mint into SOMEBODY ELSE's
    ///      claim. `tokenType` is checked first.
    function test_rollOpen_revertsForAClaimId() public {
        _deposit(alice, 20e18);
        uint256 optionId = optionIds[RUNG_PICK];
        _fund(bob, 5e18, 0);
        vm.startPrank(bob);
        nvda.approve(address(clear), 1e18);
        uint256 claimId = clear.write(optionId, 1);
        vm.stopPrank();
        assertTrue(claimId != optionId);

        _armRejects(claimId, abi.encodeWithSelector(Vault.NotAnOptionType.selector, claimId));
        // And an id nobody ever created.
        _armRejects(12345, abi.encodeWithSelector(Vault.NotAnOptionType.selector, 12345));
    }

    /// @dev The type's underlying must be THIS vault's asset and its exercise asset USDG. Anything
    ///      else would collateralise calls on the wrong token or be paid in one the vault cannot use.
    function test_rollOpen_revertsOnAssetMismatch() public {
        _deposit(alice, 20e18);
        MockERC20 other = new MockERC20("Other Stock", "OTHR", 18);
        other.mint(bob, 10e18);

        uint256 wrongUnderlying =
            clear.newOptionType(address(other), uint96(LOT), address(usdg), 231_000_000, exerciseTs, expiryTs);
        _armRejects(
            wrongUnderlying,
            abi.encodeWithSelector(ValoremLib.OptionAssetMismatch.selector, address(nvda), address(other))
        );

        uint256 wrongExercise =
            clear.newOptionType(address(nvda), uint96(LOT), address(other), 231_000_000, exerciseTs, expiryTs);
        _armRejects(
            wrongExercise,
            abi.encodeWithSelector(ValoremLib.OptionExerciseAssetMismatch.selector, address(usdg), address(other))
        );
    }

    /// @dev One contract is one token. The full matrix is test/unit/VaultLotSize.t.sol; this pins the
    ///      selector on the arm path.
    function test_rollOpen_revertsOnAnyLotButOneToken() public {
        _deposit(alice, 20e18);
        uint256 twoLot = clear.newOptionType(address(nvda), 2e18, address(usdg), 231_000_000, exerciseTs, expiryTs);
        _armRejects(twoLot, abi.encodeWithSelector(ValoremLib.UnexpectedLotSize.selector, uint96(1e18), uint96(2e18)));
    }

    /// @dev The exercise window must open at least MIN_LEAD (1 hour) from now. A type that can be
    ///      exercised in the next block could be filled and assigned inside one tick, and the deposit
    ///      gate rests on nothing being assignable before `cycleExerciseTs`.
    function test_rollOpen_revertsWhenExerciseOpensTooSoon() public {
        _deposit(alice, 20e18);
        uint40 soon = uint40(block.timestamp + 1 hours - 1);
        uint256 id = _type(231_000_000, soon, soon + 1 days);
        _armRejects(id, abi.encodeWithSelector(Vault.ExerciseTooSoon.selector, soon, uint40(block.timestamp + 1 hours)));

        // Exactly one hour out is accepted.
        uint40 ok = uint40(block.timestamp + 1 hours);
        uint256 okId = _type(231_000_000, ok, ok + 1 days);
        vm.prank(keeper);
        vault.rollOpen(okId);
        assertEq(vault.cycleExerciseTs(), ok, "MIN_LEAD is inclusive");
    }

    /// @dev A one-minute exercise window (Valorem's own floor) is a lottery, not a call. The vault
    ///      requires at least MIN_EXERCISE_WINDOW (1 day) between exercise and expiry.
    function test_rollOpen_revertsOnAnExerciseWindowUnderOneDay() public {
        _deposit(alice, 20e18);
        uint40 ex = uint40(block.timestamp + 2 days);
        uint40 shortExp = ex + 1 days - 1;
        uint256 id = _type(231_000_000, ex, shortExp);
        _armRejects(id, abi.encodeWithSelector(Vault.BadCycleWindow.selector, ex, shortExp));

        uint256 okId = _type(231_000_000, ex, ex + 1 days);
        vm.prank(keeper);
        vault.rollOpen(okId);
        assertEq(vault.cycleExpiryTs(), ex + 1 days, "exactly one day is accepted");
    }

    /// @dev The tenor ceiling. Collateral written into a type with a far expiry would be locked in
    ///      Valorem for the whole tenor with no redemption path for anyone, so anything past
    ///      MAX_CYCLE_TENOR (21 days from now) is refused before a cycle opens.
    function test_rollOpen_revertsOnATenorPast21Days() public {
        _deposit(alice, 20e18);
        uint40 ex = uint40(block.timestamp + 10 days);
        uint40 farExp = uint40(block.timestamp + 21 days + 1);
        uint256 id = _type(231_000_000, ex, farExp);
        _armRejects(id, abi.encodeWithSelector(Vault.BadCycleWindow.selector, ex, farExp));

        uint40 okExp = uint40(block.timestamp + 21 days);
        uint256 okId = _type(231_000_000, ex, okExp);
        vm.prank(keeper);
        vault.rollOpen(okId);
        assertEq(vault.cycleExpiryTs(), okExp, "exactly 21 days is accepted");
    }

    /// @dev An already-expired type has an exercise timestamp in the past: it fails the lead check
    ///      before anything else, and Valorem would refuse to write it anyway.
    function test_rollOpen_revertsOnAnExpiredType() public {
        _deposit(alice, 20e18);
        uint256 id = optionIds[RUNG_PICK];
        vm.warp(expiryTs + 1);
        _refreshFeed();
        _armRejects(
            id, abi.encodeWithSelector(Vault.ExerciseTooSoon.selector, exerciseTs, uint40(block.timestamp + 1 hours))
        );
    }

    /*//////////////////////////////////////////////////////////////
                         ROLLOPEN: STRIKE BAND
    //////////////////////////////////////////////////////////////*/

    /// @dev The 226.00 rung is 2.73% OTM at a spot of 220, just under the 3% floor. Selling it
    ///      is selling too close to the money, which is the exact thing the floor exists for.
    function test_rollOpen_revertsStrikeBelowBand() public {
        _deposit(alice, 20e18);
        _armRejects(
            optionIds[RUNG_BELOW_BAND],
            abi.encodeWithSelector(Policy.StrikeBelowBand.selector, uint256(226_000_000), BAND_LO)
        );
    }

    /// @dev BOTH bounds at the arm (decision D9): a strike above the ceiling earns nothing and is
    ///      not a call this vault underwrites. 246.00 clears the 220 ceiling of 246.40 by 40 cents;
    ///      a dollar lower spot moves the ceiling to 245.28 and puts the rung out of reach.
    function test_rollOpen_revertsStrikeAboveBand() public {
        _deposit(alice, 20e18);
        feed.setAnswer(219_00000000);
        uint256 hi = (219_000_000 * 11_200) / 10_000;
        _armRejects(
            optionIds[RUNG_ABOVE_BAND],
            abi.encodeWithSelector(Policy.StrikeAboveBand.selector, uint256(246_000_000), hi)
        );
    }

    /// @dev Both band edges in one place, so the ladder's own claim is pinned by arithmetic
    ///      rather than by a comment. At a $220 spot the window is [226.60, 246.40].
    function test_rollOpen_bandEdgesAtFixtureSpot() public {
        _deposit(alice, 25e18);
        assertEq(vault.spotUsdg(), SPOT_USDG);

        _armRejects(
            optionIds[RUNG_BELOW_BAND],
            abi.encodeWithSelector(Policy.StrikeBelowBand.selector, uint256(226_000_000), BAND_LO)
        );

        assertTrue(231_000_000 >= BAND_LO && 231_000_000 <= BAND_HI, "231.00 sits inside [226.60, 246.40]");
        assertTrue(246_000_000 <= BAND_HI, "246.00 is inside the launch band at a 220 spot");

        vm.prank(keeper);
        vault.rollOpen(optionIds[RUNG_ABOVE_BAND]);
        assertEq(vault.cycleStrikeUsdg(), 246_000_000, "the 246.00 rung is armable at 220 spot");
    }

    /*//////////////////////////////////////////////////////////////
                          ROLLOPEN: VALOREM FEE
    //////////////////////////////////////////////////////////////*/

    /// @dev Valorem's engine fee is 15 bps of NOTIONAL, which on a weekly OTM call eats most
    ///      of the premium. Turning it on must stop the keeper at the arm, so a whole week is not
    ///      listed and then refused fill by fill.
    function test_rollOpen_revertsValoremFeeNotAccepted() public {
        _deposit(alice, 20e18);
        uint256 id = optionIds[RUNG_PICK];

        mockClear.setFeesEnabled(true);
        assertFalse(vault.valoremFeeAccepted());

        _armRejects(id, abi.encodeWithSelector(Vault.ValoremFeeNotAccepted.selector, uint8(15)));

        // With the fee back off the same arm goes through untouched.
        mockClear.setFeesEnabled(false);
        vm.prank(keeper);
        vault.rollOpen(id);
        assertEq(_phase(), 1);
    }

    /// @dev The governance switch has to actually switch something: accepting the fee lets the vault
    ///      arm (and, at the fill, write and pay the fee; VaultWriteOnFill.t.sol).
    function test_rollOpen_armsOnceGovernanceAcceptsTheValoremFee() public {
        _deposit(alice, 20e18);
        uint256 id = optionIds[RUNG_PICK];

        mockClear.setFeesEnabled(true);
        vm.prank(admin);
        vault.acceptValoremFee(true);
        assertTrue(vault.valoremFeeAccepted(), "governance has accepted the fee");

        vm.prank(keeper);
        vault.rollOpen(id);
        assertEq(_phase(), 1, "governance accepted the fee, so the arm lands");
    }

    /*//////////////////////////////////////////////////////////////
                             ROLLOPEN: ORACLE
    //////////////////////////////////////////////////////////////*/

    /// @dev A Stock Token that has paused its own oracle has no defensible spot, so there is
    ///      no defensible strike band either. Hold spot and arm nothing.
    function test_rollOpen_revertsOraclePaused() public {
        _deposit(alice, 20e18);
        uint256 id = optionIds[RUNG_PICK];

        nvda.setOraclePaused(true);
        _armRejects(id, abi.encodeWithSelector(Vault.OraclePaused.selector));

        nvda.setOraclePaused(false);
        vm.prank(keeper);
        vault.rollOpen(id);
        assertEq(_phase(), 1, "arming resumes once the token's oracle is live");
    }

    function test_rollOpen_revertsStalePrice() public {
        _deposit(alice, 20e18);
        uint256 id = optionIds[RUNG_PICK];

        uint256 tooOld = block.timestamp - MAX_PRICE_AGE - 1;
        feed.setUpdatedAt(tooOld);
        _armRejects(id, abi.encodeWithSelector(Vault.StalePrice.selector, tooOld, uint256(MAX_PRICE_AGE)));

        // The check is strictly greater-than, so a price exactly MAX_PRICE_AGE old still arms.
        feed.setUpdatedAt(block.timestamp - MAX_PRICE_AGE);
        vm.prank(keeper);
        vault.rollOpen(id);
        assertEq(_phase(), 1);
    }

    /// @dev An issuer freeze of the Stock Token does not stop an ARM (nothing moves), but it stops
    ///      the fill that would move collateral: the revert surfaces where the transfer is.
    function test_rollOpen_armsUnderAnIssuerFreezeButNoFillCanWrite() public {
        _deposit(alice, 20e18);
        uint256 id = _rollOpen();
        OrderComponents memory c = _approveListing(id, 5, _okUnitPrice());

        nvda.pause();
        vm.startPrank(buyer);
        usdg.approve(address(seaport), type(uint256).max);
        vm.expectRevert();
        mockSeaport.fulfil(c, 5);
        vm.stopPrank();

        assertEq(vault.contractsWritten(), 0, "nothing written");
        assertEq(vault.claimKey(), 0, "no claim recorded");
        assertEq(nvda.balanceOf(address(vault)), 20e18, "collateral never left");

        nvda.unpause();
        _fill(c, 5);
        assertEq(vault.contractsWritten(), 5, "writing resumes when the freeze lifts");
    }

    /*//////////////////////////////////////////////////////////////
                                LOCKBOOK
    //////////////////////////////////////////////////////////////*/

    function test_lockBook_revertsBeforeExerciseTs() public {
        _deposit(alice, 20e18);
        _openAndSell(5);

        vm.warp(uint256(exerciseTs) - 1);
        vm.prank(passerby);
        vm.expectRevert(abi.encodeWithSelector(Vault.NotYetExercisable.selector, exerciseTs));
        vault.lockBook();

        assertEq(_phase(), 1, "still Listed");
    }

    /// @dev Permissionless on purpose: it only ever moves Listed -> Exercisable after a
    ///      timestamp the option type already fixed, so there is nothing to gain by calling it
    ///      and a great deal to lose if nobody can.
    function test_lockBook_isPermissionlessAtExerciseTs() public {
        _deposit(alice, 20e18);
        _openAndSell(5);

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
        _rollOpen();
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
        _openAndSell(5);
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
        _openAndSell(5);
        _warpToExercise();
        vault.lockBook();

        _warpToExpiry();
        assertEq(block.timestamp, expiryTs, "exactly at expiry, not a second later");

        vm.prank(keeper);
        vault.rollClose();

        assertEq(_phase(), 0, "Exercisable -> (Settling) -> Idle in one transaction");
        assertEq(nvda.balanceOf(address(vault)), 20e18);
    }

    /// @dev The "keeper is dead" path. Depositors must never need a hot key to be alive
    ///      to get their collateral out of Valorem. An hour of exclusivity for the keeper,
    ///      then the whole world can close the cycle.
    function test_rollClose_anyoneAfterGracePeriod() public {
        _deposit(alice, 20e18);
        _openAndSell(5);
        _warpToExercise();
        vault.lockBook();

        uint40 openAt = expiryTs + 1 hours;

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
        _openAndSell(5);
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

    /// @dev AN UNSOLD WEEK. Nothing filled, so nothing was written and there is no claim to redeem.
    ///      `rollClose` skips the redeem, forgets the armed type, settles the queue and returns to
    ///      Idle, where instant redemption works again. Nothing here touches the clearinghouse.
    function test_rollClose_withNothingSold_skipsRedeemAndReturnsToIdle() public {
        _deposit(alice, 20e18);
        uint256 id = _rollOpen();
        _approveListing(id, 10, _okUnitPrice());
        assertEq(vault.claimKey(), 0, "no claim: nothing sold");

        vm.prank(alice);
        vault.queueRedeem(5e18);

        _warpToExpiry();
        _rollClose();

        assertEq(_phase(), 0, "Idle");
        assertEq(vault.optionId(), 0, "the armed type is forgotten");
        assertEq(vault.claimKey(), 0);
        assertEq(vault.contractsWritten(), 0);
        assertEq(vault.listingHash(), bytes32(0), "the unfilled listing was killed");
        assertEq(nvda.balanceOf(address(clear)), 0, "the clearinghouse never held anything of ours");
        assertEq(vault.epochId(), 2, "the queue settled");
        assertEq(vault.reservedAssets(), 5e18, "the queuer's slice is reserved");
        assertTrue(vault.canRedeemInstantly(), "flat again");

        vm.prank(alice);
        uint256 out = vault.redeem(15e18, alice, alice);
        assertEq(out, 15e18, "instant redemption at par after an unsold week");
        vm.prank(alice);
        (uint256 queued,) = vault.completeRedeem(alice);
        assertEq(queued, 5e18, "and the queued slice collects");
    }

    /*//////////////////////////////////////////////////////////////
                          FULL CYCLE + RESTART
    //////////////////////////////////////////////////////////////*/

    /// @dev A cycle that expires out of the money returns every wei of collateral. Exact
    ///      balances on all sides, no tolerances.
    ///
    ///      THE MONEY, BY HAND. 10 contracts at a $1.90 unit price, ONE consideration item:
    ///        gross the buyer pays = 1_900_000 * 10 = 19_000_000, all of it the vault's
    ///        protocol fee = 19_000_000 * 500 / 10_000 = 950_000
    ///        net to depositors = 18_050_000
    function test_fullOtmCycleReturnsAllCollateral() public {
        _deposit(alice, 20e18);
        assertEq(nvda.balanceOf(alice), 10e18, "alice kept 10 of her 30");

        (uint256 optionId,) = _openAndSell(10);

        assertEq(clear.balanceOf(buyer, optionId), 10, "the buyer really holds the calls");
        assertEq(clear.balanceOf(address(vault), optionId), 0, "the vault holds none");
        assertEq(vault.contractsWritten(), 10, "written == sold");
        assertEq(usdg.balanceOf(address(vault)), 19_000_000, "premium landed before any fee");

        _warpToExercise();
        vault.lockBook();
        // Nobody exercises: at expiry the 231.00 calls are worthless against a 220.00 spot.
        _warpToExpiry();
        _rollClose();

        assertEq(nvda.balanceOf(address(vault)), 20e18, "vault holds all 20 NVDA again");
        assertEq(nvda.balanceOf(address(clear)), 0, "clearinghouse is empty");
        assertEq(nvda.balanceOf(buyer), 0, "an OTM call assigns nothing");
        assertEq(vault.totalAssets(), 20e18);
        assertEq(vault.lockedAssets(), 0);
        assertEq(vault.idleAssets(), 20e18);

        assertEq(usdg.balanceOf(feeSafe), 950_000, "protocol 5% of the 19 of premium harvested");
        assertEq(usdg.balanceOf(address(vault)), 18_050_000, "the rest waits to be claimed");
        assertEq(vault.claimableUsdg(alice), 18_050_000);
        assertEq(usdg.balanceOf(buyer), 5_000_000_000 - 19_000_000, "buyer paid gross once");

        // Conservation: every cent that left the buyer sits in exactly one of the two pockets.
        assertEq(
            usdg.balanceOf(feeSafe) + usdg.balanceOf(address(vault)),
            5_000_000_000 - usdg.balanceOf(buyer),
            "no USDG created, none stranded"
        );
    }

    /// @dev After a close the vault is genuinely flat: every cycle field zeroed, instant
    ///      redemption available again, and a brand new cycle armable.
    function test_rollClose_zeroesCycleStateAndANewCycleCanOpen() public {
        _deposit(alice, 20e18);
        _openAndSell(5);
        _warpToExpiry();
        _rollClose();

        assertEq(_phase(), 0, "Idle");
        assertEq(vault.claimKey(), 0, "claimKey zeroed");
        assertEq(vault.optionId(), 0, "optionId zeroed");
        assertEq(vault.contractsWritten(), 0, "contractsWritten zeroed");
        assertEq(vault.lockedAssets(), 0, "nothing locked");
        assertTrue(vault.canRedeemInstantly(), "flat again, so the queue is not the only path");
        assertEq(vault.previewRedeem(1e18), 1e18, "and the preview quotes a number you can get");

        _nextWeek();
        (uint256 newOptionId,) = _openAndSell(7);

        assertEq(_phase(), 1, "open again");
        assertEq(vault.cycleNumber(), 2, "the vault counted its second cycle");
        assertEq(vault.cycleExerciseTs(), exerciseTs);
        assertEq(vault.cycleExpiryTs(), expiryTs);
        assertEq(vault.optionId(), newOptionId);
        assertEq(vault.contractsWritten(), 7);
        assertEq(vault.lockedAssets(), 7e18);
        assertEq(vault.totalAssets(), 20e18, "two cycles in, NAV is still 20 NVDA");
    }
}
