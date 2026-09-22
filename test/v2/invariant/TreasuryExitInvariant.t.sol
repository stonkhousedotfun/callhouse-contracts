// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MakerTestBase} from "../unit/MakerBase.t.sol";
import {V2Ids} from "../../../src/v2/interfaces/V2Ids.sol";
import {RewardsDistributor} from "../../../src/v2/mm/RewardsDistributor.sol";
import {Hedger} from "../../../src/v2/periphery/Hedger.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";
import {Test} from "forge-std/Test.sol";
import {TreasuryExitHandler} from "./TreasuryExitHandler.sol";

/// @notice Stateful invariant of the INTERFACE_VERSION 8 rule that protocol-owned money has exactly ONE exit:
///         `MakerVault.withdraw`, `MakerVault.withdrawPosition` and `RewardsDistributor.defund` pay `treasury()`
///         and nothing else, whoever calls them and in whatever order.
/// @dev CONFIG. runs = 256, depth = 64, fail-on-revert on, like {MakerVaultOutflowInvariantTest}: the handler bounds
///      every argument and swallows the protocol's own refusals, so a revert reaching the fuzzer is a handler bug.
///
///      WHY THIS EXISTS AS AN INVARIANT. v7's three exits each took a free `to`, so "the money reached the treasury"
///      was a property of each CALL and one bad call broke it. v8 deletes those arguments and keeps a single stored
///      pointer that only TREASURY_ADMIN can move, which makes it a property of the CONTRACT over a whole sequence:
///      exits interleaved with pointer moves, with role-free callers trying the same functions, and with anyone
///      funding either contract. A fixed unit case fixes the order; this does not.
///
///      A DEDICATED TREASURY SET, not the fixture's `treasury`. {MakerTestBase} points the Clearinghouse and the
///      OrderBook fee recipient at `treasury`, so protocol FEES land there too and an "everything at the treasury
///      came from an exit" equality would be measuring both. setUp moves both pointers into a set of three fresh
///      addresses that receive nothing else, so {invariant_theTreasurySetHoldsExactlyWhatLeft} is exact.
///
///      NOTHING TRADES. The campaign only exits, funds and moves the pointer, so
///      {invariant_noNonTreasuryAddressEverGained} can be a strict `<=` against a balance recorded here rather than
///      an accounting argument about which of a trader's receipts were legitimate.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
/// @notice An address with code and no behaviour.
/// @dev {Hedger}'s constructor refuses a pool manager, settlement oracle, payout adapter or Morpho with no code, and
///      its {StockLoanAdapter} refuses a code-less Morpho too. This campaign exercises ONLY `withdraw`, which touches
///      none of them. A stub says that plainly. Wiring four working mocks would imply this invariant covers hedging,
///      unwinding and the loan market, and it does not -- see {HedgerExitHandler}'s note on what is NOT proved here.
contract CodePresenceStub {}

/// @notice Drives the {Hedger}'s single money exit for {TreasuryExitInvariantTest}: TREASURY_ADMIN calling
///         `withdraw`, and role-free callers trying the same.
/// @dev WHY THE HEDGER NEEDS ITS OWN HANDLER RATHER THAN A LEG ON {TreasuryExitHandler}. The vault and the
///      distributor keep a MOVABLE `treasury()` that TREASURY_ADMIN can repoint, so their invariant is "the money
///      followed the pointer". The Hedger's treasury is IMMUTABLE -- set once at construction, with no setter at all
///      -- so its claim is strictly stronger and differently shaped: the exit cannot be repointed by anyone, ever,
///      and `withdraw` lost its recipient argument entirely (F-CP-10). Folding that into the pointer-moving handler
///      would have meant a `moveTheTreasury` leg that silently does nothing for one of its three targets.
///
///      MEASURED, NOT ASSUMED, the same way its sibling does it: the recipient's balance is read before and after
///      each call and the delta compared with the amount, so an edit that paid `msg.sender`, split the payment or
///      paid a stale address is caught by the delta rather than by re-reading the slot the contract just used.
///
///      A SEPARATE TREASURY ADDRESS, deliberately outside {TreasuryExitInvariantTest.treasuries}. Sharing one would
///      have made `invariant_theTreasurySetHoldsExactlyWhatLeft` count two contracts' exits in one equality, which
///      weakens an assertion that is currently exact.
///
///      WHAT THIS DOES NOT PROVE: nothing about `hedge`, `unwind`, `repay` or `withdrawCollateral`. The Morpho and
///      v4 dependencies are stubs, so no position is ever opened here. This is the USDG exit and only that.
///
///      THE HANDLER NEVER REVERTS: the amount is bounded into range and every refusal is swallowed, so a revert
///      reaching the fuzzer under `fail-on-revert = true` is a bug in this file.
contract HedgerExitHandler is Test {
    Hedger internal immutable hedger;
    MockERC20 internal immutable usdg;

    /// @dev The Hedger's immutable exit, read from the contract itself at construction rather than passed in, so
    ///      this handler cannot be pointed at an address the contract does not actually use.
    address public immutable treasury;
    address internal immutable treasuryAdmin;
    address[3] internal outsiders;

    uint256 public usdgExited;
    uint256 public withdrawals;
    uint256 public misroutedExits;
    uint256 public unauthorizedExitsSucceeded;
    uint256 public refusedAttempts;
    uint256 public deposits;

    constructor(Hedger hedger_, MockERC20 usdg_, address treasuryAdmin_, address[3] memory outsiders_) {
        hedger = hedger_;
        usdg = usdg_;
        treasury = hedger_.treasury();
        treasuryAdmin = treasuryAdmin_;
        outsiders = outsiders_;
    }

    /// @notice The authorised exit.
    function withdrawUsdg(uint256 amount) external {
        uint256 have = usdg.balanceOf(address(hedger));
        if (have == 0) return;
        amount = bound(amount, 1, have);
        uint256 before = usdg.balanceOf(treasury);
        vm.prank(treasuryAdmin);
        try hedger.withdraw(amount) {
            usdgExited += amount;
            ++withdrawals;
            if (usdg.balanceOf(treasury) - before != amount) ++misroutedExits;
        } catch {}
    }

    /// @notice A caller holding nothing tries the exit. It must be refused, every time.
    function outsiderTriesToExit(uint8 who, uint256 amount) external {
        uint256 have = usdg.balanceOf(address(hedger));
        if (have == 0) return;
        amount = bound(amount, 1, have);
        vm.prank(outsiders[who % 3]);
        try hedger.withdraw(amount) {
            ++unauthorizedExitsSucceeded;
        } catch {
            ++refusedAttempts;
        }
    }

    /// @notice Anyone may put money IN. Funding is not an exit, and the contract must still only pay the treasury.
    function anyoneFunds(uint8 who, uint256 amount) external {
        amount = bound(amount, 1, 10_000e6);
        address from = outsiders[who % 3];
        usdg.mint(from, amount);
        vm.startPrank(from);
        usdg.approve(address(hedger), amount);
        try hedger.fund(amount) {
            ++deposits;
        } catch {
            usdg.transfer(address(hedger), amount);
            ++deposits;
        }
        vm.stopPrank();
    }
}

contract TreasuryExitInvariantTest is MakerTestBase {
    RewardsDistributor internal rewards;
    TreasuryExitHandler internal handler;
    /// @dev T-173. The Hedger's exit is IMMUTABLE, so it gets its own handler and its own recipient. See
    ///      {HedgerExitHandler} for why it is not a leg on the handler above.
    Hedger internal hedger;
    HedgerExitHandler internal hedgerHandler;
    /// @dev Outside {treasuries} on purpose, so `invariant_theTreasurySetHoldsExactlyWhatLeft` stays an exact
    ///      equality about the vault and the distributor alone.
    address internal hedgerTreasury = makeAddr("hedgerTreasurySafe");

    /// @dev The only addresses an exit may ever pay. Fresh, so nothing else reaches them.
    address[3] internal treasuries;
    /// @dev Callers with no TREASURY_ADMIN. `quoter` is the load-bearing one: it can move the vault's money all
    ///      over the book and must still not be able to take any of it out.
    address[3] internal outsiders;

    uint256 internal shortId;
    uint256[6] internal actorStartUsdg;
    uint256[6] internal actorStartStock;
    uint256[6] internal actorStartLongs;
    uint256[6] internal actorStartShorts;

    function setUp() public override {
        super.setUp();
        treasuries = [makeAddr("treasurySafeA"), makeAddr("treasurySafeB"), makeAddr("treasurySafeC")];
        outsiders = [quoter, keeper, stranger];
        shortId = V2Ids.shortIdOf(callId);

        // Both exits point at a treasury that receives nothing else.
        vm.prank(admin);
        vault.setTreasury(treasuries[0]);
        rewards = _newDistributor(IERC20(address(usdg)), treasuries[0], admin);

        // Reward balance to defund, and a real option position to unwind: the vault buys longs from alice and
        // writes shorts of its own, so both sides of {TreasuryExitHandler.withdrawPosition} have something to move.
        usdg.mint(address(this), 500_000e6);
        usdg.approve(address(rewards), type(uint256).max);
        rewards.fund(500_000e6);

        uint256 aliceAsk = _place(alice, callId, WRITE, P2_00, 5_000);
        _vaultTake(_buy(callId, _ids(aliceAsk), 5_000, P2_00, address(vault)));
        _vaultLedger(address(nvda), 60e18);
        uint256 bobBid = _place(bob, callId, BID, P2_00, 5_000);
        _vaultTake(_sell(callId, _ids(bobBid), 5_000, P2_00, true, address(vault)));
        assertGt(ch.balanceOf(address(vault), callId), 0, "the vault holds longs to unwind");
        assertGt(ch.balanceOf(address(vault), shortId), 0, "and shorts");

        // T-173. The Hedger, with idle USDG to take out. Its dependencies are code-presence stubs: this campaign
        // only exercises `withdraw`, and a stub makes that limit visible rather than implied.
        address stub = address(new CodePresenceStub());
        // T-265. The calendar is a constructor argument now, and it is the ONE dependency a stub cannot serve:
        // the constructor probes `isRegularSession` and an empty {CodePresenceStub} does not answer it, so the
        // build would revert {V2Errors.NoSource}. {MakerTestBase} already builds a real ExpiryCalendar, so this
        // uses that rather than teaching the stub a method. The campaign still only exercises `withdraw`.
        hedger = new Hedger(address(manager), address(usdg), stub, stub, stub, stub, hedgerTreasury, address(calendar));
        _wire(address(hedger), "Hedger", admin, 0);
        usdg.mint(address(hedger), 250_000e6);

        _recordActorStarts();

        handler = new TreasuryExitHandler(vault, rewards, ch, manager, usdg, nvda, admin, outsiders, treasuries, callId);
        vm.label(address(handler), "TreasuryExitHandler");
        targetContract(address(handler));

        hedgerHandler = new HedgerExitHandler(hedger, usdg, admin, outsiders);
        vm.label(address(hedgerHandler), "HedgerExitHandler");
        targetContract(address(hedgerHandler));
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev THE INVARIANT. Every base unit that left the vault or the distributor arrived, in full, at the address
    ///      `treasury()` named at that moment. The handler measures the recipient's balance around each exit, so
    ///      this fails on a payment that went somewhere else, on a partial payment, and on one that was split.
    function invariant_everySuccessfulExitLandedOnTheTreasuryInFull() public view {
        assertEq(handler.misroutedExits(), 0, "an exit did not land on treasury() in full");
    }

    /// @dev Only the treasury lane can exit, and only the treasury lane can move where an exit goes. A role-free
    ///      caller that could move the pointer would have a free `to` argument with extra steps.
    function invariant_onlyTheTreasuryLaneCanExit() public view {
        assertEq(handler.unauthorizedExitsSucceeded(), 0, "a caller without TREASURY_ADMIN took money out");
        assertEq(handler.unauthorizedTreasuryChanges(), 0, "a caller without TREASURY_ADMIN moved the exit");
    }

    /// @dev Nobody outside the treasury set is ever better off. Nothing in this campaign trades, so every one of
    ///      these balances can only fall (by funding the vault or the distributor) -- a rise means an exit paid the
    ///      wrong address, which is the failure the whole task is about. The starting values are recorded AFTER the
    ///      fixture's one round of trading, so alice's shorts and bob's longs are where the campaign found them.
    function invariant_noNonTreasuryAddressEverGained() public view {
        address[6] memory actors = _actors();
        for (uint256 i; i < actors.length; ++i) {
            assertLe(usdg.balanceOf(actors[i]), actorStartUsdg[i], "a non-treasury address gained USDG");
            assertLe(nvda.balanceOf(actors[i]), actorStartStock[i], "a non-treasury address gained Stock Tokens");
            assertLe(ch.balanceOf(actors[i], callId), actorStartLongs[i], "a non-treasury address gained longs");
            assertLe(ch.balanceOf(actors[i], shortId), actorStartShorts[i], "a non-treasury address gained shorts");
        }
    }

    /// @dev The exit is never unset and never points anywhere but the allowed set. A zero pointer would either burn
    ///      the money or force a "treasury unset" branch that a later edit could reach with money in the contract.
    function invariant_theExitIsAlwaysSetAndInsideTheAllowedSet() public view {
        assertTrue(_isATreasury(vault.treasury()), "the vault's exit left the allowed set");
        assertTrue(_isATreasury(rewards.treasury()), "the distributor's exit left the allowed set");
    }

    /// @dev The treasury set holds exactly what left, asset by asset: nothing leaked on the way and nothing else
    ///      reached those addresses. The ERC-1155 side counts both legs of the position, because
    ///      {MakerVault.withdrawPosition} takes a token id and a long and a short are different ids of one series.
    function invariant_theTreasurySetHoldsExactlyWhatLeft() public view {
        uint256 usdgHeld;
        uint256 stockHeld;
        uint256 unitsHeld;
        for (uint256 i; i < treasuries.length; ++i) {
            usdgHeld += usdg.balanceOf(treasuries[i]);
            stockHeld += nvda.balanceOf(treasuries[i]);
            unitsHeld += ch.balanceOf(treasuries[i], callId) + ch.balanceOf(treasuries[i], shortId);
        }
        assertEq(usdgHeld, handler.usdgExited(), "USDG at the treasuries is exactly what left");
        assertEq(stockHeld, handler.stockExited(), "Stock Tokens at the treasuries are exactly what left");
        assertEq(unitsHeld, handler.unitsExited(), "option units at the treasuries are exactly what left");
    }

    /*//////////////////////////////////////////////////////////////
                    T-173 -- THE HEDGER'S IMMUTABLE EXIT
    //////////////////////////////////////////////////////////////*/

    /// @dev The same claim as {invariant_everySuccessfulExitLandedOnTheTreasuryInFull}, for the Hedger. The handler
    ///      measures the recipient's balance around every `withdraw`, so this fails on a payment that went
    ///      elsewhere, on a partial payment, and on one that was split.
    function invariant_everyHedgerExitLandedOnItsTreasuryInFull() public view {
        assertEq(hedgerHandler.misroutedExits(), 0, "a Hedger exit did not land on hedger.treasury() in full");
    }

    /// @dev F-CP-10 for the Hedger. `withdraw` lost its recipient argument, so a delay-0 TREASURY_ADMIN hot key can
    ///      choose the AMOUNT and nothing else; a caller holding no role can do neither.
    function invariant_onlyTheTreasuryLaneCanExitTheHedger() public view {
        assertEq(hedgerHandler.unauthorizedExitsSucceeded(), 0, "a caller without TREASURY_ADMIN emptied the Hedger");
    }

    /// @dev THE STRONGER HALF, and the reason the Hedger is not simply a leg on the other handler: its treasury is
    ///      `immutable`, with no setter on the contract at all. The vault's and the distributor's pointers may move
    ///      within an allowed set; this one cannot move for anybody, in any sequence, ever.
    function invariant_theHedgerExitCanNeverBeRepointed() public view {
        assertEq(hedger.treasury(), hedgerTreasury, "the Hedger's immutable exit changed, which should be impossible");
    }

    /// @dev Exact, and it can be exact because `hedgerTreasury` is outside {treasuries} and receives nothing else:
    ///      no fee, no trade, no funding. Every base unit there arrived through the exit.
    function invariant_theHedgerTreasuryHoldsExactlyWhatLeftTheHedger() public view {
        assertEq(
            usdg.balanceOf(hedgerTreasury),
            hedgerHandler.usdgExited(),
            "USDG at the Hedger's treasury is exactly what left the Hedger"
        );
    }

    /*//////////////////////////////////////////////////////////////
                             NON-VACUITY
    //////////////////////////////////////////////////////////////*/

    /// @dev One scripted pass moves every counter the campaign relies on, so a green run is evidence about the
    ///      exits and not about a handler that did nothing. Deterministic and outside the campaign, because an
    ///      invariant run's state is rolled back between runs.
    function test_handlerExercisesEveryExit() public {
        handler.anyoneDeposits(2, true, 5_000e6);
        handler.anyoneDeposits(2, false, 5_000e6);
        assertGt(handler.deposits(), 0, "a role-free caller funded the vault");
        handler.anyoneFundsRewards(2, 5_000e6);
        assertGt(handler.fundings(), 0, "and the reward balance");

        handler.withdrawUsdg(1_000e6);
        assertGt(handler.usdgWithdrawals(), 0, "USDG left");
        handler.withdrawStock(1e18);
        assertGt(handler.stockWithdrawals(), 0, "a Stock Token left");
        handler.withdrawPosition(100, false);
        handler.withdrawPosition(100, true);
        assertGt(handler.positionWithdrawals(), 0, "an option position left");
        handler.defund(1_000e6);
        assertGt(handler.defunds(), 0, "rewards were reclaimed");

        // The pointer moves, and the next exit follows it rather than the old address.
        uint256 before = usdg.balanceOf(treasuries[1]);
        handler.moveTheTreasury(1, true);
        assertGt(handler.treasuryMoves(), 0, "the vault's exit moved");
        assertEq(vault.treasury(), treasuries[1], "to the second safe");
        handler.withdrawUsdg(1_000e6);
        assertEq(usdg.balanceOf(treasuries[1]) - before, 1_000e6, "the exit followed the pointer");
        handler.moveTheTreasury(2, false);

        // Every role-free attempt is refused, including the quoter's.
        for (uint8 which; which < 4; ++which) {
            handler.outsiderTriesToExit(0, which, 1_000e6);
        }
        handler.outsiderTriesToMoveTheTreasury(0, true);
        handler.outsiderTriesToMoveTheTreasury(2, false);
        assertGe(handler.refusedAttempts(), 6, "every role-free attempt was refused");

        invariant_everySuccessfulExitLandedOnTheTreasuryInFull();
        invariant_onlyTheTreasuryLaneCanExit();
        invariant_noNonTreasuryAddressEverGained();
        invariant_theExitIsAlwaysSetAndInsideTheAllowedSet();
        invariant_theTreasurySetHoldsExactlyWhatLeft();
    }

    /// @dev T-173's half of the non-vacuity pass. A green campaign must be evidence about the Hedger's exit and not
    ///      about a handler that never reached it, so every counter this file asserts on is moved once, by hand.
    function test_hedgerHandlerExercisesItsExit() public {
        hedgerHandler.anyoneFunds(2, 5_000e6);
        assertGt(hedgerHandler.deposits(), 0, "a role-free caller funded the Hedger");

        uint256 before = usdg.balanceOf(hedgerTreasury);
        hedgerHandler.withdrawUsdg(1_000e6);
        assertGt(hedgerHandler.withdrawals(), 0, "USDG left the Hedger");
        assertEq(usdg.balanceOf(hedgerTreasury) - before, 1_000e6, "and it landed on the immutable treasury");

        for (uint8 who; who < 3; ++who) {
            hedgerHandler.outsiderTriesToExit(who, 1_000e6);
        }
        assertGe(hedgerHandler.refusedAttempts(), 3, "every role-free attempt on the Hedger was refused");

        invariant_everyHedgerExitLandedOnItsTreasuryInFull();
        invariant_onlyTheTreasuryLaneCanExitTheHedger();
        invariant_theHedgerExitCanNeverBeRepointed();
        invariant_theHedgerTreasuryHoldsExactlyWhatLeftTheHedger();
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _actors() internal view returns (address[6] memory) {
        return [quoter, keeper, stranger, admin, alice, bob];
    }

    function _recordActorStarts() internal {
        address[6] memory actors = _actors();
        for (uint256 i; i < actors.length; ++i) {
            actorStartUsdg[i] = usdg.balanceOf(actors[i]);
            actorStartStock[i] = nvda.balanceOf(actors[i]);
            actorStartLongs[i] = ch.balanceOf(actors[i], callId);
            actorStartShorts[i] = ch.balanceOf(actors[i], shortId);
        }
    }

    function _isATreasury(address who) internal view returns (bool) {
        for (uint256 i; i < treasuries.length; ++i) {
            if (treasuries[i] == who) return true;
        }
        return false;
    }
}
